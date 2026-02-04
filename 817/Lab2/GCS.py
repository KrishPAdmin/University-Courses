import argparse
import hashlib
import logging
import os
import time
from concurrent import futures
from typing import Dict, List, Tuple

import grpc

import rover_pb2
import rover_pb2_grpc


def compute_pin_from_serial(serial: str) -> str:
    digest = hashlib.sha256(serial.encode("utf-8")).hexdigest()
    value = int(digest[:8], 16) % 1_000_000
    return f"{value:06d}"


def read_map_file(map_path: str) -> Tuple[List[str], int, int, int, int]:
    with open(map_path, "r", encoding="utf-8") as f:
        raw_lines = [line.rstrip("\n") for line in f.readlines()]

    rows = [line for line in raw_lines if line.strip() != ""]
    if not rows:
        raise ValueError("Map file is empty.")

    width = max(len(r) for r in rows)
    padded = [r.ljust(width) for r in rows]
    height = len(padded)

    start_x, start_y = 0, 0
    for y, row in enumerate(padded):
        idx = row.find("S")
        if idx != -1:
            start_x, start_y = idx, y
            break

    return padded, width, height, start_x, start_y


def parse_int(s: str):
    try:
        return int(s)
    except Exception:
        return None


def read_mines_file(mines_path: str) -> Dict[Tuple[int, int], str]:
    mines: Dict[Tuple[int, int], str] = {}
    if not mines_path or not os.path.exists(mines_path):
        return mines

    with open(mines_path, "r", encoding="utf-8") as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue

            tokens = stripped.replace(",", " ").split()
            if len(tokens) < 3:
                continue

            a, b, c = tokens[0], tokens[1], tokens[2]
            ai, bi, ci = parse_int(a), parse_int(b), parse_int(c)

            if ai is not None and bi is not None:
                mines[(ai, bi)] = c
                continue

            if bi is not None and ci is not None:
                mines[(bi, ci)] = a
                continue

    return mines


def read_commands(commands_dir: str, rover_id: int) -> str:
    path = os.path.join(commands_dir, f"rover_{rover_id}.txt")
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read().strip()
    return "".join(ch for ch in text if not ch.isspace())


class GroundControlServicer(rover_pb2_grpc.GroundControlServicer):
    def __init__(self, map_path: str, mines_path: str, commands_dir: str):
        self.rows, self.width, self.height, self.start_x, self.start_y = read_map_file(map_path)
        self.mines = read_mines_file(mines_path)
        self.commands_dir = commands_dir
        self.pin_log: List[Tuple[int, int, int, str, str, bool]] = []

    def GetMap(self, request, context):
        return rover_pb2.MapResponse(
            rows=self.rows,
            width=self.width,
            height=self.height,
            start_x=self.start_x,
            start_y=self.start_y,
        )

    def StreamCommands(self, request, context):
        rover_id = int(request.rover_id)
        commands = read_commands(self.commands_dir, rover_id)

        chunk_size = 8
        i = 0
        while i < len(commands):
            chunk = commands[i:i + chunk_size]
            i += chunk_size
            time.sleep(0.02)
            yield rover_pb2.CommandChunk(chunk=chunk, is_last=False)

        time.sleep(0.01)
        yield rover_pb2.CommandChunk(chunk="", is_last=True)

    def GetMineSerial(self, request, context):
        x = int(request.x)
        y = int(request.y)
        key = (x, y)

        if key in self.mines:
            return rover_pb2.MineSerialResponse(found=True, serial=self.mines[key], message="ok")

        fallback_serial = f"X{x}_Y{y}"
        return rover_pb2.MineSerialResponse(found=False, serial=fallback_serial, message="not found in mines file")

    def ShareMinePin(self, request, context):
        rover_id = int(request.rover_id)
        x = int(request.x)
        y = int(request.y)
        serial = str(request.serial)
        pin = str(request.pin)

        expected = compute_pin_from_serial(serial)
        ok = (pin == expected)
        self.pin_log.append((rover_id, x, y, serial, pin, ok))

        if ok:
            return rover_pb2.Ack(ok=True, message="PIN accepted")
        return rover_pb2.Ack(ok=False, message="PIN rejected")

    def ReportExecution(self, request, context):
        rover_id = int(request.rover_id)
        logging.info(
            "Rover %d report: success=%s exploded=%s executed=%d/%d final=(%d,%d) msg=%s",
            rover_id,
            bool(request.success),
            bool(request.exploded),
            int(request.commands_executed),
            int(request.commands_total),
            int(request.final_x),
            int(request.final_y),
            str(request.message),
        )
        return rover_pb2.Ack(ok=True, message="report received")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0:50051")
    parser.add_argument("--map", dest="map_path", default="input/map.txt")
    parser.add_argument("--mines", dest="mines_path", default="input/mines.txt")
    parser.add_argument("--commands_dir", default="input/commands")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=16))
    rover_pb2_grpc.add_GroundControlServicer_to_server(
        GroundControlServicer(args.map_path, args.mines_path, args.commands_dir),
        server,
    )
    server.add_insecure_port(args.host)
    server.start()
    logging.info("Ground Control running on %s", args.host)

    try:
        while True:
            time.sleep(0.5)
    except KeyboardInterrupt:
        logging.info("Shutting down server")
        server.stop(2)


if __name__ == "__main__":
    main()
