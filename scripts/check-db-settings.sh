#!/bin/bash
# Read-only pre-upgrade database check, run from a one-off Fargate task on the deployed
# image (the database is private and ECS Exec is disabled -- see UPGRADING.md).
#
# Reports, without printing secrets:
#   * fallback settings stored in LiteLLM_Config (STORE_MODEL_IN_DB). Since v1.108.1 a
#     fallback target written as a string stops the proxy at startup.
#   * enforce_fallback_model_access and cache_params.max_messages, if set
#   * unresolved failed Prisma migrations, which block every migration after them, and
#     rolled-back attempts with whether they were since re-applied
#   * INVALID indexes left by an interrupted CREATE INDEX CONCURRENTLY
#
# Registers a temporary task definition (litellm-migrate-admin), runs it once, and
# deregisters it. Requires: aws, jq.

set -Eeuo pipefail

CLUSTER="litellm-stack-cluster"
SERVICE="LiteLLMService"
FAMILY="litellm-migrate-admin"
LOG_GROUP="/ecs/litellm-stack-litellm"
REGION="$(aws configure get region || echo us-east-1)"

TD="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].taskDefinition' --output text)"
TJ="$(aws ecs describe-task-definition --task-definition "$TD" --output json)"
IMG="$(jq -r '.taskDefinition.containerDefinitions[]|select(.name=="LiteLLMContainer")|.image' <<<"$TJ")"
SECRET="$(jq -r '.taskDefinition.containerDefinitions[]|select(.name=="LiteLLMContainer")|.secrets[]|select(.name=="DATABASE_URL")|.valueFrom' <<<"$TJ")"
EXEC_ROLE="$(jq -r .taskDefinition.executionRoleArn <<<"$TJ")"
TASK_ROLE="$(jq -r .taskDefinition.taskRoleArn <<<"$TJ")"
ARCH="$(jq -r '.taskDefinition.runtimePlatform.cpuArchitecture // "X86_64"' <<<"$TJ")"
SUBNETS="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets' --output json | jq -r 'join(",")')"
SGS="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups' --output json | jq -r 'join(",")')"

# Only named keys are printed: general_settings can hold webhook URLs and similar.
PY="$(cat <<'EOF'
import asyncio, json
from prisma import Prisma
KEYS = ("fallbacks", "default_fallbacks", "context_window_fallbacks", "content_policy_fallbacks")

def string_targets(val):
    """Fallback entries whose target is a string rather than a list (fatal since v1.108.1)."""
    if isinstance(val, str):
        return [val]
    bad = []
    for item in val or []:
        if isinstance(item, dict):
            bad += [f"{k} -> {v!r}" for k, v in item.items() if isinstance(v, str)]
    return bad

async def main():
    db = Prisma(); await db.connect()
    rows = await db.query_raw(
        'select param_name, param_value from "LiteLLM_Config" '
        "where param_name in ('router_settings','litellm_settings','general_settings')")
    print("CHECK stored settings rows:", sorted(r["param_name"] for r in rows))
    problems = []
    for r in rows:
        v = r["param_value"]
        if isinstance(v, str):
            try: v = json.loads(v)
            except Exception: pass
        if not isinstance(v, dict):
            print("CHECK", r["param_name"], "is not a dict:", type(v).__name__); continue
        for k in KEYS:
            if k in v:
                print("CHECK", r["param_name"], k, "=", json.dumps(v[k]))
                problems += [f'{r["param_name"]}.{k}: {b}' for b in string_targets(v[k])]
        if "enforce_fallback_model_access" in v:
            print("CHECK", r["param_name"], "enforce_fallback_model_access =", v["enforce_fallback_model_access"])
        if r["param_name"] == "litellm_settings" and isinstance(v.get("cache_params"), dict):
            print("CHECK cache_params.max_messages =", v["cache_params"].get("max_messages", "<unset>"))
    print("CHECK string fallback targets:", json.dumps(problems) if problems else "none")
    # Prisma keeps the row of a rolled-back attempt alongside the row of the re-apply, so
    # historical rollbacks are reported separately from migrations that never finished.
    # Only the latter block `prisma migrate deploy` (P3009).
    unresolved = await db.query_raw(
        "select m.migration_name, m.started_at from _prisma_migrations m "
        "where m.finished_at is null and m.rolled_back_at is null")
    print("CHECK unresolved failed migrations:", json.dumps(unresolved, default=str))
    history = await db.query_raw(
        "select m.migration_name, m.rolled_back_at, exists(select 1 from _prisma_migrations o "
        "where o.migration_name = m.migration_name and o.finished_at is not null "
        "and o.rolled_back_at is null) as reapplied "
        "from _prisma_migrations m where m.rolled_back_at is not null")
    print("CHECK rolled-back attempts (reapplied=true is history):", json.dumps(history, default=str))
    inv = await db.query_raw(
        "select c.relname from pg_class c join pg_index i on i.indexrelid=c.oid where i.indisvalid=false")
    print("CHECK invalid indexes:", json.dumps(inv))
    await db.disconnect()
    print("CHECK_OK")

asyncio.run(main())
EOF
)"
# base64 avoids quoting the script through the shell, JSON and ECS override layers.
B64="$(printf '%s' "$PY" | base64 | tr -d '\n')"

# entryPoint must be sh: the image's own entrypoint is the litellm CLI.
DEF="$(jq -n --arg fam "$FAMILY" --arg img "$IMG" --arg exec "$EXEC_ROLE" --arg task "$TASK_ROLE" \
    --arg secret "$SECRET" --arg lg "$LOG_GROUP" --arg region "$REGION" --arg arch "$ARCH" '{
    family:$fam, requiresCompatibilities:["FARGATE"], networkMode:"awsvpc",
    cpu:"512", memory:"1024", executionRoleArn:$exec, taskRoleArn:$task,
    runtimePlatform:{operatingSystemFamily:"LINUX", cpuArchitecture:$arch},
    containerDefinitions:[{
        name:"migrate", image:$img, essential:true,
        entryPoint:["sh"], command:["-lc","true"],
        secrets:[{name:"DATABASE_URL", valueFrom:$secret}],
        logConfiguration:{logDriver:"awslogs", options:{
            "awslogs-group":$lg, "awslogs-region":$region,
            "awslogs-stream-prefix":"migrate-admin"}}}]}')"
REV="$(aws ecs register-task-definition --cli-input-json "$DEF" \
    --query 'taskDefinition.taskDefinitionArn' --output text)"
trap 'aws ecs deregister-task-definition --task-definition "$REV" >/dev/null 2>&1 || true' EXIT

OV="$(jq -n --arg c "echo $B64 | base64 -d > /tmp/check.py && cd /app && /app/.venv/bin/python /tmp/check.py 2>&1" \
    '{containerOverrides:[{name:"migrate", command:["-lc",$c]}]}')"
ARN="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$REV" --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SGS],assignPublicIp=DISABLED}" \
    --overrides "$OV" --query 'tasks[0].taskArn' --output text)"
echo "task ${ARN##*/} on ${IMG##*/}; waiting"
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$ARN"
EXIT_CODE="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$ARN" \
    --query 'tasks[0].containers[0].exitCode' --output text)"
sleep 10
aws logs get-log-events --log-group-name "$LOG_GROUP" \
    --log-stream-name "migrate-admin/migrate/${ARN##*/}" --start-from-head \
    --query 'events[].message' --output text | tr '\t' '\n' | grep -v 'prisma:warn' || true
echo "exit code: $EXIT_CODE"
[ "$EXIT_CODE" = "0" ]
