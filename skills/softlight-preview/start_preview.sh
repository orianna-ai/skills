#!/usr/bin/env bash
#
# Push the local branch to a Softlight challenge branch and have Softlight boot a live preview.
#
#   start_preview.sh [what to look at]
#
# The branch is pushed to origin as softlight/<nonce>, a new branch named after a random nonce.
# Uncommitted and untracked changes go with it (files .gitignore excludes stay behind): they are
# snapshotted into a commit on top of HEAD without touching the local branch, the index or the
# working tree. Softlight checks the branch out, works out which app it changes and boots it, and
# the nonce only the pusher knows is what shows Softlight the request comes from someone who can
# push to the repository.
#
# "What to look at" helps Softlight pick the app to boot in a repository with several. Without it,
# Softlight goes by the files the branch changes.
#
# Exit status:
#   0  Softlight took the request; the preview page, which shows the app once it boots, is on stdout
#   2  bad input, the push failed, or Softlight refused or could not be reached
#
# Requires git, curl and jq. Set SOFTLIGHT_BASE_URL to point at another Softlight deployment.

set -euo pipefail

BASE_URL="${SOFTLIGHT_BASE_URL:-https://app.softlight.com}"
readonly BASE_URL="${BASE_URL%/}"
readonly USAGE="usage: start_preview.sh [what to look at]"

die() {
  echo "$*" >&2
  exit 2
}

case "${1:-}" in
  -h | --help)
    sed -n '3,20s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  *) ;;
esac
[[ $# -le 1 ]] || die "${USAGE}"
command -v git >/dev/null || die "git is required"
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"

# --- Which repository -----------------------------------------------------------------------------

top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git checkout"
readonly top
head="$(git rev-parse --verify --quiet 'HEAD^{commit}')" || die "HEAD has no commits yet"
readonly head

readonly NAME='[A-Za-z0-9_.-]+'
remote="$(git config --get remote.origin.url)" || die "the checkout has no origin remote"
[[ ${remote} =~ github\.com[:/](${NAME})/(${NAME})$ ]] || die "origin (${remote}) is not on GitHub"
owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]%.git}"
readonly owner repo

branch="$(git symbolic-ref --quiet --short HEAD)" || branch="${head:0:12}"
readonly branch

readonly request="${1:-}"

# --- What to serve --------------------------------------------------------------------------------

# A scratch index keeps the snapshot from touching the real one.
sha="${head}"
if [[ -n "$(git -C "${top}" status --porcelain)" ]]; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "${scratch}"' EXIT
  export GIT_INDEX_FILE="${scratch}/index"
  git -C "${top}" read-tree "${head}"
  git -C "${top}" add --all
  tree="$(git -C "${top}" write-tree)"
  unset GIT_INDEX_FILE
  if ! git var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
    export GIT_AUTHOR_NAME=Softlight GIT_AUTHOR_EMAIL=noreply@softlight.com
    export GIT_COMMITTER_NAME=Softlight GIT_COMMITTER_EMAIL=noreply@softlight.com
  fi
  sha="$(git commit-tree "${tree}" -p "${head}" -m "Uncommitted changes on ${branch}")"
fi
readonly sha

# --- Push the challenge branch --------------------------------------------------------------------

nonce="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
readonly nonce
readonly ref="refs/heads/softlight/${nonce}"
git push --quiet origin "${sha}:${ref}" || die "couldn't push ${ref} to origin"

# --- Ask Softlight to boot it ---------------------------------------------------------------------

readonly PREVIEWS="${BASE_URL}/api/branch-previews"
body="$(
  jq -n --arg repository "${owner}/${repo}" --arg ref "${ref}" --arg request "${request:0:4000}" \
    '{repository: $repository, ref: $ref, request: $request}'
)"
response="$(
  curl --silent --show-error --max-time 30 \
    --header 'Content-Type: application/json' --data "${body}" \
    --write-out '\n%{http_code}' "${PREVIEWS}"
)" || die "could not reach ${PREVIEWS}"
code="${response##*$'\n'}"
body="${response%$'\n'*}"
detail="$(jq -r '.detail // empty | tostring' <<<"${body}" 2>/dev/null)" || detail="${body:0:300}"

case "${code}" in
  200) ;;
  401) die "Softlight wants a signed-in maker (${detail}); pushed ${ref} anyway" ;;
  403) die "Softlight won't preview ${owner}/${repo}: ${detail}" ;;
  *) die "${PREVIEWS} answered HTTP ${code}: ${detail}" ;;
esac

url="$(jq -r '.url // empty' <<<"${body}" 2>/dev/null)" || url=""
[[ -n ${url} ]] || die "${PREVIEWS} answered without a url: ${body:0:300}"
echo "${url}"
