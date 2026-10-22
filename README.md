# skills

Agent skills for working with Softlight.

| Skill                                                    | What it does                                                                            |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| [`softlight-walkthrough`](skills/softlight-walkthrough/) | Shows what a pull request's change looks like via its Softlight walkthrough video.      |
| [`softlight-preview`](skills/softlight-preview/)         | Pushes the local branch and has Softlight boot a live preview of it, no PR needed.      |
| [`softlight-review`](skills/softlight-review/)           | Pushes the local work and has Softlight review it against the right base, no PR needed. |

## Install

Install with the [skills CLI](https://github.com/vercel-labs/skills):

```bash
npx skills add orianna-ai/skills
```

It asks which skills to install and which agents to install them for. To skip the prompts, name
them:

```bash
npx skills add orianna-ai/skills --skill softlight-walkthrough -a claude-code -y
```

Skills install into your project by default (for Claude Code, `.claude/skills/`), so you can commit
them and everyone working in the repository gets them. Add `-g` to install for your user instead.
Run `npx skills update` to pull in new versions.

Your agent picks up a skill in its next session and uses it whenever a request matches the skill's
description. In Claude Code, you can also run a skill yourself as a slash command
(`/softlight-walkthrough`).
