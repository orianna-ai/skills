---
name: softlight-walkthrough
description: >-
  Get the link to a pull request's Softlight walkthrough: the app.softlight.com/demo/... page
  that plays a video of the change. Use whenever someone asks for a PR's walkthrough, Softlight
  video, share page, share link, or demo link ("get the walkthrough for #123", "send me the video
  for this PR", "is the Softlight video ready?"). Also use it on your own after you open, push to,
  or finish a pull request in a repository Softlight reviews, so you can hand your user the
  walkthrough link with your summary. Takes a PR URL, owner/repo#number, or a bare number in the
  current checkout, and says why when there's no walkthrough yet.
---

# softlight-walkthrough

Softlight reviews pull requests and films a walkthrough video of each change. The walkthrough lives
on a share page, `https://app.softlight.com/demo/<owner>/<repo>/pr<number>/<token>`. The token is
random, so you can't build the URL yourself. You have to look it up.

## Get the link

Run `get_walkthrough.sh` from this skill's directory:

```bash
<skill dir>/get_walkthrough.sh https://github.com/acme/web/pull/123
<skill dir>/get_walkthrough.sh acme/web#123
<skill dir>/get_walkthrough.sh 123    # inside a checkout of acme/web
```

| Exit | stdout              | stderr                                                         |
| ---- | ------------------- | -------------------------------------------------------------- |
| `0`  | The walkthrough URL | Nothing.                                                       |
| `1`  | Nothing             | The state and why there's no walkthrough yet (see below).      |
| `2`  | Nothing             | Bad input, a PR Softlight can't see, or Softlight unreachable. |

The script needs `curl` and `jq`. It also uses `gh` when `gh` is installed and authenticated, but
it works without it.

## Hand it over

Paste the URL bare, on its own line, so it stays clickable. Don't wrap it in code formatting, and
don't swap it for a link of your own.

If you opened the pull request yourself, the video usually lands a few minutes after the push. If
the state is `queued`, `indexing` or `running`, tell the user it's still filming and give them the
waiting page (below). Don't block your reply on it.

## When there's no link yet

| State        | What it means                                       | What to tell the user                     |
| ------------ | --------------------------------------------------- | ----------------------------------------- |
| `queued`     | The PR is new and Softlight hasn't started on it.   | It's coming. Give them the waiting page.  |
| `indexing`   | Softlight is indexing the repository first.         | Same as `queued`.                         |
| `running`    | The review is running and the video isn't out yet.  | Same as `queued`.                         |
| `video_only` | The PR plays a video but has no share page.         | The video is in the PR description.       |
| `merged`     | The PR merged without a walkthrough.                | There's no walkthrough.                   |
| `none`       | Softlight didn't film this PR.                      | There's no walkthrough.                   |
| `unknown`    | GitHub didn't answer just now.                      | Run the script again in a few seconds.    |

The waiting page is
`https://app.softlight.com/api/softlight/walkthrough/<owner>/<repo>/<number>`. It shows the
review's progress and turns into the walkthrough when the video lands. Tell the user that's what
it is, not the video itself.

## Without the script

The script reads two sources in order. You can read them yourself.

1. **The Softlight check run** on the PR's head commit. It's named
   `Softlight video · for your user to watch after merging` or `Softlight Review`. Once the video
   is published, the check run's `details_url` is the walkthrough URL. You can read it with
   `gh pr checks <n> --repo <owner>/<repo>`, or with the GitHub MCP tool `pull_request_read`
   (`method: get_check_runs`). Until the video is published, the link is a signed
   `app.softlight.com/v/...` address that opens the waiting page instead.
2. **The status endpoint**, which needs no token:

   ```bash
   curl -sS https://app.softlight.com/api/softlight/walkthrough/<owner>/<repo>/<number>/status
   ```

   It returns JSON like `{"state": "ready", "url": "https://app.softlight.com/demo/...", ...}`.
   A `ready` state means `url` is the walkthrough. Any other state is one of those in the table
   above. A `401` means Softlight keeps that repository behind sign-in, so give the user the
   waiting page to open in a browser where they're signed in to Softlight.
