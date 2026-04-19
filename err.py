#!/usr/bin/env python3
"""err 0.4 — explains your last shell command or answers questions using a local MLX model."""

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

# ── help ────────────────────────────────────────────────────────────

HELP = """\

ERR 0.4 // explains the last command or answers questions using a local LLM

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
  to a local mlx-lm server and streams a short explanation.
  Optionally capture stderr: some-cmd 2>/tmp/err_stderr; err

"""

# ── mlx-lm server management ──────────────────────────────────────


def health_ok() -> bool:
    try:
        req = urllib.request.Request(f"{MLX_HOST}/v1/models", method="GET")
        with urllib.request.urlopen(req, timeout=2) as resp:
            return resp.status == 200
    except Exception:
        return False


def ensure_running() -> bool:
    if health_ok():
        return True

    print("🚀 Starting mlx-lm server...")
    log = open("/tmp/mlx_lm_server.log", "w")

    cmd = [
        "mlx_lm", "server",
        "--model", CFG["model_id"],
        "--host", "127.0.0.1",
        "--port", PORT,
        "--chat-template-args", json.dumps({"enable_thinking": False}),
    ]

    subprocess.Popen(cmd, stdout=log, stderr=log)

    for _ in range(60):
        time.sleep(1)
        if health_ok():
            print("✅ mlx-lm ready")
            return True

    print("❌ mlx-lm server failed to start. Check /tmp/mlx_lm_server.log", file=sys.stderr)
    return False


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
        context = f"{env} Command: {cmd}"
        prompt = CFG["prompt_success"]
    else:
        context = f"{env} Command (exit {exit_code}): {cmd}"
        prompt = CFG["prompt_fail"]
        if not stderr_content:
            context += "\nNo error output available."

    if stderr_content:
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
    else:
        print(f"💥 {cmd} (exit {exit_code})")

    if not ensure_running():
        sys.exit(1)

    stderr_content = ""
    stderr_file = os.environ.get("_ERR_STDERR_FILE", "/tmp/err_stderr")
    if os.path.isfile(stderr_file) and os.path.getsize(stderr_file) > 0:
        with open(stderr_file) as f:
            stderr_content = f.read()

    handle_command(cmd, exit_code, stderr_content)


if __name__ == "__main__":
    main()
