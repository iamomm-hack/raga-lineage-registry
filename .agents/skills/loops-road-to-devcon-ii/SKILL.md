---
name: loops-road-to-devcon-ii
description: >-
  Build for the Road To Devcon - II on Loops House: ideate with the AI
  mentor, query problem knowledge graphs (graph-RAG over each problem's
  resources), create and update the project submission, save ideation
  artifacts, and check the work against each problem's success criteria. Use
  this skill whenever the user mentions Road To Devcon - II, this contest, its
  problems or standings, submitting or improving their entry, problem
  docs/stacks, judging, or asks "what should I build" — even if they never
  say "loops".
version: 0.3.2
requires_bin: loops
---

# Road To Devcon - II — Loops House skill

Help the builder compete in ONE event: `road-to-devcon-ii`. This skill carries the event data, ready-to-run `loops` commands, and the workflow below. Commands come pre-filled with the right slugs — replace only the `<angle-bracket>` placeholders. Never invent or substitute ids: the user has at most one project per event (team membership counts), and the platform resolves it from the session, so no project id appears anywhere in this skill.

The user has no project here yet. Ideate freely; create one with `loops project create` when they are ready to submit.

## Work in this order

Each step's output feeds the next:

1. **Check auth.** Run `loops auth status` before any other command and at the start of every session — sessions expire, and every other command fails confusingly without one.
2. **Orient.** Read the event data below (stage, deadlines, problems), then run `loops project get --event road-to-devcon-ii` to see where the submission stands.
3. **Ideate and research.** Brainstorm with the mentor (`ideate`); problem briefs unlock at the event start (re-run `npx loopshouse add` then); meanwhile ground problem-domain facts in `knowledge query` — cite the problem's knowledge graph instead of asserting its stack or references from memory.
4. **Persist.** Save promising directions as artifacts; create or update the submission as the project takes shape.
5. **Evaluate before the deadline.** Run `loops evaluate` for every targeted problem and act on the feedback — the judge probes the same points.

Command output is structured (add `--json` for machine-readable form) and often ends with a suggested next command (CTA) — follow it rather than guess. On `NOT_AUTHENTICATED`, run the auth flow. On `credits_exhausted`, stop and tell the user — never retry.

## Authenticate

```sh
loops auth status                        # run FIRST — who am I?
loops --version   # must match this skill's frontmatter `version`
```

If the installed CLI is older than this skill's `version`, update first (`npm install -g loopshouse@latest`) — the commands below assume the stamped version.

A failed check means the CLI still needs install + login. Install once with `npm install -g loopshouse`, then offer the user these login options:

- **Google**: `loops auth login --provider google` — opens the browser.
- **GitHub**: `loops auth login --provider github` — opens the browser.
- **Email one-time code**: `loops auth login --email <you@example.com>` sends a 6-digit code; verify with `loops auth verify --email <you@example.com> --code <123456>`.

In headless contexts the browser flows print a URL for a human to open. Re-run `loops auth status` to confirm before continuing.

## Read the event data

Treat this TOON document as ground truth for the event (TOON = compact JSON: `key: value` lines; a uniform array renders as a `name[N]{col1,col2,…}:` header plus one comma-separated row per element):

```toon
event:
  slug: road-to-devcon-ii
  name: Road To Devcon - II
  tagline: "Art, Culture & Ethereum in India"
  stage: registration_open
  stageMeaning: Registration open — enroll and start ideating
  timezone: Asia/Calcutta
  prizeCurrency: USD
  startsAt: "Aug 28, 2026, 11:11 PM (Asia/Calcutta)"
  submissionDeadline: "Aug 30, 2026, 11:11 PM (Asia/Calcutta)"
  registrationDeadline: "Aug 29, 2026, 12:00 PM (Asia/Calcutta)"
  description: null
problems[3]{title,slug}:
  The Advance That Never Shows Up,commission-escrow
  Who Taught You That Raga?,lineage-license-registry
  "The Aggregator Who Pays Late, In Cash, Minus a Cut",cooperative-treasury
```

`event.stage` and the deadlines are snapshots from when this skill was generated and do not update — sanity-check timing before planning multi-day work.

## Budget credits

**1 credit = one ideator turn or one knowledge-graph query.** Project and artifact commands and the evaluator prompt are free. Spend credits on load-bearing questions, not browsing, and check the balance before a research burst:

