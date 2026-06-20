const state = {
  sessions: [],
  activeId: null,
  socket: null,
  launching: false,
  view: "chat",
  selectedGitPath: "",
  selectedFilePath: "",
  currentFileLanguage: "text",
  selectedCommit: "",
  openFiles: []
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
  editorPane: document.querySelector("#editorPane"),
  chatTab: document.querySelector("#chatTab"),
  rawTab: document.querySelector("#rawTab"),
  fileTabs: document.querySelector("#fileTabs"),
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
  inspectCwd: document.querySelector("#inspectCwd"),
  gitRefreshBtn: document.querySelector("#gitRefreshBtn"),
  gitSummary: document.querySelector("#gitSummary"),
  gitGraph: document.querySelector("#gitGraph"),
  gitFiles: document.querySelector("#gitFiles"),
  gitDiff: document.querySelector("#gitDiff"),
  gitStageFileBtn: document.querySelector("#gitStageFileBtn"),
  gitUnstageFileBtn: document.querySelector("#gitUnstageFileBtn"),
  gitStageBtn: document.querySelector("#gitStageBtn"),
  gitUnstageBtn: document.querySelector("#gitUnstageBtn"),
  gitMessage: document.querySelector("#gitMessage"),
  gitCommitBtn: document.querySelector("#gitCommitBtn"),
  gitFetchBtn: document.querySelector("#gitFetchBtn"),
  gitPullBtn: document.querySelector("#gitPullBtn"),
  gitPushBtn: document.querySelector("#gitPushBtn"),
  gitOutput: document.querySelector("#gitOutput"),
  fileRefreshBtn: document.querySelector("#fileRefreshBtn"),
  fileStatus: document.querySelector("#fileStatus"),
  fileTree: document.querySelector("#fileTree"),
  fileName: document.querySelector("#fileName"),
  fileSaveBtn: document.querySelector("#fileSaveBtn"),
  codeEditor: document.querySelector("#codeEditor"),
  editorHighlight: document.querySelector("#editorHighlight"),
  fileEditor: document.querySelector("#fileEditor")
};

const CWD_STORAGE_KEY = "agent-room.cwd";
const THEME_STORAGE_KEY = "agent-room.theme";
els.cwd.value = localStorage.getItem(CWD_STORAGE_KEY) || "";
setTheme(localStorage.getItem(THEME_STORAGE_KEY) || "light");

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
  els.editorPane.hidden = state.view !== "editor";
  els.composer.hidden = state.view !== "chat";
  setGitEnabled(Boolean(session));
  setFileEnabled(Boolean(session));
  renderFileTabs();
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
    if (payload.type === "session_update") {
      const index = state.sessions.findIndex((session) => session.id === payload.session.id);
      if (index >= 0) state.sessions[index] = payload.session;
      renderSessions();
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
  refreshGit();
  refreshFiles();
  setTimeout(() => els.stream.focus(), 80);
}

