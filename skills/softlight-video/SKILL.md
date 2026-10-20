---
name: softlight-video
description: >-
  Have Softlight make a demo video of the local branch, uncommitted changes included, without
  opening a pull request. Use when someone asks for a video or demo of the work in their checkout
  ("make a video of this branch", "film my changes", "show me what this looks like before I open a
  PR"). Pushes the branch to a softlight/<nonce> branch and prints a demo page that fills in once
  the video is made. For a change that already has a pull request, use softlight-walkthrough
  instead.
---

# softlight-video

Softlight films a walkthrough of every pull request on its own (see `softlight-walkthrough`). For
work that isn't in a pull request yet, this skill hands it to Softlight's demo maker:

1. It pushes the branch to origin as a new branch, `softlight/<nonce>`. The random nonce is what
   shows Softlight the request comes from someone who can push to the repository. Uncommitted and
   untracked changes go with it, snapshotted into a commit on top of `HEAD` without touching the
   local branch, the index or the working tree. Files `.gitignore` excludes stay behind.
2. It asks Softlight for a demo page of that ref. Softlight checks the ref out, plans the videos and
   films them.
3. It prints the demo page, `https://app.softlight.com/v/<demo id>`, which shows the progress and
   plays the videos once they're made.

Pushing sends the local changes to the repository's remote. If the user hasn't asked for that, check
with them first, and look over `git status` for anything that shouldn't leave the machine.

## Film the branch

Run `generate_video.sh` from this skill's directory, inside the checkout. Say what to show if you
know it. You usually do, from the work you just did:

```bash
<skill dir>/generate_video.sh "Show the new bulk-edit flow on the invoices page"
<skill dir>/generate_video.sh    # films the change against origin's default branch
```

| Exit | stdout        | stderr                                                                 |
| ---- | ------------- | ---------------------------------------------------------------------- |
| `0`  | The demo page | Nothing.                                                               |
| `2`  | Nothing       | Bad input, a failed push, or Softlight refused or couldn't be reached. |

The script needs `git`, `curl` and `jq`, and origin must be a GitHub repository with the Softlight
app installed. Softlight's demo maker wants a signed-in maker for now; until the challenge branch
counts as one, the script says so and stops after the push.

## Hand it over

Making the video takes a few minutes, so don't wait on it. Paste the demo page bare, on its own
line, labelled as still filming, for example "Demo video (filming, ready in a few minutes):"
followed by the link. Tell the user that's what it is: a page that plays the video once it's made.

If the user later asks whether it's ready, read the page's state:

```bash
curl -sS https://app.softlight.com/api/demo-videos/<demo id>
```

Each entry in `turns` is a video. `status` is `ready` with a `video_url` once it's made, `failed`
with a `reason` when it wasn't, and `waiting`, `queued` or `filming` while it's still coming.

Each run pushes a new ref and films the branch as it is at that moment. Run it again after more
changes rather than reusing an old link.
