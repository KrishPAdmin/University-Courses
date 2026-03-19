#!/usr/bin/env bash
set -euo pipefail
docker rm -f mqserver >/dev/null 2>&1 || true
