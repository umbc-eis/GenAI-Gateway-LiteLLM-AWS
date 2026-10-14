#!/bin/bash
# Change the pinned LiteLLM version on an existing ECS deployment.
#
#   ./upgrade-litellm.sh --check                 # resolve the target, report drift, exit
#   ./upgrade-litellm.sh --to v1.103.2           # full upgrade to an explicit version
#   ./upgrade-litellm.sh --to main-stable        # resolve main-stable to its version first
#   ./upgrade-litellm.sh --to v1.103.2 --yes     # skip the confirmation prompt
#
# Use this instead of ./deploy.sh for a version bump. deploy.sh is the install /
# full-reconcile path: it rebuilds and pushes middleware:latest unconditionally (even
# with --skip-build, which only gates the LiteLLM image), rewrites config/config.yaml
# via yq, and applies the log-bucket stack. None of that belongs in a version change.
#
# What this does that a runbook cannot do reliably:
#   * resolves main-stable by registry digest, never by tag name
#   * refuses a target whose image lacks the architecture the task definition runs
#   * diffs the migrations bundled in the deployed image against the target image
#   * applies migrations from ONE task before the service rolls, which is the whole
#     point: LiteLLM runs `prisma migrate deploy` at boot in every task, and three
#     tasks racing deadlocked production on the v1.101.0 -> v1.103.2 upgrade
#     (Postgres 40P01), marking a migration failed and blocking the rest
#   * asserts the terraform plan touches only the task definition and service
#   * watches the rollout and prints the rollback command, because the ECS deployment
#     circuit breaker is disabled on this service (no automatic revert)
#
# Requires: aws, docker, terraform, python3, jq. See UPGRADING.md and OPERATIONS.md.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$REPO_ROOT"

CLUSTER="litellm-stack-cluster"
SERVICE="LiteLLMService"
ECR_REPO="litellm"
LOG_GROUP="/ecs/litellm-stack-litellm"
GHCR_REPO="berriai/litellm"
MIGRATE_FAMILY="litellm-migrate-admin"

TARGET=""
ASSUME_YES=false
CHECK_ONLY=false
SKIP_MIGRATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --to) TARGET="${2:?--to needs a version}"; shift 2 ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --check) CHECK_ONLY=true; shift ;;
        --skip-migrate-task) SKIP_MIGRATE=true; shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

note() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m\nERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for c in aws docker terraform python3 jq; do
    command -v "$c" >/dev/null 2>&1 || die "$c is required but not installed"
done

# ---------------------------------------------------------------- registry helpers

ghcr_token() {
    curl -fsSL "https://ghcr.io/token?scope=repository:${GHCR_REPO}:pull&service=ghcr.io" \
        | jq -r .token
}

# Manifest-list digest for a tag. This is the identity we compare: tag names move,
# digests do not.
ghcr_digest() {
    local tag="$1" tok
    tok="$(ghcr_token)"
    curl -fsSL -o /dev/null -D - \
        -H "Authorization: Bearer $tok" \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
        "https://ghcr.io/v2/${GHCR_REPO}/manifests/${tag}" 2>/dev/null \
        | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}'
}

# Platforms a tag publishes, as "os/arch" lines.
ghcr_platforms() {
    local tag="$1" tok
    tok="$(ghcr_token)"
    curl -fsSL \
        -H "Authorization: Bearer $tok" \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
        "https://ghcr.io/v2/${GHCR_REPO}/manifests/${tag}" \
        | jq -r '.manifests[]? | select(.platform.os != null) | "\(.platform.os)/\(.platform.architecture)"' \
        | grep -v unknown | sort -u
}

# ---------------------------------------------------------------- current state

note "Reading deployed state"

TASK_DEF_ARN="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].taskDefinition' --output text)"
[ "$TASK_DEF_ARN" != "None" ] || die "service $SERVICE not found in cluster $CLUSTER"

