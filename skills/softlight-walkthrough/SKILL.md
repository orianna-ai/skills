---
name: softlight-walkthrough
description: >-
  Use right after you open or push to a pull request in a repository Softlight reviews
  (softlight[bot] comments on its PRs), even if you were only asked to put up a PR: opening it is
  not the end of the task. Also use it, instead of building or screenshotting the app, whenever
  someone asks to see or demo a PR's change, for its Softlight walkthrough, video or link, or what
  Softlight found. Gets the walkthrough link and follows the review.
---

# softlight-walkthrough

Softlight films a walkthrough of each pull request, publishes it on a share page
(`https://app.softlight.com/demo/<owner>/<repo>/pr<number>/<token>`), then runs checks on it on each
device (desktop, tablet, phone). The token is random: get the link from `get_walkthrough.sh` in this
skill's directory, never build it.

**Only share the `/demo/...` link.** Never pass on a waiting page
(`app.softlight.com/api/softlight/walkthrough/...` or `app.softlight.com/v/...`), even when
Softlight's own PR comment or check links one: say the review has started and the link is coming.
Paste the link bare, on its own line.

**Send the link the moment you have it.** Whenever a `/demo/...` link reaches you (a `ready:` line,
the URL `--wait` or a plain run prints, or the check run), send it to the user before you do
anything else, including starting another run.

**"The user" is whoever you report to:** the person who gave you the task, or the session your
instructions say to report to (a driver, orchestrator or parent agent). In that case nobody reads
your own chat, so send every update there the way you send your report (for example
`conductor message create --session <id>`).

## What to do

