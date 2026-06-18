#!/usr/bin/env python3
import base64
import hashlib
import http.server
import json
import os
import pty
import selectors
import shutil
import signal
import socketserver
import struct
import subprocess
import threading
import time
import uuid
from collections import deque
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
PUBLIC = ROOT / "public"
PORT = int(os.environ.get("PORT", "3766"))
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
sessions = {}
sessions_lock = threading.RLock()


def resolve_command():
    candidates = [
        os.environ.get("CLAUDE_BIN"),
        os.environ.get("CLAUDE_HAHA_BIN"),
        "claude",
        "claude-haha",
    ]
    for candidate in [item for item in candidates if item]:
        expanded = os.path.expanduser(candidate)
        if "/" in expanded and os.path.exists(expanded):
            return expanded
        found = shutil.which(candidate)
        if found:
            return found
    return None


def normalize_cwd(value):
    if not value:
        return os.getcwd()
    return str(Path(os.path.expanduser(value)).resolve())


def resize_pty(fd, cols, rows):
    import fcntl
    import termios

    packed = struct.pack("HHHH", int(rows), int(cols), 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, packed)


class WsClient:
    def __init__(self, handler):
        self.handler = handler
        self.lock = threading.Lock()
        self.alive = True

    def send_json(self, payload):
        self.send_text(json.dumps(payload, ensure_ascii=False))

    def send_text(self, text):
        data = text.encode("utf-8", errors="replace")
        if len(data) < 126:
            header = bytes([0x81, len(data)])
        elif len(data) < 65536:
            header = bytes([0x81, 126]) + struct.pack("!H", len(data))
        else:
            header = bytes([0x81, 127]) + struct.pack("!Q", len(data))
        with self.lock:
            if not self.alive:
                return
            try:
                self.handler.wfile.write(header + data)
                self.handler.wfile.flush()
            except OSError:
                self.alive = False

    def close(self):
        self.alive = False


class Session:
    def __init__(self, title, cwd, command, args, cols, rows):
        self.id = str(uuid.uuid4())
        self.title = title
        self.cwd = cwd
        self.command = command
        self.status = "running"
        self.created_at = iso_now()
        self.last_output_at = None
        self.exit_code = None
        self.buffer = deque(maxlen=1000)
        self.clients = set()
        self.master_fd, slave_fd = pty.openpty()
        resize_pty(self.master_fd, cols, rows)
        self.proc = subprocess.Popen(
            [command, *args],
            cwd=cwd,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
            env={
                **os.environ,
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
                "CLAUDE_CODE_FORCE_RECOVERY_CLI": os.environ.get("CLAUDE_CODE_FORCE_RECOVERY_CLI", "1"),
            },
            preexec_fn=os.setsid if hasattr(os, "setsid") else None,
        )
        os.close(slave_fd)
        threading.Thread(target=self._read_loop, daemon=True).start()
        threading.Thread(target=self._wait_loop, daemon=True).start()

    def serialize(self):
        return {
            "id": self.id,
            "title": self.title,
            "cwd": self.cwd,
            "command": self.command,
            "status": self.status,
            "createdAt": self.created_at,
            "lastOutputAt": self.last_output_at,
            "exitCode": self.exit_code,
            "buffer": list(self.buffer)[-300:],
        }

    def write(self, data):
        if self.status == "running":
            os.write(self.master_fd, data.encode("utf-8", errors="replace"))

    def resize(self, cols, rows):
        resize_pty(self.master_fd, cols, rows)

    def stop(self):
        if self.status == "running":
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            except Exception:
                self.proc.terminate()

    def broadcast(self, payload):
        dead = []
        for client in list(self.clients):
            if client.alive:
                client.send_json({"sessionId": self.id, **payload})
            else:
                dead.append(client)
        for client in dead:
            self.clients.discard(client)

    def _read_loop(self):
        while True:
            try:
                chunk = os.read(self.master_fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            text = chunk.decode("utf-8", errors="replace")
            self.last_output_at = iso_now()
            self.buffer.append(text)
            self.broadcast({"type": "output", "data": text})

    def _wait_loop(self):
        self.exit_code = self.proc.wait()
        self.status = "exited"
        self.broadcast({"type": "status", "status": self.status, "exitCode": self.exit_code})


def iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def json_response(handler, status, payload):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def read_json(handler):
    length = int(handler.headers.get("Content-Length", "0") or "0")
    if length == 0:
        return {}
    return json.loads(handler.rfile.read(length).decode("utf-8"))


def read_ws_frame(handler):
    head = handler.rfile.read(2)
    if len(head) < 2:
        return None
    first, second = head
    opcode = first & 0x0F
    masked = second & 0x80
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", handler.rfile.read(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", handler.rfile.read(8))[0]
    mask = handler.rfile.read(4) if masked else b"\x00\x00\x00\x00"
    data = bytearray(handler.rfile.read(length))
    if masked:
        for index in range(length):
            data[index] ^= mask[index % 4]
    if opcode == 8:
        return None
    return data.decode("utf-8", errors="replace")


