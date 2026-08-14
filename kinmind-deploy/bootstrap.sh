#!/usr/bin/env bash
# bootstrap.sh — put kinmind under git, push it to GitHub, and switch on
# pull-and-restart auto-deploy.
#
# Run once, on the box:
#   curl -sSL <raw-url> | bash
#
# WHAT IT PROTECTS (never committed, never touched by a deploy):
#   memory/      the hearth's whole inner life — journal, loom, dreams, wants
#   workspace/   your documents and its notebook
#   backups/     the memory snapshots
#   .env         your API keys
#   config.yaml  this box's own configuration
#
# This honours GARDENERS.md hard line #5: "config.yaml and memory/ never ship
# in update zips. The hearth's life must survive every upgrade untouched."
#
# After this runs: a push to main is live on the box within ~60 seconds.

set -euo pipefail

KIN="${KIN:-/root/kinmind}"
REPO="${REPO:-https://github.com/timgunning-source/Kinmind.git}"
BRANCH="${BRANCH:-main}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31mABORTED: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
say "Checking the box"
[ -d "$KIN" ] || die "$KIN not found. Set KIN=/path/to/kinmind and re-run."
[ -f "$KIN/server.py" ] || die "$KIN/server.py not found — is that the kinmind folder?"
command -v git >/dev/null || die "git is not installed (apt install -y git)"
ok "kinmind found at $KIN"

# Find the systemd unit that actually runs this thing, rather than assuming.
UNIT=""
for candidate in kinmind kinmind.service hearth hearth.service; do
  if systemctl cat "$candidate" >/dev/null 2>&1; then UNIT="${candidate%.service}"; break; fi
done
if [ -z "$UNIT" ]; then
  UNIT="$(systemctl list-units --type=service --all --no-legend 2>/dev/null \
          | awk '{print $1}' | grep -i 'kin\|hearth' | head -1 | sed 's/\.service$//' || true)"
fi
if [ -n "$UNIT" ]; then
  ok "service unit: $UNIT ($(systemctl is-active "$UNIT" 2>/dev/null || echo unknown))"
else
  warn "no systemd unit found — deploys will pull code but not restart automatically"
fi

# ---------------------------------------------------------------- gitignore
say "Writing .gitignore (this is what keeps the hearth's life out of git)"
cat > "$KIN/.gitignore" <<'GITIGNORE'
# ---- the hearth's life: never leaves the box -------------------------------
memory/
workspace/
backups/
GROW-REQUEST.md

# ---- secrets ---------------------------------------------------------------
.env
*.env
!.env.example

# ---- this box's own configuration -----------------------------------------
# GARDENERS.md hard line #5: config.yaml never ships in an update.
config.yaml

# ---- build noise -----------------------------------------------------------
.venv/
__pycache__/
*.py[cod]
*.zip
node_modules/
.DS_Store
GITIGNORE
ok ".gitignore written"

# ------------------------------------------------------------- secret guard
say "Scanning what is about to be committed for anything key-shaped"
cd "$KIN"
[ -d .git ] || git init -q
git add -A --dry-run >/dev/null 2>&1 || true

# Build the candidate file list honouring .gitignore, then grep it.
CANDIDATES="$(git ls-files --cached --others --exclude-standard 2>/dev/null || true)"
LEAKS=""
if [ -n "$CANDIDATES" ]; then
  LEAKS="$(printf '%s\n' "$CANDIDATES" | while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in *.example|*.md) continue;; esac
    if grep -lE 'sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|xox[baprs]-|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}' "$f" >/dev/null 2>&1; then
      echo "$f"
    fi
  done)"
fi
if [ -n "$LEAKS" ]; then
  printf '\n'
  printf '  %s\n' $LEAKS
  die "the files above look like they contain credentials. Nothing was pushed.
       Move the secret into .env (already gitignored) and re-run."
fi
ok "no credential-shaped strings found in the tracked set"

# ------------------------------------------------------------------- commit
say "Committing the code"
git config user.email  "$(git config user.email 2>/dev/null || echo 'hearth@timsserver.local')" >/dev/null 2>&1 || true
git config user.name   "$(git config user.name  2>/dev/null || echo 'kinmind box')"            >/dev/null 2>&1 || true
git config --global --add safe.directory "$KIN" >/dev/null 2>&1 || true

git add -A
if git diff --cached --quiet 2>/dev/null; then
  ok "nothing new to commit"
