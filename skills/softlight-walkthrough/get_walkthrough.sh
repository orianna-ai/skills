#!/usr/bin/env bash
#
# Print the link to a pull request's Softlight walkthrough, or follow its review.
#
#   get_walkthrough.sh [--wait[=SECONDS] | --watch[=SECONDS]] <PR URL | owner/repo#number | number>
#
#   (no flag)  print the /demo/ link if it's published, else exit 1
#   --wait     poll until it's published, for at most SECONDS (default 900)
#   --watch    follow the review for at most SECONDS (default 3600), one line per event:
#                ready: <url>
#                commit: <sha>
#                issue: [P0|P1|P2 ][<device> ]— <check>[ — <finding>] (on <sha>)
#                complete: <N> issues found, <P> of <M> checks passed[ (<K> not offered on a device, counted as passed)] (on <sha>)
#
# A bare number is read against the checkout's origin remote.
#
# Exit status:
#   0  the link is on stdout (with --watch: the review completed)
#   1  no walkthrough or result yet; stderr is "<state>: <why>", with state one of queued,
#      indexing, running, video_only, merged, none, unknown or stopped
#   2  bad input, a pull request Softlight can't see, or Softlight unreachable
#
# Requires curl, jq and awk; reads the check run with gh when it's signed in.

set -euo pipefail

readonly BASE_URL="https://app.softlight.com"
readonly USAGE="usage: get_walkthrough.sh [--wait[=SECONDS] | --watch[=SECONDS]] <pull request URL | owner/repo#number | number>"
readonly POLL_SECONDS=20
readonly MAX_FAILED_PAGE_READS=5
readonly FIELD_SEPARATOR=$'\037'

die() {
  echo "$*" >&2
  exit 2
}

no_walkthrough() {
  echo "$*" >&2
  exit 1
}

watch=false
wait_seconds=0
case "${1:-}" in
  -h | --help)
    awk 'NR > 2 && !/^#/ { exit } NR > 2 { sub(/^# ?/, ""); print }' "$0"
    exit 0
    ;;
  --wait)
    wait_seconds=900
    shift
    ;;
  --watch)
    watch=true
    wait_seconds=3600
    shift
    ;;
  --wait=* | --watch=*)
    [[ $1 != --watch=* ]] || watch=true
    wait_seconds="${1#*=}"
    [[ ${wait_seconds} =~ ^[0-9]+$ ]] || die "${1%%=*} takes a number of seconds: $1"
    shift
    ;;
  *) ;;
esac
readonly watch wait_seconds

