#!/usr/bin/env bash
#
# Print the link to a pull request's Softlight walkthrough (its share page), or watch the share
# page and print each thing that happens on it.
#
#   get_walkthrough.sh [--wait[=SECONDS] | --watch[=SECONDS]] <pull request URL | owner/repo#number | number>
#
# A bare number is read against the current checkout's `origin` remote. With --wait, a pull
# request whose video is still being made is polled until the walkthrough is published, for at
# most SECONDS (default 900); use it right after opening or pushing to a pull request.
#
# With --watch, the share page is followed until Softlight's review of the pull request is over,
# for at most SECONDS (default 3600), and every event is printed on stdout, one line each, the
# moment it happens:
#   ready: <url>             the walkthrough is published at <url>
#   issue: [P0|P1|P2 ]<check>  a check on the share page found an issue (once per check)
#   complete: <summary>      the review is over; the summary counts the issues found
# Each line stands on its own, so the output can be streamed to whoever is waiting on it.
#
# Exit status:
#   0  the walkthrough URL is on stdout (with --watch: the review completed)
#   1  there is no walkthrough (yet), or (with --watch) the review stopped or ran out of time;
#      what happened is on stderr
#   2  bad input, or Softlight could not be read
#
# The link comes from the first of these that has it:
#   1. The Softlight check run on the pull request's head commit, whose details URL is the
#      walkthrough once it is published. Read with `gh`; skipped when gh is missing or signed out.
#   2. Softlight's status endpoint for the pull request, which needs no credentials.
#
# Requires curl, jq and awk. Set SOFTLIGHT_BASE_URL to point at another Softlight deployment.

set -euo pipefail

BASE_URL="${SOFTLIGHT_BASE_URL:-https://app.softlight.com}"
readonly BASE_URL="${BASE_URL%/}"
readonly USAGE="usage: get_walkthrough.sh [--wait[=SECONDS] | --watch[=SECONDS]] <pull request URL | owner/repo#number | number>"
readonly POLL_SECONDS=20

die() {
  echo "$*" >&2
  exit 2
}

no_walkthrough() {
  echo "$*" >&2
  exit 1
}

wait_seconds=0
watch=false
case "${1:-}" in
  -h | --help)
    sed -n '3,33s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  --wait)
    wait_seconds=900
    shift
    ;;
  --wait=*)
    wait_seconds="${1#--wait=}"
    [[ ${wait_seconds} =~ ^[0-9]+$ ]] || die "--wait takes a number of seconds: $1"
    shift
    ;;
  --watch)
    watch=true
    wait_seconds=3600
    shift
    ;;
  --watch=*)
    watch=true
    wait_seconds="${1#--watch=}"
    [[ ${wait_seconds} =~ ^[0-9]+$ ]] || die "--watch takes a number of seconds: $1"
    shift
    ;;
  *) ;;
esac
readonly wait_seconds watch
[[ $# -eq 1 && -n $1 ]] || die "${USAGE}"
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"
command -v awk >/dev/null || die "awk is required"

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

# --- Look it up ----------------------------------------------------------------------------------

# Sets `url` to the walkthrough and returns 0 once it is published. Returns 1 with the reason in
# `pending` while the video is still on its way, and exits for every answer that waiting won't
# change.
look_up() {
  local links link response code body parsed state

  # 1. The Softlight check run. Until the video is published, the check links to a signed /v/
  # address that opens a waiting page, so only a share page counts.
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
        url="${link}"
        return 0
      fi
    done <<<"${links}"
  fi

  # 2. The status endpoint.
  response="$(
    curl --silent --show-error --max-time 30 --retry 2 \
      --write-out '\n%{http_code}' "${WALKTHROUGH}/status"
  )" || die "could not reach ${WALKTHROUGH}/status"
  code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  case "${code}" in
    200) ;;
    3?? | 401) die "Softlight keeps ${owner}/${repo} behind sign-in, so its walkthrough link can't be looked up from here" ;;
    404) die "Softlight can't see ${owner}/${repo}#${number}; check that it exists and the Softlight app is installed on the repository" ;;
    *) die "${WALKTHROUGH}/status answered HTTP ${code}: ${body:0:300}" ;;
  esac

  parsed="$(jq -r '[.state // "unknown", .url // ""] | @tsv' <<<"${body}" 2>/dev/null)" \
    || die "${WALKTHROUGH}/status answered something other than JSON: ${body:0:300}"
  IFS=$'\t' read -r state url <<<"${parsed}"

  if [[ ${state} == ready && -n ${url} ]]; then
    return 0
  fi

  case "${state}" in
    queued) pending="queued: Softlight hasn't started on this pull request yet" ;;
    indexing) pending="indexing: Softlight is indexing the repository first" ;;
    running) pending="running: the review is running and the video isn't published yet" ;;
    video_only) no_walkthrough "video_only: the pull request plays a video in its description but has no share page" ;;
    merged) no_walkthrough "merged: the pull request merged without a walkthrough" ;;
    none) no_walkthrough "none: Softlight didn't film this pull request" ;;
    *)
      # "unknown" is also what the status endpoint says about a pull request GitHub won't show
      # Softlight. The waiting page tells the two apart: it 404s on those.
      code="$(curl --silent --max-time 30 --output /dev/null --write-out '%{http_code}' "${WALKTHROUGH}")" || code=""
      [[ ${code} != 404 ]] \
        || die "Softlight can't see ${owner}/${repo}#${number}; check that it exists and the Softlight app is installed on the repository"
      pending="${state}: Softlight couldn't say just now"
      ;;
  esac
  return 1
}

