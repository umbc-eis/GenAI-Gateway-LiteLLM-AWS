# LiteLLM upgrade: `v1.83.14-stable.patch.2` → `v1.84.6`

Concrete steps for upgrading the deployed proxy in place, with a rollback path.
There is no non-prod environment, so the safety net is a manual RDS snapshot
plus a saved copy of the previous `config.yaml`.

Reference: [v1.84.0 release notes](https://docs.litellm.ai/release_notes/v1.84.0/v1-84-0).

---

## Why this upgrade is mostly safe for *this* repo

Audited 1.84.0 behavior changes against the surface area in this codebase:

| 1.84.0 change | Affects this repo? |
|---|---|
| Pass-through endpoints default `auth: true` | No — none configured |
| Clientside `api_base`/`base_url` gated | No — middleware doesn't smuggle these |
| `os.environ/*` in key/team metadata ignored | No — our `os.environ/*` refs are in `router_settings` and `cache_params`, both still resolved |
| Master-key alias instead of hash in logs | **Yes** — S3 callback logs for master-key traffic will show `litellm_proxy_master_key` instead of the hash |
| `mock_response` / `mock_tool_calls` stripped | No — test scripts don't use these |
| Invite-link onboarding two-step | No — not used |
| CLI SSO server-side session | No — not used |
| Team self-join role restriction | No — not used |
| MCP changes | No — not used |
| `/ui/chat`, logo/favicon paths | No — not customized |
| `allow_client_tags` reverted | No — tags not used |
| Vector store credential masking | No — not used |
| `routing_groups` (additive) | No — global `routing_strategy: usage-based-routing-v2` still works |
| Health probe response gained fields | Additive — only matters if a strict-schema check is in place |

There is also a Host-header auth-bypass CVE (GHSA-4xpc-pv4p-pm3w) fixed in
1.84.0+ — independent reason to upgrade.

---

## Pre-flight (do these BEFORE touching `.env`)

### 1. Pin a quiet window

Pick a low-traffic window. Migrations run on container startup and the ECS
service does a rolling replace; brief 5xx blips are possible.

### 2. Capture current state

```bash
cd "/Users/champ/Library/CloudStorage/GoogleDrive-champ@umbc.edu/Other computers/Mac Mini - Remote/Sources/aws-litellm-prd"

# Confirm we're on a clean tree
git status

# Save the current pinned version somewhere obvious
grep '^LITELLM_VERSION=' .env
# Expected: LITELLM_VERSION="v1.83.14-stable.patch.2"

# Backup the active proxy config (the one that's actually live in S3)
cd litellm-terraform-stack
ConfigBucketName=$(terraform output -raw ConfigBucketName)
cd ..
aws s3 cp "s3://${ConfigBucketName}/config.yaml" "./config/config.yaml.pre-1.84.bak"

# Backup the local rendered config too
cp config/config.yaml config/config.yaml.pre-1.84.bak.local
```

### 3. RDS snapshot (this is the rollback artifact)

```bash
aws_region=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')

# Find the LiteLLM RDS instance identifier
DB_ID=$(aws rds describe-db-instances --region "$aws_region" \
  --query "DBInstances[?contains(DBInstanceIdentifier, 'litellm')].DBInstanceIdentifier" \
  --output text)
echo "DB instance: $DB_ID"

# Take a manual snapshot — this is what you restore from if 1.84.6 breaks
SNAPSHOT_ID="${DB_ID}-pre-1-84-upgrade-$(date +%Y%m%d-%H%M)"
aws rds create-db-snapshot \
  --region "$aws_region" \
  --db-instance-identifier "$DB_ID" \
  --db-snapshot-identifier "$SNAPSHOT_ID"

echo "Snapshot ID (save this): $SNAPSHOT_ID"

# Wait until it's available before proceeding
aws rds wait db-snapshot-available \
  --region "$aws_region" \
  --db-snapshot-identifier "$SNAPSHOT_ID"

echo "Snapshot ready."
```

**Write down `$SNAPSHOT_ID` and `$DB_ID`.** You need both for rollback.

### 4. Confirm the current ECR image is still around

There's no ECR lifecycle policy in this stack, so the `v1.83.14-stable.patch.2`
image stays in ECR. Verify:

```bash
aws ecr describe-images \
  --repository-name litellm \
  --image-ids imageTag=v1.83.14-stable.patch.2 \
  --query 'imageDetails[0].imagePushedAt'
```

If that returns a timestamp, the rollback image is available.

---

## Upgrade

### 5. Bump the version

```bash
# In .env (line 3):
#   LITELLM_VERSION="v1.83.14-stable.patch.2"
# changes to:
#   LITELLM_VERSION="v1.84.6"
```

`v1.84.6` is the latest patch on the 1.84 line. The Docker tag accepts the `v`
prefix going forward; PyPI uses bare PEP 440 (not used here, we're Docker only).

Also update `.env.template` line 1–3 so the example matches the new naming
scheme:

```
# LITELLM_VERSION eg: v1.84.6 (PEP 440 / SemVer)
# Get it from https://github.com/BerriAI/litellm/pkgs/container/litellm/versions?filters%5Bversion_type%5D=tagged
LITELLM_VERSION="v1.84.6"
```

### 6. Deploy

```bash
./deploy.sh
```

This will:
1. Build the new image (`Dockerfile` re-pulls from `ghcr.io/berriai/litellm:v1.84.6`)
2. Push to ECR
3. Run `terraform apply` (no infra change beyond the image tag)
4. Force a new ECS task deployment

Watch for the terraform confirmation prompt — review the plan; the only diff
should be the `litellm_version` variable / image tag.

### 7. Watch the rollout

```bash
cd litellm-terraform-stack
LITELLM_ECS_CLUSTER=$(terraform output -raw LitellmEcsCluster)
LITELLM_ECS_TASK=$(terraform output -raw LitellmEcsTask)
cd ..

# Service status
aws ecs describe-services \
  --cluster "$LITELLM_ECS_CLUSTER" \
  --services "$LITELLM_ECS_TASK" \
  --query 'services[0].deployments'

# Tail container logs (Prisma migrations show up here)
aws logs tail /ecs/litellm --follow --since 5m
```

What to look for in the logs:
- `Prisma` running migrations — should complete cleanly
- `Server running on port 4000` (or similar startup banner)
- No repeated CrashLoopBackOff / task-stop cycles
- No `os.environ/*` resolution warnings on startup (sanity check on item #4 above)

### 8. Smoke test

```bash
# Liveness / readiness
curl -fsS "${API_ENDPOINT}/health/liveliness"
curl -fsS "${API_ENDPOINT}/health/readiness"

# Confirm version actually flipped
curl -fsS "${API_ENDPOINT}/health/readiness" | jq '.litellm_version // "field not present"'
# In 1.84.0+ the readiness response includes litellm_version; should report 1.84.6

# Functional test against a real model
cd tests
python openai_chat_test_file.py

# Bedrock-specific
cd ..
python test-middleware-synchronous.py
python test-middleware-streaming.py
```

Pass criteria: chat completions return 200s, streaming works, master key auth
works, no 5xx on the proxy logs.

### 9. Verify the master-key log change (item #3 in the breaking-changes notes)

Make a request authenticated with the master key. In your S3 success_callback
logs, the recorded key identifier for that request should now be the literal
string `litellm_proxy_master_key` instead of a SHA-256 hash. Update any
dashboards / alerts that filter on the old hash.

### 10. Commit the bump

```bash
git add .env .env.template UPGRADE-1.84.md
git status
# Review, then commit when satisfied
```

(`.env` is `chmod 600` and tracked here per the existing pattern — that's why
it gets committed; double-check no secrets shifted.)

---

## Rollback

Three rollback levels, ordered by severity.

### Level 1: image-only revert (proxy starts but misbehaves)

If the new image runs but something is functionally wrong (latency, errors on
specific routes, callbacks failing) and you don't suspect schema corruption:

```bash
# In .env:
#   LITELLM_VERSION="v1.84.6"
# back to:
#   LITELLM_VERSION="v1.83.14-stable.patch.2"

./deploy.sh --skip-build  # image is already in ECR from before
```

The 1.84.0 schema migrations are additive (new tables, new optional columns),
so the older container *should* run against the migrated schema. This is the
expected-to-just-work case. Verify with `tests/openai_chat_test_file.py`.

### Level 2: image revert + config revert

If you also changed `config.yaml` (you shouldn't have for this upgrade, but in
case):

```bash
cd litellm-terraform-stack
ConfigBucketName=$(terraform output -raw ConfigBucketName)
cd ..

aws s3 cp ./config/config.yaml.pre-1.84.bak "s3://${ConfigBucketName}/config.yaml"

# Then redeploy old image as in Level 1
```

### Level 3: full rollback including DB (schema problem confirmed)

Only if the older 1.83 container won't start against the migrated DB. Symptoms
would be Prisma errors on startup like "column X does not exist" or migration
state mismatches. **This involves DB downtime.**

```bash
aws_region=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
DB_ID="<from pre-flight>"
SNAPSHOT_ID="<from pre-flight>"
RESTORED_ID="${DB_ID}-restored-$(date +%Y%m%d-%H%M)"

# 1. Stop the ECS service so nothing is writing
cd litellm-terraform-stack
LITELLM_ECS_CLUSTER=$(terraform output -raw LitellmEcsCluster)
LITELLM_ECS_TASK=$(terraform output -raw LitellmEcsTask)
cd ..

aws ecs update-service \
  --cluster "$LITELLM_ECS_CLUSTER" \
  --service "$LITELLM_ECS_TASK" \
  --desired-count 0

# 2. Restore the snapshot to a NEW instance (faster + safer than overwriting)
aws rds restore-db-instance-from-db-snapshot \
  --region "$aws_region" \
  --db-instance-identifier "$RESTORED_ID" \
  --db-snapshot-identifier "$SNAPSHOT_ID"

aws rds wait db-instance-available \
  --region "$aws_region" \
  --db-instance-identifier "$RESTORED_ID"

# 3. From here you have two options:
#    (a) Repoint the proxy at $RESTORED_ID by updating the DATABASE_URL secret
#        in Secrets Manager (litellm-terraform-stack/modules/base/secrets-manager.tf
#        — secret_string field). This is the faster path.
#    (b) Rename: stop original, rename restored to the original identifier.
#        More disruptive but keeps every other reference intact.
#
# Path (a) is recommended. Update the secret:

DB_SECRET_ARN=$(aws secretsmanager list-secrets --region "$aws_region" \
  --query "SecretList[?contains(Name, 'litellm') && contains(Name, 'rds')].ARN | [0]" \
  --output text)

NEW_ENDPOINT=$(aws rds describe-db-instances --region "$aws_region" \
  --db-instance-identifier "$RESTORED_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)

# Pull the existing secret to keep username/password the same, swap host
# (manual step — review the JSON before writing it back)
aws secretsmanager get-secret-value \
  --region "$aws_region" \
  --secret-id "$DB_SECRET_ARN" \
  --query SecretString --output text

# After hand-editing the connection string to point at $NEW_ENDPOINT:
# aws secretsmanager put-secret-value \
#   --region "$aws_region" \
#   --secret-id "$DB_SECRET_ARN" \
#   --secret-string '<edited json>'

# 4. Revert .env to v1.83.14-stable.patch.2 and redeploy with the old image
./deploy.sh --skip-build

# 5. Bring the service back up
aws ecs update-service \
  --cluster "$LITELLM_ECS_CLUSTER" \
  --service "$LITELLM_ECS_TASK" \
  --desired-count "$DESIRED_CAPACITY"
```

After Level 3 succeeds, the original (migrated) DB instance is still running
unused. Leave it for a few days as a second safety net, then delete it once
you're confident the restore is healthy.

---

## Post-upgrade cleanup (after a few days of stable operation)

- Delete the manual RDS snapshot if no longer needed:
  ```bash
  aws rds delete-db-snapshot --db-snapshot-identifier "$SNAPSHOT_ID"
  ```
- Delete any orphaned `*-restored-*` instance from a Level 3 rollback.
- Consider a follow-up bump to a newer MINOR (1.85 / 1.86 / 1.87 / 1.88) once
  you're comfortable. Each MINOR has its own behavior-changes section worth
  reading before that next bump.
- The legacy `main-stable` Docker tag stops publishing **2026-06-30**. This
  repo doesn't reference it, but worth knowing if any external tooling does.

---

## Quick reference

| Thing | Value |
|---|---|
| Old version | `v1.83.14-stable.patch.2` |
| New version | `v1.84.6` |
| Files changed | `.env`, `.env.template` |
| Files saved for rollback | `config/config.yaml.pre-1.84.bak` (S3 copy), `config/config.yaml.pre-1.84.bak.local` |
| Rollback image | Already in ECR; no rebuild needed |
| Rollback DB artifact | RDS snapshot `$SNAPSHOT_ID` (record value in pre-flight) |
| Smoke test scripts | `tests/openai_chat_test_file.py`, `test-middleware-synchronous.py`, `test-middleware-streaming.py` |
