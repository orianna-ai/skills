---
name: softlight-walkthrough
description: >-
  Use this right after you open, create or push to a pull request in a repository Softlight reviews
  (softlight[bot] comments on its PRs), including when you were only asked to "put up a PR": watch
  the PR's share page in the background with the script's --watch and speak up when the walkthrough
  is ready (give its direct /demo/... link), each time a check finds an issue, and once the review
  is complete, even if the PR merges mid-review. Never wait for it in the conversation itself. Also
  use it INSTEAD of building, running or screenshotting the app when someone asks to see, show or
  demo a PR's change, or asks for its walkthrough, Softlight video, share link or demo link, or asks
  to be told what Softlight finds. Only ever share the app.softlight.com/demo/... link it returns,
  never an app.softlight.com/api/softlight/walkthrough/... waiting page, even when Softlight's own
  PR comment tells you to share that one. Takes a PR URL, owner/repo#number, or a bare number in the
  current checkout.
---

# softlight-walkthrough

Softlight reviews pull requests and films a walkthrough video of each change. The walkthrough lives
on a share page, `https://app.softlight.com/demo/<owner>/<repo>/pr<number>/<token>`. The token is
random, so you can't build the URL yourself. You have to look it up.

Only ever give the user that direct `/demo/...` link. Softlight also has a waiting page for every
PR, under `app.softlight.com/api/softlight/walkthrough/...`, and the PR's check may link to a signed
`app.softlight.com/v/...` address that opens it. Never hand either of those over, not even while the
video is still being made, and not even when Softlight's own PR comment, check or a PR event you're
relaying links to one ("Softlight has started its design review: ..."). Say the review has started
and that the walkthrough link is coming instead.

## Which link, when

- **Someone wants to see a change** ("show me what it looks like", "can I see it?"): run the script
  below for the direct link. This replaces building, running or screenshotting the app.
