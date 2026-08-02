# Notes for Claude Code

Context for anyone (human or model) working on this repo.

## Execution path

**`python pipeline.py`** is what runs. It speaks JSON-RPC to the MCP hub
directly and needs no model.

`prompts/run-pipeline.md` is **reference only** — the original all-model
specification. It documents intent (paging rules, age parsing, applicant forms,
scoring) and still works via `claude -p`, but it is not what the scheduler runs.
Change `pipeline.py`; treat the prompt as design notes.

## Architecture

The MCP server is a **single long-lived process** on `http://localhost:8080/mcp`,
shared by every client. Never use stdio — that spawns a fresh server and
cold-starts Chromium per run, and two processes fight over the same browser
profile at `~/.linkedin-mcp/profile`.

Deterministic work lives in scripts so it behaves identically every run:

- `scripts/health-check.ps1` — is the hub up (406 = yes)
- `scripts/resume-sync.ps1` — newest PDF, SHA256 vs `state/resume.hash`
- `scripts/state-read.ps1` — last_run → cutoff per search; corruption → fresh
- `scripts/state-commit.ps1` — the ONLY writer of `state/*.json`, atomic
- `scripts/render-shortlist.ps1` — JSON → markdown, so layout never drifts
- `scripts/notify.ps1` + `Notify.Core.ps1` — one batched toast per run

## Non-negotiable rules

- **READ-ONLY on LinkedIn.** Only `search_jobs` and `get_job_details`. Write
  tools are blocked in `pipeline.py`, not merely avoided.
- **Max 4 `search_jobs` per search entry per run**; typical run uses 1 each.
- **Max 25 `get_job_details` per run**, hard cap.
- Calls are serialised and unthrottled — never parallelise or burst them.
- **Fail loudly on auth errors. Never retry in a loop.**
- `--login` / `--logout` only with no other client active.
- `last_run` advances **only after** the shortlist is written. A crashed run
  that advanced it would lose that window permanently.

## State keys

State is keyed on `keywords|location|work_type`. **Never hardcode these** — use
`state-commit.ps1 -AdvanceLastRun -AllPairs`, which derives them from
`config.json`. Getting a key wrong is silent and permanent: `last_run` advances
under a key nothing reads, so every run cold-starts forever while still exiting 0.

## PowerShell 5.1 traps that already bit this code

- `return $hashSet` **unrolls** into the pipeline; the caller gets an array or
  `$null`. Use `return ,$set`.
- `@(Get-Content x | ConvertFrom-Json)` on a JSON **array** yields a 1-element
  array containing the whole list. Assign first, then wrap.
- `Sort-Object` returns a **scalar** for one item, and `$obj[0]` on a
  PSCustomObject is `$null`. Wrap sorts in `@()`.
- `param(...)` followed by a statement on the same line is a parse error,
  reported as unrelated "empty pipe element" errors further down.
- Keep `.ps1` files **pure ASCII**. A BOM-less UTF-8 em-dash decodes to a smart
  quote and breaks string parsing. Emit Unicode via `[char]` codes.
- `Set-Content -Encoding utf8` writes a **BOM** — Python must read `utf-8-sig`.
- No `&&`, no ternary, no `??`.

## Credits

Built on [linkedin-mcp-server](https://github.com/stickerdaniel/linkedin-mcp-server)
by Daniel Sticker.
