#!/usr/bin/env python3
"""PTY proxy acceptance tests for TTY semantics and err shell-hook capture."""

import errno
import os
import pty
import select
import signal
import stat
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
import err as errmod

PROXY = os.path.join(REPO, "lib", "err-pty-proxy.py")
LAUNCHER = os.path.join(REPO, "err-launcher.zsh")


def read_available(fd, timeout=0.1):
    data = bytearray()
    ready, _, _ = select.select([fd], [], [], timeout)
    if ready:
        try:
            data.extend(os.read(fd, 4096))
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
    return bytes(data)


def wait_child(pid, master, timeout=5):
    deadline = time.time() + timeout
    output = bytearray()
    while time.time() < deadline:
        output.extend(read_available(master, 0.1))
        result, status = os.waitpid(pid, os.WNOHANG)
        if result:
            return status, bytes(output)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    raise AssertionError("PTY proxy child did not exit")


def proxy_argv(capture, *command):
    return [sys.executable, PROXY, "--capture-file", capture, "--"] + list(command)


def test_proxy_tty_and_markers(temp):
    capture = os.path.join(temp, "output")
    child_code = r'''import os, sys
 token = os.environ["ERR_PTY_TOKEN"].encode("ascii")
 os.write(1, b"\x1b]18188736;" + token + b";S\x07")
 print("stdout_isatty=%s" % sys.stdout.isatty())
 print("stderr_isatty=%s" % sys.stderr.isatty())
 print("captured alpha")
 print("x" * 100000)
 print("TAIL_SENTINEL")
 os.write(1, b"\x1b]18188736;" + token + b";E\x07")'''.replace("\n ", "\n")
    pid, master = pty.fork()
    if pid == 0:
        os.execv(sys.executable, proxy_argv(
            capture, sys.executable, "-c", child_code))
    status, visible = wait_child(pid, master)
    os.close(master)
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        raise AssertionError("proxy exited unsuccessfully: %r" % status)
    shown = visible.decode("utf-8", "replace")
    if ("stdout_isatty=True" not in shown or "stderr_isatty=True" not in shown
            or "captured alpha" not in shown or "TAIL_SENTINEL" not in shown
            or shown.count("x") < 100000):
        raise AssertionError("wrapped command lost TTY/output: %r" % shown)
    if "\x1b]18188736;" not in shown:
        raise AssertionError("proxy did not relay the terminal stream byte-for-byte")
    with open(capture, "rb") as stream:
        saved = stream.read().decode("utf-8", "replace")
    if stat.S_IMODE(os.stat(capture).st_mode) != 0o600:
        raise AssertionError("capture file is not private")
    if stat.S_IMODE(os.stat(temp).st_mode) != 0o700:
        raise AssertionError("capture directory is not private")
    if "TAIL_SENTINEL" not in saved:
        raise AssertionError("proxy did not save the bounded output tail")
    print("PASS PTY proxy preserves tty and captures marked output")


def test_capture_failure_does_not_kill_shell(temp):
    capture_dir = os.path.join(temp, "not-a-file")
    os.mkdir(capture_dir)
    child_code = "print('still-alive')"
    pid, master = pty.fork()
    if pid == 0:
        os.execv(sys.executable, proxy_argv(
            capture_dir, sys.executable, "-c", child_code))
    status, visible = wait_child(pid, master)
    os.close(master)
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        raise AssertionError("capture I/O failure terminated the PTY shell")
    if b"still-alive" not in visible:
        raise AssertionError("capture failure interrupted terminal output")
    print("PASS capture write failure is non-fatal")


def test_exit_status_is_preserved(temp):
    capture = os.path.join(temp, "exit-output")
    pid, master = pty.fork()
    if pid == 0:
        os.execv(sys.executable, proxy_argv(capture, "zsh", "-c", "exit 42"))
    status, _ = wait_child(pid, master)
    os.close(master)
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 42:
        raise AssertionError("proxy did not preserve child exit status")
    print("PASS PTY proxy preserves child exit status")


