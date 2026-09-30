"""
Moniva transaction tools - invoked by AgentCore Gateway on behalf of the investigation agent.

The gateway passes the tool arguments as the event and the tool name in the client context
("<target>___<tool>"). Every tool is read-only; sensitive fields are masked before they leave this function.
"""
import json
import logging
import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
transactions = dynamodb.Table(os.environ["TRANSACTIONS_TABLE"])
accounts = dynamodb.Table(os.environ["ACCOUNTS_TABLE"])
ACCOUNT_TIME_INDEX = os.environ.get("ACCOUNT_TIME_INDEX", "account-time-index")


class ToolError(Exception):
    pass


# ---------------------------------------------------------------- helpers
def _plain(value):
    """DynamoDB Decimals -> int/float, recursively."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, (list, set, tuple)):
        return [_plain(v) for v in value]
    return value


def _mask(value, keep=4):
    value = str(value or "")
    return ("*" * max(len(value) - keep, 0)) + value[-keep:] if value else value


def _mask_email(value):
    if not value or "@" not in value:
        return value
    name, domain = value.split("@", 1)
    return f"{name[:1]}***@{domain}"


def _parse_ts(value):
    return datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def _iso(dt):
    """Same format as stored timestamps (UTC, second precision, 'Z'), so string ranges compare correctly."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _clamp(value, default, low, high):
    try:
        value = int(value)
    except (TypeError, ValueError):
        return default
    return max(low, min(high, value))


def _require(args, name):
    value = str(args.get(name) or "").strip()
    if not value:
        raise ToolError(f"'{name}' is required.")
    if len(value) > 64:
        raise ToolError(f"'{name}' is too long.")
    return value


def _public_transaction(item):
    item = _plain(item)
    if "counterparty_account" in item:
        item["counterparty_account"] = _mask(item["counterparty_account"])
    if "card_number" in item:
        item["card_number"] = _mask(item["card_number"])
    return item


# ---------------------------------------------------------------- tools
def get_transaction(args):
    ref = _require(args, "transaction_reference")
    item = transactions.get_item(Key={"transaction_ref": ref}).get("Item")
    if not item:
        return {"found": False, "transaction_reference": ref, "message": "No transaction with this reference."}
    return {"found": True, "transaction": _public_transaction(item)}


def get_account_profile(args):
    account_id = _require(args, "account_id")
    item = accounts.get_item(Key={"account_id": account_id}).get("Item")
    if not item:
        return {"found": False, "account_id": account_id, "message": "No account with this ID."}
    item = _plain(item)
    item["phone"] = _mask(item.get("phone"))
    item["email"] = _mask_email(item.get("email"))
    item.pop("bvn", None)  # never returned to the agent
    return {"found": True, "account": item}


def list_account_transactions(args):
    account_id = _require(args, "account_id")
    days = _clamp(args.get("days"), 14, 1, 90)
    limit = _clamp(args.get("limit"), 20, 1, 50)
    since = _iso(datetime.now(timezone.utc) - timedelta(days=days))
    resp = transactions.query(
        IndexName=ACCOUNT_TIME_INDEX,
        KeyConditionExpression=Key("account_id").eq(account_id) & Key("timestamp").gte(since),
        ScanIndexForward=False,
        Limit=limit,
    )
    items = [_public_transaction(i) for i in resp.get("Items", [])]
    return {"account_id": account_id, "days": days, "count": len(items), "transactions": items}


def find_similar_transactions(args):
    ref = _require(args, "transaction_reference")
    window = _clamp(args.get("window_minutes"), 60, 1, 1440)
    base = transactions.get_item(Key={"transaction_ref": ref}).get("Item")
    if not base:
        return {"found": False, "transaction_reference": ref, "message": "No transaction with this reference."}

    ts = _parse_ts(base["timestamp"])
    start, end = _iso(ts - timedelta(minutes=window)), _iso(ts + timedelta(minutes=window))
    resp = transactions.query(
        IndexName=ACCOUNT_TIME_INDEX,
        KeyConditionExpression=Key("account_id").eq(base["account_id"]) & Key("timestamp").between(start, end),
    )
    matches = [
        _public_transaction(i) for i in resp.get("Items", [])
        if i["transaction_ref"] != ref
        and i.get("amount") == base.get("amount")
        and i.get("counterparty_account") == base.get("counterparty_account")
    ]
    return {
        "transaction_reference": ref,
        "window_minutes": window,
        "criteria": "same account, same amount, same counterparty",
        "similar_count": len(matches),
        "similar_transactions": matches,
    }


TOOLS = {
    "get_transaction": get_transaction,
    "get_account_profile": get_account_profile,
    "list_account_transactions": list_account_transactions,
    "find_similar_transactions": find_similar_transactions,
}


def _tool_name(context):
    custom = getattr(getattr(context, "client_context", None), "custom", None) or {}
    full = custom.get("bedrockAgentCoreToolName", "")
    return full.split("___", 1)[-1]


def handler(event, context):
    name = _tool_name(context)
    args = event if isinstance(event, dict) else {}
    tool = TOOLS.get(name)
    if not tool:
        logger.warning(json.dumps({"event": "unknown_tool", "tool": name}))
        return {"error": f"Unknown tool '{name}'."}
    try:
        result = tool(args)
        logger.info(json.dumps({"event": "tool_call", "tool": name, "args": args, "ok": True}))
        return result
    except ToolError as e:
        logger.info(json.dumps({"event": "tool_call", "tool": name, "args": args, "ok": False, "error": str(e)}))
        return {"error": str(e)}
