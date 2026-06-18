import express from "express";
import http from "http";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";
import { randomUUID } from "crypto";
import { execFileSync } from "child_process";
import pty from "node-pty";
import { WebSocketServer } from "ws";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });
const sessions = new Map();

const PORT = Number(process.env.PORT || 3766);
const DEFAULT_COMMANDS = [
  process.env.CLAUDE_BIN,
  "claude"
].filter(Boolean);

app.use(express.json({ limit: "1mb" }));
app.use("/xterm", express.static(path.join(__dirname, "node_modules/@xterm/xterm")));
app.use(express.static(path.join(__dirname, "public")));

function resolveCommand() {
  for (const candidate of DEFAULT_COMMANDS) {
    if (candidate.includes("/") && candidate.startsWith("~")) {
      const expanded = path.join(os.homedir(), candidate.slice(2));
      return expanded;
    }

    try {
      const resolved = execFileSync("bash", ["-lc", `command -v ${shellQuote(candidate)}`], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"]
      }).trim();
      if (resolved) return resolved;
    } catch {
      if (candidate.includes("/")) return candidate;
    }
  }

  return null;
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function normalizeCwd(input) {
  const cwd = (input || process.cwd()).trim();
  const expanded = cwd === "~" ? os.homedir() : cwd.startsWith("~/") ? path.join(os.homedir(), cwd.slice(2)) : cwd;
  return path.resolve(expanded);
}

function serializeSession(session) {
  return {
    id: session.id,
    title: session.title,
    cwd: session.cwd,
    command: session.command,
    status: session.status,
    createdAt: session.createdAt,
    lastOutputAt: session.lastOutputAt,
    exitCode: session.exitCode,
    buffer: session.buffer.slice(-300)
  };
}

function broadcast(session, payload) {
  const message = JSON.stringify({ sessionId: session.id, ...payload });
  for (const client of session.clients) {
    if (client.readyState === client.OPEN) client.send(message);
  }
}

app.get("/api/health", (_req, res) => {
  res.json({
    ok: true,
    command: resolveCommand(),
    cwd: process.cwd()
  });
});

app.get("/api/sessions", (_req, res) => {
  res.json([...sessions.values()].map(serializeSession));
});

app.post("/api/sessions", (req, res) => {
  const command = resolveCommand();
  if (!command) {
    res.status(400).json({
      error: "未找到 claude。可用 CLAUDE_BIN=/path/to/claude npm run dev 指定。"
    });
    return;
  }

  const cwd = normalizeCwd(req.body?.cwd);
  const title = (req.body?.title || path.basename(cwd) || "Claude").trim();
  const initialPrompt = (req.body?.prompt || "").trim();
  const cols = Number(req.body?.cols || 120);
  const rows = Number(req.body?.rows || 34);
  const args = Array.isArray(req.body?.args) ? req.body.args.map(String) : [];

  const id = randomUUID();
  let term;

  try {
    term = pty.spawn(command, args, {
      name: "xterm-256color",
      cols,
      rows,
      cwd,
      env: {
        ...process.env,
        TERM: "xterm-256color",
        COLORTERM: "truecolor"
      }
    });
  } catch (error) {
    res.status(500).json({
      error: `启动失败：${error.message}`,
      command,
      cwd
    });
    return;
  }

  const session = {
    id,
    title,
    cwd,
    command,
    status: "running",
    createdAt: new Date().toISOString(),
    lastOutputAt: null,
    exitCode: null,
    buffer: [],
    clients: new Set(),
    term
  };

  term.onData((data) => {
    session.lastOutputAt = new Date().toISOString();
    session.buffer.push(data);
    if (session.buffer.length > 800) session.buffer.splice(0, session.buffer.length - 800);
    broadcast(session, { type: "output", data });
  });

  term.onExit(({ exitCode }) => {
    session.status = "exited";
    session.exitCode = exitCode;
    broadcast(session, { type: "status", status: session.status, exitCode });
  });

  sessions.set(id, session);

  if (initialPrompt) {
    setTimeout(() => term.write(`${initialPrompt}\r`), 500);
  }

  res.status(201).json(serializeSession(session));
});

app.post("/api/sessions/:id/input", (req, res) => {
  const session = sessions.get(req.params.id);
  if (!session) {
    res.status(404).json({ error: "会话不存在" });
    return;
  }
  session.term.write(String(req.body?.data || ""));
  res.json({ ok: true });
});

app.post("/api/sessions/:id/resize", (req, res) => {
  const session = sessions.get(req.params.id);
  if (!session) {
    res.status(404).json({ error: "会话不存在" });
    return;
  }
  session.term.resize(Number(req.body?.cols || 120), Number(req.body?.rows || 34));
  res.json({ ok: true });
});

app.delete("/api/sessions/:id", (req, res) => {
  const session = sessions.get(req.params.id);
  if (!session) {
    res.status(404).json({ error: "会话不存在" });
    return;
  }
  session.term.kill();
  sessions.delete(session.id);
  res.json({ ok: true });
});

wss.on("connection", (ws, req) => {
  const url = new URL(req.url || "/", `http://${req.headers.host}`);
  const session = sessions.get(url.searchParams.get("sessionId"));
  if (!session) {
    ws.close(1008, "Unknown session");
    return;
  }

  session.clients.add(ws);
  ws.send(JSON.stringify({ sessionId: session.id, type: "snapshot", session: serializeSession(session) }));

  ws.on("message", (raw) => {
    try {
      const event = JSON.parse(raw.toString());
      if (event.type === "input") session.term.write(String(event.data || ""));
      if (event.type === "resize") session.term.resize(Number(event.cols || 120), Number(event.rows || 34));
    } catch {
      session.term.write(raw.toString());
    }
  });

  ws.on("close", () => session.clients.delete(ws));
});

server.listen(PORT, () => {
  console.log(`agent-room listening on http://localhost:${PORT}`);
  console.log(`Claude command: ${resolveCommand() || "not found"}`);
});
