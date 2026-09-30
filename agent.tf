# ===================== Investigation agent on AgentCore Runtime =====================
# The agent code in ./agent is packaged with its Python dependencies for Linux arm64,
# uploaded to S3, and deployed with AgentCore Runtime's direct code deployment (no Docker needed).

locals {
  agent_dir   = "${path.module}/agent"
  agent_files = sort(concat(tolist(fileset(local.agent_dir, "*.py")), ["requirements.txt"]))
  agent_hash  = sha256(join("", [for f in local.agent_files : filesha256("${local.agent_dir}/${f}")]))
  agent_zip   = "${path.module}/build/agent.zip"
  agent_name  = "investigation_agent_${local.sfx_}"
}

# Rebuild the package whenever the agent code or requirements change.
resource "terraform_data" "agent_package" {
  triggers_replace = [local.agent_hash]

  provisioner "local-exec" {
    command = "bash '${path.module}/scripts/build_agent.sh' '${local.agent_dir}' '${path.module}/build'"
  }
}

resource "aws_s3_object" "agent_package" {
  bucket      = aws_s3_bucket.agent_code.id
  key         = "investigation-agent/agent.zip"
  source      = local.agent_zip
  source_hash = local.agent_hash

  depends_on = [terraform_data.agent_package]
}

# ---------- Runtime execution role ----------
resource "aws_iam_role" "agent" {
  name               = "investigation-agent-role-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.agentcore_trust.json
}

data "aws_iam_policy_document" "agent" {
  statement {
    sid       = "ReadAgentPackage"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.agent_code.arn}/investigation-agent/*"]
  }

  statement {
    sid       = "InvokeClaude"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = local.generation_model_arns
  }

  statement {
    sid       = "SearchProcedures"
    actions   = ["bedrock:Retrieve"]
    resources = [aws_bedrockagent_knowledge_base.procedures.arn]
  }

  statement {
    sid       = "ApplyGuardrails"
    actions   = ["bedrock:ApplyGuardrail"]
    resources = [aws_bedrock_guardrail.input.guardrail_arn, aws_bedrock_guardrail.output.guardrail_arn]
  }

  statement {
    sid       = "GuardrailKmsKey"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }

  statement {
    sid       = "UseToolsGateway"
    actions   = ["bedrock-agentcore:InvokeGateway"]
    resources = [aws_bedrockagentcore_gateway.tools.gateway_arn]
  }

  statement {
    sid       = "InvestigationMemory"
    actions   = ["bedrock-agentcore:CreateEvent", "bedrock-agentcore:ListEvents", "bedrock-agentcore:GetEvent"]
    resources = [aws_bedrockagentcore_memory.investigations.arn]
  }

  statement {
    sid = "WorkloadIdentity"
    actions = [
      "bedrock-agentcore:GetWorkloadAccessToken",
      "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
      "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
    ]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default",
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default/workload-identity/${local.agent_name}-*",
    ]
  }

  statement {
    sid       = "RuntimeLogs"
    actions   = ["logs:DescribeLogStreams", "logs:CreateLogGroup"]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"]
  }
  statement {
    sid       = "DescribeLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
  }
  statement {
    sid       = "RuntimeLogEvents"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }
  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["bedrock-agentcore"]
    }
  }
}

resource "aws_iam_role_policy" "agent" {
  name   = "investigation-agent-policy-${local.sfx}"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent.json
}

resource "time_sleep" "agent_iam" {
  depends_on      = [aws_iam_role_policy.agent]
  create_duration = "20s"
}

# ---------- Runtime ----------
resource "aws_bedrockagentcore_agent_runtime" "investigation" {
  agent_runtime_name = local.agent_name
  description        = "Moniva transaction investigation agent (Claude Sonnet 4.5)"
  role_arn           = aws_iam_role.agent.arn

  agent_runtime_artifact {
    code_configuration {
      entry_point = ["main.py"]
      runtime     = "PYTHON_3_13"
      code {
        s3 {
          bucket     = aws_s3_bucket.agent_code.id
          prefix     = aws_s3_object.agent_package.key
          version_id = aws_s3_object.agent_package.version_id # new package version => runtime update
        }
      }
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = 900
    max_lifetime                 = 3600
  }

  environment_variables = {
    MONIVA_REGION            = local.region
    MODEL_ID                 = var.generation_model_id
    GATEWAY_URL              = aws_bedrockagentcore_gateway.tools.gateway_url
    MEMORY_ID                = aws_bedrockagentcore_memory.investigations.id
    KNOWLEDGE_BASE_ID        = aws_bedrockagent_knowledge_base.procedures.id
    KB_NUMBER_OF_RESULTS     = tostring(var.kb_number_of_results)
    INPUT_GUARDRAIL_ID       = aws_bedrock_guardrail.input.guardrail_id
    INPUT_GUARDRAIL_VERSION  = aws_bedrock_guardrail_version.input.version
    OUTPUT_GUARDRAIL_ID      = aws_bedrock_guardrail.output.guardrail_id
    OUTPUT_GUARDRAIL_VERSION = aws_bedrock_guardrail_version.output.version
    MAX_STEPS                = tostring(var.agent_max_steps)
    MAX_OUTPUT_TOKENS        = tostring(var.agent_max_output_tokens)
  }

  depends_on = [time_sleep.agent_iam]
}