async function refresh() {
  const health = await request("/api/health");
  els.commandBadge.textContent = health.command ? basename(health.command) : "未找到";
  state.sessions = await request("/api/sessions");
  if (!state.activeId && state.sessions.length) state.activeId = state.sessions[0].id;
  renderSessions();
  if (state.activeId) {
    connect(state.activeId);
    refreshGit();
    refreshFiles();
  }
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

els.gitRefreshBtn.addEventListener("click", refreshGit);
els.gitStageFileBtn.addEventListener("click", () => {
  if (!state.selectedGitPath) {
    els.gitOutput.textContent = "请先选择一个文件。";
    return;
  }
  runGitAction("stage", { paths: [state.selectedGitPath] });
});
els.gitUnstageFileBtn.addEventListener("click", () => {
  if (!state.selectedGitPath) {
    els.gitOutput.textContent = "请先选择一个文件。";
    return;
  }
  runGitAction("unstage", { paths: [state.selectedGitPath] });
});
els.gitStageBtn.addEventListener("click", () => runGitAction("stage"));
els.gitUnstageBtn.addEventListener("click", () => runGitAction("unstage"));
els.gitFetchBtn.addEventListener("click", () => runGitAction("fetch"));
els.gitPullBtn.addEventListener("click", () => runGitAction("pull"));
els.gitPushBtn.addEventListener("click", () => runGitAction("push"));
els.gitCommitBtn.addEventListener("click", () => runGitAction("commit", { message: els.gitMessage.value.trim() }));
els.fileRefreshBtn.addEventListener("click", refreshFiles);
els.fileSaveBtn.addEventListener("click", saveCurrentFile);
els.fileEditor.addEventListener("input", () => {
  renderCodeHighlight(els.fileEditor.value, state.currentFileLanguage);
});
els.fileEditor.addEventListener("scroll", () => {
  els.editorHighlight.scrollTop = els.fileEditor.scrollTop;
  els.editorHighlight.scrollLeft = els.fileEditor.scrollLeft;
});

function activeCwd() {
  return activeSession()?.cwd || els.cwd.value.trim();
}

function setGitEnabled(enabled) {
  for (const button of [
    els.gitRefreshBtn,
    els.gitStageFileBtn,
    els.gitUnstageFileBtn,
    els.gitStageBtn,
    els.gitUnstageBtn,
    els.gitCommitBtn,
    els.gitFetchBtn,
    els.gitPullBtn,
    els.gitPushBtn
  ]) {
    button.disabled = !enabled;
  }
}

function setFileEnabled(enabled) {
  els.fileRefreshBtn.disabled = !enabled;
  els.fileEditor.disabled = !enabled || !state.selectedFilePath;
  els.fileSaveBtn.disabled = !enabled || !state.selectedFilePath;
}

async function refreshGit() {
  const cwd = activeCwd();
  if (!cwd) {
    renderGitError("选择一个 git 仓库目录");
    return;
  }
  try {
    const summary = await request(`/api/git?cwd=${encodeURIComponent(cwd)}`);
    renderGit(summary);
  } catch (error) {
    renderGitError(error.message);
  }
}

function renderGit(summary) {
  els.gitSummary.innerHTML = `
    <strong>${escapeHtml(summary.branch)}</strong>
    <span>${escapeHtml(summary.repo)}</span>
    <span>${summary.clean ? "clean" : `${summary.files.length} changed`} · ${summary.ahead} ahead · ${summary.behind} behind</span>
  `;
  els.gitFiles.innerHTML = "";
  state.selectedGitPath = "";
  renderGitGraph(summary.commits || []);
  if (!summary.files.length) {
    const empty = document.createElement("div");
    empty.className = "git-file empty";
    empty.textContent = "工作区干净";
    els.gitFiles.appendChild(empty);
  }
  for (const file of summary.files) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = "git-file";
    item.innerHTML = `<span>${escapeHtml(`${file.index}${file.worktree}`)}</span><strong>${escapeHtml(file.path)}</strong>`;
    item.addEventListener("click", () => selectGitFile(file.path, item));
    els.gitFiles.appendChild(item);
  }
  els.gitDiff.textContent = summary.log.length ? summary.log.join("\n") : "No commits yet";
  els.gitOutput.textContent = summary.output || "";
}

function renderGitError(message) {
  els.gitSummary.textContent = message;
  els.gitGraph.innerHTML = "";
  els.gitFiles.innerHTML = "";
  els.gitDiff.textContent = "";
  els.gitOutput.textContent = "";
}

