#!/usr/bin/env bash
# Copy central gen config (.speakeasy/gen/*.yaml) into api/<lang>/.speakeasy/gen.yaml
# so Speakeasy CLI finds config in each target output dir. Run before speakeasy run.
# Usage: ./scripts/sync-gen-to-output.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

for lang in go typescript python mcp; do
  src=".speakeasy/gen/${lang}.yaml"
  dest_dir="api/${lang}/.speakeasy"
  if [ -f "$src" ]; then
    mkdir -p "$dest_dir"
    cp "$src" "$dest_dir/gen.yaml"
    echo "Copied $src -> $dest_dir/gen.yaml"
  fi
done

# Also sync to custom output paths defined in workflow.yaml (e.g. ../flexprice-go)
if [ -f ".speakeasy/workflow.yaml" ]; then
  while IFS= read -r line; do
    output_path="${line#*output: }"
    if [[ "$output_path" != api/* ]]; then
      dest_dir="${output_path}/.speakeasy"
      if [ -d "$output_path" ] && [ -f ".speakeasy/gen/go.yaml" ]; then
        mkdir -p "$dest_dir"
        cp ".speakeasy/gen/go.yaml" "$dest_dir/gen.yaml"
        echo "Copied .speakeasy/gen/go.yaml -> $dest_dir/gen.yaml"
      fi
    fi
  done < <(grep "output:" .speakeasy/workflow.yaml)
fi

echo "Synced central gen to output/.speakeasy/gen.yaml"
