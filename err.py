#!/usr/bin/env python3
"""err 0.601 — explain, ask and session engine for the err launcher.

Stdlib-only, single file, python3.9 compatible.
"""

import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ── config ──────────────────────────────────────────────────────────


def conf_path() -> str:
    """The one config file: $ERR_CONF, else the live copy in state, else the
    repo template. The engine seeds and reads the same file."""
    explicit = os.environ.get("ERR_CONF")
    if explicit:
        return explicit
    state = os.path.abspath(os.path.expanduser(
        os.environ.get("ERR_STATE_DIR") or "~/.cache/err"))
    live = os.path.join(state, "err.conf")
    return live if os.path.isfile(live) else os.path.join(SCRIPT_DIR, "err.conf")


def load_config() -> dict:
    cfg = {}
    conf_path_ = conf_path()
    if not os.path.isfile(conf_path_):
        print(f"err: config not found: {conf_path_}", file=sys.stderr)
        sys.exit(1)
    with open(conf_path_) as f:
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
# Everything err writes lives under one root and one uid: a fixed
# /tmp/err_shellconfig is world-readable and lets another user pre-create it.
_STATE = None


def _state_root() -> str:
    global _STATE
    if _STATE is None:
        _STATE = os.path.abspath(os.path.expanduser(
            os.environ.get("ERR_STATE_DIR") or "~/.cache/err"))
        os.makedirs(_STATE, exist_ok=True)
    return _STATE


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name) or default)
    except (TypeError, ValueError):
        return float(default)


# How often the idle watchdog wakes up, and how much CPU a server must have
# burned between two polls to count as "busy". ERR_WATCHDOG_POLL exists for the
# tests, which cannot wait 20 seconds per tick.
WATCHDOG_POLL = max(0.05, _env_float("ERR_WATCHDOG_POLL", 20))
WATCHDOG_CPU_DELTA = 0.25


def heartbeat_file(port=None) -> str:
    """Activity stamp for one server.

    fm keeps its historical unattributed `fm_heartbeat`; every MLX server gets
    its own per-port stamp, so a chat on :11501 never keeps the model on :11500
    alive (and vice versa).
    """
    if port is None:
        return os.path.join(_state_root(), "fm_heartbeat")
    return os.path.join(_state_root(), "mlx_heartbeat-%s" % port)


def fm_log_path() -> str:
    path = os.path.join(_state_root(), "logs")
    os.makedirs(path, exist_ok=True)
    return os.path.join(path, "fm.log")


def shell_config_cache_path() -> str:
    return os.path.join(_state_root(), "shellconfig.json")
SHELL_CONFIG_MARKER = "@@FUNCTIONS@@"
FUNC_BODY_LIMIT = 300

SESSION_MAX_AGE = 7 * 24 * 60 * 60
SESSION_MAX_COUNT = 50
SUGGEST_BYTE_LIMIT = 400

# ── help ────────────────────────────────────────────────────────────


# ── fm server management ────────────────────────────────────────


def health_ok(base_url: str = MLX_HOST) -> bool:
    try:
        req = urllib.request.Request(f"{base_url}/v1/models", method="GET")
        with urllib.request.urlopen(req, timeout=2) as resp:
            return resp.status == 200
    except Exception:
        return False


SPINNER_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
SPINNER_COLORS = (45, 51, 87, 123, 129, 165, 201, 207, 214, 220)


class Spinner:
    """One-line progress that animates only on a terminal.

    Piped output (`err hi | pbcopy`, tests, CI) gets the message once and a
    plain final line instead of carriage returns, so capture stays readable.
    """

    def __init__(self, message, stream=None):
        self.message = message
        self.stream = stream if stream is not None else sys.stderr
        try:
            self.tty = bool(self.stream.isatty())
        except Exception:
            self.tty = False
        self.frame = 0
        self.active = False

    def announce(self):
        if self.tty:
            self.tick()
        else:
            print(self.message, file=self.stream)

    def tick(self):
        if not self.tty:
            return
        idx = self.frame % len(SPINNER_FRAMES)
        frame = SPINNER_FRAMES[idx]
        color = SPINNER_COLORS[idx % len(SPINNER_COLORS)]
        self.stream.write("\r\033[K\033[38;5;%dm%s\033[0m %s" % (color, frame, self.message))
        self.stream.flush()
        self.frame += 1
        self.active = True

    def stop(self, final=None):
        if self.tty and self.active:
            self.stream.write("\r\033[K")
            self.stream.flush()
            self.active = False
        if final:
            self.stream.write(final + "\n")
            self.stream.flush()


