output "team_ids" {
  description = "LiteLLM team IDs by team alias."
  value       = { for name, team in litellm_team.this : name => team.id }
}

output "keys" {
  description = "Generated API keys by alias (users + service accounts)."
  sensitive   = true
  value = merge(
    { for name, key in litellm_key.user : name => key.key },
    { for name, key in litellm_key.service_account : name => key.key },
  )
}
