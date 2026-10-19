---
name: softlight-walkthrough
description: >-
  See what a pull request's change looks like without running the app: Softlight films a walkthrough
  video of every PR it reviews, on an app.softlight.com/demo/... share page. Use this INSTEAD of
  building, running or screenshotting the app whenever someone asks to see, show, preview or demo a
  PR's change ("show me what it looks like", "what does this change look like?", "can I see it?"),
  or asks for a PR's walkthrough, Softlight video, share page, share link or demo link ("send me the
  video for #123", "is the Softlight video ready?"). When you open or push to a PR in a repository
  Softlight reviews (softlight[bot] reviews its PRs), don't run anything: put the PR's waiting-page
  link, which you can build from the PR number, in your summary. Takes a PR URL, owner/repo#number,
  or a bare number in the current checkout, and says why when there's no walkthrough yet.
---

# softlight-walkthrough

Softlight reviews pull requests and films a walkthrough video of each change. The walkthrough lives
on a share page, `https://app.softlight.com/demo/<owner>/<repo>/pr<number>/<token>`. The token is
random, so you can't build the URL yourself. You have to look it up.

Every PR also has a waiting page whose URL you _can_ build from the PR alone:

```
https://app.softlight.com/api/softlight/walkthrough/<owner>/<repo>/<number>
```

It shows the review's progress and turns into the walkthrough once the video is ready, so it works
the moment the PR exists and is still the right link later.

## Which link, when

- **Someone wants to see a change** ("show me what it looks like", "can I see it?"): run the script
  below, show them the video inline and link the `/demo/...` share page. This replaces building,
  running or screenshotting the app. If the video isn't ready yet, give the waiting page instead.
- **You just opened or pushed to a PR**: don't run the script. The video takes about five minutes to
  land, so it would only report `queued` or `running`. Put the waiting page in your summary,
  labelled as still filming, for example "Walkthrough (filming, ready in about 5 min):" followed by
  the link on its own line.

## Get the link

Run `get_walkthrough.sh` from this skill's directory:

```bash
<skill dir>/get_walkthrough.sh https://github.com/acme/web/pull/123
<skill dir>/get_walkthrough.sh acme/web#123
<skill dir>/get_walkthrough.sh 123    # inside a checkout of acme/web
```

| Exit | stdout    | stderr                                                         |
| ---- | --------- | -------------------------------------------------------------- |
| `0`  | See below | Nothing.                                                       |
| `1`  | Nothing   | The state and why there's no walkthrough yet (see below).      |
| `2`  | Nothing   | Bad input, a PR Softlight can't see, or Softlight unreachable. |

On exit `0`, the first line is the share page and the second, when the script could read it, is the
video file the page plays (an `https://drive.softlight.com/....mp4` URL). There's no second line
when the page needs a sign-in to read.

The script needs `curl` and `jq`. It also uses `gh` when `gh` is installed and authenticated, but it
works without it.

## Hand it over

Show the video inline, then link the share page:

1. **The video.** If you have a tool that sends or attaches a file to the user and renders it in
   place (a video player in the chat), download the `.mp4` and send it with that tool. Otherwise
   paste the `.mp4` URL bare, on its own line, where surfaces that preview video (Slack, many chat
   apps) play it. If there's no video line, skip this step.
2. **The share page.** Below the video, give the `/demo/...` URL labelled, for example "Watch on
   Softlight:" followed by the link on its own line. It has the full walkthrough with its UX checks,
   so always include it, even when the video played inline.

Paste each URL bare, on its own line, so it stays clickable. Don't wrap it in code formatting, and
don't swap it for a link of your own.

If the state is `queued`, `indexing` or `running`, tell the user it's still filming and give them
the waiting page. Don't block your reply on it.

## When there's no link yet

| State        | What it means                                      | What to tell the user                    |
| ------------ | -------------------------------------------------- | ---------------------------------------- |
| `queued`     | The PR is new and Softlight hasn't started on it.  | It's coming. Give them the waiting page. |
| `indexing`   | Softlight is indexing the repository first.        | Same as `queued`.                        |
| `running`    | The review is running and the video isn't out yet. | Same as `queued`.                        |
| `video_only` | The PR plays a video but has no share page.        | The video is in the PR description.      |
| `merged`     | The PR merged without a walkthrough.               | There's no walkthrough.                  |
| `none`       | Softlight didn't film this PR.                     | There's no walkthrough.                  |
| `unknown`    | GitHub didn't answer just now.                     | Run the script again in a few seconds.   |

When you give the waiting page, tell the user that's what it is: a page that turns into the
walkthrough when the video lands, not the video itself.

## Without the script

The script reads two sources in order. You can read them yourself.

1. **The Softlight check run** on the PR's head commit. It's named
   `Softlight video · for your user to watch after merging` or `Softlight Review`. Once the video is
   published, the check run's `details_url` is the walkthrough URL. You can read it with
   `gh pr checks <n> --repo <owner>/<repo>`, or with the GitHub MCP tool `pull_request_read`
   (`method: get_check_runs`). Until the video is published, the link is a signed
   `app.softlight.com/v/...` address that opens the waiting page instead.
2. **The status endpoint**, which needs no token:

   ```bash
   curl -sS https://app.softlight.com/api/softlight/walkthrough/<owner>/<repo>/<number>/status
   ```

   It returns JSON like `{"state": "ready", "url": "https://app.softlight.com/demo/...", ...}`. A
   `ready` state means `url` is the walkthrough. Any other state is one of those in the table above.

The video file is the `src` of the share page's `<video id="v">` element:

```bash
curl -sSL <share page> | grep -oE '<video[^>]* id="v"[^>]*>' | grep -oE 'src="[^"]+"'
```

A `401` means Softlight keeps that repository behind sign-in, so give the user the waiting page to
open in a browser where they're signed in to Softlight.