# The model's voice. `arr //` is err's own separator (the help screen and the
# version line carry it too), and the colour is the one accent nothing else
# claims: menu chrome is 1;35 magenta, the prompts are 1;36 cyan, 212 pink is
# the catalog headers and launch status. Amber keeps the answer out of all
# three lanes while staying warm enough to read as "this is the reply".
# Escapes are emitted only for a terminal: `err "<q>" | pbcopy`, CI and the
# tests get plain text.
ANSWER_PREFIX = "arr // "
_ANSWER_ACCENT = "\033[1;38;5;214m"
_RESET = "\033[0m"


def answer_prefix() -> str:
    """The `arr // ` introducer, coloured only when stdout is a terminal."""
    if os.environ.get("NO_COLOR") or not sys.stdout.isatty():
        return ANSWER_PREFIX
    return _ANSWER_ACCENT + ANSWER_PREFIX.rstrip() + _RESET + " "


def mlx_ready(base_url: str) -> bool:
    """True once the server can answer a chat request, not merely listen.

    mlx-vlm serves /v1/models while its startup preload is still running and
    rejects the first chat request with 503 `model_loading`. /health exposes
    the real state; a server without /health (fm, another OpenAI server)
    falls back to plain liveness so this never becomes a false negative.
    """
    try:
        req = urllib.request.Request(f"{base_url}/health", method="GET")
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="replace"))
    except Exception:
        return health_ok(base_url)
    if isinstance(data, dict) and "model_ready" in data:
        return bool(data.get("model_ready"))
    return True


def wait_mlx_ready(base_url: str, model: str, timeout: float = 900.0) -> bool:
    """Wait out mlx-vlm's startup preload instead of failing on it."""
    if mlx_ready(base_url):
        return True
    spinner = Spinner("starting %s on %s" % (model, base_url))
    spinner.announce()
    deadline = time.time() + timeout
    while time.time() < deadline:
        spinner.tick()
        time.sleep(0.5)
        if mlx_ready(base_url):
            spinner.stop("ready %s on %s" % (model, base_url))
            return True
    spinner.stop()
    return False


def touch_heartbeat(port=None) -> None:
    try:
        with open(heartbeat_file(port), "w") as f:
            f.write(str(time.time()))
    except OSError:
        pass


def touch_heartbeat_if_armed(port) -> None:
    """Stamp a port's heartbeat only if a model err started lives there.

    err talks to servers it did not start too (a remote base URL, someone
    else's server); it must not leave heartbeat files for those.
    """
    if port is not None and os.path.isfile(heartbeat_file(port)):
        touch_heartbeat(port)


def url_port(url: str, default: int = 11500):
    """Port of an OpenAI base URL, as an int, or `default`."""
    try:
        port = urllib.parse.urlsplit(url).port
    except ValueError:
        port = None
    return port if port else default


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _cpu_seconds(pid: int):
    """Cumulative CPU time of `pid` in seconds, or None.

    os.times() is process-wide, not per pid, so `ps -o time=` is the only
    stdlib-reachable source. Generations and model loads always burn CPU; a
    server sitting on a loaded model does not.
    """
    try:
        out = subprocess.check_output(
            ["/bin/ps", "-o", "time=", "-p", str(pid)],
            stderr=subprocess.DEVNULL,
        ).decode("ascii", "replace").strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    if not out:
        return None
    days = 0
    if "-" in out:
        head, _, out = out.partition("-")
        try:
            days = int(head)
        except ValueError:
            return None
    total = float(days) * 86400.0
    try:
        for part in out.split(":"):
            total = total * 60.0 + float(part)
    except ValueError:
        return None
    return total


