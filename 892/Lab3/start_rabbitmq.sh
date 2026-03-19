#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found"
  exit 1
fi

docker rm -f mqserver >/dev/null 2>&1 || true
docker run -d --name mqserver -p 5672:5672 rabbitmq >/dev/null
docker ps --filter "name=mqserver"
