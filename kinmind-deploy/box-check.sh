#!/usr/bin/env bash
# box-check.sh — READ-ONLY survey of the kinmind box.
#
# Changes nothing. Starts nothing. Stops nothing. It only looks, and prints
# what it finds, so the auto-deploy setup can be written to match this box
# instead of guessing.
#
# It deliberately never prints the CONTENTS of .env, /etc/kinmind.env, or any
# API key — only whether such a file exists. Safe to paste the output back.
#
# Run:  curl -sSL <raw-url> | bash

set -uo pipefail

line() { printf '\n=== %s ===\n' "$1"; }

line "identity"
echo "user      : $(whoami)"
echo "host      : $(hostname)"
echo "os        : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -a)"
echo "uptime    : $(uptime -p 2>/dev/null || true)"

line "where kinmind lives"
KIN=""
for d in /root/kinmind /home/*/kinmind /opt/kinmind /srv/kinmind; do
  if [ -f "$d/server.py" ]; then echo "KIN_DIR   : $d"; KIN="$d"; fi
done
[ -z "$KIN" ] && echo "KIN_DIR   : (not found in the usual places)"

line "is the hearth running?"
systemctl is-active kinmind 2>/dev/null || echo "(kinmind service not active/known)"
systemctl cat kinmind 2>/dev/null \
  | grep -E '^(WorkingDirectory|ExecStart|User|EnvironmentFile|Restart)=' \
  || echo "(no kinmind systemd unit)"

line "listening ports"
(ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null) | grep -E 'LISTEN' | head -15

line "python"
if [ -n "$KIN" ] && [ -x "$KIN/.venv/bin/python" ]; then
  echo "venv      : $KIN/.venv/bin/python ($($KIN/.venv/bin/python -V 2>&1))"
else
  echo "venv      : (none found)"
fi
echo "system    : $(command -v python3 || echo none) $(python3 -V 2>&1 || true)"

line "tooling needed for auto-deploy"
for t in git curl claude node npm; do
  p="$(command -v "$t" 2>/dev/null)"
  echo "$(printf '%-9s' "$t"): ${p:-MISSING}"
done

line "secrets present? (existence only — contents never shown)"
for f in /etc/kinmind.env "${KIN:-/nonexistent}/.env"; do
  [ -f "$f" ] && echo "present   : $f" || echo "absent    : $f"
done

line "is this already a git repo?"
if [ -n "$KIN" ] && [ -d "$KIN/.git" ]; then
  echo "yes — remote: $(git -C "$KIN" remote get-url origin 2>/dev/null || echo '(none)')"
  echo "branch     : $(git -C "$KIN" branch --show-current 2>/dev/null)"
else
  echo "no (normal — the deploy step will initialise one)"
fi

line "can the box reach github?"
curl -sSI --max-time 12 https://github.com 2>/dev/null | head -n1 || echo "NO EGRESS TO GITHUB"

line "tailscale"
if command -v tailscale >/dev/null 2>&1; then
  tailscale status 2>/dev/null | head -5
  echo "--- ssh enabled on this node? ---"
  tailscale status --json 2>/dev/null | grep -o '"RunningSSHServer":[a-z]*' || echo "(could not read SSH flag)"
else
  echo "(tailscale CLI not found)"
fi

line "disk"
df -h / 2>/dev/null | tail -1

printf '\n--- survey complete. Nothing was changed. ---\n'
