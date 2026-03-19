#!/usr/bin/env bash
set -euo pipefail

PY="${PYTHON_BIN:-python3}"
VENV_DIR=".venv892"

mkdir -p input/commands
mkdir -p output

cat > rover.proto <<'EOF'
syntax = "proto3";

package rover;

service GroundControl {
  rpc GetMap(MapRequest) returns (MapReply);
  rpc GetCommandStream(CommandRequest) returns (stream Command);
  rpc GetMineSerialNumber(MineSerialRequest) returns (MineSerialReply);
}

message MapRequest {
  int32 rover_id = 1;
}

message MapReply {
  string json_map = 1;
  int32 width = 2;
  int32 height = 3;
}

message CommandRequest {
  int32 rover_id = 1;
}

message Command {
  string cmd = 1;
}

message MineSerialRequest {
  string mine_id = 1;
}

message MineSerialReply {
  bool found = 1;
  string serial = 2;
}
EOF

cat > requirements.txt <<'EOF'
grpcio
grpcio-tools
pika
EOF

cat > input/map.txt <<'EOF'
[
  [0, 0, 0, 0, 0],
  [0, 1, 0, 0, 0],
  [0, 0, 0, 2, 0],
  [0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0]
]
EOF

cat > input/mines.txt <<'EOF'
1 SN-000001
2 SN-000002
EOF

for i in $(seq 1 10); do
  cat > "input/commands/commands_${i}.txt" <<'EOF'
E E S S W N E S
EOF
done

cat > ground_control.py <<'EOF'
#!/usr/bin/env python3
# COE892 Lab 3: Ground Control (gRPC + RabbitMQ)
import argparse
import ast
import json
import logging
import os
import threading
import time
from concurrent import futures
from typing import Any, Dict, List, Tuple

import grpc
import pika

import rover_pb2
import rover_pb2_grpc

LOG = logging.getLogger("ground_control")

DEMINE_QUEUE = "Demine-Queue"
DEFUSED_EXCHANGE = "Defused-Mines"
DEFUSED_QUEUE = "Defused-Mines-Log"


def load_map_file(map_path: str) -> List[List[Any]]:
    raw = ""
    with open(map_path, "r", encoding="utf-8") as f:
        raw = f.read().strip()
    if not raw:
        raise ValueError("map file is empty")
    if raw.lstrip().startswith("["):
        grid = ast.literal_eval(raw)
        if not isinstance(grid, list):
            raise ValueError("map literal is not a list")
        return grid
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    grid: List[List[Any]] = []
    for ln in lines:
        parts = [p.strip() for p in ln.replace(",", " ").split() if p.strip()]
        row: List[Any] = []
        for p in parts:
            if p.lstrip("-").isdigit():
                row.append(int(p))
            else:
                row.append(p)
        grid.append(row)
    return grid


def normalize_grid(grid: List[List[Any]]) -> Tuple[List[List[Any]], int, int]:
    height = len(grid)
    width = 0
    for r in grid:
        if isinstance(r, list):
            width = max(width, len(r))
    norm: List[List[Any]] = []
    for r in grid:
        row = list(r) if isinstance(r, list) else [r]
        if len(row) < width:
            row.extend([0] * (width - len(row)))
        norm.append(row)
    return norm, width, height


def load_mines_file(mines_path: str) -> Dict[str, str]:
    mines: Dict[str, str] = {}
    with open(mines_path, "r", encoding="utf-8") as f:
        for ln in f:
            s = ln.strip()
            if not s or s.startswith("#"):
                continue
            parts = [p.strip() for p in s.replace(",", " ").split() if p.strip()]
            if len(parts) >= 2:
                mines[str(parts[0])] = str(parts[1])
            elif len(parts) == 1:
                mines[str(parts[0])] = str(parts[0])
    return mines


def load_commands_for_rover(commands_dir: str, template: str, rover_id: int) -> List[str]:
    fname = template.format(rover_id=rover_id)
    path = os.path.join(commands_dir, fname)
    if not os.path.exists(path):
        return []
    raw = ""
    with open(path, "r", encoding="utf-8") as f:
        raw = f.read().strip()
    if not raw:
        return []
    tokens: List[str] = []
    for ln in raw.splitlines():
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        if "," in s:
            tokens.extend([t.strip() for t in s.split(",") if t.strip()])
        else:
            tokens.extend([t for t in s.split() if t.strip()])
    if len(tokens) == 1 and len(tokens[0]) > 1:
        maybe = tokens[0].strip()
        if all(ch.isalpha() for ch in maybe):
            tokens = list(maybe)
    cleaned: List[str] = []
    for t in tokens:
        c = t.strip().upper()
        if c in {"D", "DIG", "DIGGING"}:
            continue
        cleaned.append(c)
    return cleaned


