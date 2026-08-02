# LinkedIn job shortlisting pipeline — single run

You are running an unattended, hourly job-shortlisting pipeline. Work through
the phases **in order**. Do not skip a phase. Do not ask questions — there is
no human watching. Never deviate from the call budgets.

Working directory: the repository root.
All scripts below are run with:
`powershell -NoProfile -ExecutionPolicy Bypass -File <script> <args>`

## Hard constraints — violating any of these is a failed run

- **READ-ONLY on LinkedIn.** Only `mcp__linkedin__search_jobs` and
  `mcp__linkedin__get_job_details` may be called. **Never** call
  `send_message`, `connect_with_person`, `close_session`, or any write tool.
- **Max 4 `search_jobs` calls per search entry per run.** There are 3 entries
  (Mumbai, Pune, India+remote), so 12 is the absolute ceiling; a typical run
  uses **3 total** — one each.
- **Max 25 `get_job_details` calls per run, total, across both locations.**
  Hard cap. Count them as you go.
- Tool calls are serialized and unthrottled — **never** fire them in parallel
  or in a burst. Excess volume risks a LinkedIn automation warning.
- **Fail loudly on auth errors. Never retry in a loop.** If a tool returns an
  authentication/login error, stop immediately, jump to the failure path in
  Phase 8, and do NOT advance `last_run`.

---

## Phase 1 — Health check (before any search)

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\health-check.ps1
```

Exit 0 = hub up. (HTTP 406 is success — it means the server is up and
demanding an SSE client.)

**If it exits non-zero, the run ends here:**

1. Write `shortlists\YYYY-MM-DD-HH.md` recording the failure — the endpoint,
   the error detail, and the fact that no search was performed.
2. Write `state\pending_notify.json` with a single synthetic entry so the
   outage is audible:
   `[{"id":"HUB-DOWN-<YYYY-MM-DD-HH>","title":"LinkedIn hub is DOWN","company":"pipeline","score":10}]`
   then run `scripts\notify.ps1 -JobsJson .\state\pending_notify.json`.
   (The unique per-hour id means a sustained outage notifies each hour rather
   than being silently deduped after the first.)
3. **Exit WITHOUT advancing `last_run`.**

A dead server must never look like a quiet job market.

---

## Phase 2 — Resume sync

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\resume-sync.ps1
```

- `"stale": false` → do nothing. `state\profile.md` is current.
- `"stale": true` → read the PDF at the returned `resume` path, regenerate
  `state\profile.md` (identity, seniority band, domain, recent titles, skills
  split into core / secondary / working-knowledge / absent, and scoring
  guidance), then run the same script with `-Commit` to record the new hash.

Never hardcode the resume filename — the script always picks the most recently
modified PDF in `Resumes\`.

---

## Phase 3 — Read state

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\state-read.ps1
```

Gives you, per (keywords, location) pair: `last_run`, `cutoff`
(= last_run − 20 min), and `cold` (true when state was missing/corrupt, in
which case last_run is 24h ago). Note any `warnings` — they go in the output
header.

Then read `state\profile.md` — you score against it in Phase 6.

---

## Phase 4 — Search with adaptive paging

Run **each entry in `config.searches` independently**, using that entry's own
`cutoff` from Phase 3. There are currently three:

| # | location | work_type | why |
|---|---|---|---|
| 1 | `Mumbai, Maharashtra` | — | home city |
| 2 | `Pune, Maharashtra` | — | commutable / relocation |
| 3 | `India` | `remote` | **nationwide remote** |

```
mcp__linkedin__search_jobs(
  keywords     = <config.keywords>,
  location     = <this entry's location>,
  work_type    = <this entry's work_type, ONLY if the entry sets one>,
  date_posted  = "past_24_hours",
  sort_by      = "date",
  max_pages    = N )
```

**Why the remote search is separate.** A role listed as `India (Remote)` with no
city **never appears in a Mumbai or Pune search**. Measured 2026-08-01: of 11
remote-India results, only 1 (Evolent) also showed up in the city searches — the
other 10 were completely invisible, including an Akamai Senior SRE posted 8h
earlier. A city search only catches remote roles that happen to be *tagged* to
that city.

**Overlap is expected and harmless** — `seen_jobs.json` dedups on job ID, so a
job appearing in two searches is detailed once. Deduplicate IDs across all three
searches *before* Phase 5 so you never spend two `get_job_details` calls on one
job.

The 4-page budget is **per search entry**, each with its own `last_run`. Typical
run: 1 call each, 3 total.

### The `max_pages` parameter is CUMULATIVE

