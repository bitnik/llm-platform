# LiteLLM access management (OpenTofu)

Manages LiteLLM **teams, users, keys, budgets and rate-limits** declaratively with
[OpenTofu](https://opentofu.org/) and the
[`ncecere/litellm`](https://search.opentofu.org/provider/ncecere/litellm/latest) provider.

The model is data-driven:

| Data (in [`config.tfvars`](config.tfvars)) | Resource | Purpose |
|---|---|---|
| `teams` | `litellm_team` | budget / rate-limit envelope per group |
| `users` | `litellm_user` + `litellm_team_member` + `litellm_key` | human: identity + team membership + personal key |
| `service_accounts` | `litellm_key` (team-owned, `service_account_id`) | machine identity (kagent, CI, ...) |

**Onboarding a new team, user or workload = adding one entry to
`config.tfvars` and running `tofu apply`.**
Key aliases are global in LiteLLM, so names must be unique across
`users` and `service_accounts`.

Limits layer as: team envelope (a pool **shared** by all keys in the team) →
user envelope (across all of a user's keys) → per-key budget / tpm / rpm /
parallelism. The levels are independent caps, not inheritance: an unset key
limit is not assigned the team's value — the request is simply uncapped at the
key level but still counts against the user and team pools; the tightest set
cap wins, and unset everywhere = unlimited (the GPU queue becomes the limit).
Keys without an explicit `models` list follow the team's model list
automatically (`all-team-models`).

## Prerequisites

* [`tofu`](https://opentofu.org/docs/intro/install/) >= 1.8
* Cluster access (`kubectl`) to read the master key, or the values by other means.

## Usage

The provider authenticates via environment variables (no secrets in code),
and the state passphrase comes from a variable:

```sh
just tofu init
just tofu plan
just tofu apply
```

### Reading the generated keys

```sh
# Sensitive
just tofu output keys
just tofu output -json keys | jq -r .bitnik

just tofu output team_ids
```

### Wiring the kagent key into the cluster

kagent reads its key from the SOPS-encrypted `kagent-openai` secret:

```sh
just tofu output -json keys | jq -r .kagent
# paste it as OPENAI_API_KEY in:
just edit deploy/kagent/api-key.enc.yaml
# commit + push, then:
flux reconcile kustomization deploy --with-source
# kubectl -n kagent rollout restart deployment
```

## Validation

```sh
just tofufmt check
# after init
just tofu validate
just tofu plan

# smoke test a generated key end-to-end
LITELLM_API_KEY_USER=$(just tofu output -json keys | jq -r .bitnik)
LITELLM_API_BASE=$(just extract tofu/litellm/config.enc.tfvars litellm_api_base)
curl -s "$LITELLM_API_BASE/v1/chat/completions" -H "Authorization: Bearer $LITELLM_API_KEY_USER" \
  -H 'content-type: application/json' \
  -d '{"model":"devstral-small-2-24b-awq-4bit","max_tokens":50,"messages":[{"role":"user","content":"reply with one short sentence"}]}' | jq

# inspect budgets / limits as LiteLLM sees them (master key required)
curl -s "$LITELLM_API_BASE/key/info" -H "Authorization: Bearer $LITELLM_API_KEY_USER" | jq .info
# curl -s "$LITELLM_API_BASE/team/list" -H "Authorization: Bearer $LITELLM_API_KEY_USER" | jq
curl -s "$LITELLM_API_BASE/user/info?user_id=bitnik" -H "Authorization: Bearer $LITELLM_API_KEY_USER" | jq

# rate-limit check: exceed rpm_limit and expect HTTP 429s
for i in $(seq 1 70); do
  curl -s -o /dev/null -w "%{http_code}\n" "$LITELLM_API_BASE/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_API_KEY_USER" -H 'content-type: application/json' \
    -d '{"model":"devstral-small-2-24b-awq-4bit","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' &
done | sort | uniq -c
```

## State and Backend

The state contains the generated API keys, so
[state encryption](https://opentofu.org/docs/language/state/encryption/) is
**enabled and enforced** for both state and saved plan files.
Losing the passphrase makes the state unreadable. Everything would need re-import.

The state is stored **in the K3s cluster** via the `kubernetes` backend.

```sh
kubectl -n litellm get secret tfstate-default-litellm-tofu
```

For implementation details, see [`versions.tf`](versions.tf).

## Notes

* Users are created with `auto_create_key = false`: keys are managed explicitly
  as `litellm_key` resources so they can carry their own budgets/limits and be
  rotated independently of the user.
* Key expiry/rotation:
  * Keys are only rotated when the resource is replaced, e.g.
    `tofu -chdir=tofu/litellm apply -replace='litellm_key.service_account["kagent"]'`.
  * Key expiry (`duration`) is invisible to `tofu plan`: an expired key stays in
    state unchanged and simply starts failing auth. Rotation is the same
    `-replace` — which is why service-account keys have no `duration` (a silent
    kagent outage) while human keys expire for hygiene.
