#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate

if command -v tflint >/dev/null 2>&1; then
  tflint
else
  echo "tflint not installed, skipping"
fi