from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, Field, field_validator


class RoverStatus(str, Enum):
    NOT_STARTED = "Not Started"
    FINISHED = "Finished"
    MOVING = "Moving"
    ELIMINATED = "Eliminated"


class MineStatus(str, Enum):
    ACTIVE = "active"
    DEFUSED = "defused"


class Direction(str, Enum):
    NORTH = "N"
    EAST = "E"
    SOUTH = "S"
    WEST = "W"


class Position(BaseModel):
    x: int
    y: int


class MapUpdateRequest(BaseModel):
    width: int = Field(..., ge=1, le=50)
    height: int = Field(..., ge=1, le=50)


class MapResponse(BaseModel):
    width: int
    height: int
    field: List[List[str]]
    rendered_rows: List[str]


class MineCreateRequest(BaseModel):
    x: int = Field(..., ge=0)
    y: int = Field(..., ge=0)
    serial_number: str = Field(..., min_length=1, max_length=128)


class MineUpdateRequest(BaseModel):
    x: Optional[int] = Field(default=None, ge=0)
    y: Optional[int] = Field(default=None, ge=0)
    serial_number: Optional[str] = Field(default=None, min_length=1, max_length=128)


class MineResponse(BaseModel):
    id: int
    x: int
    y: int
    serial_number: str
    status: MineStatus
    pin: Optional[str] = None


class RoverCreateRequest(BaseModel):
    commands: str = Field(..., min_length=0, max_length=10000)

    @field_validator("commands")
    @classmethod
    def validate_commands(cls, value: str) -> str:
        clean = value.strip().upper()
        valid = {"L", "R", "M", "D"}
        if any(ch not in valid for ch in clean):
            raise ValueError("Commands must contain only L, R, M, or D.")
        return clean


class RoverUpdateRequest(RoverCreateRequest):
    pass


class RoverSummary(BaseModel):
    id: int
    status: RoverStatus


class RoverDetail(BaseModel):
    id: int
    status: RoverStatus
    latest_position: Position
    direction: Direction
    commands: str
    executed_commands: str


class DispatchResponse(RoverDetail):
    path_rows: List[str]
    events: List[str]


class MineRecord(MineResponse):
    pass


class RoverRecord(RoverDetail):
    pass


class ApiMessage(BaseModel):
    detail: str