function renderGitGraph(commits) {
  els.gitGraph.innerHTML = "";
  if (!commits.length) {
    els.gitGraph.textContent = "No graph yet";
    return;
  }
  const graph = buildGraphModel(commits.slice(0, 40));
  const laneWidth = 18;
  const rowHeight = 31;
  const leftPad = 13;
  const topPad = 15;
  const graphWidth = Math.max(72, (graph.laneCount + 1) * laneWidth + leftPad * 2);
  const height = graph.rows.length * rowHeight + topPad * 2;
  const palette = ["#2f9e61", "#007aff", "#af52de", "#ff9500", "#ff2d55", "#5ac8fa"];
  const container = document.createElement("div");
  container.className = "graph-canvas";
  container.style.minHeight = `${height}px`;
  container.style.setProperty("--graph-width", `${graphWidth}px`);
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("width", graphWidth);
  svg.setAttribute("height", height);
  svg.setAttribute("viewBox", `0 0 ${graphWidth} ${height}`);
  for (const edge of graph.edges) {
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    const x1 = leftPad + edge.fromLane * laneWidth;
    const y1 = topPad + edge.fromRow * rowHeight;
    const x2 = leftPad + edge.toLane * laneWidth;
    const y2 = topPad + edge.toRow * rowHeight;
    const midY = y1 + rowHeight * 0.55;
    path.setAttribute("d", `M ${x1} ${y1} C ${x1} ${midY}, ${x2} ${midY}, ${x2} ${y2}`);
    path.setAttribute("stroke", palette[edge.fromLane % palette.length]);
    path.setAttribute("class", "graph-edge");
    svg.appendChild(path);
  }
  for (const row of graph.rows) {
    const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    circle.setAttribute("cx", leftPad + row.lane * laneWidth);
    circle.setAttribute("cy", topPad + row.row * rowHeight);
    circle.setAttribute("r", row.commit.parents.length > 1 ? "5.6" : "4.8");
    circle.setAttribute("fill", palette[row.lane % palette.length]);
    circle.setAttribute("class", "graph-node");
    svg.appendChild(circle);
  }
  container.appendChild(svg);
  const list = document.createElement("div");
  list.className = "graph-list";
  list.style.marginLeft = `${graphWidth}px`;
  for (const row of graph.rows) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `commit-row${state.selectedCommit === row.commit.hash ? " selected" : ""}`;
    button.style.top = `${topPad + row.row * rowHeight - 13}px`;
    button.innerHTML = `
      <span class="commit-hash">${escapeHtml(row.commit.short)}</span>
      <strong>${escapeHtml(row.commit.subject)}</strong>
      ${row.commit.refs ? `<em>${escapeHtml(shortRefs(row.commit.refs))}</em>` : ""}
    `;
    button.addEventListener("click", () => selectCommit(row.commit));
    list.appendChild(button);
  }
  container.appendChild(list);
  els.gitGraph.appendChild(container);
}

function buildGraphModel(commits) {
  const rows = [];
  const edges = [];
  const visibleRows = new Map();
  const active = [];
  commits.forEach((commit, row) => {
    if (!active.includes(commit.hash)) active.unshift(commit.hash);
    let lane = active.indexOf(commit.hash);
    if (lane < 0) lane = 0;
    rows.push({ commit, row, lane });
    visibleRows.set(commit.hash, { row, lane });
    const parents = commit.parents || [];
    active.splice(lane, 1, parents[0] || null);
    for (let index = 1; index < parents.length; index += 1) {
      active.splice(lane + index, 0, parents[index]);
    }
    for (let index = active.length - 1; index >= 0; index -= 1) {
      if (!active[index]) active.splice(index, 1);
    }
  });
  for (const row of rows) {
    for (const parent of row.commit.parents || []) {
      const target = visibleRows.get(parent);
      if (target) edges.push({ fromRow: row.row, fromLane: row.lane, toRow: target.row, toLane: target.lane });
    }
  }
  return { rows, edges, laneCount: Math.max(1, ...rows.map((row) => row.lane + 1)) };
}

function selectCommit(commit) {
  state.selectedCommit = commit.hash;
  for (const node of els.gitGraph.querySelectorAll(".commit-row")) node.classList.remove("selected");
  const refs = commit.refs ? `\nrefs: ${commit.refs}` : "";
  els.gitOutput.textContent = `${commit.short} ${commit.subject}${refs}\n${commit.hash}`;
  const selected = [...els.gitGraph.querySelectorAll(".commit-row")].find((node) => node.textContent.includes(commit.short));
  if (selected) selected.classList.add("selected");
}

function shortRefs(refs) {
  return refs
    .replaceAll("HEAD -> ", "")
    .replaceAll("refs/heads/", "")
    .replaceAll("refs/remotes/", "")
    .split(", ")
    .slice(0, 2)
    .join(", ");
}

async function loadGitDiff(path) {
  const cwd = activeCwd();
  try {
    const unstaged = await request(`/api/git?view=diff&cwd=${encodeURIComponent(cwd)}&path=${encodeURIComponent(path)}`);
    const staged = await request(`/api/git?view=diff&staged=1&cwd=${encodeURIComponent(cwd)}&path=${encodeURIComponent(path)}`);
    els.gitDiff.textContent = [staged.diff && `# staged\n${staged.diff}`, unstaged.diff && `# unstaged\n${unstaged.diff}`]
      .filter(Boolean)
      .join("\n") || "No diff for this file";
  } catch (error) {
    els.gitDiff.textContent = error.message;
  }
}

function selectGitFile(path, item) {
  state.selectedGitPath = path;
  for (const node of els.gitFiles.querySelectorAll(".git-file")) node.classList.remove("selected");
  item.classList.add("selected");
  loadGitDiff(path);
}

