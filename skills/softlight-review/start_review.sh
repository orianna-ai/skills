#!/usr/bin/env bash
#
# Push the local work to a Softlight challenge branch and have Softlight review it, no pull request.
#
#   start_review.sh [--base <rev>] [what to focus on]
#
# The work is pushed to origin as softlight/<nonce>, a new branch named after a random nonce.
# Uncommitted and untracked changes go with it (files .gitignore excludes stay behind): they are
# snapshotted into a commit on top of HEAD without touching the local branch, the index or the
# working tree. Softlight reviews the change from the base to that branch the way it reviews a pull
# request, as a dry run that posts nothing, and the nonce only the pusher knows is what shows
# Softlight the request comes from someone who can push to the repository. Without --base, the
# base is:
#
#   on a feature branch   where it forked from origin's default branch
#   on the default branch with unpushed commits: where it forked from origin's copy
#                         with only uncommitted changes: HEAD
#                         otherwise: the parent of the run of commits at the tip by user.email
#
# Exit status:
#   0  Softlight took the request; the review's page, which shows it once it's done, is on stdout
#   2  bad input, nothing to review, the push failed, or Softlight refused or could not be reached
#
# Requires git, curl and jq. Set SOFTLIGHT_BASE_URL to point at another Softlight deployment.

set -euo pipefail

BASE_URL="${SOFTLIGHT_BASE_URL:-https://app.softlight.com}"
readonly BASE_URL="${BASE_URL%/}"
readonly USAGE="usage: start_review.sh [--base <rev>] [what to focus on]"
# how far back the look-back on the default branch goes
readonly LOOK_BACK=100

die() {
  echo "$*" >&2
  exit 2
}

base_rev="" request=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      sed -n '3,24s/^# \{0,1\}//p' "$0"
      exit 0
      ;;
    --base)
      [[ $# -ge 2 ]] || die "${USAGE}"
      base_rev="$2"
      shift 2
      ;;
    --base=*)
      base_rev="${1#--base=}"
      shift
      ;;
    -*) die "${USAGE}" ;;
    *)
      [[ -z ${request} ]] || die "${USAGE}"
      request="$1"
      shift
      ;;
  esac
done
readonly request
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

branch="$(git symbolic-ref --quiet --short HEAD)" || branch=""
readonly branch

if default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)"; then
  default="${default#origin/}"
else
  default="$(git ls-remote --symref origin HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\(.*\)\tHEAD$|\1|p')"
fi
[[ -n ${default} ]] || die "couldn't tell origin's default branch; pass --base"
readonly default
git fetch --quiet origin "refs/heads/${default}:refs/remotes/origin/${default}" 2>/dev/null || true
upstream="$(git rev-parse --verify --quiet "refs/remotes/origin/${default}^{commit}")" || upstream=""
readonly upstream

dirty=""
[[ -z "$(git -C "${top}" status --porcelain)" ]] || dirty=1
readonly dirty

# --- What to compare against ----------------------------------------------------------------------

merge_base() {
  [[ -n ${upstream} ]] || die "origin/${default} isn't fetched; pass --base"
  git merge-base "${head}" "${upstream}" || die "${branch:-HEAD} shares no history with origin/${default}; pass --base"
}

if [[ -n ${base_rev} ]]; then
  base="$(git rev-parse --verify --quiet "${base_rev}^{commit}")" || die "no such commit: ${base_rev}"
  why="${base_rev}"
elif [[ -n ${branch} && ${branch} != "${default}" ]]; then
  base="$(merge_base)"
  why="where ${branch} forked from ${default}"
elif [[ -n ${upstream} ]] && ! git merge-base --is-ancestor "${head}" "${upstream}"; then
  base="$(merge_base)"
  why="origin/${default}, before the commits not pushed yet"
elif [[ -n ${dirty} ]]; then
  base="${head}"
  why="HEAD, before the uncommitted changes"
else
  # Everything is pushed: take the run of commits at the tip that are the user's own.
  email="$(git config --get user.email | tr "[:upper:]" "[:lower:]")" || die "everything on ${default} is pushed and user.email is unset; pass --base"
  base="" count=0
  while read -r sha author; do
    [[ ${author} == "${email}" ]] || break
    count=$((count + 1))
    base="$(git rev-parse --verify --quiet "${sha}^")" || die "the look-back reached the root commit; pass --base"
  done < <(git log --first-parent --max-count="${LOOK_BACK}" --format='%H %ae' "${head}" | tr "[:upper:]" "[:lower:]")
  [[ -n ${base} ]] || die "the last commit on ${default} isn't by ${email}; pass --base"
  why="before the last ${count} commit(s) on ${default} by ${email}"
fi
readonly base why

# --- What to review -------------------------------------------------------------------------------

# A scratch index keeps the snapshot from touching the real one.
sha="${head}"
if [[ -n ${dirty} ]]; then
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
  sha="$(git commit-tree "${tree}" -p "${head}" -m "Uncommitted changes on ${branch:-${head:0:12}}")"
fi
readonly sha

git merge-base --is-ancestor "${base}" "${sha}" || die "${base:0:12} isn't an ancestor of the work; pass a --base it grew from"
[[ "$(git rev-parse "${base}^{tree}")" != "$(git rev-parse "${sha}^{tree}")" ]] \
  || die "nothing to review: the work is the same as ${base:0:12} (${why})"

# --- Push the challenge branch --------------------------------------------------------------------

# The base is an ancestor of the work, so pushing the work puts the base on origin too.
nonce="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
readonly nonce
readonly ref="refs/heads/softlight/${nonce}"
git push --quiet origin "${sha}:${ref}" || die "couldn't push ${ref} to origin"

# --- Ask Softlight to review it -------------------------------------------------------------------

readonly REVIEWS="${BASE_URL}/api/branch-reviews"
body="$(
  jq -n --arg repository "${owner}/${repo}" --arg ref "${ref}" --arg base "${base}" \
    --arg request "${request:0:4000}" \
    '{repository: $repository, ref: $ref, base: $base, request: $request}'
)"
response="$(
  curl --silent --show-error --max-time 30 \
    --header 'Content-Type: application/json' --data "${body}" \
    --write-out '\n%{http_code}' "${REVIEWS}"
)" || die "could not reach ${REVIEWS}"
code="${response##*$'\n'}"
body="${response%$'\n'*}"
detail="$(jq -r '.detail // empty | tostring' <<<"${body}" 2>/dev/null)" || detail="${body:0:300}"

case "${code}" in
  200) ;;
  401) die "Softlight wants a signed-in maker (${detail}); pushed ${ref} anyway" ;;
  403) die "Softlight won't review ${owner}/${repo}: ${detail}" ;;
  *) die "${REVIEWS} answered HTTP ${code}: ${detail}" ;;
esac

url="$(jq -r '.url // empty' <<<"${body}" 2>/dev/null)" || url=""
[[ -n ${url} ]] || die "${REVIEWS} answered without a url: ${body:0:300}"
echo "Comparing against ${base:0:12}: ${why}" >&2
echo "${url}"
