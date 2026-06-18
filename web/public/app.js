const state = {
  sessions: [],
  activeId: null,
  socket: null,
  launching: false,
  view: "chat"
};

const els = {
  form: document.querySelector("#launchForm"),
  launchBtn: document.querySelector("#launchBtn"),
  cwd: document.querySelector("#cwd"),
  prompt: document.querySelector("#prompt"),
  sessionList: document.querySelector("#sessionList"),
  activeTitle: document.querySelector("#activeTitle"),
  activeMeta: document.querySelector("#activeMeta"),
  stream: document.querySelector("#stream"),
  terminal: document.querySelector("#terminal"),
  chatTab: document.querySelector("#chatTab"),
  rawTab: document.querySelector("#rawTab"),
  themeBtn: document.querySelector("#themeBtn"),
  runStatus: document.querySelector("#runStatus"),
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

const CWD_STORAGE_KEY = "agent-room.cwd";
const THEME_STORAGE_KEY = "agent-room.theme";
els.cwd.value = localStorage.getItem(CWD_STORAGE_KEY) || "";
setTheme(localStorage.getItem(THEME_STORAGE_KEY) || "dark");

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
        <span>${session.exitCode === null ? "live" : `code ${session.exitCode}`}</span>
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
  els.runStatus.textContent = currentStatusText(session);
  els.message.disabled = !session || session.status !== "running";
  els.sendBtn.disabled = !session || session.status !== "running";
  els.clearBtn.disabled = !session;
  els.stopBtn.disabled = !session || session.status !== "running";
  els.launchBtn.disabled = state.launching;
  els.launchBtn.textContent = state.launching ? "启动中..." : "启动 agent";
  els.chatTab.classList.toggle("active", state.view === "chat");
  els.rawTab.classList.toggle("active", state.view === "raw");
  els.stream.hidden = state.view !== "chat";
  els.terminal.hidden = state.view !== "raw";
}

function connect(sessionId) {
  if (state.socket) state.socket.close();
  const protocol = location.protocol === "https:" ? "wss" : "ws";
  const socket = new WebSocket(`${protocol}://${location.host}/ws?sessionId=${sessionId}`);
  state.socket = socket;

  socket.addEventListener("message", (event) => {
    const payload = JSON.parse(event.data);
    if (payload.type === "snapshot") {
      const index = state.sessions.findIndex((session) => session.id === payload.session.id);
      if (index >= 0) state.sessions[index] = payload.session;
      els.terminal.textContent = "";
      for (const chunk of payload.session.buffer || []) appendRaw(chunk);
      renderTranscript(payload.session.events || payload.session.buffer?.map((text) => ({ type: "output", text })) || []);
      renderSessions();
    }
    if (payload.type === "output") {
      appendRaw(payload.data);
    }
    if (payload.type === "event") {
      if (payload.event?.type === "user") appendUserMessage(payload.event.text);
      if (payload.event?.type === "assistant") appendAssistantMessage(payload.event.text);
      if (payload.event?.type === "system") appendSystemMessage(payload.event.text);
      if (payload.event?.type === "status") setRunStatus(payload.event.text);
    }
    if (payload.type === "assistant_start") startAssistantStream(payload.streamId);
    if (payload.type === "assistant_delta") appendAssistantDelta(payload.streamId, payload.text);
    if (payload.type === "assistant_replace") replaceLatestAssistant(payload.text);
    if (payload.type === "assistant_done") finishAssistantStream(payload.streamId);
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
  setTimeout(() => els.stream.focus(), 80);
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
  localStorage.setItem(CWD_STORAGE_KEY, cwd);

  const existing = state.sessions.find((session) => session.status === "running" && session.cwd === cwd);
  if (existing) {
    activate(existing.id);
    return;
  }

  if (state.launching) return;
  state.launching = true;
  renderSessions();

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
  } finally {
    state.launching = false;
    renderSessions();
  }
});

els.chatTab.addEventListener("click", () => {
  state.view = "chat";
  renderSessions();
  els.stream.focus();
});

els.rawTab.addEventListener("click", () => {
  state.view = "raw";
  renderSessions();
  els.terminal.focus();
});

els.themeBtn.addEventListener("click", () => {
  setTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light");
});

els.stream.addEventListener("keydown", handlePtyKeys);
els.terminal.addEventListener("keydown", handlePtyKeys);

els.composer.addEventListener("submit", (event) => {
  event.preventDefault();
  const value = els.message.value.trimEnd();
  if (!value || !state.socket || state.socket.readyState !== WebSocket.OPEN) return;
  state.socket.send(JSON.stringify({ type: "message", text: value }));
  els.message.value = "";
});

els.message.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    els.composer.requestSubmit();
  }
});

els.clearBtn.addEventListener("click", () => {
  els.stream.innerHTML = "";
  els.terminal.textContent = "";
});

