#!/usr/bin/env python3
import base64
import hashlib
import hmac
import http.server
import json
import os
import pty
import shutil
import signal
import secrets
import socketserver
import struct
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from pathlib import Path
from urllib.parse import parse_qs, urlparse, unquote_plus

ROOT = Path(__file__).resolve().parent
PUBLIC = ROOT / "public"
PORT = int(os.environ.get("PORT", "3766"))
SESSIONS_PATH = Path(os.environ.get("AGENTROOM_SESSIONS_PATH", ROOT / ".agentroom_sessions.json"))
AUTH_DIR = Path(os.environ.get("AGENTROOM_AUTH_DIR", Path.home() / ".agentroom"))
TOKEN_PATH = Path(os.environ.get("AGENTROOM_TOKEN_PATH", AUTH_DIR / "token"))
SESSION_SECRET_PATH = Path(os.environ.get("AGENTROOM_SESSION_SECRET_PATH", AUTH_DIR / "session_secret"))
AUTH_COOKIE = "agentroom_session"
AUTH_MAX_AGE = int(os.environ.get("AGENTROOM_AUTH_MAX_AGE", str(7 * 24 * 60 * 60)))
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
sessions = {}
sessions_lock = threading.RLock()


def run_cmd(args, cwd, timeout=20, check=False):
    proc = subprocess.run(
        args,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(proc.stdout.strip() or f"{args[0]} exited with {proc.returncode}")
    return proc.returncode, proc.stdout


def ensure_private_file(path, value_factory):
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    if not path.exists():
        path.write_text(value_factory() + "\n", encoding="utf-8")
        try:
            path.chmod(0o600)
        except OSError:
            pass
    return path.read_text(encoding="utf-8").strip()


def get_auth_token():
    env_token = os.environ.get("AGENTROOM_TOKEN")
    if env_token:
        return env_token.strip()
    return ensure_private_file(TOKEN_PATH, lambda: secrets.token_urlsafe(32))


def get_session_secret():
    env_secret = os.environ.get("AGENTROOM_SESSION_SECRET")
    if env_secret:
        return env_secret.strip()
    return ensure_private_file(SESSION_SECRET_PATH, lambda: secrets.token_urlsafe(48))


def print_token():
    token = get_auth_token()
    print(token)


def sign_session(expires, nonce):
    payload = f"{expires}:{nonce}"
    signature = hmac.new(get_session_secret().encode(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}:{signature}"


def verify_session_cookie(value):
    if not value:
        return False
    parts = value.split(":")
    if len(parts) != 3:
        return False
    expires_text, nonce, signature = parts
    try:
        expires = int(expires_text)
    except ValueError:
        return False
    if expires < int(time.time()):
        return False
    expected = hmac.new(get_session_secret().encode(), f"{expires}:{nonce}".encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature, expected)


def parse_cookies(header):
    cookies = {}
    for item in str(header or "").split(";"):
        if "=" not in item:
            continue
        key, value = item.split("=", 1)
        cookies[key.strip()] = value.strip()
    return cookies


def git_cmd(cwd, *args, timeout=20, check=False):
    return run_cmd(["git", *args], cwd, timeout=timeout, check=check)


def split_lines(text):
    return [line for line in text.splitlines() if line.strip()]


IGNORE_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build", ".next", ".cache"}
TEXT_SUFFIXES = {
    ".c", ".cc", ".cfg", ".conf", ".cpp", ".css", ".csv", ".env", ".go", ".h", ".hpp", ".html", ".ini",
    ".java", ".js", ".json", ".jsx", ".md", ".mjs", ".py", ".rb", ".rs", ".sh", ".sql", ".svg", ".toml",
    ".ts", ".tsx", ".txt", ".vue", ".xml", ".yaml", ".yml",
}


def ensure_git_repo(cwd):
    code, root = git_cmd(cwd, "rev-parse", "--show-toplevel")
    if code != 0:
        raise RuntimeError("当前目录不是 git 仓库。")
    return root.strip()


def git_summary(cwd):
    repo = ensure_git_repo(cwd)
    _, branch = git_cmd(repo, "branch", "--show-current")
    _, head = git_cmd(repo, "rev-parse", "--short", "HEAD")
    upstream_code, upstream = git_cmd(repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    _, porcelain = git_cmd(repo, "status", "--porcelain=v1", "-b")
    _, remotes = git_cmd(repo, "remote", "-v")
    _, log = git_cmd(repo, "log", "--oneline", "--decorate", "-n", "8")
    _, graph = git_cmd(repo, "log", "--graph", "--decorate", "--oneline", "--all", "-n", "32")
    commits = git_commits(repo)

    files = []
    for line in porcelain.splitlines():
        if line.startswith("## "):
            continue
        if not line:
            continue
        files.append({"index": line[:1], "worktree": line[1:2], "path": line[3:]})

    ahead = behind = 0
    upstream_name = upstream.strip() if upstream_code == 0 else ""
    if upstream_name:
        code, counts = git_cmd(repo, "rev-list", "--left-right", "--count", f"{upstream_name}...HEAD")
        if code == 0:
            parts = counts.split()
            if len(parts) == 2:
                behind, ahead = int(parts[0]), int(parts[1])

    return {
        "ok": True,
        "repo": repo,
        "branch": branch.strip() or "(detached)",
        "head": head.strip(),
        "upstream": upstream_name,
        "ahead": ahead,
        "behind": behind,
        "files": files,
        "remotes": split_lines(remotes),
        "log": split_lines(log),
        "graph": split_lines(graph),
        "commits": commits,
        "clean": len(files) == 0,
    }


def git_commits(repo, limit=80):
    _, output = git_cmd(
        repo,
        "log",
        "--all",
        "--date-order",
        f"-n{limit}",
        "--pretty=format:%H%x1f%h%x1f%D%x1f%s%x1f%P%x1e",
        timeout=30,
    )
    commits = []
    for record in output.split("\x1e"):
        record = record.strip()
        if not record:
            continue
        parts = record.split("\x1f")
        if len(parts) < 5:
            continue
        commits.append({
            "hash": parts[0],
            "short": parts[1],
            "refs": parts[2],
            "subject": parts[3],
            "parents": [item for item in parts[4].split() if item],
        })
    return commits


def git_diff(cwd, path=None, staged=False):
    repo = ensure_git_repo(cwd)
    if path and not staged:
        _, status = git_cmd(repo, "status", "--porcelain=v1", "--", path)
        if status.startswith("??"):
            _, output = git_cmd(repo, "diff", "--no-index", "--", "/dev/null", str(Path(repo) / path), timeout=30)
            return {"repo": repo, "diff": output}
    args = ["diff"]
    if staged:
        args.append("--cached")
    args.extend(["--"])
    if path:
        args.append(path)
    _, output = git_cmd(repo, *args, timeout=30)
    return {"repo": repo, "diff": output}


def safe_child(root, relative):
    root_path = Path(root).resolve()
    target = (root_path / str(relative or "")).resolve()
    if target != root_path and root_path not in target.parents:
        raise RuntimeError("路径超出当前项目目录。")
    return target


def is_probably_text(path):
    if path.suffix.lower() in TEXT_SUFFIXES:
        return True
    try:
        sample = path.read_bytes()[:2048]
    except OSError:
        return False
    return b"\x00" not in sample


def file_tree(cwd, limit=500):
    root = Path(normalize_cwd(cwd)).resolve()
    if not root.exists() or not root.is_dir():
        raise RuntimeError("项目目录不存在。")
    items = []
    for current, dirs, files in os.walk(root):
        rel_dir = Path(current).relative_to(root)
        dirs[:] = sorted([name for name in dirs if name not in IGNORE_DIRS and not name.startswith(".")])
        depth = 0 if str(rel_dir) == "." else len(rel_dir.parts)
        if depth > 5:
            dirs[:] = []
            continue
        for name in sorted(files):
            if name.startswith("."):
                continue
            path = Path(current) / name
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_size > 1024 * 1024:
                continue
            rel = path.relative_to(root).as_posix()
            items.append({
                "path": rel,
                "name": name,
                "size": stat.st_size,
                "language": language_for(path),
                "editable": is_probably_text(path),
            })
            if len(items) >= limit:
                return {"root": str(root), "files": items, "truncated": True}
    return {"root": str(root), "files": items, "truncated": False}


def read_file(cwd, relative):
    root = Path(normalize_cwd(cwd)).resolve()
    target = safe_child(root, relative)
    if not target.exists() or not target.is_file():
        raise RuntimeError("文件不存在。")
    if target.stat().st_size > 1024 * 1024:
        raise RuntimeError("文件超过 1MB，暂不在 Web 编辑器中打开。")
    if not is_probably_text(target):
        raise RuntimeError("当前文件看起来不是文本文件。")
    return {
        "path": target.relative_to(root).as_posix(),
        "content": target.read_text(encoding="utf-8", errors="replace"),
        "language": language_for(target),
    }


def write_file(cwd, relative, content):
    root = Path(normalize_cwd(cwd)).resolve()
    target = safe_child(root, relative)
    if not target.exists() or not target.is_file():
        raise RuntimeError("文件不存在。")
    text = str(content)
    if len(text.encode("utf-8")) > 1024 * 1024:
        raise RuntimeError("文件超过 1MB，暂不保存。")
    target.write_text(text, encoding="utf-8")
    return {"ok": True, "path": target.relative_to(root).as_posix(), "language": language_for(target)}


def create_file(cwd, directory, name):
    root = Path(normalize_cwd(cwd)).resolve()
    parent = safe_child(root, directory or "")
    if not parent.exists() or not parent.is_dir():
        raise RuntimeError("目标文件夹不存在。")
    clean_name = str(name or "").strip()
    if not clean_name:
        raise RuntimeError("文件名不能为空。")
    if clean_name in {".", ".."} or "/" in clean_name or "\\" in clean_name:
        raise RuntimeError("文件名不能包含路径分隔符。")
    target = safe_child(parent, clean_name)
    if target.exists():
        raise RuntimeError("文件已存在。")
    target.write_text("", encoding="utf-8")
    return {
        "ok": True,
        "path": target.relative_to(root).as_posix(),
        "language": language_for(target),
    }


def move_file(cwd, relative, target_directory):
    root = Path(normalize_cwd(cwd)).resolve()
    source = safe_child(root, relative)
    if not source.exists() or not source.is_file():
        raise RuntimeError("源文件不存在。")
    target_parent = safe_child(root, target_directory or "")
    if not target_parent.exists() or not target_parent.is_dir():
        raise RuntimeError("目标文件夹不存在。")
    target = safe_child(target_parent, source.name)
    if source == target:
        return {"ok": True, "path": source.relative_to(root).as_posix(), "language": language_for(source)}
    if target.exists():
        raise RuntimeError("目标文件夹中已存在同名文件。")
    shutil.move(str(source), str(target))
    return {
        "ok": True,
        "path": target.relative_to(root).as_posix(),
        "language": language_for(target),
    }


def language_for(path):
    suffix = path.suffix.lower()
    return {
        ".py": "python",
        ".js": "javascript",
        ".mjs": "javascript",
        ".jsx": "javascript",
        ".ts": "typescript",
        ".tsx": "typescript",
        ".json": "json",
        ".css": "css",
        ".html": "html",
        ".md": "markdown",
        ".sh": "shell",
        ".yml": "yaml",
        ".yaml": "yaml",
        ".toml": "toml",
        ".rs": "rust",
        ".go": "go",
        ".java": "java",
    }.get(suffix, "text")


def resolve_command(agent="claude"):
    if agent == "codex":
        candidates = command_candidates("CODEX_BIN", "codex")
    else:
        candidates = command_candidates("CLAUDE_BIN", "claude")
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


def command_candidates(env_name, command):
    return [
        os.environ.get(env_name),
        f"~/.local/npm/bin/{command}",
        f"~/.local/bin/{command}",
        command,
    ]


def available_agents():
    return {
        "claude": resolve_command("claude"),
        "codex": resolve_command("codex"),
    }


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


def save_sessions():
    try:
        SESSIONS_PATH.parent.mkdir(parents=True, exist_ok=True)
        with sessions_lock:
            payload = [session.serialize() for session in sessions.values()]
        tmp = SESSIONS_PATH.with_suffix(SESSIONS_PATH.suffix + ".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        tmp.replace(SESSIONS_PATH)
    except Exception as exc:
        print(f"[WARN] save sessions failed: {exc}")


def load_sessions(command):
    if not SESSIONS_PATH.exists():
        return
    try:
        data = json.loads(SESSIONS_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"[WARN] load sessions failed: {exc}")
        return
    if not isinstance(data, list):
        return
    with sessions_lock:
        for item in data:
            if not isinstance(item, dict):
                continue
            try:
                session = Session.from_saved(item, command)
                sessions[session.id] = session
            except Exception as exc:
                print(f"[WARN] restore session failed: {exc}")


def terminate_process_group(proc, grace_seconds=5):
    if not proc or proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:
        proc.terminate()
    deadline = time.time() + grace_seconds
    while time.time() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.1)
    if proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except Exception:
        proc.kill()


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
    def __init__(self, title, cwd, command, args, cols, rows, saved=None, agent="claude"):
        saved = saved or {}
        self.id = str(saved.get("id") or uuid.uuid4())
        self.title = title
        self.cwd = cwd
        self.command = command
        self.agent = str(saved.get("agent") or agent or "claude")
        self.status = str(saved.get("status") or "running")
        self.created_at = str(saved.get("createdAt") or iso_now())
        self.last_output_at = saved.get("lastOutputAt")
        self.exit_code = saved.get("exitCode")
        self.buffer = deque(saved.get("buffer") or [], maxlen=1000)
        self.events = deque(saved.get("events") or [], maxlen=500)
        self.clients = set()
        self.master_fd = None
        self.proc = None
        self.worker_proc = None
        self.busy = False
        self.prompt_queue = deque()
        self.provider_session_id = saved.get("providerSessionId")
        if not saved:
            self.add_event("system", f"房间已就绪。{self.agent_label()} 将以结构化 Agent 模式运行，工具调用、执行状态和回答会分开显示。")
        if args:
            self.start_pty(args, cols, rows)

    @classmethod
    def from_saved(cls, data, command):
        agent = str(data.get("agent") or "claude")
        status = data.get("status")
        saved = {**data, "status": "ready" if status == "running" else (status or "ready")}
        saved["busy"] = False
        restored_command = resolve_command(agent) or command or str(data.get("command") or agent)
        return cls(
            str(data.get("title") or Path(str(data.get("cwd") or "")).name or "Claude"),
            normalize_cwd(data.get("cwd")),
            restored_command,
            [],
            120,
            34,
            saved=saved,
            agent=agent,
        )

    def agent_label(self):
        return "Codex" if self.agent == "codex" else "Claude"

    def serialize(self):
        return {
            "id": self.id,
            "title": self.title,
            "cwd": self.cwd,
            "command": self.command,
            "agent": self.agent,
            "status": self.status,
            "createdAt": self.created_at,
            "lastOutputAt": self.last_output_at,
            "exitCode": self.exit_code,
            "busy": self.busy,
            "queueLength": len(self.prompt_queue),
            "providerSessionId": self.provider_session_id,
            "buffer": list(self.buffer)[-300:],
            "events": list(self.events)[-300:],
        }

    def add_event(self, event_type, text, broadcast=True):
        event = {"type": event_type, "text": text, "createdAt": iso_now()}
        self.events.append(event)
        save_sessions()
        if broadcast:
            self.broadcast({"type": "event", "event": event})

    def add_status(self, text):
        event = {"type": "status", "text": text, "createdAt": iso_now()}
        self.events.append(event)
        save_sessions()
        self.broadcast({"type": "event", "event": event})

    def broadcast_session(self):
        save_sessions()
        self.broadcast({"type": "session_update", "session": self.serialize()})

    def write(self, data, record_user=False):
        if self.status == "running" and self.master_fd is not None:
            if record_user and data.strip():
                self.add_event("user", data.strip())
            os.write(self.master_fd, data.encode("utf-8", errors="replace"))

    def send_pty_message(self, text):
        text = str(text or "").strip()
        if not text:
            return
        self.add_event("user", text)
        self.write(text + "\r")

    def send_initial_pty_prompt(self, prompt):
        def worker():
            time.sleep(1.0)
            # Safe no-op when the trust prompt is absent; confirms it when present.
            self.write("\r")
            time.sleep(0.8)
            self.send_pty_message(prompt)

        threading.Thread(target=worker, daemon=True).start()

    def resize(self, cols, rows):
        if self.master_fd is not None:
            resize_pty(self.master_fd, cols, rows)

    def stop(self):
        if self.status == "running":
            for proc in [self.worker_proc, self.proc]:
                if not proc:
                    continue
                terminate_process_group(proc, grace_seconds=1)
            self.status = "exited"
            self.exit_code = -15
            save_sessions()
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

    def enqueue_prompt(self, prompt):
        prompt = prompt.strip()
        if not prompt:
            return
        if self.status == "ready":
            self.status = "running"
            self.exit_code = None
        if self.master_fd is not None:
            self.send_pty_message(prompt)
            return
        if self.busy:
            self.prompt_queue.append(prompt)
            self.add_event("user", prompt)
            self.add_status(f"Claude 正在处理上一条消息，已排队 {len(self.prompt_queue)} 条，完成后会自动继续。")
            self.broadcast_session()
            return
        self.add_event("user", prompt)
        threading.Thread(target=self.run_prompt, args=(prompt,), daemon=True).start()

    def run_prompt(self, prompt, include_partial=True, fallback_attempted=False):
        if self.agent == "codex":
            self.run_codex_prompt(prompt)
            return
        self.run_claude_prompt(prompt, include_partial, fallback_attempted)

    def run_claude_prompt(self, prompt, include_partial=True, fallback_attempted=False):
        prompt = prompt.strip()
        if not prompt:
            return

        self.busy = True
        self.broadcast_session()
        self.add_status("Claude 正在启动..." if include_partial else "Claude 正在以兼容模式继续...")
        payload = {
            "cwd": self.cwd,
            "command": self.command,
            "prompt": prompt,
            "providerSessionId": self.provider_session_id,
            "permissionMode": os.environ.get("CLAUDE_PERMISSION_MODE", "acceptEdits"),
            "maxTurns": int(os.environ.get("CLAUDE_MAX_TURNS", "12")),
            "timeoutSeconds": int(os.environ.get("CLAUDE_RUN_TIMEOUT", "600")),
        }

        try:
            command_args = [
                self.command,
                "-p",
                "--permission-mode",
                payload["permissionMode"],
                "--max-turns",
                str(payload["maxTurns"]),
                "--verbose",
                "--output-format",
                "stream-json",
            ]
            if include_partial:
                command_args.append("--include-partial-messages")
            if self.provider_session_id:
                command_args.extend(["--resume", self.provider_session_id])
            command_args.append(prompt)
            self.worker_proc = subprocess.Popen(
                command_args,
                cwd=self.cwd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env={**os.environ, "TERM": "dumb", "NO_COLOR": "1"},
                preexec_fn=os.setsid if hasattr(os, "setsid") else None,
            )
            timed_out = False

            def kill_on_timeout():
                nonlocal timed_out
                if self.worker_proc and self.worker_proc.poll() is None:
                    timed_out = True
                    queued = len(self.prompt_queue)
                    suffix = f"队列中还有 {queued} 条，停止后会自动继续。" if queued else "没有排队消息。"
                    self.add_event("system", f"Claude 运行超过 {payload['timeoutSeconds']} 秒，已自动停止当前轮。{suffix}")
                    self.broadcast_session()
                    terminate_process_group(self.worker_proc)

            timer = threading.Timer(payload["timeoutSeconds"], kill_on_timeout)
            timer.daemon = True
            timer.start()
            seen = set()
            active_stream_id = None
            streamed_text = ""
            has_result = False
            saw_stream_tool_use = False
            saw_tool_result = False
            rerun_without_partial = False
            raw_tail = deque(maxlen=8)
            self.add_status("等待 Claude 响应...")
            for line in self.worker_proc.stdout or []:
                self.last_output_at = iso_now()
                self.buffer.append(line)
                raw_tail.append(line.strip())
                self.broadcast({"type": "output", "data": line})
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                message_event = event
                if message_event.get("session_id") and not self.provider_session_id:
                    self.provider_session_id = message_event.get("session_id")
                    self.broadcast_session()
                    self.add_status("Claude 会话已建立。")
                if message_event.get("type") == "system":
                    if message_event.get("subtype") == "init":
                        tools = message_event.get("tools") or []
                        self.add_status(f"Claude 已启动，工具 {len(tools)} 个。")
                    elif message_event.get("subtype") == "status" and message_event.get("status") == "requesting":
                        self.add_status("Claude 已收到任务，正在请求模型...")
                    elif message_event.get("subtype") == "api_retry":
                        self.add_status("模型限流，Claude 正在自动重试...")
                    continue
                if message_event.get("type") == "stream_event":
                    stream_event = message_event.get("event") or {}
                    stream_type = stream_event.get("type")
                    if stream_type == "content_block_start":
                        block = stream_event.get("content_block") or {}
                        if block.get("type") == "text":
                            active_stream_id = str(uuid.uuid4())
                            streamed_text = ""
                            self.broadcast({"type": "assistant_start", "streamId": active_stream_id})
                        elif block.get("type") == "tool_use":
                            saw_stream_tool_use = True
                            name = block.get("name") or "tool"
                            self.add_status(f"Claude 正在调用工具：{name}")
                    elif stream_type == "content_block_delta":
                        delta = stream_event.get("delta") or {}
                        text_delta = delta.get("text", "") or delta.get("text_delta", "")
                        if active_stream_id and text_delta:
                            streamed_text += text_delta
                            self.broadcast({"type": "assistant_delta", "streamId": active_stream_id, "text": text_delta})
                    elif stream_type in {"content_block_stop", "message_stop"}:
                        if active_stream_id:
                            if streamed_text.strip() and streamed_text not in seen:
                                seen.add(streamed_text)
                                has_result = True
                                self.add_event("assistant", streamed_text, broadcast=False)
                            self.broadcast({"type": "assistant_done", "streamId": active_stream_id})
                            active_stream_id = None
                    continue
                if message_event.get("type") == "assistant":
                    message = message_event.get("message") or {}
                    for block in message.get("content") or []:
                        if block.get("type") == "text":
                            text = block.get("text", "").strip()
                            if text and not streamed_text and text not in seen:
                                seen.add(text)
                                has_result = True
                                self.add_event("assistant", text, broadcast=False)
                                self.broadcast({"type": "assistant_start", "streamId": str(uuid.uuid4())})
                                self.broadcast({"type": "assistant_replace", "text": text})
                        elif block.get("type") == "tool_use":
                            saw_stream_tool_use = True
                            self.add_status(f"Claude 正在调用工具：{block.get('name') or 'tool'}")
                elif message_event.get("type") == "user":
                    result = message_event.get("tool_use_result")
                    if result is not None:
                        saw_tool_result = True
                        name = result.get("name") if isinstance(result, dict) else ""
                        self.add_status(f"{name or '工具'}结果已返回，等待 Claude 继续...")
                elif message_event.get("type") == "result":
                    result_text = str(message_event.get("result") or "").strip()
                    if message_event.get("is_error"):
                        self.add_event("system", result_text or "Claude 执行失败。")
                    elif result_text:
                        has_result = True
                        if result_text not in seen:
                            seen.add(result_text)
                            if streamed_text:
                                self.add_event("assistant", result_text, broadcast=False)
                                self.broadcast({"type": "assistant_replace", "text": result_text})
                            else:
                                self.add_event("assistant", result_text)

            code = self.worker_proc.wait()
            timer.cancel()
            if code != 0 and not timed_out:
                detail = next((line for line in reversed(raw_tail) if line), "")
                suffix = f"\n{detail}" if detail else ""
                self.add_event("system", f"Claude 进程退出码：{code}{suffix}")
            elif code == 0:
                if not has_result and include_partial and saw_stream_tool_use and not saw_tool_result and not fallback_attempted:
                    rerun_without_partial = True
                    self.add_status("检测到流式工具调用未完成，切换兼容模式继续本轮。")
                elif not has_result:
                    self.add_event("system", "Claude 本轮没有返回最终结果，可能仍停在工具调用中。")
                if not rerun_without_partial:
                    self.add_status("完成。")
        except Exception as exc:
            self.add_event("system", f"Claude 启动失败：{exc}")
        finally:
            self.worker_proc = None
            self.busy = False
            if locals().get("rerun_without_partial"):
                self.status = "running"
                self.broadcast_session()
                threading.Thread(target=self.run_prompt, args=(prompt, False, True), daemon=True).start()
                return
            if self.status == "running":
                self.status = "ready"
            self.broadcast_session()
            if self.status in {"running", "ready"} and self.prompt_queue:
                next_prompt = self.prompt_queue.popleft()
                self.status = "running"
                self.add_status(f"开始处理排队消息，剩余 {len(self.prompt_queue)} 条。")
                self.broadcast_session()
                threading.Thread(target=self.run_prompt, args=(next_prompt,), daemon=True).start()

    def run_codex_prompt(self, prompt):
        prompt = prompt.strip()
        if not prompt:
            return

        self.busy = True
        self.broadcast_session()
        self.add_status("Codex 正在启动...")
        timeout_seconds = int(os.environ.get("CODEX_RUN_TIMEOUT", os.environ.get("AGENT_RUN_TIMEOUT", "600")))
        try:
            if self.provider_session_id:
                command_args = [
                    self.command,
                    "exec",
                    "resume",
                    "--json",
                    "--dangerously-bypass-approvals-and-sandbox",
                    self.provider_session_id,
                    prompt,
                ]
            else:
                command_args = [
                    self.command,
                    "exec",
                    "--json",
                    "--dangerously-bypass-approvals-and-sandbox",
                    "-C",
                    self.cwd,
                    prompt,
                ]

            self.worker_proc = subprocess.Popen(
                command_args,
                cwd=self.cwd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env={**os.environ, "TERM": "dumb", "NO_COLOR": "1"},
                preexec_fn=os.setsid if hasattr(os, "setsid") else None,
            )
            timed_out = False

            def kill_on_timeout():
                nonlocal timed_out
                if self.worker_proc and self.worker_proc.poll() is None:
                    timed_out = True
                    queued = len(self.prompt_queue)
                    suffix = f"队列中还有 {queued} 条，停止后会自动继续。" if queued else "没有排队消息。"
                    self.add_event("system", f"Codex 运行超过 {timeout_seconds} 秒，已自动停止当前轮。{suffix}")
                    self.broadcast_session()
                    terminate_process_group(self.worker_proc)

            timer = threading.Timer(timeout_seconds, kill_on_timeout)
            timer.daemon = True
            timer.start()
            raw_tail = deque(maxlen=8)
            seen = set()
            active_stream_id = None
            self.add_status("等待 Codex 响应...")
            for line in self.worker_proc.stdout or []:
                self.last_output_at = iso_now()
                self.buffer.append(line)
                raw_tail.append(line.strip())
                self.broadcast({"type": "output", "data": line})
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    clean = line.strip()
                    if clean and not clean.startswith("Reading additional input"):
                        self.add_status(clean[:180])
                    continue
                active_stream_id = self.handle_codex_event(event, seen, active_stream_id)

            code = self.worker_proc.wait()
            timer.cancel()
            if active_stream_id:
                self.broadcast({"type": "assistant_done", "streamId": active_stream_id})
            if code != 0 and not timed_out:
                detail = next((line for line in reversed(raw_tail) if line), "")
                suffix = f"\n{detail}" if detail else ""
                self.add_event("system", f"Codex 进程退出码：{code}{suffix}")
            elif code == 0 and not timed_out:
                self.add_status("完成。")
        except Exception as exc:
            self.add_event("system", f"Codex 启动失败：{exc}")
        finally:
            self.worker_proc = None
            self.busy = False
            if self.status == "running":
                self.status = "ready"
            self.broadcast_session()
            if self.status in {"running", "ready"} and self.prompt_queue:
                next_prompt = self.prompt_queue.popleft()
                self.status = "running"
                self.add_status(f"开始处理排队消息，剩余 {len(self.prompt_queue)} 条。")
                self.broadcast_session()
                threading.Thread(target=self.run_prompt, args=(next_prompt,), daemon=True).start()

    def handle_codex_event(self, event, seen, active_stream_id):
        event_type = str(event.get("type") or "")
        if event_type == "thread.started":
            thread_id = event.get("thread_id")
            if thread_id and not self.provider_session_id:
                self.provider_session_id = thread_id
                self.broadcast_session()
                self.add_status("Codex 会话已建立。")
            return active_stream_id
        if event_type == "turn.started":
            self.add_status("Codex 已收到任务，正在请求模型...")
            return active_stream_id
        if event_type == "turn.failed":
            err = event.get("error") or {}
            self.add_event("system", err.get("message") if isinstance(err, dict) else str(err))
            return active_stream_id
        if event_type == "error":
            message = str(event.get("message") or "Codex 执行失败。")
            self.add_event("system", message)
            return active_stream_id

        delta = self.extract_codex_delta(event)
        if delta:
            if not active_stream_id:
                active_stream_id = str(uuid.uuid4())
                self.broadcast({"type": "assistant_start", "streamId": active_stream_id})
            self.broadcast({"type": "assistant_delta", "streamId": active_stream_id, "text": delta})
            return active_stream_id

        text = self.extract_codex_text(event)
        if text and text not in seen:
            seen.add(text)
            if active_stream_id:
                self.add_event("assistant", text, broadcast=False)
                self.broadcast({"type": "assistant_replace", "text": text})
                self.broadcast({"type": "assistant_done", "streamId": active_stream_id})
                active_stream_id = None
            else:
                self.add_event("assistant", text)
            return active_stream_id

        status = self.extract_codex_status(event)
        if status:
            self.add_status(status)
        return active_stream_id

    def extract_codex_delta(self, event):
        for key in ("delta", "text_delta", "content_delta"):
            value = event.get(key)
            if isinstance(value, str):
                return value
        item = event.get("item")
        if isinstance(item, dict):
            for key in ("delta", "text_delta", "content_delta"):
                value = item.get(key)
                if isinstance(value, str):
                    return value
        return ""

    def extract_codex_text(self, event):
        candidates = []
        for obj in (event, event.get("item") if isinstance(event.get("item"), dict) else None):
            if not isinstance(obj, dict):
                continue
            for key in ("text", "message", "content", "final_message", "answer"):
                value = obj.get(key)
                if isinstance(value, str):
                    candidates.append(value)
                elif isinstance(value, list):
                    parts = []
                    for part in value:
                        if isinstance(part, str):
                            parts.append(part)
                        elif isinstance(part, dict) and isinstance(part.get("text"), str):
                            parts.append(part["text"])
                    if parts:
                        candidates.append("\n".join(parts))
        for text in candidates:
            clean = text.strip()
            if clean and not clean.startswith("Model metadata for"):
                return clean
        return ""

    def extract_codex_status(self, event):
        event_type = str(event.get("type") or "")
        item = event.get("item") if isinstance(event.get("item"), dict) else {}
        item_type = str(item.get("type") or "")
        if event_type == "item.completed":
            if item_type == "error":
                return str(item.get("message") or "Codex 返回错误。")
            if "command" in item_type or item.get("command"):
                return f"Codex 已执行命令：{item.get('command') or item_type}"
            if item_type:
                return f"Codex 完成步骤：{item_type}"
        if event_type == "item.started":
            if item.get("command"):
                return f"Codex 正在执行命令：{item.get('command')}"
            if item_type:
                return f"Codex 正在执行步骤：{item_type}"
        return ""


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


def html_response(handler, status, html):
    body = html.encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def login_page():
    return """<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Agent Room 登录</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif; }
    body { min-height: 100vh; margin: 0; display: grid; place-items: center; background: #f5f5f7; color: #1d1d1f; }
    main { width: min(420px, calc(100vw - 32px)); padding: 28px; border: 1px solid rgba(60,60,67,.14); border-radius: 18px; background: rgba(255,255,255,.78); box-shadow: 0 18px 42px rgba(0,0,0,.08); backdrop-filter: blur(20px); }
    h1 { margin: 0 0 8px; font-size: 28px; line-height: 1.1; }
    p { margin: 0 0 22px; color: #6e6e73; }
    form { display: grid; gap: 12px; }
    label { display: grid; gap: 7px; color: #6e6e73; font-size: 13px; font-weight: 650; }
    input, button { font: inherit; border-radius: 10px; }
    input { width: 100%; box-sizing: border-box; border: 1px solid rgba(60,60,67,.18); padding: 12px; outline: none; }
    input:focus { border-color: #007aff; box-shadow: 0 0 0 3px rgba(0,122,255,.14); }
    button { border: 1px solid rgba(60,60,67,.14); padding: 11px 14px; background: #34c759; color: #06100a; font-weight: 750; cursor: pointer; }
    .error { min-height: 20px; color: #ff3b30; font-size: 13px; }
    code { padding: 2px 5px; border-radius: 6px; background: rgba(0,0,0,.06); }
  </style>
</head>
<body>
  <main>
    <h1>Agent Room</h1>
    <p>输入访问 token 登录。</p>
    <form id="loginForm" method="post" action="api/agent-room-login">
      <label>Token <input name="token" type="password" autocomplete="current-password" autofocus></label>
      <button type="submit">进入</button>
    </form>
  </main>
</body>
</html>"""


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

    def is_authenticated(self):
        cookies = parse_cookies(self.headers.get("Cookie"))
        return verify_session_cookie(cookies.get(AUTH_COOKIE))

    def require_auth(self, parsed):
        if parsed.path in {"/agent-room-login", "/api/agent-room-login", "/api/auth", "/api/health"}:
            return True
        if self.is_authenticated():
            return True
        if parsed.path.startswith("/api/") or parsed.path == "/ws":
            json_response(self, 401, {"ok": False, "error": "需要登录"})
            return False
        prefix = self.headers.get("X-Forwarded-Prefix", "")
        self.send_response(302)
        self.send_header("Location", prefix + "/agent-room-login")
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def set_auth_cookie(self):
        expires = int(time.time()) + AUTH_MAX_AGE
        value = sign_session(expires, secrets.token_urlsafe(16))
        self.send_header(
            "Set-Cookie",
            f"{AUTH_COOKIE}={value}; Max-Age={AUTH_MAX_AGE}; Path=/; HttpOnly; SameSite=Lax",
        )

    def clear_auth_cookie(self):
        self.send_header("Set-Cookie", f"{AUTH_COOKIE}=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax")

    def do_GET(self):
        parsed = urlparse(self.path)
        if not self.require_auth(parsed):
            return
        if parsed.path == "/agent-room-login":
            if self.is_authenticated():
                self.send_response(302)
                self.send_header("Location", "/")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            return html_response(self, 200, login_page())
        if parsed.path == "/api/auth":
            return json_response(self, 200, {"ok": True, "authenticated": self.is_authenticated()})
        if parsed.path == "/api/health":
            agents = available_agents()
            return json_response(self, 200, {"ok": True, "command": agents.get("claude"), "agents": agents, "cwd": os.getcwd()})
        if parsed.path == "/api/sessions":
            with sessions_lock:
                data = [session.serialize() for session in sessions.values()]
            return json_response(self, 200, data)
        if parsed.path == "/api/git":
            return self.git_get(parsed)
        if parsed.path == "/api/files":
            return self.files_get(parsed)
        if parsed.path == "/ws":
            return self.handle_ws(parsed)
        return self.serve_static(parsed.path)

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/agent-room-login":
            content_type = self.headers.get("Content-Type", "")
            if "application/x-www-form-urlencoded" in content_type:
                length = int(self.headers.get("Content-Length", "0") or "0")
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                params = dict(pair.split("=", 1) for pair in raw.split("&") if "=" in pair)
                token = unquote_plus(params.get("token", ""))
            else:
                body = read_json(self)
                token = str(body.get("token") or "")
            if not hmac.compare_digest(token, get_auth_token()):
                return json_response(self, 401, {"ok": False, "error": "token 不正确"})
            prefix = self.headers.get("X-Forwarded-Prefix", "")
            self.send_response(302)
            self.send_header("Location", prefix + "/")
            self.set_auth_cookie()
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self.require_auth(parsed):
            return
        if parsed.path == "/api/logout":
            payload = json.dumps({"ok": True}, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.clear_auth_cookie()
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if parsed.path == "/api/sessions":
            return self.create_session()
        if parsed.path.startswith("/api/git/"):
            return self.git_post(parsed)
        if parsed.path == "/api/files":
            return self.files_post(parsed)
        if parsed.path.startswith("/api/sessions/") and parsed.path.endswith("/input"):
            session_id = parsed.path.split("/")[3]
            body = read_json(self)
            with sessions_lock:
                session = sessions.get(session_id)
            if not session:
                return json_response(self, 404, {"error": "会话不存在"})
            session.write(str(body.get("data", "")), bool(body.get("recordUser")))
            return json_response(self, 200, {"ok": True})
        if parsed.path.startswith("/api/sessions/") and parsed.path.endswith("/message"):
            session_id = parsed.path.split("/")[3]
            body = read_json(self)
            with sessions_lock:
                session = sessions.get(session_id)
            if not session:
                return json_response(self, 404, {"error": "会话不存在"})
            text = str(body.get("text", "")).strip()
            if not text:
                return json_response(self, 400, {"error": "消息不能为空"})
            session.enqueue_prompt(text)
            return json_response(self, 202, session.serialize())
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

    def git_get(self, parsed):
        query = parse_qs(parsed.query)
        cwd = normalize_cwd((query.get("cwd") or [""])[0])
        try:
            if (query.get("view") or ["summary"])[0] == "diff":
                path = (query.get("path") or [""])[0] or None
                staged = (query.get("staged") or ["0"])[0] == "1"
                return json_response(self, 200, git_diff(cwd, path, staged))
            return json_response(self, 200, git_summary(cwd))
        except Exception as exc:
            return json_response(self, 400, {"ok": False, "error": str(exc)})

    def git_post(self, parsed):
        action = parsed.path.split("/")[-1]
        body = read_json(self)
        cwd = normalize_cwd(body.get("cwd") or body.get("project"))
        paths = [str(path) for path in body.get("paths", [])]
        try:
            repo = ensure_git_repo(cwd)
            output = ""
            if action == "stage":
                git_cmd(repo, "add", "--", *(paths or ["."]), check=True)
            elif action == "unstage":
                git_cmd(repo, "restore", "--staged", "--", *(paths or ["."]), check=True)
            elif action == "commit":
                message = str(body.get("message") or "").strip()
                if not message:
                    raise RuntimeError("提交信息不能为空。")
                _, output = git_cmd(repo, "commit", "-m", message, timeout=60, check=True)
            elif action == "fetch":
                _, output = git_cmd(repo, "fetch", "--all", "--prune", timeout=120, check=True)
            elif action == "pull":
                _, output = git_cmd(repo, "pull", "--ff-only", timeout=120, check=True)
            elif action == "push":
                _, output = git_cmd(repo, "push", timeout=120, check=True)
            else:
                return json_response(self, 404, {"ok": False, "error": "unknown git action"})
            summary = git_summary(repo)
            summary["output"] = output
            return json_response(self, 200, summary)
        except Exception as exc:
            return json_response(self, 400, {"ok": False, "error": str(exc)})

    def files_get(self, parsed):
        query = parse_qs(parsed.query)
        cwd = normalize_cwd((query.get("cwd") or [""])[0])
        view = (query.get("view") or ["tree"])[0]
        try:
            if view == "read":
                return json_response(self, 200, read_file(cwd, (query.get("path") or [""])[0]))
            return json_response(self, 200, file_tree(cwd))
        except Exception as exc:
            return json_response(self, 400, {"ok": False, "error": str(exc)})

    def files_post(self, parsed):
        body = read_json(self)
        cwd = normalize_cwd(body.get("cwd"))
        action = str(body.get("action") or "save")
        try:
            if action == "create":
                return json_response(self, 200, create_file(cwd, body.get("directory"), body.get("name")))
            if action == "move":
                return json_response(self, 200, move_file(cwd, body.get("path"), body.get("targetDirectory")))
            return json_response(self, 200, write_file(cwd, body.get("path"), body.get("content", "")))
        except Exception as exc:
            return json_response(self, 400, {"ok": False, "error": str(exc)})

    def do_DELETE(self):
        parsed = urlparse(self.path)
        if not self.require_auth(parsed):
            return
        if parsed.path.startswith("/api/sessions/"):
            session_id = parsed.path.split("/")[3]
        else:
            return json_response(self, 404, {"error": "not found"})
        with sessions_lock:
            session = sessions.pop(session_id, None)
        if not session:
            return json_response(self, 404, {"error": "会话不存在"})
        session.stop()
        save_sessions()
        return json_response(self, 200, {"ok": True})
        return json_response(self, 404, {"error": "not found"})

    def create_session(self):
        body = read_json(self)
        agent = str(body.get("agent") or "claude").strip().lower()
        if agent not in {"claude", "codex"}:
            return json_response(self, 400, {"error": "agent 只能是 claude 或 codex"})
        command = resolve_command(agent)
        if not command:
            env_name = "CODEX_BIN" if agent == "codex" else "CLAUDE_BIN"
            return json_response(self, 400, {"error": f"未找到 {agent}。可用 {env_name}=/path/to/{agent} bash dev.sh 指定。"})
        cwd = normalize_cwd(body.get("cwd"))
        title = str(body.get("title") or Path(cwd).name or agent.title()).strip()
        args = [str(item) for item in body.get("args", []) if str(item)]
        if not args:
            args = []
        cols = int(body.get("cols", 120))
        rows = int(body.get("rows", 34))
        prompt = str(body.get("prompt") or "").strip()
        try:
            session = Session(title, cwd, command, args, cols, rows, agent=agent)
        except Exception as exc:
            return json_response(self, 500, {"error": f"启动失败：{exc}", "command": command, "cwd": cwd})
        with sessions_lock:
            sessions[session.id] = session
        save_sessions()
        if prompt:
            if session.master_fd is not None:
                session.send_initial_pty_prompt(prompt)
            else:
                session.enqueue_prompt(prompt)
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
                        session.enqueue_prompt(text)
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
        if path.suffix in {".html", ".js", ".css"}:
            self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] == "token":
            print_token()
            raise SystemExit(0)
        print("Usage: bash dev.sh [token]", file=sys.stderr)
        raise SystemExit(2)
    os.chdir(ROOT)
    get_auth_token()
    get_session_secret()
    command = resolve_command()
    load_sessions(command)
    print(f"agent-room listening on http://0.0.0.0:{PORT}")
    print(f"Claude command: {command or 'not found'}")
    print(f"Auth token: cat ~/.agentroom/token")
    print(f"Auth token CLI: python3 {ROOT / 'server.py'} token")
    ThreadingServer(("0.0.0.0", PORT), Handler).serve_forever()