def test_alt_screen_is_not_saved(temp):
    capture = os.path.join(temp, "alt-screen-output")
    child_code = r'''import os
 token = os.environ["ERR_PTY_TOKEN"].encode("ascii")
 start = b"\x1b]18188736;" + token + b";S\x07"
 end = b"\x1b]18188736;" + token + b";E\x07"
 os.write(1, start + b"OLD_TRANSCRIPT" + end)
 os.write(1, start + b"\x1b[?1049hTUI_SCREEN\x1b[?1049l" + end)'''.replace("\n ", "\n")
    pid, master = pty.fork()
    if pid == 0:
        os.execv(sys.executable, proxy_argv(
            capture, sys.executable, "-c", child_code))
    status, _ = wait_child(pid, master)
    os.close(master)
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        raise AssertionError("alternate-screen proxy child failed")
    if not os.path.exists(capture) or os.path.getsize(capture) != 0:
        raise AssertionError("TUI output left stale output in the capture file")
    print("PASS alternate-screen output is excluded")


def test_zsh_hooks_capture_previous_command(temp):
    state = os.path.join(temp, "state")
    zdotdir = os.path.join(temp, "zdot")
    os.makedirs(state)
    os.makedirs(zdotdir)
    with open(os.path.join(state, "err.conf"), "w") as config:
        config.write("# existing config with comments\nbackend = fm\ncapture = pty\n")
    with open(os.path.join(zdotdir, ".zshrc"), "w") as startup:
        startup.write("source '%s'\n" % os.path.join(REPO, "lib", "err-pty-startup.zsh"))
        startup.write("source '%s'\n" % LAUNCHER)
    env = os.environ.copy()
    env["ERR_STATE_DIR"] = state
    env["SHELL"] = "/bin/bash"  # PTY bootstrap must relaunch zsh, not this hint.
    env.pop("ERR_CAPTURE", None)
    env.pop("ERR_CONF", None)
    # A developer's shell may itself be a PTY proxy child. If these leak in,
    # the bootstrap sees ERR_PTY_PROXY_ACTIVE=1 and skips starting its own
    # proxy, so the hooks emit markers with an empty token and capture nothing.
    env.pop("ERR_PTY_PROXY_ACTIVE", None)
    env.pop("ERR_PTY_TOKEN", None)
    env.pop("ERR_PTY_CAPTURE_FILE", None)
    env["ZDOTDIR"] = zdotdir
    pid, master = pty.fork()
    if pid == 0:
        os.execvpe("zsh", ["zsh", "-i"], env)

    child_finished = False
    try:
        # .zshrc bootstraps the proxy; its child shell installs err's hooks.
        startup_output = bytearray()
        startup_output.extend(read_available(master, 0.75))
        os.write(master, b"echo 'Hello from your shell!'\n")
        deadline = time.time() + 5
        saved = b""
        run_dir = os.path.join(state, "run")
        while time.time() < deadline:
            try:
                paths = [os.path.join(run_dir, name) for name in os.listdir(run_dir)
                         if name.startswith("pty-output.")]
                for path in paths:
                    with open(path, "rb") as stream:
                        saved = stream.read()
                    if b"Hello from your shell!" in saved:
                        break
            except OSError:
                pass
            if b"Hello from your shell!" in saved:
                break
            startup_output.extend(read_available(master, 0.1))
        if b"Hello from your shell!" not in saved:
            raise AssertionError("zsh hooks missed output; terminal=%r; state=%r" % (
                startup_output[-1200:], os.listdir(run_dir) if os.path.isdir(run_dir) else []))
        old_capture_path = os.environ.get("_ERR_STDOUT_FILE")
        os.environ["_ERR_STDOUT_FILE"] = paths[0]
        try:
            clean = errmod.tail_output(errmod.read_capture_file("_ERR_STDOUT_FILE"))
        finally:
            if old_capture_path is None:
                os.environ.pop("_ERR_STDOUT_FILE", None)
            else:
                os.environ["_ERR_STDOUT_FILE"] = old_capture_path
        if clean != "Hello from your shell!":

            raise AssertionError("capture reader retained prompt artifacts: %r" % clean)
        os.write(master, b'exit\n')
        status, _ = wait_child(pid, master)
        child_finished = True
        if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
            raise AssertionError("interactive capture shell exited unsuccessfully")
    finally:
        if not child_finished:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except OSError:
                pass
        try:
            os.close(master)
        except OSError:
            pass
    print("PASS .zshrc PTY startup captures ordinary zsh command output")


def main():
    with tempfile.TemporaryDirectory(prefix="err-pty-test-") as temp:
        test_proxy_tty_and_markers(temp)
        test_capture_failure_does_not_kill_shell(temp)
        test_exit_status_is_preserved(temp)
        test_alt_screen_is_not_saved(temp)
        test_zsh_hooks_capture_previous_command(temp)


if __name__ == "__main__":
    main()