```sh
loops credits --event road-to-devcon-ii
```

## Ideate with the AI mentor

The mentor knows this contest's problems, briefs, and judging criteria, grounded in each problem's knowledge graph. Conversations persist locally per event (`~/.loops/sessions/`) and continue automatically — each call sends one more message, so ask follow-ups freely instead of cramming everything into one prompt.

```sh
loops ideate --event road-to-devcon-ii -m "<your prompt>"
loops ideate --event road-to-devcon-ii -m "<follow-up>"               # same conversation
loops ideate --event road-to-devcon-ii --withProject -m "<prompt>"    # mentor sees the user's project
loops ideate --event road-to-devcon-ii --new -m "<fresh start>"       # discard the session first
loops ideate --event road-to-devcon-ii --problems <problemSlug> -m "<prompt>"   # focus on one problem
loops session --event road-to-devcon-ii            # show the stored conversation (--clear to delete)
```

Pass `--withProject` once a project exists — feedback grounded in the actual build beats generic advice.

## Query problem knowledge graphs (graph-RAG)

Each problem in this contest has a knowledge graph built from its brief, resources, and reference materials. A query returns a **cited evidence block** (entities, relationships, chunks, sources) — read the evidence and compose the answer yourself, citing it. Problem briefs, stacks, and rubrics unlock when the event starts — until then the event data lists titles only. Re-run `npx loopshouse add road-to-devcon-ii` after the start to refresh this skill with the full problem data. 1 credit per query. One ready command per problem:

```sh
# The Advance That Never Shows Up
loops knowledge query --event road-to-devcon-ii --problem commission-escrow -q "<your question about The Advance That Never Shows Up>"

# Who Taught You That Raga?
loops knowledge query --event road-to-devcon-ii --problem lineage-license-registry -q "<your question about Who Taught You That Raga?>"

# The Aggregator Who Pays Late, In Cash, Minus a Cut
loops knowledge query --event road-to-devcon-ii --problem cooperative-treasury -q "<your question about The Aggregator Who Pays Late, In Cash, Minus a Cut>"
```

## Manage the project

The project IS the submission. The user has at most one here, and the platform resolves it from the session — no ids, no listings.

```sh
loops project get --event road-to-devcon-ii       # current state (exists=false if none yet)
loops project create --event road-to-devcon-ii --repoUrl <url>
loops project update --event road-to-devcon-ii --description "<new description>"
```

**The repo IS the entry**: create ONLY when a real GitHub repository exists to submit — the platform rejects a repo-less compete submission. Never create a placeholder entry "to fill in later"; the user then has to repair it by hand.

**Update is a PATCH**: only the fields you pass change — an update with just `--tagline` cannot wipe the repo URL. Fields: `--name`, `--tagline`, `--pitch`, `--description`, `--repoUrl`, `--demoUrl`, `--videoUrl`.

## Save ideation artifacts

Save ideas, problems, and tech-stack notes against this event — they appear in the user's web playground too, so persist anything worth keeping instead of letting it die in the conversation. Kinds: `idea`, `problem`, `tech-stack`, `note`.

```sh
loops artifact list --event road-to-devcon-ii
loops artifact save --event road-to-devcon-ii --name "<title>" --kind idea --body "<markdown body>"
loops artifact update --event road-to-devcon-ii --id <artifactId> --body "<updated markdown>"
loops artifact remove --event road-to-devcon-ii --id <artifactId>
```

## Evaluate the project against a problem

Fetch a self-contained evaluator prompt for one problem (free; the platform attaches the user's project record), then **execute the prompt yourself inside the project repo** — it assumes the code access you have. The prompt walks that problem's brief, success criteria, and weighted judging criteria and returns alignment feedback: verified strengths, gaps, and where to focus. Run it for every problem the project targets, well before the deadline.

```sh
# The Advance That Never Shows Up
loops evaluate --event road-to-devcon-ii --problem commission-escrow

# Who Taught You That Raga?
loops evaluate --event road-to-devcon-ii --problem lineage-license-registry

# The Aggregator Who Pays Late, In Cash, Minus a Cut
loops evaluate --event road-to-devcon-ii --problem cooperative-treasury
```

Report the feedback to the user, then apply agreed improvements via `loops project update`.
