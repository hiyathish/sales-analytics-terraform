#!/usr/bin/env bash
set -euo pipefail
ENV=${1:?usage: plan.sh <dev|qa|prod>}
cd "$(dirname "$0")/.."

scripts/checks.sh
terraform plan -input=false \
  -var-file="environments/${ENV}.tfvars" \
  -out="${ENV}.tfplan"
terraform show -no-color "${ENV}.tfplan" > "${ENV}.plan.txt"

echo "Plan saved. Review ${ENV}.plan.txt, then run: scripts/apply.sh ${ENV}"