There is **no page-offset parameter**. `max_pages=2` re-fetches page 1 *and*
page 2. So "fetch the next page" means: call again with `max_pages` one
higher, and examine the newly revealed results. Start at `max_pages=1`.
N goes 1 → 2 → 3 → 4, which is exactly the 4-call-per-location budget.

### Trust `job_ids`, not the text blob

The response carries a text blob in `sections.search_results` **and** a
`job_ids` array. **`job_ids` is authoritative — it contains only real search
results for this query and location.**

The broad boolean query makes LinkedIn append recommendation sections after the
line `Are these results helpful?`:

```
Top job picks for you
Jobs where you're more likely to hear back
Similar to a job you applied to less than a day ago
Your job alert: ...
Expand your search / Expand date posted to past week
```

**Everything after `Are these results helpful?` is noise. Ignore all of it.**
Those blocks contain jobs from *other cities* and *far outside the date window*
— a Pune search on 2026-08-01 listed a 4-month-old Mumbai role and a 2-week-old
Blitzy posting in there. Scoring one of those would be a silent correctness bug.

Cross-check: the number of entries in `job_ids` must equal the number of result
blocks you parsed *before* that marker. If they disagree, trust `job_ids`.

### Parsing ages

Each result block, before the marker, looks like:

```
<Title>
<Company>
<Location> (On-site|Hybrid|Remote)
<"N connections work here" | "N company alumni work here">   <- optional
<relative age>                                                <- OPTIONAL, may be absent
<badge: "Within the past 24 hours" | "Be an early applicant" | "Viewed">
```

Convert each relative age to an absolute UTC timestamp, **rounding the
timestamp DOWN (older)**. LinkedIn truncates when it displays, so a job shown
as "N units ago" is actually between N and N+1 units old. Assume the oldest:

| Displayed | Assume age |
|---|---|
| "just now", "moments ago" | 1 minute |
| "N minutes ago" | N+1 minutes |
| "N hours ago" | N+1 hours |
| "1 day ago" | **48 hours** |
| "N days ago" | (N+1) × 24 hours |
| "N weeks ago" | (N+1) × 7 days |
| "Within the past 24 hours" (no other age) | 24 hours |
| **absent entirely** | **unknown** |

**Age may be absent** — a job you have already viewed shows "Viewed" where the
age would be. Handle it: a job with unknown age is still *processed* (the
`past_24_hours` filter already bounds it), but it is **excluded from the
oldest-on-page calculation** below.

If a page has **no parseable age at all**, treat `need_more_time` as *false* for
that page and add a warning — but keep honouring `need_more_items`, which does
not depend on ages. Do not stop paging just because the ages were unreadable;
that is exactly when the header count is the only signal you have.

`get_job_details` **does** carry the age for these (`"... · 9 hours ago · ..."`),
so use that authoritative value for the output and the 3-day filter once you
have it — the search-page gap only affects the paging decision.

### The paging decision — TWO independent reasons to go deeper

There are two different questions, and one does not answer the other:

1. **"Have I reached back far enough in time?"** — answered by the cutoff.
2. **"Have I enumerated everything in the window?"** — answered by the
   `N results` header versus how many IDs you actually hold.

**Page deeper if EITHER says to. Stop only when BOTH are satisfied**, or at the
4-page cap.

```
retrieved      = unique job_ids collected so far for this location
header_count   = the "N results" number near the top of search_results
oldest_on_page = min(timestamp of jobs with a parseable age on this page)

catching_up     = (cutoff is older than 2h)        # cold start or missed runs
need_more_time  = (oldest_on_page  >  cutoff)      # not far enough back yet
need_more_items = (header_count > len(retrieved)) AND catching_up

if (need_more_time OR need_more_items) AND pages_fetched < 4:
        FETCH THE NEXT PAGE          # max_pages = pages_fetched + 1
else:
        STOP
```

**Why `need_more_items` is gated on `catching_up`.** Measured 2026-08-01: Pune's
header claimed 18–22 results, but `max_pages=2` returned **exactly the same 11
IDs** as page 1. The header counts results LinkedIn will not serve through this
path, so on a normal hourly run the extra call retrieves nothing and just burns
budget. On a cold start or after a gap, full enumeration is worth one
speculative call to confirm; in steady state it is not.

#### Reason 1 — the cutoff (get the direction right)

Results are **newest-first**, so the **last** job on the page is the **oldest**.
If that oldest job is still **newer** than the cutoff, results may be truncated
and you have not yet read back to the previous successful run — **KEEP PAGING**.
Stopping there instead is the one bug that fails silently and looks identical to
a slow job market.

#### Reason 2 — full enumeration of the window

