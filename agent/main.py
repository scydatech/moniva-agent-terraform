"""
Moniva transaction investigation agent - runs on Amazon Bedrock AgentCore Runtime.

Contract: HTTP server on port 8080 with GET /ping and POST /invocations.

One invocation = one investigation turn:
  1. Input guardrail checks the staff request (blocks requests for the agent to take account/payment actions).
  2. Prior turns of this investigation are loaded from AgentCore Memory.
  3. Claude Sonnet 4.5 plans and calls tools:
       - transaction/account tools through AgentCore Gateway (MCP, IAM-signed)
       - search_procedures against the Bedrock knowledge base of approved procedures
  4. The model writes a structured case summary; the output guardrail masks sensitive data.
  5. The turn is saved to AgentCore Memory for follow-up questions.

The agent is read-only: it gathers evidence and recommends next steps. Staff authorize any action.
"""
import json
import logging
import os
import re
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.config import Config

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("investigation-agent")

REGION = os.environ.get("MONIVA_REGION") or os.environ.get("AWS_REGION", "eu-central-1")
MODEL_ID = os.environ["MODEL_ID"]
GATEWAY_URL = os.environ["GATEWAY_URL"]
MEMORY_ID = os.environ.get("MEMORY_ID", "")
KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
KB_NUMBER_OF_RESULTS = int(os.environ.get("KB_NUMBER_OF_RESULTS", "5"))
INPUT_GUARDRAIL_ID = os.environ.get("INPUT_GUARDRAIL_ID", "")
INPUT_GUARDRAIL_VERSION = os.environ.get("INPUT_GUARDRAIL_VERSION", "")
OUTPUT_GUARDRAIL_ID = os.environ.get("OUTPUT_GUARDRAIL_ID", "")
OUTPUT_GUARDRAIL_VERSION = os.environ.get("OUTPUT_GUARDRAIL_VERSION", "")
MAX_STEPS = int(os.environ.get("MAX_STEPS", "10"))
MAX_OUTPUT_TOKENS = int(os.environ.get("MAX_OUTPUT_TOKENS", "3000"))
MAX_TOOL_RESULT_CHARS = 8000
HISTORY_TURNS = 5

# Requests that instruct the agent to act on money or accounts. The agent has no tools that can do this;
# this gives staff a clear answer instead of an attempted investigation.
ACTION_COMMAND_RE = re.compile(
    r"^\s*(?:please\s+|kindly\s+|go ahead and\s+|(?:can|could|would) you\s+)?"
    r"(?:reverse|refund|credit|debit|freeze|unfreeze|block|unblock|close|reopen|increase|raise|reduce|lower|"
    r"reset|send|transfer|pay|cancel|retry|approve|waive|release|lift)\b",
    re.IGNORECASE,
)
ACTION_MESSAGE = ("The investigation agent can't perform or approve account or payment actions. "
                  "It gathers evidence and prepares a case summary; authorized staff take any action.")


def is_action_command(text):
    return any(ACTION_COMMAND_RE.match(sentence) for sentence in re.split(r"[.!?\n]+", text))

_cfg = Config(region_name=REGION, retries={"max_attempts": 4, "mode": "adaptive"}, read_timeout=120)
bedrock = boto3.client("bedrock-runtime", config=_cfg)
kb = boto3.client("bedrock-agent-runtime", config=_cfg)
agentcore = boto3.client("bedrock-agentcore", config=_cfg)
_session = boto3.Session(region_name=REGION)

SYSTEM_PROMPT = """You are the Moniva Transaction Investigation Agent, working for Moniva operations staff.

Your job: investigate the transaction or account issue the staff member describes, gather the evidence with your tools, check the applicable operational procedure, and prepare a structured case summary.

How to work:
- Start from the transaction reference or account ID you are given. Look up the transaction, the account, related or similar transactions, and recent activity as needed.
- Always search the approved procedures (search_procedures) for the situation you find, and follow them.
- Base every finding on tool results. Quote exact references, amounts (NGN), statuses and timestamps. Never invent data.
- If a tool returns nothing or an error, say so and continue with what you have.
- You are read-only. You cannot and must not reverse, refund, freeze, unfreeze, or change anything. Recommend actions for staff and state who must authorize them according to the procedure.

Write the final answer in Markdown with exactly these sections:
## Summary
Two or three sentences: what happened and the most likely explanation.
## Transaction details
The key facts of the transaction(s) involved.
## Evidence reviewed
A bulleted list; each item names what was checked (tool and reference) and what it showed.
## Applicable procedure
The procedure(s) that apply, cited as [P1], [P2] from search_procedures results.
## Findings
Numbered findings, each tied to evidence.
## Recommended next steps
Numbered steps. Mark every consequential action (reversal, refund, freeze, unfreeze, limit change, escalation to a bank or regulator) with **Requires staff authorization** and name the approver the procedure specifies.
## Open questions
Anything missing or uncertain that staff should check.

Today's date (UTC) is {today}."""

