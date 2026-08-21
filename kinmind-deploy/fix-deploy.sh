#!/usr/bin/env bash
# fix-deploy.sh — repair the auto-deploy runner.
#
# Two faults in the first version, both mine:
#
#   1. systemd does not set HOME for a root service, so git could not find
#      /root/.gitconfig, so the credential helper never loaded, so `git fetch`
#      against a private repo failed authentication.
#   2. The runner ended that fetch with `|| exit 0`, so the failure was
#      silent — the timer ticked every minute and did nothing, forever,
#      without a single line in the journal.
#
# This rewrites the runner to authenticate explicitly (no dependence on HOME
# at all) and to LOG every failure loudly. Then it runs one deploy so you see
# the result immediately.
#
# Safe to run repeatedly.

set -uo pipefail

KIN="${KIN:-/root/kinmind}"
BRANCH="${BRANCH:-main}"
CRED="${CRED:-/root/.git-credentials}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok()  { printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '    \033[31m✗\033[0m %s\n' "$1"; }

say "Checking prerequisites"
[ -d "$KIN/.git" ] || { bad "$KIN is not a git repo — run bootstrap.sh first"; exit 1; }
ok "repo at $KIN"
if [ -f "$CRED" ]; then ok "credentials file present: $CRED"
else bad "no $CRED — the fetch will fail; re-run bootstrap.sh to store a token"; fi

UNIT=""
for c in kinmind hearth; do
  if systemctl cat "$c" >/dev/null 2>&1; then UNIT="$c"; break; fi
done
[ -n "$UNIT" ] && ok "service unit: $UNIT" || bad "no service unit found (code will still update)"

# ------------------------------------------------------------------ runner
say "Rewriting the deploy runner (explicit auth + real logging)"
cat > /usr/local/bin/kinmind-deploy.sh <<RUNNER
#!/usr/bin/env bash
# Pull kinmind code from GitHub; restart the hearth if the commit changed.
# Only fast-forwards TRACKED files, so memory/, workspace/ and .env - which are
# untracked - are never modified by a deploy.
set -uo pipefail

# Do not rely on systemd providing HOME: set it, AND pass the credential
# helper explicitly so authentication cannot depend on global git config.
export HOME=/root

KIN="$KIN"
UNIT="$UNIT"
BRANCH="$BRANCH"
CRED="$CRED"

log() { logger -t kinmind-deploy "\$*"; }

cd "\$KIN" || { log "ERROR cannot cd to \$KIN"; exit 1; }

BEFORE="\$(git rev-parse HEAD 2>/dev/null || echo none)"

if ! ERR="\$(git -c credential.helper="store --file=\$CRED" fetch origin "\$BRANCH" 2>&1)"; then
  log "ERROR fetch failed: \$(printf '%s' "\$ERR" | tr '\n' ' ' | cut -c1-300)"
  exit 1
fi

AFTER="\$(git rev-parse "origin/\$BRANCH" 2>/dev/null || echo none)"

if [ "\$BEFORE" = "\$AFTER" ]; then
  exit 0                      # up to date; stay quiet so the journal is signal
fi

log "update \$BEFORE -> \$AFTER"

if ! ERR="\$(git merge --ff-only "origin/\$BRANCH" 2>&1)"; then
  log "ERROR ff-only merge refused (local commits on the box?): \$(printf '%s' "\$ERR" | tr '\n' ' ' | cut -c1-300)"
  exit 1
fi

if [ -n "\$UNIT" ]; then
  if systemctl restart "\$UNIT"; then
    log "restarted \$UNIT"
  else
    log "ERROR restart of \$UNIT failed"
    exit 1
  fi
fi

log "deploy complete at \$AFTER"
RUNNER
chmod +x /usr/local/bin/kinmind-deploy.sh
ok "/usr/local/bin/kinmind-deploy.sh rewritten"

# ------------------------------------------------------------------- unit
say "Adding HOME to the systemd service"
cat > /etc/systemd/system/kinmind-deploy.service <<'SVC'
[Unit]
Description=Pull kinmind code from GitHub and restart the hearth if it changed
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/usr/local/bin/kinmind-deploy.sh
SVC
systemctl daemon-reload
ok "service unit updated (Environment=HOME=/root)"

# ------------------------------------------------------------ run it once
say "Running one deploy now"
if /usr/local/bin/kinmind-deploy.sh; then
  ok "runner exited cleanly"
else
  bad "runner reported a failure — see the log below"
fi

say "What the runner logged"
journalctl -t kinmind-deploy -n 15 --no-pager || true

say "Where the box is now"
git -C "$KIN" log --oneline -3 || true
printf '\n'
if [ -f "$KIN/DEPLOYING.md" ]; then
  ok "DEPLOYING.md is present — the pipeline works end to end"
else
  bad "DEPLOYING.md still missing — read the ERROR line above"
fi
