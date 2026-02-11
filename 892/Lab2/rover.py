import argparse
import hashlib
import time
from dataclasses import dataclass
from typing import List, Tuple

import grpc

import rover_pb2
import rover_pb2_grpc


@dataclass
class RoverResult:
    rover_id: int
    success: bool
    exploded: bool
    commands_total: int
    commands_executed: int
    final_x: int
    final_y: int
    elapsed_s: float


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


def fetch_commands(stub, rover_id: int, stream_sleep_s: float) -> str:
    stream = stub.StreamCommands(rover_pb2.CommandRequest(rover_id=rover_id))
    parts: List[str] = []
    for chunk in stream:
        if chunk.is_last:
            break
        if chunk.chunk:
            parts.append(chunk.chunk)
        if stream_sleep_s > 0:
            time.sleep(stream_sleep_s)
    return "".join(parts)


def run_single_rover(rover_id: int, host: str, stream_sleep_s: float, exec_sleep_s: float) -> RoverResult:
    start_t = time.perf_counter()

    channel = grpc.insecure_channel(host)
    stub = rover_pb2_grpc.GroundControlStub(channel)

    rows, width, height, x, y = fetch_map(stub, rover_id)
    commands = fetch_commands(stub, rover_id, stream_sleep_s)

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
        if exec_sleep_s > 0:
            time.sleep(exec_sleep_s)

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

    elapsed_s = time.perf_counter() - start_t

    return RoverResult(
        rover_id=rover_id,
        success=success,
        exploded=exploded,
        commands_total=len(commands),
        commands_executed=commands_executed,
        final_x=x,
        final_y=y,
        elapsed_s=elapsed_s,
    )


def print_result_line(r: RoverResult):
    time_ms = r.elapsed_s * 1000.0
    print(
        f"Rover {r.rover_id:>2} | "
        f"ok={str(r.success):<5} | "
        f"exploded={str(r.exploded):<5} | "
        f"executed={r.commands_executed:>3}/{r.commands_total:<3} | "
        f"final=({r.final_x:>2},{r.final_y:>2}) | "
        f"time_ms={time_ms:>8.2f}"
    )


def run_all_sequential(host: str, start_id: int, end_id: int, stream_sleep_s: float, exec_sleep_s: float, stagger_s: float):
    start_t = time.perf_counter()
    results: List[RoverResult] = []
    for rover_id in range(start_id, end_id + 1):
        res = run_single_rover(rover_id, host, stream_sleep_s, exec_sleep_s)
        results.append(res)
        print_result_line(res)
        if stagger_s > 0:
            time.sleep(stagger_s)
    total_s = time.perf_counter() - start_t
    return results, total_s


def run_all_concurrent(host: str, start_id: int, end_id: int, workers: int, stream_sleep_s: float, exec_sleep_s: float, stagger_s: float):
    from concurrent.futures import ThreadPoolExecutor, as_completed

    start_t = time.perf_counter()
    rover_ids = list(range(start_id, end_id + 1))
    results: List[RoverResult] = []

    with ThreadPoolExecutor(max_workers=max(1, workers)) as ex:
        futures = []
        for rover_id in rover_ids:
            futures.append(ex.submit(run_single_rover, rover_id, host, stream_sleep_s, exec_sleep_s))
            if stagger_s > 0:
                time.sleep(stagger_s)

        for fut in as_completed(futures):
            results.append(fut.result())

    results.sort(key=lambda r: r.rover_id)
    for r in results:
        print_result_line(r)

    total_s = time.perf_counter() - start_t
    return results, total_s


def parse_args():
    parser = argparse.ArgumentParser()

    parser.add_argument("rover_id", nargs="?", type=int)
    parser.add_argument("--host", default="localhost:50051")

    parser.add_argument("--all", action="store_true")
    parser.add_argument("--mode", choices=["sequential", "concurrent"], default="sequential")
    parser.add_argument("--start_id", type=int, default=1)
    parser.add_argument("--end_id", type=int, default=10)
    parser.add_argument("--workers", type=int, default=10)
    parser.add_argument("--stagger_ms", type=int, default=50)

    parser.add_argument("--stream_sleep_ms", type=int, default=10)
    parser.add_argument("--exec_sleep_ms", type=int, default=5)

    return parser.parse_args()


def main():
    args = parse_args()

    stream_sleep_s = max(0.0, float(args.stream_sleep_ms) / 1000.0)
    exec_sleep_s = max(0.0, float(args.exec_sleep_ms) / 1000.0)
    stagger_s = max(0.0, float(args.stagger_ms) / 1000.0)

    if args.all:
        if args.mode == "sequential":
            results, total_s = run_all_sequential(
                args.host,
                args.start_id,
                args.end_id,
                stream_sleep_s,
                exec_sleep_s,
                stagger_s,
            )
        else:
            results, total_s = run_all_concurrent(
                args.host,
                args.start_id,
                args.end_id,
                args.workers,
                stream_sleep_s,
                exec_sleep_s,
                stagger_s,
            )

        ok_count = sum(1 for r in results if r.success)
        exploded_count = sum(1 for r in results if r.exploded)

        total_ms = total_s * 1000.0
        avg_ms = (sum(r.elapsed_s for r in results) / len(results)) * 1000.0 if results else 0.0
        max_ms = max((r.elapsed_s for r in results), default=0.0) * 1000.0

        print("")
        print("Run summary")
        print(f"  rovers           : {len(results)}")
        print(f"  ok               : {ok_count}")
        print(f"  exploded         : {exploded_count}")
        print(f"  total_time_ms    : {total_ms:.2f}")
        print(f"  avg_rover_time_ms: {avg_ms:.2f}")
        print(f"  max_rover_time_ms: {max_ms:.2f}")
        return

    if args.rover_id is None:
        raise ValueError("Provide rover_id (1-10) or use --all")

    rover_id = int(args.rover_id)
    if rover_id < 1 or rover_id > 10:
        raise ValueError("rover_id must be 1 to 10")

    res = run_single_rover(rover_id, args.host, stream_sleep_s, exec_sleep_s)
    print_result_line(res)


if __name__ == "__main__":
    main()
