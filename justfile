# TODO run all these in a devcontainer.

# regex matching our encrypted-file naming convention
regex := '.*\.enc\.(ya?ml|json|env|md|tfvars)$'

# list available recipes
default:
    @just --list

# run pre-commit on all files
[group('lint')]
pre-commit:
    pre-commit run --all-files

# Format every YAML in the repo with yamlfmt.
[group('lint')]
yamlfmt:
    yamlfmt "**/*.{yaml,yml,yamlfmt}"

# Format tf files. Set Check to "true" to run in check mode.
[group('lint')]
tofufmt CHECK="":
    #!/usr/bin/env bash
    set -euo pipefail
    check_flag=""
    if [[ "{{CHECK}}" = "check" || "{{CHECK}}" = "true" ]]; then
      check_flag="-check"
    fi
    echo "tofufmt $check_flag"
    find . -type f \( -name '*.tf' -o -name '*.tfvars' \) \
      ! -name 'config.enc.tfvars' \
      -print0 | xargs -0 -n1 tofu fmt $check_flag

# encrypt a single FILE or every plaintext *.enc.* file in place (idempotent — skips already-encrypted)
[group('sops')]
encrypt FILE="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{FILE}}" ]; then
      echo "encrypting: all files"
      n=0
      while IFS= read -r -d '' f; do
        if grep -q 'ENC\[' "$f"; then
          echo "skip (already encrypted): $f"
        else
          kind=$(yq eval '.kind' "$f" 2>/dev/null || echo "none")
          if [[ "$kind" == "Secret" || "$kind" == "ConfigMap" ]]; then
            echo "encrypting $kind: $f"; sops encrypt --encrypted-regex '^(data|stringData)$' -i "$f"; n=$((n+1))
          else
            echo "encrypting: $f"; sops encrypt -i "$f"; n=$((n+1))
          fi
        fi
      done < <(find . -type f -regextype posix-extended -regex '{{regex}}' -print0)
      echo "encrypted $n file(s)."
    else
      echo "encrypting: {{FILE}}"
      if grep -q 'ENC\[' "{{FILE}}"; then
        echo "skip (already encrypted): {{FILE}}"
      else
        sops encrypt -i "{{FILE}}"
      fi
    fi

# decrypt a single FILE or every *.enc.* file in place. WARNING: leaves plaintext on disk
[group('sops')]
decrypt FILE="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{FILE}}" ]; then
      echo "decrypting: all files"
      n=0
      while IFS= read -r -d '' f; do
        if grep -q 'ENC\[' "$f"; then
          echo "decrypting: $f"; sops decrypt -i "$f"; n=$((n+1))
        else
          echo "skip (already decrypted): $f"
        fi
      done < <(find . -type f -regextype posix-extended -regex '{{regex}}' -print0)
      echo "decrypted $n file(s)."
    else
      if grep -q 'ENC\[' "{{FILE}}"; then
        echo "decrypting: {{FILE}}"
        sops decrypt -i "{{FILE}}"
      else
        echo "skip (already decrypted): {{FILE}}"
      fi
    fi

# open one file: decrypt -> $EDITOR -> re-encrypt on save
[group('sops')]
edit FILE:
    sops {{FILE}}

# Extract a value from a encrypted .tfvars or .yaml file using grep/yq. Ex: `just extract deploy/litellm/config.enc.yaml '.stringData["values.yaml"]'` or `just extract tofu/litellm/config.enc.tfvars kube_config_path`.
[group('sops')]
extract FILE KEY:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "{{FILE}}" == *.tfvars ]]; then
      sops decrypt "{{FILE}}" | grep '^{{KEY}}' | sed -E 's/^[^=]+=\s*//' | tr -d '"'
    elif [[ "{{FILE}}" == *.yaml ]]; then
      sops decrypt "{{FILE}}" | yq '{{KEY}}' | sed -E 's/^[^=]+=\s*//'
    else
      echo "Supports .tfvars and .yaml file types only. Got: {{FILE}}"
      exit 1
    fi

# verify ALL *.enc.* files are encrypted; non-zero exit if any plaintext
[group('sops')]
check:
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    while IFS= read -r -d '' f; do
        grep -q 'ENC\[' "$f" || { echo "PLAINTEXT: $f"; fail=1; }
    done < <(find . -type f -regextype posix-extended -regex '{{regex}}' -print0)
    [ "$fail" -eq 0 ] && echo "all encrypted ✓"
    exit $fail

# # re-apply .sops.yaml recipients to all files (run after adding/removing a teammate)
# updatekeys:
#     #!/usr/bin/env bash
#     set -euo pipefail
#     find . -type f -regextype posix-extended -regex '{{regex}}' -print0 \
#       | xargs -0 -r -I{} sops updatekeys -y {}

# # rotate one file's data key (use after removing a recipient / suspected leak)
# rotate FILE:
#     sops rotate -i {{FILE}}

# # one-time per clone: install the git pre-commit hook
# setup:
#     pre-commit install

# run tofu against the LiteLLM workspace.
[group('tofu')]
tofu +CMD="plan":
    #!/usr/bin/env bash
    set -euo pipefail
    # echo "tofu {{CMD}}"
    export KUBE_CONFIG_PATH=$(just extract tofu/litellm/config.enc.tfvars kube_config_path)
    # echo "KUBE_CONFIG_PATH: $KUBE_CONFIG_PATH"
    if [[ "{{CMD}}" == init ]]; then
        sops exec-file tofu/litellm/config.enc.tfvars 'tofu -chdir=tofu/litellm {{CMD}} -var-file={} -var-file=config.tfvars'
    elif [[ "{{CMD}}" == plan ]]; then
        sops exec-file tofu/litellm/config.enc.tfvars 'tofu -chdir=tofu/litellm {{CMD}} -var-file={} -var-file=config.tfvars -out=tfplan'
    elif [[ "{{CMD}}" == apply ]]; then
        export TF_VAR_state_encrypt_passphrase=$(just extract tofu/litellm/config.enc.tfvars state_encrypt_passphrase)
        tofu -chdir=tofu/litellm {{CMD}} "tfplan"
    else
        export TF_VAR_state_encrypt_passphrase=$(just extract tofu/litellm/config.enc.tfvars state_encrypt_passphrase)
        tofu -chdir=tofu/litellm {{CMD}}
    fi
