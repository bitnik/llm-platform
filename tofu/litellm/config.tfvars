# Desired state of LiteLLM access: teams, users, service accounts.
# To onboard a new team/user/workload, add an entry here and `tofu apply`.
#
# How budgets & limits behave (LiteLLM semantics, checked per request):
# * team / user / key caps are INDEPENDENT — nothing inherits or copies down;
#   the tightest set cap wins.
# * Team caps are a POOL shared by all keys of the team; user caps span all
#   keys of that user; key caps bind that key alone.
# * Unset = unlimited at that level (then the GPU queue is the real limit).
#
# Sizing rationale (single RTX 4000 SFF Ada, devstral 24B AWQ):
# * Budgets are accounting units, not money: the per-token prices in
#   deploy/litellm/deploy.yaml are arbitrary ($0.20/$0.40 per 1M tokens),
#   so $25 ~= 80-125M tokens. They act as runaway kill-switches.
# * tpm/rpm are sized ABOVE what the GPU can serve: they never throttle
#   normal use, they only cut off a runaway loop.

teams = {
  # In-cluster autonomous agents (kagent today).
  agents = {
    models = ["devstral-small-2-24b-awq-4bit"]
    # ~125-250M tokens per 30d at the arbitrary prices; kill-switch, not a quota
    max_budget      = 50
    budget_duration = "30d"
    # pool shared by ALL keys in this team
    tpm_limit = 200000 # ~ a few concurrent agent loops with 10k-token contexts
    rpm_limit = 120    # 2 req/s sustained across the team
    metadata = {
      description = "in-cluster autonomous agents"
    }
  }
  # Humans running local tests / dev tools against the gateway.
  developers = {
    models          = ["devstral-small-2-24b-awq-4bit"]
    max_budget      = 50
    budget_duration = "30d"
    tpm_limit       = 200000
    rpm_limit       = 120
    metadata = {
      description = "human developers, local testing"
    }
  }
}

users = {
  bitnik = {
    email = "ke@bitnik.io"
    team  = "developers"
    key = {
      # budget as backstop only; no key-level tpm/rpm — local tests should be
      # limited by the GPU and the developers team pool, not by the proxy
      max_budget      = 25
      budget_duration = "30d"
      # human keys expire for hygiene. NOTE: expiry is invisible to `tofu
      # plan` — the key just starts failing auth; rotate it with
      # `just tofu apply -replace='litellm_key.user["bitnik"]'`
      duration = "90d"
    }
  }
}

service_accounts = {
  # Autonomy is where runaways happen: keep the agent key tightly bounded.
  kagent = {
    team = "agents"
    # kill-switch: an agent stuck in a loop dies here, not at month's end
    max_budget      = 25
    budget_duration = "30d"
    tpm_limit       = 100000 # ~half the team pool, leaves room for future agents
    rpm_limit       = 60     # 1 req/s sustained; raise if many agents run in parallel
    # matches vLLM concurrency headroom (maxModelLen was lowered to 10000 for this)
    max_parallel_requests = 4
    # no `duration`: an expired key takes kagent down silently (expiry doesn't
    # show up in `tofu plan`) and needs a manual -replace + SOPS re-wire
    metadata = {
      workload  = "kagent"
      namespace = "kagent"
    }
  }
}
