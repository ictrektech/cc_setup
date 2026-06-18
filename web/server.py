#!/usr/bin/env python3
import base64
import hashlib
import http.server
import json
import os
import pty
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
    candidates = [os.environ.get("CLAUDE_BIN"), "claude"]
    for candidate in [item for item in candidates if item]:
        expanded = os.path.expanduser(candidate)
        if "/" in expanded and os.path.exists(expanded):
            return expanded
        found = shutil.which(candidate)
        if found:
            return found

        try:
            resolved = subprocess.check_output(
                ["bash", "-lc", f"command -v {shell_quote(candidate)}"],
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
            if resolved:
                return resolved
        except Exception:
            pass
    return None


def shell_quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


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
        self.events = deque(maxlen=500)
        self.clients = set()
        self.master_fd = None
        self.proc = None
        self.worker_proc = None
        self.busy = False
        self.add_event("system", "房间已就绪。发送任务后会以 claude -p 运行，并在这里显示结构化回答。")
        if args:
            self.start_pty(args, cols, rows)

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
            "events": list(self.events)[-300:],
        }

    def add_event(self, event_type, text, broadcast=True):
        event = {"type": event_type, "text": text, "createdAt": iso_now()}
        self.events.append(event)
        if broadcast:
            self.broadcast({"type": "event", "event": event})

    def add_status(self, text):
        event = {"type": "status", "text": text, "createdAt": iso_now()}
        self.events.append(event)
        self.broadcast({"type": "event", "event": event})

    def write(self, data, record_user=False):
        if self.status == "running" and self.master_fd is not None:
            if record_user and data.strip():
                self.add_event("user", data.strip())
            os.write(self.master_fd, data.encode("utf-8", errors="replace"))

    def resize(self, cols, rows):
        if self.master_fd is not None:
            resize_pty(self.master_fd, cols, rows)

    def stop(self):
        if self.status == "running":
            for proc in [self.worker_proc, self.proc]:
                if not proc:
                    continue
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except Exception:
                    proc.terminate()
            self.status = "exited"
            self.exit_code = -15
            self.broadcast({"type": "status", "status": self.status, "exitCode": self.exit_code})

    def start_pty(self, args, cols, rows):
        self.master_fd, slave_fd = pty.openpty()
        resize_pty(self.master_fd, cols, rows)
        self.proc = subprocess.Popen(
            [self.command, *args],
            cwd=self.cwd,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
            env={
                **os.environ,
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
            },
            preexec_fn=os.setsid if hasattr(os, "setsid") else None,
        )
        os.close(slave_fd)
        threading.Thread(target=self._read_loop, daemon=True).start()
        threading.Thread(target=self._wait_loop, daemon=True).start()

    def run_prompt(self, prompt):
        prompt = prompt.strip()
        if not prompt:
            return
        if self.busy:
            self.add_event("system", "Claude 正在处理上一条任务，请稍后再发送。")
            return

        self.busy = True
        self.add_event("user", prompt)
        self.add_status("Claude 正在启动任务...")

        try:
            self.worker_proc = subprocess.Popen(
                [self.command, "-p", "--verbose", "--output-format", "stream-json", "--include-partial-messages", prompt],
                cwd=self.cwd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env={**os.environ, "TERM": "dumb"},
                preexec_fn=os.setsid if hasattr(os, "setsid") else None,
            )
            seen = set()
            active_stream_id = None
            streamed_text = ""
            self.add_status("等待 Claude 首字返回...")
            for line in self.worker_proc.stdout or []:
                self.last_output_at = iso_now()
                self.buffer.append(line)
                self.broadcast({"type": "output", "data": line})
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if event.get("type") == "system" and event.get("subtype") == "status":
                    if event.get("status") == "requesting":
                        self.add_status("Claude 已收到任务，正在请求模型...")
                    continue
                if event.get("type") == "stream_event":
                    stream_event = event.get("event") or {}
                    stream_type = stream_event.get("type")
                    if stream_type == "content_block_start":
                        active_stream_id = str(uuid.uuid4())
                        streamed_text = ""
                        self.broadcast({"type": "assistant_start", "streamId": active_stream_id})
                    elif stream_type == "content_block_delta":
                        delta = stream_event.get("delta") or {}
                        text_delta = delta.get("text", "")
                        if active_stream_id and text_delta:
                            streamed_text += text_delta
                            self.broadcast({"type": "assistant_delta", "streamId": active_stream_id, "text": text_delta})
                    elif stream_type in {"content_block_stop", "message_stop"}:
                        if active_stream_id:
                            self.broadcast({"type": "assistant_done", "streamId": active_stream_id})
                            active_stream_id = None
                    continue
                if event.get("type") == "assistant":
                    message = event.get("message") or {}
                    for block in message.get("content") or []:
                        if block.get("type") == "text":
                            text = block.get("text", "").strip()
                            if text and text not in seen:
                                seen.add(text)
                                if streamed_text:
                                    self.add_event("assistant", text, broadcast=False)
                                    self.broadcast({"type": "assistant_replace", "text": text})
                                else:
                                    self.add_event("assistant", text)
                elif event.get("type") == "result" and event.get("is_error"):
                    self.add_event("system", event.get("result") or "Claude 执行失败。")

            code = self.worker_proc.wait()
            if code != 0:
                self.add_event("system", f"Claude 进程退出码：{code}")
            else:
                self.add_status("完成。")
        except Exception as exc:
            self.add_event("system", f"Claude 启动失败：{exc}")
        finally:
            self.worker_proc = None
            self.busy = False


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
            self.events.append({"type": "output", "text": text, "createdAt": self.last_output_at})
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
    server_version = "AgentRoom/0.2"

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
            session.write(str(body.get("data", "")), bool(body.get("recordUser")))
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
            return json_response(self, 400, {"error": "未找到 claude。可用 CLAUDE_BIN=/path/to/claude bash dev.sh 指定。"})
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
            threading.Thread(target=session.run_prompt, args=(prompt,), daemon=True).start()
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
                elif event.get("type") == "message":
                    text = str(event.get("text", "")).strip()
                    if text:
                        threading.Thread(target=session.run_prompt, args=(text,), daemon=True).start()
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
    print(f"agent-room listening on http://0.0.0.0:{PORT}")
    print(f"Claude command: {command or 'not found'}")
    ThreadingServer(("0.0.0.0", PORT), Handler).serve_forever()
