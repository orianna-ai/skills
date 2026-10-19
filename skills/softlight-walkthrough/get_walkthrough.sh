#!/usr/bin/env bash
#
# Print the link to a pull request's Softlight walkthrough (its share page).
#
#   get_walkthrough.sh <pull request URL | owner/repo#number | number>
#
# A bare number is read against the current checkout's `origin` remote.
#
# Exit status:
#   0  the walkthrough URL is on stdout
#   1  there is no walkthrough yet; its state and what that means are on stderr
#   2  bad input, or Softlight could not be read
#
# The link comes from the first of these that has it:
#   1. The Softlight check run on the pull request's head commit, whose details URL is the
#      walkthrough once it is published. Read with `gh`; skipped when gh is missing or signed out.
#   2. Softlight's status endpoint for the pull request, which needs no credentials.
#
# Requires curl and jq. Set SOFTLIGHT_BASE_URL to point at another Softlight deployment.

set -euo pipefail

BASE_URL="${SOFTLIGHT_BASE_URL:-https://app.softlight.com}"
readonly BASE_URL="${BASE_URL%/}"
readonly USAGE="usage: get_walkthrough.sh <pull request URL | owner/repo#number | number>"

die() {
  echo "$*" >&2
  exit 2
}

no_walkthrough() {
  echo "$*" >&2
  exit 1
}

case "${1:-}" in
  -h | --help)
    sed -n '3,19s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  "") die "${USAGE}" ;;
  *) ;;
esac
[[ $# -eq 1 ]] || die "${USAGE}"
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"

# --- Which pull request ---------------------------------------------------------------------------

readonly NAME='[A-Za-z0-9_.-]+'
if [[ $1 =~ ^https://(www\.)?github\.com/(${NAME})/(${NAME})/pull/([0-9]+)([/?#].*)?$ ]]; then
  owner="${BASH_REMATCH[2]}" repo="${BASH_REMATCH[3]}" number="${BASH_REMATCH[4]}"
elif [[ $1 =~ ^(${NAME})/(${NAME})#([0-9]+)$ ]]; then
  owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
elif [[ $1 =~ ^#?([0-9]+)$ ]]; then
  number="${BASH_REMATCH[1]}"
  remote="$(git remote get-url origin 2>/dev/null)" \
    || die "${number} needs a checkout with an origin remote; pass owner/repo#${number} instead"
  [[ ${remote} =~ github\.com[:/](${NAME})/(${NAME})$ ]] \
    || die "origin (${remote}) is not on GitHub; pass owner/repo#${number} instead"
  owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]%.git}"
else
  die "not a pull request: $1"$'\n'"${USAGE}"
fi
readonly owner repo number

readonly WALKTHROUGH="${BASE_URL}/api/softlight/walkthrough/${owner}/${repo}/${number}"
# The share page's path, lowercased the way Softlight mints it.
share_prefix="${BASE_URL}/demo/$(tr '[:upper:]' '[:lower:]' <<<"${owner}/${repo}")/pr${number}/"
readonly share_prefix

# --- 1. The Softlight check run -------------------------------------------------------------------

# Until the video is published, the check links to a signed /v/ address that opens the waiting page,
# so only a share page counts.
if command -v gh >/dev/null; then
  links="$(
    gh pr view "${number}" --repo "${owner}/${repo}" --json statusCheckRollup --jq '
      .statusCheckRollup[]
      | select(.__typename == "CheckRun")
      | select(.name == "Softlight Review" or (.name | startswith("Softlight video")))
      | .detailsUrl // empty' 2>/dev/null
  )" || links=""
  while IFS= read -r link; do
    if [[ ${link} == "${share_prefix}"* ]]; then
      echo "${link}"
      exit 0
    fi
  done <<<"${links}"
fi

# --- 2. The status endpoint -----------------------------------------------------------------------

response="$(
  curl --silent --show-error --max-time 30 --retry 2 \
    --write-out '\n%{http_code}' "${WALKTHROUGH}/status"
)" || die "could not reach ${WALKTHROUGH}/status"
code="${response##*$'\n'}"
body="${response%$'\n'*}"

case "${code}" in
  200) ;;
  3??) die "Softlight asked for a sign-in; open ${WALKTHROUGH} in a browser signed in to Softlight" ;;
  401) die "Softlight keeps ${owner}/${repo} behind sign-in; open ${WALKTHROUGH} in a browser signed in to Softlight" ;;
  404) die "Softlight can't see ${owner}/${repo}#${number}; check that it exists and the Softlight app is installed on the repository" ;;
  *) die "${WALKTHROUGH}/status answered HTTP ${code}: ${body:0:300}" ;;
esac

parsed="$(jq -r '[.state // "unknown", .url // ""] | @tsv' <<<"${body}" 2>/dev/null)" \
  || die "${WALKTHROUGH}/status answered something other than JSON: ${body:0:300}"
IFS=$'\t' read -r state url <<<"${parsed}"

if [[ ${state} == ready && -n ${url} ]]; then
  echo "${url}"
  exit 0
fi

case "${state}" in
  queued) no_walkthrough "queued: Softlight hasn't started on this pull request yet. Waiting page: ${WALKTHROUGH}" ;;
  indexing) no_walkthrough "indexing: Softlight is indexing the repository first. Waiting page: ${WALKTHROUGH}" ;;
  running) no_walkthrough "running: the review is running and the video isn't published yet. Waiting page: ${WALKTHROUGH}" ;;
  video_only) no_walkthrough "video_only: the pull request plays a video in its description but has no share page" ;;
  merged) no_walkthrough "merged: the pull request merged without a walkthrough" ;;
  none) no_walkthrough "none: Softlight didn't film this pull request" ;;
  *) ;;
esac

# "unknown" is also what the status endpoint says about a pull request GitHub won't show Softlight.
# The waiting page tells the two apart: it 404s on those.
code="$(curl --silent --max-time 30 --output /dev/null --write-out '%{http_code}' "${WALKTHROUGH}")" || code=""
case "${code}" in
  404) die "Softlight can't see ${owner}/${repo}#${number}; check that it exists and the Softlight app is installed on the repository" ;;
  *) no_walkthrough "${state}: Softlight couldn't say just now; try again in a few seconds" ;;
esac
