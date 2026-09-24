#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

exec python3 -B "$script_dir/mee2-93-hosted-proof.py" proof "$@"
