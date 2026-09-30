# ===================== Staff sign-in =====================
resource "aws_cognito_user_pool" "staff" {
  name                     = "staff-${local.sfx}"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "ON"
  deletion_protection      = var.environment == "prod" ? "ACTIVE" : "INACTIVE"

  software_token_mfa_configuration {
    enabled = true
  }

  # Accounts are created by administrators only; no self sign-up.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_group" "staff" {
  for_each     = local.staff_groups
  name         = each.value
  user_pool_id = aws_cognito_user_pool.staff.id
  description = {
    investigators = "Operations staff who run transaction investigations"
    supervisors   = "Can view all investigations and authorize consequential actions outside the agent"
    admins        = "Full access"
  }[each.key]
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "web-client-${local.sfx}"
  user_pool_id = aws_cognito_user_pool.staff.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = var.cognito_callback_urls
  logout_urls                          = var.cognito_logout_urls

  # Password sign-in from the CLI is allowed in dev only, for testing.
  explicit_auth_flows = concat(
    ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"],
    var.environment == "dev" ? ["ALLOW_USER_PASSWORD_AUTH"] : []
  )

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
  access_token_validity         = 1
  id_token_validity             = 1
  refresh_token_validity        = 12
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "hours"
  }
}

resource "aws_cognito_user_pool_domain" "staff" {
  domain       = "auth-${var.environment}-${local.account_id}-${var.client}"
  user_pool_id = aws_cognito_user_pool.staff.id
}
