# LinkedIn Job Shortlister

Polls LinkedIn on a schedule, reads the **body** of every new job, scores it
against your CV, and sends one desktop notification when something genuinely
worth applying to appears.

Built for a simple problem: in a competitive market the useful window on a good
posting is measured in minutes, and job titles lie constantly.

**Windows. No Docker. Runs mostly without an LLM.**

---

## Why bother

A plain `devops` keyword search across two cities returned **nine jobs, none of
which was a DevOps role** — Oracle BI reporting, SAP integration, Microsoft
Dynamics, Windows server support, ITIL service management. That is what LinkedIn's
matcher does with a single keyword.

Reading bodies rather than titles catches things like:

| Listed as | Actually |
|---|---|
| "Senior Site Reliability Engineer" | A data-science/ML role. Body: *"not a standard QA, DevOps, or operational position"* |
| "Infra Tech Support Practitioner", Pune | A **Remote**, 12+ year Flexera ITAM specialist post |
| "GCP Infrastructure Engineer" | An AVP-level management role |
| "DevOps Engineer", Mumbai | Real location **Bengaluru** |
| "Cloud Engineer" | Azure L2 support desk |

Every one of those came from a single day of real runs.

## What it does

1. **Searches** several locations independently, each with its own history, and
   pages deeper automatically after downtime.
2. **Filters** out jobs already seen, too old, from blocked companies, or with
   obviously wrong titles — before spending any API call on them.
3. **Reads the body** of each survivor: real role, real location, years required,
   compensation, applicant count.
4. **Scores 1–10** against your CV — deterministic rules first, then a single
   cheap LLM call for the judgement calls.
5. **Writes a shortlist** to `shortlists/YYYY-MM-DD-HH.md`, best first.
6. **Notifies once** per run when something clears the bar.

Nothing is ever hidden. Rejected, stale, saturated and blocked jobs all appear
in the shortlist with the reason.

## Cost

The pipeline is a Python script talking JSON-RPC to the MCP server. **No model
is involved** in searching, paging, state, dedup, filtering, applicant parsing,
rule scoring, rendering or notification.

A model is called **once per run, only when there are new jobs worth judging.**

| Situation | Model cost |
|---|---|
| No new jobs (most runs) | **0 tokens** |
| N new jobs | 1 call, **~1.1k tokens per job** |
| `llm.enabled: false` | **0 tokens, ever** |

Three things get you there: **zero-token idle runs**, **stripped job
descriptions** (company marketing, competitor analysis and "More jobs" blocks
removed — 51% measured), and **title pre-rejection** before any detail call.

Defaults to Claude Haiku.

---

## Requirements

