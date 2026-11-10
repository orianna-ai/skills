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
  # Any host: agents often clone through a proxy (Capy's is git.capy.ai/<owner>/<repo>.git).
  [[ ${remote%/} =~ [:/](${NAME})/(${NAME})$ ]] \
    || die "can't tell the repository from origin (${remote}); pass owner/repo#${number} instead"
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

# Sets `url` and returns 0 once published; returns 1 with the reason in `pending` while it's on
# its way; exits on any answer waiting won't change.
look_up() {
  local links link response code body parsed state

  # 1. The Softlight check run. Until the video is published it links a /v/ waiting page, so
  # only a share page counts.
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
    merged) no_walkthrough "merged: the pull request merged before the video finished recording, so there is no walkthrough" ;;
    none) no_walkthrough "none: Softlight didn't film this pull request" ;;
    *)
      # The status endpoint also says "unknown" for a PR Softlight can't see; the waiting page
      # 404s on those.
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

# One line per check and device on the share page: "<result>\037<device>\037<check>\037<finding>",
# with result passed, not_offered, running, or "issue[ <level>]". Split on \037, not a tab: `read`
# collapses empty tab-separated fields, and the device is empty on a one-device page.
#
# The #videos list only shows the page's own device; each check's film (<section class="take">)
# holds every device's result in its .devices box, and that's what the page's score counts. A check
# shown from a previous run, or still being filmed, is running.
page_checks() {
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
      # the films, indexed the way data-take counts them in the list: every .take but a .more one
      # (a "take pd-na" still counts, or later rows would get the wrong film)
      ntakes = split(page, takes, "<section class=\"take")
      t = -1
      for (k = 2; k <= ntakes; k++) {
        take = takes[k]
        if (!match(take, /^[^"]*"/)) continue
        classes = substr(take, 1, RLENGTH - 1)
        if (classes != "" && substr(classes, 1, 1) != " ") continue
        if ((classes " ") ~ / more /) continue
        t++
        stop = index(take, "</section>")
        if (stop) take = substr(take, 1, stop - 1)
        box = index(take, "<div class=\"devices\"")
        if (!box) continue
        boxtag = substr(take, box)
        boxtag = substr(boxtag, 1, index(boxtag, ">"))
        own[t] = attr(boxtag, "data-own")
        head = substr(take, box + length(boxtag))
        cut = index(head, "<div")
        if (cut) head = substr(head, 1, cut - 1)
        ndev[t] = 0
        while (match(head, /<span class="device[^>]*>/)) {
          tag = substr(head, RSTART, RLENGTH)
          head = substr(head, RSTART + RLENGTH)
          d = attr(tag, "data-device")
          ndev[t]++
          dev[t, ndev[t]] = d
          cls = attr(tag, "class")
          if (cls ~ /running/) st = "running"
          else if (cls ~ /unchecked/) st = "unchecked"
          else if (cls ~ /not-offered/) st = "not_offered"
          else st = attr(tag, "data-verdict")
          state[t, d] = st
          # the page scores only the devices some film was recorded (or is being) on
          if (st != "unchecked" && st != "not_offered") { filmed[d] = 1; anyfilm = 1 }
          level[t, d] = attr(tag, "data-priority")
        }
        # a finding title belongs to the device of its .variant, or the own device outside the box
        depth = 0
        rest = take
        while (match(rest, /<div[ >][^>]*>|<\/div>|<p class="fix-title">[^<]*/)) {
          tok = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          if (tok == "</div>") {
            if (depth > 0) depth--
          } else if (tok ~ /^<div/) {
            depth++
            ctx[depth] = ""
            if (tok ~ /class="devices"/) ctx[depth] = "box"
            else if (tok ~ /class="variant/) ctx[depth] = "v:" attr(tok, "data-device")
          } else {
            d = own[t]
            for (j = depth; j >= 1; j--) {
              if (ctx[j] ~ /^v:/) { d = substr(ctx[j], 3); break }
              if (ctx[j] == "box") { d = ""; break }
            }
            sub(/<p class="fix-title">/, "", tok)
            if (d != "" && !((t, d) in title)) title[t, d] = text(tok)
          }
        }
      }

      # the list: every check, in order, and whether it is still running
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
        t = match(row, /data-take="[0-9]+"/) ? substr(row, RSTART + 11, RLENGTH - 12) + 0 : -1
        if (row ~ /^[^>]*(pending|prev|pd-run)/ || row ~ /class="mark spin/) {
          print "running\037\037" check "\037"
          continue
        }
        if (t >= 0 && (t in ndev)) {
          for (j = 1; j <= ndev[t]; j++) {
            d = dev[t, j]
            if (!(d in filmed)) continue
            st = state[t, d]
            if (st == "unchecked" || st == "withheld") continue
            if (st == "running") result = "running"
            else if (st == "finding") result = "issue" (level[t, d] != "" ? " " level[t, d] : "")
            # counted as passed, as the page score does
            else if (st == "not_offered") result = "not_offered"
            else result = "passed"
            print result "\037" d "\037" check "\037" ((t, d) in title ? title[t, d] : "")
          }
          continue
        }
        # on a page with devices, a film without a devices box counts on no device
        if (anyfilm && t >= 0) continue
        # a check not filmed on the device the page shows is not one of its checks there
        if (row ~ /^[^>]*pd-off/) continue
        if (row ~ /class="mark bad/) {
          result = "issue"
          if (match(row, /class="mark bad pri[^>]*>P[0-9]</)) {
            lv = substr(row, RSTART, RLENGTH)
            sub(/.*>/, "", lv)
            sub(/</, "", lv)
            result = result " " lv
          }
        } else {
          result = "passed"
        }
        print result "\037\037" check "\037" ((t >= 0 && (t, own[t]) in title) ? title[t, own[t]] : "")
      }
    }'
}

readonly HEAD_META='<meta name="softlight-head" content="([0-9a-fA-F]+)"'
readonly PAGE_ID_META='<meta name="softlight-page-id" content="([0-9a-fA-F]+)"'
# Polls in a row the share page may fail to read before giving up with exit 2.
readonly MAX_UNREAD=5

seen=$'\n'
unread=0
commit=""
while :; do
  # run_head: the commit being checked. head: the PR's newest commit. page_id: the page the link
  # should serve. rides: the earlier commit whose review the head's check reuses.
  parsed="$(
    curl --silent --max-time 30 --retry 2 "${WALKTHROUGH}/status?rec=1" \
      | jq -r '[.state // "unknown", .run_status // "", .conclusion // "", .refresh // "", .title // "", .pr_state // "", (.run_head // .head // ""), .page_id // "", .head // "", .rides // ""] | join("|")' 2>/dev/null
  )" || parsed="unknown|||||||||"
  IFS='|' read -r state run_status conclusion refresh title pr_state run_head page_id head rides <<<"${parsed}"
  run_head="${run_head:0:7}"
  head="${head:0:7}"
  rides="${rides:0:7}"

  # A page without the checks list wasn't read, so its checks are unknown, not passed.
  html="$(curl --silent --fail --location --compressed --max-time 30 --retry 2 "${url}")" || html=""
  if [[ ${html} == *'<ol class="videos" id="videos">'* ]]; then
    unread=0
  else
    unread=$((unread + 1))
    ((unread < MAX_UNREAD)) \
      || die "could not read the share page at ${url} ${unread} times in a row, so the review's results are unknown"
  fi
  page_head=""
  if [[ ${html} =~ ${HEAD_META} ]]; then
    page_head="${BASH_REMATCH[1]:0:7}"
  fi
  their_id=""
  if [[ ${html} =~ ${PAGE_ID_META} ]]; then
    their_id="${BASH_REMATCH[1]}"
  fi

  if [[ -n ${run_head} && ${run_head} != "${commit}" ]]; then
    commit="${run_head}"
    echo "commit: ${commit}"
  fi
  # Stale: rendered at another commit than the one being checked (unless it's the one the head
  # rides), or not the page the status says the link serves. Nothing on it counts.
  ridden=false
  [[ -z ${rides} || ${page_head} != "${rides}" ]] || ridden=true
  stale=false
  if [[ -n ${run_head} && -n ${page_head} && ${run_head} != "${page_head}" ]] && ! ${ridden}; then
    stale=true
  elif [[ -n ${page_id} && -n ${their_id} && ${page_id} != "${their_id}" ]]; then
    stale=true
  fi
  # Behind: the PR has a newer push than the page, and a run for it is still coming.
  behind=false
  if [[ -n ${head} && -n ${page_head} && ${head} != "${page_head}" ]] && ! ${ridden} \
    && [[ ${pr_state} != merged && ${pr_state} != closed ]]; then
    behind=true
  fi

  # print each issue the first time it shows on this commit
  checks="$(page_checks <<<"${html}")" || checks=""
  issues=0
  passed=0
  not_offered=0
  running=${stale}
  ((unread == 0)) || running=true
  while IFS=$'\037' read -r result device check finding; do
    ${stale} && break
    case "${result}" in
      issue*)
        issues=$((issues + 1))
        level="${result#issue}"
        key="${commit}|${device}|${check}"
        if [[ ${seen} != *$'\n'"${key}"$'\n'* ]]; then
          seen+="${key}"$'\n'
          echo "issue:${level}${device:+ ${device}} — ${check}${finding:+ — ${finding}}${commit:+ (on ${commit})}"
        fi
        ;;
      passed) passed=$((passed + 1)) ;;
      not_offered)
        passed=$((passed + 1))
        not_offered=$((not_offered + 1))
        ;;
      running) running=true ;;
      *) ;;
    esac
  done <<<"${checks}"

  case "${issues}" in
    0) summary="no issues found" ;;
    1) summary="1 issue found" ;;
    *) summary="${issues} issues found" ;;
  esac

  # Over once the run has concluded and no check is still running. On a merged or closed PR, a
  # check left running was cut off and doesn't hold the watch. A superseded run doesn't end it.
  concluded=false
  if [[ -n ${run_status} ]]; then
    [[ ${run_status} != completed && ${run_status} != none ]] || concluded=true
  elif [[ -z ${refresh} ]]; then
    concluded=true
  fi
  settled=false
  if [[ ${state} == ready && ${title} != *Superseded* ]] && ${concluded} && ! ${behind} \
    && ((unread == 0)); then
    if ! ${running} || [[ ${pr_state} == merged || ${pr_state} == closed ]]; then
      settled=true
    fi
  fi
  if ${settled}; then
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
    elif ${running}; then
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
