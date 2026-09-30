# ===================== AgentCore Memory =====================
# Short-term memory of each investigation's conversation, so staff can ask follow-up questions
# ("now check the other account") without repeating context. Keyed by investigation (session)
# and by the staff member (actor). Events expire automatically.

resource "aws_bedrockagentcore_memory" "investigations" {
  name                  = "investigation_memory_${local.sfx_}"
  description           = "Conversation context for multi-turn Moniva transaction investigations"
  event_expiry_duration = var.memory_event_expiry_days
}
