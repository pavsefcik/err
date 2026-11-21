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
import time
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
    turns_file = os.path.join(tmp, "turns")
    suggest_file = os.path.join(tmp, "suggest")
    session_id_file = os.path.join(tmp, "session_id")
    stderr_file = os.path.join(tmp, "stderr")
    stdout_file = os.path.join(tmp, "stdout")

    base_env = {
        "ERR_STATE_DIR": tmp,
        "ERR_BACKEND": "mlx",
        "ERR_BASE_URL": base_url,
        # The mock stands in for the :11500 server; mlx-vlm would otherwise be
        # asked to load err.conf's fm model_id ("system").
        "ERR_MLX_MODEL": "mock/model",
        "_ERR_SESSION_ID": sid,
        "_ERR_TOKENS_FILE": tokens_file,
        "_ERR_TURNS_FILE": turns_file,
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
        check(errmod.tail_output("a\nb\nc", 2) == "b\nc", "tail_output line bound")
        check(errmod.tail_output("q", 10, 1).endswith("q"), "tail_output char bound")
        check(errmod.build_ask_user("q") == "q", "a question with no command must stay bare")
        check(
            errmod.first_fenced_line("Try:\n```bash\nls -la\n```\n") == "ls -la",
            "first fenced line extraction",
        )
        ok("redact + fenced extraction")

        # ── unit: readiness + error bodies ────────────────────────────
        code, msg = errmod.http_error_detail(
            '{"detail":{"code":"model_loading","message":"Startup preloading is in progress"}}'
        )
        check(code == "model_loading", "model_loading code not parsed")
        check(msg == "Startup preloading is in progress", "error message not unwrapped")
        check(errmod.http_error_detail("plain text") == ("", "plain text"),
              "non-JSON error body not passed through")
        # No /health on the mock: readiness must fall back to /v1/models.
        check(errmod.mlx_ready(base_url) is True,
              "mlx_ready must accept a server without /health")
        state.model_ready = False
        check(errmod.mlx_ready(base_url) is False,
              "mlx_ready ignored /health's model_ready=false")
        state.model_ready = True
        check(errmod.mlx_ready(base_url) is True,
              "mlx_ready ignored /health's model_ready=true")
        state.model_ready = None
        ok("readiness + error body parsing")

        # A server that answers /v1/models while still preloading rejects the
        # first chat with 503 model_loading. That is a wait, not a failure.
        state.reply = "A glob matches filenames."
        state.loading_attempts = 1
        proc = run(["--ask", "what is a glob"],
                   {"_ERR_SESSION_ID": str(uuid.uuid4())})
        check(proc.returncode == 0, f"503 model_loading not retried: {proc.stderr}")
        check("A glob matches filenames." in proc.stdout,
              "answer missing after the loading retry")
        check("starting mock/model on " in proc.stderr,
              "the loading wait was not announced")
        check("ready mock/model on " in proc.stderr,
              "the loading wait did not settle on a ready line")
        check(proc.stdout.startswith("arr // "),
              "the answer is not introduced by the arr // prefix")
        check("\033" not in proc.stdout,
              "the answer prefix leaked colour into a pipe")
        ok("503 model_loading is waited out")

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
        # The prompt in force comes from one definition (err.py); err.conf may
        # override it but must not duplicate it, or the copies drift apart.
        check(
            messages[0]["content"] == errmod.DEFAULT_SYSTEM_PROMPT,
            "explain did not send the built-in system prompt",
        )
        check(
            "code block" in errmod.DEFAULT_SYSTEM_PROMPT.lower(),
            "the explain prompt must refuse a code block: its first fenced "
            "line would be fed to the suggestion channel",
        )
        check(
            "never see the terminal" in errmod.DEFAULT_SYSTEM_PROMPT,
            "the explain prompt must not claim to see terminal output",
        )
        check(
            "not the terminal" in errmod.DEFAULT_QUESTION_PROMPT
            and "piped into err" in errmod.DEFAULT_QUESTION_PROMPT,
            "the question prompt must say only piped output reaches err",
        )
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
            request["messages"][0]["content"] == errmod.DEFAULT_QUESTION_PROMPT,
            "ask did not send the built-in question prompt",
        )
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

        # ── captured output: what a command printed reaches the model ─
        # `ps aux | head | err why`: the launcher marks the stdin pipe and err
        # reads it. The exit code is unknown on purpose — a pipeline's status
        # is not the producer's.
        state.reply = "The load is high on three processes."
        proc = run([], {"_ERR_LAST_CMD": "ps aux | head",
                       "_ERR_LAST_EXIT": "-1",
                       "_ERR_STDIN_PIPED": "1"},
                   stdin="USER PID %CPU\npavel 44594 9.4\n")
        check(proc.returncode == 0, f"piped explain failed: {proc.stderr}")
        user = state.requests[-1]["messages"][-1]["content"]
        check("Output (last lines):" in user, "piped output not labelled in the prompt")
        check("pavel 44594 9.4" in user, "piped output did not reach the model")
        check("Exit code: unknown" in user, "a piped command claimed a known exit code")

        # `errc`'s capture file, bounded to the tail (the model gets the shape
        # of the output, not 200 lines of it).
        with open(stdout_file, "w") as f:
            f.write("\n".join("row %d" % i for i in range(200)) + "\n")
        proc = run([], {"_ERR_LAST_CMD": "errc ps aux", "_ERR_LAST_EXIT": "0",
                       "_ERR_STDOUT_FILE": stdout_file})
        user = state.requests[-1]["messages"][-1]["content"]
        check("row 199" in user, "captured stdout tail missing")
        check("row 159" not in user, "captured stdout not bounded to the tail")
        ok("captured output reaches the explain prompt")

        # ── question mode carries the last command as context ────────
        state.reply = "Looks like ten busy processes."
        proc = run(["--ask", "what is going on"],
                   {"_ERR_LAST_CMD": "ps aux | head", "_ERR_LAST_EXIT": "0",
                    "_ERR_LAST_FRESH": "1", "_ERR_STDOUT_FILE": stdout_file})
        check(proc.returncode == 0, f"context ask failed: {proc.stderr}")
        user = state.requests[-1]["messages"][-1]["content"]
        check("the command I just ran" in user, "question lost the last command context")
        check("Command: ps aux | head" in user, "question context missing the command")
        check("row 199" in user, "question context missing captured output")
        check("Question: what is going on" in user, "question text not last")

        # Stale context must not leak: once err has answered, the launcher
        # clears _ERR_LAST_FRESH and the next question is bare.
        proc = run(["--ask", "what is a glob"],
                   {"_ERR_LAST_CMD": "ps aux | head", "_ERR_STDOUT_FILE": stdout_file})
        check(state.requests[-1]["messages"][-1]["content"] == "what is a glob",
              "non-fresh command leaked into a later question")
        ok("question context is one turn only")

        # ── one prompt, one source: defaults live in err.py ──────────
        # err.conf carries no prompt text by default; `err doctor` asks err.py
        # what is in force. Overrides are read from either key, the new one
        # winning, and the merged text is what the launcher's doctor row shows.
        prompt_conf = os.path.join(tmp, "prompt.conf")
        with open(prompt_conf, "w") as f:
            f.write("model_id = system\n")

        def prompt(kind, conf=prompt_conf):
            proc = run(["--prompt", kind], {"ERR_CONF": conf})
            check(proc.returncode == 0, f"--prompt {kind} failed: {proc.stderr}")
            origin, _, text = proc.stdout.rstrip("\n").partition("\t")
            return origin, text

        origin, text = prompt("explain")
        check(origin == "builtin", f"empty conf should be builtin, got {origin!r}")
        check(text == errmod.DEFAULT_SYSTEM_PROMPT, "builtin explain text changed")
        origin, text = prompt("question")
        check(origin == "builtin", f"empty conf should be builtin, got {origin!r}")
        check(text == errmod.DEFAULT_QUESTION_PROMPT, "builtin question text changed")

        with open(prompt_conf, "w") as f:
            f.write("system_prompt = Legacy explain.\n")
        check(prompt("explain") == ("custom", "Legacy explain."),
              "the legacy system_prompt key is no longer read")

        with open(prompt_conf, "w") as f:
            f.write("system_prompt = Legacy explain.\n"
                    "explain_system_prompt = New explain.\n")
        check(prompt("explain") == ("custom", "New explain."),
              "explain_system_prompt must win over system_prompt")

        with open(prompt_conf, "w") as f:
            f.write("question_system_prompt = Answer in one word.\n")
        check(prompt("question") == ("custom", "Answer in one word."),
              "question_system_prompt override ignored")
        proc = run(["--prompt", "bogus"], {"ERR_CONF": prompt_conf})
        check(proc.returncode == 2, "--prompt bogus should exit 2")

        # The shipped err.conf must not restate the defaults: that was the
        # duplication that made drift invisible.
        shipped = read(os.path.join(REPO, "err.conf"))
        for word in ("You explain what a shell command did",
                     "You answer shell questions"):
            check(word not in shipped,
                  "err.conf duplicates a built-in prompt: " + word)
        ok("prompts come from one source, both keys honoured")

        # ── session round-trip persists and reloads turns ────────────
        sess = json.loads(read(session_file(sid)))
        check(len(sess["turns"]) >= 2, "session did not accumulate turns")
        check(sess["turns"][0]["q"].startswith("Command: ls -la"), "turn q lost")
        check(sess["turns"][0]["a"] == "It lists files.", "turn a lost")
        check(sess["turns"][1]["q"] == "how do I list files", "ask turn q lost")
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
        # A row is a command: `err resume 1  <age>  <tty>  <cwd>  <title>`.
        check(rows[0].strip().startswith("err resume 1 "),
              f"resume row malformed: {rows[0]!r}")
        check("resume 1" in proc.stdout and "ls -la" in proc.stdout,
              "resume row does not carry the session title")
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
        check(read(turns_file).strip() == "0", "new did not publish 0 turns")
        check(read(tokens_file).strip() == "0", "new did not publish 0 tokens")
        check("new session" in proc.stdout, "new did not confirm the reset")
        with open(session_file(new_id)) as f:
            fresh = json.load(f)
        check(fresh.get("turns") == [], "new session started with turns")
        # And it must really be empty on the next ask: no history from `sid`.
        state.reply = "Fresh start."
        proc = run(["--ask", "anything"], {"_ERR_SESSION_ID": new_id})
        check(proc.returncode == 0, f"ask after new failed: {proc.stderr}")
        msgs = state.requests[-1].get("messages", [])
        check([m.get("role") for m in msgs] == ["system", "user"],
              f"ask after new carried history: {msgs}")
        check(read(turns_file).strip() == "1", "ask did not publish 1 turn")
        check(read(tokens_file).strip() != "0", "ask did not publish its tokens")
        ok("new writes _ERR_SESSION_ID_FILE")

        # `err stop` calls this: mint a session silently and reset both files.
        reset_file = os.path.join(tmp, "reset_session_id")
        proc = run(["--reset-session"], {"_ERR_SESSION_ID_FILE": reset_file})
        check(proc.returncode == 0, f"--reset-session failed: {proc.stderr}")
        check(proc.stdout == "", f"--reset-session was not silent: {proc.stdout!r}")
        reset_id = read(reset_file).strip()
        uuid.UUID(reset_id)
        check(read(turns_file).strip() == "0", "reset did not clear the turn count")
        check(read(tokens_file).strip() == "0", "reset did not clear the token count")
        ok("--reset-session clears the counters silently")

        # ── delete declines cleanly, then removes on confirmation ────
        proc = run(["delete"], stdin="n\n")
        check(proc.returncode == 0, f"delete decline failed: {proc.stderr}")
        check("Cancelled" in proc.stdout, "delete decline message missing")
        check(os.path.isfile(session_file(sid)), "declined delete removed files")
        proc = run(["delete"], stdin="y\n")
        check(proc.returncode == 0, f"delete failed: {proc.stderr}")
        check(not os.path.isfile(session_file(sid)), "confirmed delete left files")
        ok("delete confirm")

        # Alias expansion: a pre-seeded cache must be used without rebuilding
        # (with backend=mlx it used to never be built, so aliases were explained
        # as unrelated commands).
        cache = errmod.shell_config_cache_path()
        with open(cache, "w") as f:
            json.dump({"aliases": {"ports": "lsof -i -P -n | grep LISTEN"},
                       "functions": {"lk": "uv run lk $@"}}, f)
        check(errmod.shell_defn("ports -i") == "alias: lsof -i -P -n | grep LISTEN",
              "alias expansion from the cache")
        check(errmod.shell_defn("lk foo").startswith("function:"),
              "function expansion from the cache")
        ok("shell alias/function expansion")

        # Explain turns persist the command line as the session title; it must
        # be redacted like everything else (the title is what `err resume` shows).
        secret = "export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        proc = run([], extra={"_ERR_LAST_CMD": secret, "_ERR_LAST_EXIT": "0"})
        check(proc.returncode == 0, f"explain with a secret failed: {proc.stderr}")
        with open(session_file(sid)) as f:
            data = json.load(f)
        check("ghp_" not in data.get("title", ""), "session title leaked a secret")
        check("ghp_" not in json.dumps(data), "session file leaked a secret")
        ok("explain title is redacted")

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
            for sentinel in ("apple-fm", "system", "pcc"):
                with open(os.path.join(errmod.state_dir(), "last-model"), "w") as f:
                    f.write(sentinel + "\n")
                check(errmod.mlx_model_id() == "",
                      "mlx_model_id returned the fm sentinel %r" % sentinel)
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

        # ── idle watchdog: every server err starts gets shut down ────
        # A server nothing ever touches must die after idle_timeout_minutes;
        # one whose heartbeat keeps being stamped must not. ERR_WATCHDOG_POLL
        # keeps this to a few seconds instead of the production 20 s tick.
        wd = tempfile.mkdtemp(prefix="err-watchdog-", dir=tmp)
        wd_conf = os.path.join(wd, "err.conf")
        with open(wd_conf, "w") as f:
            f.write("idle_timeout_minutes = 0.05\n")
        wd_env = dict(os.environ)
        wd_env.update({
            "ERR_CONF": wd_conf,
            "ERR_STATE_DIR": wd,
            "ERR_WATCHDOG_POLL": "0.2",
        })

        def arm(pid, port=None):
            args = [sys.executable, ERR_PY, "--watchdog", str(pid)]
            if port is not None:
                args.append(str(port))
            return subprocess.run(
                args, cwd=REPO, env=wd_env, capture_output=True, text=True,
                timeout=30,
            )

        idle = subprocess.Popen(["/bin/sleep", "120"])
        try:
            check(arm(idle.pid).returncode == 0, "arming the watchdog failed")
            for _ in range(60):
                if idle.poll() is not None:
                    break
                time.sleep(0.25)
            check(idle.poll() is not None,
                  "an idle server survived past idle_timeout_minutes")
        finally:
            if idle.poll() is None:
                idle.kill()
            idle.wait()

        busy = subprocess.Popen(["/bin/sleep", "120"])
        try:
            check(arm(busy.pid).returncode == 0, "arming the watchdog failed")
            hb = os.path.join(wd, "fm_heartbeat")
            for _ in range(24):              # ~6 s = 3x the idle timeout
                with open(hb, "w") as f:
                    f.write("1")
                if busy.poll() is not None:
                    break
                time.sleep(0.25)
            check(busy.poll() is None,
                  "a busy server (fresh heartbeat) was killed")
        finally:
            if busy.poll() is None:
                busy.kill()
            busy.wait()
        ok("idle watchdog reaps idle servers, spares busy ones")

        # A client err knows nothing about (curl, pi, another app) stamps no
        # heartbeat and may not hold a connection open, so CPU is the last
        # safety net: a server that generates tokens burns some.
        worker = subprocess.Popen(
            [sys.executable, "-c", "while True: pass"])
        try:
            check(arm(worker.pid, 11599).returncode == 0,
                  "arming a port watchdog failed")
            time.sleep(3.5)                    # > 3x the idle timeout
            check(worker.poll() is None,
                  "a CPU-busy server (no heartbeat, no connection) was killed")
        finally:
            if worker.poll() is None:
                worker.kill()
            worker.wait()
        ok("idle watchdog spares a server that is burning CPU")

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
