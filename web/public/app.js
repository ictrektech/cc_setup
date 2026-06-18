const state = {
  sessions: [],
  activeId: null,
  socket: null
};

const els = {
  form: document.querySelector("#launchForm"),
  cwd: document.querySelector("#cwd"),
  prompt: document.querySelector("#prompt"),
  sessionList: document.querySelector("#sessionList"),
  activeTitle: document.querySelector("#activeTitle"),
  activeMeta: document.querySelector("#activeMeta"),
  terminal: document.querySelector("#terminal"),
  composer: document.querySelector("#composer"),
  message: document.querySelector("#message"),
  sendBtn: document.querySelector("#sendBtn"),
  clearBtn: document.querySelector("#clearBtn"),
  stopBtn: document.querySelector("#stopBtn"),
  commandBadge: document.querySelector("#commandBadge"),
  projectName: document.querySelector("#projectName"),
  runningCount: document.querySelector("#runningCount"),
  doneCount: document.querySelector("#doneCount"),
  totalCount: document.querySelector("#totalCount"),
  inspectStatus: document.querySelector("#inspectStatus"),
  inspectCommand: document.querySelector("#inspectCommand"),
  inspectCwd: document.querySelector("#inspectCwd")
};

els.cwd.value = localStorage.getItem("cc-haha-room.cwd") || "";

async function request(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || response.statusText);
  return data;
}

function activeSession() {
  return state.sessions.find((session) => session.id === state.activeId);
}

function renderSessions() {
  els.sessionList.innerHTML = "";
  const running = state.sessions.filter((session) => session.status === "running").length;
  const done = state.sessions.filter((session) => session.status !== "running").length;
  els.runningCount.textContent = running;
  els.doneCount.textContent = done;
  els.totalCount.textContent = state.sessions.length;

  if (!state.sessions.length) {
    const empty = document.createElement("div");
    empty.className = "room-card empty";
    empty.textContent = "还没有 agent 房间";
    els.sessionList.appendChild(empty);
  }

  for (const session of state.sessions) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = `room-card${session.id === state.activeId ? " active" : ""}`;
    item.innerHTML = `
      <div class="room-top">
        <div class="role-dot">C</div>
        <span class="status ${session.status}">${escapeHtml(session.status)}</span>
      </div>
      <div>
        <strong>${escapeHtml(session.title)}</strong>
        <div class="room-path">${escapeHtml(session.cwd)}</div>
      </div>
      <div class="room-bottom">
        <span>Claude</span>
        <span>${session.exitCode === null ? "" : `code ${session.exitCode}`}</span>
      </div>
    `;
    item.addEventListener("click", () => activate(session.id));
    els.sessionList.appendChild(item);
  }

  const session = activeSession();
  els.activeTitle.textContent = session ? session.title : "还没有会话";
  els.activeMeta.textContent = session ? `${session.command} · ${session.cwd}` : "选择项目目录，启动一个 Claude agent";
  els.projectName.textContent = session ? basename(session.cwd) : basename(els.cwd.value) || "未选择";
  els.inspectStatus.textContent = session?.status || "空闲";
  els.inspectCommand.textContent = session?.command || "-";
  els.inspectCwd.textContent = session?.cwd || "-";
  els.message.disabled = !session || session.status !== "running";
  els.sendBtn.disabled = !session || session.status !== "running";
  els.clearBtn.disabled = !session;
  els.stopBtn.disabled = !session || session.status !== "running";
}

function appendTerminal(data) {
  els.terminal.textContent += stripAnsi(data);
  els.terminal.scrollTop = els.terminal.scrollHeight;
}

function connect(sessionId) {
  if (state.socket) state.socket.close();
  const protocol = location.protocol === "https:" ? "wss" : "ws";
  const socket = new WebSocket(`${protocol}://${location.host}/ws?sessionId=${sessionId}`);
  state.socket = socket;

  socket.addEventListener("message", (event) => {
    const payload = JSON.parse(event.data);
    if (payload.type === "snapshot") {
      els.terminal.textContent = "";
      for (const chunk of payload.session.buffer || []) appendTerminal(chunk);
      const index = state.sessions.findIndex((session) => session.id === payload.session.id);
      if (index >= 0) state.sessions[index] = payload.session;
      renderSessions();
    }
    if (payload.type === "output") appendTerminal(payload.data);
    if (payload.type === "status") {
      const session = state.sessions.find((item) => item.id === payload.sessionId);
      if (session) {
        session.status = payload.status;
        session.exitCode = payload.exitCode;
      }
      renderSessions();
    }
  });
}

function activate(sessionId) {
  state.activeId = sessionId;
  connect(sessionId);
  renderSessions();
}

async function refresh() {
  const health = await request("/api/health");
  els.commandBadge.textContent = health.command ? basename(health.command) : "未找到";
  state.sessions = await request("/api/sessions");
  if (!state.activeId && state.sessions.length) state.activeId = state.sessions[0].id;
  renderSessions();
  if (state.activeId) connect(state.activeId);
}

els.form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const cwd = els.cwd.value.trim();
  localStorage.setItem("cc-haha-room.cwd", cwd);

  try {
    const session = await request("/api/sessions", {
      method: "POST",
      body: JSON.stringify({
        cwd,
        title: basename(cwd) || "Claude",
        prompt: els.prompt.value,
        cols: 120,
        rows: 36
      })
    });
    state.sessions.unshift(session);
    els.prompt.value = "";
    activate(session.id);
  } catch (error) {
    alert(error.message);
  }
});

els.composer.addEventListener("submit", async (event) => {
  event.preventDefault();
  const value = els.message.value.trimEnd();
  if (!value || !state.socket || state.socket.readyState !== WebSocket.OPEN) return;
  state.socket.send(JSON.stringify({ type: "input", data: `${value}\r` }));
  els.message.value = "";
});

els.message.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    els.composer.requestSubmit();
  }
});

els.clearBtn.addEventListener("click", () => {
  els.terminal.textContent = "";
});

els.stopBtn.addEventListener("click", async () => {
  if (!state.activeId) return;
  await request(`/api/sessions/${state.activeId}`, { method: "DELETE" });
  state.sessions = state.sessions.filter((session) => session.id !== state.activeId);
  state.activeId = state.sessions[0]?.id || null;
  els.terminal.textContent = "";
  renderSessions();
  if (state.activeId) connect(state.activeId);
});

function basename(value) {
  const trimmed = String(value || "").replace(/\/+$/, "");
  return trimmed.split("/").pop() || trimmed;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function stripAnsi(value) {
  return String(value).replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
}

refresh().catch((error) => alert(error.message));
