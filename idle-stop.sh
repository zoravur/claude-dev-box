#!/bin/bash
# Stops the instance after IDLE_MINUTES with no activity. Runs on the host
# from cron every 5 minutes (see user_data in main.tf).
#
# Activity is any of:
#   - a Claude conversation transcript was written (every message/tool call)
#   - a Session Manager or SSH shell is open
#   - the 5-minute load average is above 0.5 (e.g. a long build)
# The idle clock starts no earlier than boot, so a fresh start from the phone
# gets the full window before it can stop again.
#
# Dry run: IDLE_STOP_DRY_RUN=1 idle-stop

IDLE_MINUTES=${IDLE_MINUTES:-30}
TRANSCRIPTS=${TRANSCRIPTS:-/srv/claude-home/.claude/projects}

now=$(date +%s)
last=$(( now - $(cut -d. -f1 /proc/uptime) ))

newest=$(find "$TRANSCRIPTS" -maxdepth 2 -name '*.jsonl' -printf '%T@\n' 2>/dev/null \
  | sort -n | tail -1 | cut -d. -f1)
if [ -n "$newest" ] && [ "$newest" -gt "$last" ]; then
  last=$newest
fi

if pgrep -f ssm-session-worker >/dev/null || pgrep -f '^sshd(-session)?: [^ ]+@' >/dev/null; then
  last=$now
fi

if awk '{ exit !($2 > 0.5) }' /proc/loadavg; then
  last=$now
fi

idle=$(( (now - last) / 60 ))
if [ -n "$IDLE_STOP_DRY_RUN" ]; then
  echo "idle ${idle}m (stops at ${IDLE_MINUTES}m)"
elif (( idle >= IDLE_MINUTES )); then
  logger -t idle-stop "idle for ${idle} min; stopping instance"
  shutdown -h now
fi
