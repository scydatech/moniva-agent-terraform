"""
Moniva investigation worker - runs one investigation turn on the AgentCore Runtime agent
and stores the result on the investigation record. Invoked asynchronously by the API Lambda.
"""
import json
import logging
import os
import time
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

AGENT_RUNTIME_ARN = os.environ["AGENT_RUNTIME_ARN"]
table = boto3.resource("dynamodb").Table(os.environ["INVESTIGATIONS_TABLE"])
agentcore = boto3.client(
    "bedrock-agentcore",
    config=Config(read_timeout=580, connect_timeout=10, retries={"max_attempts": 2, "mode": "standard"}),
)


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _dynamo_safe(value):
    """Floats -> Decimal for DynamoDB."""
    return json.loads(json.dumps(value, default=str), parse_float=Decimal)


def _log(**fields):
    print(json.dumps(fields, default=str))


def _save(investigation_id, index, turn_fields, item_status):
    names = {"#status": "status"}
    values = {":item_status": item_status, ":now": _now()}
    sets = ["#status = :item_status", "updated_at = :now"]
    for i, (key, value) in enumerate(turn_fields.items()):
        names[f"#f{i}"] = key
        values[f":v{i}"] = _dynamo_safe(value)
        sets.append(f"turns[{index}].#f{i} = :v{i}")
    table.update_item(
        Key={"investigation_id": investigation_id},
        UpdateExpression="SET " + ", ".join(sets),
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )


def handler(event, context):
    investigation_id = event["investigation_id"]
    index = int(event["turn_index"])
    started = time.time()

    payload = {
        "investigation_id": investigation_id,
        "turn_index": index,
        "request": event["request"],
        "transaction_reference": event.get("transaction_reference"),
        "user": event.get("user", {}),
    }

    try:
        resp = agentcore.invoke_agent_runtime(
            agentRuntimeArn=AGENT_RUNTIME_ARN,
            qualifier="DEFAULT",
            runtimeSessionId=investigation_id,  # one runtime session per investigation (>= 33 characters)
            contentType="application/json",
            accept="application/json",
            payload=json.dumps(payload).encode("utf-8"),
        )
        result = json.loads(resp["response"].read() or b"{}")
        status = result.get("status", "FAILED")
        if status not in ("COMPLETED", "BLOCKED"):
            raise RuntimeError(result.get("error") or "The agent did not return a result.")

        _save(investigation_id, index, {
            "turn_status": status,
            "answer": result.get("answer", ""),
            "evidence": result.get("evidence", []),
            "steps": result.get("steps", 0),
            "guardrail": result.get("guardrail", {}),
            "completed_at": _now(),
        }, item_status="READY")

        guardrail = result.get("guardrail", {})
        _log(event="investigation_completed", investigation_id=investigation_id, turn=index, status=status,
             steps=result.get("steps"), tools=[e.get("tool") for e in result.get("evidence", [])],
             usage=result.get("usage"), guardrail=guardrail,
             guardrail_blocked="blocked" in (guardrail.get("input"), guardrail.get("output")),
             latency_ms=int((time.time() - started) * 1000))

    except Exception as exc:
        logger.exception("Investigation turn failed")
        message = "The investigation could not be completed. Try again, or narrow the request."
        try:
            _save(investigation_id, index, {
                "turn_status": "FAILED",
                "answer": message,
                "error": f"{type(exc).__name__}: {str(exc)[:500]}",
                "completed_at": _now(),
            }, item_status="READY")
        finally:
            _log(event="investigation_failed", investigation_id=investigation_id, turn=index,
                 error=f"{type(exc).__name__}: {str(exc)[:300]}", latency_ms=int((time.time() - started) * 1000))