def _port_busy(port: int) -> bool:
    """True while any client still holds a connection to `port`."""
    try:
        out = subprocess.check_output(
            ["lsof", "-nP", "-iTCP:%d" % port, "-sTCP:ESTABLISHED", "-t"],
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    return bool(out.strip())


def _cpu_delta_threshold() -> float:
    """CPU seconds between two polls that count as work.

    Scaled to the poll interval: with the production 20 s tick a busy server
    burns far more than 0.25 s, while a lowered poll (tests) would otherwise
    never reach an absolute threshold and reap a working server.
    """
    return max(0.01, min(WATCHDOG_CPU_DELTA, WATCHDOG_POLL * 0.25))


def watchdog_loop(pid: int, port=None) -> None:
    """SIGTERM `pid` after IDLE_TIMEOUT_MIN minutes without activity.

    A server is idle when no client stamped its heartbeat, no connection is
    established on its port, and it burned no CPU since the last poll. CPU is
    what catches clients that stamp nothing (curl, pi, another app): a server
    generating tokens always burns some.
    """
    hb = heartbeat_file(port)
    timeout = max(0.02, IDLE_TIMEOUT_MIN) * 60.0
    cpu_delta = _cpu_delta_threshold()
    cpu_prev = _cpu_seconds(pid)
    last = time.time()          # grace: never reap right after arming
    while True:
        time.sleep(WATCHDOG_POLL)
        if not _pid_alive(pid):
            return
        now = time.time()
        try:
            last = max(last, os.path.getmtime(hb))
        except OSError:
            pass
        if port is not None:
            cpu = _cpu_seconds(pid)
            if cpu is not None and cpu_prev is not None \
                    and cpu - cpu_prev >= cpu_delta:
                last = now
            cpu_prev = cpu
            if _port_busy(port):
                last = now
        if now - last >= timeout:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
            return


def spawn_idle_watchdog(server_pid: int, port=None) -> None:
    """Arm a detached idle watchdog for a server err started.

    Both start paths call this: err.py's own `ensure_running` (fm) and the
    engine's `_err_headless_launch` (the MLX model on :11500).
    """
    cmd = [sys.executable, os.path.abspath(__file__), "--watchdog-run",
           str(server_pid)]
    if port is not None:
        cmd.append(str(port))
    subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def ensure_running() -> bool:
    if health_ok():
        touch_heartbeat()
        if not os.path.isfile(shell_config_cache_path()):
            build_shell_config_cache()
        return True

    spinner = Spinner("starting apple-fm on %s" % MLX_HOST)
    spinner.announce()
    log_path = fm_log_path()
    log = open(log_path, "w")

    cmd = [
        "fm", "serve",
        "--host", "127.0.0.1",
        "--port", PORT,
    ]

    proc = subprocess.Popen(cmd, stdout=log, stderr=log, start_new_session=True)

    for _ in range(120):
        spinner.tick()
        time.sleep(0.5)
        if health_ok():
            spinner.stop("ready apple-fm on %s" % MLX_HOST)
            touch_heartbeat()
            build_shell_config_cache()
            spawn_idle_watchdog(proc.pid)
            return True

    spinner.stop()
    print(f"err: fm server failed to start. Check {log_path}", file=sys.stderr)
    return False


# ── backend selection ──────────────────────────────────────────────


def backend_name() -> str:
    return (os.environ.get("ERR_BACKEND") or CFG.get("backend", "fm")).strip().lower()


def mlx_base_url() -> str:
    url = os.environ.get("ERR_BASE_URL") or CFG.get("mlx_base_url", "http://127.0.0.1:11500")
    return url.strip().rstrip("/")


FM_MODEL_IDS = ("apple-fm", "system", "pcc")


def _cfg_int(key: str, default: int) -> int:
    try:
        return int(str(CFG.get(key, default)).strip())
    except (TypeError, ValueError):
        return default


def _cfg_float(key: str, default: float) -> float:
    try:
        return float(str(CFG.get(key, default)).strip())
    except (TypeError, ValueError):
        return default


def mlx_model_id() -> str:
    """The model id the :11500 server is serving.

    err.conf's `model_id` (`system` / `pcc`) belongs to the fm backend. Sending
    it to the MLX server makes mlx-vlm try to load a HuggingFace repo called
    "system" and fail with Repository Not Found. The model manager records what
    it started in `last-model` (and what you chose in `default-model`).
    """
    explicit = (os.environ.get("ERR_MLX_MODEL") or CFG.get("mlx_model") or "").strip()
    if explicit:
        return explicit
    for name in ("last-model", "default-model"):
        try:
            with open(os.path.join(state_dir(), name)) as f:
                model = f.readline().strip()
        except OSError:
            continue
        if model and model not in FM_MODEL_IDS:
            return model
    return ""


def autostart_enabled() -> bool:
    v = (os.environ.get("ERR_MLX_AUTOSTART") or CFG.get("mlx_autostart", "on"))
    return v.strip().lower() not in ("0", "off", "false", "no")


def autostart_mlx(base: str, model: str) -> bool:
    """Bring :11500 up by asking the engine, so a question never needs `err run`.

    Launching lives in err-models.zsh (weights, flags, APC, MoE); err.py only
    asks for it. The engine stops whatever else is on :11500 first, and waits
    for the weights — which is why there is no timeout here.
    """
    engine = os.path.join(SCRIPT_DIR, "err-models.zsh")
    if not os.path.isfile(engine):
        print(f"err: engine missing: {engine} — re-run install.sh", file=sys.stderr)
        return False
    # The engine prints the one startup line ("Starting <model> on <url>");
    # repeating it here made every autostart read as two different events.
    # Data on stdout is err's contract: the engine's chatter goes to stderr.
    # A real stderr fd keeps it live during a multi-minute load; without one
    # (embedded callers) drop it rather than crashing.
    chatter = sys.stderr
    try:
        chatter.fileno()
    except Exception:
        chatter = subprocess.DEVNULL
    try:
        rc = subprocess.call(
            ["zsh", engine, "ensure", model],
            stdout=chatter,
            stderr=chatter,
        )
    except OSError as exc:
        print(f"err: could not run the engine: {exc}", file=sys.stderr)
        return False
    if rc != 0:
        print(f"err: starting {model} failed (exit {rc})", file=sys.stderr)
        return False
    return mlx_ready(base)


def prepare_backend() -> tuple:
    """Return (base_url, model_id) for the configured backend."""
    backend = backend_name()
    if backend == "mlx":
        base = mlx_base_url()
        model = mlx_model_id()
        if not model:
            print(
                "err: no MLX model selected — run: err run <model>",
                file=sys.stderr,
            )
            sys.exit(1)
        # Never start fm for the mlx backend. When :11500 is down, start the
        # chosen model instead of telling the user to run `err run` first; the
        # engine swaps out a different model if one is already serving.
        if not health_ok(base):
            if not (autostart_enabled() and autostart_mlx(base, model)):
                print(
                    f"err: mlx server not reachable at {base} — start it with: err run {model}",
                    file=sys.stderr,
                )
                sys.exit(1)
            model = mlx_model_id() or model
        # /v1/models answers throughout mlx-vlm's startup preload, so a server
        # that looks up can still 503 the first request. Wait for the real
        # readiness signal rather than making the user re-run the question.
        if not wait_mlx_ready(base, model):
            print(
                f"err: {model} never became ready on {base} — see the log in {os.path.join(_state_root(), 'logs')}",
                file=sys.stderr,
            )
            sys.exit(1)
        touch_heartbeat_if_armed(url_port(base))
        return base, model

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
        with open(shell_config_cache_path(), "w") as f:
            json.dump({"aliases": aliases, "functions": functions}, f)
    except OSError:
        pass


def load_shell_config() -> dict:
    try:
        with open(shell_config_cache_path()) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


SHELL_CONFIG_TTL = 3600  # seconds; also rebuilt when ~/.zshrc is newer


def ensure_shell_config_cache() -> None:
    """Make sure the alias/function dump exists and is not stale.

    It used to be built only when err started the fm server, so with
    `backend = mlx` it was never built at all and err explained the user's
    aliases as if they were unrelated commands (`ports` -> "MacPorts").
    """
    path = shell_config_cache_path()
    try:
        built_at = os.path.getmtime(path)
    except OSError:
        built_at = 0.0
    newest_rc = 0.0
    for rc in ("~/.zshrc", "~/.zshenv", "~/.zprofile", "~/.bashrc", "~/.bash_profile"):
        try:
            newest_rc = max(newest_rc, os.path.getmtime(os.path.expanduser(rc)))
        except OSError:
            pass
    fresh = built_at > 0         and (time.time() - built_at) < SHELL_CONFIG_TTL         and built_at >= newest_rc
    if not fresh:
        build_shell_config_cache()


def shell_defn(cmd: str) -> str:
    first = cmd.split()[0] if cmd.split() else cmd
    ensure_shell_config_cache()
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
        os.path.expanduser(os.environ.get("ERR_STATE_DIR") or "~/.cache/err")
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


def write_counter_file(env_name: str, total: int) -> None:
    path = os.environ.get(env_name)
    if not path:
        return
    try:
        with open(path, "w") as f:
            f.write(f"{total}\n")
    except OSError:
        pass


def write_tokens_file(total: int) -> None:
    write_counter_file("_ERR_TOKENS_FILE", total)


def write_turns_file(total: int) -> None:
    write_counter_file("_ERR_TURNS_FILE", total)


def publish_session_state(sess: dict) -> None:
    """Mirror the current conversation's counters to the shell's files.

    The launcher cannot see a session dict, so the RPROMPT counter is driven by
    these two files. `new` / `clear` must publish 0/0 and `resume` must publish
    the resumed session's own totals — otherwise the prompt keeps showing the
    session err just left.
    """
    write_tokens_file(_safe_int(sess.get("tokens", 0)))
    write_turns_file(len(sess.get("turns") or []))


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
        # `title` is caller-supplied from the RAW command/question (see the
        # callers), so it must go through the same redaction as the turn.
        sess["title"] = redact(title or _session_title(user_content, c))[:60]
    sess["turns"].append({"q": q, "a": a, "cmd": c, "exit": exit_code, "tokens": tokens})
    sess["tokens"] = _safe_int(sess.get("tokens", 0)) + tokens
    sess["last_used"] = int(time.time())
    save_session(sess)
    publish_session_state(sess)


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
    return (os.environ.get("ERR_SUGGEST") or CFG.get("suggest", "history")).strip().lower()


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


def http_error_detail(body: str) -> tuple:
    """(code, message) from an OpenAI/FastAPI error body.

    mlx-vlm answers 503 with {"detail": {"code": "model_loading", …}} while
    FastAPI 4xx bodies put the message in "detail"; OpenAI-shaped servers use
    {"error": {…}}. One parser keeps the printed error a sentence.
    """
    try:
        parsed = json.loads(body)
    except (ValueError, TypeError):
        return "", body
    detail = parsed.get("error", parsed.get("detail", parsed))
    if isinstance(detail, dict):
        return str(detail.get("code", "")), str(detail.get("message") or detail)
    return "", str(detail)


# How long a chat request keeps retrying while the model is still preloading.
MODEL_LOAD_RETRY_SECONDS = 600


def stream_chat(messages: list, base_url: str, model_id: str) -> tuple:
    """Stream one chat completion. Returns (text, tokens); text is None on failure."""
    payload = json.dumps(
        {
            "model": model_id,
            "max_tokens": _cfg_int("max_tokens", 200),
            "temperature": _cfg_float("temperature", 0.3),
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
    loading_until = None
    spinner = None
    # A request in flight is activity: it keeps the idle watchdog off the
    # server that is answering this very question.
    touch_heartbeat_if_armed(url_port(base_url))
    while True:
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                started = True
                if spinner is not None:
                    # The retry spinner owned the current line; hand it back.
                    spinner.stop("ready %s on %s" % (model_id, base_url))
                    spinner = None
                print(answer_prefix(), end="", flush=True)
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
                print("\r\033[K" + answer_prefix() + cleaned, end="")
            print()
            tokens = usage_total if usage_total is not None else len(cleaned) // 4
            return cleaned, tokens
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            code, err_msg = http_error_detail(body)
            # A model that is still preloading is not a failure: wait it out.
            if e.code == 503 and code == "model_loading":
                if loading_until is None:
                    loading_until = time.time() + MODEL_LOAD_RETRY_SECONDS
                    spinner = Spinner("starting %s on %s" % (model_id, base_url))
                    spinner.announce()
                if time.time() < loading_until:
                    spinner.tick()
                    time.sleep(0.5)
                    continue
                spinner.stop()
            nl = "\n" if started else ""
            print(f"{nl}err: server error ({e.code}): {err_msg}", file=sys.stderr)
            return None, None
        except urllib.error.URLError as e:
            nl = "\n" if started else ""
            print(f"{nl}err: connection failed: {e.reason}", file=sys.stderr)
            return None, None


# ── command explanation ───────────────────────────────────────────

# One prompt, one source: these are the defaults, err.conf only overrides them.
# The explain prompt must not ask for a code block — err feeds the first fenced
# line to the suggestion channel, and `err what` must not put a command in your
# history behind your back. The question prompt *is* that contract, on purpose.
DEFAULT_SYSTEM_PROMPT = (
    "You explain what a shell command did on macOS zsh. Answer in one short "
    "sentence. If the command is an alias, say which command the alias runs. "
    "Do not include a code block. You see the command, its exit code, and any "
    "output piped into err; you never see the terminal's own output."
)

DEFAULT_QUESTION_PROMPT = (
    "You answer shell questions for macOS zsh. Reply in at most three short "
    "sentences, then give one example command in a fenced code block. If the "
    "answer needs no command, skip the code block. You see the last command, "
    "its exit code, and any output piped into err — not the terminal's own "
    "output; if asked what you can see, say that and suggest `cmd | err wtf`."
)


def effective_prompt(kind: str) -> tuple:
    """(origin, text) of the system prompt in force for `kind`.

    origin is "custom" when err.conf overrides the built-in default, so
    `err doctor` can say which prompt is actually answering. The explain key
    was called `system_prompt` for a long time; the old name is still read, so
    an existing err.conf keeps working (and keeps being reported as custom).
    """
    if kind == "explain":
        for key in ("explain_system_prompt", "system_prompt"):
            if CFG.get(key):
                return "custom", CFG[key]
        return "builtin", DEFAULT_SYSTEM_PROMPT
    if kind == "question":
        if CFG.get("question_system_prompt"):
            return "custom", CFG["question_system_prompt"]
        return "builtin", DEFAULT_QUESTION_PROMPT
    raise ValueError("unknown prompt kind: %s" % kind)


# ── captured output ─────────────────────────────────────────────────
# The shell cannot capture stdout without turning fd 1 into a pipe (colours,
# pagers and full-screen programs all break), so err gets the last command's
# output from exactly two places: the capture file (_ERR_STDOUT_FILE) and,
# for `cmd | err wtf`, err's own stdin. Both are bounded here: the model
# needs the shape of the output, not a log dump.
OUTPUT_LINES = max(1, _cfg_int("output_lines", 40))
OUTPUT_CHARS = 3000
STDIN_MAX_BYTES = 65536


def _flag(name: str) -> bool:
    """Truthy env flag; "0"/"false"/"no"/"off" are false (ERR_DEBUG rule)."""
    value = (os.environ.get(name) or "").strip().lower()
    return value not in ("", "0", "false", "no", "off")


def tail_output(text: str, max_lines: int = OUTPUT_LINES,
                max_chars: int = OUTPUT_CHARS) -> str:
    """Last `max_lines` lines of `text`, capped at `max_chars`."""
    if not text:
        return ""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").splitlines()
    out = "\n".join(lines[-max_lines:]).strip()
    if len(out) > max_chars:
        out = "…" + out[-max_chars:]
    return out


def read_stdin_output() -> str:
    """Output piped into err (`ps aux | err wtf`).

    Only when the launcher says so (_ERR_STDIN_PIPED): reading fd 0 on a guess
    would steal the next line from a shell that is itself reading a script
    from stdin.
    """
    if not _flag("_ERR_STDIN_PIPED"):
        return ""
    try:
        return sys.stdin.buffer.read(STDIN_MAX_BYTES).decode("utf-8", "replace")
    except Exception:
        return ""


def read_capture_file(name: str) -> str:
    """The TAIL of a capture file.

    A capture file can hold everything a command printed, which for `find /` can be
    far more than a model should see. Read the last STDIN_MAX_BYTES so what
    survives the line bound below is the end of the output, not its start.
    """
    path = os.environ.get(name, "")
    if not path or not os.path.isfile(path):
        return ""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - STDIN_MAX_BYTES))
            return f.read(STDIN_MAX_BYTES).decode("utf-8", "replace")
    except OSError:
        return ""


def captured_output(stdin_text: str) -> str:
    """The last command's stdout: the pipe err was handed, else the capture file."""
    return stdin_text or read_capture_file("_ERR_STDOUT_FILE")


def build_explain_user(cmd: str, exit_code: int, stderr_content: str,
                       output_content: str = "") -> str:
    first = cmd.split()[0] if cmd.split() else cmd
    defn = shell_defn(cmd)
    output = tail_output(output_content)

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

    if output:
        lines.append("Output (last lines):")
        lines.append(output)

    if exit_code > 0:
        if stderr_content.strip():
            lines.append(f"Error output: {stderr_content.strip()[:300]}")
        else:
            lines.append("Error output: none")

    lines.append("")
    if exit_code == 0:
        instruction = CFG.get("prompt_success",
                              "Explain in one short sentence what running it did.")
        if output:
            instruction += (" Use the output above: say what it shows and whether"
                            " it looks normal.")
        lines.append(instruction)
    elif exit_code < 0:
        instruction = CFG.get("prompt_unknown", "")
        if output:
            instruction += (" Use the output above: say what it shows and"
                            " whether anything looks wrong.")
        lines.append(instruction)
    elif exit_code == 127:
        lines.append(CFG.get("prompt_not_found")
                     or CFG.get("prompt_fail")
                     or "In one or two short sentences, explain what went wrong.")
    else:
        lines.append(CFG.get("prompt_fail")
                     or "In one or two short sentences, explain what went wrong.")

    return "\n".join(lines)


def run_explain() -> None:
    cmd = os.environ.get("_ERR_LAST_CMD", "")
    exit_code_str = os.environ.get("_ERR_LAST_EXIT", "0")

    if not cmd:
        print("err: no command recorded yet.", file=sys.stderr)
        sys.exit(1)

    exit_code = int(exit_code_str)

    # Drain the pipe BEFORE prepare_backend can spawn anything: the engine it
    # may start inherits fd 0, and a prompt there would eat the output.
    stdin_output = read_stdin_output()

    if exit_code == 0:
        print(f"{cmd} (exit 0)")
    elif exit_code < 0:
        print(f"{cmd} (exit unknown)")
    else:
        print(f"{cmd} (exit {exit_code})")

    base_url, model_id = prepare_backend()

    stderr_content = ""
    stderr_file = os.environ.get("_ERR_STDERR_FILE", "")
    if exit_code > 0 and os.path.isfile(stderr_file) and os.path.getsize(stderr_file) > 0:
        with open(stderr_file) as f:
            stderr_content = f.read()

    sid = current_session_id()
    user_content = build_explain_user(cmd, exit_code, stderr_content,
                                      captured_output(stdin_output))
    system_prompt = effective_prompt("explain")[1]
    messages = conversation_messages(system_prompt, sid, user_content)

    clear_suggest_file()
    answer, tokens = stream_chat(messages, base_url, model_id)
    if answer is None:
        sys.exit(1)
    write_suggest_file(answer)
    record_turn(sid, user_content, answer, cmd, exit_code, tokens, title=cmd)


# ── freeform question ─────────────────────────────────────────────


def build_ask_user(question: str, cmd: str = "", exit_code: int = -1,
                   output_content: str = "") -> str:
    """The question, carrying the command just run as context when there is one.

    Without it a follow-up like "what is going on?" answers from nothing: the
    launcher exports the last command for exactly this reason.
    """
    if not cmd:
        return question
    lines = ["Context — the command I just ran:", "Command: " + cmd]
    if exit_code == 0:
        lines.append("Exit code: 0 (success)")
    elif exit_code > 0:
        lines.append(f"Exit code: {exit_code} (failure)")
    else:
        lines.append("Exit code: unknown")
    output = tail_output(output_content)
    if output:
        lines.append("Output (last lines):")
        lines.append(output)
    lines.append("")
    lines.append("Question: " + question)
    return "\n".join(lines)


def run_ask(question: str) -> None:
    stdin_output = read_stdin_output()
    base_url, model_id = prepare_backend()

    # Only a command that literally just ran is context; after an err call the
    # launcher clears the flag, so back-to-back questions don't re-attach it.
    cmd = os.environ.get("_ERR_LAST_CMD", "")
    fresh = _flag("_ERR_LAST_FRESH")
    exit_code = -1
    if fresh:
        exit_code = _safe_int(os.environ.get("_ERR_LAST_EXIT", "-1"), -1)
        if _flag("_ERR_STDIN_PIPED"):
            # A pipeline's status is not the producer's, and `ps aux | err wtf`
            # must not claim exit 0 for the command whose output it was handed.
            exit_code = -1
    output_content = captured_output(stdin_output) if (fresh or _flag("_ERR_STDIN_PIPED")) else ""
    user_content = build_ask_user(question, cmd if fresh else "", exit_code,
                                  output_content)

    sid = current_session_id()
    system_prompt = effective_prompt("question")[1]
    messages = conversation_messages(system_prompt, sid, user_content)

    clear_suggest_file()
    answer, tokens = stream_chat(messages, base_url, model_id)
    if answer is None:
        sys.exit(1)
    write_suggest_file(answer)
    suggested = first_fenced_line(answer) or ""
    record_turn(sid, user_content, answer, suggested, 0, tokens, title=question)


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


def cmd_new(quiet: bool = False) -> None:
    sid = str(uuid.uuid4())
    sess = default_session(sid)
    save_session(sess)
    publish_session_state(sess)
    emit_session_id(sid)
    # The launcher sets _ERR_SESSION_ID_FILE; without it this is the internal
    # "mint an id and print it" mode, whose stdout must stay a bare id.
    if os.environ.get("_ERR_SESSION_ID_FILE") and not quiet:
        print(answer_prefix() + "new session")


def cmd_clear() -> None:
    sid = current_session_id()
    sess = load_session(sid) or default_session(sid)
    sess["turns"] = []
    sess["title"] = ""
    sess["tokens"] = 0
    sess["last_used"] = int(time.time())
    save_session(sess)
    publish_session_state(sess)


def human_age(seconds: int) -> str:
    seconds = max(0, seconds)
    if seconds < 60:
        return "now"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"


def pick_row(rows: list) -> int:
    """Arrow-key picker with err's look; returns the index, or -1 to cancel.

    err's menus are drawn by the zsh engine, but sessions belong to err.py, so
    the same look is painted here: `arr //` on the cursor row, 7-column indent
    for the rest, a blank line, then the key hints. Anything without a terminal
    (a pipe, a script, EOF) returns -1 so the caller prints the list instead.
    """
    if not rows or not sys.stdin.isatty() or not sys.stderr.isatty():
        return -1
    try:
        import select
        import termios
        import tty
    except ImportError:
        return -1

    fd = sys.stdin.fileno()
    try:
        old = termios.tcgetattr(fd)
    except (termios.error, OSError):
        return -1
    try:
        size = os.get_terminal_size(fd)
        lines, columns = size.lines, size.columns
    except OSError:
        lines, columns = 24, 80
    if lines < 8:
        lines = 24
    if columns < 40:
        columns = 80

    footer = "←↓↑→ navigate • esc return • enter submit"
    vis = max(3, min(len(rows), lines - 4))
    cursor = 0
    scroll = 0
    drawn = 0
    nlines = 0
    err = sys.stderr

    def paint():
        nonlocal drawn, nlines
        out = []
        for index in range(scroll, min(scroll + vis, len(rows))):
            if index == cursor:
                out.append("\x1b[1;36marr // " + rows[index] + "\x1b[0m")
            else:
                out.append("       " + rows[index])
        out.append("")
        out.append("\x1b[2m" + footer[:max(0, columns - 1)] + "\x1b[0m")
        if drawn:
            err.write("\x1b[%dA\x1b[J" % nlines)
        err.write("\x1b[?25l")
        for line in out:
            err.write(line + "\x1b[K\n")
        nlines = len(out)
        drawn = 1
        err.flush()

    def clear():
        if drawn:
            err.write("\x1b[%dA\x1b[J" % nlines)
        err.write("\x1b[?25h")
        err.flush()

    def read_key():
        """One keypress; escape sequences come back whole: b'\\x1b[A' etc."""
        first = os.read(fd, 1)
        if first != b"\x1b":
            return first
        seq = b""
        while len(seq) < 5:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if not ready:
                break
            seq += os.read(fd, 1)
            if seq[-1:] in b"~ABCDHF":
                break
        return b"\x1b" + seq

    try:
        tty.setcbreak(fd)
        paint()
        while True:
            key = read_key()
            if key in (b"\r", b"\n"):
                return cursor
            if key in (b"k", b"K"):
                cursor = max(0, cursor - 1)
            elif key in (b"j", b"J"):
                cursor = min(len(rows) - 1, cursor + 1)
            elif key.startswith(b"\x1b"):
                tail = key[1:]
                if not tail:
                    return -1
                if tail in (b"[A", b"OA"):
                    cursor = max(0, cursor - 1)
                elif tail in (b"[B", b"OB"):
                    cursor = min(len(rows) - 1, cursor + 1)
                elif tail in (b"[H", b"[1~", b"OH"):
                    cursor = 0
                elif tail in (b"[F", b"[4~", b"OF"):
                    cursor = len(rows) - 1
                elif tail == b"[5~":
                    cursor = max(0, cursor - (vis - 1))
                elif tail == b"[6~":
                    cursor = min(len(rows) - 1, cursor + (vis - 1))
            if cursor < scroll:
                scroll = cursor
            elif cursor >= scroll + vis:
                scroll = cursor - vis + 1
            paint()
    finally:
        clear()
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def cmd_resume(args: list) -> None:
    sessions = load_all_sessions()
    sessions.sort(key=lambda s: _safe_int(s.get("last_used", 0)), reverse=True)

    if not args:
        if not sessions:
            print("No sessions.")
            return
        now = int(time.time())
        rows = []
        for index, sess in enumerate(sessions, 1):
            age = human_age(now - _safe_int(sess.get("last_used", 0)))
            tty = sess.get("tty") or "?"
            cwd = sess.get("cwd") or "?"
            title = (sess.get("title") or "").strip() or "(untitled)"
            # The row stays a command: `err resume 3` is what you would type,
            # the rest is the label that makes the number meaningful.
            rows.append(f"err resume {index}  {age:>4}  {tty}  {cwd}  {title}")
        picked = pick_row(rows)
        if picked < 0:
            # No terminal, or cancelled: the list itself is the answer.
            for row in rows:
                print(row)
            return
        args = [str(picked + 1)]

    if len(args) != 1 or not args[0].isdigit():
        print("usage: err resume [n]", file=sys.stderr)
        sys.exit(2)

    choice = int(args[0])
    if choice < 1 or choice > len(sessions):
        print(f"err: no session {choice}.", file=sys.stderr)
        sys.exit(1)

    sess = sessions[choice - 1]
    sid = sess.get("id")
    if not sid:
        print("err: session has no id.", file=sys.stderr)
        sys.exit(1)
    sess["last_used"] = int(time.time())
    save_session(sess)
    publish_session_state(sess)
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

    # Internal: arm / run the idle watchdog. `--watchdog <pid> [port]` arms a
    # detached one; `--watchdog-run` is that detached process itself. Called by
    # err.py itself (fm) and by the engine's `_err_headless_launch` (MLX),
    # so a model err started never outlives its usefulness.
    if args and args[0] in ("--watchdog", "--watchdog-run"):
        try:
            pid = int(args[1])
        except (IndexError, ValueError):
            return
        port = None
        if len(args) > 2:
            try:
                port = int(args[2])
            except ValueError:
                port = None
        if args[0] == "--watchdog-run":
            watchdog_loop(pid, port)
        else:
            spawn_idle_watchdog(pid, port)
        return

    if args and args[0] == "--prompt":
        # Internal: `origin<TAB>text` of the system prompt in force, so
        # `err doctor` can show what is actually answering instead of guessing
        # from err.conf (which may override nothing at all).
        kind = args[1] if len(args) > 1 else "explain"
        try:
            origin, text = effective_prompt(kind)
        except ValueError:
            print("usage: err.py --prompt explain|question", file=sys.stderr)
            sys.exit(2)
        print("%s\t%s" % (origin, text))
        return

    if args and args[0] in ("-h", "--help"):
        # The launcher owns the help screen; err.py is internal.
        print("err: run `err -h` for the command list (err.py is explain/ask, not the CLI)")
        return

    prune_sessions()

    if not args:
        run_explain()
        return

    verb = args[0]
    if verb == "new":
        cmd_new()
        return
    if verb == "--reset-session":
        # Internal: the launcher calls this after `err stop` so the next
        # conversation starts clean. Silent on purpose.
        cmd_new(quiet=True)
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