async function runGitAction(action, extra = {}) {
  const cwd = activeCwd();
  if (action === "commit" && !extra.message) {
    els.gitOutput.textContent = "提交信息不能为空。";
    return;
  }
  els.gitOutput.textContent = `${action}...`;
  try {
    const summary = await request(`/api/git/${action}`, {
      method: "POST",
      body: JSON.stringify({ cwd, ...extra })
    });
    renderGit(summary);
    if (action === "commit" || action === "stage" || action === "unstage") refreshFiles();
    if (action === "commit") els.gitMessage.value = "";
  } catch (error) {
    els.gitOutput.textContent = error.message;
  }
}

async function refreshFiles() {
  const cwd = activeCwd();
  if (!cwd) {
    renderFileError("选择项目后加载文件");
    return;
  }
  try {
    const data = await request(`/api/files?cwd=${encodeURIComponent(cwd)}`);
    renderFileTree(data);
  } catch (error) {
    renderFileError(error.message);
  }
}

function renderFileTree(data) {
  els.fileTree.innerHTML = "";
  els.fileStatus.textContent = `${basename(data.root)} · ${data.files.length} files${data.truncated ? " · truncated" : ""}`;
  if (!data.files.length) {
    const empty = document.createElement("div");
    empty.className = "file-item empty";
    empty.textContent = "没有可编辑文本文件";
    els.fileTree.appendChild(empty);
    return;
  }
  const tree = buildFileTree(data.files);
  renderTreeNode(tree, els.fileTree, 0);
}

function buildFileTree(files) {
  const root = { dirs: new Map(), files: [] };
  for (const file of files) {
    const parts = file.path.split("/");
    let node = root;
    for (const part of parts.slice(0, -1)) {
      if (!node.dirs.has(part)) node.dirs.set(part, { name: part, dirs: new Map(), files: [] });
      node = node.dirs.get(part);
    }
    node.files.push(file);
  }
  return root;
}

function renderTreeNode(node, container, depth) {
  for (const dir of [...node.dirs.values()].sort((a, b) => a.name.localeCompare(b.name))) {
    const details = document.createElement("details");
    details.className = "tree-folder";
    details.open = depth < 1;
    const summary = document.createElement("summary");
    summary.innerHTML = `<span class="folder-icon">▸</span><strong>${escapeHtml(dir.name)}</strong>`;
    details.appendChild(summary);
    const branch = document.createElement("div");
    branch.className = "tree-branch";
    renderTreeNode(dir, branch, depth + 1);
    details.appendChild(branch);
    container.appendChild(details);
  }
  for (const file of node.files.sort((a, b) => a.path.localeCompare(b.path))) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = `file-item${file.path === state.selectedFilePath ? " selected" : ""}`;
    item.innerHTML = `<strong>${escapeHtml(file.name)}</strong><span>${escapeHtml(file.language)}</span>`;
    item.title = file.path;
    item.disabled = !file.editable;
    item.addEventListener("click", () => openFile(file.path, item));
    container.appendChild(item);
  }
}

function renderFileError(message) {
  els.fileStatus.textContent = message;
  els.fileTree.innerHTML = "";
}

async function openFile(path, item) {
  const cwd = activeCwd();
  try {
    const data = await request(`/api/files?view=read&cwd=${encodeURIComponent(cwd)}&path=${encodeURIComponent(path)}`);
    state.selectedFilePath = data.path;
    state.currentFileLanguage = data.language || "text";
    if (!state.openFiles.find((file) => file.path === data.path)) {
      state.openFiles.push({ path: data.path, language: state.currentFileLanguage });
    }
    state.view = "editor";
    els.fileName.textContent = data.path;
    els.codeEditor.dataset.language = state.currentFileLanguage;
    els.fileEditor.value = data.content;
    renderCodeHighlight(data.content, state.currentFileLanguage);
    for (const node of els.fileTree.querySelectorAll(".file-item")) node.classList.remove("selected");
    item.classList.add("selected");
    setFileEnabled(true);
    renderSessions();
  } catch (error) {
    els.fileStatus.textContent = error.message;
  }
}

