"""
Moniva investigations API.

  POST /v1/investigations                 start an investigation            -> 202
  POST /v1/investigations/{id}/messages   follow-up on an investigation     -> 202
  GET  /v1/investigations/{id}            status, case summaries, evidence  -> 200
  GET  /v1/investigations                 the caller's recent investigations -> 200

Work runs asynchronously in the worker Lambda; clients poll GET /v1/investigations/{id}.
"""
import json
import os
import re
import time
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

table = boto3.resource("dynamodb").Table(os.environ["INVESTIGATIONS_TABLE"])
lambda_client = boto3.client("lambda")

OWNER_INDEX = os.environ.get("OWNER_INDEX", "owner-created-index")
WORKER_FUNCTION = os.environ["WORKER_FUNCTION"]
INVESTIGATOR_GROUPS = {g for g in os.environ.get("INVESTIGATOR_GROUPS", "").split(",") if g}
SUPERVISOR_GROUPS = {g for g in os.environ.get("SUPERVISOR_GROUPS", "").split(",") if g}
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "365"))

MAX_REQUEST_CHARS = 4000
MAX_TURNS = 20
STALE_AFTER = timedelta(minutes=12)  # worker timeout is 10 minutes
ID_RE = re.compile(r"^inv-[0-9a-f]{32}$")
REF_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


# ---------------------------------------------------------------- helpers
def _now():
    return datetime.now(timezone.utc)


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _json(value):
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body, default=_json),
    }


def _groups(claims):
    raw = claims.get("cognito:groups", "")
    if isinstance(raw, list):
        return set(raw)
    return {g for g in re.split(r"[\s,]+", str(raw).strip("[]")) if g}


def _body(event):
    try:
        return json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        raise ApiError(400, "Body must be valid JSON.")


def _request_text(body):
    text = str(body.get("request", "")).strip()
    if not text:
        raise ApiError(400, "'request' is required.")
    if len(text) > MAX_REQUEST_CHARS:
        raise ApiError(400, f"'request' must be at most {MAX_REQUEST_CHARS} characters.")
    return text


def _is_stale(item):
    if item.get("status") != "RUNNING":
        return False
    updated = datetime.fromisoformat(item.get("updated_at", "1970-01-01T00:00:00Z").replace("Z", "+00:00"))
    return _now() - updated > STALE_AFTER


def _load(investigation_id, caller_sub, groups):
    if not ID_RE.match(investigation_id or ""):
        raise ApiError(404, "Investigation not found.")
    item = table.get_item(Key={"investigation_id": investigation_id}).get("Item")
    if not item or (item["owner_sub"] != caller_sub and not groups & SUPERVISOR_GROUPS):
        raise ApiError(404, "Investigation not found.")
    return item


def _start_turn(item, index, request_text, caller_sub, groups):
    lambda_client.invoke(
        FunctionName=WORKER_FUNCTION,
        InvocationType="Event",
        Payload=json.dumps({
            "investigation_id": item["investigation_id"],
            "turn_index": index,
            "request": request_text,
            "transaction_reference": item.get("transaction_reference"),
            # Memory is kept per investigation owner, so follow-ups by a supervisor share the same context.
            "user": {"sub": item["owner_sub"], "requested_by": caller_sub, "groups": sorted(groups)},
        }).encode("utf-8"),
    )


def _audit(**fields):
    print(json.dumps(fields, default=str))


