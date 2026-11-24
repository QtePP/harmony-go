#!/usr/bin/env bash
#
# Push the current branch to both code hosts.
#
#   GitHub  → origin (credentials already configured on this machine)
#   AtomGit → HTTPS, using a token supplied in the environment
#
# The token is never written to disk by this script: no remote with credentials
# is added, no credential helper is asked to store it. It lives in this
# process's memory and in the push URL, which is not echoed. On macOS it may be
# read from an existing Keychain item instead of the environment:
#
#   security add-generic-password -a atomgit -s atomgit-token -w   # store once
#
# ...after which plain `bash scripts/push-all.sh` works with no variables set.
#
# Usage:
#   ATOMGIT_TOKEN=... bash scripts/push-all.sh
#   grep -q . <<< "${ATOMGIT_TOKEN:-}" || echo "set ATOMGIT_TOKEN first"
#   bash scripts/push-all.sh --dry-run     # only report what would be pushed
#   bash scripts/push-all.sh --tags        # also push tags
#
# Environment:
#   ATOMGIT_TOKEN   required for the AtomGit leg; without it GitHub-only.
#                   On macOS, when unset, the script falls back to the Keychain
#                   item (account "atomgit", service "atomgit-token").
#   ATOMGIT_USER    AtomGit account name (default: the repo owner below)
#   ATOMGIT_REPO    owner/repo on AtomGit (default: the repo this ships with)
#
# Exit codes: 0 both pushed (or AtomGit skipped with a warning), 1 a push failed.

set -u

ATOMGIT_DEFAULT_REPO="qtepp/harmony-go"
ATOMGIT_DEFAULT_USER="qq_446289021111111111111118aq"
ATOMGIT_HOST="atomgit.com"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

DRY_RUN=""
WITH_TAGS=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="--dry-run" ;;
    --tags) WITH_TAGS="--tags" ;;
    -h|--help)
      sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg (try --dry-run / --tags / --help)" >&2
      exit 1
      ;;
  esac
done

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || fail "git is not installed"
git rev-parse --git-dir >/dev/null 2>&1 || fail "not a git repository: $REPO_ROOT"

BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
[ -n "$BRANCH" ] || fail "detached HEAD; check out a branch first"

say "repo:   $REPO_ROOT"
say "branch: $BRANCH"
if [ -n "$(git status --porcelain)" ]; then
  say "note:   working tree has uncommitted changes; they are NOT pushed"
fi

# --- GitHub ----------------------------------------------------------------
say ""
say "==> GitHub (origin)"
git push $DRY_RUN $WITH_TAGS origin "$BRANCH" || fail "GitHub push failed"

# --- AtomGit ---------------------------------------------------------------
ATOMGIT_REPO="${ATOMGIT_REPO:-$ATOMGIT_DEFAULT_REPO}"
ATOMGIT_USER="${ATOMGIT_USER:-$ATOMGIT_DEFAULT_USER}"
ATOMGIT_TOKEN="${ATOMGIT_TOKEN:-}"
KEYCHAIN_NOTE=""
if [ -z "$ATOMGIT_TOKEN" ] && [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
  ATOMGIT_TOKEN="$(security find-generic-password -a atomgit -s atomgit-token -w 2>/dev/null | tr -d '\n' || true)"
  if [ -n "$ATOMGIT_TOKEN" ]; then
    KEYCHAIN_NOTE=" (from macOS Keychain)"
  fi
fi

say ""
if [ -z "$ATOMGIT_TOKEN" ]; then
  say "==> AtomGit skipped: no token in ATOMGIT_TOKEN and no Keychain item"
  say "    store it once: security add-generic-password -a atomgit -s atomgit-token -w"
  say "    or run with:   ATOMGIT_TOKEN=<token> bash scripts/push-all.sh"
else
  say "==> AtomGit ($ATOMGIT_HOST/$ATOMGIT_REPO)${KEYCHAIN_NOTE}"
  # The token goes into the URL only for this invocation; git never writes it
  # to .git/config because no remote is added. Do not set -x around this.
  ATOMGIT_URL="https://${ATOMGIT_USER}:${ATOMGIT_TOKEN}@${ATOMGIT_HOST}/${ATOMGIT_REPO}.git"
  GIT_TERMINAL_PROMPT=0 git push $DRY_RUN $WITH_TAGS "$ATOMGIT_URL" "$BRANCH:$BRANCH" \
    || fail "AtomGit push failed (token expired or lacking write access?)"
  unset ATOMGIT_URL
fi

# --- report the tips -------------------------------------------------------
say ""
say "==> tips"
say "local   $(git rev-parse --short HEAD)"
if git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
  say "origin  $(git ls-remote origin "refs/heads/$BRANCH" | cut -f1 | cut -c1-7)"
fi
if [ -n "$ATOMGIT_TOKEN" ]; then
  ATOMGIT_TIP="$(git ls-remote "https://${ATOMGIT_USER}@${ATOMGIT_HOST}/${ATOMGIT_REPO}.git" "refs/heads/$BRANCH" 2>/dev/null | cut -f1 | cut -c1-7)"
  say "atomgit ${ATOMGIT_TIP:-unavailable (read needs a token or the repo is private)}"
fi

if [ -n "$DRY_RUN" ]; then
  say ""
  say "dry run only: nothing was written to either remote"
fi