function renderFileTabs() {
  els.fileTabs.innerHTML = "";
  for (const file of state.openFiles) {
    const tab = document.createElement("button");
    tab.type = "button";
    tab.className = `ghost file-tab${state.view === "editor" && state.selectedFilePath === file.path ? " active" : ""}`;
    tab.innerHTML = `<span>${escapeHtml(basename(file.path))}</span><b>×</b>`;
    tab.title = file.path;
    tab.addEventListener("click", () => reopenFile(file.path));
    tab.querySelector("b").addEventListener("click", (event) => {
      event.stopPropagation();
      closeFileTab(file.path);
    });
    els.fileTabs.appendChild(tab);
  }
}

async function reopenFile(path) {
  const selected = [...els.fileTree.querySelectorAll(".file-item")].find((item) => item.title === path);
  if (selected) return openFile(path, selected);
  return openFile(path, document.createElement("button"));
}

function closeFileTab(path) {
  state.openFiles = state.openFiles.filter((file) => file.path !== path);
  if (state.selectedFilePath === path) {
    const next = state.openFiles[state.openFiles.length - 1];
    if (next) {
      reopenFile(next.path);
    } else {
      state.selectedFilePath = "";
      state.currentFileLanguage = "text";
      state.view = "chat";
      els.fileName.textContent = "未选择文件";
      els.fileEditor.value = "";
      renderCodeHighlight("", "text");
      setFileEnabled(Boolean(activeSession()));
      renderSessions();
    }
    return;
  }
  renderFileTabs();
}

async function saveCurrentFile() {
  if (!state.selectedFilePath) return;
  els.fileStatus.textContent = "保存中...";
  try {
    await request("/api/files", {
      method: "POST",
      body: JSON.stringify({ cwd: activeCwd(), path: state.selectedFilePath, content: els.fileEditor.value })
    });
    els.fileStatus.textContent = `已保存 ${state.selectedFilePath}`;
    refreshGit();
  } catch (error) {
    els.fileStatus.textContent = error.message;
  }
}

function renderCodeHighlight(value, language) {
  els.editorHighlight.innerHTML = highlightCode(value, language) + "\n";
}

function highlightCode(value, language) {
  const keywords = new Set([
    "function", "const", "let", "var", "return", "if", "else", "for", "while", "class", "import", "from", "export",
    "async", "await", "def", "try", "except", "with", "as", "True", "False", "None", "public", "private", "static",
    "void", "new", "type", "interface", "struct", "enum", "package"
  ]);
  return String(value || "").split("\n").map((line) => {
    const commentIndex = findCommentIndex(line, language);
    const code = commentIndex >= 0 ? line.slice(0, commentIndex) : line;
    const comment = commentIndex >= 0 ? line.slice(commentIndex) : "";
    const pattern = /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d+(?:\.\d+)?\b|\b[A-Za-z_][A-Za-z0-9_]*\b)/g;
    let highlighted = "";
    let lastIndex = 0;
    for (const match of code.matchAll(pattern)) {
      const token = match[0];
      highlighted += escapeHtml(code.slice(lastIndex, match.index));
      if (/^["'`]/.test(token)) highlighted += `<span class="tok-string">${escapeHtml(token)}</span>`;
      else if (/^\d/.test(token)) highlighted += `<span class="tok-number">${escapeHtml(token)}</span>`;
      else if (keywords.has(token)) highlighted += `<span class="tok-keyword">${escapeHtml(token)}</span>`;
      else highlighted += escapeHtml(token);
      lastIndex = match.index + token.length;
    }
    highlighted += escapeHtml(code.slice(lastIndex));
    return highlighted + (comment ? `<span class="tok-comment">${escapeHtml(comment)}</span>` : "");
  }).join("\n");
}

function findCommentIndex(line, language) {
  if (["python", "shell", "yaml", "toml"].includes(language)) return line.indexOf("#");
  const slash = line.indexOf("//");
  return slash >= 0 ? slash : -1;
}

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

    if (event.type === "output") continue;
    const clean = normalizeOutput(event.text);
    if (!clean || looksLikeJsonEvent(clean)) continue;
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
  if (!clean || looksLikeJsonEvent(clean)) return;
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
  if (session.busy) return "Claude 正在处理";
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

function looksLikeJsonEvent(value) {
  const text = String(value || "").trim();
  if (!text.startsWith("{") || !text.endsWith("}")) return false;
  try {
    const data = JSON.parse(text);
    return ["system", "assistant", "user", "result", "stream_event", "runner_complete"].includes(data?.type);
  } catch {
    return false;
  }
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
