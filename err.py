#!/usr/bin/env python3
"""err 0.601 — explain, ask and session engine for the err launcher.

Stdlib-only, single file, python3.9 compatible.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ── config ──────────────────────────────────────────────────────────


def load_config() -> dict:
    cfg = {}
    conf_path = os.path.join(SCRIPT_DIR, "err.conf")
    if not os.path.isfile(conf_path):
        print(f"❌ Config not found: {conf_path}", file=sys.stderr)
        sys.exit(1)
    with open(conf_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            if key and value:
                cfg[key] = value
    return cfg


CFG = load_config()

PORT = CFG.get("port", "8080")
MLX_HOST = f"http://127.0.0.1:{PORT}"
IDLE_TIMEOUT_MIN = float(CFG.get("idle_timeout_minutes", "10"))
HEARTBEAT_FILE = "/tmp/err_last_use"
SHELL_CONFIG_CACHE = "/tmp/err_shellconfig"
SHELL_CONFIG_MARKER = "@@FUNCTIONS@@"
FUNC_BODY_LIMIT = 300

SESSION_MAX_AGE = 7 * 24 * 60 * 60
SESSION_MAX_COUNT = 50
SUGGEST_BYTE_LIMIT = 400

# ── help ────────────────────────────────────────────────────────────

HELP = """\

ERR 0.601 // explains the last command, answers questions, keeps sessions

Usage:
  err                  Explain the last command
  err <question>       Ask a shell/CLI question
  err new              Start a fresh session
  err clear | err -c   Clear the current session (keep its id)
  err resume [n]       List sessions, or resume session number n
  err delete           Delete all sessions (asks once)
  errc <cmd...>        Run <cmd>, capture stderr, then auto-explain
  err -h|--help        Show this help

Exit codes explained:
  1     General error (catchall)
  2     Misuse of shell builtin
  126   Command found but not executable (permission denied)
  127   Command not found (typo, not installed, not in PATH)
  128   Invalid exit argument
  128+N Killed by signal N (e.g. 130 = Ctrl-C, 137 = SIGKILL, 139 = segfault)
  255   Exit status out of range

How it works:
  Run a command, then type `err`. It sends the command and exit code
  to a model server and streams a short explanation. Optionally capture
  stderr: some-cmd 2>/tmp/err_stderr; err

