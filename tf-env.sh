#!/bin/bash
# Export the TF_VAR_* set that litellm-terraform-stack needs.
#
# Source this (do not execute it) from the repository root:
#   source ./tf-env.sh
#
# Why this exists: 53 root variables in litellm-terraform-stack/variables.tf have no
# default, so `terraform plan` fails with "No value for required variable" unless every
# one is exported -- including provider API keys whose value is an empty string. Four
# more (name, ecrLitellmRepository, ecrMiddlewareRepository, create_cluster) are
# hardcoded in deploy.sh rather than read from .env, so they are not obvious from the
# file alone. Running terraform by hand without this is the single biggest source of
# friction in this repo.
#
# deploy.sh does its own exporting inline and does not source this, so the two can
# drift. If you add a variable to the stack, update both.

# Detect execution vs sourcing. When sourced, BASH_SOURCE[0] is this file while $0 is
# the calling shell; when executed directly they are the same path. Compare resolved
# basenames so `bash ./tf-env.sh` and `./tf-env.sh` are both caught.
if [ "$(basename -- "${BASH_SOURCE[0]:-$0}")" = "$(basename -- "$0")" ] \
   && [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    echo "tf-env.sh must be sourced, not executed: source ./tf-env.sh" >&2
    exit 1
fi

# Resolve this file's own directory, not the caller's cwd, so sourcing from a
# subdirectory (e.g. from inside litellm-terraform-stack) still finds .env.
_tf_env_repo_root="$(cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

if [ ! -f "$_tf_env_repo_root/.env" ]; then
    echo "tf-env.sh: .env not found at $_tf_env_repo_root/.env" >&2
    return 1
fi

# .env is a flat KEY="value" file. Export everything it declares, matching deploy.sh.
set -a
# shellcheck disable=SC1091
source "$_tf_env_repo_root/.env"
set +a

# Hardcoded in deploy.sh (lines 64-67), not present in .env.
export TF_VAR_name="litellm-stack"
export TF_VAR_ecrLitellmRepository="litellm"
export TF_VAR_ecrMiddlewareRepository="middleware"

# deploy.sh derives these from .env values.
export TF_VAR_deployment_platform="${DEPLOYMENT_PLATFORM:-ECS}"
export TF_VAR_vpc_id="${EXISTING_VPC_ID:-}"
export TF_VAR_litellm_version="${LITELLM_VERSION:?LITELLM_VERSION must be set in .env}"
export TF_VAR_litellm_log_level="${LITELLM_LOG_LEVEL:-INFO}"
export TF_VAR_public_load_balancer="${PUBLIC_LOAD_BALANCER:-true}"
export TF_VAR_existing_cluster_name="${EXISTING_EKS_CLUSTER_NAME:-}"
export TF_VAR_architecture="${CPU_ARCHITECTURE:-$(case "$(uname -m)" in x86_64) echo x86 ;; arm64) echo arm ;; esac)}"

# create_cluster follows deploy.sh:389-393 -- false only when reusing an existing EKS cluster.
if [ -n "${EXISTING_EKS_CLUSTER_NAME:-}" ]; then
    export TF_VAR_create_cluster="false"
else
    export TF_VAR_create_cluster="true"
fi

# The log bucket ARN is an output of the separate log-bucket stack. deploy.sh applies
# that stack first and passes the output through; read it from state instead so this
# does not require applying anything.
if [ -z "${TF_VAR_log_bucket_arn:-}" ]; then
    if [ -d "$_tf_env_repo_root/litellm-s3-log-bucket-terraform" ]; then
        TF_VAR_log_bucket_arn="$(cd "$_tf_env_repo_root/litellm-s3-log-bucket-terraform" \
            && terraform output -raw LogBucketArn 2>/dev/null || true)"
        export TF_VAR_log_bucket_arn
    fi
fi
if [ -z "${TF_VAR_log_bucket_arn:-}" ]; then
    echo "tf-env.sh: could not resolve TF_VAR_log_bucket_arn from the log-bucket stack." >&2
    echo "  Run 'terraform init' in litellm-s3-log-bucket-terraform, or export it yourself." >&2
    return 1
fi

# Capacity and autoscaling.
export TF_VAR_desired_capacity="${DESIRED_CAPACITY:-3}"
export TF_VAR_min_capacity="${MIN_CAPACITY:-3}"
export TF_VAR_max_capacity="${MAX_CAPACITY:-10}"
export TF_VAR_cpu_target_utilization_percent="${ECS_CPU_TARGET_UTILIZATION_PERCENTAGE:-50}"
export TF_VAR_memory_target_utilization_percent="${ECS_MEMORY_TARGET_UTILIZATION_PERCENTAGE:-40}"
export TF_VAR_alb_requests_per_target="${ECS_ALB_REQUESTS_PER_TARGET:-100}"
export TF_VAR_vcpus="${ECS_VCPUS:-4}"

# Database and cache sizing. Note max_allocated_storage is deliberately not wired up --
# RDS storage autoscaling is intentionally off. See OPERATIONS.md.
export TF_VAR_rds_instance_class="${RDS_INSTANCE_CLASS:?RDS_INSTANCE_CLASS must be set in .env}"
export TF_VAR_rds_allocated_storage="${RDS_ALLOCATED_STORAGE_GB:?RDS_ALLOCATED_STORAGE_GB must be set in .env}"
export TF_VAR_redis_node_type="${REDIS_NODE_TYPE:?REDIS_NODE_TYPE must be set in .env}"
export TF_VAR_redis_num_cache_clusters="${REDIS_NUM_CACHE_CLUSTERS:-2}"

# Networking and DNS.
export TF_VAR_record_name="${RECORD_NAME:-}"
export TF_VAR_hosted_zone_name="${HOSTED_ZONE_NAME:-}"
export TF_VAR_certificate_arn="${CERTIFICATE_ARN:-}"
export TF_VAR_use_route53="${USE_ROUTE53:-false}"
export TF_VAR_use_cloudfront="${USE_CLOUDFRONT:-false}"
export TF_VAR_cloudfront_price_class="${CLOUDFRONT_PRICE_CLASS:-}"
export TF_VAR_create_private_hosted_zone_in_existing_vpc="${CREATE_PRIVATE_HOSTED_ZONE_IN_EXISTING_VPC:-false}"
export TF_VAR_create_vpc_endpoints_in_existing_vpc="${CREATE_VPC_ENDPOINTS_IN_EXISTING_VPC:-false}"
export TF_VAR_disable_outbound_network_access="${DISABLE_OUTBOUND_NETWORK_ACCESS:-false}"
export TF_VAR_public_subnet_ids="$([ -n "${PUBLIC_SUBNET_IDS:-}" ] && echo "[\"$(echo "$PUBLIC_SUBNET_IDS" | sed 's/,/\",\"/g')\"]" || echo "[]")"
export TF_VAR_private_subnet_ids="$([ -n "${PRIVATE_SUBNET_IDS:-}" ] && echo "[\"$(echo "$PRIVATE_SUBNET_IDS" | sed 's/,/\",\"/g')\"]" || echo "[]")"

# UI surface.
export TF_VAR_disable_swagger_page="${DISABLE_SWAGGER_PAGE:-false}"
export TF_VAR_disable_admin_ui="${DISABLE_ADMIN_UI:-false}"

# EKS-only knobs; still required to have values on ECS.
export TF_VAR_install_add_ons_in_existing_eks_cluster="${INSTALL_ADD_ONS_IN_EXISTING_EKS_CLUSTER:-false}"
export TF_VAR_arm_instance_type="${EKS_ARM_INSTANCE_TYPE:-}"
export TF_VAR_x86_instance_type="${EKS_X86_INSTANCE_TYPE:-}"
export TF_VAR_arm_ami_type="${EKS_ARM_AMI_TYPE:-}"
export TF_VAR_x86_ami_type="${EKS_X86_AMI_TYPE:-}"

# Observability / auth integrations.
export TF_VAR_langsmith_project="${LANGSMITH_PROJECT:-}"
export TF_VAR_langsmith_default_run_name="${LANGSMITH_DEFAULT_RUN_NAME:-}"
export TF_VAR_langsmith_api_key="${LANGSMITH_API_KEY:-}"
export TF_VAR_langfuse_public_key="${LANGFUSE_PUBLIC_KEY:-}"
export TF_VAR_langfuse_secret_key="${LANGFUSE_SECRET_KEY:-}"
export TF_VAR_okta_audience="${OKTA_AUDIENCE:-}"
export TF_VAR_okta_issuer="${OKTA_ISSUER:-}"
[ -n "${LANGFUSE_HOST:-}" ] && export TF_VAR_langfuse_host="$LANGFUSE_HOST"

# Provider API keys. Required variables with no default: each must be exported even
# when empty, or terraform refuses to plan.
for _k in OPENAI_API_KEY AZURE_OPENAI_API_KEY AZURE_API_KEY ANTHROPIC_API_KEY \
          GROQ_API_KEY COHERE_API_KEY CO_API_KEY HF_TOKEN HUGGINGFACE_API_KEY \
          DATABRICKS_API_KEY GEMINI_API_KEY CODESTRAL_API_KEY MISTRAL_API_KEY \
          AZURE_AI_API_KEY NVIDIA_NIM_API_KEY XAI_API_KEY PERPLEXITYAI_API_KEY \
          GITHUB_API_KEY DEEPSEEK_API_KEY AI21_API_KEY; do
    # TF_VAR names are the lowercased env names.
    _lower="$(echo "$_k" | tr '[:upper:]' '[:lower:]')"
    eval "export TF_VAR_${_lower}=\"\${${_k}:-}\""
done
unset _k _lower

# Fail loudly now rather than mid-plan if the stack grew a variable this file misses.
if command -v python3 >/dev/null 2>&1; then
    _tf_env_missing="$(python3 - "$_tf_env_repo_root" <<'PY'
import os, re, sys
root = sys.argv[1]
path = os.path.join(root, "litellm-terraform-stack", "variables.tf")
try:
    src = open(path).read()
except OSError:
    sys.exit(0)
blocks = re.findall(r'variable\s+"([^"]+)"\s*\{(.*?)\n\}', src, re.S)
required = [n for n, b in blocks if "default" not in b]
print(" ".join(n for n in required if "TF_VAR_" + n not in os.environ))
PY
)"
    if [ -n "$_tf_env_missing" ]; then
        echo "tf-env.sh: required stack variables are not exported: $_tf_env_missing" >&2
        echo "  Add them to tf-env.sh (and deploy.sh, which exports its own set)." >&2
        unset _tf_env_missing
        return 1
    fi
    unset _tf_env_missing
fi

echo "tf-env.sh: exported TF_VAR_* for ${TF_VAR_name} (litellm ${TF_VAR_litellm_version}, ${TF_VAR_architecture}, rds ${TF_VAR_rds_allocated_storage}GB)"
