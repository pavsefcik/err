# err

Explains your last shell command using a local LLM via Apple's MLX-LM. After running a failed command type `err` to get a short explanation of what happened. You can also type `err <question>` to ask a shell or CLI question directly, or `errc <cmd...>` to run a command with stderr captured and get an explanation automatically.

**Requirements:** macOS (Apple Silicon), [uv](https://github.com/astral-sh/uv)

**Install:** double-click `install.command` (or run it from a terminal). It installs `mlx-lm` as a uv tool and adds a line to your `~/.zshrc` to source `err.zsh`.

The model (configured in `err.conf`, default `mlx-community/gemma-4-e2b-it-4bit`) is downloaded on first run. On first run, the mlx-lm server starts in the background and stays running for subsequent calls.
