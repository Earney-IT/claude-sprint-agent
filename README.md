# Claude Sprint

A wrapper script that runs an unattended Claude Code "sprint" in headless mode, monitors the output for a `DONE` signal, and automatically tears down the screen session when work is complete.

Built for the workflow: *work with Claude Code interactively, then hand off a scoped set of tasks for Claude to complete autonomously while you're away.*

---

## What it does

1. Runs `claude` in headless print mode (`-p`) with a scoped permission set tuned for dev work.
2. Optionally resumes a prior Claude Code session so Claude keeps the full context of what you were working on.
3. Streams all output to a timestamped log file (`~/claude-sprint-<YYYYMMDD-HHMMSS>-<session-tag>.log`) so every run is preserved, with `~/claude-sprint.log` as a symlink to the most recent run.
4. Watches the log for `DONE` — the signal Claude emits when the task list is complete.
5. Writes a timestamped status file alongside the log, also symlinked at `~/claude-sprint.status`.
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

1. Download the script and make it executable (`wget` saves files without the execute bit, so `chmod +x` is required):
   ```bash
   wget https://raw.githubusercontent.com/Earney-IT/claude-sprint-agent/refs/heads/main/claude-sprint.sh -O ~/claude-sprint.sh
   chmod +x ~/claude-sprint.sh
   ```
2. Edit the top of the script and set `PROJECT_DIR` to the directory where your project lives.

---

## Usage

The script self-detaches into a `screen` session — you'll get your terminal back immediately and the sprint runs in the background.

### Option A — Fresh sprint (no prior session)

```bash
~/claude-sprint.sh
```

Claude starts clean. The prompt in the script tells it to work through tasks in order, run tests, commit, push, and redeploy after each milestone, then respond with `DONE` when finished.

### Option B — Resume a prior session

First, list available sessions:

```bash
claude --resume
```

Pick the session you want and copy its ID. Then:

```bash
~/claude-sprint.sh <session-id>
```

Claude picks up with full conversation history from that session.

### Option C — Multi-pass sprint (`--passes N`)

Claude sometimes emits `DONE` prematurely — for example, finishing the "current batch" of tasks but leaving later phases untouched. `--passes N` re-runs the sprint after each `DONE`, up to `N` total passes, giving Claude another shot at picking up the remaining work:

```bash
~/claude-sprint.sh --passes 3                      # fresh sprint, up to 3 passes
~/claude-sprint.sh <session-id> --passes 3         # resume, up to 3 passes
```

Behavior:
- Pass 1 runs. If Claude says `DONE`, pass 2 runs (resuming the same session). If pass 2 says `DONE`, pass 3 runs. And so on up to `N`.
- If any pass hits `INCOMPLETE` (no `DONE`, typically from `--max-turns`), the multi-pass run stops there.
- If any pass errors, the multi-pass run stops immediately with status `ERROR`.
- When pass 1 starts fresh (no session ID), the script captures the new session ID from pass 1's stream-json output and uses it to resume for passes 2+.

Good for: finishing a multi-phase plan where the "done" marker only reflects the most recent batch, not the whole backlog. Bad for: single-task sprints where you know a `DONE` means truly done — stick with `--passes 1` (the default) to avoid extra cost.

### Option D — Budget-capped sprint (`--usage N%`)

For when you want to run as long as possible on your Claude Max plan without blowing past your monthly allowance:

```bash
~/claude-sprint.sh <session-id> --passes 50 --usage 100%   # run until 100% or 50 passes
~/claude-sprint.sh <session-id> --passes 20 --usage 50%    # run until 50% or 20 passes
```

How it works:
- Each pass's `total_cost_usd` is extracted from its stream-json `result` event and accumulated.
- Between passes, the script checks whether cumulative cost has reached the budget. If so, it stops with status `USAGE_LIMIT`.
- The check is **between passes, not mid-pass** — so the actual stop may overshoot the target by up to one pass's cost. Set `--max-turns` lower or use a smaller `--usage` percentage if that matters to you.
- Pairs naturally with `--passes N` — set passes to a large number and let `--usage` be the real stop condition.

