# COE892 Lab 4-5 Rover Control

FastAPI-based rover and minefield control system built for **COE892 Labs 4 and 5**.

This project implements a web API and browser-based operator interface for managing a minefield map, creating and updating mine records, creating and dispatching rovers, and rendering rover execution results. The final version was validated inside an Ubuntu VM and packaged to run locally in Docker.

## Project scope

This repository combines the work completed for:

- **Lab 4**: REST API + operator interface for rover and mine management
- **Lab 5**: containerized deployment of the Lab 4 system using Docker

Implementation note:

- The system was run and tested **inside a VM** rather than on a cloud deployment target.
- The Dockerized version still provides the full backend and operator UI locally through a browser.

## Features

- FastAPI backend with documented endpoints at `/docs`
- Session-based login page for the operator UI
- Interactive dashboard styled after the ProxSyncQ control plane
- Map resize support
- Mine CRUD operations
- Rover CRUD operations
- Rover dispatch endpoint with step-by-step execution results
- Path rendering with map rows returned by the backend
- Deterministic mine defuse PIN generation from mine serial numbers
- Docker support for local deployment on port `8892`

## Repository layout

```text
.
├── app.py
├── models.py
├── store.py
├── simulator.py
├── requirements.txt
├── Dockerfile
├── start.sh
├── static/
│   ├── app.js
│   └── style.css
└── templates/
    ├── index.html
    └── login.html
```

## Core components

### `app.py`
Main FastAPI application.

Responsibilities:

- initializes the FastAPI server
- mounts static files and Jinja templates
- handles login and logout routes
- serves the main operator dashboard
- exposes API endpoints for map, mines, rovers, and dispatch
- provides `/api/dashboard` for UI refreshes
- provides `/ui/reset-demo` to reset in-memory demo state

### `models.py`
Pydantic request and response models.

Includes:

- map update models
- mine create and update models
- rover create and update models
- rover status, mine status, and direction enums
- dispatch response schema

### `store.py`
In-memory state manager.

Responsibilities:

- stores map dimensions
- stores mine records
- stores rover records
- validates coordinates and conflicts
- resets rover state when commands are changed
- marks mines as defused

### `simulator.py`
Rover execution engine.

Responsibilities:

- processes `L`, `R`, `M`, and `D` commands
- updates rover direction and position
- detects active mines
- handles defuse actions
- marks rovers as eliminated when required
- renders the rover path as row strings for display

### `templates/index.html`
Main dashboard UI.

Provides:

- overview panels
- map interaction section
- mine control section
- rover control section
- dispatch output and event log
- status console

### `templates/login.html`
Simple login form for the UI.

### `static/app.js`
Client-side logic for:

- refreshing dashboard data
- rendering map cells
- filling forms from selected records
- creating, updating, deleting, and dispatching through the API
- displaying backend responses in the status console

### `static/style.css`
Shared visual styling for the operator interface.

## API summary

### Authentication and UI

- `GET /login`
- `POST /login`
- `GET /logout`
- `GET /`
- `GET /api/dashboard`
- `POST /ui/reset-demo`

### Health

- `GET /health`

### Map

- `GET /map`
- `PUT /map`

### Mines

- `GET /mines`
- `GET /mines/{mine_id}`
- `POST /mines`
- `PUT /mines/{mine_id}`
- `DELETE /mines/{mine_id}`

### Rovers

- `GET /rovers`
- `GET /rovers/{rover_id}`
- `POST /rovers`
- `PUT /rovers/{rover_id}`
- `DELETE /rovers/{rover_id}`
- `POST /rovers/{rover_id}/dispatch`

## Rover command logic

Supported rover commands:

- `L` = turn left
- `R` = turn right
- `M` = move forward
- `D` = defuse mine at current position

Execution notes:

- rovers start at `(0, 0)` facing south
- map boundaries are enforced
- moving off an active mine without defusing it eliminates the rover
- if a rover steps onto an active mine, the event log records it
- a mine is defused using a deterministic PIN generated from its serial number
- the dispatch response returns:
  - final rover status
  - latest position
  - direction
  - executed commands
  - `path_rows`
  - event messages

## Default login settings

The app uses these environment variable names:

- `LAB4_UI_USERNAME`
- `LAB4_UI_PASSWORD`
- `LAB4_SESSION_SECRET`

Default fallback values in the code are:

- username: `krishadmin`
- password: `lab4pass`

For real use, change them before deployment.

## Local Python setup

Create and activate a virtual environment, then install the dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Run locally with Uvicorn:

```bash
python -m uvicorn app:app --host 0.0.0.0 --port 8892 --reload
```

Open:

- `http://127.0.0.1:8892/login`
- `http://127.0.0.1:8892/docs`

## Start script

This repository also includes a helper start script:

```bash
chmod +x start.sh
./start.sh
```

The script starts:

```bash
.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8892 --reload
```

## Docker deployment

Build the image:

```bash
docker build -t coe892-lab45-rover-control .
```

Run the container:

```bash
docker run --rm -p 8892:8892 \
  -e LAB4_UI_USERNAME=krishadmin \
  -e LAB4_UI_PASSWORD=lab4pass \
  -e LAB4_SESSION_SECRET=change-this-secret \
  coe892-lab45-rover-control
```

Then open:

- `http://127.0.0.1:8892/login`
- `http://127.0.0.1:8892/docs`

## Example test flow

1. Open the dashboard and log in.
2. Confirm the default map size.
3. Create one or more mines with valid coordinates.
4. Create a rover with a command sequence such as `MMDD` or `LMMMMRMMDD`.
5. Dispatch the rover.
6. Observe:
   - final rover state
   - event log messages
   - path output in the dashboard
   - API response in the status console
7. Use `/docs` to verify each endpoint independently.

## Important implementation note

This version uses an **in-memory store**. That means:

- data resets when the application process restarts
- this is suitable for lab demonstration and testing
- a database-backed version would be needed for persistent storage

## Screenshots and report usage

This repo can be paired with the Lab 4-5 report and screenshots showing:

- the operator dashboard
- mine creation
- rover creation
- rover dispatch
- returned path rows and event log
- FastAPI `/docs` endpoint list

## Author

**Krish Patel**

Built for COE892 Labs 4 and 5.
