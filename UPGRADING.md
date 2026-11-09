# Upgrading LiteLLM

Changing the pinned LiteLLM version on the ECS deployment. Version-independent — the
only thing that changes between upgrades is the target.

```bash
./upgrade-litellm.sh --check               # resolve the target, report drift, change nothing
./upgrade-litellm.sh --to lts              # resolve lts to a version, then upgrade (default)
./upgrade-litellm.sh --to v1.108.3         # upgrade to an explicit version
```

Always run `--check` first. It is read-only and prints the target, the architecture
check, and the migrations that will run.

## Picking a version

Upstream publishes two moving channels on `ghcr.io/berriai/litellm`:

- **`lts`**: the long-term support line, starting with 1.108 (a one-month pilot
  from 2026-11-02, see <https://docs.litellm.ai/docs/enterprise/lts_pilot>). It gets
  backported fixes on `lts/1.108.x` and moves with every LTS patch. **This deployment
  tracks `lts`.**
- **`main-stable`**: the regular stable channel. It is no longer guaranteed to match
  `lts`. On 2026-11-09 it pointed at v1.108.0 while `lts` was v1.108.3.

Both tags move, so **identify the version by digest, never by tag name**:

```bash
crane digest ghcr.io/berriai/litellm:lts
crane digest ghcr.io/berriai/litellm:vX.Y.Z    # must match
```

`--to lts` (the default) and `--to main-stable` do this for you: the script resolves
the digest, walks published non-prerelease releases to find the one with the same
digest, and pins that concrete version. It reports where both channels point. Pin
the version rather than the channel, because `LITELLM_VERSION` doubles as the ECR
image tag, and a floating tag there makes ECR contents ambiguous.

LTS versions are also tagged `vX.Y.Z-lts`, which has the same digest as `vX.Y.Z`. The
script normalizes `--to vX.Y.Z-lts` to `vX.Y.Z`, so the ECR tag, the in-image version
check and the snapshot name all agree.

LTS patch notes say "no action needed" relative to the *previous LTS patch* only.
Read the breaking-change callouts on every minor release in between. Use the curated
notes at <https://docs.litellm.ai/release_notes>, not the GitHub PR lists.

When the pilot ends, check the LTS pilot page before the next upgrade. The `lts`
channel may move to a new line or stop.

## Why not `./deploy.sh`

`deploy.sh` is the install / full-reconcile path and stays as-is — it is upstream's
entry point, referenced by the AWS Implementation Guide and workshop the README links
to, and this is a fork with live upstream merge history.

It does too much for a version bump:

- Rebuilds and pushes `middleware:latest` **unconditionally**. `--skip-build` only
  gates the LiteLLM image, so a "version only" run also ships whatever is in
  `middleware/` — an undeclared second change.
- Rewrites `config/config.yaml` in place via `yq`, adding callbacks.
- Applies the log-bucket stack as well.

## What the script does, and why each step exists

1. **Reads deployed state** from the live service rather than assuming — current image,
   `runtimePlatform`, DB secret ARN, task/execution roles, subnets, security groups.
   Warns when the `.env` pin and the running version differ, which means a previous
   pin was committed but never deployed.

2. **Resolves the target by digest** and **refuses a target that does not publish the
   architecture the task definition runs** (this deployment is ARM64). A missing arch
   would otherwise fail at task start, after the rollout had begun.

3. **Diffs bundled migrations** between the deployed image and the target by listing
   `litellm_proxy_extras/migrations` in each, then classifies each new migration:

   - blocking `CREATE INDEX` — holds a write lock while it builds
   - `CREATE INDEX CONCURRENTLY` — non-blocking, but can leave an INVALID index
   - `DROP COLUMN` / `DROP TABLE` — destructive, review before proceeding

   It also detects a **downgrade** (target shipping fewer migrations than deployed).

   This is the main reason to use a script. Nobody diffs migration sets between two
   container images by hand, and the risk ranking is not obvious from release notes.

4. **Builds and pushes to ECR**, skipping the build when the tag already exists, then
   verifies the in-image `litellm` package version matches the tag.

5. **Snapshots the database** and waits for both the snapshot *and* the instance to
   return to `available`. A snapshot moves the instance to `backing-up`, and RDS
   rejects `ModifyDBInstance` in that state — a trap worth avoiding.

6. **Applies migrations from a single task**, before the service rolls. See below.

7. **Plans, then refuses to apply** anything outside `aws_ecs_task_definition` and
   `aws_ecs_service`, and verifies the new task definition really references the target
   tag. A version bump has no business touching RDS, the ALB or Redis.

8. **Rolls the service and watches it**, printing the rollback command up front.

## The migration race

LiteLLM runs `prisma migrate deploy` at boot in **every** task. With three tasks, three
processes race.

On the v1.101.0 → v1.103.2 upgrade this deadlocked:

```
Error: P3018
Database error code: 40P01
ERROR: deadlock detected
  Process 23953 waits for ShareLock on virtual transaction 76/1907; blocked by process 24001.
  Process 24001 waits for ExclusiveLock on advisory lock [16413,0,72707369,1]; blocked by process 23953.
```

The failed migration (`20260831120001_spend_logs_litellm_call_id_index`, a
`CREATE INDEX CONCURRENTLY` on a then-10 GB `LiteLLM_SpendLogs`) was marked failed,
which **blocks every migration after it**. Three columns were missing until LiteLLM's
own recovery rolled the migration back, rebuilt the invalid index, and re-applied.
Chat traffic kept serving throughout; tool/skill policies and MCP OAuth did not.

So the script applies migrations once, from a standalone Fargate task, and aborts
without touching the service if that fails. The ordering is the point.

## One-off database access

The database is private and ECS Exec is disabled on the service, so there is no psql
path from a workstation. Run a Fargate task on the existing image instead, reusing the
service's subnets, security group and `DATABASE_URL` secret — no EC2 host, no key pair,
no inbound SSH:

```bash
aws ecs run-task --cluster litellm-stack-cluster \
  --task-definition litellm-migrate-admin --launch-type FARGATE \
  --network-configuration 'awsvpcConfiguration={subnets=[...],securityGroups=[...],assignPublicIp=DISABLED}' \
  --overrides '{"containerOverrides":[{"name":"migrate","command":["-lc","<command>"]}]}'
```

Two things that will waste your time otherwise:

- **Set `entryPoint` to `sh`.** The image's entrypoint is the `litellm` CLI, so
  overriding only `command` makes it parse your script as CLI flags
  (`Error: No such option: -l`).
- **`asyncpg` is not installed.** Query through the bundled Prisma client
  (`from prisma import Prisma`, then `query_raw`), and pass non-trivial Python in via
  base64 rather than fighting shell quoting across the layers.

Useful checks:

```bash
# migration state
cd /app/.venv/lib/python3.13/site-packages/litellm_proxy_extras \
  && /app/.venv/bin/prisma migrate status --schema=./schema.prisma

# invalid indexes left by an interrupted concurrent build
select c.relname from pg_class c join pg_index i on i.indexrelid=c.oid where i.indisvalid=false;

# migrations that failed or were rolled back
select migration_name, finished_at, rolled_back_at from _prisma_migrations
where finished_at is null or rolled_back_at is not null;
```

## Rollback

The ECS deployment circuit breaker is enabled with rollback (since the v1.105.1
upgrade, 2026-10-16), and `minimumHealthyPercent` is 100. A rollout whose tasks keep
failing to start or pass health checks is stopped and reverted to the last steady
deployment automatically. A rollout that comes up healthy but misbehaves is not, so
watch it and revert by hand.

To revert the application:

```bash
aws ecs update-service --cluster litellm-stack-cluster --service LiteLLMService \
  --task-definition litellm-stack-fargate-task:<previous-revision>
```

Then set `LITELLM_VERSION` back in `.env` so the next apply does not re-upgrade.

**Migrations are forward-only.** Rolling the image back does not undo applied schema
changes. They are additive in practice (new columns, new indexes), so the older image
runs against the newer schema, but this is roll-forward-preferred, not a clean revert.

Restoring the snapshot is the last resort: RDS restores to a *new* instance, so it
means repointing `DATABASE_URL`, and spend logs written after the snapshot are lost.

## After an upgrade

- 3/3 tasks running, single deployment, both target groups healthy
  (`litellm-stack-4000` = LiteLLM/chat, `litellm-stack-3000` = middleware)
- A real chat completion succeeds through the gateway
- No migration or `does not exist in the current database` errors in `/ecs/litellm-stack-litellm`
- No invalid indexes (query above)
- `FreeStorageSpace` — new indexes consume space, and storage autoscaling is off

Expect some benign log noise since v1.103.x: `Auto-router baseline observation could
not be initialized` (a swallowed exception on an optional feature) and
`_acount_pre_call_check_tokens: failed to count tokens` alongside Bedrock `CountTokens`
400s for models that do not support that API.

Behaviour changes that arrived with v1.104/v1.105 and apply here:

- Over-budget requests return **422**, not 429 (`budget_exceeded_status_code` in
  `litellm_settings` restores 429). Accepted as-is on 2026-10-16.
- A failed boot migration now stops the task (exit 1) instead of serving on a stale
  schema (`ENFORCE_PRISMA_MIGRATION_CHECK`, default true).
- The proxy refuses to start on an unset, empty or `sk-1234` master key.
- Password logins are screened against haveibeenpwned (fails open); a breached or
  admin-set password restricts that session to `/ui/change-password`.

Behaviour changes that arrived with v1.106–v1.108. Production went v1.105.1 → v1.106.6
on 2026-10-29 (task definition `:32`; the pin was not committed at the time) and then
v1.106.6 → v1.108.3, so the v1.106 items were live from 2026-10-29:

- **String fallback targets make the proxy exit at startup** (v1.108.1). A fallback
  target must be a list: `fallbacks: [{"a": ["b"]}]`, `default_fallbacks: ["b"]`.
  `config/config.yaml` has none, but router settings saved through the Admin UI live
  in the database (`STORE_MODEL_IN_DB`), so check there before upgrading (query
  below). The circuit breaker would roll back a crash-looping rollout, but only
  after the migrations had been applied.
- Fallbacks to models the caller's key cannot access are skipped
  (`general_settings.enforce_fallback_model_access`, default true).
- The proxy refuses to start when a configured logging callback cannot load. `s3`
  is built in, so it is unaffected.
- The response cache skips requests with more than 4 messages
  (`cache_params.max_messages`, default 4). This deployment has `cache: True` with
  Redis, so expect a lower hit rate on multi-turn chat. Raise the limit or set it to
  `null` under `litellm_settings.cache_params` to restore the old behaviour.
- Token-count routes (`/v1/messages/count_tokens`, `/v1/responses/input_tokens`,
  `/utils/token_counter?call_endpoint=true`) now return the provider's error instead
  of a 200 with a local estimate. Bedrock models without `CountTokens` (e.g. Nova)
  return 400. Claude Code calls `/v1/messages/count_tokens`, so test it after the
  upgrade. `token_count_framing` / `token_count_model` in `model_info` restore a
  local count per model.
- The Bedrock guardrail returns 400 for attachments it cannot scan (PDFs, audio,
  images by URL) unless `skip_unscannable_attachments: true` is set. This only
  applies if guardrails are configured in the database.
- The caller's LiteLLM key is never forwarded to MCP servers, including via Extra
  Headers.
- `PATCH /credentials/{name}` no longer renames a credential (use `display_name`).
- `refusal` moved from `provider_specific_fields` to `message.refusal`. The
  middleware does not read either field.
- OpenRouter models were removed from the built-in cost map.

`scripts/check-db-settings.sh` checks the stored settings for string fallback targets,
plus failed migrations and invalid indexes, from a one-off task (read-only, prints no
secrets). Run it before an upgrade. The underlying query:

```sql
select param_name, param_value from "LiteLLM_Config"
where param_name in ('router_settings', 'litellm_settings', 'general_settings');
```

## Known gaps

- Only the LiteLLM image is handled. The middleware image is unchanged and still
  deploys as `middleware:latest`, which is not pinned.
- ECS only. The EKS path in the stack is untouched.
- The migrations path is hardcoded to `python3.13` (still correct on v1.108.3). The
  script now aborts if either image lists no migrations there, rather than treating
  that as "nothing to apply".
- The migration task runs the target image's `prisma migrate deploy`. It does not
  recover a database already carrying a *failed* migration — if `--check` or the logs
  show one, resolve it before upgrading.
- `tf-env.sh` duplicates the `TF_VAR_*` exports that `deploy.sh` does inline. Adding a
  stack variable means updating both; `tf-env.sh` fails loudly if the stack grows a
  required variable it does not export.
