#!/usr/bin/env bash
set -euo pipefail
ENV=${1:?usage: apply.sh <dev|qa|prod>}
cd "$(dirname "$0")/.."

if [[ ! -f "${ENV}.tfplan" ]]; then
  echo "No ${ENV}.tfplan found. Run scripts/plan.sh ${ENV} first." >&2
  exit 1
fi

if [[ "$ENV" == "prod" ]]; then
  read -r -p "Type 'prod' to confirm the PROD apply: " answer
  [[ "$answer" == "prod" ]] || { echo "Cancelled."; exit 1; }
fi

terraform apply -input=false "${ENV}.tfplan"
rm -f "${ENV}.tfplan"