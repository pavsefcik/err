#!/usr/bin/env python3
"""Plain-python acceptance tests for err.py (no pytest, no fm, no network).

Run from the repository root:  python3 tests/test_err.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = os.path.dirname(os.path.abspath(__file__))
ERR_PY = os.path.join(REPO, "err.py")

sys.path.insert(0, REPO)
sys.path.insert(0, TESTS)

import err as errmod  # noqa: E402
import mock_fm_server  # noqa: E402


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def read(path):
    with open(path) as f:
        return f.read()


def main():
    state, server, base_url = mock_fm_server.start()
    tmp = tempfile.mkdtemp(prefix="err-test-")
    sid = str(uuid.uuid4())
    tokens_file = os.path.join(tmp, "tokens")
    tokens_file_2 = os.path.join(tmp, "tokens2")
    suggest_file = os.path.join(tmp, "suggest")
    session_id_file = os.path.join(tmp, "session_id")
    stderr_file = os.path.join(tmp, "stderr")

    base_env = {
        "ERR_STATE_DIR": tmp,
        "ERR_BACKEND": "mlx",
        "ERR_BASE_URL": base_url,
        # The mock stands in for the :11500 server; mlx-vlm would otherwise be
        # asked to load err.conf's fm model_id ("system").
        "ERR_MLX_MODEL": "mock/model",
        "_ERR_SESSION_ID": sid,
        "_ERR_TOKENS_FILE": tokens_file,
        "_ERR_SUGGEST_FILE": suggest_file,
        "_ERR_SESSION_ID_FILE": session_id_file,
        "_ERR_STDERR_FILE": stderr_file,
    }

    def run(args, extra=None, stdin=None):
        env = os.environ.copy()
        env.pop("ERR_SUGGEST", None)
        env.update(base_env)
        if extra:
            env.update(extra)
        return subprocess.run(
            [sys.executable, ERR_PY] + args,
            cwd=REPO,
            env=env,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def session_file(session_id):
        return os.path.join(tmp, "sessions", f"{session_id}.json")

    passed = []

    def ok(name):
        passed.append(name)
        print(f"PASS {name}")

    try:
        # ── unit: redaction + fenced extraction ──────────────────────
        redacted = errmod.redact("export GITHUB_TOKEN=ghp_abc123XYZ")
        check("ghp_abc123XYZ" not in redacted, "raw github token survived redaction")
        check("«redacted»" in redacted, "redaction marker missing")
        check(
            errmod.first_fenced_line("Try:\n```bash\nls -la\n```\n") == "ls -la",
            "first fenced line extraction",
        )
        ok("redact + fenced extraction")

        # ── explain mode: messages, session turn, usage tokens ───────
        state.reply = "It lists files."
        state.usage_total = 42
        proc = run([], {"_ERR_LAST_CMD": "ls -la", "_ERR_LAST_EXIT": "0"})
        check(proc.returncode == 0, f"explain failed: {proc.stderr}")
        request = state.requests[-1]
        check(
            request.get("stream_options", {}).get("include_usage") is True,
            "stream_options.include_usage missing",
        )
        messages = request["messages"]
        check(messages[0]["role"] == "system", "system prompt not first")
        check(
            "Command: ls -la" in messages[-1]["content"],
            "explain user content missing command",
        )
        check(
            "Exit code: 0 (success)" in messages[-1]["content"],
            "explain user content missing exit code",
        )
        check(
            int(read(tokens_file).strip()) == 42,
            "usage total not written to _ERR_TOKENS_FILE",
        )
        sess = json.loads(read(session_file(sid)))
        check(len(sess["turns"]) == 1, "explain turn not persisted")
        ok("explain mode messages + usage tokens")

        # ── ask mode + history window + fenced suggestion ────────────
        state.reply = "Use ls.\n```bash\nls -la\n```\n"
        state.usage_total = 10
        proc = run(["--ask", "how do I list files"])
        check(proc.returncode == 0, f"ask failed: {proc.stderr}")
        request = state.requests[-1]
        check(
            request["messages"][-1]["content"] == "how do I list files",
            "ask question not the final user message",
        )
        roles = [m["role"] for m in request["messages"]]
        check(
            roles == ["system", "user", "assistant", "user"],
            f"history window wrong roles: {roles}",
        )
        check(
            "Command: ls -la" in request["messages"][1]["content"],
            "prior turn not replayed as history",
        )
        check(read(suggest_file) == "ls -la", "suggested command not written")
        ok("ask mode + history + suggestion")

        # ── session round-trip persists and reloads turns ────────────
        sess = json.loads(read(session_file(sid)))
        check(len(sess["turns"]) == 2, "session did not accumulate two turns")
        check(sess["turns"][0]["q"].startswith("Command: ls -la"), "turn q lost")
        check(sess["turns"][0]["a"] == "It lists files.", "turn a lost")
        ok("session round-trip")

        # ── redaction happens before persisting ──────────────────────
        state.reply = "done"
        state.usage_total = 5
        proc = run(["--ask", "export GITHUB_TOKEN=ghp_secret123"])
        check(proc.returncode == 0, f"redaction ask failed: {proc.stderr}")
        raw = read(session_file(sid))
        check("ghp_secret123" not in raw, "secret persisted to session file")
        check("«redacted»" in raw, "redaction marker not persisted")
        ok("redaction before persistence")

        # ── resume listing prints a row ──────────────────────────────
        proc = run(["resume"])
        check(proc.returncode == 0, f"resume failed: {proc.stderr}")
        rows = [line for line in proc.stdout.splitlines() if line.strip()]
        check(bool(rows), "resume printed no rows")
        check(rows[0].strip().startswith("1."), f"resume row malformed: {rows[0]!r}")
        check(REPO in rows[0], "resume row missing cwd")
        ok("resume listing")

        # ── token estimate when the server omits usage ───────────────
        state.usage_total = None
        state.reply = "a" * 40  # estimated at len(text)//4 == 10
        sid2 = str(uuid.uuid4())
        proc = run(
            ["--ask", "estimate please"],
            {"_ERR_SESSION_ID": sid2, "_ERR_TOKENS_FILE": tokens_file_2},
        )
        check(proc.returncode == 0, f"estimate ask failed: {proc.stderr}")
        check(int(read(tokens_file_2).strip()) == 10, "token estimate was not len//4")
        ok("token estimate fallback")

        # ── new writes the id to _ERR_SESSION_ID_FILE ────────────────
        new_id_file = os.path.join(tmp, "new_session_id")
        proc = run(["new"], {"_ERR_SESSION_ID_FILE": new_id_file})
        check(proc.returncode == 0, f"new failed: {proc.stderr}")
        content = read(new_id_file)
        check(content.endswith("\n"), "session id file should be one line")
        new_id = content.strip()
        check("\n" not in new_id, "session id file has more than one line")
        uuid.UUID(new_id)  # raises if not a uuid
        check(os.path.isfile(session_file(new_id)), "new session file not created")
        ok("new writes _ERR_SESSION_ID_FILE")

        # ── delete declines cleanly, then removes on confirmation ────
        proc = run(["delete"], stdin="n\n")
        check(proc.returncode == 0, f"delete decline failed: {proc.stderr}")
        check("Cancelled" in proc.stdout, "delete decline message missing")
        check(os.path.isfile(session_file(sid)), "declined delete removed files")
        proc = run(["delete"], stdin="y\n")
        check(proc.returncode == 0, f"delete failed: {proc.stderr}")
        check(not os.path.isfile(session_file(sid)), "confirmed delete left files")
        ok("delete confirm")

        # The mlx backend must not send err.conf's fm model_id ("system") to the
        # server: mlx-vlm would try to load an HF repo called "system".
        saved_env = {k: os.environ.get(k) for k in ("ERR_STATE_DIR", "ERR_MLX_MODEL")}
        os.environ["ERR_STATE_DIR"] = tempfile.mkdtemp(prefix="err-state-", dir=tmp)
        os.environ.pop("ERR_MLX_MODEL", None)
        try:
            check(errmod.mlx_model_id() == "", "unknown mlx model should be empty")
            with open(os.path.join(errmod.state_dir(), "last-model"), "w") as f:
                f.write("mlx-community/Some-Model\n")
            check(errmod.mlx_model_id() == "mlx-community/Some-Model",
                  "mlx_model_id did not read last-model")
            with open(os.path.join(errmod.state_dir(), "last-model"), "w") as f:
                f.write("apple-fm\n")
            check(errmod.mlx_model_id() == "",
                  "mlx_model_id returned the Apple sentinel")
            os.environ["ERR_MLX_MODEL"] = "explicit/model"
            check(errmod.mlx_model_id() == "explicit/model",
                  "ERR_MLX_MODEL did not win")
        finally:
            os.environ.pop("ERR_MLX_MODEL", None)
            for k, v in saved_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        ok("mlx model id resolution")

        # Autostart: `err "<question>"` brings the server up itself, but must
        # never spawn a launch when the user turned it off (scripts, CI, a
        # machine where loading 6 GB of weights is not wanted).
        saved_env = {k: os.environ.get(k) for k in
                     ("ERR_STATE_DIR", "ERR_MLX_MODEL", "ERR_BASE_URL",
                      "ERR_MLX_AUTOSTART", "ERR_BACKEND")}
        os.environ["ERR_STATE_DIR"] = tempfile.mkdtemp(prefix="err-state-", dir=tmp)
        os.environ["ERR_MLX_MODEL"] = "mock/model"
        os.environ["ERR_BASE_URL"] = "http://127.0.0.1:9"   # nothing listens
        # Without this the call takes the fm branch, starts the real fm server
        # and returns instead of raising — the assertion below then lies.
        os.environ["ERR_BACKEND"] = "mlx"
        try:
            for value in ("off", "0", "false", "no"):
                os.environ["ERR_MLX_AUTOSTART"] = value
                check(not errmod.autostart_enabled(),
                      f"ERR_MLX_AUTOSTART={value} should disable autostart")
            os.environ["ERR_MLX_AUTOSTART"] = "on"
            check(errmod.autostart_enabled(), "ERR_MLX_AUTOSTART=on should enable it")
            os.environ.pop("ERR_MLX_AUTOSTART")
            check(errmod.autostart_enabled(), "autostart should default to on")

            # With autostart off and no server, the old instruction is printed
            # and err exits 1 instead of hanging or launching.
            os.environ["ERR_MLX_AUTOSTART"] = "off"
            import io
            import contextlib
            err_out = io.StringIO()
            raised = 0
            with contextlib.redirect_stderr(err_out):
                try:
                    errmod.prepare_backend()
                except SystemExit as exc:
                    raised = exc.code
            check(raised == 1, f"prepare_backend should exit 1, got {raised!r}")
            check("not reachable" in err_out.getvalue(),
                  "missing the not-reachable message: " + err_out.getvalue())
        finally:
            for k, v in saved_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        ok("mlx autostart opt-out")

        print(f"\nALL {len(passed)} TESTS PASSED")
        return 0
    except AssertionError as exc:
        print(f"\nFAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
