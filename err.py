#!/usr/bin/env python3
"""err 0.5 — explains your last shell command or answers questions using Apple Foundation Models."""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

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

# ── help ────────────────────────────────────────────────────────────

HELP = """\

ERR 0.5 // explains the last command or answers questions using Apple Foundation Models

Usage:
  err                  Explain the last command
  err <question>       Ask a shell/CLI question
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
  to an Apple Foundation Models server and streams a short explanation.
  Optionally capture stderr: some-cmd 2>/tmp/err_stderr; err

"""

# ── fm server management ────────────────────────────────────────


def health_ok() -> bool:
    try:
        req = urllib.request.Request(f"{MLX_HOST}/v1/models", method="GET")
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
            print("✅ fm server ready")
            touch_heartbeat()
            build_shell_config_cache()
            spawn_idle_watchdog(proc.pid)
            return True

    print("❌ fm server failed to start. Check /tmp/fm_server.log", file=sys.stderr)
    return False


# ── shell-config cache ──────────────────────────────────────────────
# Dumped once when the fm server starts; looked up per call.


def _strip_quotes(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    return s


def parse_shell_config(dump: str) -> tuple[dict, dict]:
    aliases: dict[str, str] = {}
    functions: dict[str, str] = {}
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
    body: list[str] = []
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


# ── LLM helpers ───────────────────────────────────────────────────


def strip_thinking(text: str) -> str:
    """Safety fallback: remove any <think> blocks that slip through."""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()


def stream_response(messages: list[dict]) -> None:
    payload = json.dumps(
        {
            "model": CFG["model_id"],
            "max_tokens": int(CFG["max_tokens"]),
            "temperature": float(CFG["temperature"]),
            "top_p": 0.8,
            "stream": True,
            "messages": messages,
        }
    ).encode()

    req = urllib.request.Request(
        f"{MLX_HOST}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    collected = []
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            for raw_line in resp:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                    delta = chunk["choices"][0]["delta"].get("content", "")
                    if delta:
                        collected.append(delta)
                        print(delta, end="", flush=True)
                except (json.JSONDecodeError, KeyError, IndexError):
                    continue

        # safety strip on full output
        full = "".join(collected)
        cleaned = strip_thinking(full)
        if cleaned != full:
            # reprint cleaned version
            print(f"\r\033[K{cleaned}", end="")
        print("\n")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            err_msg = json.loads(body).get("error", body)
        except json.JSONDecodeError:
            err_msg = body
        print(f"\n❌ Server error ({e.code}): {err_msg}", file=sys.stderr)
    except urllib.error.URLError as e:
        print(f"\n❌ Connection failed: {e.reason}", file=sys.stderr)


# ── command explanation ───────────────────────────────────────────


def handle_command(cmd: str, exit_code: int, stderr_content: str) -> None:
    env = "macOS, zsh."
    if exit_code == 0:
        context = f"{env} Command (exit 0): {cmd}"
        prompt = CFG["prompt_success"]
    elif exit_code < 0:
        context = f"{env} Command (exit unknown): {cmd}"
        prompt = CFG.get(
            "prompt_unknown",
            "If the context includes a shell-config definition for the command, state it and explain what the command does. Do not assume it failed unless there is evidence of an error.",
        )
    else:
        context = f"{env} Command (exit {exit_code}): {cmd}"
        prompt = CFG["prompt_fail"]
        if not stderr_content:
            context += "\nNo error output available."

    defn = shell_defn(cmd)
    if defn:
        first = cmd.split()[0] if cmd.split() else cmd
        context += f"\nThe user's shell config defines '{first}' as: {defn}"

    if stderr_content and exit_code > 0:
        stderr_trimmed = stderr_content.strip()[:300]
        context += f"\nStderr: {stderr_trimmed}"

    messages = [{"role": "user", "content": f"{context}\n{prompt}"}]
    stream_response(messages)


# ── freeform question ─────────────────────────────────────────────


def handle_question(question: str) -> None:
    system_prompt = "Short shell answers for macOS and zsh. Include one example command."

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": question},
    ]

    stream_response(messages)


# ── main ────────────────────────────────────────────────────────────


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] in ("-h", "--help"):
        print(HELP)
        return

    # freeform question mode: err <question...>
    if len(sys.argv) >= 2:
        question = " ".join(sys.argv[1:])
        print()
        if not ensure_running():
            sys.exit(1)
        handle_question(question)
        return

    # default mode: explain last command
    cmd = os.environ.get("_ERR_LAST_CMD", "")
    exit_code_str = os.environ.get("_ERR_LAST_EXIT", "0")

    if not cmd:
        print("No command recorded yet.", file=sys.stderr)
        sys.exit(1)

    exit_code = int(exit_code_str)

    print()
    if exit_code == 0:
        print(f"✅ {cmd} (exit 0)")
    elif exit_code < 0:
        print(f"❔ {cmd} (exit unknown)")
    else:
        print(f"💥 {cmd} (exit {exit_code})")

    if not ensure_running():
        sys.exit(1)

    stderr_content = ""
    stderr_file = os.environ.get("_ERR_STDERR_FILE", "/tmp/err_stderr")
    if exit_code > 0 and os.path.isfile(stderr_file) and os.path.getsize(stderr_file) > 0:
        with open(stderr_file) as f:
            stderr_content = f.read()

    handle_command(cmd, exit_code, stderr_content)


if __name__ == "__main__":
    main()
