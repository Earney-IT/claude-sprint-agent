# Claude Sprint

A wrapper script that runs an unattended Claude Code "sprint" in headless mode, monitors the output for a `DONE` signal, and automatically tears down the screen session when work is complete.

Built for the workflow: *work with Claude Code interactively, then hand off a scoped set of tasks for Claude to complete autonomously while you're away.*

---

## What it does

1. Runs `claude` in headless print mode (`-p`) with a scoped permission set tuned for dev work.
2. Optionally resumes a prior Claude Code session so Claude keeps the full context of what you were working on.
3. Streams all output to `~/claude-sprint.log` for later review.
4. Watches the log for `DONE` — the signal Claude emits when the task list is complete.
5. Writes a status file (`~/claude-sprint.status`) so you can check the outcome at a glance.
6. Kills the wrapping `screen` session automatically once the sprint ends.

---

## Requirements

- **Claude Code** installed and authenticated (`claude auth status` should return logged-in).
- **GNU `screen`** (`sudo apt install screen` on Debian/Ubuntu).
- **`bash`** — the script uses bash-specific features (`PIPESTATUS`, `[[ ... ]]`).
- A **project directory** where Claude has prior session history if you plan to resume (`-c` / `--resume`).
- The **tools in the allowlist** installed where relevant to your project (git, docker, language runtimes, etc.). Tools not installed just won't get used — they won't break the script.

---

## Installation

1. Save the script as `~/claude-sprint.sh`.
2. Make it executable:
   ```bash
   chmod +x ~/claude-sprint.sh
   ```
3. Edit the top of the script and set `PROJECT_DIR` to the directory where your project lives.

---

## Usage

### Option A — Fresh sprint (no prior session)

```bash
screen -S claude-sprint ~/claude-sprint.sh
```

Claude starts clean. The prompt in the script tells it to work through tasks in order, run tests, commit, push, and redeploy after each milestone, then respond with `DONE` when finished.

### Option B — Resume a prior session

First, list available sessions:

```bash
claude --resume
```

Pick the session you want and copy its ID. Then:

```bash
screen -S claude-sprint ~/claude-sprint.sh <session-id>
```

Claude picks up with full conversation history from that session.

### Detaching

Once the sprint is running, detach from screen with:

```
Ctrl+a  then  d
```

The sprint keeps running in the background. You can close your terminal, log out, walk away.

---

## Monitoring while it runs

From any machine with SSH access:

```bash
# Is the screen session still alive?
screen -ls

# Current status (DONE / INCOMPLETE / ERROR)
cat ~/claude-sprint.status

# Tail the live log
tail -f ~/claude-sprint.log
```

When `screen -ls` shows no matching session, the sprint has ended — check the status file to see how.

---

## Status file meanings

`~/claude-sprint.status` is written when the sprint ends. It contains one of:

- **`DONE`** — Claude finished the task list and said `DONE`. Clean success.
- **`INCOMPLETE`** — Claude exited without saying `DONE`. Usually means it hit `--max-turns` (300) or the stop condition was met some other way. Check the log to see where it stopped.
- **`ERROR`** — Claude exited non-zero. Something went wrong. Log will have details.

---

## What flags are being passed to Claude

The script runs:

```bash
claude -p [--resume <session-id>] \
  --permission-mode acceptEdits \
  --effort max \
  --max-turns 300 \
  --output-format stream-json \
  --include-partial-messages \
  --allowedTools <scoped dev toolkit> \
  "<sprint prompt>"
```

### Flag breakdown

| Flag | Purpose |
|---|---|
| `-p` | Print mode. Runs headless, streams to stdout, exits when done. |
| `--resume <id>` | Continues a specific prior session by ID (only if you passed one in). |
| `--permission-mode acceptEdits` | File edits auto-accept. Bash commands still filtered by allowlist. |
| `--effort max` | Maximum reasoning effort per turn. Best output quality; higher token cost. |
| `--max-turns 300` | Hard cap on agentic turns. Safety net against runaway loops. |
| `--output-format stream-json` | Structured JSON streaming output. Parseable, reviewable after the fact. |
| `--include-partial-messages` | Include mid-turn partial content in the stream. Useful for live tailing. |
| `--allowedTools` | Whitelist of Bash commands Claude can run without prompting. |

