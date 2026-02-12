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
