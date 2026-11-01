# Shell, non-interactive

OpenCode's own shell has no terminal. A command that waits for input, opens an editor, or starts a pager hangs until it times out. Background and interactive programs belong in the PTY tools (`pty_spawn`, `pty_write`, `pty_read`, `pty_list`, `pty_kill`), not in the shell tool.

These rules are the shell strategy by JRedeker, MIT, Copyright (c) 2025 JRedeker, taken from `shell_strategy.md` at commit `1303f24`. https://github.com/JRedeker/opencode-shell-strategy

## Core rules

1. No editors or pagers. `vim`, `nano`, `less`, `more`, `man`, and similar terminal tools are banned in the shell tool.
2. No interactive modes. Avoid flags that open an interactive UI, such as `git add -p`, `git rebase -i`, or `bash -i`.
3. Use the command's own non-interactive flag (`-y`, `--no-input`, `--no-edit`, `--no-pager`) instead of a generic force.
4. When a command cannot run without a password or a user choice, use a non-interactive form that fails immediately, or stop and report.
5. Prefer OpenCode's Read, Write, and Edit tools for file changes.

## Prompts

Do not blanket-approve prompts with `yes | …` or heredocs.

- Authorized and the tool has a non-interactive flag: use it. Examples: `apt-get install -y pkg`, `npm init -y`, `pip install --no-input pkg`.
- Needs credentials or a choice, and a non-interactive mode fails visibly: use that. Examples: `sudo -n command`, `ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 user@host`.
- Not authorized, or no safe non-interactive form: stop and say that the operation needs user input, credentials, or a trusted host.

## SSH and privilege

`StrictHostKeyChecking=accept-new` accepts a previously unknown host key and refuses a changed one. `StrictHostKeyChecking=no` is prohibited.

`sudo -n` runs only when no password is required. Do not pipe passwords to `sudo -S` or any other command.

## Commands

- `npm init` without `-y` is interactive. `npm install` is already non-interactive; do not add `--force`.
- Git: `git commit -m "msg"`, `git merge --no-edit`, `git pull --no-edit`, `git rebase` without `-i`, `git add` without `-p`, `git --no-pager log`, `git --no-pager diff`.
- `rm`, `cp`, and `mv` do not prompt unless `-i` is set. `rm -f` suppresses errors. Check the target before a destructive command. `unzip -o` overwrites without prompting.
- REPLs: `python -c` and `node -e`. A bare `python` or `node` belongs in a PTY, or not at all.

Optional, for one command only, never exported globally: `GIT_TERMINAL_PROMPT=0`, `DEBIAN_FRONTEND=noninteractive`, `PIP_NO_INPUT=1`.