[[ $# -eq 1 && -n $1 ]] || die "${USAGE}"
for tool in curl jq awk; do
  command -v "${tool}" >/dev/null || die "${tool} is required"
done

readonly NAME='[A-Za-z0-9_.-]+'
if [[ $1 =~ ^https://(www\.)?github\.com/(${NAME})/(${NAME})/pull/([0-9]+)([/?#].*)?$ ]]; then
  owner="${BASH_REMATCH[2]}" repo="${BASH_REMATCH[3]}" number="${BASH_REMATCH[4]}"
elif [[ $1 =~ ^(${NAME})/(${NAME})#([0-9]+)$ ]]; then
  owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
elif [[ $1 =~ ^#?([0-9]+)$ ]]; then
  number="${BASH_REMATCH[1]}"
  remote="$(git remote get-url origin 2>/dev/null)" \
    || die "${number} needs a checkout with an origin remote; pass owner/repo#${number} instead"
  [[ ${remote%/} =~ [:/](${NAME})/(${NAME})$ ]] \
    || die "can't tell the repository from origin (${remote/\/\/*@/\/\/}); pass owner/repo#${number} instead"
  owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]%.git}"
else
  die "not a pull request: $1"$'\n'"${USAGE}"
fi
readonly owner repo number

readonly STATUS_URL="${BASE_URL}/api/softlight/walkthrough/${owner}/${repo}/${number}/status"
readonly WAITING_PAGE_URL="${BASE_URL}/api/softlight/walkthrough/${owner}/${repo}/${number}"
SHARE_URL_PREFIX="${BASE_URL}/demo/$(tr '[:upper:]' '[:lower:]' <<<"${owner}/${repo}")/pr${number}/"
readonly SHARE_URL_PREFIX
readonly NOT_VISIBLE="Softlight can't see ${owner}/${repo}#${number}; check that it exists and the Softlight app is installed on the repository"

link_from_check_run() {
  local check_link

  command -v gh >/dev/null || return 1
  while IFS= read -r check_link; do
    if [[ ${check_link} == "${SHARE_URL_PREFIX}"* ]]; then
      url="${check_link}"
      return 0
    fi
  done < <(
    gh pr view "${number}" --repo "${owner}/${repo}" --json statusCheckRollup --jq '
      .statusCheckRollup[]
      | select(.__typename == "CheckRun")
      | select(.name == "Softlight Review" or (.name | startswith("Softlight video")))
      | .detailsUrl // empty' 2>/dev/null || true
  )
  return 1
}

link_from_status() {
  local response http_code body parsed state

  response="$(curl --silent --show-error --max-time 30 --retry 2 --write-out '\n%{http_code}' "${STATUS_URL}")" \
    || die "could not reach ${STATUS_URL}"
  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  case "${http_code}" in
    200) ;;
    3?? | 401) die "Softlight keeps ${owner}/${repo} behind sign-in, so its walkthrough link can't be looked up from here" ;;
    404) die "${NOT_VISIBLE}" ;;
    *) die "${STATUS_URL} answered HTTP ${http_code}: ${body:0:300}" ;;
  esac

  parsed="$(jq -r '[.state // "unknown", .url // ""] | @tsv' <<<"${body}" 2>/dev/null)" \
    || die "${STATUS_URL} answered something other than JSON: ${body:0:300}"
  IFS=$'\t' read -r state url <<<"${parsed}"
  [[ ${state} != ready || -z ${url} ]] || return 0

  case "${state}" in
    queued) not_ready_reason="queued: Softlight hasn't started on this pull request yet" ;;
    indexing) not_ready_reason="indexing: Softlight is indexing the repository first" ;;
    running) not_ready_reason="running: the review is running and the video isn't published yet" ;;
    video_only) no_walkthrough "video_only: the pull request plays a video in its description but has no share page" ;;
    merged) no_walkthrough "merged: the pull request merged before the video finished recording, so there is no walkthrough" ;;
    none) no_walkthrough "none: Softlight didn't film this pull request" ;;
    *)
      [[ $(curl --silent --max-time 30 --output /dev/null --write-out '%{http_code}' "${WAITING_PAGE_URL}") != 404 ]] \
        || die "${NOT_VISIBLE}"
      not_ready_reason="${state}: Softlight couldn't say just now"
      ;;
  esac
  return 1
}

url=""
not_ready_reason=""
deadline=$((SECONDS + wait_seconds))
until link_from_check_run || link_from_status; do
  if ((SECONDS + POLL_SECONDS > deadline)); then
    ((wait_seconds == 0)) || no_walkthrough "${not_ready_reason}; still not published after ${wait_seconds}s, run this again later"
    no_walkthrough "${not_ready_reason}; run this again with --wait to wait for the video"
  fi
  sleep "${POLL_SECONDS}"
done

if ! ${watch}; then
  echo "${url}"
  exit 0
fi
echo "ready: ${url}"