class GroundControlService(rover_pb2_grpc.GroundControlServicer):
    def __init__(self, grid: List[List[Any]], width: int, height: int, mines: Dict[str, str], commands_dir: str, commands_template: str, stream_delay_s: float):
        self._grid = grid
        self._width = width
        self._height = height
        self._mines = mines
        self._commands_dir = commands_dir
        self._commands_template = commands_template
        self._stream_delay_s = stream_delay_s

    def GetMap(self, request: rover_pb2.MapRequest, context: grpc.ServicerContext) -> rover_pb2.MapReply:
        payload = json.dumps(self._grid)
        return rover_pb2.MapReply(json_map=payload, width=self._width, height=self._height)

    def GetCommandStream(self, request: rover_pb2.CommandRequest, context: grpc.ServicerContext):
        cmds = load_commands_for_rover(self._commands_dir, self._commands_template, request.rover_id)
        for c in cmds:
            yield rover_pb2.Command(cmd=c)
            time.sleep(self._stream_delay_s)

    def GetMineSerialNumber(self, request: rover_pb2.MineSerialRequest, context: grpc.ServicerContext) -> rover_pb2.MineSerialReply:
        mine_id = str(request.mine_id)
        serial = self._mines.get(mine_id, "")
        return rover_pb2.MineSerialReply(found=bool(serial), serial=serial)


def rabbitmq_defused_listener(mq_host: str, mq_port: int, log_path: str, stop_evt: threading.Event):
    params = pika.ConnectionParameters(host=mq_host, port=mq_port, heartbeat=30, blocked_connection_timeout=30)
    conn = pika.BlockingConnection(params)
    ch = conn.channel()
    ch.exchange_declare(exchange=DEFUSED_EXCHANGE, exchange_type="fanout", durable=True)
    ch.queue_declare(queue=DEFUSED_QUEUE, durable=True)
    ch.queue_bind(queue=DEFUSED_QUEUE, exchange=DEFUSED_EXCHANGE)

    def on_msg(channel, method, properties, body: bytes):
        msg = body.decode("utf-8", errors="replace")
        try:
            obj = json.loads(msg)
        except Exception:
            obj = {"raw": msg}
        line = json.dumps(obj, ensure_ascii=False)
        LOG.info("defused_mine=%s", line)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        channel.basic_ack(delivery_tag=method.delivery_tag)

    ch.basic_qos(prefetch_count=25)
    ch.basic_consume(queue=DEFUSED_QUEUE, on_message_callback=on_msg, auto_ack=False)

    while not stop_evt.is_set():
        conn.process_data_events(time_limit=0.5)
        time.sleep(0.05)

    try:
        conn.close()
    except Exception:
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0:50051")
    parser.add_argument("--map_file", default="input/map.txt")
    parser.add_argument("--mines_file", default="input/mines.txt")
    parser.add_argument("--commands_dir", default="input/commands")
    parser.add_argument("--commands_template", default="commands_{rover_id}.txt")
    parser.add_argument("--mq_host", default="localhost")
    parser.add_argument("--mq_port", type=int, default=5672)
    parser.add_argument("--defused_log", default="output/defused_mines.log")
    parser.add_argument("--max_workers", type=int, default=10)
    parser.add_argument("--stream_delay_s", type=float, default=0.01)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    grid_raw = load_map_file(args.map_file)
    grid, width, height = normalize_grid(grid_raw)
    mines = load_mines_file(args.mines_file)

    LOG.info("map_loaded width=%d height=%d mines=%d", width, height, len(mines))

    stop_evt = threading.Event()
    t = threading.Thread(target=rabbitmq_defused_listener, args=(args.mq_host, args.mq_port, args.defused_log, stop_evt), daemon=True)
    t.start()

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=args.max_workers))
    rover_pb2_grpc.add_GroundControlServicer_to_server(GroundControlService(grid, width, height, mines, args.commands_dir, args.commands_template, args.stream_delay_s), server)
    server.add_insecure_port(args.host)
    server.start()
    LOG.info("grpc_listening host=%s", args.host)

    try:
        while True:
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass

    stop_evt.set()
    try:
        server.stop(grace=2)
    except Exception:
        pass


if __name__ == "__main__":
    main()
EOF

