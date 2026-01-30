# =============================================================================
# Maestro Agent Module - Main Configuration
# =============================================================================

# Get current AWS account and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Secret names for Maestro Agent
locals {
  agent_cert_secret_name   = "maestro/agent-cert"
  agent_config_secret_name = "maestro/agent-config"

  common_tags = merge(
    var.tags,
    {
      Component         = "maestro-agent"
      ManagementCluster = var.cluster_id
      ManagedBy         = "terraform"
    }
  )
}

# Reference existing secrets (created by provision-maestro-agent-iot-management.sh)
data "aws_secretsmanager_secret" "maestro_agent_cert" {
  name = local.agent_cert_secret_name
}

data "aws_secretsmanager_secret" "maestro_agent_config" {
  name = local.agent_config_secret_name
}