The percentage is computed against `PLAN_CAP_USD` (a constant at the top of the script). Defaults to `$100` which is the rough monthly equivalent of Claude Max 5x. For Max 20x, edit the script and set `PLAN_CAP_USD=200`. Because Claude Code doesn't expose "percent of plan" directly, this is a proxy based on observed API dollar spend — calibrate `PLAN_CAP_USD` to whatever your monthly bill is when you're genuinely at 100% plan usage.

Good for: "burn my plan on this backlog and stop at 100%" / "max out at 50% so I have headroom for the rest of the week." Not exact — treat the percentage as a soft target, not a hard guarantee.

### Tuning effort and turn budget

```bash
~/claude-sprint.sh <session-id> --effort high              # cheaper per turn than max
~/claude-sprint.sh <session-id> --max-turns 100 --passes 5 # shorter passes, more of them
~/claude-sprint.sh <session-id> --effort max --max-turns 500
                                                           # every knob cranked
```

- `--effort` accepts `low` / `medium` / `high` / `max`. Defaults to `max`. Lower = faster and cheaper per turn at the cost of reasoning quality.
- `--max-turns N` is the per-pass turn budget (default `300`). When a pass hits it without emitting `DONE`, the run ends as `INCOMPLETE`. Pair with a big `--passes N` to turn one long pass into several shorter ones that each get a fresh turn counter.

### Watching it live (optional)

The sprint runs detached in the background — you don't have to attach. But if you want to peek at it live:

```bash
screen -r claude-sprint
```

To detach again without killing it: `Ctrl+a` then `d`. To stop watching and let it keep running: just detach. To kill the sprint: `screen -X -S claude-sprint quit`.

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

`~/claude-sprint.log` and `~/claude-sprint.status` are symlinks that always point to the most recent run. The actual files are timestamped (e.g. `~/claude-sprint-20260418-043700-ff983357.log`) and persist across runs, so you can `ls -lt ~/claude-sprint-*.log` to browse history.

When `screen -ls` shows no matching session, the sprint has ended — check the status file to see how.

---

## Status file meanings

`~/claude-sprint.status` is written when the sprint ends. It contains one of:

- **`DONE`** — The last pass Claude ran emitted `DONE`. In multi-pass mode, this also means every earlier pass emitted `DONE` (otherwise the run would have stopped earlier as `INCOMPLETE`). Clean success.
- **`INCOMPLETE`** — A pass exited without emitting `DONE` (usually because it hit `--max-turns`). Check the log to see where it stopped.
- **`USAGE_LIMIT`** — The cumulative cost across passes reached the `--usage N%` threshold and the multi-pass run stopped on purpose. Not a failure — just the budget working as configured.
- **`ERROR`** — A pass exited non-zero. Something went wrong. Log will have details.

---

## What flags are being passed to Claude

The script runs:

```bash
claude -p [--resume <session-id>] \
  --permission-mode acceptEdits \
  --effort <EFFORT> \
  --max-turns <MAX_TURNS> \
  --output-format stream-json \
  --verbose \
  --include-partial-messages \
  --allowedTools <scoped dev toolkit> \
  "<sprint prompt>"
```

`<EFFORT>` and `<MAX_TURNS>` come from wrapper flags `--effort` and `--max-turns` (defaults: `max` and `300`).

### Flag breakdown

