#!/usr/bin/env python3
"""Standalone runner for tests/mock_fm_server.py — used by tests/smoke.zsh.

Usage:  python3 tests/mock_serve.py <port-file>
Prints the base URL to <port-file>, then serves until killed.

Env: MOCK_REPLY  text streamed back (chunked); defaults to an answer with a
                 fenced block so err.py's suggestion channel is exercised.
"""

import json
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mock_fm_server  # noqa: E402


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: mock_serve.py <port-file>", file=sys.stderr)
        return 2
    port_file = sys.argv[1]

    state = mock_fm_server.MockState()
    state.reply = os.environ.get(
        "MOCK_REPLY", "A glob matches filenames.\n```bash\nls *.txt\n```\n"
    )
    state.usage_total = int(os.environ["MOCK_USAGE"]) if os.environ.get("MOCK_USAGE") else None

    _, server, base_url = mock_fm_server.start(state)
    with open(port_file + ".tmp", "w") as f:
        f.write(base_url)
    os.replace(port_file + ".tmp", port_file)
    print(base_url, flush=True)

    def bye(*_):
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)

    while True:
        time.sleep(0.2)
        # Requests are appended to state.requests; expose the count so the
        # shell test can assert the launcher really reached the server, and the
        # last body so it can assert what the model was actually told.
        with open(port_file + ".count", "w") as f:
            f.write(str(len(state.requests)))
        if state.requests:
            last = port_file + ".last"
            with open(last + ".tmp", "w") as f:
                json.dump(state.requests[-1], f, indent=1)
            os.replace(last + ".tmp", last)


if __name__ == "__main__":
    sys.exit(main())