TASK_JSON="$(aws ecs describe-task-definition --task-definition "$TASK_DEF_ARN" --output json)"
DEPLOYED_IMAGE="$(echo "$TASK_JSON" | jq -r '.taskDefinition.containerDefinitions[]|select(.name=="LiteLLMContainer")|.image')"
DEPLOYED_VERSION="${DEPLOYED_IMAGE##*:}"
TASK_ARCH="$(echo "$TASK_JSON" | jq -r '.taskDefinition.runtimePlatform.cpuArchitecture // "X86_64"')"
DB_SECRET="$(echo "$TASK_JSON" | jq -r '.taskDefinition.containerDefinitions[]|select(.name=="LiteLLMContainer")|.secrets[]|select(.name=="DATABASE_URL")|.valueFrom')"
EXEC_ROLE="$(echo "$TASK_JSON" | jq -r '.taskDefinition.executionRoleArn')"
TASK_ROLE="$(echo "$TASK_JSON" | jq -r '.taskDefinition.taskRoleArn')"
RUNNING="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].runningCount' --output text)"

case "$TASK_ARCH" in
    ARM64) DOCKER_PLATFORM="linux/arm64"; BUILD_ARCH="arm" ;;
    X86_64) DOCKER_PLATFORM="linux/amd64"; BUILD_ARCH="x86" ;;
    *) die "unexpected task cpuArchitecture: $TASK_ARCH" ;;
esac

info "service         : $SERVICE ($RUNNING running)"
info "task definition : ${TASK_DEF_ARN##*/}"
info "deployed version: $DEPLOYED_VERSION"
info "task platform   : $TASK_ARCH -> $DOCKER_PLATFORM"

ENV_VERSION="$(grep -E '^LITELLM_VERSION=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)"
[ -n "$ENV_VERSION" ] || die "LITELLM_VERSION not found in .env"
info ".env pin        : $ENV_VERSION"
if [ "$ENV_VERSION" != "$DEPLOYED_VERSION" ]; then
    warn ".env pin and the running version differ -- the repo pin was never deployed."
fi

# ---------------------------------------------------------------- resolve target

note "Resolving target version"

[ -n "$TARGET" ] || TARGET="main-stable"

TARGET_DIGEST="$(ghcr_digest "$TARGET")"
[ -n "$TARGET_DIGEST" ] || die "tag '$TARGET' not found in ghcr.io/${GHCR_REPO}"

if [[ "$TARGET" =~ ^v[0-9] ]]; then
    TARGET_VERSION="$TARGET"
else
    # A floating tag: find the concrete vX.Y.Z release sharing its digest. Pinning the
    # floating tag itself would make the ECR tag ambiguous, since .env doubles as the
    # ECR image tag.
    info "'$TARGET' is a floating tag ($TARGET_DIGEST); finding the version it points at"
    TARGET_VERSION=""
    while read -r cand; do
        [ -n "$cand" ] || continue
        if [ "$(ghcr_digest "$cand")" = "$TARGET_DIGEST" ]; then TARGET_VERSION="$cand"; break; fi
    done < <(curl -fsSL "https://api.github.com/repos/BerriAI/litellm/releases?per_page=30" \
             | jq -r '.[] | select(.prerelease==false and .draft==false) | .tag_name')
    [ -n "$TARGET_VERSION" ] || die "could not match '$TARGET' ($TARGET_DIGEST) to a published release"
fi

STABLE_DIGEST="$(ghcr_digest main-stable || true)"
info "target version : $TARGET_VERSION"
info "target digest  : $TARGET_DIGEST"
if [ -n "$STABLE_DIGEST" ]; then
    if [ "$STABLE_DIGEST" = "$TARGET_DIGEST" ]; then
        info "main-stable    : matches this target"
    else
        warn "main-stable points elsewhere ($STABLE_DIGEST) -- $TARGET_VERSION is not the current production release."
    fi
fi

PLATFORMS="$(ghcr_platforms "$TARGET_VERSION")"
echo "$PLATFORMS" | grep -qx "$DOCKER_PLATFORM" \
    || die "$TARGET_VERSION does not publish $DOCKER_PLATFORM (publishes: $(echo "$PLATFORMS" | tr '\n' ' '))"
