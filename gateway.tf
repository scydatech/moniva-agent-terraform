# ===================== AgentCore Gateway =====================
# Exposes the transaction tools to the agent over MCP. Inbound calls are authorized with AWS IAM
# (only the agent runtime role may invoke it); outbound calls to Lambda use the gateway's own role.

locals {
  gateway_tools = {
    "get-transaction" = {
      tool        = "get_transaction"
      description = "Look up a single transaction by its reference. Returns amount, type, channel, status, timestamps, counterparty (masked), failure reason, settlement status and reversal details."
      properties = [
        { name = "transaction_reference", type = "string", description = "Transaction reference, e.g. TXN-20260921-0001", required = true },
      ]
    }
    "get-account-profile" = {
      tool        = "get_account_profile"
      description = "Look up an account by ID. Returns account name, KYC tier, status (ACTIVE, PND, FROZEN), limits, balances, risk flags and recent security events. Contact details are masked."
      properties = [
        { name = "account_id", type = "string", description = "Account ID, e.g. ACC-1001", required = true },
      ]
    }
    "list-account-transactions" = {
      tool        = "list_account_transactions"
      description = "List an account's transactions, newest first, for the last N days."
      properties = [
        { name = "account_id", type = "string", description = "Account ID, e.g. ACC-1001", required = true },
        { name = "days", type = "integer", description = "How many days back to look (1-90). Default 14.", required = false },
        { name = "limit", type = "integer", description = "Maximum transactions to return (1-50). Default 20.", required = false },
      ]
    }
    "find-similar-transactions" = {
      tool        = "find_similar_transactions"
      description = "Find transactions on the same account with the same amount and counterparty close in time to a given transaction. Use to check for duplicate debits or repeated attempts."
      properties = [
        { name = "transaction_reference", type = "string", description = "Reference of the transaction to compare against", required = true },
        { name = "window_minutes", type = "integer", description = "Minutes before and after to search (1-1440). Default 60.", required = false },
      ]
    }
  }
}

data "aws_iam_policy_document" "agentcore_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "tools-gateway-role-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.agentcore_trust.json
}

resource "aws_iam_role_policy" "gateway" {
  name = "tools-gateway-policy-${local.sfx}"
  role = aws_iam_role.gateway.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeTransactionTools"
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [aws_lambda_function.tools.arn, "${aws_lambda_function.tools.arn}:*"]
    }]
  })
}

resource "time_sleep" "gateway_iam" {
  depends_on      = [aws_iam_role_policy.gateway]
  create_duration = "15s"
}

resource "aws_bedrockagentcore_gateway" "tools" {
  name            = "tools-gateway-${local.sfx}"
  description     = "Controlled transaction and account lookups for the Moniva investigation agent"
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "AWS_IAM"

  protocol_configuration {
    mcp {
      instructions = "Read-only tools for investigating Moniva transactions. No tool can change an account or payment."
    }
  }

  depends_on = [time_sleep.gateway_iam]
}

resource "aws_bedrockagentcore_gateway_target" "tools" {
  for_each = local.gateway_tools

  name               = each.key
  gateway_identifier = aws_bedrockagentcore_gateway.tools.gateway_id
  description        = each.value.description

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tools.arn
        tool_schema {
          inline_payload {
            name        = each.value.tool
            description = each.value.description
            input_schema {
              type = "object"
              dynamic "property" {
                for_each = each.value.properties
                content {
                  name        = property.value.name
                  type        = property.value.type
                  description = property.value.description
                  required    = property.value.required
                }
              }
            }
          }
        }
      }
    }
  }
}
