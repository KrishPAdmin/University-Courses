#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
exec .venv/bin/uvicorn app:app --host 0.0.0.0 --port 8892 --reload