info "platforms      : $(echo "$PLATFORMS" | tr '\n' ' ')"

if [ "$TARGET_VERSION" = "$DEPLOYED_VERSION" ]; then
    note "Already running $TARGET_VERSION"
    $CHECK_ONLY && exit 0
    info "Nothing to do. Re-run with a different --to to change versions."
    exit 0
fi

# ---------------------------------------------------------------- migration diff

note "Comparing bundled migrations"

MIG_DIR='/app/.venv/lib/python3.13/site-packages/litellm_proxy_extras/migrations'
list_migrations() {  # image ref -> migration directory names
    docker run --rm --entrypoint sh "$1" -c "ls $MIG_DIR 2>/dev/null" 2>/dev/null \
        | grep -v migration_lock.toml | sort
}

info "pulling $DEPLOYED_IMAGE"
aws ecr get-login-password --region "$(aws configure get region || echo us-east-1)" \
    | docker login --username AWS --password-stdin "${DEPLOYED_IMAGE%%/*}" >/dev/null 2>&1 || true
docker pull --quiet --platform "$DOCKER_PLATFORM" "$DEPLOYED_IMAGE" >/dev/null
info "pulling ghcr.io/${GHCR_REPO}:${TARGET_VERSION}"
docker pull --quiet --platform "$DOCKER_PLATFORM" "ghcr.io/${GHCR_REPO}:${TARGET_VERSION}" >/dev/null

OLD_MIGS="$(list_migrations "$DEPLOYED_IMAGE")"
NEW_MIGS="$(list_migrations "ghcr.io/${GHCR_REPO}:${TARGET_VERSION}")"
PENDING="$(comm -13 <(echo "$OLD_MIGS") <(echo "$NEW_MIGS"))"
PENDING_COUNT="$(echo "$PENDING" | grep -c . || true)"

info "migrations: $(echo "$OLD_MIGS" | grep -c .) deployed -> $(echo "$NEW_MIGS" | grep -c .) target ($PENDING_COUNT new)"

# A target that is missing migrations the deployed image ships is a downgrade. The
# database keeps the newer schema either way -- `prisma migrate deploy` never reverts --
# so the older image runs against a schema it does not know about. That is usually fine
# for additive changes, but it is never what someone means by "upgrade".
REGRESSED="$(comm -23 <(echo "$OLD_MIGS") <(echo "$NEW_MIGS") | grep -c . || true)"
if [ "$REGRESSED" -gt 0 ]; then
    warn "$TARGET_VERSION ships $REGRESSED fewer migrations than $DEPLOYED_VERSION -- this is a DOWNGRADE."
    warn "Applied migrations are not reverted, so the older image will run against the newer schema."
fi

if [ "$PENDING_COUNT" -gt 0 ]; then
    echo "$PENDING" | sed 's/^/      + /'
    # Surface the statements that can hold locks or fail. A blocking CREATE INDEX on a
    # large table stalls writes; CREATE INDEX CONCURRENTLY can leave an INVALID index.
    RISKY=""
    while read -r m; do
        [ -n "$m" ] || continue
        sql="$(docker run --rm --entrypoint cat "ghcr.io/${GHCR_REPO}:${TARGET_VERSION}" \
               "$MIG_DIR/$m/migration.sql" 2>/dev/null || true)"
        body="$(echo "$sql" | grep -v '^\s*--' | grep -v '^\s*$')"
        if echo "$body" | grep -qi 'CREATE INDEX CONCURRENTLY'; then
            RISKY+="      ~ $m: CREATE INDEX CONCURRENTLY (non-blocking; can leave an INVALID index if interrupted)"$'\n'
        elif echo "$body" | grep -qi 'CREATE INDEX'; then
            RISKY+="      ! $m: blocking CREATE INDEX (holds a write lock for the build)"$'\n'
        fi
        if echo "$body" | grep -qiE 'DROP (COLUMN|TABLE)'; then
            RISKY+="      !! $m: DROP COLUMN/TABLE -- destructive, review before proceeding"$'\n'
        fi
    done <<< "$PENDING"
    if [ -n "$RISKY" ]; then
        note "Migrations worth knowing about"
        printf '%s' "$RISKY"
        info "Migrations are forward-only: rolling the image back does not undo them."
    fi
