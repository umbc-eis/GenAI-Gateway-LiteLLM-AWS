# Upgrading LiteLLM

Changing the pinned LiteLLM version on the ECS deployment. Version-independent — the
only thing that changes between upgrades is the target.

```bash
./upgrade-litellm.sh --check               # resolve the target, report drift, change nothing
./upgrade-litellm.sh --to main-stable      # resolve main-stable to a version, then upgrade
./upgrade-litellm.sh --to v1.103.2         # upgrade to an explicit version
```

Always run `--check` first. It is read-only and prints the target, the architecture
check, and the migrations that will run.

## Picking a version

Upstream publishes `ghcr.io/berriai/litellm:main-stable` and points its production
documentation at it. That tag moves, so **identify the version by digest, never by tag
name**:

```bash
crane digest ghcr.io/berriai/litellm:main-stable
crane digest ghcr.io/berriai/litellm:vX.Y.Z    # must match
```

`--to main-stable` does this for you: it resolves the digest, walks published
non-prerelease releases to find the one with the same digest, and pins that concrete
version. Pin the version rather than `main-stable` itself, because `LITELLM_VERSION`
doubles as the ECR image tag — a floating tag there makes ECR contents ambiguous.

Upstream maintains `stable/1.x` branches and backports onto them, so patch releases on
the current stable line are fixes only, no features.

Per-version `vX.Y.Z-stable` tags do **not** exist; only `main-stable` and plain
`vX.Y.Z`. (An earlier commit in this repo claimed the `-stable` convention had been
dropped entirely. That was wrong.)

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

There is **no automatic rollback** — the ECS deployment circuit breaker is disabled
(`enable: false, rollback: false`) with `minimumHealthyPercent: 100`. Failing tasks are
retried, not reverted. Watch the rollout.

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

Expect some benign new log noise on v1.103.x: `Auto-router baseline observation could
not be initialized` (a swallowed exception on an optional feature) and
`_acount_pre_call_check_tokens: failed to count tokens` alongside Bedrock `CountTokens`
400s for models that do not support that API.

## Known gaps

- Only the LiteLLM image is handled. The middleware image is unchanged and still
  deploys as `middleware:latest`, which is not pinned.
- ECS only. The EKS path in the stack is untouched.
- The migration task runs the target image's `prisma migrate deploy`. It does not
  recover a database already carrying a *failed* migration — if `--check` or the logs
  show one, resolve it before upgrading.
- `tf-env.sh` duplicates the `TF_VAR_*` exports that `deploy.sh` does inline. Adding a
  stack variable means updating both; `tf-env.sh` fails loudly if the stack grows a
  required variable it does not export.
