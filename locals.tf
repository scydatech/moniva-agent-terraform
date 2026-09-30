data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.aws_region
  partition  = data.aws_partition.current.partition

  # Naming: <service>-<env>-<client>, e.g. investigations-api-dev-moniva.
  # AgentCore runtime and memory names only allow letters, digits and underscores.
  sfx  = "${var.environment}-${var.client}"
  sfx_ = "${var.environment}_${var.client}"

  common_tags = {
    Client      = var.client
    Environment = var.environment
    Workload    = "transaction-investigation-agent"
    ManagedBy   = "terraform"
  }

  inference_profile_arn = "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:inference-profile/${var.generation_model_id}"
  generation_model_arns = [
    local.inference_profile_arn,
    "arn:${local.partition}:bedrock:*::foundation-model/${var.generation_foundation_model_id}",
  ]
  embedding_model_arn = "arn:${local.partition}:bedrock:${local.region}::foundation-model/${var.embedding_model_id}"

  docs_prefix = "approved/"

  staff_groups = {
    investigators = "investigators-${local.sfx}"
    supervisors   = "supervisors-${local.sfx}"
    admins        = "admins-${local.sfx}"
  }
}