| Flag | Purpose |
|---|---|
| `-p` | Print mode. Runs headless, streams to stdout, exits when done. |
| `--resume <id>` | Continues a specific prior session by ID (only if you passed one in). |
| `--permission-mode acceptEdits` | File edits auto-accept. Bash commands still filtered by allowlist. |
| `--effort <level>` | Reasoning effort per turn. `max` = best output, highest cost. `low` / `medium` / `high` available for cheaper/faster work. Overridable via `--effort` wrapper flag. |
| `--max-turns <N>` | Per-pass cap on agentic turns before the pass ends as INCOMPLETE. Overridable via `--max-turns` wrapper flag. |
| `--output-format stream-json` | Structured JSON streaming output. Parseable, reviewable after the fact. |
| `--verbose` | Required alongside `-p` + `stream-json`. |
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
- `docker compose*`, `docker-compose*` — full Compose lifecycle (build, up, down, restart, logs, exec, ps, pull, run). Bare `docker` subcommands (e.g. `docker system prune`, `docker stop <name>`, `docker rm`) are intentionally NOT allowed — every container operation must go through Compose, which scopes it to this project's stack.

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

Note that bare `docker` subcommands (anything that isn't `docker compose ...`) are also blocked — Claude can only manage containers through Compose, which scopes operations to this project's stack and never touches workloads from other projects on the same host.

---

## The sprint prompt

The prompt the script sends to Claude:

> Continue working through the remaining tasks in order. Agent teams are pre-enabled for you (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) — create a team of 3-5 specialized teammates (each one a full Claude Code instance with its own context window) whenever the remaining backlog has independent work streams that can genuinely run in parallel without stepping on each other: e.g. a backend implementer, a frontend implementer, a test writer, and a code reviewer. Assign each teammate a focused piece of work, let them coordinate via the shared task list and inter-agent messaging, and synthesize their output back before committing. Keep the team alive and keep assigning new work to it throughout the sprint — do not tear it down after a single round. After session resumption (the `--resume` flag), re-spawn the team if teammates have been lost, because in-process teammates do not currently persist across `/resume` in this experimental feature. For lighter-weight parallelization — focused codebase exploration, research questions, reviewing a specific change — use subagents via the Task/Agent tool (including any project-specific agents defined in `.claude/agents/`) rather than spinning up a full team. When multiple pieces of work can happen concurrently with no shared state or sequential dependency, spawn the agents in a single turn rather than doing it all sequentially on the main thread. Ignore any claude-sprint.sh file — that is the wrapper script running you, not part of the project work. Be aware that this host may run other Docker workloads outside this project: scope every Docker operation to this project's compose stack (use `docker compose` targeted at this project's compose file, or named containers/images/volumes that belong to this project). Never run host-wide destructive commands like `docker system prune`, `docker volume prune`, `docker image prune -a`, `docker rm $(docker ps -aq)`, or anything that would touch containers/images/networks/volumes belonging to other projects. After each major milestone: run tests, commit with a clear descriptive message, push to the remote branch, and rebuild/redeploy the Docker containers so the live platform reflects the progress. If tests fail, fix them before pushing. If a deploy fails, diagnose and retry. When all tasks are done, respond with exactly `DONE` and stop.

If you want to change behavior, edit the prompt string in the script. Common tweaks:

- Add a specific task file reference: `"Work through TASKS.md in order..."`
- Narrow the scope: `"Only complete tasks under the 'Backend' heading..."`
- Change the commit cadence: `"Commit after every file change..."`
- Remove the deploy step: strip the "rebuild/redeploy" clause if you don't want live deploys during the sprint.

---

## Parallelization: agent teams and subagents

The sprint script gives Claude two separate mechanisms for parallel work, and the prompt tells it when to use which.

### Agent teams (experimental — enabled by the script)

