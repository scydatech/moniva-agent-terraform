variable "aws_region" {
  description = "Region for the workload. Must support Bedrock AgentCore, Claude Sonnet 4.5, Titan Embeddings V2 and S3 Vectors."
  type        = string
  default     = "eu-central-1"
}

variable "client" {
  description = "Client identifier, used as the suffix on every resource name."
  type        = string
  default     = "moniva"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
  default     = "dev"
}

# ---------- Models ----------
variable "generation_model_id" {
  description = "Claude Sonnet 4.5 inference profile used by the investigation agent."
  type        = string
  default     = "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "generation_foundation_model_id" {
  description = "Foundation model behind the inference profile (used for IAM)."
  type        = string
  default     = "anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "embedding_model_id" {
  description = "Embedding model for the procedures knowledge base."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "embedding_dimensions" {
  description = "Embedding vector size (256, 512 or 1024 for Titan V2)."
  type        = number
  default     = 1024
}

# ---------- Agent behaviour ----------
variable "agent_max_steps" {
  description = "Maximum model/tool rounds per investigation turn."
  type        = number
  default     = 10
}

variable "agent_max_output_tokens" {
  description = "Maximum tokens per model response."
  type        = number
  default     = 3000
}

variable "kb_number_of_results" {
  description = "Procedure passages retrieved per search."
  type        = number
  default     = 5
}

variable "memory_event_expiry_days" {
  description = "Days AgentCore Memory keeps investigation conversation events (7-365)."
  type        = number
  default     = 30
}

variable "investigation_retention_days" {
  description = "Days investigation records are kept in DynamoDB before automatic expiry."
  type        = number
  default     = 365
}

# ---------- Access ----------
variable "cognito_callback_urls" {
  description = "Sign-in return URLs for a staff web interface."
  type        = list(string)
  default     = ["http://localhost:3000/"]
}

variable "cognito_logout_urls" {
  description = "Sign-out return URLs for a staff web interface."
  type        = list(string)
  default     = ["http://localhost:3000/"]
}

variable "allowed_cors_origins" {
  description = "Browser origins allowed to call the API."
  type        = list(string)
  default     = ["http://localhost:3000"]
}

# ---------- Operations ----------
variable "alarm_email" {
  description = "Email address for alarm notifications. Leave empty to skip."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 90
}

variable "kb_sync_schedule" {
  description = "Backstop schedule for knowledge base syncs."
  type        = string
  default     = "rate(1 hour)"
}

variable "enable_cloudtrail_data_events" {
  description = "Create a trail recording data events (transaction/account table reads, procedure documents, knowledge base retrievals). Management events are included unless an organization trail already covers them."
  type        = bool
  default     = true
}

variable "enable_model_invocation_logging" {
  description = "Bedrock model invocation logging. ACCOUNT-WIDE setting: enable it in only one stack per account and region."
  type        = bool
  default     = false
}