share_page_results() {
  awk -v sep="${FIELD_SEPARATOR}" '
    function text(s) {
      gsub(/<[^>]*>/, "", s)
      gsub(/&lt;/, "<", s)
      gsub(/&gt;/, ">", s)
      gsub(/&quot;/, "\"", s)
      gsub(/&#x27;|&#39;/, "\047", s)
      gsub(/&amp;/, "\\&", s)
      gsub("[\t" sep " ]+", " ", s)
      sub(/^ /, "", s)
      sub(/ $/, "", s)
      return s
    }

    function attr(tag, name) {
      if (!match(tag, name "=\"[^\"]*\"")) return ""
      return substr(tag, RSTART + length(name) + 2, RLENGTH - length(name) - 3)
    }

    function before(s, marker,    at) {
      at = index(s, marker)
      return at ? substr(s, 1, at - 1) : s
    }

    function emit(result, device, check, finding) {
      print result sep device sep check sep finding
    }

    { page = page $0 " " }

    END {
      film_count = split(page, film_sections, "<section class=\"take")
      film = -1
      for (k = 2; k <= film_count; k++) {
        film_html = film_sections[k]
        if (!match(film_html, /^[^"]*"/)) continue
        classes = substr(film_html, 1, RLENGTH - 1)
        if (classes != "" && substr(classes, 1, 1) != " ") continue
        if ((classes " ") ~ / more /) continue
        film++

        film_html = before(film_html, "</section>")
        box_at = index(film_html, "<div class=\"devices\"")
        if (!box_at) continue
        box_tag = substr(film_html, box_at)
        box_tag = substr(box_tag, 1, index(box_tag, ">"))
        own_device[film] = attr(box_tag, "data-own")

        device_spans = before(substr(film_html, box_at + length(box_tag)), "<div")
        device_count[film] = 0
        while (match(device_spans, /<span class="device[^>]*>/)) {
          span = substr(device_spans, RSTART, RLENGTH)
          device_spans = substr(device_spans, RSTART + RLENGTH)
          device = attr(span, "data-device")
          device_of[film, ++device_count[film]] = device
          span_class = attr(span, "class")
          if (span_class ~ /running/) verdict = "running"
          else if (span_class ~ /unchecked/) verdict = "unchecked"
          else if (span_class ~ /not-offered/) verdict = "not_offered"
          else verdict = attr(span, "data-verdict")
          verdict_of[film, device] = verdict
          priority_of[film, device] = attr(span, "data-priority")
          if (verdict != "unchecked" && verdict != "not_offered") {
            filmed_devices[device] = 1
            page_has_filmed_device = 1
          }
        }

        depth = 0
        rest = film_html
        while (match(rest, /<div[ >][^>]*>|<\/div>|<p class="fix-title">[^<]*/)) {
          token = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          if (token == "</div>") {
            if (depth > 0) depth--
          } else if (token ~ /^<div/) {
            div_kind[++depth] = ""
            if (token ~ /class="devices"/) div_kind[depth] = "box"
            else if (token ~ /class="variant/) div_kind[depth] = "v:" attr(token, "data-device")
          } else {
            device = own_device[film]
            for (j = depth; j >= 1; j--) {
              if (div_kind[j] ~ /^v:/) { device = substr(div_kind[j], 3); break }
              if (div_kind[j] == "box") { device = ""; break }
            }
            sub(/<p class="fix-title">/, "", token)
            if (device != "" && !((film, device) in title)) title[film, device] = text(token)
          }
        }
      }

      list_at = index(page, "<ol class=\"videos\" id=\"videos\">")
      if (!list_at) exit
      row_count = split(before(substr(page, list_at), "</ol>"), rows, "<li")
      for (i = 2; i <= row_count; i++) {
        row = rows[i]
        check = row
        if (!sub(/.*<span class="lbl">/, "", check)) continue
        check = text(before(check, "</span>"))
        film = match(row, /data-take="[0-9]+"/) ? substr(row, RSTART + 11, RLENGTH - 12) + 0 : -1

        if (row ~ /^[^>]*(pending|prev|pd-run)/ || row ~ /class="mark spin/) {
          emit("running", "", check, "")
          continue
        }

        if (film in device_count) {
          for (j = 1; j <= device_count[film]; j++) {
            device = device_of[film, j]
            verdict = verdict_of[film, device]
            if (!(device in filmed_devices) || verdict == "unchecked" || verdict == "withheld") continue
            if (verdict == "running" || verdict == "not_offered") result = verdict
            else if (verdict == "finding") result = "issue" (priority_of[film, device] != "" ? " " priority_of[film, device] : "")
            else result = "passed"
            emit(result, device, check, title[film, device])
          }
          continue
        }

        if (page_has_filmed_device && film >= 0) continue
        if (row ~ /^[^>]*pd-off/) continue
        result = "passed"
        if (row ~ /class="mark bad/) {
          result = "issue"
          if (match(row, /class="mark bad pri[^>]*>P[0-9]</)) result = result " " substr(row, RSTART + RLENGTH - 3, 2)
        }
        emit(result, "", check, film >= 0 ? title[film, own_device[film]] : "")
      }
    }'
}

readonly PAGE_COMMIT_META='<meta name="softlight-head" content="([0-9a-fA-F]+)"'
readonly PAGE_ID_META='<meta name="softlight-page-id" content="([0-9a-fA-F]+)"'

commit=""
reported_issues=$'\n'
failed_page_reads=0
while :; do
  status="$(
    curl --silent --max-time 30 --retry 2 "${STATUS_URL}?rec=1" | jq -r '[
      .state // "unknown", .run_status // "", .conclusion // "", .refresh // "", .title // "",
      .pr_state // "", (.run_head // .head // ""), .page_id // "", .head // "", .rides // ""
    ] | join("|")' 2>/dev/null
  )" || status="unknown|||||||||"
  IFS='|' read -r state run_status conclusion refresh title pr_state checked_commit served_page_id pr_head reused_review_commit <<<"${status}"
  checked_commit="${checked_commit:0:7}"
  pr_head="${pr_head:0:7}"
  reused_review_commit="${reused_review_commit:0:7}"
  pr_finished=false
  [[ ${pr_state} != merged && ${pr_state} != closed ]] || pr_finished=true

  page_html="$(curl --silent --fail --location --compressed --max-time 30 --retry 2 "${url}")" || page_html=""
  if [[ ${page_html} == *'<ol class="videos" id="videos">'* ]]; then
    failed_page_reads=0
  elif ((++failed_page_reads >= MAX_FAILED_PAGE_READS)); then
    die "could not read the share page at ${url} ${failed_page_reads} times in a row, so the review's results are unknown"
  fi
  page_commit=""
  page_id=""
  if [[ ${page_html} =~ ${PAGE_COMMIT_META} ]]; then page_commit="${BASH_REMATCH[1]:0:7}"; fi
  if [[ ${page_html} =~ ${PAGE_ID_META} ]]; then page_id="${BASH_REMATCH[1]}"; fi

  if [[ -n ${checked_commit} && ${checked_commit} != "${commit}" ]]; then
    commit="${checked_commit}"
    echo "commit: ${commit}"
  fi

  page_is_reused_review=false
  [[ -z ${reused_review_commit} || ${page_commit} != "${reused_review_commit}" ]] || page_is_reused_review=true
  page_is_stale=false
  newer_push_pending=false
  if ! ${page_is_reused_review} && [[ -n ${page_commit} ]]; then
    [[ -z ${checked_commit} || ${checked_commit} == "${page_commit}" ]] || page_is_stale=true
    [[ -z ${pr_head} || ${pr_head} == "${page_commit}" ]] || ${pr_finished} || newer_push_pending=true
  fi
  [[ -z ${served_page_id} || -z ${page_id} || ${served_page_id} == "${page_id}" ]] || page_is_stale=true

  issues=0
  passed=0
  not_offered=0
  still_running=${page_is_stale}
  ((failed_page_reads == 0)) || still_running=true
  if ! ${page_is_stale}; then
    while IFS="${FIELD_SEPARATOR}" read -r result device check finding; do
      case "${result}" in
        issue*)
          issues=$((issues + 1))
          issue_key="${commit}|${device}|${check}"
          if [[ ${reported_issues} != *$'\n'"${issue_key}"$'\n'* ]]; then
            reported_issues+="${issue_key}"$'\n'
            echo "issue:${result#issue}${device:+ ${device}} — ${check}${finding:+ — ${finding}}${commit:+ (on ${commit})}"
          fi
          ;;
        passed) passed=$((passed + 1)) ;;
        not_offered) passed=$((passed + 1)) not_offered=$((not_offered + 1)) ;;
        running) still_running=true ;;
        *) ;;
      esac
    done < <(share_page_results <<<"${page_html}" || true)
  fi

  run_concluded=false
  if [[ -n ${run_status} ]]; then
    [[ ${run_status} != completed && ${run_status} != none ]] || run_concluded=true
  elif [[ -z ${refresh} ]]; then
    run_concluded=true
  fi

  if [[ ${state} == ready && ${title} != *Superseded* ]] && ${run_concluded} && ! ${newer_push_pending} \
    && ((failed_page_reads == 0)) && { ! ${still_running} || ${pr_finished}; }; then
    case "${issues}" in
      0) summary="no issues found" ;;
      1) summary="1 issue found" ;;
      *) summary="${issues} issues found" ;;
    esac
    tally="${passed} of $((passed + issues)) checks passed"
    ((not_offered == 0)) || tally+=" (${not_offered} not offered on a device, counted as passed)"
    so_far="${summary} before then, ${tally}"

    if [[ ${title} == *Waiting* ]]; then
      no_walkthrough "stopped: Softlight is waiting until the pull request is ready for review"
    elif [[ ${title} == *Interrupted* && ${pr_state} == merged ]]; then
      no_walkthrough "stopped: the pull request merged before the checks finished; ${so_far}"
    elif [[ ${title} == *Interrupted* ]]; then
      no_walkthrough "stopped: Softlight was interrupted before the checks finished; ${so_far}"
    elif [[ -n ${conclusion} && ${conclusion} != success && ${conclusion} != neutral ]] \
      && [[ ! ${title} =~ Complete|Not\ Needed|Up\ to\ Date ]]; then
      no_walkthrough "stopped: ${title:-Softlight stopped before the checks finished}; ${so_far}"
    elif ${still_running}; then
      no_walkthrough "stopped: the pull request ${pr_state} before the checks finished; ${so_far}"
    fi
    echo "complete: ${summary}, ${tally}${commit:+ (on ${commit})}"
    exit 0
  fi

  if ((SECONDS + POLL_SECONDS > deadline)); then
    no_walkthrough "running: the review is still running after ${wait_seconds}s; run this again with --watch to keep watching"
  fi
  sleep "${POLL_SECONDS}"
done
