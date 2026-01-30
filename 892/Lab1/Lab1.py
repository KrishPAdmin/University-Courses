# ================================================================
# Project: COE892 Lab 1 - Concurrency vs Parallelism (Rovers + Mines)
# File: COE892-Lab1-Krish_Patel.py
# Author: Krish Patel (KrishAdmin) - https://krishadmin.com
#
# NOTICE:
# This script is intended only for individuals who were directly
# provided the GitHub repository link by the author. Any use,
# copying, modification, or distribution without explicit
# permission from the author is prohibited.
# ================================================================

from __future__ import annotations

import argparse
import hashlib
import json
import os
import threading
import time
from dataclasses import dataclass
from multiprocessing import Pool, cpu_count
from queue import Empty, Queue
from typing import Dict, List, Optional, Set, Tuple

import requests

Coord = Tuple[int, int]
ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"
DIRECTIONS = ["N", "E", "S", "W"]


# -------------------------
# Data
# -------------------------
@dataclass(frozen=True)
class Mine:
    row: int
    col: int
    serial: str


@dataclass
class RoverResult:
    rover_id: int
    visited: Set[Coord]
    exploded: bool
    explosion_at: Optional[Coord]


# -------------------------
# Logging
# -------------------------
_print_lock = threading.Lock()


def log(msg: str) -> None:
    with _print_lock:
        print(msg, flush=True)


# -------------------------
# Args
# -------------------------
def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser()

    ap.add_argument("--p1", action="store_true", help="Run Part 1")
    ap.add_argument("--p2", action="store_true", help="Run Part 2")

    ap.add_argument("--seq", action="store_true", help="Run sequential only")
    ap.add_argument("--threaded", action="store_true", help="Run threaded only")
    ap.add_argument("--mp", action="store_true", help="Run multiprocessing only (Part 2 only)")

    ap.add_argument("--map", default=None, help="Map file path")
    ap.add_argument("--mines", default=None, help="Mines file path (can also be map.txt)")
    ap.add_argument(
        "--serial-mode",
        default="coords",
        choices=["coords", "value", "coords_value"],
        help="Serial strategy when mines are extracted from a map file",
    )

    ap.add_argument("--out", default="output", help="Output root folder")

    ap.add_argument("--base-url", default="http://127.0.0.1:8000/lab1/rover", help="Rover API base URL")
    ap.add_argument("--timeout", type=float, default=10.0, help="HTTP timeout seconds")
    ap.add_argument("--rovers", default="1-10", help="Rover IDs: 1-10 or 1,2,3,10")

    ap.add_argument("--cache", default=None, help="Rover command cache path (json)")
    ap.add_argument("--refresh-cache", action="store_true", help="Re-fetch rover commands and overwrite cache")

    ap.add_argument("--difficulty", type=int, default=6, help="Leading zeros required in sha256 hex digest")
    ap.add_argument("--p2-threads", type=int, default=4, help="Worker count for Part 2 threaded and mp modes")
    ap.add_argument("--yield-every", type=int, default=20000, help="Yield every N attempts in brute force loop")

    return ap.parse_args()


# -------------------------
# Utilities
# -------------------------
def now() -> float:
    return time.perf_counter()


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def parse_rover_ids(spec: str) -> List[int]:
    s = spec.strip()
    if not s:
        return []
    if "-" in s and "," not in s:
        a, b = s.split("-", 1)
        start = int(a.strip())
        end = int(b.strip())
        if start <= end:
            return list(range(start, end + 1))
        return list(range(start, end - 1, -1))
    parts = [p.strip() for p in s.split(",") if p.strip()]
    ids: List[int] = []
    for p in parts:
        if "-" in p:
            a, b = p.split("-", 1)
            start = int(a.strip())
            end = int(b.strip())
            if start <= end:
                ids.extend(range(start, end + 1))
            else:
                ids.extend(range(start, end - 1, -1))
        else:
            ids.append(int(p))
    return sorted(set(ids))


