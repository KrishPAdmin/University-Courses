const state = {
  map: null,
  mines: [],
  roverSummaries: [],
  roverDetails: new Map(),
  selectedMineId: null,
  selectedRoverId: null,
  selectedCell: null,
};

function qs(selector) {
  return document.querySelector(selector);
}

function nowStamp() {
  return new Date().toLocaleString();
}

function setConsole(title, payload) {
  qs("#timestamp").textContent = nowStamp();
  const text = typeof payload === "string" ? payload : JSON.stringify(payload, null, 2);
  qs("#status-console").textContent = `${title}\n\n${text}`;
}

function setMessage(text) {
  qs("#server-message").textContent = text;
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    ...options,
  });

  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const detail = data.detail || `Request failed with status ${response.status}`;
    throw new Error(detail);
  }
  return data;
}

function syncSelectedCellInputs() {
  const cell = state.selectedCell;
  if (!cell) {
    qs("#selected-cell").textContent = "x: -, y: -";
    return;
  }
  qs("#selected-cell").textContent = `x: ${cell.x}, y: ${cell.y}`;
  qs("#mine-x").value = cell.x;
  qs("#mine-y").value = cell.y;
}

function clearMineForm() {
  qs("#mine-id").value = "";
  qs("#mine-x").value = state.selectedCell ? state.selectedCell.x : "";
  qs("#mine-y").value = state.selectedCell ? state.selectedCell.y : "";
  qs("#mine-serial").value = "";
  state.selectedMineId = null;
  renderMineTable();
}

function clearRoverForm() {
  qs("#rover-id").value = "";
  qs("#rover-commands").value = "";
  state.selectedRoverId = null;
  renderRoverTable();
}

function selectMine(mine) {
  state.selectedMineId = mine.id;
  qs("#mine-id").value = mine.id;
  qs("#mine-x").value = mine.x;
  qs("#mine-y").value = mine.y;
  qs("#mine-serial").value = mine.serial_number;
  state.selectedCell = { x: mine.x, y: mine.y };
  syncSelectedCellInputs();
  renderMineTable();
  renderMap();
}

function selectRover(rover) {
  state.selectedRoverId = rover.id;
  qs("#rover-id").value = rover.id;
  qs("#rover-commands").value = rover.commands;
  renderRoverTable();
}

function renderMineTable() {
  const body = qs("#mines-table-body");
  body.innerHTML = "";
  if (!state.mines.length) {
    body.innerHTML = `<tr><td colspan="5">No mines created yet.</td></tr>`;
    return;
  }

  for (const mine of state.mines) {
    const row = document.createElement("tr");
    if (mine.id === state.selectedMineId) {
      row.classList.add("selected-row");
    }
    row.innerHTML = `
      <td>${mine.id}</td>
      <td>(${mine.x}, ${mine.y})</td>
      <td>${mine.serial_number}</td>
      <td>${mine.status}</td>
      <td>${mine.pin || "-"}</td>
    `;
    row.addEventListener("click", () => selectMine(mine));
    body.appendChild(row);
  }
}

function renderRoverTable() {
  const body = qs("#rovers-table-body");
  body.innerHTML = "";
  if (!state.roverSummaries.length) {
    body.innerHTML = `<tr><td colspan="5">No rovers created yet.</td></tr>`;
    return;
  }

  for (const summary of state.roverSummaries) {
    const detail = state.roverDetails.get(summary.id);
    const row = document.createElement("tr");
    if (summary.id === state.selectedRoverId) {
      row.classList.add("selected-row");
    }
    row.innerHTML = `
      <td>${summary.id}</td>
      <td>${summary.status}</td>
      <td>${detail ? `(${detail.latest_position.x}, ${detail.latest_position.y})` : "-"}</td>
      <td>${detail ? detail.direction : "-"}</td>
      <td>${detail ? detail.commands : "-"}</td>
    `;
    row.addEventListener("click", () => {
      if (detail) {
        selectRover(detail);
      }
    });
    body.appendChild(row);
  }
}

