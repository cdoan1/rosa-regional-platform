# Stage 1: Build stage - Download Terraform
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS terraform-installer

ARG TERRAFORM_VERSION=1.14.3

USER root

# Download Terraform directly from HashiCorp
RUN microdnf install -y tar gzip findutils && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; fi && \
    curl -fsSL https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip -o /tmp/terraform.zip && \
    microdnf install -y unzip && \
    unzip /tmp/terraform.zip -d /usr/bin && \
    chmod +x /usr/bin/terraform && \
    rm /tmp/terraform.zip && \
    microdnf clean all

# Stage 2: Runtime stage
FROM registry.access.redhat.com/ubi9/go-toolset:latest

# Switch to root temporarily to copy Terraform and set up directories
USER root

# Copy Terraform binary from build stage
COPY --from=terraform-installer /usr/bin/terraform /usr/bin/terraform

ENV TF_PLUGIN_CACHE_DIR="/opt/app-root/.terraform-cache"

RUN mkdir -p ${TF_PLUGIN_CACHE_DIR} && \
    chown -R 1001:0 ${TF_PLUGIN_CACHE_DIR} && \
    chmod -R g+rwX ${TF_PLUGIN_CACHE_DIR}

WORKDIR /workspace

COPY --chown=1001:0 . .

# Switch back to non-root user (default go-toolset user)
USER 1001

CMD ["/bin/bash"]
