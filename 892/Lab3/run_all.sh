#!/usr/bin/env bash
set -euo pipefail

VENV_DIR=".venv892"
HOST="${HOST:-localhost:50051}"

if [[ ! -d "$VENV_DIR" ]]; then
  echo "missing venv: $VENV_DIR"
  exit 1
fi

source "$VENV_DIR/bin/activate"

./start_rabbitmq.sh >/dev/null 2>&1 || true
sleep 0.4

python3 ground_control.py --host 0.0.0.0:50051 > output/ground_control.log 2>&1 &
GC_PID=$!
sleep 0.6

python3 deminer.py 1 > output/deminer_1.log 2>&1 &
D1_PID=$!
sleep 0.2

python3 deminer.py 2 > output/deminer_2.log 2>&1 &
D2_PID=$!
sleep 0.2

PIDS=()
for i in $(seq 1 10); do
  python3 rover.py "$i" --host "$HOST" > "output/rover_${i}.log" 2>&1 &
  PIDS+=("$!")
  sleep 0.1
done

FAIL=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAIL=1
done

sleep 0.6

kill "$D1_PID" "$D2_PID" "$GC_PID" >/dev/null 2>&1 || true

echo ""
echo "Defused mine log:"
if [[ -f output/defused_mines.log ]]; then
  tail -n 50 output/defused_mines.log
else
  echo "output/defused_mines.log not found"
fi

exit "$FAIL"
