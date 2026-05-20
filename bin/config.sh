#!/usr/bin/env bash
# =============================================================================
# config.sh — Load configuration for k8-lib tools
#
# Primary mode: reads from k8-util-config.yaml via config-resolver.sh
# Legacy mode:  falls back to config.env if no YAML config found
#
# All values can also be set as environment variables before sourcing.
# =============================================================================

_K8_LIB_DIR="${K8_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Source the unified config resolver
source "$_K8_LIB_DIR/bin/config-resolver.sh"

# Resolve the config file (YAML or legacy)
_resolve_config

if (( _K8_LEGACY_MODE )); then
  # --- Legacy: load from config.env (deprecated) ---
  if [[ -f "${INFRA_ROOT:-.}/config.env" ]]; then
    source "${INFRA_ROOT:-.}/config.env"
  elif [[ -f "$_K8_LIB_DIR/config.env" ]]; then
    source "$_K8_LIB_DIR/config.env"
  fi

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
  K8_HELM_OCI_REGISTRY="${K8_HELM_OCI_REGISTRY:-}"
  K8_HELM_REGISTRY_HOST="${K8_HELM_REGISTRY_HOST:-ghcr.io}"
  K8_HELM_REGISTRY_USER="${K8_HELM_REGISTRY_USER:-}"
  K8_DIFF_VIEWER="${K8_DIFF_VIEWER:-code}"
  K8_ADMIN_EMAIL="${K8_ADMIN_EMAIL:-admin@example.com}"
else
  # --- YAML mode: load from k8-util-config.yaml ---
  _load_k8_vars
fi
