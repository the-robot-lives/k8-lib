#!/usr/bin/env bash
# =============================================================================
# config.sh — Load configuration from config.env if present
#
# Search order:
#   1. $INFRA_ROOT/config.env   (project-level config)
#   2. k8-lib/config.env        (library-level config)
#
# All values can also be set as environment variables before sourcing.
# =============================================================================

_K8_LIB_DIR="${K8_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ -f "${INFRA_ROOT:-.}/config.env" ]]; then
  source "${INFRA_ROOT:-.}/config.env"
elif [[ -f "$_K8_LIB_DIR/config.env" ]]; then
  source "$_K8_LIB_DIR/config.env"
fi

# --- Defaults (environment variables override config.env) --------------------
K8_AWS_PROFILE="${K8_AWS_PROFILE:-terraformer}"
K8_AWS_ACCOUNT_ID="${K8_AWS_ACCOUNT_ID:-}"
K8_AWS_REGION="${K8_AWS_REGION:-us-east-1}"
K8_DOCKER_REGISTRY="${K8_DOCKER_REGISTRY:-}"
K8_NAMESPACE="${K8_NAMESPACE:-default}"
K8_STAGING_NAMESPACE="${K8_STAGING_NAMESPACE:-staging}"
K8_INFRA_NAMESPACE="${K8_INFRA_NAMESPACE:-infra}"
K8_INFISICAL_HOST="${K8_INFISICAL_HOST:-}"
K8_INFISICAL_PROJECT_ID="${K8_INFISICAL_PROJECT_ID:-}"
K8_INFISICAL_CLIENT_ID="${K8_INFISICAL_CLIENT_ID:-}"
K8_INFISICAL_CLIENT_SECRET="${K8_INFISICAL_CLIENT_SECRET:-}"
K8_TF_DIR="${K8_TF_DIR:-}"
K8_TF_STATE_BUCKET="${K8_TF_STATE_BUCKET:-}"
K8_TF_KMS_ALIAS="${K8_TF_KMS_ALIAS:-}"
K8_TF_LOCK_TABLE="${K8_TF_LOCK_TABLE:-terraform-lock}"
K8_CREDENTIALS_LINK="${K8_CREDENTIALS_LINK:-}"
K8_DIFF_VIEWER="${K8_DIFF_VIEWER:-code}"
K8_ADMIN_EMAIL="${K8_ADMIN_EMAIL:-admin@example.com}"
