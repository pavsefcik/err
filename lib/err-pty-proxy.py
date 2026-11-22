#!/usr/bin/env python3
"""PTY relay that captures shell output between err's OSC command markers.

This is intentionally a small stdlib-only process supervisor. It lets the
interactive shell and its foreground programs keep a real TTY while copying
only command output to err's bounded per-shell capture file.
"""

import argparse
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import tty

MAX_CAPTURE_BYTES = 65536


class MarkerCapture:
    """Observe private OSC boundaries and save bytes inside each pair."""

    def __init__(self, token, output_path):
        # Private OSC namespace; the random token distinguishes this proxy's
        # boundaries from unrelated terminal / shell-integration sequences.
        self.start = b"\x1b]18188736;" + token.encode("ascii") + b";S\x07"
        self.end = b"\x1b]18188736;" + token.encode("ascii") + b";E\x07"
        self.pending = b""
        self.output_path = output_path
        self.active = False
        self.capture = bytearray()
        self.alt_screen = False

    def _append_capture(self, data):
        if data:
            scan = bytes(self.capture[-16:]) + data
            if any(sequence in scan for sequence in (
                    b"\x1b[?1049h", b"\x1b[?1047h", b"\x1b[?47h")):
                self.alt_screen = True
            self.capture.extend(data)
            if len(self.capture) > MAX_CAPTURE_BYTES:
                del self.capture[:-MAX_CAPTURE_BYTES]

    def _finish(self):
        # Full-screen TUIs use the alternate screen; retaining their cursor and
        # repaint traffic is not useful conversational context (and can contain
        # sensitive screen contents). Drop those command transcripts entirely.
        temp_path = self.output_path + ".tmp." + str(os.getpid())
        try:
            directory = os.path.dirname(self.output_path)
            if directory:
                os.makedirs(directory, mode=0o700, exist_ok=True)
                os.chmod(directory, 0o700)
            with open(temp_path, "wb") as stream:
                os.chmod(temp_path, 0o600)
                # TUI output is intentionally represented by an empty capture,
                # never by the previous command's transcript.
                if not self.alt_screen:
                    stream.write(self.capture)
            os.replace(temp_path, self.output_path)
        except OSError:
            # Capture is best-effort. Disk-full/permission failures must not
            # terminate the user's interactive shell or interrupt the relay.
            try:
                os.unlink(temp_path)
            except OSError:
                pass
            try:
                with open(self.output_path, "wb") as stream:
                    os.chmod(self.output_path, 0o600)
            except OSError:
                try:
                    os.unlink(self.output_path)
                except OSError:
                    pass
        finally:
            self.capture.clear()
            self.active = False

    def feed(self, data, final=False):
        self.pending += data
        while True:
            candidates = [(self.end, "end")] if self.active else [
                (self.start, "start"), (self.end, "end")]
            found = [(self.pending.find(marker), marker, action)
                     for marker, action in candidates]
            found = [item for item in found if item[0] >= 0]
            if found:
                index, marker, action = min(found, key=lambda item: item[0])
                chunk = self.pending[:index]
                if self.active:
                    self._append_capture(chunk)
                    self._finish()
                elif action == "start":
                    self.capture.clear()
                    self.alt_screen = False
                    self.active = True
                self.pending = self.pending[index + len(marker):]
                continue

            if final:
                chunk, self.pending = self.pending, b""
            else:
                # Retain only a suffix that could actually be the beginning
                # of a marker. Holding an arbitrary marker-sized tail would
                # hide short shell prompts and deadlock an interactive user.
                keep = 0
                for marker, _action in candidates:
                    upper = min(len(marker) - 1, len(self.pending))
                    for size in range(upper, keep, -1):
                        if self.pending.endswith(marker[:size]):
                            keep = size
                            break
                if keep == len(self.pending):
                    break
                if keep:
                    chunk, self.pending = self.pending[:-keep], self.pending[-keep:]
                else:
                    chunk, self.pending = self.pending, b""
            if self.active:
                self._append_capture(chunk)
            if final:
                break


