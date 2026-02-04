import argparse
import hashlib
import time
from typing import List, Tuple

import grpc

import rover_pb2
import rover_pb2_grpc


def compute_pin_from_serial(serial: str) -> str:
    digest = hashlib.sha256(serial.encode("utf-8")).hexdigest()
    value = int(digest[:8], 16) % 1_000_000
    return f"{value:06d}"


def is_mine_cell(ch: str) -> bool:
    return ch in {"M", "*", "X"}


def is_blocked_cell(ch: str) -> bool:
    return ch in {"#", "W"}


def clamp_position(x: int, y: int, width: int, height: int) -> Tuple[int, int]:
    nx = max(0, min(width - 1, x))
    ny = max(0, min(height - 1, y))
    return nx, ny


def turn_left(direction: int) -> int:
    return (direction + 3) % 4


def turn_right(direction: int) -> int:
    return (direction + 1) % 4


def forward_delta(direction: int) -> Tuple[int, int]:
    if direction == 0:
        return 0, -1
    if direction == 1:
        return 1, 0
    if direction == 2:
        return 0, 1
    return -1, 0


def fetch_map(stub, rover_id: int):
    resp = stub.GetMap(rover_pb2.MapRequest(rover_id=rover_id))
    rows = list(resp.rows)
    return rows, int(resp.width), int(resp.height), int(resp.start_x), int(resp.start_y)


def fetch_commands(stub, rover_id: int) -> str:
    stream = stub.StreamCommands(rover_pb2.CommandRequest(rover_id=rover_id))
    parts: List[str] = []
    for chunk in stream:
        if chunk.is_last:
            break
        if chunk.chunk:
            parts.append(chunk.chunk)
        time.sleep(0.01)
    return "".join(parts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("rover_id", type=int)
    parser.add_argument("--host", default="localhost:50051")
    args = parser.parse_args()

    rover_id = int(args.rover_id)
    if rover_id < 1 or rover_id > 10:
        raise ValueError("rover_id must be 1 to 10")

    channel = grpc.insecure_channel(args.host)
    stub = rover_pb2_grpc.GroundControlStub(channel)

    rows, width, height, x, y = fetch_map(stub, rover_id)
    commands = fetch_commands(stub, rover_id)

    direction = 0
    exploded = False
    commands_executed = 0
    needs_disarm = False

    for cmd in commands:
        if exploded:
            break

        if needs_disarm and cmd != "D":
            exploded = True
            break

        if cmd == "L":
            direction = turn_left(direction)
        elif cmd == "R":
            direction = turn_right(direction)
        elif cmd == "M":
            dx, dy = forward_delta(direction)
            nx, ny = clamp_position(x + dx, y + dy, width, height)
            cell = rows[ny][nx]
            if not is_blocked_cell(cell):
                x, y = nx, ny
                if is_mine_cell(rows[y][x]):
                    needs_disarm = True
        elif cmd == "D":
            if is_mine_cell(rows[y][x]):
                serial_resp = stub.GetMineSerial(
                    rover_pb2.MineSerialRequest(rover_id=rover_id, x=x, y=y)
                )
                serial = serial_resp.serial
                pin = compute_pin_from_serial(serial)

                ack = stub.ShareMinePin(
                    rover_pb2.MinePin(rover_id=rover_id, x=x, y=y, serial=serial, pin=pin)
                )
                if not ack.ok:
                    exploded = True
                needs_disarm = False
            else:
                needs_disarm = False

        commands_executed += 1
        time.sleep(0.005)

    success = (not exploded) and (commands_executed == len(commands))
    msg = "ok" if success else ("exploded" if exploded else "stopped early")

    stub.ReportExecution(
        rover_pb2.ExecutionReport(
            rover_id=rover_id,
            success=success,
            exploded=exploded,
            commands_total=len(commands),
            commands_executed=commands_executed,
            final_x=x,
            final_y=y,
            message=msg,
        )
    )

    print(f"Rover {rover_id}: success={success} exploded={exploded} executed={commands_executed}/{len(commands)} final=({x},{y})")


if __name__ == "__main__":
    main()