`header_count > len(retrieved)` *suggests* LinkedIn is holding results inside
the date window you have never been shown. When catching up, spend one call to
check — the cutoff rule cannot answer this question, because **results are not
strictly date-sorted**: "Viewed" jobs and reposts get reshuffled between calls,
so page 2 *can* contain jobs newer than page 1's oldest entry.

> **Measured 2026-08-01, both directions.** Pune reported 20–22 results while
> returning 11 per page. Two runs stopped at page 1 (oldest there already
> predated the cutoff), and a Barclays "DevOps Engineer" plus an Arrow "Senior
> SRE" surfaced a full day late — which looked like a paging gap.
>
> It was not. When a run finally *did* fetch page 2, it returned **exactly the
> same 11 IDs**. The header over-counts; those two jobs had rotated onto page 1,
> they were never on page 2. Deeper paging does not recover them — the 3-day
> eligibility window does, which is precisely what caught them.

So treat the header as a weak hint, not a promise. The **3-day eligibility
window in Phase 5 is the real safety net** for anything that surfaces late.

#### Stopping

**Exhaustion.** Because `max_pages` is cumulative, a deeper call on a short
result set returns *exactly the same* `job_ids`. If a deeper call reveals **no
new job IDs**, LinkedIn has no more results — **STOP immediately**, and do not
warn about the page cap. Burning the remaining calls on identical data is pure
automation risk for zero information. Treat this as authoritative even if
`header_count` still looks higher; the header is approximate.

**`header_count == len(retrieved)`** → everything is in hand. Stop.
(Mumbai, 2026-08-01: "7 results", 7 IDs → one call, done.)

Both checks are independent of age parsing, so they still work when a page has
no parseable ages at all — which is common, since "Viewed" replaces the age on
any job you have already looked at.

**Expected cost:** 1 call per location on a normal hourly run. A catch-up run
may spend a second call per location confirming enumeration. Budget is 4.

Read that twice. **"Oldest job is still NEWER than the cutoff" means KEEP
PAGING** — you have not yet reached back to the last successful run, so there
may be more new jobs just past the page boundary. Stopping here instead is the
one bug that fails silently and looks identical to a slow job market.

Record `pages_fetched` per location for the output header, **and state which
condition stopped you** — `cutoff reached`, `fully enumerated (header == N ids)`,
`exhausted (no new ids)`, or `4-page cap`. That one word is what makes a
one-page run auditable instead of ambiguous.

If a location hits the 4-page cap, emit this warning:

> WARNING: `<location>` hit the 4-page cap — the schedule may be too slow or
> the keywords too broad. Jobs older than the last page may have been missed.

If a location stops with `header_count > len(retrieved)` still true (only
possible at the cap), that is a **coverage gap** — say so explicitly and give
the shortfall, e.g. "retrieved 44 of ~60 results".

### Known limitation — surface it when it bites

`date_posted="past_24_hours"` caps what can ever be recovered at **24 hours**,
no matter how deep the paging goes. If a pair's `cutoff` is more than 24h old
(a long outage, or a cold start), paging cannot reach it. Emit:

> WARNING: cutoff for `<pair>` is `<N>`h old but `past_24_hours` caps recovery
> at 24h — jobs older than 24h in that gap are unrecoverable this run.

---

## Phase 5 — Filter

1. Collect the union of `job_ids` from all pages, per location, de-duplicated
   (cumulative paging returns earlier pages again).
