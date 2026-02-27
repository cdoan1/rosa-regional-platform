# =============================================================================
# HyperFleet Infrastructure Module - Local Variables
# =============================================================================

data "aws_region" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      ManagedBy = "terraform"
      Module    = "hyperfleet-infrastructure"
    }
  )
}