[Agent teams](https://code.claude.com/docs/en/agent-teams) spin up multiple peer Claude Code instances that coordinate via a shared task list and can message each other directly. They're the right tool when the remaining backlog has independent work streams that benefit from genuine parallelism (backend + frontend + tests, or multi-perspective code review).

Agent teams are **experimental and disabled by default in Claude Code**. The sprint script auto-enables them:

```bash
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

This is set before Claude launches, so the agent can create and manage teams without any extra config. Requires Claude Code v2.1.32+ (check with `claude --version`).

**Known headless caveats** (all documented in the official docs):
- **Teammates do not survive `/resume`**: after a session resumes (which is exactly what multi-pass mode does), any in-process teammates from the prior pass are gone. The prompt instructs Claude to re-spawn the team when this happens.
- **In-process mode only**: split-pane mode needs tmux or iTerm2; we're in `screen`, so the default in-process mode is what you get. That's fine — teammates still coordinate via the shared task list and mailbox, Claude just can't display them in split panes.
- **Token cost is higher**: every teammate is a separate Claude Code instance with its own context window. The sprint's `--usage N%` budget cap still applies — be aware that a 5-teammate team can burn budget ~5× faster than a solo session.

### Subagents (always on)

[Subagents](https://code.claude.com/docs/en/sub-agents) are lighter-weight: the main agent dispatches a specialized helper (via the Task/Agent tool), the helper does a focused job, and reports back. They work for things like "explore this codebase", "review this PR", or "run the tests and summarize". They're enabled by default in headless mode — no flag needed, the `Agent` tool does not need to be on the `--allowedTools` list.

**Where agent definitions live** (both subagents and agent teammates can use these):
1. `.claude/agents/` in the project dir — project-specific roles
2. `~/.claude/agents/` — your personal agents, cross-project
3. Plugin-provided agents from installed Claude Code plugins

Drop markdown files with frontmatter (`description`, `tools`, optional `model`) and Claude will discover them. `/agents` in an interactive Claude Code session shows what's currently available.

**Subagent / teammate model override (optional):**

Want teammates and subagents on a cheaper model than the main sprint Opus thread? Set:

```bash
export CLAUDE_CODE_SUBAGENT_MODEL=claude-sonnet-4-6
~/claude-sprint.sh <session-id> --passes 10 --usage 100%
```

Main sprint runs on Opus (`--effort max`), parallel work runs on Sonnet — a common optimization for multi-agent runs.

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
SCREEN_NAME="claude-sprint"            # Must match the screen -S name used to launch
PLAN_CAP_USD=100                       # Dollar proxy for 100% of your Claude Max plan
                                       #   (Max 5x ≈ $100, Max 20x ≈ $200; tune to your bill)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)       # Generated per-run
SESSION_TAG=...                        # First 8 chars of SESSION_ID, or "fresh"
LOG_FILE="$HOME/claude-sprint-${TIMESTAMP}-${SESSION_TAG}.log"
STATUS_FILE="$HOME/claude-sprint-${TIMESTAMP}-${SESSION_TAG}.status"
LATEST_LOG_LINK="$HOME/claude-sprint.log"      # Symlink → current LOG_FILE
LATEST_STATUS_LINK="$HOME/claude-sprint.status" # Symlink → current STATUS_FILE
```

Each run gets its own timestamped log and status file (so history is preserved), plus the `~/claude-sprint.log` and `~/claude-sprint.status` symlinks are repointed at the active run's files — so the standard `tail -f` / `cat` commands always show "the current run."

To run multiple sprints on different projects in parallel, make copies of the script with different `SCREEN_NAME` and `LATEST_LOG_LINK` / `LATEST_STATUS_LINK` values, and launch each in its own named screen session.

---

## Safety notes

- **`git*` is fully open.** Claude can force-push, rewrite history, delete branches. The assumption is that GitHub history + branch protection rules on important branches are your recovery safety net.
- **Docker is restricted to Compose.** Only `docker compose ...` (and legacy `docker-compose ...`) are on the allowlist — bare `docker` subcommands are blocked. This is a hard constraint, not just a prompt instruction: Claude cannot run `docker system prune`, `docker stop <name>`, `docker rm`, or anything else that would reach containers/images/volumes outside this project's Compose stack. If it tries, the sprint stalls waiting for an approval that never comes (which is the desired behavior). The full Compose lifecycle (build, up, down, restart, logs, exec, ps, pull, run) is unrestricted.
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
