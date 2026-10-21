#!/usr/bin/env bash
#
# Push the local work and open a throwaway draft pull request that Softlight reviews.
#
#   open_review.sh [--base <rev>] [--ready] [what to focus on]
#
# Softlight reviews pull requests, so this pushes two branches to origin and opens one into the
# other: softlight/<nonce> holds the work (uncommitted and untracked changes included, snapshotted
# into a commit on top of HEAD without touching the local branch, the index or the working tree) and
# softlight/<nonce>-base holds the commit it is compared against. Without --base, the base is:
#
#   on a feature branch   where it forked from origin's default branch
#   on the default branch with unpushed commits: where it forked from origin's copy
#                         with only uncommitted changes: HEAD
#                         otherwise: the parent of the run of commits at the tip by user.email
#
# --ready opens the pull request ready for review instead of as a draft.
#
# Exit status:
#   0  the pull request is open; its URL and its Softlight walkthrough page are on stdout
#   2  bad input, nothing to review, the push failed, or GitHub refused the pull request
#
# Requires git and gh (signed in). Set SOFTLIGHT_BASE_URL to point at another Softlight deployment.

set -euo pipefail

BASE_URL="${SOFTLIGHT_BASE_URL:-https://app.softlight.com}"
readonly BASE_URL="${BASE_URL%/}"
readonly USAGE="usage: open_review.sh [--base <rev>] [--ready] [what to focus on]"
# how far back the look-back on the default branch goes
readonly LOOK_BACK=100

die() {
  echo "$*" >&2
  exit 2
}

base_rev="" request=""
draft=(--draft)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      sed -n '3,25s/^# \{0,1\}//p' "$0"
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
    --ready)
      draft=()
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
readonly draft request
command -v git >/dev/null || die "git is required"
command -v gh >/dev/null || die "gh is required"

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
commits="$(git rev-list --count "${base}..${sha}")"
readonly commits

# --- Push both branches ---------------------------------------------------------------------------

nonce="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
readonly nonce
readonly head_branch="softlight/${nonce}" base_branch="softlight/${nonce}-base"
git push --quiet --atomic origin "${sha}:refs/heads/${head_branch}" "${base}:refs/heads/${base_branch}" \
  || die "couldn't push ${head_branch} and ${base_branch} to origin"

# --- Open the pull request ------------------------------------------------------------------------

title="Softlight review: ${branch:-${head:0:12}} ($(git log -1 --format=%s "${head}"))"
body="$(
  cat <<EOF
A throwaway pull request so Softlight reviews local work. Don't merge it: close it when you're done,
and delete \`${base_branch}\`.

- **Work:** \`${branch:-${head:0:12}}\` at \`${head:0:12}\`${dirty:+ plus uncommitted changes}
- **Compared against:** \`${base:0:12}\`, ${why} (${commits} commit(s))
${request:+
${request:0:4000}}
EOF
)"
url="$(
  gh pr create --repo "${owner}/${repo}" ${draft[@]+"${draft[@]}"} \
    --base "${base_branch}" --head "${head_branch}" --title "${title:0:250}" --body "${body}"
)" || {
  git push --quiet origin --delete "${head_branch}" "${base_branch}" || true
  die "GitHub wouldn't open the pull request; removed ${head_branch} and ${base_branch}"
}
url="$(tail -n1 <<<"${url}")"
[[ ${url} =~ /pull/([0-9]+)$ ]] || die "gh answered without a pull request URL: ${url}"
echo "${url}"
echo "${BASE_URL}/api/softlight/walkthrough/${owner}/${repo}/${BASH_REMATCH[1]}"
