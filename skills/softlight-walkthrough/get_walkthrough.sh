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
# SOFTLIGHT_BASE_URL points it at another Softlight deployment.

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
    awk 'NR > 2 && !/^#/ { exit } NR > 2 { sub(/^# ?/, ""); print }' "$0"
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

readonly NAME='[A-Za-z0-9_.-]+'
if [[ $1 =~ ^https://(www\.)?github\.com/(${NAME})/(${NAME})/pull/([0-9]+)([/?#].*)?$ ]]; then
  owner="${BASH_REMATCH[2]}" repo="${BASH_REMATCH[3]}" number="${BASH_REMATCH[4]}"
elif [[ $1 =~ ^(${NAME})/(${NAME})#([0-9]+)$ ]]; then
  owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}" number="${BASH_REMATCH[3]}"
elif [[ $1 =~ ^#?([0-9]+)$ ]]; then
  number="${BASH_REMATCH[1]}"
  remote="$(git remote get-url origin 2>/dev/null)" \
    || die "${number} needs a checkout with an origin remote; pass owner/repo#${number} instead"
  # Any host: agents often clone through a proxy (Capy's is git.capy.ai/<owner>/<repo>.git).
  [[ ${remote%/} =~ [:/](${NAME})/(${NAME})$ ]] \
    || die "can't tell the repository from origin (${remote/\/\/*@/\/\/}); pass owner/repo#${number} instead"
  owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]%.git}"
else
  die "not a pull request: $1"$'\n'"${USAGE}"
fi
readonly owner repo number

readonly WALKTHROUGH="${BASE_URL}/api/softlight/walkthrough/${owner}/${repo}/${number}"
share_url_prefix="${BASE_URL}/demo/$(tr '[:upper:]' '[:lower:]' <<<"${owner}/${repo}")/pr${number}/"
readonly share_url_prefix

look_up_walkthrough() {
  local check_links check_link response code body parsed state waiting_page_code

  if command -v gh >/dev/null; then
    check_links="$(
      gh pr view "${number}" --repo "${owner}/${repo}" --json statusCheckRollup --jq '
        .statusCheckRollup[]
        | select(.__typename == "CheckRun")
        | select(.name == "Softlight Review" or (.name | startswith("Softlight video")))
        | .detailsUrl // empty' 2>/dev/null
    )" || check_links=""
    while IFS= read -r check_link; do
      if [[ ${check_link} == "${share_url_prefix}"* ]]; then
        url="${check_link}"
        return 0
      fi
    done <<<"${check_links}"
  fi

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
    queued) not_ready_reason="queued: Softlight hasn't started on this pull request yet" ;;
    indexing) not_ready_reason="indexing: Softlight is indexing the repository first" ;;
    running) not_ready_reason="running: the review is running and the video isn't published yet" ;;
    video_only) no_walkthrough "video_only: the pull request plays a video in its description but has no share page" ;;
    merged) no_walkthrough "merged: the pull request merged before the video finished recording, so there is no walkthrough" ;;
    none) no_walkthrough "none: Softlight didn't film this pull request" ;;
    *)
      waiting_page_code="$(curl --silent --max-time 30 --output /dev/null --write-out '%{http_code}' "${WALKTHROUGH}")" || waiting_page_code=""
      [[ ${waiting_page_code} != 404 ]] \
        || die "Softlight can't see ${owner}/${repo}#${number}; check that it exists and the Softlight app is installed on the repository"
      not_ready_reason="${state}: Softlight couldn't say just now"
      ;;
  esac
  return 1
}

not_ready_reason=""
deadline=$((SECONDS + wait_seconds))
url=""
until look_up_walkthrough; do
  if ((SECONDS + POLL_SECONDS > deadline)); then
    if ((wait_seconds > 0)); then
      no_walkthrough "${not_ready_reason}; still not published after ${wait_seconds}s, run this again later"
    fi
    no_walkthrough "${not_ready_reason}; run this again with --wait to wait for the video"
  fi
  sleep "${POLL_SECONDS}"
done

if ! ${watch}; then
  echo "${url}"
  exit 0
fi
echo "ready: ${url}"