fi

if $CHECK_ONLY; then
    note "Check only -- nothing changed"
    exit 0
fi

# ---------------------------------------------------------------- confirm

note "Plan"
info "$DEPLOYED_VERSION  ->  $TARGET_VERSION"
info "$PENDING_COUNT migrations will be applied from a single task before the service rolls"
info "ECS circuit breaker is disabled on this service: no automatic rollback"
if ! $ASSUME_YES; then
    printf '\n    Proceed? [y/N] '
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "    aborted"; exit 1; }
fi

# ---------------------------------------------------------------- build and push

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_REGION="$(aws configure get region || echo us-east-1)"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

note "Publishing ${ECR_REPO}:${TARGET_VERSION} to ECR"
if aws ecr describe-images --repository-name "$ECR_REPO" \
       --image-ids "imageTag=${TARGET_VERSION}" >/dev/null 2>&1; then
    info "already present in ECR; skipping build"
else
    aws ecr get-login-password --region "$AWS_REGION" \
        | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" >/dev/null
    docker build --platform "$DOCKER_PLATFORM" \
        --build-arg "LITELLM_VERSION=${TARGET_VERSION}" \
        -t "${ECR_REPO}:${TARGET_VERSION}" .
    docker tag "${ECR_REPO}:${TARGET_VERSION}" "${ECR_URI}:${TARGET_VERSION}"
    docker push "${ECR_URI}:${TARGET_VERSION}"
fi

# Verify what we are about to ship really is the requested version.
IN_IMAGE="$(docker run --rm --entrypoint python "ghcr.io/${GHCR_REPO}:${TARGET_VERSION}" \
    -c 'from importlib.metadata import version; print(version("litellm"))' 2>/dev/null | tail -1)"
info "in-image litellm version: ${IN_IMAGE:-unknown}"
if [ -n "$IN_IMAGE" ] && [ "v$IN_IMAGE" != "$TARGET_VERSION" ]; then
    warn "image reports $IN_IMAGE but the tag says $TARGET_VERSION"
fi

# ---------------------------------------------------------------- snapshot

note "Snapshotting the database"
DB_ID="$(aws rds describe-db-instances \
    --query "DBInstances[?starts_with(DBInstanceIdentifier,'litellm-stack')].DBInstanceIdentifier|[0]" --output text)"
[ "$DB_ID" != "None" ] || die "could not find the litellm RDS instance"
SNAP="litellm-db-pre-${TARGET_VERSION//./-}-$(date +%Y%m%d-%H%M%S)"
aws rds create-db-snapshot --db-instance-identifier "$DB_ID" --db-snapshot-identifier "$SNAP" \
    --tags Key=project,Value=llmgateway "Key=purpose,Value=pre-upgrade-${TARGET_VERSION}" >/dev/null
info "$SNAP"
info "waiting for the snapshot, then for the instance to leave backing-up"
# Both waits matter: a snapshot moves the instance to backing-up, and migrations
# should not start against an instance that is still settling.
aws rds wait db-snapshot-completed --db-snapshot-identifier "$SNAP"
aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
info "snapshot available"

# ---------------------------------------------------------------- migrate once

