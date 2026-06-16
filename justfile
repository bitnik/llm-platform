# TODO run all these in a devcontainer.

# regex matching our encrypted-file naming convention
regex := '.*\.enc\.(ya?ml|json|env|md)$'

# list available recipes
default:
    @just --list

# run pre-commit on all files
[group('lint')]
pre-commit:
    pre-commit run --all-files

# Format every YAML in the repo with yamlfmt.
[group('lint')]
fmt:
    yamlfmt "**/*.{yaml,yml,yamlfmt}"

# encrypt every plaintext *.enc.* file in place (idempotent — skips already-encrypted)
[group('sops')]
encrypt:
    #!/usr/bin/env bash
    set -euo pipefail
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

# decrypt every *.enc.* file in place. WARNING: leaves plaintext on disk
[group('sops')]
decrypt:
    #!/usr/bin/env bash
    set -euo pipefail
    find . -type f -regextype posix-extended -regex '{{regex}}' -print0 \
      | xargs -0 -r -I{} sops decrypt -i {}

# open one file: decrypt -> $EDITOR -> re-encrypt on save
[group('sops')]
edit FILE:
    sops {{FILE}}

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