def load_map(map_path: str) -> Tuple[List[List[int]], int, int]:
    with open(map_path, "r", encoding="utf-8") as f:
        first = f.readline().strip()
        if not first:
            raise ValueError("map file first line is empty")
        rows_s, cols_s = first.split()
        rows = int(rows_s)
        cols = int(cols_s)

        grid: List[List[int]] = []
        for _ in range(rows):
            line = f.readline()
            if not line:
                raise ValueError("map file has fewer rows than declared")
            row = [int(x) for x in line.strip().split()]
            if len(row) != cols:
                raise ValueError("map file row has wrong column count")
            grid.append(row)

    return grid, rows, cols


def deep_copy_grid(grid: List[List[int]]) -> List[List[int]]:
    return [r[:] for r in grid]


def render_path(rows: int, cols: int, visited: Set[Coord]) -> str:
    lines: List[str] = []
    for r in range(rows):
        line_cells = []
        for c in range(cols):
            line_cells.append("*" if (r, c) in visited else "0")
        lines.append(" ".join(line_cells))
    return "\n".join(lines)


def write_path_file(out_dir: str, rover_id: int, rows: int, cols: int, visited: Set[Coord]) -> str:
    ensure_dir(out_dir)
    path = os.path.join(out_dir, f"path_{rover_id}.txt")
    content = f"{rows} {cols}\n{render_path(rows, cols, visited)}\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return path


# -------------------------
# Rover API + Cache
# -------------------------
_cache_lock = threading.Lock()


def _normalize_commands(raw: str) -> str:
    valid = {"L", "R", "M", "D"}
    cleaned = "".join(ch for ch in raw if ch in valid)
    if not cleaned:
        raise RuntimeError(f"Empty or invalid command string: {raw!r}")
    return cleaned


def load_cache(cache_path: str) -> Dict[str, str]:
    if not cache_path or not os.path.exists(cache_path):
        return {}
    with open(cache_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        return {}
    out: Dict[str, str] = {}
    for k, v in data.items():
        if isinstance(k, str) and isinstance(v, str) and v:
            out[k] = v
    return out


def save_cache(cache_path: str, cache: Dict[str, str]) -> None:
    ensure_dir(os.path.dirname(cache_path) or ".")
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=2, sort_keys=True)


def fetch_rover_commands(rover_id: int, base_url: str, timeout: float) -> str:
    url = f"{base_url.rstrip('/')}/{rover_id}"
    r = requests.get(url, timeout=timeout)
    r.raise_for_status()

    raw = r.text
    try:
        j = r.json()
        if isinstance(j, dict) and "commands" in j and isinstance(j["commands"], str):
            raw = j["commands"]
    except Exception:
        pass

    return _normalize_commands(raw)


def get_rover_commands(
    rover_id: int,
    base_url: str,
    timeout: float,
    cache_path: Optional[str],
    refresh: bool,
    cache_obj: Optional[Dict[str, str]] = None,
) -> str:
    cache: Dict[str, str] = cache_obj if cache_obj is not None else {}
    key = str(rover_id)

    if cache_path and not refresh:
        if key in cache:
            return cache[key]

    cmds = fetch_rover_commands(rover_id, base_url, timeout)

    if cache_path:
        with _cache_lock:
            cache[key] = cmds
            save_cache(cache_path, cache)

    return cmds


# -------------------------
# Rover Simulation
# -------------------------
def turn_left(dir_idx: int) -> int:
    return (dir_idx - 1) % 4


def turn_right(dir_idx: int) -> int:
    return (dir_idx + 1) % 4


def forward_delta(dir_idx: int) -> Coord:
    d = DIRECTIONS[dir_idx]
    if d == "N":
        return (-1, 0)
    if d == "E":
        return (0, 1)
    if d == "S":
        return (1, 0)
    return (0, -1)


