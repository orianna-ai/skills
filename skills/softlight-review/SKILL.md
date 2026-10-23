---
name: softlight-review
description: >-
  Have Softlight review the local work, uncommitted changes included, without a pull request, even
  when it is sitting on main. Use when someone asks for a Softlight review, a design review or UX
  feedback on what's in their checkout ("run softlight on this", "get a softlight review of my
  changes", "have softlight look at what I just did on main"). Works out what to compare against
  (where the branch forked, the commits not pushed yet, or the user's own latest commits on main),
  pushes the work to a softlight/<nonce> branch and prints a page that shows the review once it's
  done. For a change that already has a pull request, Softlight reviews it on its own; use
  softlight-walkthrough to see it.
---

# softlight-review

Softlight reviews every pull request on its own. For work that isn't on one, or is on `main`, this
skill asks Softlight for the same review with no pull request:

1. It picks the **base**, the commit the work is compared against (see below).
2. It pushes the work to origin as a new branch, `softlight/<nonce>`. The random nonce is what shows
   Softlight the request comes from someone who can push to the repository. Uncommitted and
   untracked changes go with it, snapshotted into a commit on top of `HEAD` without touching the
   local branch, the index or the working tree. Files `.gitignore` excludes stay behind.
3. It asks Softlight to review the change from the base to that branch. Softlight runs the full
   review a pull request gets, as a dry run: it always runs, whatever would gate a pull request's
   review, and posts nothing anywhere.
4. It prints the review's page, `https://app.softlight.com/branch-review/<review id>`, which is the
   review's share page: it waits in the share page's layout until the walkthrough's first page is
   published, then moves onto the share page at its own `app.softlight.com/demo/...` address, which
   takes in each video and check as the review publishes it. A review that films nothing shows its
   overview and comments instead.

Pushing sends the local changes to the repository's remote. If the user hasn't asked for that, check
with them first, and look over `git status` for anything that shouldn't leave the machine.

## Pick the base

Without `--base`, the script works it out:

| Where `HEAD` is                                  | Base                                                                 |
| ------------------------------------------------ | -------------------------------------------------------------------- |
| A feature branch                                 | Where it forked from origin's default branch                         |
| The default branch, with commits not pushed yet  | origin's copy of the default branch                                  |
| The default branch, all pushed, uncommitted work | `HEAD`, so only the uncommitted changes                              |
| The default branch, all pushed and clean         | The parent of the unbroken run of commits at the tip by `user.email` |

Pass `--base <rev>` whenever you know better, which you often do from the work in this session: if
you made three commits on `main` and pushed them, `--base HEAD~3` reviews exactly those. Use it too
when the last row finds nothing (someone else committed on top) or finds too much (the user's
commits from last week run straight into today's). Read `git log --oneline -20` to decide where the
work starts. The base must be an ancestor of `HEAD`.

## Start the review

Run `start_review.sh` from this skill's directory, inside the checkout. Say what to focus on if you
know it:

```bash
<skill dir>/start_review.sh "The new bulk-edit flow on the invoices page"
<skill dir>/start_review.sh --base HEAD~3      # exactly the last three commits
```

| Exit | stdout          | stderr                                                                                    |
| ---- | --------------- | ----------------------------------------------------------------------------------------- |
| `0`  | The review page | The base it compared against, and why.                                                    |
| `2`  | Nothing         | Bad input, nothing to review, a failed push, or Softlight refused or couldn't be reached. |

The script needs `git`, `curl` and `jq`, and origin must be a GitHub repository with the Softlight
app installed. Softlight's branch reviews take a signed-in maker or a repository that accepts
challenge branches; otherwise the script says so and stops after the push.

## Hand it over

A review takes 15 to 30 minutes, so don't wait on it. Paste the review page bare, on its own line,
labelled as still running, for example "Softlight review (running, ready in 15 to 30 minutes):"
followed by the link, and say what it compared against. Tell the user that's what it is: the
review's share page, which fills in on its own as Softlight films and checks the change.

Each run pushes a new ref and reviews the work as it is at that moment. Run it again after more
changes rather than reusing an old link.