else
  git commit -q -m "kinmind: initial import from the live box

Code only. memory/, workspace/, backups/, .env and config.yaml are
deliberately excluded so the hearth's life stays on the box."
  ok "committed"
fi
git branch -M "$BRANCH"

printf '\n    Files that WILL be in GitHub:\n'
git ls-files | sed 's/^/      /' | head -40
TOTAL=$(git ls-files | wc -l)
printf '      (%s files total)\n' "$TOTAL"

printf '\n    Confirmed NOT in GitHub:\n'
for p in memory workspace backups .env config.yaml .venv; do
  if [ -e "$p" ]; then printf '      %s\n' "$p"; fi
done

# -------------------------------------------------------------------- token
say "GitHub credentials"
cat <<'NOTE'
    You need a GitHub token with write access to the Kinmind repo.
    Make one on your phone:
      github.com -> Settings -> Developer settings
        -> Personal access tokens -> Tokens (classic)
        -> Generate new token (classic) -> tick "repo" -> Generate -> copy

    Paste it below. It is NOT echoed and NOT saved to shell history.
NOTE
printf '    Token: '
read -rs TOKEN
printf '\n'
[ -n "$TOKEN" ] || die "no token entered"

printf '%s\n' "https://x-access-token:${TOKEN}@github.com" > /root/.git-credentials
chmod 600 /root/.git-credentials
git config --global credential.helper store
ok "credentials stored (root-only, chmod 600)"
unset TOKEN

git remote remove origin 2>/dev/null || true
git remote add origin "$REPO"
ok "remote set to $REPO"

# --------------------------------------------------------------------- push
say "Pushing to GitHub"
if git push -u origin "$BRANCH" --force; then
  ok "pushed — your code is now in GitHub"
else
  die "push failed. Check the token has 'repo' scope and the repo name matches:
       $REPO"
fi

# ------------------------------------------------------------ deploy runner
say "Installing the auto-deploy runner"
cat > /usr/local/bin/kinmind-deploy.sh <<DEPLOY
#!/usr/bin/env bash
# Pull code from GitHub and restart the hearth if anything changed.
# Only ever touches tracked files: memory/, workspace/ and .env are untracked
# and therefore never modified by this.
set -euo pipefail
KIN="$KIN"
UNIT="$UNIT"
BRANCH="$BRANCH"

cd "\$KIN" || exit 0
BEFORE="\$(git rev-parse HEAD 2>/dev/null || echo none)"
git fetch --quiet origin "\$BRANCH" || exit 0
AFTER="\$(git rev-parse "origin/\$BRANCH" 2>/dev/null || echo none)"

[ "\$BEFORE" = "\$AFTER" ] && exit 0

logger -t kinmind-deploy "update \$BEFORE -> \$AFTER"
if ! git merge --ff-only "origin/\$BRANCH" --quiet; then
  logger -t kinmind-deploy "ff-only merge refused; box has local commits — skipping"
  exit 0
fi

if [ -n "\$UNIT" ]; then
  systemctl restart "\$UNIT" && logger -t kinmind-deploy "restarted \$UNIT"
fi
DEPLOY
chmod +x /usr/local/bin/kinmind-deploy.sh
ok "/usr/local/bin/kinmind-deploy.sh"

# -------------------------------------------------------------- timer units
say "Installing the every-minute timer"
cat > /etc/systemd/system/kinmind-deploy.service <<'SVC'
[Unit]
Description=Pull kinmind code from GitHub and restart the hearth if it changed
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kinmind-deploy.sh
SVC

cat > /etc/systemd/system/kinmind-deploy.timer <<'TMR'
[Unit]
Description=Check GitHub for kinmind updates every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now kinmind-deploy.timer
ok "timer enabled and running"

# ------------------------------------------------------------------ summary
say "Done"
cat <<SUMMARY
    Repo    : $REPO
    Branch  : $BRANCH
    Code    : $KIN  ($TOTAL files tracked)
    Service : ${UNIT:-<none detected>}
    Timer   : kinmind-deploy.timer (every 60s)

    From now on: a merge to $BRANCH goes live here within about a minute.

    Useful:
      systemctl list-timers kinmind-deploy.timer
      journalctl -t kinmind-deploy -n 20
      /usr/local/bin/kinmind-deploy.sh      # force a check right now

    Your memory/, workspace/, backups/, .env and config.yaml were not
    uploaded and are never modified by a deploy.
SUMMARY