if [ "$PENDING_COUNT" -gt 0 ] && ! $SKIP_MIGRATE; then
    note "Applying migrations from one task"
    info "The service runs 'prisma migrate deploy' at boot in every task. Three tasks"
    info "racing deadlocked this database on the v1.101.0 -> v1.103.2 upgrade, so apply"
    info "them once here, before the rollout."

    SUBNETS="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
        --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets' --output json | jq -r 'join(",")')"
    SGS="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
        --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups' --output json | jq -r 'join(",")')"

    # entryPoint must be sh: the image's own entrypoint is the litellm CLI, which would
    # otherwise parse the command as CLI flags.
    MIG_TASK_JSON="$(jq -n \
        --arg fam "$MIGRATE_FAMILY" --arg img "${ECR_URI}:${TARGET_VERSION}" \
        --arg exec "$EXEC_ROLE" --arg task "$TASK_ROLE" --arg arch "$TASK_ARCH" \
        --arg secret "$DB_SECRET" --arg lg "$LOG_GROUP" --arg region "$AWS_REGION" '{
        family:$fam, requiresCompatibilities:["FARGATE"], networkMode:"awsvpc",
        cpu:"1024", memory:"2048", executionRoleArn:$exec, taskRoleArn:$task,
        runtimePlatform:{operatingSystemFamily:"LINUX", cpuArchitecture:$arch},
        containerDefinitions:[{
            name:"migrate", image:$img, essential:true,
            entryPoint:["sh"], command:["-lc","true"],
            secrets:[{name:"DATABASE_URL", valueFrom:$secret}],
            logConfiguration:{logDriver:"awslogs", options:{
                "awslogs-group":$lg, "awslogs-region":$region,
                "awslogs-stream-prefix":"migrate-admin"}}}]}')"
    aws ecs register-task-definition --cli-input-json "$MIG_TASK_JSON" >/dev/null
    MIG_REV="$(aws ecs list-task-definitions --family-prefix "$MIGRATE_FAMILY" --sort DESC \
        --max-items 1 --query 'taskDefinitionArns[0]' --output text)"
    info "registered ${MIG_REV##*/}"

    MIG_CMD='cd /app/.venv/lib/python3.13/site-packages/litellm_proxy_extras \
        && /app/.venv/bin/prisma migrate deploy --schema=./schema.prisma 2>&1 \
        && echo "MIGRATE_OK"'
    OVERRIDES="$(jq -n --arg c "$MIG_CMD" \
        '{containerOverrides:[{name:"migrate",command:["-lc",$c]}]}')"
    MIG_ARN="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$MIG_REV" \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SGS],assignPublicIp=DISABLED}" \
        --overrides "$OVERRIDES" --query 'tasks[0].taskArn' --output text)"
    info "migration task ${MIG_ARN##*/}; waiting"
    aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$MIG_ARN"
    MIG_EXIT="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$MIG_ARN" \
        --query 'tasks[0].containers[0].exitCode' --output text)"
    sleep 12
    MIG_LOG="$(aws logs get-log-events --log-group-name "$LOG_GROUP" \
        --log-stream-name "migrate-admin/migrate/${MIG_ARN##*/}" --start-from-head \
        --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' \
        | grep -v 'prisma:warn\|Please report' || true)"
    echo "$MIG_LOG" | sed 's/^/      /'
    aws ecs deregister-task-definition --task-definition "$MIG_REV" >/dev/null 2>&1 || true

    if [ "$MIG_EXIT" != "0" ] || ! echo "$MIG_LOG" | grep -q MIGRATE_OK; then
        die "migrations failed (exit $MIG_EXIT). The service is untouched and still on
       $DEPLOYED_VERSION. Snapshot: $SNAP
       If a migration is marked failed, LiteLLM may roll it back and retry on its own;
       re-run with --check to inspect before trying again."
    fi
    info "migrations applied"
fi

# ---------------------------------------------------------------- terraform

note "Updating the task definition"
python3 - "$TARGET_VERSION" <<'PY'
import re, sys
v = sys.argv[1]
for path in (".env", ".env.template"):
    try:
        src = open(path).read()
    except OSError:
        continue
    new = re.sub(r'^LITELLM_VERSION=.*$', f'LITELLM_VERSION="{v}"', src, count=1, flags=re.M)
    if new != src and path == ".env":
        open(path, "w").write(new)
        print(f"    {path}: LITELLM_VERSION -> {v}")
PY

# shellcheck disable=SC1091
source "$REPO_ROOT/tf-env.sh" >/dev/null
[ "$TF_VAR_litellm_version" = "$TARGET_VERSION" ] \
    || die "tf-env.sh resolved $TF_VAR_litellm_version, expected $TARGET_VERSION"

PLAN="$(mktemp -t litellm-upgrade-plan)"
( cd litellm-terraform-stack && terraform plan -input=false -lock-timeout=120s -out="$PLAN" >/dev/null )

# Refuse to apply anything beyond the task definition and service. A version bump has
# no business touching RDS, the ALB, or Redis.
( cd litellm-terraform-stack && terraform show -json "$PLAN" ) | python3 - "$TARGET_VERSION" <<'PY'
import json, sys, re
plan = json.load(sys.stdin)
target = sys.argv[1]
changes = [c for c in plan.get("resource_changes", []) if c["change"]["actions"] != ["no-op"]]
allowed = ("aws_ecs_task_definition", "aws_ecs_service")
bad = [c["address"] for c in changes if c["type"] not in allowed]
print("    changeset:")
for c in changes:
    print(f"      {c['address']} {c['change']['actions']}")
if bad:
    sys.exit("    REFUSING: plan touches resources beyond the task definition/service:\n      "
             + "\n      ".join(bad))
imgs = []
for c in changes:
    if c["type"] == "aws_ecs_task_definition":
        cd = (c["change"].get("after") or {}).get("container_definitions") or ""
        imgs = re.findall(r'"image":\s*"([^"]+)"', cd)
litellm_imgs = [i for i in imgs if "/litellm:" in i]
if not any(i.endswith(":" + target) for i in litellm_imgs):
    sys.exit(f"    REFUSING: new task definition does not reference litellm:{target} (found {litellm_imgs})")
print(f"    verified: new task definition uses litellm:{target}")
PY

( cd litellm-terraform-stack && terraform apply -input=false -auto-approve -lock-timeout=120s "$PLAN" >/dev/null )
rm -f "$PLAN"
info "applied"

# ---------------------------------------------------------------- roll out

note "Rolling the service"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
    --force-new-deployment --no-cli-pager >/dev/null

NEW_REV="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].taskDefinition' --output text)"
info "new task definition: ${NEW_REV##*/}"
info "rollback if needed : aws ecs update-service --cluster $CLUSTER --service $SERVICE --task-definition ${TASK_DEF_ARN##*/}"

DEADLINE=$(( $(date +%s) + 900 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    read -r PRIM_RUN PRIM_PEND <<<"$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
        --query 'services[0].deployments[?status==`PRIMARY`].[runningCount,pendingCount]' --output text)"
    OLD_RUN="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
        --query 'services[0].deployments[?status==`ACTIVE`].runningCount' --output text)"
    printf '    %s  new=%s/%s old=%s\n' "$(date +%H:%M:%S)" "${PRIM_RUN:-0}" "${PRIM_PEND:-0}" "${OLD_RUN:-0}"
    if [ "${PRIM_RUN:-0}" -ge "$RUNNING" ] && [ -z "${OLD_RUN:-}" ]; then
        info "rollout complete"; break
    fi
    sleep 20
done

note "Health"
for tg in $(aws elbv2 describe-target-groups \
        --query "TargetGroups[?starts_with(TargetGroupName,'litellm-stack')].TargetGroupArn" --output text); do
    printf '    %-24s %s\n' "$(basename "${tg%/*}")" \
        "$(aws elbv2 describe-target-health --target-group-arn "$tg" \
           --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
done

note "Done: $DEPLOYED_VERSION -> $TARGET_VERSION"
info "snapshot : $SNAP"
info "rollback : aws ecs update-service --cluster $CLUSTER --service $SERVICE --task-definition ${TASK_DEF_ARN##*/}"
info "Migrations are forward-only; rolling the image back does not undo them."
info "Watch for a few minutes: this service has no deployment circuit breaker."
