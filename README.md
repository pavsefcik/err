# err

Explains your last shell command using Apple Foundation Models. After running a failed command type `err` to get a short explanation of what happened. You can also type `err <question>` to ask a shell or CLI question directly, or `errc <cmd...>` to run a command with stderr captured and get an explanation automatically.

**Requirements:** macOS 27 with the Apple Foundation Models CLI (`fm`, preinstalled)

**Install:** double-click `install.command` (or run it from a terminal). It adds a line to your `~/.zshrc` to source `err-launcher.zsh`.

The model is configured in `err.conf` (`system` = on-device Apple Foundation Model by default, or `pcc` for Private Cloud Compute). On first run, `fm serve` starts in the background and stays running for subsequent calls.
