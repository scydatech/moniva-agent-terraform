# ===================== Transaction tools (Lambda behind AgentCore Gateway) =====================
# One Lambda implements the read-only investigation tools. The gateway tells it which tool was
# called; the Lambda can only read the transaction and account tables.

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tools" {
  name               = "transaction-tools-role-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "tools" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.tools.arn}:*"]
  }
  statement {
    sid     = "ReadTransactionData"
    actions = ["dynamodb:GetItem", "dynamodb:Query"]
    resources = [
      aws_dynamodb_table.transactions.arn,
      "${aws_dynamodb_table.transactions.arn}/index/*",
      aws_dynamodb_table.accounts.arn,
    ]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "tools" {
  name   = "transaction-tools-policy-${local.sfx}"
  role   = aws_iam_role.tools.id
  policy = data.aws_iam_policy_document.tools.json
}

data "archive_file" "tools" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/tools"
  output_path = "${path.module}/build/tools.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "tools" {
  function_name    = "transaction-tools-${local.sfx}"
  description      = "Read-only transaction and account lookups for the investigation agent"
  role             = aws_iam_role.tools.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.tools.output_path
  source_code_hash = data.archive_file.tools.output_base64sha256
  timeout          = 30
  memory_size      = 512
  kms_key_arn      = aws_kms_key.main.arn

  environment {
    variables = {
      TRANSACTIONS_TABLE = aws_dynamodb_table.transactions.name
      ACCOUNTS_TABLE     = aws_dynamodb_table.accounts.name
      ACCOUNT_TIME_INDEX = "account-time-index"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.tools.name
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy.tools]
}