def _write_all(fd, data):
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def _drain_master(master_fd, parser, output_fd):
    """Forward everything already queued after the child process exits."""
    os.set_blocking(master_fd, False)
    while True:
        try:
            data = os.read(master_fd, 4096)
        except (BlockingIOError, OSError):
            break
        if not data:
            break
        parser.feed(data)
        _write_all(output_fd, data)


def _window_size(fd):
    try:
        return fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
    except OSError:
        return struct.pack("HHHH", 24, 80, 0, 0)


def run(shell_argv, output_path):
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("err: PTY capture requires an interactive terminal", file=sys.stderr)
        return 2

    token = os.urandom(16).hex()
    env = os.environ.copy()
    env["ERR_PTY_PROXY_ACTIVE"] = "1"
    env["ERR_PTY_TOKEN"] = token
    env["ERR_PTY_CAPTURE_FILE"] = output_path

    pid, master_fd = pty.fork()
    if pid == 0:
        os.execvpe(shell_argv[0], shell_argv, env)

    old_attrs = termios.tcgetattr(sys.stdin.fileno())
    old_winsize = _window_size(sys.stdout.fileno())
    parser = MarkerCapture(token, output_path)
    child_status = None
    try:
        tty.setraw(sys.stdin.fileno())
        fcntl.ioctl(master_fd, termios.TIOCSWINSZ, old_winsize)

        def resized(_signum, _frame):
            try:
                fcntl.ioctl(master_fd, termios.TIOCSWINSZ,
                            _window_size(sys.stdout.fileno()))
            except OSError:
                pass

        def terminate(signum, _frame):
            raise SystemExit(128 + signum)

        signal.signal(signal.SIGWINCH, resized)
        for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT, signal.SIGQUIT):
            signal.signal(signum, terminate)
        stdin_fd = sys.stdin.fileno()
        stdin_open = True
        while True:
            readers = [master_fd] + ([stdin_fd] if stdin_open else [])
            ready, _, _ = select.select(readers, [], [], 0.1)
            if stdin_open and stdin_fd in ready:
                try:
                    data = os.read(stdin_fd, 4096)
                except OSError:
                    data = b""
                if not data:
                    # Let the child shell observe terminal EOF (VEOF) and
                    # exit naturally instead of waiting forever on its PTY.
                    stdin_open = False
                    _write_all(master_fd, b"\x04")
                else:
                    _write_all(master_fd, data)
            if master_fd in ready:
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    data = b""
                if not data:
                    break
                parser.feed(data)
                # Keep the terminal byte stream byte-exact. Terminals ignore
                # our private OSC markers; other shell integrations must pass
                # through untouched.
                _write_all(sys.stdout.fileno(), data)
            waited, status = os.waitpid(pid, os.WNOHANG)
            if waited:
                child_status = status
                # The shell may exit with more than one read buffer queued
                # (e.g. `cat` of a large file). Drain it before restoring tty.
                _drain_master(master_fd, parser, sys.stdout.fileno())
                break

        parser.feed(b"", final=True)
        if child_status is None:
            _, child_status = os.waitpid(pid, 0)
    finally:
        try:
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_attrs)
        except OSError:
            pass
        try:
            os.close(master_fd)
        except OSError:
            pass

    if os.WIFEXITED(child_status):
        return os.WEXITSTATUS(child_status)
    if os.WIFSIGNALED(child_status):
        return 128 + os.WTERMSIG(child_status)
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture-file", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print("usage: err-pty-proxy.py --capture-file PATH -- SHELL [ARGS...]",
              file=sys.stderr)
        return 2
    try:
        return run(command, args.capture_file)
    except (OSError, ValueError) as exc:
        print("err: PTY proxy failed: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