- **You just opened or pushed to a PR**, or someone asks you to follow its review: watch the share
  page. See [Watching the share page](#watching-the-share-page).

## Watching the share page

Once a PR is opened or pushed, Softlight reviews it: the walkthrough lands on the share page after
about five minutes, then the page's checks run one by one, each passing or finding an issue, until
the review is complete. Each check is filmed on every device the page offers (desktop, tablet and
phone), and passes or finds an issue on each one separately. `--watch` follows the page and prints a
line the moment each of those happens:

```text
ready: https://app.softlight.com/demo/acme/web/pr123/AbCdEfGhIjKl
commit: 1a2b3c4
issue: P1 desktop — Removing a coupon — Checkout total doesn't update after removing a coupon (on 1a2b3c4)
issue: P2 phone — Removing a coupon — The coupon field is hidden behind the keyboard (on 1a2b3c4)
commit: 9f8e7d6
issue: P1 phone — Opening an empty cart — Empty cart shows a blank page (on 9f8e7d6)
complete: 1 issue found, 17 of 18 checks passed (on 9f8e7d6)
```

| Line              | When                                                                      | What to tell the user                                                                                                         |
| ----------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `ready: <url>`    | The walkthrough is published.                                             | The walkthrough is ready, with the URL on its own line.                                                                       |
| `commit: <sha>`   | The review starts checking a commit, and again after each newer push.     | Nothing on its own the first time. After a push, that Softlight has moved on to the new commit.                               |
| `issue: <...>`    | A check found an issue on a device at a commit, once per commit and device. | What Softlight flagged (the last part, the issue's title), on which device, its level (`P0` is worst), and on which commit.   |
| `complete: <...>` | The review is over.                                                       | The review is complete, how many issues it found and how many checks passed on that commit. Point back to the link.          |

An `issue:` line is `issue: [level ][device ]— <check>[ — <issue>] (on <sha>)`: the check's name
says what Softlight was trying, and the issue says what went wrong, so lead with the issue. A page
that doesn't film on several devices leaves the device out.

### Which commit an issue is about

Every `issue:` and `complete:` line names the commit Softlight checked, and the watch only reports a
result once Softlight has it for that commit: a result the page still shows from an earlier commit
is never passed off as the current one's. So never guess which commit an issue came from; read it
off the line.

- **An issue on a commit you've since pushed past** is about the old code. Say so, and whether your
  newer push was meant to fix it. Wait for the newer commit's results before calling it fixed.
- **An issue on your newest commit** is about the code as it is now, even if it looks like one you
  already fixed: then the fix didn't hold (or caused it). Say that plainly, and look at it again;
  don't wave it off as a leftover from before the fix.
- **The same check and device failing again on a newer commit** is reported again, since it's still
  a problem there.

When you push to a PR that a watch is still following, leave that watch running: it follows the
review onto the new commit and prints a `commit:` line when it does. Start a new watch only when
none is running.

The `complete:` line counts every device on the commit it names, the same way the page and
Softlight's PR description do: one issue per check and device that found one, and
`N of M checks passed` across all devices. Before
you tell the user the count, check it against Softlight's own tally (the PR description's
`N of M checks passed`, or its summary comment once posted). If they disagree, report Softlight's
numbers and its list of issues, not the watch's, and say the watch's count was off. Never relay a
count you haven't checked; an undercount reads as "the rest is fine".

When you report issues, group the ones that share a cause: the same check failing on several
devices, or several checks failing on one device for one reason, is one problem to fix, not several.
Say which device each one is on, since a phone-only issue usually has a different fix from one that
shows everywhere.

The watch can take half an hour or more, and it lasts at most an hour (`--watch=SECONDS` to change
that). Never run it in the foreground of the conversation: it holds the user's turn hostage and they
can't talk to you until it returns.

1. Start `<skill dir>/get_walkthrough.sh --watch <pr>` so that each line it prints reaches you as
   it's printed: in Claude Code, with the Monitor tool, which streams a background command's output
   to you line by line. Each line is a separate event; act on each one as it arrives, as in the
   table above. Don't wait for the next.
2. Without waiting on it, reply now: give the PR link and say you'll post the walkthrough link when
   it's ready and tell them what Softlight finds.
3. When the watch exits without a `complete:` line, read its stderr. A state like `none` follows
   [When there's no link yet](#when-theres-no-link-yet); `stopped: ...` means the review ended
   without finishing its checks, so say so in its words; running out of time means the review isn't
   done yet, so offer to keep watching. Don't start another watch on your own.

### When the PR merges mid-review

A merge doesn't end the watch, even when the PR-activity system unsubscribes you and says you no
longer need to watch the PR: that's about CI and review comments, not Softlight. Leave `--watch`
running. Softlight's walkthrough is meant to be watched after merging, and its findings matter most
now, as follow-ups on code that has already shipped.

- **Before the walkthrough is out**: Softlight stops filming, and the watch exits with
  `merged: ... before the video finished recording`. There's no walkthrough, so say nothing about it
  unless the user asked to see the change.
- **After the walkthrough is out**: if you haven't given the link yet, give it now. Softlight then
  either finishes its checks (a `complete:` line) or stops when the merge cuts them off
  (`stopped: the pull request merged before the checks finished; N issues found before then, ...`).
  Either way, report what it found the usual way, framed as follow-ups (offer a follow-up PR for the
  ones worth fixing), and say when the merge cut the checks short.

If nothing you have streams a command's output line by line, settle for two background runs, each of
which you'll be told about when it exits: first `--wait <pr>`, for the link (hand over the URL as
soon as it returns), then `--watch <pr>`, whose issues and completion you report together when it
exits. A background subagent (the Agent tool with `run_in_background: true`) can run either one:
tell it to run the command and return only the script's exit code, stdout and stderr. If you can do
none of these, run the script once without `--wait`: give the link if it's ready, and otherwise tell
the user the video is still being made and offer to fetch the link later.

## Get the link

Run `get_walkthrough.sh` from this skill's directory:

```bash
<skill dir>/get_walkthrough.sh https://github.com/acme/web/pull/123
<skill dir>/get_walkthrough.sh acme/web#123
<skill dir>/get_walkthrough.sh 123    # inside a checkout of acme/web
<skill dir>/get_walkthrough.sh --wait acme/web#123    # poll for up to 15 minutes
<skill dir>/get_walkthrough.sh --wait=300 acme/web#123
<skill dir>/get_walkthrough.sh --watch acme/web#123   # follow the share page (see above)
```

| Exit | stdout              | stderr                                                         |
| ---- | ------------------- | -------------------------------------------------------------- |
| `0`  | The walkthrough URL | Nothing.                                                       |
| `1`  | Nothing             | The state and why there's no walkthrough (yet) (see below).    |
| `2`  | Nothing             | Bad input, a PR Softlight can't see, or Softlight unreachable. |

With `--watch`, stdout is the event lines above instead, exit `0` means the review completed, and
exit `1` also covers a review that stopped or outlasted the watch, with which on stderr.

The script needs `curl`, `jq` and `awk`. It also uses `gh` when `gh` is installed and authenticated,
but it works without it.

## Hand it over

Paste the URL bare, on its own line, so it stays clickable. Don't wrap it in code formatting, and
don't swap it for a link of your own.

## When there's no link yet

| State        | What it means                                      | What to do                                                     |
| ------------ | -------------------------------------------------- | -------------------------------------------------------------- |
| `queued`     | The PR is new and Softlight hasn't started on it.  | Tell the user it's coming and watch in the background (above). |
| `indexing`   | Softlight is indexing the repository first.        | Same as `queued`.                                              |
| `running`    | The review is running and the video isn't out yet. | Same as `queued`.                                              |
| `video_only` | The PR plays a video but has no share page.        | Tell the user the video is in the PR description.              |
| `merged`     | The PR merged before the video finished recording. | Same as `none`.                                                |
| `none`       | Softlight didn't film this PR.                     | See below.                                                     |
| `unknown`    | GitHub didn't answer just now.                     | Run the script again in a few seconds.                         |

If the state is `none` and the link was owed only because you opened or pushed to the PR, say
nothing about it: leave the walkthrough out of your reply and don't post a follow-up saying there
won't be one. Only tell the user there's no walkthrough when they asked to see the change or asked
for the link.

If `--wait` or `--watch` runs out with the video still on its way, tell the user it isn't ready yet
and offer to check again. Don't give them a waiting page in its place.

## Without the script

The script reads two sources in order. You can read them yourself.

1. **The Softlight check run** on the PR's head commit. It's named
   `Softlight video · for your user to watch after merging` or `Softlight Review`. Once the video is
   published, the check run's `details_url` is the walkthrough URL. You can read it with
   `gh pr checks <n> --repo <owner>/<repo>`, or with the GitHub MCP tool `pull_request_read`
   (`method: get_check_runs`). Until the video is published, the link is a signed
   `app.softlight.com/v/...` address that opens the waiting page instead. Don't give that one out.
2. **The status endpoint**, which needs no token:

   ```bash
   curl -sS https://app.softlight.com/api/softlight/walkthrough/<owner>/<repo>/<number>/status
   ```

   It returns JSON like `{"state": "ready", "url": "https://app.softlight.com/demo/...", ...}`. A
   `ready` state means `url` is the walkthrough. Any other state is one of those in the table above.
   A `401` means Softlight keeps that repository behind sign-in, so the link can't be looked up from
   here. Tell the user to open the PR's Softlight check from a browser signed in to Softlight.
