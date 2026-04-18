#!/usr/bin/env bash
set -uo pipefail

# --- Arg parsing ---
# Usage: claude-sprint.sh [session-id] [flags]
# See --help for full reference.
PASSES=1
USAGE_PERCENT=""
EFFORT="max"
MAX_TURNS=300
PROJECT_DIR_FLAG=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --passes)
      PASSES="$2"
      shift 2
      ;;
    --passes=*)
      PASSES="${1#--passes=}"
      shift
      ;;
    --usage)
      USAGE_PERCENT="$2"
      shift 2
      ;;
    --usage=*)
      USAGE_PERCENT="${1#--usage=}"
      shift
      ;;
    --effort)
      EFFORT="$2"
      shift 2
      ;;
    --effort=*)
      EFFORT="${1#--effort=}"
      shift
      ;;
    --max-turns)
      MAX_TURNS="$2"
      shift 2
      ;;
    --max-turns=*)
      MAX_TURNS="${1#--max-turns=}"
      shift
      ;;
    --project-dir)
      PROJECT_DIR_FLAG="$2"
      shift 2
      ;;
    --project-dir=*)
      PROJECT_DIR_FLAG="${1#--project-dir=}"
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [session-id] [flags]

  session-id       Claude Code session ID to resume (optional).
                   If omitted, starts fresh and captures the new ID for later passes.

  --passes N       Run the sprint up to N times. Each pass resumes the same
                   session. Stops early only on ERROR or --usage cap; INCOMPLETE
                   (pass ran out of --max-turns without DONE) continues to the
                   next pass with a fresh turn budget. Default: 1.
  --usage N%       Stop multi-pass once cumulative cost reaches N% of PLAN_CAP_USD.
                   Accepts "50%" or "50". Checked between passes, so may overshoot
                   by up to one pass's cost.
  --effort LEVEL   Passed through to claude --effort. Default: max.
                   Claude Code accepts: low, medium, high, max.
                   Lower effort = faster / cheaper per turn, weaker reasoning.
  --max-turns N    Passed through to claude --max-turns. Default: 300.
                   Per-pass cap on agentic turns before the pass ends as INCOMPLETE.
  --project-dir P  Directory to cd into before running Claude. Default: the
                   current working directory. Override via CLAUDE_SPRINT_PROJECT_DIR
                   env var if you want a persistent default.

Examples:
  $(basename "$0")                                       # fresh, 1 pass, max effort
  $(basename "$0") abc123def                             # resume, 1 pass
  $(basename "$0") --passes 3                            # fresh, up to 3 passes
  $(basename "$0") abc123def --passes 50 --usage 100%    # resume, budget-capped
  $(basename "$0") abc123def --effort high               # cheaper per turn
  $(basename "$0") abc123def --max-turns 100 --passes 5  # short passes, more of them
EOF
      exit 0
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
SESSION_ID="${POSITIONAL[0]:-}"

if ! [[ "$PASSES" =~ ^[0-9]+$ ]] || [[ "$PASSES" -lt 1 ]]; then
  echo "Error: --passes must be a positive integer (got: $PASSES)" >&2
  exit 1
fi

if ! [[ "$MAX_TURNS" =~ ^[0-9]+$ ]] || [[ "$MAX_TURNS" -lt 1 ]]; then
  echo "Error: --max-turns must be a positive integer (got: $MAX_TURNS)" >&2
  exit 1
fi

if [[ -z "$EFFORT" ]]; then
  echo "Error: --effort cannot be empty" >&2
  exit 1
fi

# --- Config ---
# PROJECT_DIR resolution order (first match wins):
#   1. --project-dir flag
#   2. CLAUDE_SPRINT_PROJECT_DIR env var
#   3. Current working directory when the script was invoked
if [[ -n "$PROJECT_DIR_FLAG" ]]; then
  PROJECT_DIR="$PROJECT_DIR_FLAG"
elif [[ -n "${CLAUDE_SPRINT_PROJECT_DIR:-}" ]]; then
  PROJECT_DIR="$CLAUDE_SPRINT_PROJECT_DIR"
else
  PROJECT_DIR="$(pwd)"
fi

# Derive a project-unique tag from PROJECT_DIR's basename so multiple sprints
# on different projects can run in parallel without colliding on the screen
# session name or the "latest" symlink paths. Sanitize to [a-zA-Z0-9_-] so the
# result is always a valid screen session name.
PROJECT_BASENAME=$(basename "$PROJECT_DIR")
PROJECT_TAG=$(echo "$PROJECT_BASENAME" | tr -c 'a-zA-Z0-9_-' '_' | sed 's/__*/_/g; s/^_//; s/_$//')
if [[ -z "$PROJECT_TAG" ]]; then
  PROJECT_TAG="project"
