# ===================== Knowledge base sync =====================
# Uploading or removing a procedure under approved/ starts a sync; an hourly schedule is the backstop.

resource "aws_iam_role" "ingestion" {
  name               = "kb-ingestion-role-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "ingestion" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ingestion.arn}:*"]
  }
  statement {
    sid       = "KnowledgeBaseSync"
    actions   = ["bedrock:StartIngestionJob", "bedrock:ListIngestionJobs", "bedrock:GetIngestionJob"]
    resources = [aws_bedrockagent_knowledge_base.procedures.arn]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "ingestion" {
  name   = "kb-ingestion-policy-${local.sfx}"
  role   = aws_iam_role.ingestion.id
  policy = data.aws_iam_policy_document.ingestion.json
}

data "archive_file" "ingestion" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/ingestion"
  output_path = "${path.module}/build/ingestion.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "ingestion" {
  function_name    = "kb-ingestion-${local.sfx}"
  description      = "Starts procedures knowledge base syncs"
  role             = aws_iam_role.ingestion.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.ingestion.output_path
  source_code_hash = data.archive_file.ingestion.output_base64sha256
  timeout          = 60
  memory_size      = 256
  kms_key_arn      = aws_kms_key.main.arn

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.procedures.id
      DATA_SOURCE_ID    = aws_bedrockagent_data_source.procedures.data_source_id
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.ingestion.name
  }

  depends_on = [aws_iam_role_policy.ingestion]
}

resource "aws_lambda_permission" "ingestion_s3" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.ingestion.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.docs.arn
  source_account = local.account_id
}

resource "aws_s3_bucket_notification" "docs" {
  bucket = aws_s3_bucket.docs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingestion.arn
    events              = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_prefix       = local.docs_prefix
  }

  depends_on = [aws_lambda_permission.ingestion_s3]
}

resource "aws_cloudwatch_event_rule" "kb_sync" {
  name                = "kb-sync-schedule-${local.sfx}"
  description         = "Backstop sync of the Moniva procedures knowledge base"
  schedule_expression = var.kb_sync_schedule
}

resource "aws_cloudwatch_event_target" "kb_sync" {
  rule = aws_cloudwatch_event_rule.kb_sync.name
  arn  = aws_lambda_function.ingestion.arn
}

resource "aws_lambda_permission" "ingestion_schedule" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.kb_sync.arn
}