els.stopBtn.addEventListener("click", async () => {
  if (!state.activeId) return;
  await request(`/api/sessions/${state.activeId}`, { method: "DELETE" });
  state.sessions = state.sessions.filter((session) => session.id !== state.activeId);
  state.activeId = state.sessions[0]?.id || null;
  els.stream.innerHTML = "";
  els.terminal.textContent = "";
  renderSessions();
  if (state.activeId) connect(state.activeId);
});

function handlePtyKeys(event) {
  const session = activeSession();
  if (!session || session.status !== "running") return;
  if (!state.socket || state.socket.readyState !== WebSocket.OPEN) return;
  const data = keyToPtyInput(event);
  if (!data) return;
  event.preventDefault();
  state.socket.send(JSON.stringify({ type: "input", data }));
}

function renderTranscript(events) {
  els.stream.innerHTML = "";
  for (const event of coalesceEvents(events)) {
    if (event.type === "user") appendUserMessage(event.text);
    if (event.type === "assistant") appendAssistantMessage(event.text);
    if (event.type === "system") appendSystemMessage(event.text);
    if (event.type === "status") appendStatusMessage(event.text);
  }
  if (!events.length) appendSystemMessage("Claude 会话启动后，安全确认和回答会出现在这里。需要直接按键时，点击这个区域后按 Enter。");
}

function coalesceEvents(events) {
  const result = [];
  for (const event of events) {
    if (event.type === "user") {
      result.push({ type: "user", text: cleanUserInput(event.text) });
      continue;
    }
    if (event.type === "system") {
      const clean = normalizeOutput(event.text);
      if (clean) result.push({ type: "system", text: clean });
      continue;
    }
    if (event.type === "status") {
      const clean = normalizeOutput(event.text);
      if (clean) result.push({ type: "status", text: clean });
      continue;
    }
    if (event.type === "assistant") {
      const clean = normalizeOutput(event.text);
      if (clean) result.push({ type: "assistant", text: clean });
      continue;
    }

    const clean = normalizeOutput(event.text);
    if (!clean) continue;
    const type = classifyOutput(clean);
    const last = result[result.length - 1];
    if (last && last.type === type && type !== "system") {
      last.text = compactJoin(last.text, clean);
    } else {
      result.push({ type, text: clean });
    }
  }
  return result;
}

function appendRaw(data) {
  els.terminal.textContent += stripAnsi(data);
  els.terminal.scrollTop = els.terminal.scrollHeight;
}

function appendAssistantOutput(data) {
  const clean = normalizeOutput(data);
  if (!clean) return;
  const type = classifyOutput(clean);
  if (type === "system") {
    appendSystemMessage(clean);
    return;
  }
  const last = els.stream.lastElementChild;
  if (last?.dataset.role === "assistant") {
    const body = last.querySelector(".bubble-body");
    body.textContent = compactJoin(body.textContent, clean);
  } else {
    appendAssistantMessage(clean);
  }
  els.stream.scrollTop = els.stream.scrollHeight;
}

function appendUserMessage(text) {
  appendBubble("user", cleanUserInput(text));
}

function appendAssistantMessage(text) {
  const clean = String(text || "").trim();
  const last = els.stream.lastElementChild;
  if (last?.dataset.role === "assistant") {
    const body = last.querySelector(".bubble-body");
    if (body?.textContent.trim() === clean) return;
  }
  appendBubble("assistant", text);
}

function appendSystemMessage(text) {
  appendBubble("system", text);
}

function appendStatusMessage(text) {
  setRunStatus(text);
}

function startAssistantStream(streamId) {
  const last = els.stream.lastElementChild;
  if (last?.classList.contains("streaming")) last.remove();
  const item = document.createElement("article");
  item.className = "bubble assistant streaming";
  item.dataset.role = "assistant";
  item.dataset.streamId = streamId;
  item.innerHTML = '<div class="bubble-label">Claude <span class="typing">生成中</span></div><div class="bubble-body"></div>';
  els.stream.appendChild(item);
  els.stream.scrollTop = els.stream.scrollHeight;
  setRunStatus("Claude 正在生成回答...");
}

function appendAssistantDelta(streamId, text) {
  const item = els.stream.querySelector(`[data-stream-id="${streamId}"]`);
  if (!item) return;
  const body = item.querySelector(".bubble-body");
  body.textContent += text;
  els.stream.scrollTop = els.stream.scrollHeight;
}

function finishAssistantStream(streamId) {
  const item = els.stream.querySelector(`[data-stream-id="${streamId}"]`);
  settleAssistantBubble(item);
  setRunStatus("完成。");
}

