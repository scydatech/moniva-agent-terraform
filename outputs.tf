output "api_endpoint" {
  description = "Investigations API base URL"
  value       = aws_apigatewayv2_stage.main.invoke_url
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.staff.id
}

output "cognito_web_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cognito_hosted_ui_domain" {
  value = "https://${aws_cognito_user_pool_domain.staff.domain}.auth.${local.region}.amazoncognito.com"
}

output "staff_groups" {
  value = local.staff_groups
}

output "procedures_bucket" {
  description = "Upload approved procedures under approved/"
  value       = aws_s3_bucket.docs.bucket
}

output "knowledge_base_id" {
  value = aws_bedrockagent_knowledge_base.procedures.id
}

output "data_source_id" {
  value = aws_bedrockagent_data_source.procedures.data_source_id
}

output "transactions_table" {
  value = aws_dynamodb_table.transactions.name
}

output "accounts_table" {
  value = aws_dynamodb_table.accounts.name
}

output "investigations_table" {
  value = aws_dynamodb_table.investigations.name
}

output "agent_runtime_arn" {
  value = aws_bedrockagentcore_agent_runtime.investigation.agent_runtime_arn
}

output "gateway_url" {
  value = aws_bedrockagentcore_gateway.tools.gateway_url
}

output "memory_id" {
  value = aws_bedrockagentcore_memory.investigations.id
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}
