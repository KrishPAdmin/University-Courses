from __future__ import annotations

import hashlib
from typing import Iterable, List, Set, Tuple

from models import Direction, DispatchResponse, Position, RoverStatus
from store import MemoryStore

_DIRECTION_ORDER = [Direction.NORTH, Direction.EAST, Direction.SOUTH, Direction.WEST]
_DELTAS = {
    Direction.NORTH: (0, -1),
    Direction.EAST: (1, 0),
    Direction.SOUTH: (0, 1),
    Direction.WEST: (-1, 0),
}


def turn_left(direction: Direction) -> Direction:
    idx = _DIRECTION_ORDER.index(direction)
    return _DIRECTION_ORDER[(idx - 1) % len(_DIRECTION_ORDER)]


def turn_right(direction: Direction) -> Direction:
    idx = _DIRECTION_ORDER.index(direction)
    return _DIRECTION_ORDER[(idx + 1) % len(_DIRECTION_ORDER)]


def _mine_pin(serial_number: str) -> str:
    digest = hashlib.sha256(serial_number.encode("utf-8")).hexdigest().upper()
    return f"PIN-{digest[:8]}"


def _render_path(width: int, height: int, visited: Iterable[Tuple[int, int]], current: Position, store: MemoryStore) -> List[str]:
    grid = [["0" for _ in range(width)] for _ in range(height)]
    for x, y in visited:
        if 0 <= x < width and 0 <= y < height:
            grid[y][x] = "*"
    for mine in store.mines.values():
        grid[mine.y][mine.x] = "M" if mine.status.value == "active" else "X"
    if 0 <= current.x < width and 0 <= current.y < height:
        grid[current.y][current.x] = "R"
    return [" ".join(row) for row in grid]


def dispatch_rover(store: MemoryStore, rover_id: int) -> DispatchResponse:
    rover = store.get_rover(rover_id)
    if rover.status not in {RoverStatus.NOT_STARTED, RoverStatus.FINISHED}:
        raise ValueError("Rover can only be dispatched when status is Not Started or Finished.")

    rover.status = RoverStatus.MOVING
    rover.executed_commands = ""
    visited: Set[Tuple[int, int]] = {(rover.latest_position.x, rover.latest_position.y)}
    events: List[str] = []

    for command in rover.commands:
        mine_here = store.active_mine_at(rover.latest_position.x, rover.latest_position.y)

        if command == "D":
            rover.executed_commands += command
            if mine_here is None:
                events.append(f"No active mine at ({rover.latest_position.x}, {rover.latest_position.y}) to defuse.")
            else:
                pin = _mine_pin(mine_here.serial_number)
                defused = store.defuse_mine(mine_here.id, pin)
                events.append(f"Mine {defused.id} defused at ({defused.x}, {defused.y}) with PIN {pin}.")
            continue

        if command == "L":
            rover.direction = turn_left(rover.direction)
            rover.executed_commands += command
            continue

        if command == "R":
            rover.direction = turn_right(rover.direction)
            rover.executed_commands += command
            continue

        if command == "M":
            if mine_here is not None:
                rover.executed_commands += command
                rover.status = RoverStatus.ELIMINATED
                events.append(f"Rover {rover.id} attempted to leave active mine {mine_here.id} and was eliminated.")
                break

            dx, dy = _DELTAS[rover.direction]
            new_x = rover.latest_position.x + dx
            new_y = rover.latest_position.y + dy
            rover.executed_commands += command

            if not (0 <= new_x < store.width and 0 <= new_y < store.height):
                events.append(f"Move ignored at map edge while facing {rover.direction.value}.")
                continue

            rover.latest_position = Position(x=new_x, y=new_y)
            visited.add((new_x, new_y))
            mine_after_move = store.active_mine_at(new_x, new_y)
            if mine_after_move is not None:
                events.append(f"Rover {rover.id} is now on active mine {mine_after_move.id} at ({new_x}, {new_y}).")
            continue

    if rover.status != RoverStatus.ELIMINATED:
        rover.status = RoverStatus.FINISHED

    saved = store.save_rover(rover)
    return DispatchResponse(
        id=saved.id,
        status=saved.status,
        latest_position=saved.latest_position,
        direction=saved.direction,
        commands=saved.commands,
        executed_commands=saved.executed_commands,
        path_rows=_render_path(store.width, store.height, visited, saved.latest_position, store),
        events=events,
    )
