# ===================== Logs =====================
resource "aws_cloudwatch_log_group" "tools" {
  name              = "/aws/lambda/transaction-tools-${local.sfx}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/investigations-api-${local.sfx}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/investigation-worker-${local.sfx}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "ingestion" {
  name              = "/aws/lambda/kb-ingestion-${local.sfx}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/investigations-http-api-${local.sfx}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

# X-Ray tracing for the Lambdas
resource "aws_iam_role_policy_attachment" "xray" {
  for_each = {
    tools  = aws_iam_role.tools.name
    api    = aws_iam_role.api.name
    worker = aws_iam_role.worker.name
  }
  role       = each.value
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ===================== Alarms =====================
resource "aws_sns_topic" "alarms" {
  name              = "alarms-${local.sfx}"
  kms_master_key_id = aws_kms_key.main.id
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  lambda_error_alarms = {
    api       = { function = aws_lambda_function.api.function_name, threshold = 3 }
    worker    = { function = aws_lambda_function.worker.function_name, threshold = 3 }
    tools     = { function = aws_lambda_function.tools.function_name, threshold = 5 }
    ingestion = { function = aws_lambda_function.ingestion.function_name, threshold = 3 }
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.lambda_error_alarms

  alarm_name          = "${each.key}-errors-${local.sfx}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value.function }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "api-5xx-${local.sfx}"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.main.id, Stage = aws_apigatewayv2_stage.main.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# The worker writes one JSON line per investigation turn; these filters turn them into metrics.
resource "aws_cloudwatch_log_metric_filter" "investigations_failed" {
  name           = "investigations-failed-${local.sfx}"
  log_group_name = aws_cloudwatch_log_group.worker.name
  pattern        = "{ $.event = \"investigation_failed\" }"
  metric_transformation {
    name      = "InvestigationsFailed"
    namespace = "InvestigationAgent/${local.sfx}"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "guardrail_blocks" {
  name           = "guardrail-blocks-${local.sfx}"
  log_group_name = aws_cloudwatch_log_group.worker.name
  pattern        = "{ $.guardrail_blocked = true }"
  metric_transformation {
    name      = "GuardrailBlocks"
    namespace = "InvestigationAgent/${local.sfx}"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "investigations_failed" {
  alarm_name          = "investigations-failed-${local.sfx}"
  alarm_description   = "Investigation turns failing (agent errors or timeouts)"
  namespace           = "InvestigationAgent/${local.sfx}"
  metric_name         = "InvestigationsFailed"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "guardrail_blocks" {
  alarm_name          = "guardrail-blocks-${local.sfx}"
  alarm_description   = "Unusual number of blocked requests (possible misuse)"
  namespace           = "InvestigationAgent/${local.sfx}"
  metric_name         = "GuardrailBlocks"
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# ===================== CloudTrail: data events =====================
# Records who read transaction/account data, procedure documents and knowledge base retrievals.
# Management events are included; remove that selector if an organization trail already records them.
resource "aws_s3_bucket" "trail" {
  count  = var.enable_cloudtrail_data_events ? 1 : 0
  bucket = "cloudtrail-${var.environment}-${local.account_id}-${var.client}"
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count                   = var.enable_cloudtrail_data_events ? 1 : 0
  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count  = var.enable_cloudtrail_data_events ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

locals {
  trail_name = "data-events-trail-${local.sfx}"
  trail_arn  = "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${local.trail_name}"
}

data "aws_iam_policy_document" "trail_bucket" {
  count = var.enable_cloudtrail_data_events ? 1 : 0

  statement {
    sid       = "AclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail[0].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
  statement {
    sid       = "Write"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail[0].arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.trail[0].arn, "${aws_s3_bucket.trail[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  count      = var.enable_cloudtrail_data_events ? 1 : 0
  bucket     = aws_s3_bucket.trail[0].id
  policy     = data.aws_iam_policy_document.trail_bucket[0].json
  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_cloudtrail" "data_events" {
  count                         = var.enable_cloudtrail_data_events ? 1 : 0
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.trail[0].id
  kms_key_id                    = aws_kms_key.main.arn
  enable_log_file_validation    = true
  include_global_service_events = false

  advanced_event_selector {
    name = "Management events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  advanced_event_selector {
    name = "Transaction and account table access"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::DynamoDB::Table"]
    }
    field_selector {
      field  = "resources.ARN"
      equals = [aws_dynamodb_table.transactions.arn, aws_dynamodb_table.accounts.arn]
    }
  }

  advanced_event_selector {
    name = "Procedure document access"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = ["${aws_s3_bucket.docs.arn}/"]
    }
  }

  advanced_event_selector {
    name = "Knowledge base retrievals"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::Bedrock::KnowledgeBase"]
    }
  }

  depends_on = [aws_s3_bucket_policy.trail]
}

# ===================== Bedrock model invocation logging (account-wide; off by default) =====================
resource "aws_cloudwatch_log_group" "bedrock_invocations" {
  count             = var.enable_model_invocation_logging ? 1 : 0
  name              = "/aws/bedrock/model-invocations-${local.sfx}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

data "aws_iam_policy_document" "bedrock_logging_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "bedrock_logging" {
  count              = var.enable_model_invocation_logging ? 1 : 0
  name               = "bedrock-logging-role-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.bedrock_logging_trust.json
}

resource "aws_iam_role_policy" "bedrock_logging" {
  count = var.enable_model_invocation_logging ? 1 : 0
  name  = "bedrock-logging-policy-${local.sfx}"
  role  = aws_iam_role.bedrock_logging[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.bedrock_invocations[0].arn}:*"
    }]
  })
}

resource "aws_bedrock_model_invocation_logging_configuration" "main" {
  count = var.enable_model_invocation_logging ? 1 : 0

  logging_config {
    text_data_delivery_enabled      = true
    embedding_data_delivery_enabled = false
    image_data_delivery_enabled     = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock_invocations[0].name
      role_arn       = aws_iam_role.bedrock_logging[0].arn
    }
  }

  depends_on = [aws_iam_role_policy.bedrock_logging]
}