2. Drop IDs already seen:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\filter-new.ps1 -Ids "<comma-separated ids>"
   ```
   Keep only the `new` array.
3. Drop anything whose assumed posted age is more than **3 days** old.

4. **Drop excluded companies.** Match each result's company name from the
   *search results* case-insensitively against `config.excluded_companies`
   (substring match, so `Hired` also catches `Hired.com`). Currently: **Hired,
   Jobs AI, CodeRound AI**.

   Do this **before** any `get_job_details` call — the company is already in the
   search text, so an excluded job should cost **zero** detail calls.

   Record each one in the `excluded` array of the result JSON (`id`, `company`,
   `title`) and count them in `counts.excluded`. They are reported, not hidden,
   so you can tell "filtered out" from "never appeared".

   Excluded jobs **still go into `seen_jobs.json`** — they were considered and
   rejected, and re-evaluating them every hour is pure waste.

If nothing survives, skip to Phase 8 and write the "nothing qualifying" file.

---

## Phase 6 — Details, applicant count, and scoring

Sort survivors **newest-first**. Call `get_job_details(job_id)` on **at most
25** across the whole run.

**Anything beyond the 25 cap must be left OUT of `seen_jobs.json`** so the
next run picks it up. Count them and report `jobs_deferred`.

### Applicant count

It is free text inside the `job_posting` string, on the same line as the age,
e.g. `"50 minutes ago · 4 applicants"`. Parse every form:

| Form | Meaning |
|---|---|
| `"N applicants"` / `"N applicant"` | exact = N |
| `"N people clicked apply"` | exact = N — **the common wording in practice** |
| `"Over N applicants"` / `"Over N people clicked apply"` | N+ — **exceeds** the threshold, treat as > N |
| `"Be among the first N applicants"` | fewer than N |
| nothing present | **unknown** |

**Observed reality:** LinkedIn currently words this as **"N people clicked
apply"**, *not* "N applicants", on essentially every promoted listing. Treat the
two as equivalent. Both the exact form ("2", "18", "27") and the capped form
("Over 100") occur.

**Prefer the exact total when available.** Further down the detail page there is
usually a `Candidates who clicked apply` block:

```
Candidates who clicked apply
1937   total
76     in the past day
```

That total is strictly better data than a capped `"Over 100"` headline — use it
when present, and mention the `in the past day` figure in the fit line when it
is small relative to the total (it means the posting is going cold, so a late
application competes with fewer live candidates).

Note this is a **click** metric, not submitted applications, and it runs high —
expect a majority of listings to exceed a threshold of 20.

### Applicant count is a SCORING INPUT, never a filter

**Do not drop anything on applicant count.** Every job that reaches this phase
gets scored and appears in the shortlist, ranked by score.

This is deliberate. The count only exists inside `get_job_details`, so filtering
on it never saved a single call — it just hid jobs from you. And it is a *click*
metric ("N people clicked apply"), not submitted applications, so a high number
is weak evidence. A 9/10 role with 200 clicks is worth seeing; a 2/10 role with
3 clicks is not.

Fold it into the score instead, against
`config.limits.applicant_soft_ceiling` (20):

- **well under the ceiling** (or "Be among the first N") → **+1, up to +2** when
  the role is otherwise a good fit. A strong match with a cold pool is the best
  thing this pipeline can find.
- **near the ceiling** → neutral.
- **far over** (`Over 100`, or an exact total in the hundreds/thousands) →
  **−1**, and say so in the fit line. Never more than −1: a genuinely excellent
  role stays a high score even in a crowded field, because you can still apply.
- **unknown** → neutral, and flag it as `unknown` in the output.

Prefer the exact `Candidates who clicked apply` total over a capped headline,
and treat a small `in the past day` figure against a large total as a positive
(the posting is going cold, so a late application competes with fewer live
candidates).

### Scoring — read the BODY, not the title

Score **1–10** against `state\profile.md`. Titles mislead and bodies
frequently contradict the listing. A real example from this exact search: a
role titled *"System Engineer"*, listed in *Mumbai*, matching a *"dev ops"*
search, whose body read *"Profile: Microstrategy Technical Specialist"* and
*"Location: Remote"*. The keyword match is loose enough that a "devops" search
in Mumbai returns Oracle Reporting, SAP CPI and Microsoft F&O roles.

From the **body**, extract:
- **actual role** (what the work really is)
- **real location** (and on-site / hybrid / remote)
- **years of experience required**
- **compensation**, if stated

**Report title/body mismatches explicitly** — role, location, or stack. These
waste the most time, so they must be visible, and they should drag the score
down hard.

### Weak-pool boost

Applicant *insights* beat raw counts. `"100% Entry level people applied for
this job"` on a role asking 3–7 years means the real competition is near zero
— a stronger signal than the headline applicant number. Boost such roles by
1–2 points and say so in the fit line.

---

## Phase 7 — Write the shortlist

**Do NOT write markdown.** Write structured data; the renderer writes the
document. That is what makes every shortlist byte-identical in layout instead of
drifting each run — and JSON costs far fewer output tokens than composed prose.