- **Windows 10/11** (PowerShell 5.1 — ships with Windows)
- **Python 3.9+** on `PATH`
- **[uv](https://docs.astral.sh/uv/)** for `uvx`
- A **LinkedIn account**
- *Optional:* the [Claude CLI](https://claude.com/claude-code) for LLM scoring.
  Skip it and set `llm.enabled: false` — everything else still works.

---

## Setup

### 1. Get the code

```bash
git clone https://github.com/<you>/linkedin-job-shortlister.git
cd linkedin-job-shortlister
```

### 2. Log in to LinkedIn once

This opens a browser and saves a session to `~/.linkedin-mcp/profile`.

```bash
uvx mcp-server-linkedin@latest --login
```

> Run `--login` and `--logout` with **no other client running**. The browser
> profile lock does not span processes safely.

### 3. Start the server

```bash
start-linkedin-hub.bat
```

One long-lived process on `http://localhost:8080/mcp`. The launcher refuses to
start a second one, and polls until the endpoint answers rather than sleeping a
guessed number of seconds.

> A plain GET returns **406 Not Acceptable** — that is **success**. It means the
> server is up and expecting an SSE client.

Start it automatically at login:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-startup-shortcut.ps1
```

### 4. Describe yourself — the one step that matters most

**`scoring.json > profile_brief` is the only thing the model is ever told about
you.** This is the required step; get it right and everything else is tuning.

Keep it under ~200 words — it is sent on every judged run, so length costs
tokens on every job. Be blunt about what you **do not** have: the `ABSENT` list
is what lets the scorer reject plausible-looking mismatches rather than rating
every AWS-adjacent role an 8.

Fastest way, if you have the Claude CLI:

```bash
claude "Read my CV at <path-to-your-cv.pdf> and rewrite the profile_brief field in scoring.json to describe me. Keep it under 200 words and be explicit about skills I lack."
```

Then tune the keyword weights in the same file:

- `positive` / `negative` — **negatives do the real work.** Positives are capped
  on purpose (see below).
- `title_reject` — titles rejected before any API call is spent
- `freshness`, `saturation` — how aggressively to skip stale or crowded postings

### 5. Configure the search

**`config.json`** — what to look for:

- `keywords` — use a boolean OR query, not one word (the file's comment has the
  measured difference)
- `searches` — one entry per location. **Include a nationwide remote entry:** a
  job listed as `India (Remote)` with no city never appears in a city search. Of
  11 remote-only results in testing, just 1 also showed up in the city searches.
- `excluded_companies` — aggregators and reposters you never want to see
- `notify` — when a toast is allowed to fire

### 5b. Optional: CV file and `state/profile.md`

**Not required by `pipeline.py`** — it scores from `profile_brief` alone.

These exist for the alternative model-driven path in `prompts/run-pipeline.md`,
and as a fuller human-readable record. If you want them: drop one PDF into
`Resumes/` (newest `.pdf` wins, filenames are never hardcoded) and copy
`state/profile.template.md` to `state/profile.md`.

`scripts/resume-sync.ps1` fingerprints the PDF so the profile is only rebuilt
when the CV actually changes.

### 6. Enable LLM scoring (optional)

```bash
claude setup-token
```

It **prints** a token; it does not save one. Store it as a **User** variable so
the scheduled task inherits it:

```bash
powershell -NoProfile -Command "[Environment]::SetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN','PASTE_TOKEN_HERE','User'); Write-Host 'Set.'"
```

> **Open a new terminal afterwards.** Setting a User variable does not touch
> already-running processes, so testing in the same window shows
> `Not logged in` and looks exactly like a bad token.

### 7. Notifications

```bash
powershell -NoProfile -Command "Install-Module -Name BurntToast -Scope CurrentUser -Force"
```

Without it, the pipeline falls back to a message box. Test both paths:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-notify.ps1
```

### 8. First run

```bash
python pipeline.py
```

Check the newest file in `shortlists/`. Once you are happy, schedule it:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\register-schedule.ps1 -Register -IntervalMinutes 30
```

Inspect or remove with `-Show` / `-Remove`.

---

## Verify before trusting it

**Notifications** — the one thing that fails for reasons unrelated to code.
Test by hand *and* via the scheduler, since a toast can work in a terminal and
be invisible from a scheduled task:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\register-schedule.ps1 -NotifyTest
powershell -NoProfile -Command "Start-ScheduledTask -TaskName 'LinkedInNotifyTest'"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\register-schedule.ps1 -NotifyTest -Remove
```

If it reports PASS but you saw nothing: Focus Assist, notification permissions,
or the task missing interactive logon.

**Server down** — stop the hub and run once. It must write a shortlist recording
the failure, fire a notification, and leave `state/last_run.json` **unchanged**.
A dead server must never look like a quiet job market.

**Recovery** — rewind and confirm it pages deeper:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-last-run.ps1 -HoursAgo 12
python pipeline.py
```

The header should log 2+ pages. If it fetches one page and reports nothing new,
check the "N results" count first — genuine exhaustion and an inverted paging
condition look identical from the outside.

---

## How it works

```
config.json      what to search for, where, and when to notify
scoring.json     who you are, and how to score
pipeline.py      the whole deterministic pipeline
scripts/         state, notification, scheduling, rendering
prompts/         reference spec (design notes, not executed)
state/           profile, last_run, seen_jobs, notified
shortlists/      YYYY-MM-DD-HH.md, one per run
```

### Adaptive paging

Each search tracks its own `last_run`. The cutoff is `last_run - 20 min` to
absorb scheduler drift.

Results are newest-first, so the **last** job on a page is the **oldest**. If
that oldest job is still **newer** than the cutoff, results may be truncated —
so it fetches another page. After downtime it automatically pages deeper until
it reads past the gap, then stops. Normal runs cost one call per search.

> `max_pages` is **cumulative** — there is no page offset. Paging means calling
> again with a higher `max_pages`. A deeper call returning no new IDs means
> exhaustion; stop immediately.

### Scoring

Deterministic rules run first and decide **ranking** and **who is worth an LLM
call** — they are not a verdict. Measured against real model scores, mean
absolute error was ~2.4 points.

Positive keywords are capped hard. They are table stakes: nearly every posting
in a field mentions that field's core stack, and summing them uncapped made
every job score 10/10. The **negatives** discriminate.

### Notifications

One batched toast per run, never one per job — a catch-up run can produce a
dozen. `state/notified.json` guarantees a job never alerts twice. Notification
failure never fails the run: the shortlist file is the source of truth.

---

## Safety

- **Read-only.** Only `search_jobs` and `get_job_details` are ever called.
  `send_message` and `connect_with_person` are blocked in code, not just by
  convention.
- **Rate limited.** Max 4 search calls per location per run, 25 detail calls per
  run, all serialised. Excessive volume risks a LinkedIn automation warning.
- **Fails loudly** on auth errors, and never retries in a loop.
- **`last_run` advances only after** a shortlist is written. A crashed run that
  advanced it would lose that window permanently.

## Privacy

`.gitignore` excludes your CV, generated profile, run state, shortlists and
logs. Nothing personal is committed by default.

The auth token belongs in the `CLAUDE_CODE_OAUTH_TOKEN` environment variable,
never in a file. Note that a User environment variable is readable by any
process running as you — the usual trade-off for an unattended task.

---

## Gotchas

**PowerShell 5.1 encoding.** A literal em-dash in a BOM-less UTF-8 `.ps1`
decodes as CP1252 into a smart quote, which the parser treats as a string
delimiter — breaking every string after it, reported as unrelated errors on
later lines. Keep `.ps1` files ASCII and emit Unicode via `[char]` codes.
`Set-Content -Encoding utf8` writes a **BOM**, so Python must read `utf-8-sig`.

**PowerShell 5.1 arrays.** `ConvertFrom-Json` emits a JSON array as a *single*
object, so `@(Get-Content x | ConvertFrom-Json)` gives a one-element array
containing the whole list. Assign first, then wrap. Returning a `HashSet` from a
function unrolls it — use `return ,$set`.

**LinkedIn quirks.** The "N results" header over-counts what pagination will
actually serve. Jobs you have viewed show "Viewed" instead of an age. Broad
queries append recommendation blocks containing jobs from other cities and
outside the date window — trust `job_ids`, ignore everything after
`Are these results helpful?`.

**Scheduled tasks.** Must run with interactive logon or toasts cannot render.
Hiding the *window* is fine and does not change the session — this repo uses a
VBScript shim so no console flashes on screen every run.

---

## Credits

Built on **[linkedin-mcp-server](https://github.com/stickerdaniel/linkedin-mcp-server)**
by [Daniel Sticker](https://github.com/stickerdaniel) — the MCP server that does
all the actual LinkedIn work. This project is only a scheduler, scorer and
notifier on top of it. If it is useful to you, star that repo.

## Disclaimer

Unaffiliated with LinkedIn. Automating LinkedIn may conflict with its Terms of
Service; you use this at your own risk. The defaults are deliberately
conservative — read-only, hard call caps, serialised requests — but no volume of
automation is guaranteed safe. Start slow.

## Licence

MIT — see [LICENSE](LICENSE).