cat > rover.py <<'EOF'
#!/usr/bin/env python3
# COE892 Lab 3: Rover (gRPC client + RabbitMQ publisher)
import argparse
import json
import logging
import time
from typing import Any, Dict, List, Optional, Set, Tuple

import grpc
import pika

import rover_pb2
import rover_pb2_grpc

LOG = logging.getLogger("rover")

DEMINE_QUEUE = "Demine-Queue"


def normalize_command(cmd: str) -> Optional[str]:
    c = cmd.strip().upper()
    if not c:
        return None
    if c in {"D", "DIG", "DIGGING"}:
        return None
    mapping = {
        "NORTH": "N",
        "SOUTH": "S",
        "EAST": "E",
        "WEST": "W",
        "UP": "N",
        "DOWN": "S",
        "LEFT": "W",
        "RIGHT": "E",
        "U": "N",
        "L": "W",
        "R": "E",
    }
    return mapping.get(c, c)


def move_xy(x: int, y: int, cmd: str, width: int, height: int) -> Tuple[int, int]:
    nx, ny = x, y
    if cmd == "N":
        ny -= 1
    elif cmd == "S":
        ny += 1
    elif cmd == "W":
        nx -= 1
    elif cmd == "E":
        nx += 1
    if nx < 0 or ny < 0 or nx >= width or ny >= height:
        return x, y
    return nx, ny


def cell_to_mine_id(cell: Any, x: int, y: int) -> Optional[str]:
    if cell is None:
        return None
    if isinstance(cell, int):
        if cell == 0:
            return None
        return str(cell)
    s = str(cell).strip()
    if not s:
        return None
    if s in {"0", ".", "EMPTY"}:
        return None
    if s.lstrip("-").isdigit():
        if int(s) == 0:
            return None
        return str(int(s))
    if s.upper() in {"M", "MINE"}:
        return f"{x},{y}"
    return s


def publish_task(mq_host: str, mq_port: int, task: Dict[str, Any]):
    params = pika.ConnectionParameters(host=mq_host, port=mq_port, heartbeat=30, blocked_connection_timeout=30)
    conn = pika.BlockingConnection(params)
    ch = conn.channel()
    ch.queue_declare(queue=DEMINE_QUEUE, durable=True)
    body = json.dumps(task, ensure_ascii=False).encode("utf-8")
    ch.basic_publish(exchange="", routing_key=DEMINE_QUEUE, body=body, properties=pika.BasicProperties(delivery_mode=2))
    try:
        conn.close()
    except Exception:
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("rover_id", type=int)
    parser.add_argument("--host", default="localhost:50051")
    parser.add_argument("--mq_host", default="localhost")
    parser.add_argument("--mq_port", type=int, default=5672)
    parser.add_argument("--start_x", type=int, default=0)
    parser.add_argument("--start_y", type=int, default=0)
    parser.add_argument("--step_delay_s", type=float, default=0.01)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    channel = grpc.insecure_channel(args.host)
    stub = rover_pb2_grpc.GroundControlStub(channel)

    map_reply = stub.GetMap(rover_pb2.MapRequest(rover_id=args.rover_id))
    grid: List[List[Any]] = json.loads(map_reply.json_map)
    width = int(map_reply.width)
    height = int(map_reply.height)

    x, y = int(args.start_x), int(args.start_y)
    reported: Set[str] = set()

    LOG.info("rover_started id=%d pos=(%d,%d) map=(%d,%d)", args.rover_id, x, y, width, height)

    stream = stub.GetCommandStream(rover_pb2.CommandRequest(rover_id=args.rover_id))
    for msg in stream:
        c = normalize_command(msg.cmd)
        if c is None:
            time.sleep(args.step_delay_s)
            continue

        x, y = move_xy(x, y, c, width, height)
        cell = grid[y][x] if 0 <= y < height and 0 <= x < width else 0
        mine_id = cell_to_mine_id(cell, x, y)

        if mine_id is not None:
            key = f"{mine_id}@{x},{y}"
            if key not in reported:
                serial_reply = stub.GetMineSerialNumber(rover_pb2.MineSerialRequest(mine_id=str(mine_id)))
                serial = serial_reply.serial if serial_reply.found else "UNKNOWN"
                task = {"rover_id": args.rover_id, "mine_id": str(mine_id), "x": x, "y": y, "serial": serial, "ts": time.time()}
                publish_task(args.mq_host, args.mq_port, task)
                reported.add(key)
                LOG.info("mine_task_published mine_id=%s pos=(%d,%d) serial=%s", mine_id, x, y, serial)

        time.sleep(args.step_delay_s)

    LOG.info("rover_done id=%d final=(%d,%d) tasks=%d", args.rover_id, x, y, len(reported))


