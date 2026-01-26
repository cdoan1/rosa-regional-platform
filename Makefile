.PHONY: help terraform-fmt terraform-upgrade provision-management provision-regional apply-infra-management apply-infra-regional destroy-management destroy-regional extract-maestro-cert test test-e2e

# Default target
help:
	@echo "🚀 Cluster Provisioning / Deprovisioning:"
	@echo "  provision-management             - Provision management cluster environment (infra & argocd bootstrap)"
	@echo "  provision-regional               - Provision regional cluster environment (infra & argocd bootstrap)"
	@echo "  destroy-management               - Destroy management cluster environment"
	@echo "  destroy-regional                 - Destroy regional cluster environment"
	@echo ""
	@echo "🔧 Infrastructure Only:"
	@echo "  apply-infra-management       - Apply only management cluster infrastructure"
	@echo "  apply-infra-regional         - Apply only regional cluster infrastructure"
	@echo ""
	@echo "🛠️  Terraform Utilities:"
	@echo "  terraform-fmt                    - Format all Terraform files"
	@echo "  terraform-upgrade                - Upgrade provider versions"
	@echo ""
	@echo "🎺 Maestro Utilities:"
	@echo "  extract-maestro-cert             - Extract management-01 Maestro certificate to JSON file"
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
	scripts/bootstrap-argocd.sh management

# Provision complete regional cluster (infrastructure + ArgoCD)
provision-regional:
	@echo "🚀 Provisioning regional cluster..."
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
	@scripts/bootstrap-argocd.sh regional

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

# =============================================================================
# Maestro Utilities
# =============================================================================

# Extract Maestro agent certificate for management-01
extract-maestro-cert:
	@echo "📜 Extracting Maestro certificate for management-01..."
	@cd terraform/config/regional-cluster && \
		terraform output -json maestro_agent_certificates | jq '.["management-01"]' > ../../../management-01-maestro-cert.json
	@echo "✅ Certificate saved to management-01-maestro-cert.json"

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