"""

# ── fm server management ────────────────────────────────────────


def health_ok(base_url: str = MLX_HOST) -> bool:
    try:
        req = urllib.request.Request(f"{base_url}/v1/models", method="GET")
        with urllib.request.urlopen(req, timeout=2) as resp:
            return resp.status == 200
    except Exception:
        return False


def touch_heartbeat() -> None:
    try:
        with open(HEARTBEAT_FILE, "w") as f:
            f.write(str(time.time()))
    except OSError:
        pass


def spawn_idle_watchdog(server_pid: int) -> None:
    watchdog = (
        "import os, sys, time, signal\n"
        f"pid={server_pid}\n"
        f"hb={HEARTBEAT_FILE!r}\n"
        f"timeout={IDLE_TIMEOUT_MIN}*60\n"
        "while True:\n"
        "    time.sleep(30)\n"
        "    try: os.kill(pid, 0)\n"
        "    except OSError: sys.exit(0)\n"
        "    try: last=os.path.getmtime(hb)\n"
        "    except OSError: last=time.time()\n"
        "    if time.time()-last>timeout:\n"
        "        try: os.kill(pid, signal.SIGTERM)\n"
        "        except OSError: pass\n"
        "        sys.exit(0)\n"
    )
    subprocess.Popen(
        [sys.executable, "-c", watchdog],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def ensure_running() -> bool:
    if health_ok():
        touch_heartbeat()
        if not os.path.isfile(SHELL_CONFIG_CACHE):
            build_shell_config_cache()
        return True

    print("🚀 Starting Apple Foundation Models server...")
    log = open("/tmp/fm_server.log", "w")

    cmd = [
        "fm", "serve",
        "--host", "127.0.0.1",
        "--port", PORT,
    ]

    proc = subprocess.Popen(cmd, stdout=log, stderr=log, start_new_session=True)

    for _ in range(60):
        time.sleep(1)
        if health_ok():
            print("🟢 fm server ready")
            touch_heartbeat()
            build_shell_config_cache()
            spawn_idle_watchdog(proc.pid)
            return True

    print("❌ fm server failed to start. Check /tmp/fm_server.log", file=sys.stderr)
    return False


# ── backend selection ──────────────────────────────────────────────


def backend_name() -> str:
    return (os.environ.get("ERR_BACKEND") or CFG.get("backend", "fm")).strip().lower()


def mlx_base_url() -> str:
    url = os.environ.get("ERR_BASE_URL") or CFG.get("mlx_base_url", "http://127.0.0.1:11500")
    return url.strip().rstrip("/")


def prepare_backend() -> tuple:
    """Return (base_url, model_id) for the configured backend."""
    backend = backend_name()
    if backend == "mlx":
        base = mlx_base_url()
        # Never start fm for the mlx backend: just point at the running server.
        if not health_ok(base):
            print(
                f"❌ mlx server not reachable at {base} — start it with: err run <model>",
                file=sys.stderr,
            )
            sys.exit(1)
        return base, CFG.get("model_id", "system")

    # fm and pcc both use the on-device fm server.
    if not ensure_running():
        sys.exit(1)
    model_id = "pcc" if backend == "pcc" else CFG.get("model_id", "system")
    return MLX_HOST, model_id


# ── shell-config cache ──────────────────────────────────────────────
# Dumped once when the fm server starts; looked up per call.


def _strip_quotes(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    return s


def parse_shell_config(dump: str) -> tuple:
    aliases = {}
    functions = {}
    if SHELL_CONFIG_MARKER in dump:
        alias_part, _, func_part = dump.partition(SHELL_CONFIG_MARKER)
    else:
        alias_part, func_part = dump, ""

    for line in alias_part.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        name, _, value = line.partition("=")
        name = name.strip()
        if name:
            aliases[name] = _strip_quotes(value)

    func_name = None
    body = []
    for line in func_part.splitlines():
        stripped = line.strip()
        m = re.match(r"^(?:function\s+)?(\S+)\s*\(\s*\)\s*\{?\s*$", stripped)
        if m:
            if func_name:
                functions[func_name] = " ".join(body)[:FUNC_BODY_LIMIT]
            func_name = m.group(1)
            body = []
        elif func_name is not None:
            body.append(stripped)
    if func_name:
        functions[func_name] = " ".join(body)[:FUNC_BODY_LIMIT]

    return aliases, functions


def build_shell_config_cache() -> None:
    """Dump the shell's aliases and functions into the cache file."""
    try:
        dump = subprocess.run(
            ["zsh", "-ic", f'alias; print -r -- "{SHELL_CONFIG_MARKER}"; functions'],
            capture_output=True,
            text=True,
            timeout=30,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return
    aliases, functions = parse_shell_config(dump)
    try:
        with open(SHELL_CONFIG_CACHE, "w") as f:
            json.dump({"aliases": aliases, "functions": functions}, f)
    except OSError:
        pass


def load_shell_config() -> dict:
    try:
        with open(SHELL_CONFIG_CACHE) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def shell_defn(cmd: str) -> str:
    first = cmd.split()[0] if cmd.split() else cmd
    cfg = load_shell_config()
    aliases = cfg.get("aliases", {})
    functions = cfg.get("functions", {})
    if first in aliases:
        return f"alias: {aliases[first]}"
    if first in functions:
        return f"function: {functions[first]}"
    return ""


# ── sessions ─────────────────────────────────────────────────────────


def state_dir() -> str:
    return os.path.abspath(
        os.path.expanduser(os.environ.get("ERR_STATE_DIR") or "~/.cache/marv/mlx")
    )


def sessions_dir() -> str:
    return os.path.join(state_dir(), "sessions")


def ensure_sessions_dir() -> str:
    d = sessions_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def session_path(sid: str) -> str:
    return os.path.join(sessions_dir(), f"{sid}.json")


def valid_session_id(sid: str) -> bool:
    try:
        uuid.UUID(sid)
        return True
    except (ValueError, AttributeError, TypeError):
        return False


def current_session_id() -> str:
    sid = os.environ.get("_ERR_SESSION_ID", "").strip()
    if sid and valid_session_id(sid):
        return sid
    return str(uuid.uuid4())


def _safe_int(value, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def default_session(sid: str) -> dict:
    now = int(time.time())
    return {
        "id": sid,
        "created_at": now,
        "last_used": now,
        "pid": os.getppid(),
        "tty": current_tty(),
        "cwd": os.getcwd(),
        "title": "",
        "turns": [],
        "tokens": 0,
    }


def current_tty() -> str:
    try:
        if sys.stdin.isatty():
            return os.path.basename(os.ttyname(sys.stdin.fileno()))
    except (OSError, ValueError, AttributeError):
        pass
    return os.environ.get("TTY", "") or "?"


def load_session(sid: str):
    try:
        with open(session_path(sid)) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    data.setdefault("id", sid)
    data.setdefault("created_at", 0)
    data.setdefault("last_used", 0)
    data.setdefault("pid", 0)
    data.setdefault("tty", "?")
    data.setdefault("cwd", "")
    data.setdefault("title", "")
    data.setdefault("turns", [])
    data.setdefault("tokens", 0)
    return data


def save_session(sess: dict) -> None:
    ensure_sessions_dir()
    path = session_path(sess["id"])
    payload = json.dumps(sess, ensure_ascii=False)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(payload)
    finally:
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass


def session_files() -> list:
    d = sessions_dir()
    try:
        names = os.listdir(d)
    except OSError:
        return []
    return [os.path.join(d, n) for n in names if n.endswith(".json")]


def load_all_sessions() -> list:
    sessions = []
    for path in session_files():
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict):
            sessions.append(data)
    return sessions


def prune_sessions() -> None:
    """Drop sessions older than 7 days or beyond the 50 newest, oldest first."""
    entries = []
    for path in session_files():
        try:
            with open(path) as f:
                data = json.load(f)
            last_used = _safe_int(data.get("last_used", 0))
        except (OSError, json.JSONDecodeError, AttributeError):
            last_used = 0
        entries.append((path, last_used))
    entries.sort(key=lambda item: item[1], reverse=True)
    now = int(time.time())
    for index, (path, last_used) in enumerate(entries):
        expired = last_used <= 0 or now - last_used > SESSION_MAX_AGE
        if index >= SESSION_MAX_COUNT or expired:
            try:
                os.remove(path)
            except OSError:
                pass


def write_tokens_file(total: int) -> None:
    path = os.environ.get("_ERR_TOKENS_FILE")
    if not path:
        return
    try:
        with open(path, "w") as f:
            f.write(f"{total}\n")
    except OSError:
        pass


# ── redaction ───────────────────────────────────────────────────────

REDACTION_PATTERNS = [
    (
        re.compile(r"([A-Z_]*(?:KEY|TOKEN|SECRET|PASSWORD)[A-Z_]*=)\S*"),
        r"\1«redacted»",
    ),
    (re.compile(r"\bghp_[A-Za-z0-9]+"), "«redacted»"),
    (re.compile(r"\bsk-[A-Za-z0-9_-]+"), "«redacted»"),
    (re.compile(r"(Bearer\s+)\S+"), r"\1«redacted»"),
]


def redact(text: str) -> str:
    if not text:
        return text
    for pattern, replacement in REDACTION_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


# ── conversation window ─────────────────────────────────────────────


def history_turn_limit() -> int:
    return max(0, _safe_int(CFG.get("history_turns", "6"), 6))


def conversation_messages(system_prompt: str, sid: str, user_content: str) -> list:
    sess = load_session(sid) or default_session(sid)
    prior = sess.get("turns", [])[-history_turn_limit():] if history_turn_limit() else []
    messages = [{"role": "system", "content": system_prompt}]
    for turn in prior:
        if turn.get("q"):
            messages.append({"role": "user", "content": turn["q"]})
        if turn.get("a"):
            messages.append({"role": "assistant", "content": turn["a"]})
    messages.append({"role": "user", "content": user_content})
    return messages


def _session_title(user_content: str, command: str) -> str:
    """One readable line for `err resume`.

    An explain turn has no question, so its "user content" is the whole
    `Command: … / Exit code: … / <prompt>` block; the command is the useful
    part. Either way the title is collapsed to a single line.
    """
    command = " ".join((command or "").split())
    if command:
        return ("explain: " + command)[:60]
    return " ".join((user_content or "").split())[:60]


def record_turn(sid: str, user_content: str, answer: str, cmd: str, exit_code: int, tokens: int,
                title: str = "") -> None:
    sess = load_session(sid) or default_session(sid)
    q = redact(user_content)
    a = redact(answer)
    c = redact(cmd)
    if not sess.get("turns") and not sess.get("title"):
        sess["title"] = (title or _session_title(user_content, c))[:60]
    sess["turns"].append({"q": q, "a": a, "cmd": c, "exit": exit_code, "tokens": tokens})
    sess["tokens"] = _safe_int(sess.get("tokens", 0)) + tokens
    sess["last_used"] = int(time.time())
    save_session(sess)
    write_tokens_file(sess["tokens"])


# ── suggested command ───────────────────────────────────────────────

FENCED_BLOCK_RE = re.compile(r"```[^\n]*\n(.*?)```", re.DOTALL)


def first_fenced_line(text: str):
    match = FENCED_BLOCK_RE.search(text or "")
    if not match:
        return None
    for line in match.group(1).splitlines():
        stripped = line.strip()
        if stripped:
            return stripped
    return None


def suggest_mode() -> str:
    return (os.environ.get("ERR_SUGGEST") or CFG.get("suggest", "ask")).strip().lower()


def clear_suggest_file() -> None:
    if suggest_mode() == "off":
        return
    path = os.environ.get("_ERR_SUGGEST_FILE")
    if not path:
        return
    try:
        with open(path, "w"):
            pass
    except OSError:
        pass


def write_suggest_file(text: str) -> None:
    if suggest_mode() == "off":
        return
    path = os.environ.get("_ERR_SUGGEST_FILE")
    if not path:
        return
    command = first_fenced_line(text)
    if not command:
        return
    data = command.encode("utf-8")[:SUGGEST_BYTE_LIMIT].decode("utf-8", "ignore")
    try:
        with open(path, "w") as f:
            f.write(data)
    except OSError:
        pass


# ── LLM helpers ───────────────────────────────────────────────────


def strip_thinking(text: str) -> str:
    """Safety fallback: remove any <think> blocks that slip through."""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()


def stream_chat(messages: list, base_url: str, model_id: str) -> tuple:
    """Stream one chat completion. Returns (text, tokens); text is None on failure."""
    payload = json.dumps(
        {
            "model": model_id,
            "max_tokens": int(CFG["max_tokens"]),
            "temperature": float(CFG["temperature"]),
            "top_p": 0.8,
            "stream": True,
            "stream_options": {"include_usage": True},
            "messages": messages,
        }
    ).encode()

    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    collected = []
    usage_total = None
    started = False
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print("💡 ", end="", flush=True)
            started = True
            for raw_line in resp:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                except json.JSONDecodeError:
                    continue
                usage = chunk.get("usage")
                if isinstance(usage, dict):
                    usage_total = _safe_int(usage.get("total_tokens"), usage_total or 0)
                choices = chunk.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta", {}).get("content", "")
                if delta:
                    collected.append(delta)
                    print(delta, end="", flush=True)

        full = "".join(collected)
        cleaned = strip_thinking(full)
        if cleaned != full:
            # reprint cleaned version
            print(f"\r\033[K💡 {cleaned}", end="")
        print()
        tokens = usage_total if usage_total is not None else len(cleaned) // 4
        return cleaned, tokens
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            err_msg = json.loads(body).get("error", body)
        except json.JSONDecodeError:
            err_msg = body
        nl = "\n" if started else ""
        print(f"{nl}❌ Server error ({e.code}): {err_msg}", file=sys.stderr)
    except urllib.error.URLError as e:
        nl = "\n" if started else ""
        print(f"{nl}❌ Connection failed: {e.reason}", file=sys.stderr)
    return None, None


# ── command explanation ───────────────────────────────────────────


DEFAULT_SYSTEM_PROMPT = (
    "You explain what a shell command did on macOS zsh. Answer in one short "
    "sentence. If the command is an alias, say which command the alias runs."
)


def build_explain_user(cmd: str, exit_code: int, stderr_content: str) -> str:
    first = cmd.split()[0] if cmd.split() else cmd
    defn = shell_defn(cmd)

    lines = [f"Command: {cmd}"]
    if defn:
        kind, _, expansion = defn.partition(": ")
        lines.append(f"Shell {kind} ({first}) expands to: {expansion}")

    if exit_code == 0:
        lines.append("Exit code: 0 (success)")
    elif exit_code < 0:
        lines.append("Exit code: unknown")
    else:
        lines.append(f"Exit code: {exit_code} (failure)")

    if exit_code > 0:
        if stderr_content.strip():
            lines.append(f"Error output: {stderr_content.strip()[:300]}")
        else:
            lines.append("Error output: none")

    lines.append("")
    if exit_code == 0:
        lines.append(CFG["prompt_success"])
    elif exit_code < 0:
        lines.append(CFG.get("prompt_unknown", ""))
    elif exit_code == 127:
        lines.append(CFG.get("prompt_not_found", CFG["prompt_fail"]))
    else:
        lines.append(CFG["prompt_fail"])

    return "\n".join(lines)


def run_explain() -> None:
    cmd = os.environ.get("_ERR_LAST_CMD", "")
    exit_code_str = os.environ.get("_ERR_LAST_EXIT", "0")

    if not cmd:
        print("🤔 No command recorded yet.", file=sys.stderr)
        sys.exit(1)

    exit_code = int(exit_code_str)

    if exit_code == 0:
        print(f"✅ {cmd} (exit 0)")
    elif exit_code < 0:
        print(f"❔ {cmd} (exit unknown)")
    else:
        print(f"💥 {cmd} (exit {exit_code})")

    base_url, model_id = prepare_backend()

    stderr_content = ""
    stderr_file = os.environ.get("_ERR_STDERR_FILE", "/tmp/err_stderr")
    if exit_code > 0 and os.path.isfile(stderr_file) and os.path.getsize(stderr_file) > 0:
        with open(stderr_file) as f:
            stderr_content = f.read()

    sid = current_session_id()
    user_content = build_explain_user(cmd, exit_code, stderr_content)
    system_prompt = CFG.get("system_prompt", DEFAULT_SYSTEM_PROMPT)
    messages = conversation_messages(system_prompt, sid, user_content)

    clear_suggest_file()
    answer, tokens = stream_chat(messages, base_url, model_id)
    if answer is None:
        sys.exit(1)
    write_suggest_file(answer)
    record_turn(sid, user_content, answer, cmd, exit_code, tokens, title=cmd)


# ── freeform question ─────────────────────────────────────────────


DEFAULT_QUESTION_PROMPT = (
    "You answer shell questions for macOS zsh. Reply in at most three short "
    "sentences, then give one example command in a fenced code block. If the "
    "answer needs no command, skip the code block."
)


def run_ask(question: str) -> None:
    base_url, model_id = prepare_backend()

    sid = current_session_id()
    system_prompt = CFG.get("question_system_prompt", DEFAULT_QUESTION_PROMPT)
    messages = conversation_messages(system_prompt, sid, question)

    clear_suggest_file()
    answer, tokens = stream_chat(messages, base_url, model_id)
    if answer is None:
        sys.exit(1)
    write_suggest_file(answer)
    cmd = first_fenced_line(answer) or ""
    record_turn(sid, question, answer, cmd, 0, tokens, title=question)


# ── session verbs ───────────────────────────────────────────────────


def emit_session_id(sid: str) -> None:
    path = os.environ.get("_ERR_SESSION_ID_FILE")
    if path:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(f"{sid}\n")
            return
        except OSError:
            pass
    # No _ERR_SESSION_ID_FILE (e.g. a direct `python3 err.py new` run): print the
    # id on stdout so the caller can export _ERR_SESSION_ID itself.
    print(sid)


def cmd_new() -> None:
    sid = str(uuid.uuid4())
    save_session(default_session(sid))
    emit_session_id(sid)


def cmd_clear() -> None:
    sid = current_session_id()
    sess = load_session(sid) or default_session(sid)
    sess["turns"] = []
    sess["title"] = ""
    sess["last_used"] = int(time.time())
    save_session(sess)


def human_age(seconds: int) -> str:
    seconds = max(0, seconds)
    if seconds < 60:
        return "now"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"


def cmd_resume(args: list) -> None:
    sessions = load_all_sessions()
    sessions.sort(key=lambda s: _safe_int(s.get("last_used", 0)), reverse=True)

    if not args:
        if not sessions:
            print("No sessions.")
            return
        now = int(time.time())
        for index, sess in enumerate(sessions, 1):
            age = human_age(now - _safe_int(sess.get("last_used", 0)))
            tty = sess.get("tty") or "?"
            cwd = sess.get("cwd") or "?"
            title = (sess.get("title") or "").strip() or "(untitled)"
            print(f"{index:>2}. {age:>4}  {tty:<10}  {cwd}  —  {title}")
        return

    if len(args) != 1 or not args[0].isdigit():
        print("usage: err resume [n]", file=sys.stderr)
        sys.exit(2)

    choice = int(args[0])
    if choice < 1 or choice > len(sessions):
        print(f"❌ No session {choice}.", file=sys.stderr)
        sys.exit(1)

    sess = sessions[choice - 1]
    sid = sess.get("id")
    if not sid:
        print("❌ Session has no id.", file=sys.stderr)
        sys.exit(1)
    sess["last_used"] = int(time.time())
    save_session(sess)
    emit_session_id(sid)


def cmd_delete() -> None:
    files = session_files()
    if not files:
        print("No sessions.")
        return
    print(f"Delete {len(files)} session(s)? [y/N] ", end="", file=sys.stderr, flush=True)
    answer = sys.stdin.readline().strip().lower()
    if answer not in ("y", "yes"):
        print("Cancelled.")
        return
    removed = 0
    for path in files:
        try:
            os.remove(path)
            removed += 1
        except OSError:
            pass
    print(f"Deleted {removed} session(s).")


# ── main ────────────────────────────────────────────────────────────


def main() -> None:
    args = sys.argv[1:]

    if args and args[0] in ("-h", "--help"):
        print(HELP)
        return

    prune_sessions()

    if not args:
        run_explain()
        return

    verb = args[0]
    if verb == "new":
        cmd_new()
        return
    if verb in ("clear", "-c"):
        cmd_clear()
        return
    if verb == "resume":
        cmd_resume(args[1:])
        return
    if verb == "delete":
        cmd_delete()
        return

    if verb == "--ask":
        question = " ".join(args[1:])
    else:
        question = " ".join(args)

    if not question:
        print("usage: err <question>", file=sys.stderr)
        sys.exit(2)

    run_ask(question)


if __name__ == "__main__":
    main()