if __name__ == "__main__":
    main()
EOF

cat > deminer.py <<'EOF'
#!/usr/bin/env python3
# COE892 Lab 3: Deminer (RabbitMQ consumer + publisher)
import argparse
import hashlib
import json
import logging
import time
from typing import Any, Dict

import pika

LOG = logging.getLogger("deminer")

DEMINE_QUEUE = "Demine-Queue"
DEFUSED_EXCHANGE = "Defused-Mines"


def serial_to_pin(serial: str) -> str:
    h = hashlib.sha256(serial.encode("utf-8", errors="ignore")).hexdigest()
    n = int(h[:12], 16) % 1_000_000
    return f"{n:06d}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("deminer_id", type=int)
    parser.add_argument("--mq_host", default="localhost")
    parser.add_argument("--mq_port", type=int, default=5672)
    parser.add_argument("--disarm_time_s", type=float, default=0.35)
    parser.add_argument("--idle_sleep_s", type=float, default=0.05)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    params = pika.ConnectionParameters(host=args.mq_host, port=args.mq_port, heartbeat=30, blocked_connection_timeout=30)
    conn = pika.BlockingConnection(params)
    ch = conn.channel()

    ch.queue_declare(queue=DEMINE_QUEUE, durable=True)
    ch.exchange_declare(exchange=DEFUSED_EXCHANGE, exchange_type="fanout", durable=True)
    ch.basic_qos(prefetch_count=1)

    LOG.info("deminer_started id=%d", args.deminer_id)

    def on_task(channel, method, properties, body: bytes):
        raw = body.decode("utf-8", errors="replace")
        try:
            task = json.loads(raw)
        except Exception:
            task = {"raw": raw}

        mine_id = str(task.get("mine_id", "UNKNOWN"))
        x = int(task.get("x", -1))
        y = int(task.get("y", -1))
        serial = str(task.get("serial", "UNKNOWN"))
        rover_id = task.get("rover_id", "UNKNOWN")

        LOG.info("task_received mine_id=%s pos=(%d,%d) rover=%s", mine_id, x, y, rover_id)

        time.sleep(args.disarm_time_s)
        pin = serial_to_pin(serial)

        result: Dict[str, Any] = {"deminer_id": args.deminer_id, "mine_id": mine_id, "x": x, "y": y, "pin": pin, "serial": serial, "ts": time.time()}
        channel.basic_publish(exchange=DEFUSED_EXCHANGE, routing_key="", body=json.dumps(result, ensure_ascii=False).encode("utf-8"), properties=pika.BasicProperties(delivery_mode=2))

        channel.basic_ack(delivery_tag=method.delivery_tag)
        LOG.info("task_completed mine_id=%s pin=%s", mine_id, pin)
        time.sleep(args.idle_sleep_s)

    ch.basic_consume(queue=DEMINE_QUEUE, on_message_callback=on_task, auto_ack=False)

    try:
        ch.start_consuming()
    except KeyboardInterrupt:
        pass

    try:
        conn.close()
    except Exception:
        pass


if __name__ == "__main__":
    main()
EOF

cat > start_rabbitmq.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found"
  exit 1
fi

docker rm -f mqserver >/dev/null 2>&1 || true
docker run -d --name mqserver -p 5672:5672 rabbitmq >/dev/null
docker ps --filter "name=mqserver"
EOF

cat > stop_rabbitmq.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
docker rm -f mqserver >/dev/null 2>&1 || true
EOF

cat > run_all.sh <<'EOF'
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
EOF

cat > README.md <<'EOF'
COE892 Lab 3 (gRPC + RabbitMQ)

Folders
- input: map.txt, mines.txt, commands
- output: logs and defused mine output

Scripts
- bootstrap_lab3.sh: generates project files
- start_rabbitmq.sh: starts RabbitMQ using docker
- stop_rabbitmq.sh: stops RabbitMQ docker container
- run_all.sh: runs ground control, deminers, and rovers
EOF

chmod +x ground_control.py rover.py deminer.py start_rabbitmq.sh stop_rabbitmq.sh run_all.sh

if [[ ! -d "$VENV_DIR" ]]; then
  "$PY" -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
python -m pip install --upgrade pip >/dev/null
pip install -r requirements.txt >/dev/null

python -m grpc_tools.protoc -I . --python_out=. --grpc_python_out=. rover.proto

echo ""
echo "Created in: $(pwd)"
echo "Venv: $VENV_DIR"
echo "Run: ./run_all.sh"
EOF