fi
SCREEN_NAME="claude-sprint-$PROJECT_TAG"
# PLAN_CAP_USD: dollar proxy for 100% of your Claude Max plan's usage limit.
# Since Claude Code doesn't expose "percent of plan" directly, --usage N% is
# computed as N% of this value. Tune to match your observed monthly spend at
# 100% plan usage. Rough defaults: Max 5x ≈ $100, Max 20x ≈ $200.
PLAN_CAP_USD=100

# Resolve --usage N% → absolute dollar cap
USAGE_CAP_USD=""
if [[ -n "$USAGE_PERCENT" ]]; then
  PCT="${USAGE_PERCENT%\%}"
  if ! [[ "$PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Error: --usage must be a percentage like 50% or 100% (got: $USAGE_PERCENT)" >&2
    exit 1
  fi
  USAGE_CAP_USD=$(awk -v pct="$PCT" -v cap="$PLAN_CAP_USD" 'BEGIN { printf "%.4f", cap * pct / 100 }')
fi
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [[ -n "$SESSION_ID" ]]; then
  SESSION_TAG="${SESSION_ID:0:8}"        # first 8 chars of session ID
else
  SESSION_TAG="fresh"
fi
LOG_FILE="$HOME/claude-sprint-${PROJECT_TAG}-${TIMESTAMP}-${SESSION_TAG}.log"
STATUS_FILE="$HOME/claude-sprint-${PROJECT_TAG}-${TIMESTAMP}-${SESSION_TAG}.status"
LATEST_LOG_LINK="$HOME/claude-sprint-${PROJECT_TAG}.log"
LATEST_STATUS_LINK="$HOME/claude-sprint-${PROJECT_TAG}.status"
# --------------

# Self-detach: if not already inside screen, re-exec inside a detached screen
# session so the caller gets their terminal back immediately.
if [[ -z "${STY:-}" ]]; then
  echo "Starting Claude sprint in detached screen session: $SCREEN_NAME"
  echo "  Passes:        up to $PASSES"
  echo "  Watch live:    screen -r $SCREEN_NAME"
  echo "  Tail log:      tail -f $LATEST_LOG_LINK"
  echo "  Check status:  cat $LATEST_STATUS_LINK"
  exec screen -dmS "$SCREEN_NAME" "$0" "$@"
fi

# Create this run's log/status files and point the "latest" symlinks at them.
# Done BEFORE the cd so that an unresolvable PROJECT_DIR still leaves a visible
# error trail in the log (the cd error would otherwise vanish into screen's
# buffer).
: > "$LOG_FILE"
: > "$STATUS_FILE"
ln -sf "$LOG_FILE" "$LATEST_LOG_LINK"
ln -sf "$STATUS_FILE" "$LATEST_STATUS_LINK"

if ! cd "$PROJECT_DIR" 2>/dev/null; then
  echo "[$(date)] ERROR: cannot cd to PROJECT_DIR=$PROJECT_DIR" | tee -a "$LOG_FILE"
  echo "[$(date)] Hint: pass --project-dir PATH or set CLAUDE_SPRINT_PROJECT_DIR" | tee -a "$LOG_FILE"
  echo "ERROR" > "$STATUS_FILE"
  if [[ -n "${STY:-}" ]]; then
    sleep 2
    screen -X -S "$SCREEN_NAME" quit
  fi
  exit 1
fi

echo "[$(date)] Starting Claude sprint" | tee -a "$LOG_FILE"
echo "[$(date)] Project:    $PROJECT_DIR" | tee -a "$LOG_FILE"
echo "[$(date)] Log file:   $LOG_FILE" | tee -a "$LOG_FILE"
echo "[$(date)] Status:     $STATUS_FILE" | tee -a "$LOG_FILE"
echo "[$(date)] Passes:     up to $PASSES" | tee -a "$LOG_FILE"
echo "[$(date)] Effort:     $EFFORT" | tee -a "$LOG_FILE"
echo "[$(date)] Max turns:  $MAX_TURNS" | tee -a "$LOG_FILE"
if [[ -n "$USAGE_CAP_USD" ]]; then
  echo "[$(date)] Usage cap:  ${USAGE_PERCENT%\%}% of \$${PLAN_CAP_USD} = \$${USAGE_CAP_USD}" | tee -a "$LOG_FILE"
fi

# Enable agent teams (experimental, disabled by default in Claude Code).
# Requires Claude Code v2.1.32+. Without this, the main agent can still use
# subagents via the Task tool, but cannot spin up a team of peer Claude Code
# instances that coordinate via a shared task list.
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
echo "[$(date)] CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 (agent teams enabled)" | tee -a "$LOG_FILE"

# --- Sprint prompt ---
# Captured into a variable so it can be passed as the value of -p, avoiding
# argument-parsing collisions with the multi-value --allowedTools flag.
# Using `read -d ''` (not $(cat <<EOF)) because bash -n misparses literal
# $(...) inside a heredoc nested in command substitution.
IFS= read -r -d '' SPRINT_PROMPT <<'PROMPT_EOF' || true
Continue working through the remaining tasks in order. Agent teams are pre-enabled for you (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1) — create a team of 3-5 specialized teammates (each one a full Claude Code instance with its own context window) whenever the remaining backlog has independent work streams that can genuinely run in parallel without stepping on each other: e.g. a backend implementer, a frontend implementer, a test writer, and a code reviewer. Assign each teammate a focused piece of work, let them coordinate via the shared task list and inter-agent messaging, and synthesize their output back before committing. Keep the team alive and keep assigning new work to it throughout the sprint — do not tear it down after a single round. After session resumption (the --resume flag), re-spawn the team if teammates have been lost, because in-process teammates do not currently persist across /resume in this experimental feature. For lighter-weight parallelization — focused codebase exploration, research questions, reviewing a specific change — use subagents via the Task/Agent tool (including any project-specific agents defined in .claude/agents/) rather than spinning up a full team. When multiple pieces of work can happen concurrently with no shared state or sequential dependency, spawn the agents in a single turn rather than doing it all sequentially on the main thread. Ignore any claude-sprint.sh file — that is the wrapper script running you, not part of the project work. Be aware that this host may run other Docker workloads outside this project: scope every Docker operation to this project's compose stack (use 'docker compose' targeted at this project's compose file, or named containers/images/volumes that belong to this project). Never run host-wide destructive commands like 'docker system prune', 'docker volume prune', 'docker image prune -a', 'docker rm $(docker ps -aq)', or anything that would touch containers/images/networks/volumes belonging to other projects. After each major milestone: run tests, commit with a clear descriptive message, push to the remote branch, and rebuild/redeploy the Docker containers so the live platform reflects the progress. If tests fail, fix them before pushing. If a deploy fails, diagnose and retry. When the current batch of work is complete but there may still be more to do in follow-up passes, respond with exactly 'DONE' and stop. When you have genuinely searched for remaining work (re-read the plan / task file, checked git status, looked at any TODO/BACKLOG docs) and there is truly nothing left to do, respond with exactly 'NO TASKS' and stop — the wrapper uses this as a hard signal to end the multi-pass run and not waste further credits on empty iterations. Do not say 'NO TASKS' just because the current batch is finished; only use it when the backlog itself is empty.
PROMPT_EOF

# --- Multi-pass loop ---
OVERALL_STATUS="INCOMPLETE"
FINAL_EXIT=0
CUMULATIVE_COST_USD="0"

for (( pass=1; pass<=PASSES; pass++ )); do
  echo "" | tee -a "$LOG_FILE"
  echo "============================================================" | tee -a "$LOG_FILE"
  echo "[$(date)] Pass $pass of $PASSES" | tee -a "$LOG_FILE"
  echo "============================================================" | tee -a "$LOG_FILE"

  # Pre-pass usage-cap check (stop before spending any more if already over)
  if [[ -n "$USAGE_CAP_USD" ]]; then
    OVER=$(awk -v c="$CUMULATIVE_COST_USD" -v cap="$USAGE_CAP_USD" 'BEGIN { print (c+0 >= cap+0) ? 1 : 0 }')
    if [[ "$OVER" == "1" ]]; then
      echo "[$(date)] Usage cap already reached before pass $pass (\$${CUMULATIVE_COST_USD} >= \$${USAGE_CAP_USD}) — stopping." | tee -a "$LOG_FILE"
      OVERALL_STATUS="USAGE_LIMIT"
      break
    fi
  fi

  # Build --resume flag from current SESSION_ID (captured from pass 1 if fresh)
  RESUME_FLAG=""
  if [[ -n "$SESSION_ID" ]]; then
    RESUME_FLAG="--resume $SESSION_ID"
  fi

  # Mark log line where this pass starts — used to scope DONE detection and
  # session-id capture to just this pass's output.
  PASS_START=$(wc -l < "$LOG_FILE")

  # Run Claude. Prompt is passed as the value of -p (not as a trailing positional)
  # so the long --allowedTools list can't accidentally swallow it.
  claude -p "$SPRINT_PROMPT" \
    $RESUME_FLAG \
    --permission-mode acceptEdits \
    --effort "$EFFORT" \
    --max-turns "$MAX_TURNS" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    --allowedTools \
      "Bash(git*)" "Bash(gh*)" \
      "Bash(docker compose*)" "Bash(docker-compose*)" \
      "Bash(npm*)" "Bash(npx*)" "Bash(node*)" "Bash(yarn*)" "Bash(pnpm*)" "Bash(bun*)" \
      "Bash(python*)" "Bash(python3*)" "Bash(pip*)" "Bash(pip3*)" "Bash(pipx*)" "Bash(poetry*)" "Bash(uv*)" "Bash(pytest*)" "Bash(venv*)" \
      "Bash(go*)" "Bash(cargo*)" "Bash(rustc*)" "Bash(ruby*)" "Bash(gem*)" "Bash(bundle*)" "Bash(php*)" "Bash(composer*)" "Bash(java*)" "Bash(javac*)" "Bash(mvn*)" "Bash(gradle*)" \
      "Bash(make*)" "Bash(cmake*)" \
      "Bash(ls*)" "Bash(cat*)" "Bash(less*)" "Bash(head*)" "Bash(tail*)" "Bash(wc*)" "Bash(sort*)" "Bash(uniq*)" "Bash(grep*)" "Bash(rg*)" "Bash(find*)" "Bash(fd*)" "Bash(tree*)" "Bash(pwd)" "Bash(echo*)" "Bash(which*)" "Bash(whereis*)" "Bash(file*)" "Bash(stat*)" "Bash(du*)" "Bash(df*)" \
      "Bash(mkdir*)" "Bash(cp*)" "Bash(mv*)" "Bash(touch*)" "Bash(chmod*)" "Bash(ln*)" \
      "Bash(jq*)" "Bash(yq*)" "Bash(sed*)" "Bash(awk*)" "Bash(tr*)" "Bash(cut*)" "Bash(xargs*)" "Bash(tee*)" "Bash(diff*)" "Bash(patch*)" \
      "Bash(curl*)" "Bash(wget*)" "Bash(ping*)" "Bash(dig*)" "Bash(nslookup*)" "Bash(host*)" "Bash(nc*)" "Bash(ssh-keygen*)" \
      "Bash(tar*)" "Bash(zip*)" "Bash(unzip*)" "Bash(gzip*)" "Bash(gunzip*)" \
      "Bash(env*)" "Bash(export*)" "Bash(printenv*)" "Bash(date*)" "Bash(uname*)" "Bash(whoami*)" "Bash(id*)" "Bash(hostname*)" \
      "Bash(ps*)" "Bash(top*)" "Bash(htop*)" "Bash(kill*)" "Bash(pkill*)" "Bash(lsof*)" "Bash(netstat*)" "Bash(ss*)" \
      "Bash(systemctl status*)" "Bash(journalctl*)" "Bash(service * status)" \
      "Bash(psql*)" "Bash(mysql*)" "Bash(redis-cli*)" "Bash(sqlite3*)" "Bash(mongosh*)" \
    2>&1 | tee -a "$LOG_FILE"

  CLAUDE_EXIT=${PIPESTATUS[0]}
  FINAL_EXIT=$CLAUDE_EXIT

  echo "" | tee -a "$LOG_FILE"
  echo "[$(date)] Pass $pass: Claude exited with code $CLAUDE_EXIT" | tee -a "$LOG_FILE"

  # Capture session ID from pass output if we didn't have one — so later passes
  # resume the session pass 1 just created.
  if [[ -z "$SESSION_ID" ]]; then
    CAPTURED_ID=$(tail -n +$((PASS_START + 1)) "$LOG_FILE" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"\([^"]*\)"/\1/')
    if [[ -n "$CAPTURED_ID" ]]; then
      SESSION_ID="$CAPTURED_ID"
      echo "[$(date)] Captured session ID: $SESSION_ID (will resume on subsequent passes)" | tee -a "$LOG_FILE"
    fi
  fi

  # Stop immediately on error
  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    echo "[$(date)] Pass $pass errored — stopping multi-pass run." | tee -a "$LOG_FILE"
    OVERALL_STATUS="ERROR"
    break
  fi

  # Detect terminal markers within this pass's output only.
  # NO TASKS is a hard stop. To avoid false positives from subagents or
  # teammates saying "NO TASKS" in their own reports, we ONLY check the main
  # agent's final result event (the top-level "type":"result" line — there is
  # exactly one per headless -p invocation, and it carries the main agent's
  # final response). Subagent/teammate outputs live inside assistant messages
  # and never produce their own result events at this level.
  PASS_OUTPUT=$(tail -n +$((PASS_START + 1)) "$LOG_FILE")
  MAIN_RESULT=$(echo "$PASS_OUTPUT" | grep '"type":"result"' | tail -1)
  PASS_NO_TASKS=0
  PASS_DONE=0
  if echo "$MAIN_RESULT" | grep -q '"result":"NO TASKS"'; then
    echo "[$(date)] Pass $pass: NO TASKS detected from main agent — backlog is empty." | tee -a "$LOG_FILE"
    PASS_NO_TASKS=1
  elif echo "$MAIN_RESULT" | grep -q '"result":"DONE"' || \
       echo "$PASS_OUTPUT" | grep -qE '(^|[^A-Z])DONE([^A-Z]|$)'; then
    echo "[$(date)] Pass $pass: DONE detected." | tee -a "$LOG_FILE"
    OVERALL_STATUS="DONE"
    PASS_DONE=1
  fi

  # Extract this pass's cost from its result event and update cumulative total
  PASS_COST=$(echo "$PASS_OUTPUT" | grep '"type":"result"' | tail -1 | grep -oE '"total_cost_usd":[0-9.]+' | head -1 | sed 's/.*://')
  if [[ -n "$PASS_COST" ]]; then
    CUMULATIVE_COST_USD=$(awk -v a="$CUMULATIVE_COST_USD" -v b="$PASS_COST" 'BEGIN { printf "%.4f", a + b }')
    echo "[$(date)] Pass $pass cost: \$${PASS_COST}  |  cumulative: \$${CUMULATIVE_COST_USD}" | tee -a "$LOG_FILE"
  else
    echo "[$(date)] Pass $pass: could not extract cost from result event" | tee -a "$LOG_FILE"
  fi

  # NO TASKS from the main agent = hard stop. Nothing left to do, don't waste
  # more passes on empty iterations.
  if [[ "$PASS_NO_TASKS" == "1" ]]; then
    OVERALL_STATUS="NO_TASKS"
    break
  fi

  # Post-pass usage-cap check — trumps DONE/continue logic so we always exit
  # once we've crossed the budget.
  if [[ -n "$USAGE_CAP_USD" ]]; then
    OVER=$(awk -v c="$CUMULATIVE_COST_USD" -v cap="$USAGE_CAP_USD" 'BEGIN { print (c+0 >= cap+0) ? 1 : 0 }')
    if [[ "$OVER" == "1" ]]; then
      echo "[$(date)] Usage cap reached after pass $pass (\$${CUMULATIVE_COST_USD} >= \$${USAGE_CAP_USD}) — stopping." | tee -a "$LOG_FILE"
      OVERALL_STATUS="USAGE_LIMIT"
      break
    fi
  fi

  # No DONE marker → record INCOMPLETE for this pass but keep going. This lets
  # you chain short --max-turns passes: each one runs out of its turn budget,
  # the next one resumes with a fresh budget. Only ERROR, USAGE_LIMIT, and
  # NO_TASKS break the multi-pass loop.
  if [[ "$PASS_DONE" != "1" ]]; then
    echo "[$(date)] Pass $pass: no DONE marker (INCOMPLETE) — continuing to next pass." | tee -a "$LOG_FILE"
    OVERALL_STATUS="INCOMPLETE"
  fi
done

# Write final status
echo "$OVERALL_STATUS" > "$STATUS_FILE"
echo "" | tee -a "$LOG_FILE"
echo "[$(date)] Multi-pass run complete. Overall status: $OVERALL_STATUS  |  total cost: \$${CUMULATIVE_COST_USD}" | tee -a "$LOG_FILE"

# Kill the screen session if we're inside one
if [[ -n "${STY:-}" ]]; then
  echo "[$(date)] Killing screen session: $SCREEN_NAME" | tee -a "$LOG_FILE"
  sleep 2  # give log a moment to flush
  screen -X -S "$SCREEN_NAME" quit
fi

exit $FINAL_EXIT
