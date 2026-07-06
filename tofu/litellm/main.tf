# Teams: the budget / rate-limit envelope everything else hangs off.
resource "litellm_team" "this" {
  for_each = var.teams

  team_alias      = each.key
  models          = each.value.models
  max_budget      = each.value.max_budget
  budget_duration = each.value.budget_duration
  tpm_limit       = each.value.tpm_limit
  rpm_limit       = each.value.rpm_limit
  metadata        = each.value.metadata

  # model_aliases = {
  #   "fast" = "gpt-4o-mini"
  # }
  # model_rpm_limit = {
  #   "gpt-4o" = 500
  # }
  # model_tpm_limit = {
  #   "gpt-4o" = 50000
  # }
}

# Humans: the internal user (identity, global role, user-level envelope)
# https://docs.litellm.ai/docs/proxy/user_management_heirarchy
resource "litellm_user" "this" {
  for_each = var.users

  user_id    = each.key
  user_alias = each.value.alias
  user_email = each.value.email
  user_role  = each.value.user_role

  max_budget      = each.value.max_budget
  budget_duration = each.value.budget_duration
  tpm_limit       = each.value.tpm_limit
  rpm_limit       = each.value.rpm_limit

  # keys are managed explicitly below
  # If true, gives you zero control over the generated key: no per-key budget, tpm/rpm, max_parallel_requests, team attribution, or metadata. It's just "a key".
  auto_create_key = false

  metadata = {
    managed_by = "opentofu"
  }
}
# and their team membership
resource "litellm_team_member" "this" {
  for_each = var.users

  team_id            = litellm_team.this[each.value.team].id
  user_id            = litellm_user.this[each.key].id
  user_email         = each.value.email
  role               = each.value.team_role
  max_budget_in_team = each.value.max_budget_in_team
}
# and plus one personal key each, attributed to user + team.
resource "litellm_key" "user" {
  for_each = var.users

  key_alias = each.key
  user_id   = litellm_user.this[each.key].id
  team_id   = litellm_team.this[each.value.team].id
  # null -> provider sends "all-team-models": the key follows the team's model list
  models = each.value.key.models

  max_budget            = each.value.key.max_budget
  budget_duration       = each.value.key.budget_duration
  tpm_limit             = each.value.key.tpm_limit
  rpm_limit             = each.value.key.rpm_limit
  max_parallel_requests = each.value.key.max_parallel_requests
  duration              = each.value.key.duration

  metadata = {
    managed_by = "opentofu"
    owner      = each.value.email
  }

  depends_on = [litellm_team_member.this]
}

# Machines: one team-owned service-account key per workload,
# no human user attached (key_alias defaults to service_account_id).
resource "litellm_key" "service_account" {
  for_each = var.service_accounts

  service_account_id = each.key
  team_id            = litellm_team.this[each.value.team].id
  # null -> provider sends "all-team-models": the key follows the team's model list
  models = each.value.models

  max_budget            = each.value.max_budget
  budget_duration       = each.value.budget_duration
  tpm_limit             = each.value.tpm_limit
  rpm_limit             = each.value.rpm_limit
  max_parallel_requests = each.value.max_parallel_requests
  duration              = each.value.duration

  metadata = merge(
    { managed_by = "opentofu" },
    each.value.metadata,
  )
}