LOCAL_TOOLS = [{
    "toolSpec": {
        "name": "search_procedures",
        "description": "Search Moniva's approved operational procedures (investigation steps, reversal rules, escalation and authorization matrices, timelines). Use for every investigation.",
        "inputSchema": {"json": {
            "type": "object",
            "properties": {"query": {"type": "string", "description": "What to look up, e.g. 'failed transfer customer debited reversal timeline'"}},
            "required": ["query"],
        }},
    }
}]


# ---------------------------------------------------------------- AgentCore Gateway (MCP over HTTPS, SigV4-signed)
class GatewayClient:
    def __init__(self, url):
        self.url = url
        self.session_id = None
        self._id = 0
        self._tools = None
        self._tools_loaded = 0.0
        self._lock = threading.Lock()

    def _post(self, method, params=None, notify=False):
        self._id += 1
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            message["id"] = self._id
        body = json.dumps(message).encode()

        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        request = AWSRequest(method="POST", url=self.url, data=body, headers=headers)
        SigV4Auth(_session.get_credentials().get_frozen_credentials(), "bedrock-agentcore", REGION).add_auth(request)

        http_request = urllib.request.Request(self.url, data=body, headers=dict(request.headers), method="POST")
        with urllib.request.urlopen(http_request, timeout=60) as response:
            self.session_id = response.headers.get("Mcp-Session-Id", self.session_id)
            raw = response.read().decode("utf-8")
            content_type = response.headers.get("Content-Type", "")
        if notify or not raw.strip():
            return None
        return self._parse(raw, content_type)

    @staticmethod
    def _parse(raw, content_type):
        if "text/event-stream" in content_type:
            result = None
            for line in raw.splitlines():
                if line.startswith("data:"):
                    data = line[5:].strip()
                    if data:
                        msg = json.loads(data)
                        if "result" in msg or "error" in msg:
                            result = msg
            if result is None:
                raise RuntimeError("Gateway returned an empty event stream")
            msg = result
        else:
            msg = json.loads(raw)
        if "error" in msg:
            raise RuntimeError(f"Gateway error: {msg['error']}")
        return msg.get("result", {})

    def _ensure_initialized(self):
        if self.session_id is None and self._tools is None:
            self._post("initialize", {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "moniva-investigation-agent", "version": "1.0"},
            })
            try:
                self._post("notifications/initialized", notify=True)
            except urllib.error.HTTPError:
                pass  # some servers don't acknowledge notifications

    def tool_specs(self):
        """Bedrock toolSpecs for every gateway tool (cached for 10 minutes)."""
        with self._lock:
            if self._tools is None or time.time() - self._tools_loaded > 600:
                self._ensure_initialized()
                tools, cursor = [], None
                while True:
                    result = self._post("tools/list", {"cursor": cursor} if cursor else {})
                    tools.extend(result.get("tools", []))
                    cursor = result.get("nextCursor")
                    if not cursor:
                        break
                self._tools = [{
                    "toolSpec": {
                        "name": t["name"],
                        "description": (t.get("description") or t["name"])[:1000],
                        "inputSchema": {"json": t.get("inputSchema") or {"type": "object", "properties": {}}},
                    }
                } for t in tools]
                self._tools_loaded = time.time()
            return self._tools

    def call(self, name, arguments):
        with self._lock:
            result = self._post("tools/call", {"name": name, "arguments": arguments or {}})
        text = "".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        return text, bool(result.get("isError"))


gateway = GatewayClient(GATEWAY_URL)


# ---------------------------------------------------------------- tools
def search_procedures(query):
    resp = kb.retrieve(
        knowledgeBaseId=KNOWLEDGE_BASE_ID,
        retrievalQuery={"text": query[:1000]},
        retrievalConfiguration={"vectorSearchConfiguration": {"numberOfResults": KB_NUMBER_OF_RESULTS}},
    )
    passages = []
    for i, r in enumerate(resp.get("retrievalResults", []), start=1):
        uri = r.get("location", {}).get("s3Location", {}).get("uri", "")
        passages.append({
            "id": f"P{i}",
            "document": uri.rsplit("/", 1)[-1],
            "score": round(r.get("score") or 0, 3),
            "text": r.get("content", {}).get("text", ""),
        })
    return {"query": query, "passages": passages}


