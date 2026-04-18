#!/usr/bin/env bash
set -uo pipefail

# --- Config ---
PROJECT_DIR="$HOME/eit-infosource"
SESSION_ID="${1:-}"                      # optional: pass session ID as first arg
SCREEN_NAME="claude-sprint"
LOG_FILE="$HOME/claude-sprint.log"
STATUS_FILE="$HOME/claude-sprint.status"
# --------------

# Self-detach: if not already inside screen, re-exec inside a detached screen
# session so the caller gets their terminal back immediately.
if [[ -z "${STY:-}" ]]; then
  echo "Starting Claude sprint in detached screen session: $SCREEN_NAME"
  echo "  Watch live:    screen -r $SCREEN_NAME"
  echo "  Tail log:      tail -f $LOG_FILE"
  echo "  Check status:  cat $STATUS_FILE"
  exec screen -dmS "$SCREEN_NAME" "$0" "$@"
fi

cd "$PROJECT_DIR" || { echo "Cannot cd to $PROJECT_DIR"; exit 1; }

# Build --resume flag only if a session ID was provided
RESUME_FLAG=""
if [[ -n "$SESSION_ID" ]]; then
  RESUME_FLAG="--resume $SESSION_ID"
fi

# Clear prior run artifacts
: > "$LOG_FILE"
: > "$STATUS_FILE"

echo "[$(date)] Starting Claude sprint in $PROJECT_DIR" | tee -a "$LOG_FILE"

# --- Sprint prompt ---
# Captured into a variable so it can be passed as the value of -p, avoiding
# argument-parsing collisions with the multi-value --allowedTools flag.
# Using `read -d ''` (not $(cat <<EOF)) because bash -n misparses literal
# $(...) inside a heredoc nested in command substitution.
IFS= read -r -d '' SPRINT_PROMPT <<'PROMPT_EOF' || true
Continue working through the remaining tasks in order. Ignore any claude-sprint.sh file — that is the wrapper script running you, not part of the project work. Be aware that this host may run other Docker workloads outside this project: scope every Docker operation to this project's compose stack (use 'docker compose' targeted at this project's compose file, or named containers/images/volumes that belong to this project). Never run host-wide destructive commands like 'docker system prune', 'docker volume prune', 'docker image prune -a', 'docker rm $(docker ps -aq)', or anything that would touch containers/images/networks/volumes belonging to other projects. After each major milestone: run tests, commit with a clear descriptive message, push to the remote branch, and rebuild/redeploy the Docker containers so the live platform reflects the progress. If tests fail, fix them before pushing. If a deploy fails, diagnose and retry. When all tasks are done, respond with exactly 'DONE' and stop.
PROMPT_EOF

# Run Claude. Prompt is passed as the value of -p (not as a trailing positional)
# so the long --allowedTools list can't accidentally swallow it.
claude -p "$SPRINT_PROMPT" \
  $RESUME_FLAG \
  --permission-mode acceptEdits \
  --effort max \
  --max-turns 300 \
  --output-format stream-json \
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

echo "" | tee -a "$LOG_FILE"
echo "[$(date)] Claude exited with code $CLAUDE_EXIT" | tee -a "$LOG_FILE"

# Check why it ended
if grep -q '"DONE"' "$LOG_FILE" || grep -qE '(^|[^A-Z])DONE([^A-Z]|$)' "$LOG_FILE"; then
  echo "[$(date)] DONE detected — sprint complete." | tee -a "$LOG_FILE"
  echo "DONE" > "$STATUS_FILE"
elif [[ $CLAUDE_EXIT -ne 0 ]]; then
  echo "[$(date)] Sprint ended with error (exit $CLAUDE_EXIT)." | tee -a "$LOG_FILE"
  echo "ERROR" > "$STATUS_FILE"
else
  echo "[$(date)] Sprint ended without DONE marker (max-turns or stop condition)." | tee -a "$LOG_FILE"
  echo "INCOMPLETE" > "$STATUS_FILE"
fi

# Kill the screen session if we're inside one
if [[ -n "${STY:-}" ]]; then
  echo "[$(date)] Killing screen session: $SCREEN_NAME" | tee -a "$LOG_FILE"
  sleep 2  # give log a moment to flush
  screen -X -S "$SCREEN_NAME" quit
fi

exit $CLAUDE_EXIT
