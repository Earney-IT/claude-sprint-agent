#!/usr/bin/env bash
set -uo pipefail

# --- Arg parsing ---
# Usage: claude-sprint.sh [session-id] [--passes N]
#   session-id: Claude Code session ID to resume (optional positional)
#   --passes N: run sprint up to N times, continuing on DONE (default 1)
#
# Multi-pass behavior: if Claude emits DONE but more passes remain, the script
# re-runs the same sprint (resuming the same session) so Claude gets another
# chance to pick up work it might have prematurely considered finished.
# Stops early on INCOMPLETE (max-turns hit without DONE) or ERROR (non-zero exit).
PASSES=1
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
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [session-id] [--passes N]

  session-id  Claude Code session ID to resume (optional). If omitted, starts fresh.
  --passes N  Run the sprint up to N times. After each DONE, re-run up to N-1
              more times. Stops early on INCOMPLETE or ERROR. Default: 1.

Examples:
  $(basename "$0")                              # fresh sprint, 1 pass
  $(basename "$0") abc123def                    # resume session, 1 pass
  $(basename "$0") --passes 3                   # fresh sprint, up to 3 passes
  $(basename "$0") abc123def --passes 3         # resume, up to 3 passes
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

# --- Config ---
PROJECT_DIR="$HOME/eit-infosource"
SCREEN_NAME="claude-sprint"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [[ -n "$SESSION_ID" ]]; then
  SESSION_TAG="${SESSION_ID:0:8}"        # first 8 chars of session ID
else
  SESSION_TAG="fresh"
fi
LOG_FILE="$HOME/claude-sprint-${TIMESTAMP}-${SESSION_TAG}.log"
STATUS_FILE="$HOME/claude-sprint-${TIMESTAMP}-${SESSION_TAG}.status"
LATEST_LOG_LINK="$HOME/claude-sprint.log"
LATEST_STATUS_LINK="$HOME/claude-sprint.status"
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

cd "$PROJECT_DIR" || { echo "Cannot cd to $PROJECT_DIR"; exit 1; }

# Create this run's log/status files and point the "latest" symlinks at them
: > "$LOG_FILE"
: > "$STATUS_FILE"
ln -sf "$LOG_FILE" "$LATEST_LOG_LINK"
ln -sf "$STATUS_FILE" "$LATEST_STATUS_LINK"

echo "[$(date)] Starting Claude sprint in $PROJECT_DIR (passes: up to $PASSES)" | tee -a "$LOG_FILE"
echo "[$(date)] Log file: $LOG_FILE" | tee -a "$LOG_FILE"
echo "[$(date)] Status file: $STATUS_FILE" | tee -a "$LOG_FILE"

# --- Sprint prompt ---
# Captured into a variable so it can be passed as the value of -p, avoiding
# argument-parsing collisions with the multi-value --allowedTools flag.
# Using `read -d ''` (not $(cat <<EOF)) because bash -n misparses literal
# $(...) inside a heredoc nested in command substitution.
IFS= read -r -d '' SPRINT_PROMPT <<'PROMPT_EOF' || true
Continue working through the remaining tasks in order. Ignore any claude-sprint.sh file — that is the wrapper script running you, not part of the project work. Be aware that this host may run other Docker workloads outside this project: scope every Docker operation to this project's compose stack (use 'docker compose' targeted at this project's compose file, or named containers/images/volumes that belong to this project). Never run host-wide destructive commands like 'docker system prune', 'docker volume prune', 'docker image prune -a', 'docker rm $(docker ps -aq)', or anything that would touch containers/images/networks/volumes belonging to other projects. After each major milestone: run tests, commit with a clear descriptive message, push to the remote branch, and rebuild/redeploy the Docker containers so the live platform reflects the progress. If tests fail, fix them before pushing. If a deploy fails, diagnose and retry. When all tasks are done, respond with exactly 'DONE' and stop.
PROMPT_EOF

# --- Multi-pass loop ---
OVERALL_STATUS="INCOMPLETE"
FINAL_EXIT=0

for (( pass=1; pass<=PASSES; pass++ )); do
  echo "" | tee -a "$LOG_FILE"
  echo "============================================================" | tee -a "$LOG_FILE"
  echo "[$(date)] Pass $pass of $PASSES" | tee -a "$LOG_FILE"
  echo "============================================================" | tee -a "$LOG_FILE"

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
    --effort max \
    --max-turns 300 \
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

  # Detect DONE within this pass's output only
  PASS_OUTPUT=$(tail -n +$((PASS_START + 1)) "$LOG_FILE")
  if echo "$PASS_OUTPUT" | grep -q '"result":"DONE"' || \
     echo "$PASS_OUTPUT" | grep -qE '(^|[^A-Z])DONE([^A-Z]|$)'; then
    echo "[$(date)] Pass $pass: DONE detected." | tee -a "$LOG_FILE"
    OVERALL_STATUS="DONE"
    # Continue to next pass if any remain
  else
    echo "[$(date)] Pass $pass: no DONE marker (INCOMPLETE) — stopping multi-pass run." | tee -a "$LOG_FILE"
    OVERALL_STATUS="INCOMPLETE"
    break
  fi
done

# Write final status
echo "$OVERALL_STATUS" > "$STATUS_FILE"
echo "" | tee -a "$LOG_FILE"
echo "[$(date)] Multi-pass run complete. Overall status: $OVERALL_STATUS" | tee -a "$LOG_FILE"

# Kill the screen session if we're inside one
if [[ -n "${STY:-}" ]]; then
  echo "[$(date)] Killing screen session: $SCREEN_NAME" | tee -a "$LOG_FILE"
  sleep 2  # give log a moment to flush
  screen -X -S "$SCREEN_NAME" quit
fi

exit $FINAL_EXIT
