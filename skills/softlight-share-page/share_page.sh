#!/usr/bin/env bash
# Print the Softlight share page for a pull request.
#
#   share_page.sh <pr>
#
# <pr> is a pull request URL (https://github.com/<owner>/<repo>/pull/<n>), <owner>/<repo>#<n>, or a
# bare number (the repository is then read from the current checkout's `origin` remote).
#
# Prints the share page URL on stdout and exits 0 when the pull request has one. Otherwise prints
# what Softlight says about the pull request on stderr and exits 1 (no share page yet) or 2 (bad
# input or nothing could be read).
#
# Two sources, in order:
#   1. The Softlight check run on the pull request's head commit. Its details_url is the share page
#      once one is published (needs `gh`, authenticated; skipped when it isn't available).
#   2. Softlight's status endpoint for the pull request's permanent walkthrough link, which answers
#      with the walkthrough's state and, when it is ready, the share page.
set -euo pipefail

SOFTLIGHT_BASE_URL="${SOFTLIGHT_BASE_URL:-https://app.softlight.com}"

die() {
  echo "$*" >&2
  exit 2
}

[[ $# -eq 1 ]] || die "usage: share_page.sh <pull request URL | owner/repo#number | number>"
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"

pr="$1"
if [[ "$pr" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
elif [[ "$pr" =~ ^([^/#[:space:]]+)/([^/#[:space:]]+)#([0-9]+)$ ]]; then
  owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
elif [[ "$pr" =~ ^#?([0-9]+)$ ]]; then
  number="${BASH_REMATCH[1]}"
  remote="$(git remote get-url origin 2>/dev/null)" ||
    die "a bare number needs a git checkout with an origin remote; pass owner/repo#$number"
  [[ "$remote" =~ github\.com[:/]([^/]+)/([^/]+)$ ]] ||
    die "origin ($remote) is not a GitHub repository; pass owner/repo#$number"
  owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]%.git}"
else
  die "not a pull request: $pr"
fi

# A share page is the console's demo page for exactly this pull request, or an immutable drive page.
is_share_page() {
  local lower_owner lower_repo
  lower_owner="$(tr '[:upper:]' '[:lower:]' <<<"$owner")"
  lower_repo="$(tr '[:upper:]' '[:lower:]' <<<"$repo")"
  [[ "$1" == "$SOFTLIGHT_BASE_URL/demo/$lower_owner/$lower_repo/pr$number/"* ]] ||
    [[ "$1" =~ ^https://drive\.softlight\.com/ ]]
}

# 1. The Softlight check run. Until the share page exists its details_url is a signed short link
#    (/v/...) that opens the waiting page, so only a share page counts here.
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  if sha="$(gh api "repos/$owner/$repo/pulls/$number" --jq .head.sha 2>/dev/null)"; then
    link="$(
      gh api "repos/$owner/$repo/commits/$sha/check-runs?per_page=100" --jq '
        [.check_runs[] | select(.name == "Softlight Review" or (.name | startswith("Softlight video")))]
        | sort_by(.started_at) | last | .details_url // empty' 2>/dev/null || true
    )"
    if [[ -n "$link" ]] && is_share_page "$link"; then
      echo "$link"
      exit 0
    fi
  fi
fi

# 2. The status endpoint.
status_url="$SOFTLIGHT_BASE_URL/api/softlight/walkthrough/$owner/$repo/$number/status"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
code="$(curl -sS -m 30 -o "$tmp" -w '%{http_code}' "$status_url")" || die "could not reach $status_url"
body="$(cat "$tmp")"

case "$code" in
  200) ;;
  401) die "Softlight keeps $owner/$repo behind sign-in; open $SOFTLIGHT_BASE_URL/api/softlight/walkthrough/$owner/$repo/$number in a browser signed in to Softlight" ;;
  404) die "Softlight does not know $owner/$repo#$number (is the Softlight app installed on the repository?)" ;;
  *) die "$status_url answered HTTP $code: $body" ;;
esac

state="$(jq -r '.state // "unknown"' <<<"$body")"
url="$(jq -r '.url // empty' <<<"$body")"
if [[ -n "$url" ]]; then
  echo "$url"
  exit 0
fi

permanent="$SOFTLIGHT_BASE_URL/api/softlight/walkthrough/$owner/$repo/$number"
case "$state" in
  queued) echo "queued: Softlight has not started on this pull request yet. Waiting page: $permanent" >&2 ;;
  indexing) echo "indexing: Softlight is indexing the repository. Waiting page: $permanent" >&2 ;;
  running) echo "running: the review is in progress and the video is not published yet. Waiting page: $permanent" >&2 ;;
  video_only) echo "video_only: the pull request plays a walkthrough but has no share page" >&2 ;;
  merged) echo "merged: the pull request merged without a walkthrough" >&2 ;;
  none) echo "none: Softlight did not publish a walkthrough for this pull request" >&2 ;;
  *) echo "$state: Softlight could not say right now; try again shortly" >&2 ;;
esac
exit 1