function overlayForCell(x, y) {
  const rover = [...state.roverDetails.values()].find(
    (item) => item.latest_position.x === x && item.latest_position.y === y
  );
  if (rover) {
    return { label: `R${rover.id}`, className: "rover" };
  }

  const mine = state.mines.find((item) => item.x === x && item.y === y);
  if (!mine) {
    return { label: `${x},${y}`, className: "empty" };
  }
  if (mine.status === "defused") {
    return { label: `X${mine.id}`, className: "defused" };
  }
  return { label: `M${mine.id}`, className: "mine" };
}

function renderMap() {
  const mapGrid = qs("#map-grid");
  mapGrid.innerHTML = "";
  if (!state.map) {
    return;
  }

  qs("#map-size").textContent = `${state.map.width} × ${state.map.height}`;
  qs("#map-width").value = state.map.width;
  qs("#map-height").value = state.map.height;

  for (let y = 0; y < state.map.height; y += 1) {
    const row = document.createElement("div");
    row.className = "map-row";
    row.style.gridTemplateColumns = `repeat(${state.map.width}, minmax(0, 1fr))`;

    for (let x = 0; x < state.map.width; x += 1) {
      const cell = document.createElement("button");
      const overlay = overlayForCell(x, y);
      cell.className = `map-cell ${overlay.className}`;
      cell.textContent = overlay.label;
      if (state.selectedCell && state.selectedCell.x === x && state.selectedCell.y === y) {
        cell.classList.add("selected");
      }
      cell.addEventListener("click", () => {
        state.selectedCell = { x, y };
        syncSelectedCellInputs();
        renderMap();
      });
      row.appendChild(cell);
    }

    mapGrid.appendChild(row);
  }
}

function renderEvents(events = []) {
  const log = qs("#event-log");
  log.innerHTML = "";
  if (!events.length) {
    log.innerHTML = `<li class="empty">No events yet.</li>`;
    return;
  }

  [...events].reverse().forEach((eventText) => {
    const item = document.createElement("li");
    item.textContent = `[${nowStamp()}] ${eventText}`;
    log.appendChild(item);
  });
}

async function refreshHealth() {
  const data = await api("/health");
  qs("#server-status").textContent = data.status.toUpperCase();
  setMessage(data.message);
  qs("#mine-count").textContent = data.mine_count;
  qs("#rover-count").textContent = data.rover_count;
  return data;
}

async function refreshMap() {
  state.map = await api("/map");
  renderMap();
  return state.map;
}

async function refreshMines() {
  state.mines = await api("/mines");
  qs("#mine-count").textContent = state.mines.length;
  renderMineTable();
  renderMap();
  return state.mines;
}

async function refreshRovers() {
  state.roverSummaries = await api("/rovers");
  const details = await Promise.all(state.roverSummaries.map((summary) => api(`/rovers/${summary.id}`)));
  state.roverDetails = new Map(details.map((detail) => [detail.id, detail]));
  qs("#rover-count").textContent = state.roverSummaries.length;
  renderRoverTable();
  renderMap();
  return details;
}

async function refreshAll() {
  try {
    const [health] = await Promise.all([refreshHealth(), refreshMap(), refreshMines(), refreshRovers()]);
    setConsole("Refresh complete", health);
  } catch (error) {
    setConsole("Refresh failed", error.message);
    setMessage(error.message);
  }
}

function minePayloadFromForm(partial = false) {
  const xValue = qs("#mine-x").value;
  const yValue = qs("#mine-y").value;
  const serial = qs("#mine-serial").value.trim();
  const payload = {};
  if (!partial || xValue !== "") {
    payload.x = Number(xValue);
  }
  if (!partial || yValue !== "") {
    payload.y = Number(yValue);
  }
  if (!partial || serial !== "") {
    payload.serial_number = serial;
  }
  return payload;
}

async function createMine() {
  try {
    const data = await api("/mines", {
      method: "POST",
      body: JSON.stringify(minePayloadFromForm(false)),
    });
    clearMineForm();
    await refreshAll();
    setConsole("Mine created", data);
  } catch (error) {
    setConsole("Create mine failed", error.message);
  }
}

async function updateMine() {
  try {
    const id = Number(qs("#mine-id").value);
    if (!id) {
      throw new Error("Select a mine first.");
    }
    const data = await api(`/mines/${id}`, {
      method: "PUT",
      body: JSON.stringify(minePayloadFromForm(true)),
    });
    await refreshAll();
    selectMine(data);
    setConsole("Mine updated", data);
  } catch (error) {
    setConsole("Update mine failed", error.message);
  }
}

