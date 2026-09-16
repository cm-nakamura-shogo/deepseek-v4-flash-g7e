#!/usr/bin/env bash

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID to the 12-digit target AWS account ID.}"
ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME:-self-hosted-llm-poc}"
AWS_PAGER=""
ACTIVE_PROFILE=""
ECS_SERVICE_NAME=""
COMPUTE_POOL_NAME=""
ASG_NAME=""

export AWS_REGION AWS_PAGER

profile_names() {
  echo "nemotron-nano deepseek-v4-flash"
}

pool_names() {
  echo "g7e-1gpu g7e-2gpu"
}

profile_service_name() {
  case "$1" in
    nemotron-nano) echo "self-hosted-llm-poc-vllm" ;;
    deepseek-v4-flash) echo "self-hosted-llm-poc-deepseek-v4-flash" ;;
    *) return 1 ;;
  esac
}

profile_pool_name() {
  case "$1" in
    nemotron-nano) echo "g7e-1gpu" ;;
    deepseek-v4-flash) echo "g7e-2gpu" ;;
    *) return 1 ;;
  esac
}

pool_asg_name() {
  case "$1" in
    g7e-1gpu) echo "self-hosted-llm-poc-gpu" ;;
    g7e-2gpu) echo "self-hosted-llm-poc-g7e-2gpu" ;;
    *) return 1 ;;
  esac
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

require_aws_identity() {
  local actual_account_id

  require_command aws
  actual_account_id="$(aws sts get-caller-identity --query Account --output text)"

  if [[ "${actual_account_id}" != "${AWS_ACCOUNT_ID}" ]]; then
    echo "Refusing to continue: authenticated account ${actual_account_id} does not match ${AWS_ACCOUNT_ID}." >&2
    exit 1
  fi
}

require_profile() {
  local profile="$1"

  if ! profile_service_name "${profile}" >/dev/null; then
    echo "Unknown profile: ${profile}" >&2
    echo "Available profiles: $(profile_names)" >&2
    exit 2
  fi
}

configure_profile() {
  local profile="$1"

  require_profile "${profile}"
  ACTIVE_PROFILE="${profile}"
  ECS_SERVICE_NAME="$(profile_service_name "${profile}")"
  COMPUTE_POOL_NAME="$(profile_pool_name "${profile}")"
  ASG_NAME="$(pool_asg_name "${COMPUTE_POOL_NAME}")"
}

show_base_context() {
  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  echo "AWS account: ${account_id} (verified)"
  echo "Region:      ${AWS_REGION}"
  echo "Cluster:     ${ECS_CLUSTER_NAME}"
}

show_profile_context() {
  echo "Profile:     ${ACTIVE_PROFILE}"
  echo "Service:     ${ECS_SERVICE_NAME}"
  echo "Pool:        ${COMPUTE_POOL_NAME}"
  echo "ASG:         ${ASG_NAME}"
}

service_counts() {
  local service_name="$1"
  local counts

  counts="$(aws ecs describe-services \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${service_name}" \
    --query 'services[0].[desiredCount,runningCount,pendingCount]' \
    --output text)"

  if [[ -z "${counts}" || "${counts}" == "None" ]]; then
    printf '0\t0\t0\n'
    return
  fi

  echo "${counts}"
}

service_is_active() {
  local service_name="$1"
  local counts desired_count running_count pending_count remainder

  counts="$(service_counts "${service_name}")"
  desired_count="${counts%%$'\t'*}"
  remainder="${counts#*$'\t'}"
  running_count="${remainder%%$'\t'*}"
  pending_count="${remainder##*$'\t'}"

  [[ "${desired_count}" != "0" || "${running_count}" != "0" || "${pending_count}" != "0" ]]
}

pool_has_active_services() {
  local target_pool="$1"
  local profile service_name

  for profile in $(profile_names); do
    if [[ "$(profile_pool_name "${profile}")" != "${target_pool}" ]]; then
      continue
    fi

    service_name="$(profile_service_name "${profile}")"
    if service_is_active "${service_name}"; then
      return 0
    fi
  done

  return 1
}