| Situation                                                     | Do                                                                        |
| ------------------------------------------------------------- | ------------------------------------------------------------------------- |
| You just opened or pushed to a PR, or were asked to follow it | [Watch the review](#watch-the-review) in the background.                  |
| Someone wants to see a PR's change, or asks for its link      | Run `get_walkthrough.sh <pr>` and hand over the link it prints.           |
| You pushed again while a watch on that PR is still running    | Leave it: it follows the review onto the new commit. Don't start another. |

`<pr>` is `https://github.com/acme/web/pull/123`, `acme/web#123`, or `123` inside a checkout of
`acme/web`. Pass the URL or `owner/repo#number` whenever you have it, as you do right after opening
the PR: a bare number depends on reading the checkout's remote.

## Watch the review

The walkthrough is published about five minutes after a push; the checks take half an hour or more
after that. Never run the watch in the foreground. If your tool times out background commands, give
each run a timeout longer than its `--wait` or `--watch` seconds (900 and 3600 by default): a run
killed early never prints its result.

First, how does a command's output reach you?

- **Each printed line, while it runs** (in Claude Code, the Monitor tool): follow the steps below.
- **Only when a background command exits** (a background command or subagent that returns the exit
  code, stdout and stderr): tell the user as in step 2, then run `--wait <pr>`. It prints the bare
  link, with no `ready:` prefix: send it the moment it returns, before you start anything else,
  `--watch` included. Only then run `--watch <pr>`, and report its issues and completion when it
  exits. If `--wait` runs out first, say the link is coming and start `--watch` anyway: it waits for
  the link itself and prints `ready:` when it appears.
- **You can't run anything in the background:** run the script once without flags and give the link,
  or say the video is still being made and offer to fetch it later.

If your harness can kill a background command once your turn ends or the machine goes idle, keep the
run alive by waiting on it the way the harness provides (for example, registering a wait on the
operation) before you end your turn. Never take a run that has gone quiet to mean it's still
waiting. Before you report on the review, run the script once with no flags: it prints the link at
once if it's published.

1. Start `<skill dir>/get_walkthrough.sh --watch <pr>` so each line reaches you as it's printed.
2. Right away, tell the user the PR link and that you'll send the walkthrough link and what
   Softlight finds. Don't hold this message for the link.
3. Act on each line the moment it arrives. When the script exits, see [When it ends](#when-it-ends).

```text
ready: https://app.softlight.com/demo/acme/web/pr123/AbCdEfGhIjKl
commit: 1a2b3c4
issue: P1 desktop — Removing a coupon — Checkout total doesn't update after removing a coupon (on 1a2b3c4)
issue: P2 phone — Removing a coupon — The coupon field is hidden behind the keyboard (on 1a2b3c4)
commit: 9f8e7d6
issue: P1 phone — Opening an empty cart — Empty cart shows a blank page (on 9f8e7d6)
complete: 1 issue found, 17 of 18 checks passed (2 not offered on a device, counted as passed) (on 9f8e7d6)
```

| Line                                                       | Tell the user                                                                                 |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `ready: <url>`                                             | Immediately, before anything else: the walkthrough is ready, with the URL on its own line.    |
| `commit: <sha>`                                            | Nothing the first time. After a push: Softlight has moved on to the new commit.               |
| `issue: [level ][device ]— <check>[ — <issue>] (on <sha>)` | The issue (lead with it), the device, the level (`P0` is worst) and the commit.               |
| `complete: <...> (on <sha>)`                               | The review is complete, how many issues and checks passed on that commit, and the link again. |

Each issue is printed once per commit, check and device. A page that films one device leaves the
device out.

### Reporting what it finds

- **Read the commit off the line.** An issue on a commit you've since pushed past is about the old
  code: say so, and wait for the newer commit's result before calling it fixed. An issue on your
  newest commit is about the code as it is now, even if it looks like one you already fixed.
- **Group issues that share a cause**, and say which devices each is on: a phone-only issue usually
  needs a different fix.
- **Check the `complete:` issue count** against Softlight's own list (the PR description or its
  summary comment). If they disagree, report Softlight's numbers and list. The PR description's
  `N/M UX checks passed` is lower by the "not offered" number in the `complete:` line; that's
  expected, don't report it.

### When the PR merges mid-review

Keep the watch running. A merge doesn't end Softlight's review, even if the PR-activity system
unsubscribes you. Report what it finds as follow-ups on shipped code, offer a follow-up PR for the
ones worth fixing, and say if the merge cut the checks short.

## When it ends

Exit `0` is success: the link on stdout, or with `--watch`, a `complete:` line. Exit `1` means
there's no walkthrough or result (yet); stderr is one line, `<state>: <why>`:

| State                           | Means                                                             | Do                                                                                    |
| ------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `queued`, `indexing`, `running` | The video or the review isn't done yet (or the wait ran out).     | Say it's on its way and offer to keep watching. Don't restart a watch on your own.    |
| `stopped`                       | The review ended without finishing its checks.                    | Say so in its words, with what it found before then.                                  |
| `merged`, `none`                | No walkthrough: the PR merged first, or Softlight didn't film it. | Say nothing unless the user asked to see the change; then say there's no walkthrough. |
| `video_only`                    | The video is in the PR description; there's no share page.        | Point the user to the PR description.                                                 |
| `unknown`                       | Softlight couldn't say just now.                                  | Run it again in a few seconds.                                                        |

Exit `2` means bad input, a PR Softlight can't see, or Softlight unreachable; stderr says which.

- It couldn't tell the repository from a bare number, or Softlight can't see the PR: run it again
  with `owner/repo#number`.
- The repository is behind Softlight sign-in: tell the user to open the PR's Softlight check from a
  browser signed in to Softlight.

## Reference

```bash
<skill dir>/get_walkthrough.sh <pr>              # the link if it's published, else exit 1 at once
<skill dir>/get_walkthrough.sh --wait <pr>       # poll for the link, up to 15 minutes (--wait=SECONDS)
<skill dir>/get_walkthrough.sh --watch <pr>      # follow the review, up to an hour (--watch=SECONDS)
```

Needs `curl`, `jq` and `awk`; also reads the PR's checks with `gh` when it's signed in.

**Without the script**, the link is in either of these:

1. The PR's Softlight check run (`Softlight Review` or `Softlight video · ...`): once the video is
   published, its `details_url` is the `/demo/...` link (`gh pr checks <n> --repo <owner>/<repo>`,
   or the GitHub MCP `pull_request_read` with `method: get_check_runs`). Before that it's a `/v/...`
   waiting link; don't give that out.
2. `curl -sS https://app.softlight.com/api/softlight/walkthrough/<owner>/<repo>/<number>/status`
   returns `{"state": "ready", "url": "https://app.softlight.com/demo/...", ...}` once published;
   any other state is one in the table above. A `401` means the repository is behind sign-in.