def run_tool(name, arguments):
    """Returns (text_result, is_error)."""
    try:
        if name == "search_procedures":
            return json.dumps(search_procedures(str(arguments.get("query", "")))), False
        return gateway.call(name, arguments)
    except Exception as exc:  # report tool failures to the model instead of failing the turn
        log.exception("Tool %s failed", name)
        return json.dumps({"error": f"{type(exc).__name__}: {exc}"}), True


def short_tool_name(name):
    return name.split("___", 1)[-1]


# ---------------------------------------------------------------- guardrails
def apply_guardrail(guardrail_id, version, source, text):
    """Returns (intervened, blocked, output_text)."""
    if not guardrail_id or not text:
        return False, False, text
    resp = bedrock.apply_guardrail(
        guardrailIdentifier=guardrail_id,
        guardrailVersion=version,
        source=source,
        content=[{"text": {"text": text}}],
    )
    if resp.get("action") != "GUARDRAIL_INTERVENED":
        return False, False, text
    output = "".join(o.get("text", "") for o in resp.get("outputs", [])) or text
    blocked = '"BLOCKED"' in json.dumps(resp.get("assessments", []))
    return True, blocked, output


# ---------------------------------------------------------------- memory
def load_history(actor_id, session_id):
    """Prior user/assistant turns of this investigation as Converse messages."""
    if not MEMORY_ID:
        return []
    try:
        resp = agentcore.list_events(
            memoryId=MEMORY_ID, actorId=actor_id, sessionId=session_id, includePayloads=True, maxResults=100
        )
    except Exception:
        log.exception("Could not load investigation memory")
        return []
    events = sorted(resp.get("events", []), key=lambda e: str(e.get("eventTimestamp")))
    turns = []
    for event in events:
        for item in event.get("payload", []):
            conv = item.get("conversational")
            if conv:
                turns.append((conv.get("role"), conv.get("content", {}).get("text", "")))
    messages = []
    for role, text in turns[-HISTORY_TURNS * 2:]:
        role = "user" if role == "USER" else "assistant"
        if not text or (messages and messages[-1]["role"] == role):
            continue
        if not messages and role != "user":
            continue
        messages.append({"role": role, "content": [{"text": text[:6000]}]})
    if messages and messages[-1]["role"] == "user":
        messages.pop()  # an unanswered earlier request; start fresh from the new one
    return messages


def save_turn(actor_id, session_id, request_text, answer):
    if not MEMORY_ID:
        return
    try:
        agentcore.create_event(
            memoryId=MEMORY_ID,
            actorId=actor_id,
            sessionId=session_id,
            eventTimestamp=datetime.now(timezone.utc),
            payload=[
                {"conversational": {"content": {"text": request_text}, "role": "USER"}},
                {"conversational": {"content": {"text": answer}, "role": "ASSISTANT"}},
            ],
        )
    except Exception:
        log.exception("Could not save investigation memory")


