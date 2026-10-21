---
name: softlight-walkthrough
description: >-
  See what a pull request's change looks like without running the app: Softlight films a walkthrough
  video of every PR it reviews, on an app.softlight.com/demo/... share page. Use this INSTEAD of
  building, running or screenshotting the app whenever someone asks to see, show, preview or demo a
  PR's change ("show me what it looks like", "what does this change look like?", "can I see it?"),
  or asks for a PR's walkthrough, Softlight video, share page, share link or demo link ("send me the
  video for #123", "is the Softlight video ready?"). Also use it whenever someone asks you to open,
  create or push a PR in a repository Softlight reviews (softlight[bot] reviews its PRs): your reply
  with the PR link must also give the walkthrough's direct /demo/... link, which takes about five
  minutes to exist, so wait for it with the script's --wait. Takes a PR URL, owner/repo#number, or a
  bare number in the current checkout, and says why when there's no walkthrough.
---

# softlight-walkthrough

Softlight reviews pull requests and films a walkthrough video of each change. The walkthrough lives
on a share page, `https://app.softlight.com/demo/<owner>/<repo>/pr<number>/<token>`. The token is
random, so you can't build the URL yourself. You have to look it up.

Only ever give the user that direct `/demo/...` link. Softlight also has a waiting page for every
PR, under `app.softlight.com/api/softlight/walkthrough/...`, and the PR's check may link to a signed
`app.softlight.com/v/...` address that opens it. Never hand either of those over, not even while the
video is still being made.

## Which link, when

- **Someone wants to see a change** ("show me what it looks like", "can I see it?"): run the script
  below for the direct link. This replaces building, running or screenshotting the app.
- **You just opened or pushed to a PR**: the reply with the PR link must also give the walkthrough
  link. The video takes about five minutes to land, so run the script with `--wait`, which polls
  until it's published. If you can run a command in the background and be told when it finishes,
  do that: give the PR link now, saying the walkthrough link follows, and post the link once the
  script prints it. Otherwise wait for the script before you reply.

## Get the link

Run `get_walkthrough.sh` from this skill's directory:

```bash
<skill dir>/get_walkthrough.sh https://github.com/acme/web/pull/123
<skill dir>/get_walkthrough.sh acme/web#123
<skill dir>/get_walkthrough.sh 123    # inside a checkout of acme/web
<skill dir>/get_walkthrough.sh --wait acme/web#123    # poll for up to 15 minutes
<skill dir>/get_walkthrough.sh --wait=300 acme/web#123
```

| Exit | stdout              | stderr                                                         |
| ---- | ------------------- | -------------------------------------------------------------- |
| `0`  | The walkthrough URL | Nothing.                                                       |
| `1`  | Nothing             | The state and why there's no walkthrough (yet) (see below).    |
| `2`  | Nothing             | Bad input, a PR Softlight can't see, or Softlight unreachable. |

The script needs `curl` and `jq`. It also uses `gh` when `gh` is installed and authenticated, but it
works without it.

## Hand it over

Paste the URL bare, on its own line, so it stays clickable. Don't wrap it in code formatting, and
don't swap it for a link of your own.

## When there's no link yet

| State        | What it means                                      | What to do                                                        |
| ------------ | -------------------------------------------------- | ----------------------------------------------------------------- |
| `queued`     | The PR is new and Softlight hasn't started on it.  | Run the script with `--wait`. Tell the user the video is coming.  |
| `indexing`   | Softlight is indexing the repository first.        | Same as `queued`.                                                 |
| `running`    | The review is running and the video isn't out yet. | Same as `queued`.                                                 |
| `video_only` | The PR plays a video but has no share page.        | Tell the user the video is in the PR description.                 |
| `merged`     | The PR merged without a walkthrough.               | Tell the user there's no walkthrough.                             |
| `none`       | Softlight didn't film this PR.                     | Tell the user there's no walkthrough.                             |
| `unknown`    | GitHub didn't answer just now.                     | Run the script again in a few seconds.                            |

If `--wait` runs out with the video still on its way, tell the user it isn't ready yet and offer to
check again. Don't give them a waiting page in its place.

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
   A `401` means Softlight keeps that repository behind sign-in, so the link can't be looked up
   from here. Tell the user to open the PR's Softlight check from a browser signed in to Softlight.
