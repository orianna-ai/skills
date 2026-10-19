---
name: softlight-walkthrough
description: >-
  Get the Softlight share page for a GitHub pull request: the app.softlight.com/demo/... page with
  the walkthrough video of the change. Use when someone asks for a PR's share page, share link,
  Softlight video, walkthrough, or demo link ("get the share page for #123", "send me the video
  for this PR", "is the Softlight walkthrough ready?"), or when you've finished a pull request and
  want to hand your user its video. Takes a PR URL, owner/repo#number, or a bare number in the
  current checkout, and says why when there is no share page yet.
---

# softlight-walkthrough

Softlight reviews pull requests and films a walkthrough of each change. The **share page** is the
page that plays it: `https://app.softlight.com/demo/<owner>/<repo>/pr<number>/<token>`. The token is
random, so you can't build the URL yourself. You have to look it up.

## Quick start

Run `share_page.sh`, which sits next to this file:

```bash
<skill dir>/share_page.sh https://github.com/acme/web/pull/123
<skill dir>/share_page.sh acme/web#123
<skill dir>/share_page.sh 123    # inside a checkout of acme/web
```

The script prints the share page and exits `0`. If there's no share page yet, it prints the
walkthrough's state to stderr and exits `1`. On bad input, or if nothing could be read, it exits
`2`. It needs `curl` and `jq`. It also uses `gh`, when `gh` is installed and authenticated.

## Where the link comes from

The script tries two sources in order. If you can't run it, use the same sources yourself.

1. **The Softlight check run** on the PR's head commit. The check is named `Softlight Review` or
   `Softlight video · for your user to watch after merging`. Once the share page is published, the
   check run's `details_url` is the share page. You can read it with
   `gh pr checks <n> --repo <owner>/<repo>`, with the GitHub MCP tool `pull_request_read`
   (`method: get_check_runs`), or with
   `gh api repos/<owner>/<repo>/commits/<sha>/check-runs`. Before the share page exists, the link
   is a signed `app.softlight.com/v/...` address that opens a waiting page. That is not the share
   page yet.
2. **The status endpoint** for the PR's permanent walkthrough link:

   ```bash
   curl -sS https://app.softlight.com/api/softlight/walkthrough/<owner>/<repo>/<number>/status
   ```

   It returns JSON like `{"state": "ready", "url": "https://app.softlight.com/demo/...", ...}`. The
   endpoint needs no token. A `401` means Softlight keeps that repository behind sign-in, so the
   user has to open the link in a browser where they're signed in to Softlight.

## Reading the state

| `state`      | What it means                                       | What to tell the user                                 |
| ------------ | --------------------------------------------------- | ----------------------------------------------------- |
| `ready`      | The share page is published. `url` is the link.     | The link.                                             |
| `running`    | The review is running and the video isn't out yet.  | It's still filming. Offer the waiting page (below).   |
| `indexing`   | Softlight is indexing the repository first.         | Same as `running`.                                    |
| `queued`     | The PR is new and Softlight hasn't started on it.   | Same as `running`.                                    |
| `video_only` | The PR plays a video but has no share page.         | There's a video in the PR description, but no page.   |
| `merged`     | The PR merged without a walkthrough.                | No share page.                                        |
| `none`       | Softlight didn't film this PR.                      | No share page.                                        |
| `unknown`    | GitHub didn't answer just now.                      | Try again in a few seconds.                           |

While a video is still coming, the permanent link
`https://app.softlight.com/api/softlight/walkthrough/<owner>/<repo>/<number>` shows a waiting page.
The page turns into the share page when the video lands. It's fine to hand that link over, but say
it's a waiting page, not the video.

## Giving the link to the user

Paste the URL bare, on its own line, so it stays clickable. Don't wrap it in code formatting.
