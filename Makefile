.PHONY: help terraform-fmt terraform-upgrade provision-management provision-regional apply-infra-management apply-infra-regional provision-maestro-agent-iot-regional provision-maestro-agent-iot-management cleanup-maestro-agent-iot destroy-management destroy-regional output-regional output-management test test-e2e

# Default target
help:
	@echo "🚀 Cluster Provisioning / Deprovisioning:"
	@echo "  provision-management             - Provision management cluster environment (infra & argocd bootstrap)"
	@echo "  provision-regional               - Provision regional cluster environment (infra & argocd bootstrap)"
	@echo "  destroy-management               - Destroy management cluster environment"
	@echo "  destroy-regional                 - Destroy regional cluster environment"
	@echo ""
	@echo "🔧 Infrastructure Only:"
	@echo "  apply-infra-management                - Apply only management cluster infrastructure"
	@echo "  apply-infra-regional                  - Apply only regional cluster infrastructure"
	@echo ""
	@echo "📡 Maestro Agent IoT Provisioning (2-step process):"
	@echo "  provision-maestro-agent-iot-regional   - Step 1: Provision IoT in regional account"
	@echo "  provision-maestro-agent-iot-management - Step 2: Create secret in management account"
	@echo "  cleanup-maestro-agent-iot              - Cleanup IoT resources before re-provisioning"
	@echo ""
	@echo "🛠️  Terraform Utilities:"
	@echo "  terraform-fmt                    - Format all Terraform files"
	@echo "  terraform-upgrade                - Upgrade provider versions"
	@echo "  output-regional                  - Display regional cluster terraform outputs"
	@echo "  output-management                - Display management cluster terraform outputs"
	@echo ""
	@echo "🧪 Testing:"
	@echo "  test                             - Run tests"
	@echo "  test-e2e                         - Run end-to-end tests"
	@echo ""
	@echo "  help                             - Show this help message"

# Discover all directories containing Terraform files (excluding .terraform subdirectories)
TERRAFORM_DIRS := $(shell find ./terraform -name "*.tf" -type f -not -path "*/.terraform/*" | xargs dirname | sort -u)

# Format all Terraform files
terraform-fmt:
	@echo "🔧 Formatting Terraform files..."
	@for dir in $(TERRAFORM_DIRS); do \
		echo "   Formatting $$dir"; \
		terraform -chdir=$$dir fmt -recursive; \
	done
	@echo "✅ Terraform formatting complete"

# Upgrade provider versions in all Terraform configurations
terraform-upgrade:
	@echo "🔧 Upgrading Terraform provider versions..."
	@for dir in $(TERRAFORM_DIRS); do \
		echo "   Upgrading $$dir"; \
		terraform -chdir=$$dir init -upgrade -backend=false; \
	done
	@echo "✅ Terraform upgrade complete"

# =============================================================================
# Cluster Provisioning/Deprovisioning Targets
# =============================================================================

# Provision complete management cluster (infrastructure + ArgoCD)
provision-management:
	@echo "🚀 Provisioning management cluster..."
	@echo ""
	@scripts/validate-argocd-config.sh management-cluster
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/management-cluster"
	@echo "🔑 AWS Caller Identity:" && aws sts get-caller-identity
	@echo ""
	@read -p "Do you want to proceed? [y/N]: " confirm && \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
			echo "❌ Operation cancelled."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/management-cluster && \
		terraform init && terraform apply
	@echo ""
	@echo "Bootstrapping argocd..."
	scripts/bootstrap-argocd.sh management-cluster

# Provision complete regional cluster (infrastructure + ArgoCD)
provision-regional:
	@echo "🚀 Provisioning regional cluster..."
	@echo ""
	@scripts/validate-argocd-config.sh regional-cluster
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/regional-cluster"
	@echo "🔑 AWS Caller Identity:" && aws sts get-caller-identity
	@echo ""
	@read -p "Do you want to proceed? [y/N]: " confirm && \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
			echo "❌ Operation cancelled."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/regional-cluster && \
		terraform init && terraform apply
	@echo ""
	@echo "Bootstrapping argocd..."
	@scripts/bootstrap-argocd.sh regional-cluster

# Destroy management cluster and all resources
destroy-management:
	@echo "🗑️  Destroying management cluster..."
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/management-cluster"
	@echo "🔑 AWS Caller Identity:" && aws sts get-caller-identity
	@echo ""
	@read -p "Type 'destroy' to confirm deletion: " confirm && \
		if [ "$$confirm" != "destroy" ]; then \
			echo "❌ Operation cancelled. You must type exactly 'destroy' to proceed."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/management-cluster && \
		terraform init && terraform destroy

