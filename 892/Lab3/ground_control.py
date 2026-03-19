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
