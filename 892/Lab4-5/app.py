from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import List

from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

from models import (
    ApiMessage,
    DispatchResponse,
    MapResponse,
    MapUpdateRequest,
    MineCreateRequest,
    MineResponse,
    MineUpdateRequest,
    RoverCreateRequest,
    RoverDetail,
    RoverSummary,
    RoverUpdateRequest,
)
from simulator import dispatch_rover
from store import MemoryStore

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
TEMPLATES_DIR = BASE_DIR / "templates"

app = FastAPI(
    title="COE892 Lab 4 Rover Control",
    description="Lab 4 FastAPI backend with ProxSyncQ-inspired templated operator UI.",
    version="2.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_middleware(
    SessionMiddleware,
    secret_key=os.getenv("LAB4_SESSION_SECRET", "lab4-change-this-secret"),
    same_site="lax",
)

templates = Jinja2Templates(directory=str(TEMPLATES_DIR))
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

store = MemoryStore()

UI_USERNAME = os.getenv("LAB4_UI_USERNAME", "krishadmin")
UI_PASSWORD = os.getenv("LAB4_UI_PASSWORD", "lab4pass")


def _bad_request(message: str) -> HTTPException:
    return HTTPException(status_code=400, detail=message)


def _not_found(message: str) -> HTTPException:
    return HTTPException(status_code=404, detail=message)


def _is_logged_in(request: Request) -> bool:
    return bool(request.session.get("username"))


def _username(request: Request) -> str:
    return str(request.session.get("username", "guest"))


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _dashboard_payload(request: Request) -> dict:
    map_payload = store.get_map().model_dump(mode="json")
    mines_payload = [mine.model_dump(mode="json") for mine in store.list_mines()]
    rover_summaries = store.list_rovers()
    rovers_payload = [
        store.get_rover(summary.id).model_dump(mode="json")
        for summary in rover_summaries
    ]

    return {
        "updated_at": _now_iso(),
        "username": _username(request),
        "map": map_payload,
        "mine_count": len(mines_payload),
        "rover_count": len(rovers_payload),
        "mines": mines_payload,
        "rovers": rovers_payload,
        "docs_url": "/docs",
    }


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    if _is_logged_in(request):
        return RedirectResponse(url="/", status_code=303)
    return templates.TemplateResponse(
        "login.html",
        {
            "request": request,
            "error": "",
            "ui_marker": "ui-lab4-template-v1",
        },
    )


@app.post("/login", response_class=HTMLResponse)
async def login_submit(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
):
    if username == UI_USERNAME and password == UI_PASSWORD:
        request.session["username"] = username
        return RedirectResponse(url="/", status_code=303)

    return templates.TemplateResponse(
        "login.html",
        {
            "request": request,
            "error": "Invalid username or password.",
            "ui_marker": "ui-lab4-template-v1",
        },
        status_code=401,
    )


@app.get("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse(url="/login", status_code=303)


@app.get("/", response_class=HTMLResponse)
def operator(request: Request):
    if not _is_logged_in(request):
        return RedirectResponse(url="/login", status_code=303)

    dashboard = _dashboard_payload(request)
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "dashboard_json": json.dumps(dashboard),
        },
    )


@app.get("/api/dashboard")
def api_dashboard(request: Request):
    if not _is_logged_in(request):
        return JSONResponse(status_code=401, content={"detail": "Not authenticated"})
    return JSONResponse(_dashboard_payload(request))


@app.post("/ui/reset-demo")
def reset_demo(request: Request):
    global store
    if not _is_logged_in(request):
        return JSONResponse(status_code=401, content={"detail": "Not authenticated"})
    store = MemoryStore()
    return JSONResponse(
        {
            "detail": "Lab 4 demo state has been reset.",
            "updated_at": _now_iso(),
        }
    )


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "message": "Lab 4 server is running.",
        "map_size": {"width": store.width, "height": store.height},
        "mine_count": len(store.mines),
        "rover_count": len(store.rovers),
    }


@app.get("/map", response_model=MapResponse)
def get_map() -> MapResponse:
    return store.get_map()


@app.put("/map", response_model=MapResponse)
def put_map(payload: MapUpdateRequest) -> MapResponse:
    try:
        return store.update_map(payload)
    except ValueError as exc:
        raise _bad_request(str(exc)) from exc


@app.get("/mines", response_model=List[MineResponse])
def get_mines() -> List[MineResponse]:
    return store.list_mines()


@app.get("/mines/{mine_id}", response_model=MineResponse)
def get_mine(mine_id: int) -> MineResponse:
    try:
        return store.get_mine(mine_id)
    except KeyError as exc:
        raise _not_found(str(exc)) from exc


@app.post("/mines", response_model=MineResponse, status_code=201)
def post_mine(payload: MineCreateRequest) -> MineResponse:
    try:
        return store.create_mine(payload)
    except ValueError as exc:
        raise _bad_request(str(exc)) from exc


@app.put("/mines/{mine_id}", response_model=MineResponse)
def put_mine(mine_id: int, payload: MineUpdateRequest) -> MineResponse:
    try:
        return store.update_mine(mine_id, payload)
    except KeyError as exc:
        raise _not_found(str(exc)) from exc
    except ValueError as exc:
        raise _bad_request(str(exc)) from exc


@app.delete("/mines/{mine_id}", response_model=ApiMessage)
def delete_mine(mine_id: int) -> ApiMessage:
    try:
        store.delete_mine(mine_id)
        return ApiMessage(detail=f"Mine {mine_id} deleted.")
    except KeyError as exc:
        raise _not_found(str(exc)) from exc


@app.get("/rovers", response_model=List[RoverSummary])
def get_rovers() -> List[RoverSummary]:
    return store.list_rovers()


@app.get("/rovers/{rover_id}", response_model=RoverDetail)
def get_rover(rover_id: int) -> RoverDetail:
    try:
        return store.get_rover(rover_id)
    except KeyError as exc:
        raise _not_found(str(exc)) from exc


@app.post("/rovers", response_model=RoverDetail, status_code=201)
def post_rover(payload: RoverCreateRequest) -> RoverDetail:
    return store.create_rover(payload)


@app.put("/rovers/{rover_id}", response_model=RoverDetail)
def put_rover(rover_id: int, payload: RoverUpdateRequest) -> RoverDetail:
    try:
        return store.update_rover_commands(rover_id, payload)
    except KeyError as exc:
        raise _not_found(str(exc)) from exc
    except ValueError as exc:
        raise _bad_request(str(exc)) from exc


@app.delete("/rovers/{rover_id}", response_model=ApiMessage)
def delete_rover(rover_id: int) -> ApiMessage:
    try:
        store.delete_rover(rover_id)
        return ApiMessage(detail=f"Rover {rover_id} deleted.")
    except KeyError as exc:
        raise _not_found(str(exc)) from exc


@app.post("/rovers/{rover_id}/dispatch", response_model=DispatchResponse)
def post_dispatch(rover_id: int) -> DispatchResponse:
    try:
        return dispatch_rover(store, rover_id)
    except KeyError as exc:
        raise _not_found(str(exc)) from exc
    except ValueError as exc:
        raise _bad_request(str(exc)) from exc