# ---------------------------------------------------------------- agent loop
def investigate(payload, session_id):
    started = time.time()
    request_text = str(payload.get("request", "")).strip()
    reference = str(payload.get("transaction_reference") or "").strip()
    user = payload.get("user") or {}
    actor_id = str(user.get("sub") or "unknown-actor")
    investigation_id = str(payload.get("investigation_id") or session_id)

    if not request_text:
        return {"status": "FAILED", "error": "Empty request."}

    if is_action_command(request_text):
        log.info(json.dumps({"event": "action_request_declined", "investigation_id": investigation_id}))
        return {"status": "BLOCKED", "answer": ACTION_MESSAGE, "evidence": [], "guardrail": {"input": "blocked"}}

    # 1. Input guardrail on the staff request
    intervened, _, message = apply_guardrail(INPUT_GUARDRAIL_ID, INPUT_GUARDRAIL_VERSION, "INPUT", request_text)
    if intervened:
        log.info(json.dumps({"event": "input_blocked", "investigation_id": investigation_id}))
        return {"status": "BLOCKED", "answer": message, "evidence": [], "guardrail": {"input": "blocked"}}

    # 2. Context: earlier turns of this investigation
    messages = load_history(actor_id, investigation_id)
    user_text = request_text if not reference else f"Transaction reference: {reference}\n\n{request_text}"
    messages.append({"role": "user", "content": [{"text": user_text}]})

    # 3. Plan, call tools, repeat
    tool_config = {"tools": LOCAL_TOOLS + gateway.tool_specs()}
    system = [{"text": SYSTEM_PROMPT.format(today=datetime.now(timezone.utc).strftime("%Y-%m-%d"))}]
    evidence, usage = [], {"inputTokens": 0, "outputTokens": 0}
    answer, steps = "", 0

    for steps in range(1, MAX_STEPS + 1):
        resp = bedrock.converse(
            modelId=MODEL_ID,
            system=system,
            messages=messages,
            toolConfig=tool_config,
            inferenceConfig={"maxTokens": MAX_OUTPUT_TOKENS, "temperature": 0.1},
        )
        for k in usage:
            usage[k] += resp.get("usage", {}).get(k, 0)
        msg = resp["output"]["message"]
        messages.append(msg)

        if resp.get("stopReason") != "tool_use":
            answer = "".join(b.get("text", "") for b in msg["content"]).strip()
            break

        results = []
        for block in msg["content"]:
            call = block.get("toolUse")
            if not call:
                continue
            text, is_error = run_tool(call["name"], call.get("input") or {})
            evidence.append({
                "step": steps,
                "tool": short_tool_name(call["name"]),
                "input": call.get("input") or {},
                "ok": not is_error,
                "result_preview": text[:500],
            })
            results.append({"toolResult": {
                "toolUseId": call["toolUseId"],
                "content": [{"text": text[:MAX_TOOL_RESULT_CHARS]}],
                "status": "error" if is_error else "success",
            }})
        if steps == MAX_STEPS - 1:
            results.append({"text": "Step limit reached. Do not call more tools. Write the case summary now from the evidence gathered, noting anything left unchecked under Open questions."})
        messages.append({"role": "user", "content": results})

    if "## Summary" in answer:
        answer = answer[answer.index("## Summary"):]  # drop any preamble before the report

    if not answer:
        answer = ("## Summary\nThe investigation reached its step limit before a summary was written. "
                  "Review the evidence below and ask a narrower follow-up question.")

    # 4. Output guardrail on the case summary (masks sensitive data; blocks harmful content)
    out_intervened, out_blocked, answer = apply_guardrail(OUTPUT_GUARDRAIL_ID, OUTPUT_GUARDRAIL_VERSION, "OUTPUT", answer)

    # 5. Remember this turn for follow-up questions
    save_turn(actor_id, investigation_id, user_text, answer)

    result = {
        "status": "BLOCKED" if out_blocked else "COMPLETED",
        "answer": answer,
        "evidence": evidence,
        "steps": steps,
        "usage": usage,
        "guardrail": {"input": "passed", "output": "blocked" if out_blocked else ("masked" if out_intervened else "passed")},
        "latency_ms": int((time.time() - started) * 1000),
    }
    log.info(json.dumps({
        "event": "investigation_turn", "investigation_id": investigation_id, "actor": actor_id,
        "status": result["status"], "steps": steps, "tools": [e["tool"] for e in evidence],
        "usage": usage, "guardrail": result["guardrail"], "latency_ms": result["latency_ms"],
    }))
    return result


# ---------------------------------------------------------------- HTTP server (AgentCore Runtime contract)
_busy = 0
_busy_lock = threading.Lock()
_last_status_change = int(time.time())


def _set_busy(delta):
    global _busy, _last_status_change
    with _busy_lock:
        before = _busy > 0
        _busy += delta
        if (_busy > 0) != before:
            _last_status_change = int(time.time())


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        data = json.dumps(body, default=str).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") == "/ping":
            self._send(200, {"status": "HealthyBusy" if _busy > 0 else "Healthy",
                             "time_of_last_update": _last_status_change})
        else:
            self._send(404, {"error": "Not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/invocations":
            self._send(404, {"error": "Not found"})
            return
        session_id = self.headers.get("X-Amzn-Bedrock-AgentCore-Runtime-Session-Id", "")
        _set_busy(1)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
            self._send(200, investigate(payload, session_id))
        except json.JSONDecodeError:
            self._send(400, {"status": "FAILED", "error": "Body must be JSON."})
        except Exception as exc:
            log.exception("Investigation failed")
            self._send(500, {"status": "FAILED", "error": f"{type(exc).__name__}: {exc}"})
        finally:
            _set_busy(-1)

    def log_message(self, fmt, *args):  # keep logs to our JSON lines
        return


if __name__ == "__main__":
    log.info(json.dumps({"event": "agent_started", "region": REGION, "model": MODEL_ID}))
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
