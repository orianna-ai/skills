---
name: softlight-review
description: >-
  Have Softlight review the local work, uncommitted changes included, even when it isn't on a pull
  request or is sitting on main. Use when someone asks for a Softlight review, a design review or
  UX feedback on what's in their checkout ("run softlight on this", "get a softlight review of my
  changes", "have softlight look at what I just did on main"). Works out what to compare against
  (where the branch forked, the commits not pushed yet, or the user's own latest commits on main),
  pushes the work and that base as softlight/<nonce> branches, and opens a throwaway draft pull
  request between them that softlight[bot] reviews. For a change that already has a pull request,
  Softlight reviews it on its own; use softlight-walkthrough to see it.
---

# softlight-review

Softlight only reviews pull requests: `softlight[bot]` reviews each one when it opens and again on
every push. Work in a checkout often isn't on one, or is on `main`, where there's no pull request to
open. This skill makes one that holds exactly the work:

1. It picks the **base**, the commit the work is compared against (see below).
2. It pushes two branches to origin: `softlight/<nonce>` holds the work and `softlight/<nonce>-base`
   holds the base. Uncommitted and untracked changes go with the work, snapshotted into a commit on
   top of `HEAD` without touching the local branch, the index or the working tree. Files
   `.gitignore` excludes stay behind.
3. It opens a draft pull request from the first into the second, so the diff Softlight reviews is
   exactly base → work, and prints it with its Softlight walkthrough page.

Pushing sends the local changes to the repository's remote and opens a pull request others can see.
If the user hasn't asked for that, check with them first, and look over `git status` for anything
that shouldn't leave the machine.

## Pick the base

Without `--base`, the script works it out:

| Where `HEAD` is                                  | Base                                                                |
| ------------------------------------------------ | ------------------------------------------------------------------- |
| A feature branch                                 | Where it forked from origin's default branch                        |
| The default branch, with commits not pushed yet  | origin's copy of the default branch                                 |
| The default branch, all pushed, uncommitted work | `HEAD`, so only the uncommitted changes                             |
| The default branch, all pushed and clean         | The parent of the unbroken run of commits at the tip by `user.email` |

Pass `--base <rev>` whenever you know better, which you often do from the work in this session: if
you made three commits on `main` and pushed them, `--base HEAD~3` reviews exactly those. Use it too
when the last row finds nothing (someone else committed on top) or finds too much (the user's
commits from last week run straight into today's). Read `git log --oneline -20` to decide where the
work starts. The base must be an ancestor of `HEAD`.

## Open the review

Run `open_review.sh` from this skill's directory, inside the checkout. Say what to focus on if you
know it; it goes in the pull request's description:

```bash
<skill dir>/open_review.sh "The new bulk-edit flow on the invoices page"
<skill dir>/open_review.sh --base HEAD~3      # exactly the last three commits
<skill dir>/open_review.sh --ready            # ready for review rather than a draft
```

| Exit | stdout                                         | stderr                                                                       |
| ---- | ---------------------------------------------- | ---------------------------------------------------------------------------- |
| `0`  | The pull request, then its walkthrough page    | `gh`'s own progress, if any.                                                 |
| `2`  | Nothing                                        | Bad input, nothing to review, a failed push, or GitHub refused the pull request. |

The script needs `git` and a signed-in `gh`, and origin must be a GitHub repository with the
Softlight app installed. The pull request is opened as whoever `gh` is signed in as, and Softlight
applies its usual rules to it: an author it doesn't review for, or a change with no visible UI, gets
no review. Draft pull requests are reviewed unless the organization turned that off; pass `--ready`
if it did.

## Hand it over

The review takes several minutes, so don't wait on it. Give the user the pull request link and,
under it, the walkthrough page, labelled as still running, for example "Softlight review (running,
ready in a few minutes):". The review lands as comments on the pull request; the walkthrough page
shows the video once it's made (`softlight-walkthrough` can check on it).

If Softlight skips it (the "Softlight Review" check says so), a human commenting `@softlight` on the
pull request runs it anyway. A comment from a bot token is ignored.

Each run opens a new pull request on the work as it is at that moment. Close the old one and run it
again after more changes rather than reusing it. When the user is done with it, close it and delete
both branches:

```bash
gh pr close <number> --delete-branch
git push origin --delete softlight/<nonce>-base
```