Write `state\run-result.json`, then run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\render-shortlist.ps1 -ResultJson .\state\run-result.json
```

It prints the path it wrote. It derives `shortlists\YYYY-MM-DD-HH.md` from
`run_utc` and auto-suffixes (`-17b.md`) rather than overwriting an existing
record. Ranking, the reject table, the verdict line and the "nothing new"
wording are all handled for you.

### Exact schema — emit these keys and no others

```json
{
  "run_utc": "2026-08-01T17:00:00Z",
  "search_calls": 5,
  "searches": [
    { "label": "Mumbai",         "pages": 1, "stop": "fully enumerated", "header": 3,  "got": 3  },
    { "label": "Pune",           "pages": 1, "stop": "cutoff reached",   "header": 16, "got": 10 },
    { "label": "India (remote)", "pages": 3, "stop": "exhausted",        "header": 20, "got": 11 }
  ],
  "counts": { "found": 24, "unique": 23, "new": 12, "detailed": 12, "deferred": 0, "excluded": 1 },
  "warnings": ["short strings; omit the key entirely if none"],
  "jobs": [
    {
      "id": "4447813572",
      "title": "DevOps Engineer",
      "company": "Flexiple",
      "loc": "real location FROM THE BODY, with Remote/Hybrid/On-site",
      "applicants": "96 clicked apply",
      "age": "~1h",
      "score": 9,
      "fit": "ONE sentence.",
      "gap": "ONE sentence.",
      "mismatch": "omit unless title/body/location genuinely disagree",
      "url": "https://www.linkedin.com/jobs/view/4447813572/"
    }
  ],
  "excluded": [ { "id": "999", "company": "Hired", "title": "DevOps Engineer" } ]
}
```

Rules:

- `stop` must be exactly one of: `cutoff reached`, `fully enumerated`,
  `exhausted`, `4-page cap`.
- **Every** job you detailed goes in `jobs`, whatever it scored. The renderer
  puts 5+ in the main list and everything below into a compact reject table, so
  you can still see what was considered and why it lost.
- `fit` and `gap` are **one sentence each**. No bullets, no paragraphs.
- Omit `mismatch`, `warnings`, `excluded` and `note` entirely when empty.
- Do not invent extra keys — the renderer ignores them and they cost tokens.

---

## Phase 8 — Commit state, then notify (order matters)

**Only after the shortlist file is successfully written on disk:**

1. Add every job you actually processed (called `get_job_details` on) to seen:
   ```
   .\scripts\state-commit.ps1 -AddSeen "<ids>"
   ```
   **Deferred jobs must NOT be added.**

2. Advance `last_run` — **only now**:

   ```
   .\scripts\state-commit.ps1 -AdvanceLastRun -AllPairs -RunUtc "<the now_utc from Phase 3>"
   ```

   > **Always use `-AllPairs`. Never pass `-Pairs` by hand, and never hardcode
   > a key.** State is keyed on the *full* `keywords|location` string, and
   > `keywords` is a long boolean OR query containing quotes and parentheses —
   > not the word `devops`. `-AllPairs` reads `config.json` and builds the keys
   > itself, so they cannot drift from what `state-read.ps1` looks up, and there
   > is no quoting to get wrong.
   >
   > Getting this wrong is silent and permanent: `last_run` advances under a key
   > nothing ever reads, so every subsequent run cold-starts — re-scanning 24h
   > each hour and burning the detail budget on jobs already seen — while still
   > exiting 0 and looking perfectly healthy.

   Use the `now_utc` captured in Phase 3, not the current time — anything
   posted during the run is then still inside the next run's window.

   **Verify it took:** re-run `state-read.ps1` and confirm `cold_start` is now
   `false`. If it still says `true`, the write did not land — fix it before the
   run ends.

   **A crashed or failed run must not advance the timestamp**, or that gap is
   lost permanently. If any phase failed, skip this step.

3. Notify. Write every job scoring **8, 9 or 10** to
   `state\pending_notify.json`:
   ```json
   [{"id":"<job_id>","title":"<title>","company":"<company>","score":9}]
   ```
   then:
   ```
   .\scripts\notify.ps1 -JobsJson .\state\pending_notify.json
   ```
   The script handles batching (ONE notification per run), the never-notify-
   twice guarantee via `state\notified.json`, sound, and the BurntToast →
   MessageBox fallback. It always exits 0.

   **Notification failure must never fail the run or corrupt state.** The
   shortlist file is the source of truth. If nothing scored 8+, still run it —
   it will no-op cleanly.

---

## Finally

Print **at most 6 lines** to stdout: shortlist path, pages per search, counts,
deferred, notification result, warnings. This goes to a log file, not a person.

## Token discipline

This runs every hour, forever. Cost per run matters more than polish.

- **Never quote job bodies back.** Not in your reasoning, not in the summary.
  Read the body, extract the four facts (real role, real location, years, comp),
  and move on. The bodies are the single largest cost in the run.
- **Do not re-read files you have already read** this run — `profile.md` and the
  `state-read.ps1` output are read once each.
- **Do not restate the plan** or narrate phases as you go. Execute them.
- **Do not echo tool output** back into your own text.
- `fit` and `gap` are one sentence each. That limit is a budget, not a style
  preference.
- No closing commentary beyond the 6-line summary.