function replaceLatestAssistant(text) {
  let item = els.stream.querySelector(".bubble.assistant.streaming");
  if (!item) item = [...els.stream.querySelectorAll(".bubble.assistant")].pop();
  if (!item) {
    appendAssistantMessage(text);
    return;
  }
  const body = item.querySelector(".bubble-body");
  if (body) body.textContent = text;
  settleAssistantBubble(item);
  els.stream.scrollTop = els.stream.scrollHeight;
}

function settleAssistantBubble(item) {
  if (!item) return;
  item.classList.remove("streaming");
  item.removeAttribute("data-stream-id");
  const typing = item.querySelector(".typing");
  if (typing) typing.remove();
}

function appendBubble(role, text) {
  const clean = String(text || "").trim();
  if (!clean) return;
  const item = document.createElement("article");
  item.className = `bubble ${role}`;
  item.dataset.role = role;
  item.innerHTML = `<div class="bubble-label">${roleLabel(role)}</div><div class="bubble-body"></div>`;
  item.querySelector(".bubble-body").textContent = clean;
  els.stream.appendChild(item);
  els.stream.scrollTop = els.stream.scrollHeight;
}

function setRunStatus(text) {
  els.runStatus.textContent = text || "空闲";
}

function currentStatusText(session) {
  if (!session) return "空闲";
  const statusEvent = [...(session.events || [])].reverse().find((event) => event.type === "status");
  if (statusEvent?.text) return statusEvent.text;
  return session.status === "running" ? "等待输入" : "已结束";
}

function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem(THEME_STORAGE_KEY, theme);
  if (els.themeBtn) els.themeBtn.textContent = theme === "light" ? "深色" : "浅色";
}

function classifyOutput(text) {
  if (/Permission Required|Quick safety check|Security guide|Enter to confirm|Welcome back|Claude Code v|Auto-updating|Auto-update failed|Yes, I trust this folder/i.test(text)) {
    return "system";
  }
  return "assistant";
}

function normalizeOutput(value) {
  let clean = stripAnsi(value)
    .replace(/\s*●\s+(high|low|medium|max)\s+·\s+\/effort.*$/gim, "")
    .replace(/\b(Philosophising|Herding|Thinking|Tip:)[^\n]*$/gim, "")
    .replace(/\besc to interrupt\b/gi, "")
    .replace(/\binput:/gi, "")
    .replace(/\bclaude:\s*/gi, "")
    .replace(/\byou:\s*/gi, "")
    .replace(/\s{3,}/g, " ")
    .trim();
  if (/Quick safety check/i.test(clean)) return "安全确认：当前工作目录需要信任确认。点击对话区域后按 Enter 继续。";
  if (/Welcome back|Claude Code v/i.test(clean)) return "Claude 已启动，等待输入。";
  if (/Auto-updating/i.test(clean)) return "Claude 正在检查更新。";
  if (/Auto-update failed/i.test(clean)) return "Claude 自动更新失败，可稍后用 claude doctor 检查。";
  if (/^\d{1,3}$/.test(clean)) return "";
  if (/^[─╭╮╰╯│\s]+$/.test(clean)) return "";
  return clean;
}

function cleanUserInput(value) {
  return String(value || "").replace(/\r/g, "").trim();
}

function compactJoin(left, right) {
  const a = String(left || "").trimEnd();
  const b = String(right || "").trimStart();
  if (!a) return b;
  if (!b) return a;
  if (b.startsWith(a)) return b;
  if (a.endsWith(b) || a.includes(b)) return a;
  if (/[\n。！？.!?:：]$/.test(a) || /^[，。！？,.!?:：]/.test(b)) return `${a}${b}`;
  return `${a} ${b}`;
}

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

function roleLabel(role) {
  if (role === "user") return "You";
  if (role === "system") return "System";
  return "Claude";
}

function stripAnsi(value) {
  return String(value)
    .replace(/\r/g, "")
    .replace(/\x1b\[\d+G/g, " ")
    .replace(/\x1b\[\d+C/g, " ")
    .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\x1b[()#][0-9A-Za-z]/g, "")
    .replace(/\x1b[@-Z\\-_]/g, "")
    .replace(/[\x00-\x09\x0b-\x1f\x7f]/g, "");
}

function keyToPtyInput(event) {
  if (event.metaKey || event.ctrlKey || event.altKey) return "";
  if (event.key === "Enter") return "\r";
  if (event.key === "Backspace") return "\x7f";
  if (event.key === "Tab") return "\t";
  if (event.key === "Escape") return "\x1b";
  if (event.key === "ArrowUp") return "\x1b[A";
  if (event.key === "ArrowDown") return "\x1b[B";
  if (event.key === "ArrowRight") return "\x1b[C";
  if (event.key === "ArrowLeft") return "\x1b[D";
  if (event.key.length === 1) return event.key;
  return "";
}

refresh().catch((error) => alert(error.message));