# --- Wait for it ----------------------------------------------------------------------------------

pending=""
deadline=$((SECONDS + wait_seconds))
url=""
until look_up; do
  if ((SECONDS + POLL_SECONDS > deadline)); then
    if ((wait_seconds > 0)); then
      no_walkthrough "${pending}; still not published after ${wait_seconds}s, run this again later"
    fi
    no_walkthrough "${pending}; run this again with --wait to wait for the video"
  fi
  sleep "${POLL_SECONDS}"
done

if ! ${watch}; then
  echo "${url}"
  exit 0
fi
echo "ready: ${url}"

# --- Watch the share page -------------------------------------------------------------------------

# The checks the share page lists (its #videos list, the same one the page counts its issues
# from), one per line: "<result>\t<check>", where the result is "passed", "running", or "issue"
# followed by the issue's level when it has one ("issue P1"). A check the page shows from a
# previous run, or one still being filmed, is running: its result isn't this run's yet.
page_checks() {
  awk '
    { page = page $0 " " }
    END {
      start = index(page, "<ol class=\"videos\" id=\"videos\">")
      if (!start) exit
      page = substr(page, start)
      stop = index(page, "</ol>")
      if (stop) page = substr(page, 1, stop - 1)
      n = split(page, rows, "<li")
      for (i = 2; i <= n; i++) {
        row = rows[i]
        check = row
        if (!sub(/.*<span class="lbl">/, "", check)) continue
        sub(/<\/span>.*/, "", check)
        gsub(/&lt;/, "<", check)
        gsub(/&gt;/, ">", check)
        gsub(/&quot;/, "\"", check)
        gsub(/&#x27;|&#39;/, "\047", check)
        gsub(/&amp;/, "\\&", check)
        # a check not filmed on the device the page shows is not one of its checks there
        if (row ~ /^[^>]*pd-off/) continue
        if (row ~ /^[^>]*(pending|prev|pd-run)/ || row ~ /class="mark spin/) {
          result = "running"
        } else if (row ~ /class="mark bad/) {
          result = "issue"
          if (match(row, /class="mark bad pri[^>]*>P[0-9]</)) {
            level = substr(row, RSTART, RLENGTH)
            sub(/.*>/, "", level)
            sub(/</, "", level)
            result = result " " level
          }
        } else {
          result = "passed"
        }
        print result "\t" check
      }
    }'
}

seen=$'\n'
while :; do
  # the review's own state, from the status the share page itself polls
  parsed="$(
    curl --silent --max-time 30 --retry 2 "${WALKTHROUGH}/status?rec=1" \
      | jq -r '[.state // "unknown", .run_status // "", .conclusion // "", .refresh // "", .title // ""] | join("|")' 2>/dev/null
  )" || parsed="unknown||||"
  IFS='|' read -r state run_status conclusion refresh title <<<"${parsed}"

  # the page's checks: print each issue the first time it shows
  checks="$(curl --silent --location --max-time 30 --retry 2 "${url}" | page_checks)" || checks=""
  issues=0
  running=false
  while IFS=$'\t' read -r result check; do
    case "${result}" in
      issue*)
        issues=$((issues + 1))
        level="${result#issue}"
        if [[ ${seen} != *$'\n'"${check}"$'\n'* ]]; then
          seen+="${check}"$'\n'
          echo "issue:${level} ${check}"
        fi
        ;;
      running) running=true ;;
      *) ;;
    esac
  done <<<"${checks}"

  # the review is over once its check has concluded and the page shows no check still running
  settled=false
  if [[ ${state} == ready ]] && ! ${running}; then
    if [[ -n ${run_status} ]]; then
      [[ ${run_status} != completed && ${run_status} != none ]] || settled=true
    elif [[ -z ${refresh} ]]; then
      settled=true
    fi
  fi
  if ${settled}; then
    if [[ ${title} == *Waiting* ]]; then
      no_walkthrough "stopped: Softlight is waiting until the pull request is ready for review"
    elif [[ ${title} == *Interrupted* ]]; then
      no_walkthrough "stopped: Softlight was interrupted before the checks finished"
    elif [[ ${title} == *Superseded* ]]; then
      no_walkthrough "stopped: a newer push replaced this run"
    elif [[ -n ${conclusion} && ${conclusion} != success && ${conclusion} != neutral ]] \
      && [[ ! ${title} =~ Complete|Not\ Needed|Up\ to\ Date ]]; then
      no_walkthrough "stopped: ${title:-Softlight stopped before the checks finished}"
    fi
    case "${issues}" in
      0) echo "complete: no issues found" ;;
      1) echo "complete: 1 issue found" ;;
      *) echo "complete: ${issues} issues found" ;;
    esac
    exit 0
  fi

  if ((SECONDS + POLL_SECONDS > deadline)); then
    no_walkthrough "the review is still running after ${wait_seconds}s; run this again with --watch to keep watching"
  fi
  sleep "${POLL_SECONDS}"
done