def simulate_rover(grid: List[List[int]], commands: str, rover_id: int) -> RoverResult:
    rows = len(grid)
    cols = len(grid[0]) if rows else 0

    r, c = 0, 0
    dir_idx = DIRECTIONS.index("S")

    visited: Set[Coord] = {(r, c)}
    exploded = False
    explosion_at: Optional[Coord] = None

    on_armed_mine = grid[r][c] > 0

    for ch in commands:
        if exploded:
            break

        if ch == "D":
            if grid[r][c] > 0:
                grid[r][c] = 0
            on_armed_mine = False
            continue

        if on_armed_mine:
            exploded = True
            explosion_at = (r, c)
            break

        if ch == "L":
            dir_idx = turn_left(dir_idx)
        elif ch == "R":
            dir_idx = turn_right(dir_idx)
        elif ch == "M":
            dr, dc = forward_delta(dir_idx)
            nr, nc = r + dr, c + dc
            if 0 <= nr < rows and 0 <= nc < cols:
                r, c = nr, nc
                visited.add((r, c))
                on_armed_mine = grid[r][c] > 0

    return RoverResult(rover_id=rover_id, visited=visited, exploded=exploded, explosion_at=explosion_at)


# -------------------------
# Part 1
# -------------------------
def run_part1_one(
    rover_id: int,
    map_path: str,
    out_dir: str,
    base_url: str,
    timeout: float,
    cache_path: Optional[str],
    refresh_cache: bool,
    cache_obj: Optional[Dict[str, str]] = None,
) -> None:
    grid, rows, cols = load_map(map_path)
    cmds = get_rover_commands(rover_id, base_url, timeout, cache_path, refresh_cache, cache_obj=cache_obj)
    res = simulate_rover(deep_copy_grid(grid), cmds, rover_id)
    file_path = write_path_file(out_dir, rover_id, rows, cols, res.visited)

    if res.exploded:
        log(f"Rover {rover_id}: exploded at {res.explosion_at} | wrote {file_path}")
    else:
        log(f"Rover {rover_id}: OK | wrote {file_path}")


def run_part1_sequential(args: argparse.Namespace, rover_ids: List[int], map_path: str) -> float:
    out_dir = os.path.join(args.out, "part1")
    ensure_dir(out_dir)

    cache_obj = load_cache(args.cache) if args.cache else {}
    t0 = now()
    for rid in rover_ids:
        run_part1_one(
            rover_id=rid,
            map_path=map_path,
            out_dir=out_dir,
            base_url=args.base_url,
            timeout=args.timeout,
            cache_path=args.cache,
            refresh_cache=args.refresh_cache,
            cache_obj=cache_obj,
        )
    return now() - t0


def run_part1_threaded(args: argparse.Namespace, rover_ids: List[int], map_path: str) -> float:
    out_dir = os.path.join(args.out, "part1")
    ensure_dir(out_dir)

    cache_obj = load_cache(args.cache) if args.cache else {}
    t0 = now()

    threads: List[threading.Thread] = []
    for rid in rover_ids:
        th = threading.Thread(
            target=run_part1_one,
            args=(
                rid,
                map_path,
                out_dir,
                args.base_url,
                args.timeout,
                args.cache,
                args.refresh_cache,
                cache_obj,
            ),
            daemon=True,
        )
        threads.append(th)
        th.start()

    for th in threads:
        th.join()

    return now() - t0


# -------------------------
# Mines loading
# -------------------------
def _coord_width(rows: int, cols: int) -> int:
    w = max(len(str(max(rows - 1, 0))), len(str(max(cols - 1, 0))))
    return max(2, w)


def mines_from_map(grid: List[List[int]], rows: int, cols: int, serial_mode: str) -> List[Mine]:
    w = _coord_width(rows, cols)
    out: List[Mine] = []

    for r in range(rows):
        for c in range(cols):
            v = grid[r][c]
            if v > 0:
                if serial_mode == "value":
                    serial = str(v)
                elif serial_mode == "coords_value":
                    serial = f"{r:0{w}d}{c:0{w}d}{v}"
                else:
                    serial = f"{r:0{w}d}{c:0{w}d}"
                out.append(Mine(row=r, col=c, serial=serial))

    if not out:
        raise ValueError("No mines found in the map file")

    return out