# Destroy regional cluster and all resources
destroy-regional:
	@echo "🗑️  Destroying regional cluster..."
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/regional-cluster"
	@echo "🔑 AWS Caller Identity:" && aws sts get-caller-identity
	@echo ""
	@read -p "Type 'destroy' to confirm deletion: " confirm && \
		if [ "$$confirm" != "destroy" ]; then \
			echo "❌ Operation cancelled. You must type exactly 'destroy' to proceed."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/regional-cluster && \
		terraform init && terraform destroy

# =============================================================================
# Infrastructure Maintenance Targets
# =============================================================================

# Infrastructure-only deployment
apply-infra-management:
	@echo "🏗️  Applying management cluster infrastructure..."
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/management-cluster"
	@echo ""
	@read -p "Do you want to proceed? [y/N]: " confirm && \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
			echo "❌ Operation cancelled."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/management-cluster && \
		terraform init && terraform apply

apply-infra-regional:
	@echo "🏗️  Applying regional cluster infrastructure..."
	@echo ""
	@echo "📍 Terraform Directory: terraform/config/regional-cluster"
	@echo ""
	@read -p "Do you want to proceed? [y/N]: " confirm && \
		if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
			echo "❌ Operation cancelled."; \
			exit 1; \
		fi
	@echo ""
	@cd terraform/config/regional-cluster && \
		terraform init && terraform apply

# Provision IoT resources in regional account (Step 1)
provision-maestro-agent-iot-regional:
	@if [ -z "$(MGMT_TFVARS)" ]; then \
		echo "❌ Error: MGMT_TFVARS not set"; \
		echo ""; \
		echo "Usage: make provision-maestro-agent-iot-regional MGMT_TFVARS=<path-to-tfvars>"; \
		echo ""; \
		echo "Example:"; \
		echo "  make provision-maestro-agent-iot-regional MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars"; \
		echo ""; \
		echo "⚠️  Ensure you are authenticated with REGIONAL AWS account credentials!"; \
		exit 1; \
	fi
	@./scripts/provision-maestro-agent-iot-regional.sh $(MGMT_TFVARS)

# Create secret in management account (Step 2)
provision-maestro-agent-iot-management:
	@if [ -z "$(MGMT_TFVARS)" ]; then \
		echo "❌ Error: MGMT_TFVARS not set"; \
		echo ""; \
		echo "Usage: make provision-maestro-agent-iot-management MGMT_TFVARS=<path-to-tfvars>"; \
		echo ""; \
		echo "Example:"; \
		echo "  make provision-maestro-agent-iot-management MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars"; \
		echo ""; \
		echo "⚠️  Ensure you are authenticated with MANAGEMENT AWS account credentials!"; \
		exit 1; \
	fi
	@./scripts/provision-maestro-agent-iot-management.sh $(MGMT_TFVARS)

# Cleanup IoT resources (run before re-provisioning)
cleanup-maestro-agent-iot:
	@if [ -z "$(MGMT_TFVARS)" ]; then \
		echo "❌ Error: MGMT_TFVARS not set"; \
		echo ""; \
		echo "Usage: make cleanup-maestro-agent-iot MGMT_TFVARS=<path-to-tfvars>"; \
		echo ""; \
		echo "Example:"; \
		echo "  make cleanup-maestro-agent-iot MGMT_TFVARS=terraform/config/management-cluster/terraform.tfvars"; \
		echo ""; \
		echo "⚠️  Run this in the same AWS account where IoT resources were created"; \
		exit 1; \
	fi
	@./scripts/cleanup-maestro-agent-iot.sh $(MGMT_TFVARS)

# =============================================================================
# Terraform Output Targets
# =============================================================================

# Display regional cluster terraform outputs
output-regional:
	@echo "📊 Regional Cluster Terraform Outputs"
	@echo "📍 Terraform Directory: terraform/config/regional-cluster"
	@echo ""
	@cd terraform/config/regional-cluster && terraform output

# Display management cluster terraform outputs
output-management:
	@echo "📊 Management Cluster Terraform Outputs"
	@echo "📍 Terraform Directory: terraform/config/management-cluster"
	@echo ""
	@cd terraform/config/management-cluster && terraform output

# =============================================================================
# Testing Targets
# =============================================================================

# Run tests
test:
	@echo "🧪 Running tests..."
	@./test/execute-prow-job.sh
	@echo "✅ Tests complete"

# Run end-to-end tests
test-e2e:
	@echo "🧪 Running end-to-end tests..."
	@echo "✅ End-to-end tests complete"

