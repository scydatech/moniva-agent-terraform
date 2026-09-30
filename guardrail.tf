# Two guardrails, applied by the agent with ApplyGuardrail:
#  - input:  checks the staff request before the agent starts (decision/action requests, prompt attacks, harmful content)
#  - output: checks the final case summary (harmful content, sensitive data masking)
# Keeping the "account actions" topic on input only stops it firing on correct summaries that
# merely recommend an action for staff to authorize.

resource "aws_bedrock_guardrail" "input" {
  name                      = "input-guardrail-${local.sfx}"
  description               = "Moniva investigation agent: checks staff requests"
  kms_key_arn               = aws_kms_key.main.arn
  blocked_input_messaging   = "The investigation agent can't perform or approve account or payment actions. It gathers evidence and prepares a case summary; authorized staff take any action."
  blocked_outputs_messaging = "The investigation agent can't perform or approve account or payment actions."


  content_policy_config {
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "INSULTS"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
  }
}

resource "aws_bedrock_guardrail_version" "input" {
  guardrail_arn = aws_bedrock_guardrail.input.guardrail_arn
  description   = "Managed by Terraform"
  skip_destroy  = true

  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.input]
  }
}

resource "aws_bedrock_guardrail" "output" {
  name                      = "output-guardrail-${local.sfx}"
  description               = "Moniva investigation agent: checks case summaries"
  kms_key_arn               = aws_kms_key.main.arn
  blocked_input_messaging   = "This content can't be processed."
  blocked_outputs_messaging = "The case summary couldn't be returned because it conflicts with Moniva's AI usage policy. Review the evidence directly or contact your supervisor."

  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "INSULTS"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
  }

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_CVV"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "PIN"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "PASSWORD"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "AWS_ACCESS_KEY"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "AWS_SECRET_KEY"
      action = "ANONYMIZE"
    }
    regexes_config {
      name        = "NG-BVN"
      description = "Nigerian Bank Verification Number when labelled as BVN"
      pattern     = "(?i)\\bBVN[:#\\s-]*\\d{11}\\b"
      action      = "ANONYMIZE"
    }
    regexes_config {
      name        = "NG-NIN"
      description = "Nigerian National Identification Number when labelled as NIN"
      pattern     = "(?i)\\bNIN[:#\\s-]*\\d{11}\\b"
      action      = "ANONYMIZE"
    }
  }
}

resource "aws_bedrock_guardrail_version" "output" {
  guardrail_arn = aws_bedrock_guardrail.output.guardrail_arn
  description   = "Managed by Terraform"
  skip_destroy  = true

  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.output]
  }
}
