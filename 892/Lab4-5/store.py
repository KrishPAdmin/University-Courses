from __future__ import annotations

from copy import deepcopy
from typing import Dict, List, Optional

from models import (
    Direction,
    MapResponse,
    MapUpdateRequest,
    MineCreateRequest,
    MineRecord,
    MineStatus,
    MineUpdateRequest,
    Position,
    RoverCreateRequest,
    RoverRecord,
    RoverStatus,
    RoverSummary,
    RoverUpdateRequest,
)


class MemoryStore:
    def __init__(self) -> None:
        self.width = 8
        self.height = 8
        self.mines: Dict[int, MineRecord] = {}
        self.rovers: Dict[int, RoverRecord] = {}
        self._mine_id = 1
        self._rover_id = 1

    def _validate_coordinates(self, x: int, y: int) -> None:
        if not (0 <= x < self.width and 0 <= y < self.height):
            raise ValueError(f"Coordinates ({x}, {y}) are outside the current map.")

    def _ensure_free_coordinate(self, x: int, y: int, ignore_mine_id: Optional[int] = None) -> None:
        for mine_id, mine in self.mines.items():
            if ignore_mine_id is not None and mine_id == ignore_mine_id:
                continue
            if mine.x == x and mine.y == y:
                raise ValueError(f"A mine already exists at ({x}, {y}).")

    def get_map(self) -> MapResponse:
        field = [["0" for _ in range(self.width)] for _ in range(self.height)]
        for mine in self.mines.values():
            field[mine.y][mine.x] = "M" if mine.status == MineStatus.ACTIVE else "X"
        rendered_rows = [" ".join(row) for row in field]
        return MapResponse(width=self.width, height=self.height, field=field, rendered_rows=rendered_rows)

    def update_map(self, payload: MapUpdateRequest) -> MapResponse:
        for mine in self.mines.values():
            if mine.x >= payload.width or mine.y >= payload.height:
                raise ValueError("Resize would place at least one mine outside the map.")
        for rover in self.rovers.values():
            if rover.latest_position.x >= payload.width or rover.latest_position.y >= payload.height:
                raise ValueError("Resize would place at least one rover outside the map.")
        self.width = payload.width
        self.height = payload.height
        return self.get_map()

    def list_mines(self) -> List[MineRecord]:
        return [deepcopy(self.mines[mine_id]) for mine_id in sorted(self.mines)]

    def get_mine(self, mine_id: int) -> MineRecord:
        mine = self.mines.get(mine_id)
        if mine is None:
            raise KeyError(f"Mine {mine_id} was not found.")
        return deepcopy(mine)

    def create_mine(self, payload: MineCreateRequest) -> MineRecord:
        self._validate_coordinates(payload.x, payload.y)
        self._ensure_free_coordinate(payload.x, payload.y)
        mine = MineRecord(
            id=self._mine_id,
            x=payload.x,
            y=payload.y,
            serial_number=payload.serial_number,
            status=MineStatus.ACTIVE,
            pin=None,
        )
        self.mines[mine.id] = mine
        self._mine_id += 1
        return deepcopy(mine)

    def update_mine(self, mine_id: int, payload: MineUpdateRequest) -> MineRecord:
        mine = self.mines.get(mine_id)
        if mine is None:
            raise KeyError(f"Mine {mine_id} was not found.")
        new_x = mine.x if payload.x is None else payload.x
        new_y = mine.y if payload.y is None else payload.y
        self._validate_coordinates(new_x, new_y)
        self._ensure_free_coordinate(new_x, new_y, ignore_mine_id=mine_id)
        mine.x = new_x
        mine.y = new_y
        if payload.serial_number is not None:
            mine.serial_number = payload.serial_number
        self.mines[mine_id] = mine
        return deepcopy(mine)

    def delete_mine(self, mine_id: int) -> None:
        if mine_id not in self.mines:
            raise KeyError(f"Mine {mine_id} was not found.")
        del self.mines[mine_id]

    def active_mine_at(self, x: int, y: int) -> Optional[MineRecord]:
        for mine in self.mines.values():
            if mine.x == x and mine.y == y and mine.status == MineStatus.ACTIVE:
                return mine
        return None

    def defuse_mine(self, mine_id: int, pin: str) -> MineRecord:
        mine = self.mines.get(mine_id)
        if mine is None:
            raise KeyError(f"Mine {mine_id} was not found.")
        mine.status = MineStatus.DEFUSED
        mine.pin = pin
        self.mines[mine_id] = mine
        return deepcopy(mine)

    def list_rovers(self) -> List[RoverSummary]:
        return [
            RoverSummary(id=rover.id, status=rover.status)
            for rover in sorted(self.rovers.values(), key=lambda item: item.id)
        ]

    def get_rover(self, rover_id: int) -> RoverRecord:
        rover = self.rovers.get(rover_id)
        if rover is None:
            raise KeyError(f"Rover {rover_id} was not found.")
        return deepcopy(rover)

    def create_rover(self, payload: RoverCreateRequest) -> RoverRecord:
        rover = RoverRecord(
            id=self._rover_id,
            status=RoverStatus.NOT_STARTED,
            latest_position=Position(x=0, y=0),
            direction=Direction.SOUTH,
            commands=payload.commands,
            executed_commands="",
        )
        self.rovers[rover.id] = rover
        self._rover_id += 1
        return deepcopy(rover)

    def update_rover_commands(self, rover_id: int, payload: RoverUpdateRequest) -> RoverRecord:
        rover = self.rovers.get(rover_id)
        if rover is None:
            raise KeyError(f"Rover {rover_id} was not found.")
        if rover.status not in {RoverStatus.NOT_STARTED, RoverStatus.FINISHED}:
            raise ValueError("Commands can only be updated when rover status is Not Started or Finished.")
        rover.commands = payload.commands
        rover.executed_commands = ""
        rover.status = RoverStatus.NOT_STARTED
        rover.latest_position = Position(x=0, y=0)
        rover.direction = Direction.SOUTH
        self.rovers[rover_id] = rover
        return deepcopy(rover)

    def save_rover(self, rover: RoverRecord) -> RoverRecord:
        self.rovers[rover.id] = deepcopy(rover)
        return deepcopy(rover)

    def delete_rover(self, rover_id: int) -> None:
        if rover_id not in self.rovers:
            raise KeyError(f"Rover {rover_id} was not found.")
        del self.rovers[rover_id]