# Prints "<result>\037<device>\037<check>\037<finding>" per check and device. \037, not a tab,
# because `read` collapses empty tab-separated fields, and device is empty on a one-device page.
share_page_results() {
  awk '
    function text(s) {
      gsub(/<[^>]*>/, "", s)
      gsub(/&lt;/, "<", s)
      gsub(/&gt;/, ">", s)
      gsub(/&quot;/, "\"", s)
      gsub(/&#x27;|&#39;/, "\047", s)
      gsub(/&amp;/, "\\&", s)
      gsub(/[\t\037 ]+/, " ", s)
      sub(/^ /, "", s)
      sub(/ $/, "", s)
      return s
    }
    function attr(tag, name,    v) {
      if (!match(tag, name "=\"[^\"]*\"")) return ""
      v = substr(tag, RSTART + length(name) + 2, RLENGTH - length(name) - 3)
      return v
    }
    { page = page $0 " " }
    END {
      nfilms = split(page, film_sections, "<section class=\"take")
      film = -1
      for (k = 2; k <= nfilms; k++) {
        film_html = film_sections[k]
        if (!match(film_html, /^[^"]*"/)) continue
        classes = substr(film_html, 1, RLENGTH - 1)
        if (classes != "" && substr(classes, 1, 1) != " ") continue
        if ((classes " ") ~ / more /) continue
        film++
        stop = index(film_html, "</section>")
        if (stop) film_html = substr(film_html, 1, stop - 1)
        box = index(film_html, "<div class=\"devices\"")
        if (!box) continue
        boxtag = substr(film_html, box)
        boxtag = substr(boxtag, 1, index(boxtag, ">"))
        own_device[film] = attr(boxtag, "data-own")
        device_spans = substr(film_html, box + length(boxtag))
        cut = index(device_spans, "<div")
        if (cut) device_spans = substr(device_spans, 1, cut - 1)
        device_count[film] = 0
        while (match(device_spans, /<span class="device[^>]*>/)) {
          tag = substr(device_spans, RSTART, RLENGTH)
          device_spans = substr(device_spans, RSTART + RLENGTH)
          device = attr(tag, "data-device")
          device_count[film]++
          device_of[film, device_count[film]] = device
          span_class = attr(tag, "class")
          if (span_class ~ /running/) verdict = "running"
          else if (span_class ~ /unchecked/) verdict = "unchecked"
          else if (span_class ~ /not-offered/) verdict = "not_offered"
          else verdict = attr(tag, "data-verdict")
          state[film, device] = verdict
          if (verdict != "unchecked" && verdict != "not_offered") { filmed_devices[device] = 1; page_has_filmed_device = 1 }
          priority[film, device] = attr(tag, "data-priority")
        }
        depth = 0
        rest = film_html
        while (match(rest, /<div[ >][^>]*>|<\/div>|<p class="fix-title">[^<]*/)) {
          token = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          if (token == "</div>") {
            if (depth > 0) depth--
          } else if (token ~ /^<div/) {
            depth++
            div_kind[depth] = ""
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
        check = text(check)
        film = match(row, /data-take="[0-9]+"/) ? substr(row, RSTART + 11, RLENGTH - 12) + 0 : -1
        if (row ~ /^[^>]*(pending|prev|pd-run)/ || row ~ /class="mark spin/) {
          print "running\037\037" check "\037"
          continue
        }
        if (film >= 0 && (film in device_count)) {
          for (j = 1; j <= device_count[film]; j++) {
            device = device_of[film, j]
            if (!(device in filmed_devices)) continue
            verdict = state[film, device]
            if (verdict == "unchecked" || verdict == "withheld") continue
            if (verdict == "running") result = "running"
            else if (verdict == "finding") result = "issue" (priority[film, device] != "" ? " " priority[film, device] : "")
            else if (verdict == "not_offered") result = "not_offered"
            else result = "passed"
            print result "\037" device "\037" check "\037" ((film, device) in title ? title[film, device] : "")
          }
          continue
        }
        if (page_has_filmed_device && film >= 0) continue
        if (row ~ /^[^>]*pd-off/) continue
        if (row ~ /class="mark bad/) {
          result = "issue"
          if (match(row, /class="mark bad pri[^>]*>P[0-9]</)) {
            priority_label = substr(row, RSTART, RLENGTH)
            sub(/.*>/, "", priority_label)
            sub(/</, "", priority_label)
            result = result " " priority_label
          }
        } else {
          result = "passed"
        }
        print result "\037\037" check "\037" ((film >= 0 && (film, own_device[film]) in title) ? title[film, own_device[film]] : "")
      }
    }'
}

readonly PAGE_COMMIT_META='<meta name="softlight-head" content="([0-9a-fA-F]+)"'
readonly PAGE_ID_META='<meta name="softlight-page-id" content="([0-9a-fA-F]+)"'
readonly MAX_FAILED_PAGE_READS=5

reported_issues=$'\n'
failed_page_reads=0
commit=""
while :; do
  parsed="$(
    curl --silent --max-time 30 --retry 2 "${WALKTHROUGH}/status?rec=1" \
      | jq -r '[.state // "unknown", .run_status // "", .conclusion // "", .refresh // "", .title // "", .pr_state // "", (.run_head // .head // ""), .page_id // "", .head // "", .rides // ""] | join("|")' 2>/dev/null
  )" || parsed="unknown|||||||||"
  IFS='|' read -r state run_status conclusion refresh title pr_state checked_commit served_page_id pr_head reused_review_commit <<<"${parsed}"
  checked_commit="${checked_commit:0:7}"
  pr_head="${pr_head:0:7}"
  reused_review_commit="${reused_review_commit:0:7}"

  page_html="$(curl --silent --fail --location --compressed --max-time 30 --retry 2 "${url}")" || page_html=""
  if [[ ${page_html} == *'<ol class="videos" id="videos">'* ]]; then
    failed_page_reads=0
  else
    failed_page_reads=$((failed_page_reads + 1))
    ((failed_page_reads < MAX_FAILED_PAGE_READS)) \
      || die "could not read the share page at ${url} ${failed_page_reads} times in a row, so the review's results are unknown"
  fi
  page_commit=""
  if [[ ${page_html} =~ ${PAGE_COMMIT_META} ]]; then
    page_commit="${BASH_REMATCH[1]:0:7}"
  fi
  page_id_in_html=""
  if [[ ${page_html} =~ ${PAGE_ID_META} ]]; then
    page_id_in_html="${BASH_REMATCH[1]}"
  fi

  if [[ -n ${checked_commit} && ${checked_commit} != "${commit}" ]]; then
    commit="${checked_commit}"
    echo "commit: ${commit}"
  fi
  page_is_reused_review=false
  [[ -z ${reused_review_commit} || ${page_commit} != "${reused_review_commit}" ]] || page_is_reused_review=true
  page_is_stale=false
  if [[ -n ${checked_commit} && -n ${page_commit} && ${checked_commit} != "${page_commit}" ]] && ! ${page_is_reused_review}; then
    page_is_stale=true
  elif [[ -n ${served_page_id} && -n ${page_id_in_html} && ${served_page_id} != "${page_id_in_html}" ]]; then
    page_is_stale=true
  fi
  newer_push_pending=false
  if [[ -n ${pr_head} && -n ${page_commit} && ${pr_head} != "${page_commit}" ]] && ! ${page_is_reused_review} \
    && [[ ${pr_state} != merged && ${pr_state} != closed ]]; then
    newer_push_pending=true
  fi

  page_results="$(share_page_results <<<"${page_html}")" || page_results=""
  issues=0
  passed=0
  not_offered=0
  still_running=${page_is_stale}
  ((failed_page_reads == 0)) || still_running=true
  while IFS=$'\037' read -r result device check finding; do
    ${page_is_stale} && break
    case "${result}" in
      issue*)
        issues=$((issues + 1))
        level="${result#issue}"
        issue_key="${commit}|${device}|${check}"
        if [[ ${reported_issues} != *$'\n'"${issue_key}"$'\n'* ]]; then
          reported_issues+="${issue_key}"$'\n'
          echo "issue:${level}${device:+ ${device}} — ${check}${finding:+ — ${finding}}${commit:+ (on ${commit})}"
        fi
        ;;
      passed) passed=$((passed + 1)) ;;
      not_offered)
        passed=$((passed + 1))
        not_offered=$((not_offered + 1))
        ;;
      running) still_running=true ;;
      *) ;;
    esac
  done <<<"${page_results}"

  case "${issues}" in
    0) summary="no issues found" ;;
    1) summary="1 issue found" ;;
    *) summary="${issues} issues found" ;;
  esac

  run_concluded=false
  if [[ -n ${run_status} ]]; then
    [[ ${run_status} != completed && ${run_status} != none ]] || run_concluded=true
  elif [[ -z ${refresh} ]]; then
    run_concluded=true
  fi
  review_over=false
  if [[ ${state} == ready && ${title} != *Superseded* ]] && ${run_concluded} && ! ${newer_push_pending} \
    && ((failed_page_reads == 0)); then
    if ! ${still_running} || [[ ${pr_state} == merged || ${pr_state} == closed ]]; then
      review_over=true
    fi
  fi
  if ${review_over}; then
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
