# =============================================================================
# Maestro Agent IoT Provisioning - Standalone Configuration
#
# This configuration wraps the maestro-agent-iot-provisioning module and
# provides a standalone entrypoint for pipeline-based IoT provisioning.
#
# Usage:
#   1. Generate terraform.tfvars with cluster-specific values
#   2. Run: terraform init && terraform apply
#   3. Extract certificate data: terraform output -json certificate_data
#   4. Transfer to management account Secrets Manager
# =============================================================================

# Configure AWS provider - region is automatically detected from AWS profile
provider "aws" {
  default_tags {
    tags = {
      app-code      = var.app_code
      service-phase = var.service_phase
      cost-center   = var.cost_center
    }
  }
}

# Call the maestro-agent-iot-provisioning module
module "maestro_agent_iot" {
  source = "../../modules/maestro-agent-iot-provisioning"

  management_cluster_id = var.management_cluster_id
  mqtt_topic_prefix     = var.mqtt_topic_prefix

  tags = merge(
    var.tags,
    {
      ProvisioningMethod = "pipeline"
      ManagedBy          = "terraform"
    }
  )
}
