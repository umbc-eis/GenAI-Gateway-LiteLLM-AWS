# Operating notes for this deployment

State that a fresh clone plus `terraform apply` does **not** reproduce. `.env` is
gitignored and some settings are stored in the database rather than in
`config/config.yaml`; this file records what is different and why.

Security gaps and their remediation are tracked privately, not here.

## Settings held in the database, not in config.yaml

`config/config.yaml` has **no `general_settings` block**. All of it lives in the
`LiteLLM_Config` table under `param_name = 'general_settings'`, which keeps it editable
from the Admin UI by every administrator without sharing values in a committed file.

Precedence matters. `litellm/proxy/config_resolvers/settings_rules.py` resolves
`general_settings` as *config wins*: any key `config.yaml` declares becomes
config-owned, can no longer be changed from the UI, and the stored value is ignored.
So **adding a `general_settings` block to `config.yaml` silently freezes whichever
keys it names.** Prefer the database for this section.

The proxy re-reads database config every `PROXY_CONFIG_RELOAD_INTERVAL_SECONDS`
(default 30), so database-side changes take effect without a restart or deploy.

| Key | Value | Set |
|---|---|---|
| `disable_env_credential_login` | `true` | 2026-10-01 |

**Re-apply these after standing up any new environment** — they are not in version
control and a fresh deploy does not set them. `disable_env_credential_login` turns off
UI sign-in with the environment credentials; database users with their own passwords
are unaffected, and the master key keeps working over the API either way.

## Sizing that differs from `.env.template`

`.env` is gitignored, so these are invisible to a clone. `.env.template` intentionally
keeps the smaller upstream defaults for a fresh deploy.

| Setting | `.env.template` | Production |
|---|---|---|
| `RDS_ALLOCATED_STORAGE_GB` | 20 | **100** |
| `RDS_INSTANCE_CLASS` | db.t3.small | db.t3.medium |

RDS storage **autoscaling is intentionally off** (`max_allocated_storage` is unset in
`litellm-terraform-stack/modules/base/rds.tf`). Storage is a fixed 100 GB with no
safety net, so watch `FreeStorageSpace`. AWS will not accept another storage change
within ~6 hours of the last one, so size in one step rather than nudging upward.

Spend logs are retained for **at least a year** (deliberate, for billing and audit),
and no retention policy is set.

## Junk rows in the daily spend tables

LiteLLM writes a row to `LiteLLM_DailyUserSpend` and `LiteLLM_DailyTeamSpend` for
every *failed* request, including ones rejected for an invalid API key, and each
distinct bad key becomes its own row. A key-guessing burst therefore inflates these
tables by one row per attempt. The Usage page aggregates them, so enough junk makes
it time out and fall back to fetching hundreds of pages one by one.

That happened in September–October 2026 and the junk was deleted on 2026-10-13. The
WAF rule `RateLimit-ModelsList` (`modules/base/waf.tf`) now throttles the endpoint the
traffic used. If junk builds up again, this predicate removes it and nothing else:

```sql
-- known keys: every key ever issued, live or deleted
WITH known AS (
  SELECT token FROM "LiteLLM_VerificationToken" WHERE token IS NOT NULL
  UNION
  SELECT token FROM "LiteLLM_DeletedVerificationToken" WHERE token IS NOT NULL)
DELETE FROM "LiteLLM_DailyUserSpend" s       -- and the same for "LiteLLM_DailyTeamSpend"
WHERE s.spend = 0
  AND s.successful_requests = 0
  AND s.date < to_char(current_date, 'YYYY-MM-DD')
  AND NOT EXISTS (SELECT 1 FROM known k WHERE k.token = s.api_key);
```

Snapshot first, run it in a transaction, and confirm that `SUM(spend)` and
`SUM(successful_requests)` are unchanged before committing. Do **not** drop the
`spend = 0` / `successful_requests = 0` conditions: unknown-key rows that carry real
spend exist (most likely master-key traffic, which has no virtual-key row). Run it
the way UPGRADING.md describes one-off database access.