def mines_from_file(mines_path: str) -> List[Mine]:
    mines: List[Mine] = []
    with open(mines_path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue

            parts = s.replace(",", " ").split()
            if len(parts) >= 3:
                try:
                    r = int(parts[0])
                    c = int(parts[1])
                    serial = str(parts[2])
                    mines.append(Mine(row=r, col=c, serial=serial))
                    continue
                except Exception:
                    pass

            mines.append(Mine(row=-1, col=-1, serial=str(parts[0])))

    if not mines:
        raise ValueError("No mines found in mines file")

    return mines


def load_mines(map_path: str, mines_path: Optional[str], serial_mode: str) -> List[Mine]:
    if mines_path and os.path.exists(mines_path):
        try:
            grid, rows, cols = load_map(mines_path)
            return mines_from_map(grid, rows, cols, serial_mode)
        except Exception:
            return mines_from_file(mines_path)

    grid, rows, cols = load_map(map_path)
    return mines_from_map(grid, rows, cols, serial_mode)


def make_unique_serial_map(mines: List[Mine]) -> Dict[str, Mine]:
    used: Set[str] = set()
    out: Dict[str, Mine] = {}

    for m in mines:
        key = m.serial
        if key in used:
            if m.row >= 0 and m.col >= 0:
                key = f"{m.serial}_{m.row}_{m.col}"
            else:
                suffix = 2
                while f"{m.serial}_{suffix}" in used:
                    suffix += 1
                key = f"{m.serial}_{suffix}"
        used.add(key)
        out[key] = m

    return out


# -------------------------
# PIN solving
# -------------------------
def _to_base36(n: int) -> str:
    if n == 0:
        return ALPHABET[0]
    base = len(ALPHABET)
    s = ""
    x = n
    while x > 0:
        x, r = divmod(x, base)
        s = ALPHABET[r] + s
    return s


def find_pin_for_serial(serial: str, difficulty: int, yield_every: int) -> str:
    target = "0" * difficulty
    attempts = 0
    n = 0
    while True:
        pin = _to_base36(n)
        temp_key = f"{pin}{serial}"
        digest = hashlib.sha256(temp_key.encode("utf-8")).hexdigest()
        if digest.startswith(target):
            return pin
        n += 1
        attempts += 1
        if yield_every > 0 and attempts % yield_every == 0:
            time.sleep(0)


def solve_one_serial(args_tuple: Tuple[str, int, int]) -> Tuple[str, str]:
    serial, difficulty, yield_every = args_tuple
    pin = find_pin_for_serial(serial, difficulty, yield_every)
    return serial, pin


# -------------------------
# Part 2
# -------------------------
def run_part2_sequential(args: argparse.Namespace, serials: List[str]) -> Tuple[float, Dict[str, str]]:
    t0 = now()
    out: Dict[str, str] = {}
    for sn in serials:
        out[sn] = find_pin_for_serial(sn, args.difficulty, args.yield_every)
    return now() - t0, out


def run_part2_threaded(args: argparse.Namespace, serials: List[str]) -> Tuple[float, Dict[str, str]]:
    t0 = now()
    out: Dict[str, str] = {}
    out_lock = threading.Lock()

    q: Queue[str] = Queue()
    for sn in serials:
        q.put(sn)

    def worker() -> None:
        while True:
            try:
                sn = q.get_nowait()
            except Empty:
                break
            pin = find_pin_for_serial(sn, args.difficulty, args.yield_every)
            with out_lock:
                out[sn] = pin
            q.task_done()

    threads: List[threading.Thread] = []
    n_workers = max(1, int(args.p2_threads))
    for _ in range(n_workers):
        th = threading.Thread(target=worker, daemon=True)
        threads.append(th)
        th.start()

    for th in threads:
        th.join()

    return now() - t0, out


def run_part2_multiprocessing(args: argparse.Namespace, serials: List[str]) -> Tuple[float, Dict[str, str]]:
    t0 = now()
    procs = max(1, int(args.p2_threads))
    procs = min(procs, cpu_count() or procs)

    payload = [(sn, args.difficulty, args.yield_every) for sn in serials]
    out: Dict[str, str] = {}

    with Pool(processes=procs) as pool:
        for serial, pin in pool.imap_unordered(solve_one_serial, payload, chunksize=1):
            out[serial] = pin

    return now() - t0, out


def write_part2_output(out_dir: str, pins: Dict[str, str]) -> str:
    ensure_dir(out_dir)
    path = os.path.join(out_dir, "disarmed_mines.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(pins, f, indent=2, sort_keys=True)
    return path


# -------------------------
# Main
# -------------------------
def main() -> int:
    args = parse_args()

    do_p1 = args.p1 or (not args.p1 and not args.p2)
    do_p2 = args.p2 or (not args.p1 and not args.p2)

    rover_ids = parse_rover_ids(args.rovers)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    map_path = args.map if args.map else os.path.join(script_dir, "map.txt")
    mines_path = args.mines

    ensure_dir(args.out)

    if do_p1:
        log("Part 1: rover paths")
        seq_t: Optional[float] = None
        thr_t: Optional[float] = None

        if args.seq:
            seq_t = run_part1_sequential(args, rover_ids, map_path)
            log(f"Part 1 sequential total: {seq_t:.6f}s")
        elif args.threaded:
            thr_t = run_part1_threaded(args, rover_ids, map_path)
            log(f"Part 1 threaded total: {thr_t:.6f}s")
        else:
            seq_t = run_part1_sequential(args, rover_ids, map_path)
            thr_t = run_part1_threaded(args, rover_ids, map_path)
            log(f"Part 1 sequential total: {seq_t:.6f}s")
            log(f"Part 1 threaded total:  {thr_t:.6f}s")
            log(f"Part 1 delta (seq - threaded): {(seq_t - thr_t):.6f}s")

    if do_p2:
        log("Part 2: mine disarming")

        mines = load_mines(map_path, mines_path, args.serial_mode)
        unique = make_unique_serial_map(mines)
        serials = list(unique.keys())
        log(f"Part 2 mines loaded: {len(serials)}")

        out_dir = os.path.join(args.out, "part2")
        ensure_dir(out_dir)

        if args.mp:
            t_mp, pins = run_part2_multiprocessing(args, serials)
            out_path = write_part2_output(out_dir, pins)
            log(f"Part 2 multiprocessing total: {t_mp:.6f}s | wrote {out_path}")
        elif args.seq:
            t_seq, pins = run_part2_sequential(args, serials)
            out_path = write_part2_output(out_dir, pins)
            log(f"Part 2 sequential total: {t_seq:.6f}s | wrote {out_path}")
        elif args.threaded:
            t_thr, pins = run_part2_threaded(args, serials)
            out_path = write_part2_output(out_dir, pins)
            log(f"Part 2 threaded total: {t_thr:.6f}s | wrote {out_path}")
        else:
            t_seq, pins_seq = run_part2_sequential(args, serials)
            out_path_seq = write_part2_output(out_dir, pins_seq)

            t_thr, pins_thr = run_part2_threaded(args, serials)
            out_path_thr = write_part2_output(out_dir, pins_thr)

            log(f"Part 2 sequential total: {t_seq:.6f}s | wrote {out_path_seq}")
            log(f"Part 2 threaded total:  {t_thr:.6f}s | wrote {out_path_thr}")
            log(f"Part 2 delta (seq - threaded): {(t_seq - t_thr):.6f}s")
            log("Part 2 note: threading may not improve CPU hashing due to the GIL")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

this is my old code, sorry, can you update this with the proper header to put it into github, and also update part 1 so the map is only loaded once rather than for every rover, and update the output naming to trace_x instead of path_x like his
also for part 2, make it include mine identifers in the output data and in the disarmed mine print statements 

send it all back in 1 code block ONLY
```python
# ================================================================
# Project: COE892 Lab 1 - Concurrency vs Parallelism (Rovers + Mines)
# File: COE892-Lab1-Krish_Patel.py
# Author: Krish Patel (KrishAdmin) - https://krishadmin.com
#
# NOTICE:
# This script is intended only for individuals who were directly
# provided the GitHub repository link by the author. Any use,
# copying, modification, or distribution without explicit
# permission from the author is prohibited.
# ================================================================
