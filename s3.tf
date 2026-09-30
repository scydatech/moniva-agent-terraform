# ---------- Approved operational procedures (knowledge base source) ----------
resource "aws_s3_bucket" "docs" {
  bucket = "procedures-${var.environment}-${local.account_id}-${var.client}"
}

resource "aws_s3_bucket_ownership_controls" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket                  = aws_s3_bucket.docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "docs" {
  bucket = aws_s3_bucket.docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

# ---------- Agent code packages (read by AgentCore Runtime) ----------
# SSE-S3 rather than the CMK: AgentCore reads the package with the deploying identity and the runtime role.
resource "aws_s3_bucket" "agent_code" {
  bucket        = "agent-code-${var.environment}-${local.account_id}-${var.client}"
  force_destroy = true # build artifacts only
}

resource "aws_s3_bucket_ownership_controls" "agent_code" {
  bucket = aws_s3_bucket.agent_code.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "agent_code" {
  bucket                  = aws_s3_bucket.agent_code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "agent_code" {
  bucket = aws_s3_bucket.agent_code.id
  versioning_configuration {
    status = "Enabled" # each upload gets a version ID, which triggers a runtime update
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "agent_code" {
  bucket = aws_s3_bucket.agent_code.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "agent_code" {
  bucket = aws_s3_bucket.agent_code.id
  rule {
    id     = "expire-old-packages"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ---------- TLS-only policies ----------
data "aws_iam_policy_document" "tls_only" {
  for_each = {
    docs       = aws_s3_bucket.docs.arn
    agent_code = aws_s3_bucket.agent_code.arn
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value, "${each.value}/*"]
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

resource "aws_s3_bucket_policy" "docs" {
  bucket     = aws_s3_bucket.docs.id
  policy     = data.aws_iam_policy_document.tls_only["docs"].json
  depends_on = [aws_s3_bucket_public_access_block.docs]
}

resource "aws_s3_bucket_policy" "agent_code" {
  bucket     = aws_s3_bucket.agent_code.id
  policy     = data.aws_iam_policy_document.tls_only["agent_code"].json
  depends_on = [aws_s3_bucket_public_access_block.agent_code]
}
