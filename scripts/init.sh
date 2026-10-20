#!/usr/bin/env bash
set -euo pipefail
ENV=${1:?usage: init.sh <dev|qa|prod>}
cd "$(dirname "$0")/.."

terraform init -reconfigure -input=false \
  -backend-config="environments/${ENV}.backend.hcl"