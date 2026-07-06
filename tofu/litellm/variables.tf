variable "state_encrypt_passphrase" {
  description = <<-EOT
    Passphrase for OpenTofu state/plan encryption (min 16 characters).
    Provide via `export TF_VAR_state_encrypt_passphrase=...`.
    Losing it makes the state unreadable (resources would need re-import).
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_encrypt_passphrase) >= 16
    error_message = "state_encrypt_passphrase must be at least 16 characters (pbkdf2 requirement)."
  }
}

variable "litellm_api_base" {
  description = "Base URL for the LiteLLM API."
  type        = string
  sensitive   = true
}

variable "litellm_api_key" {
  description = "API key for the LiteLLM API."
  type        = string
  sensitive   = true
}

variable "kube_config_path" {
  description = "Path to the kubeconfig file. Needed for kubernetes backend."
  type        = string
  sensitive   = true
}

# https://search.opentofu.org/provider/ncecere/litellm/latest
# All access to the gateway is declared as data in config.tfvars:
#   teams            -> litellm_team (budget / rate-limit envelope)
#   users            -> litellm_user + litellm_team_member + a personal litellm_key
#   service_accounts -> a team-owned litellm_key (machine identity, no human user)
# Onboarding a new team/user/workload = adding one entry there.
#
# Budget/limit semantics (LiteLLM, enforced per request): team / user / key
# caps are independent — nothing inherits, the tightest set cap wins. Team
# caps are a pool shared by all the team's keys; user caps span all keys of
# that user; key caps bind one key. Unset = unlimited at that level.
variable "teams" {
  description = "LiteLLM teams keyed by team alias."
  type = map(object({
    # LLM model names (as exposed by the LiteLLM proxy) this team may use.
    models = list(string)
    # Budget in USD per budget_duration (costs are the arbitrary per-token
    # prices set in the litellm model_list; useful for relative usage tracking).
    max_budget      = optional(number)
    budget_duration = optional(string) # e.g. "30d", "7d", "24h"
    # Team-wide rate limits (shared by all keys in the team).
    tpm_limit = optional(number) # tokens per minute
    rpm_limit = optional(number) # requests per minute
    metadata  = optional(map(string), {})
  }))
  default = {}
}

variable "users" {
  description = <<-EOT
    Human users keyed by user id. Each user is created as a LiteLLM internal user,
    becomes a member of one team, and gets one personal API key (key_alias = user id).
    Limits layer as team -> user (all keys of the user) -> key; unset levels don't constrain.
  EOT
  type = map(object({
    email = string
    alias = optional(string) # human-readable display name
    team  = string           # key into var.teams
    # Global proxy role: internal_user | internal_user_viewer | proxy_admin | proxy_admin_viewer
    user_role = optional(string, "internal_user")
    # Role within the team: user | admin. NOTE: "admin" (team admin) requires
    # a LiteLLM Enterprise license — the API rejects it on OSS.
    team_role = optional(string, "user")
    # Budget for this member inside the team budget.
    max_budget_in_team = optional(number)
    # User-level envelope, applies across all of the user's keys.
    max_budget      = optional(number)
    budget_duration = optional(string)
    tpm_limit       = optional(number)
    rpm_limit       = optional(number)
    key = optional(object({
      # null -> all team models ("all-team-models")
      models                = optional(list(string))
      max_budget            = optional(number)
      budget_duration       = optional(string)
      tpm_limit             = optional(number)
      rpm_limit             = optional(number)
      max_parallel_requests = optional(number)
      # Key lifetime, e.g. "90d". null -> non-expiring.
      duration = optional(string)
    }), {})
  }))
  default = {}
}

variable "service_accounts" {
  description = <<-EOT
    Machine identities (in-cluster workloads, CI, ...) keyed by name.
    Each gets one team-owned service-account API key (service_account_id = key_alias = name),
    not attached to a human user.
    Names must not collide with user ids: key aliases are global in LiteLLM.
  EOT
  type = map(object({
    team = string # key into var.teams
    # null -> all team models ("all-team-models")
    models                = optional(list(string))
    max_budget            = optional(number)
    budget_duration       = optional(string)
    tpm_limit             = optional(number)
    rpm_limit             = optional(number)
    max_parallel_requests = optional(number)
    metadata              = optional(map(string), {})
    # Key lifetime, e.g. "90d". null -> non-expiring.
    duration = optional(string)
  }))
  default = {}
}