# ---------------------------------------------------------------- routes
def create_investigation(event, caller_sub, email, groups):
    body = _body(event)
    request_text = _request_text(body)
    reference = str(body.get("transaction_reference") or "").strip() or None
    if reference and not REF_RE.match(reference):
        raise ApiError(400, "'transaction_reference' has an invalid format.")

    now = _now()
    item = {
        "investigation_id": f"inv-{uuid.uuid4().hex}",
        "owner_sub": caller_sub,
        "owner_email": email,
        "transaction_reference": reference,
        "title": (reference + ": " if reference else "") + request_text[:120],
        "status": "RUNNING",
        "created_at": _iso(now),
        "updated_at": _iso(now),
        "expires_at": int(time.time()) + RETENTION_DAYS * 86400,
        "turns": [{"index": 0, "request": request_text, "requested_by": caller_sub,
                   "requested_at": _iso(now), "turn_status": "RUNNING"}],
    }
    item = {k: v for k, v in item.items() if v is not None}
    table.put_item(Item=item, ConditionExpression="attribute_not_exists(investigation_id)")
    _start_turn(item, 0, request_text, caller_sub, groups)
    _audit(event="investigation_created", investigation_id=item["investigation_id"], user=caller_sub,
           transaction_reference=reference)
    return _response(202, {"investigation_id": item["investigation_id"], "status": "RUNNING", "turn_index": 0,
                           "poll": f"/v1/investigations/{item['investigation_id']}"})


def add_message(event, caller_sub, groups):
    investigation_id = (event.get("pathParameters") or {}).get("id", "")
    item = _load(investigation_id, caller_sub, groups)
    request_text = _request_text(_body(event))

    turns = item.get("turns", [])
    if item.get("status") == "RUNNING" and not _is_stale(item):
        raise ApiError(409, "This investigation is still running. Wait for the current answer before asking a follow-up.")
    if len(turns) >= MAX_TURNS:
        raise ApiError(409, f"This investigation has reached {MAX_TURNS} turns. Start a new investigation.")

    now = _iso(_now())
    index = len(turns)
    try:
        table.update_item(
            Key={"investigation_id": investigation_id},
            UpdateExpression="SET turns = list_append(turns, :turn), #status = :running, updated_at = :now",
            ConditionExpression="size(turns) = :count",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":turn": [{"index": index, "request": request_text, "requested_by": caller_sub,
                           "requested_at": now, "turn_status": "RUNNING"}],
                ":running": "RUNNING", ":now": now, ":count": index,
            },
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise ApiError(409, "The investigation changed while sending. Refresh and try again.")
        raise
    _start_turn(item, index, request_text, caller_sub, groups)
    _audit(event="investigation_followup", investigation_id=investigation_id, user=caller_sub, turn=index)
    return _response(202, {"investigation_id": investigation_id, "status": "RUNNING", "turn_index": index})


def get_investigation(event, caller_sub, groups):
    investigation_id = (event.get("pathParameters") or {}).get("id", "")
    item = _load(investigation_id, caller_sub, groups)
    if _is_stale(item):
        item["status"] = "STALLED"
    item.pop("expires_at", None)
    _audit(event="investigation_viewed", investigation_id=investigation_id, user=caller_sub)
    return _response(200, item)


def list_investigations(event, caller_sub):
    resp = table.query(
        IndexName=OWNER_INDEX,
        KeyConditionExpression=Key("owner_sub").eq(caller_sub),
        ScanIndexForward=False,
        Limit=20,
    )
    items = [{
        "investigation_id": i["investigation_id"],
        "title": i.get("title"),
        "status": "STALLED" if _is_stale(i) else i.get("status"),
        "transaction_reference": i.get("transaction_reference"),
        "created_at": i.get("created_at"),
        "updated_at": i.get("updated_at"),
        "turns": len(i.get("turns", [])),
    } for i in resp.get("Items", [])]
    return _response(200, {"investigations": items})


def handler(event, context):
    claims = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
    caller_sub = claims.get("sub", "")
    groups = _groups(claims)
    route = event.get("routeKey", "")
    try:
        if not caller_sub or not groups & INVESTIGATOR_GROUPS:
            raise ApiError(403, "Your account is not assigned to an investigation group.")
        if route == "POST /v1/investigations":
            return create_investigation(event, caller_sub, claims.get("email", ""), groups)
        if route == "POST /v1/investigations/{id}/messages":
            return add_message(event, caller_sub, groups)
        if route == "GET /v1/investigations/{id}":
            return get_investigation(event, caller_sub, groups)
        if route == "GET /v1/investigations":
            return list_investigations(event, caller_sub)
        raise ApiError(404, "Route not found.")
    except ApiError as e:
        return _response(e.status, {"error": e.message})
