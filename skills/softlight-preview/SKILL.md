---
name: softlight-preview
description: >-
  Have Softlight boot a live, clickable preview of the local branch, uncommitted changes included,
  without opening a pull request. Use when someone wants to try or click through the work in their
  checkout ("give me a preview link", "spin up a preview of this branch", "let me click around this
  before I open a PR", "boot this so I can try it"). Pushes the branch to a softlight/<nonce> branch
  and prints a preview page that shows the running app once it boots. For a change that already has
  a pull request, use softlight-walkthrough.
---

# softlight-preview

Softlight can boot the app on a branch and serve it live, so someone can click through the change in
their browser without running anything. This skill hands it the work in the checkout:

1. It pushes the branch to origin as a new branch, `softlight/<nonce>`. The random nonce is what
   shows Softlight the request comes from someone who can push to the repository. Uncommitted and
   untracked changes go with it, snapshotted into a commit on top of `HEAD` without touching the
   local branch, the index or the working tree. Files `.gitignore` excludes stay behind.
2. It asks Softlight for a preview of that ref. Softlight checks the ref out, works out which app
   the change lands in, and boots it with the repository's boot recipe.
3. It prints the preview page, `https://app.softlight.com/preview/<preview id>`, which says it's
   booting and then shows the running app.

Pushing sends the local changes to the repository's remote. If the user hasn't asked for that, check
with them first, and look over `git status` for anything that shouldn't leave the machine.

## Start the preview

Run `start_preview.sh` from this skill's directory, inside the checkout. Say what to look at if you
know it, which helps pick the app in a repository with several. You usually do, from the work you
just did:

```bash
<skill dir>/start_preview.sh "The new bulk-edit flow on the invoices page"
<skill dir>/start_preview.sh    # boots the app the branch's changes land in
```

| Exit | stdout           | stderr                                                                 |
| ---- | ---------------- | ---------------------------------------------------------------------- |
| `0`  | The preview page | Nothing.                                                               |
| `2`  | Nothing          | Bad input, a failed push, or Softlight refused or couldn't be reached. |

The script needs `git`, `curl` and `jq`, and origin must be a GitHub repository with the Softlight
app installed. Softlight boots a repository with the recipe its reviews set up, so a repository
Softlight hasn't reviewed yet gets a page saying it can't boot it.

## Hand it over

Booting takes a few minutes, so don't wait on it. Paste the preview page bare, on its own line,
labelled as still booting, for example "Live preview (booting, ready in a few minutes):" followed by
the link. Tell the user that's what it is: a page that shows the running app once it's up, and
refreshes itself until then.

Each run pushes a new ref and boots the branch as it is at that moment. Run it again after more
changes rather than reusing an old link.
