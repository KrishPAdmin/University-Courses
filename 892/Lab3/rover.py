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
