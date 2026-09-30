# Sample "data layer" for the tools. In production, replace these with Moniva's system of record
# (or keep the tools Lambda and point it at Moniva's transaction API).

resource "aws_dynamodb_table" "transactions" {
  name                        = "transactions-${local.sfx}"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "transaction_ref"
  deletion_protection_enabled = var.environment == "prod"

  attribute {
    name = "transaction_ref"
    type = "S"
  }
  attribute {
    name = "account_id"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "S"
  }

  global_secondary_index {
    name            = "account-time-index"
    hash_key        = "account_id"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "accounts" {
  name                        = "accounts-${local.sfx}"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "account_id"
  deletion_protection_enabled = var.environment == "prod"

  attribute {
    name = "account_id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

# Investigation cases created through the API: status, each turn's request, the agent's summary and evidence.
resource "aws_dynamodb_table" "investigations" {
  name                        = "investigations-${local.sfx}"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "investigation_id"
  deletion_protection_enabled = var.environment == "prod"

  attribute {
    name = "investigation_id"
    type = "S"
  }
  attribute {
    name = "owner_sub"
    type = "S"
  }
  attribute {
    name = "created_at"
    type = "S"
  }

  global_secondary_index {
    name            = "owner-created-index"
    hash_key        = "owner_sub"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}