---

## The permission model

The script uses `--permission-mode acceptEdits` combined with a scoped `--allowedTools` list. Translation:

- **File edits** — auto-approved. Claude can freely edit any file in the project.
- **Bash commands on the allowlist** — auto-approved. Run without prompting.
- **Bash commands NOT on the allowlist** — blocked. Claude will stall waiting for approval that never comes (since nobody's watching the session).

This is intentional. It's a tripwire: if Claude tries something the allowlist doesn't cover, the sprint stalls rather than doing something destructive or unexpected.

### What's allowed (the allowlist)

**Version control**
- `git*` — full git, including push/force-push/rebase/merge.
- `gh*` — GitHub CLI (PRs, workflow status, etc.).

**Containers**
- `docker*`, `docker-compose*`, `docker compose*` — build, up, down, restart, logs, exec, prune.

**Package managers & runtimes**
- JS: `npm`, `npx`, `node`, `yarn`, `pnpm`, `bun`
- Python: `python`, `python3`, `pip`, `pip3`, `pipx`, `poetry`, `uv`, `pytest`, `venv`
- Other: `go`, `cargo`, `rustc`, `ruby`, `gem`, `bundle`, `php`, `composer`, `java`, `javac`, `mvn`, `gradle`
- Build: `make`, `cmake`

**Read / navigate / inspect**
- `ls`, `cat`, `less`, `head`, `tail`, `wc`, `sort`, `uniq`
- `grep`, `rg`, `find`, `fd`, `tree`
- `pwd`, `echo`, `which`, `whereis`, `file`, `stat`, `du`, `df`

**Non-destructive file ops**
- `mkdir`, `cp`, `mv`, `touch`, `chmod`, `ln`

**Text processing**
- `jq`, `yq`, `sed`, `awk`, `tr`, `cut`, `xargs`, `tee`, `diff`, `patch`

**Network**
- `curl`, `wget`, `ping`, `dig`, `nslookup`, `host`, `nc`, `ssh-keygen`

**Archives**
- `tar`, `zip`, `unzip`, `gzip`, `gunzip`

**Environment / system info**
- `env`, `export`, `printenv`, `date`, `uname`, `whoami`, `id`, `hostname`

**Process inspection**
- `ps`, `top`, `htop`, `kill`, `pkill`, `lsof`, `netstat`, `ss`

**System (read-only)**
- `systemctl status*`, `journalctl*`, `service * status`

**Databases**
- `psql`, `mysql`, `redis-cli`, `sqlite3`, `mongosh`

### What's intentionally NOT allowed

- **`rm`** — no file deletion. Tripwire against destructive operations.
- **`sudo`** — no privilege escalation.
- **`apt`, `yum`, `dnf`, `brew`** — no system-level package installs. Language-level (pip, npm, etc.) is fine.
- **`systemctl start/stop/restart`** — only `status` is read-only allowed.
- **`iptables`, `ufw`, `firewall-cmd`** — no firewall changes.
- **`dd`, `mkfs`, `fdisk`, `parted`** — no disk-level operations.
- **`crontab`** — no silent scheduling.

Docker can still clean up containers/images with `docker rm`, `docker system prune`, etc. — those live inside `docker*` and don't require the `rm` command.

---

## The sprint prompt

The prompt the script sends to Claude:

> Continue working through the remaining tasks in order. After each major milestone: run tests, commit with a clear descriptive message, push to the remote branch, and rebuild/redeploy the Docker containers so the live platform reflects the progress. If tests fail, fix them before pushing. If a deploy fails, diagnose and retry. When all tasks are done, respond with exactly `DONE` and stop.

If you want to change behavior, edit the prompt string in the script. Common tweaks:

- Add a specific task file reference: `"Work through TASKS.md in order..."`
- Narrow the scope: `"Only complete tasks under the 'Backend' heading..."`
- Change the commit cadence: `"Commit after every file change..."`
- Remove the deploy step: strip the "rebuild/redeploy" clause if you don't want live deploys during the sprint.

---

## How `DONE` detection works

After Claude exits, the script greps the log for `DONE` in either:
- A standalone word (plain-text fallback)
- A quoted JSON string value (`"DONE"` — how stream-json wraps message content)

If found, status is set to `DONE` and the screen session is killed. If not found and the exit code is zero, status is `INCOMPLETE`. If the exit code is non-zero, status is `ERROR`.

### Possible false positives

The match is deliberately loose to catch both output shapes. This means a message like *"we're DONE with the auth module"* earlier in the log could trigger the DONE detection. In practice this hasn't been an issue because the prompt instructs Claude to emit `DONE` as a standalone final response and stop — but if you want to eliminate the risk entirely, swap the grep for a tail-based match (e.g., only check the last 50 lines of the log).

---

## Coming back after the sprint

When you return:

```bash
# Check outcome
cat ~/claude-sprint.status

# Review full log
less ~/claude-sprint.log

# Check what git/docker state the sprint left behind
cd /path/to/project
git log --oneline -20
git status
docker ps
```

If status is `DONE`, Claude should have committed, pushed, and redeployed as it went — the live platform should already reflect the work.

If status is `INCOMPLETE` or `ERROR`, review the log to see where things stopped, then either:
- Run an interactive Claude session to finish up manually, or
- Adjust the prompt/allowlist and re-run the sprint.

---

## Customization

All configuration lives at the top of the script:

```bash
PROJECT_DIR="$HOME/eit-infosource"     # Where the sprint runs
SESSION_ID="${1:-}"                    # Optional positional arg
SCREEN_NAME="claude-sprint"            # Must match the screen -S name used to launch
LOG_FILE="$HOME/claude-sprint.log"
STATUS_FILE="$HOME/claude-sprint.status"
```

To run multiple sprints on different projects in parallel, make copies of the script with different `SCREEN_NAME`, `LOG_FILE`, and `STATUS_FILE` values, and launch each in its own named screen session.

---

## Safety notes

- **`git*` is fully open.** Claude can force-push, rewrite history, delete branches. The assumption is that GitHub history + branch protection rules on important branches are your recovery safety net.
- **Docker is fully open.** Claude can stop containers, remove images, prune volumes. If your host runs containers outside this project, be aware a `docker system prune -af` would hit them too.
- **Network is open.** `curl` and `wget` can hit any URL. Not a realistic risk for dev work, but worth knowing.
- **No runtime supervision.** Unlike the remote-control version of this workflow, you cannot interrupt, redirect, or course-correct the sprint mid-run without SSH'ing in and killing the process. Make the prompt count.

For higher-stakes work (production systems, shared infra, anything where a mistake is expensive) consider running with remote control enabled instead so you can watch and intervene from claude.ai.

---

## Troubleshooting

**"No deferred tool marker found in the resumed session"**
The `-c` continue flag couldn't find a resumable session in the current directory. Either run a fresh interactive session first, or use `--resume <session-id>` with an explicit ID from `claude --resume`.

**Screen session dies immediately**
Check that the script is executable (`chmod +x ~/claude-sprint.sh`) and that `PROJECT_DIR` exists.

**Sprint stalls with no output**
Claude likely hit a Bash command not on the allowlist and is waiting for approval. `tail -f ~/claude-sprint.log` to see the last command attempted. To fix, add that command pattern to `--allowedTools` and restart.

**Status never changes from initial blank**
The screen session is still running. `screen -ls` to confirm, `screen -r claude-sprint` to attach and see what's happening.

**`DONE` detected prematurely**
Claude said "DONE" earlier in the log for some reason (quoted someone, described task status, etc.). Tighten the grep in the script to only check the last N lines, or require `DONE` to be the last non-empty line.