class Handler(http.server.SimpleHTTPRequestHandler):
    server_version = "ClaudeHahaRoom/0.2"

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args))

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/health":
            return json_response(self, 200, {"ok": True, "command": resolve_command(), "cwd": os.getcwd()})
        if parsed.path == "/api/sessions":
            with sessions_lock:
                data = [session.serialize() for session in sessions.values()]
            return json_response(self, 200, data)
        if parsed.path == "/ws":
            return self.handle_ws(parsed)
        return self.serve_static(parsed.path)

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/sessions":
            return self.create_session()
        if parsed.path.startswith("/api/sessions/") and parsed.path.endswith("/input"):
            session_id = parsed.path.split("/")[3]
            body = read_json(self)
            with sessions_lock:
                session = sessions.get(session_id)
            if not session:
                return json_response(self, 404, {"error": "会话不存在"})
            session.write(str(body.get("data", "")))
            return json_response(self, 200, {"ok": True})
        if parsed.path.startswith("/api/sessions/") and parsed.path.endswith("/resize"):
            session_id = parsed.path.split("/")[3]
            body = read_json(self)
            with sessions_lock:
                session = sessions.get(session_id)
            if not session:
                return json_response(self, 404, {"error": "会话不存在"})
            session.resize(int(body.get("cols", 120)), int(body.get("rows", 34)))
            return json_response(self, 200, {"ok": True})
        return json_response(self, 404, {"error": "not found"})

    def do_DELETE(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/sessions/"):
            session_id = parsed.path.split("/")[3]
            with sessions_lock:
                session = sessions.pop(session_id, None)
            if not session:
                return json_response(self, 404, {"error": "会话不存在"})
            session.stop()
            return json_response(self, 200, {"ok": True})
        return json_response(self, 404, {"error": "not found"})

    def create_session(self):
        command = resolve_command()
        if not command:
            return json_response(self, 400, {"error": "未找到 claude 或 claude-haha。可用 CLAUDE_BIN=/path/to/claude bash dev.sh 指定。"})
        body = read_json(self)
        cwd = normalize_cwd(body.get("cwd"))
        title = str(body.get("title") or Path(cwd).name or "Claude").strip()
        args = [str(item) for item in body.get("args", []) if str(item)]
        cols = int(body.get("cols", 120))
        rows = int(body.get("rows", 34))
        prompt = str(body.get("prompt") or "").strip()
        try:
            session = Session(title, cwd, command, args, cols, rows)
        except Exception as exc:
            return json_response(self, 500, {"error": f"启动失败：{exc}", "command": command, "cwd": cwd})
        with sessions_lock:
            sessions[session.id] = session
        if prompt:
            threading.Timer(0.8, lambda: session.write(prompt + "\r")).start()
        return json_response(self, 201, session.serialize())

    def handle_ws(self, parsed):
        query = parse_qs(parsed.query)
        session_id = (query.get("sessionId") or [""])[0]
        with sessions_lock:
            session = sessions.get(session_id)
        if not session:
            self.send_error(404, "Unknown session")
            return
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            self.send_error(400, "Missing websocket key")
            return
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        client = WsClient(self)
        session.clients.add(client)
        client.send_json({"sessionId": session.id, "type": "snapshot", "session": session.serialize()})
        try:
            while client.alive:
                raw = read_ws_frame(self)
                if raw is None:
                    break
                try:
                    event = json.loads(raw)
                except json.JSONDecodeError:
                    session.write(raw)
                    continue
                if event.get("type") == "input":
                    session.write(str(event.get("data", "")))
                elif event.get("type") == "resize":
                    session.resize(int(event.get("cols", 120)), int(event.get("rows", 34)))
        finally:
            client.close()
            session.clients.discard(client)

    def serve_static(self, request_path):
        path = PUBLIC / ("index.html" if request_path in {"", "/"} else request_path.lstrip("/"))
        if not path.resolve().is_relative_to(PUBLIC.resolve()) or not path.exists() or path.is_dir():
            self.send_error(404)
            return
        ctype = "text/html"
        if path.suffix == ".js":
            ctype = "text/javascript"
        elif path.suffix == ".css":
            ctype = "text/css"
        elif path.suffix == ".map":
            ctype = "application/json"
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    os.chdir(ROOT)
    command = resolve_command()
    print(f"cc-haha-room listening on http://0.0.0.0:{PORT}")
    print(f"Claude command: {command or 'not found'}")
    ThreadingServer(("0.0.0.0", PORT), Handler).serve_forever()