async function deleteMine() {
  try {
    const id = Number(qs("#mine-id").value);
    if (!id) {
      throw new Error("Select a mine first.");
    }
    const data = await api(`/mines/${id}`, { method: "DELETE" });
    clearMineForm();
    await refreshAll();
    setConsole("Mine deleted", data);
  } catch (error) {
    setConsole("Delete mine failed", error.message);
  }
}

async function updateMapSize() {
  try {
    const data = await api("/map", {
      method: "PUT",
      body: JSON.stringify({
        width: Number(qs("#map-width").value),
        height: Number(qs("#map-height").value),
      }),
    });
    state.map = data;
    renderMap();
    await refreshHealth();
    setConsole("Map updated", data);
  } catch (error) {
    setConsole("Map update failed", error.message);
  }
}

async function createRover() {
  try {
    const data = await api("/rovers", {
      method: "POST",
      body: JSON.stringify({
        commands: qs("#rover-commands").value.trim().toUpperCase(),
      }),
    });
    await refreshAll();
    selectRover(data);
    setConsole("Rover created", data);
  } catch (error) {
    setConsole("Create rover failed", error.message);
  }
}

async function updateRover() {
  try {
    const id = Number(qs("#rover-id").value);
    if (!id) {
      throw new Error("Select a rover first.");
    }
    const data = await api(`/rovers/${id}`, {
      method: "PUT",
      body: JSON.stringify({
        commands: qs("#rover-commands").value.trim().toUpperCase(),
      }),
    });
    await refreshAll();
    selectRover(data);
    setConsole("Rover updated", data);
  } catch (error) {
    setConsole("Update rover failed", error.message);
  }
}

async function deleteRover() {
  try {
    const id = Number(qs("#rover-id").value);
    if (!id) {
      throw new Error("Select a rover first.");
    }
    const data = await api(`/rovers/${id}`, { method: "DELETE" });
    clearRoverForm();
    await refreshAll();
    qs("#dispatch-summary").textContent = "No rover dispatched yet";
    qs("#path-output").textContent = "Dispatch a rover to render its path here.";
    renderEvents([]);
    setConsole("Rover deleted", data);
  } catch (error) {
    setConsole("Delete rover failed", error.message);
  }
}

async function dispatchRover() {
  try {
    const id = Number(qs("#rover-id").value);
    if (!id) {
      throw new Error("Select a rover first.");
    }
    const data = await api(`/rovers/${id}/dispatch`, { method: "POST" });
    qs("#dispatch-summary").textContent = `Rover ${data.id} • ${data.status}`;
    qs("#path-output").textContent = data.path_rows.join("\n");
    renderEvents(data.events);
    await refreshAll();
    selectRover(data);
    setConsole("Rover dispatched", data);
  } catch (error) {
    setConsole("Dispatch rover failed", error.message);
  }
}

function bindEvents() {
  qs("#refresh-all-btn").addEventListener("click", refreshAll);
  qs("#refresh-mines-btn").addEventListener("click", refreshMines);
  qs("#refresh-rovers-btn").addEventListener("click", refreshRovers);
  qs("#update-map-btn").addEventListener("click", updateMapSize);

  qs("#create-mine-btn").addEventListener("click", createMine);
  qs("#update-mine-btn").addEventListener("click", updateMine);
  qs("#delete-mine-btn").addEventListener("click", deleteMine);
  qs("#clear-mine-form-btn").addEventListener("click", clearMineForm);

  qs("#create-rover-btn").addEventListener("click", createRover);
  qs("#update-rover-btn").addEventListener("click", updateRover);
  qs("#dispatch-rover-btn").addEventListener("click", dispatchRover);
  qs("#delete-rover-btn").addEventListener("click", deleteRover);
  qs("#clear-rover-form-btn").addEventListener("click", clearRoverForm);
}

async function init() {
  bindEvents();
  syncSelectedCellInputs();
  renderEvents([]);
  await refreshAll();
}

window.addEventListener("DOMContentLoaded", init);
