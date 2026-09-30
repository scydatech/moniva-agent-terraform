# ===================== Investigations API =====================
# Investigations can take longer than API Gateway's 30-second limit, so the API is asynchronous:
#   POST /v1/investigations                 -> 202 + investigation_id (worker runs the agent in the background)
#   POST /v1/investigations/{id}/messages   -> 202, follow-up question on the same investigation
#   GET  /v1/investigations/{id}            -> status, case summaries and evidence
#   GET  /v1/investigations                 -> the caller's recent investigations

# ---------- API Lambda ----------
resource "aws_iam_role" "api" {
  name               = "investigations-api-role-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "api" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }
  statement {
    sid       = "Investigations"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
    resources = [aws_dynamodb_table.investigations.arn, "${aws_dynamodb_table.investigations.arn}/index/*"]
  }
  statement {
    sid       = "StartWorker"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.worker.arn]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "investigations-api-policy-${local.sfx}"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

data "archive_file" "api" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/api"
  output_path = "${path.module}/build/api.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "api" {
  function_name    = "investigations-api-${local.sfx}"
  description      = "Creates and returns transaction investigations"
  role             = aws_iam_role.api.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  timeout          = 15
  memory_size      = 256
  kms_key_arn      = aws_kms_key.main.arn

  environment {
    variables = {
      INVESTIGATIONS_TABLE = aws_dynamodb_table.investigations.name
      OWNER_INDEX          = "owner-created-index"
      WORKER_FUNCTION      = aws_lambda_function.worker.function_name
      INVESTIGATOR_GROUPS  = join(",", values(local.staff_groups))
      SUPERVISOR_GROUPS    = join(",", [local.staff_groups.supervisors, local.staff_groups.admins])
      RETENTION_DAYS       = tostring(var.investigation_retention_days)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.api.name
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy.api]
}

# ---------- Worker Lambda: runs one investigation turn on AgentCore Runtime ----------
resource "aws_iam_role" "worker" {
  name               = "investigation-worker-role-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "worker" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.worker.arn}:*"]
  }
  statement {
    sid     = "InvokeAgent"
    actions = ["bedrock-agentcore:InvokeAgentRuntime"]
    resources = [
      aws_bedrockagentcore_agent_runtime.investigation.agent_runtime_arn,
      "${aws_bedrockagentcore_agent_runtime.investigation.agent_runtime_arn}/*",
    ]
  }
  statement {
    sid       = "UpdateInvestigation"
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.investigations.arn]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "investigation-worker-policy-${local.sfx}"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

data "archive_file" "worker" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/worker"
  output_path = "${path.module}/build/worker.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "worker" {
  function_name    = "investigation-worker-${local.sfx}"
  description      = "Runs an investigation turn on the AgentCore agent and stores the result"
  role             = aws_iam_role.worker.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256
  timeout          = 600
  memory_size      = 256
  kms_key_arn      = aws_kms_key.main.arn

  environment {
    variables = {
      INVESTIGATIONS_TABLE = aws_dynamodb_table.investigations.name
      AGENT_RUNTIME_ARN    = aws_bedrockagentcore_agent_runtime.investigation.agent_runtime_arn
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.worker.name
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy.worker]
}

# One attempt per turn: a retry would repeat the whole investigation.
resource "aws_lambda_function_event_invoke_config" "worker" {
  function_name                = aws_lambda_function.worker.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 300
}

# ---------- HTTP API ----------
resource "aws_apigatewayv2_api" "main" {
  name          = "investigations-http-api-${local.sfx}"
  protocol_type = "HTTP"
  description   = "Moniva transaction investigation API"

  cors_configuration {
    allow_origins = var.allowed_cors_origins
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  name             = "cognito-authorizer-${local.sfx}"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.staff.id}"
  }
}

resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 15000
}

resource "aws_apigatewayv2_route" "routes" {
  for_each = toset([
    "POST /v1/investigations",
    "GET /v1/investigations",
    "GET /v1/investigations/{id}",
    "POST /v1/investigations/{id}/messages",
  ])

  api_id             = aws_apigatewayv2_api.main.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "main" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = var.environment
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit   = 20
    throttling_rate_limit    = 10
    detailed_metrics_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      requestTime    = "$context.requestTime"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      userSub        = "$context.authorizer.claims.sub"
      latencyMs      = "$context.responseLatency"
      integrationErr = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
