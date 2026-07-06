terraform {
  required_version = ">= 1.8.0"

  required_providers {
    # https://search.opentofu.org/provider/ncecere/litellm/latest
    litellm = {
      source  = "ncecere/litellm"
      version = "2.0.1"
    }
  }


  # State lives in the K3s cluster as Secret litellm/tfstate-default-litellm-tofu,
  # encrypted client-side with the passphrase above before upload.
  backend "kubernetes" {
    secret_suffix = "litellm-tofu"
    namespace     = "litellm"
    # Pass this via KUBE_CONFIG_PATH env var.
    # config_path   = var.kube_config_path
  }
  # https://opentofu.org/docs/language/state/encryption/
  encryption {
    key_provider "pbkdf2" "passphrase" {
      passphrase = var.state_encrypt_passphrase
    }
    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.passphrase
    }
    state {
      method   = method.aes_gcm.default
      enforced = true
      # fallback {
      #   method = method.unencrypted.migrate
      # }
    }
    plan {
      method   = method.aes_gcm.default
      enforced = true
    }
  }
}
