#!/usr/bin/env python3
"""
pipeline.py - hybrid LinkedIn job shortlister.

Everything deterministic runs here with NO model in the loop: MCP calls,
adaptive paging, state, dedup, company exclusions, applicant parsing, rule
scoring, rendering, notification.

A model is invoked exactly once per run, and only when there is something worth
judging. Its input is a set of STRIPPED job descriptions (boilerplate removed),
not raw tool output.

Cost shape:
  - no new jobs            -> 0 tokens   (the common case on an hourly schedule)
  - N new jobs             -> 1 call, ~700 tokens of JD each instead of ~4500
  - scoring.json llm.enabled=false -> 0 tokens, ever (rule scores only)

Read-only on LinkedIn: only search_jobs and get_job_details are ever called.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(ROOT, "state")
LOGS = os.path.join(ROOT, "logs")
MCP_URL = "http://127.0.0.1:8080/mcp"

WRITE_TOOLS = {"send_message", "connect_with_person", "close_session", "logout"}


def log(msg):
    print(msg, flush=True)


def load_json(path, default=None):
    # utf-8-sig, not utf-8: PowerShell 5.1's `Set-Content -Encoding utf8`
    # emits a BOM, and state-commit.ps1 writes every state file that way.
    # Plain utf-8 chokes on the BOM and silently returns the default, which
    # would look exactly like "state missing -> cold start" forever.
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            txt = f.read().strip()
        return json.loads(txt) if txt else default
    except Exception:
        return default


def write_json_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


# --------------------------------------------------------------------------
# MCP client (JSON-RPC over streamable HTTP)
# --------------------------------------------------------------------------
class Mcp:
    def __init__(self, url=MCP_URL):
        self.url = url
        self.sid = None
        self._id = 0
        self.search_calls = 0
        self.detail_calls = 0

    def _rpc(self, method, params=None, notify=False, timeout=180):
        self._id += 1
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if not notify:
            body["id"] = self._id
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.sid:
            headers["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(
            self.url, data=json.dumps(body).encode(), headers=headers, method="POST"
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            got = r.headers.get("Mcp-Session-Id")
            if got:
                self.sid = got
            raw = r.read().decode("utf-8", "replace")
        raw = raw.lstrip("﻿")
        if not raw.strip():
            return None

        # Server-sent events may lead with ANY of: "event:", "data:", "id:",
        # "retry:", or a ":" keepalive comment. Keying off only event:/data:
        # meant a frame beginning with id: or a heartbeat fell through to
        # json.loads() and crashed the run with "Expecting value: line 1
        # column 1". Look for a data: line anywhere instead.
        if "\ndata:" in raw or raw.startswith("data:"):
            payload = None
            for line in raw.splitlines():
                if line.startswith("data:"):
                    chunk = line[5:].strip()
                    if chunk and chunk != "[DONE]":
                        payload = chunk
            if payload is None:
                return None
            return json.loads(payload)

        try:
            return json.loads(raw)
        except json.JSONDecodeError as e:
            # Never fail with a bare parser error - say what actually arrived.
            snippet = raw.strip().replace("\n", " ")[:200]
            raise RuntimeError(
                f"{method}: expected JSON or SSE, got {len(raw)} chars: {snippet!r}"
            ) from e

    def connect(self):
        r = self._rpc(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "linkedin-pipeline", "version": "2.0"},
            },
            timeout=30,
        )
        if not r or "result" not in r:
            raise RuntimeError("MCP initialize failed")
        self._rpc("notifications/initialized", {}, notify=True)
        return r["result"].get("serverInfo", {})

    def call(self, name, args):
        # Hard guard: this pipeline is read-only on LinkedIn.
        if name in WRITE_TOOLS:
            raise RuntimeError(f"BLOCKED: {name} is a write tool; pipeline is read-only")
        r = self._rpc("tools/call", {"name": name, "arguments": args})
        if not r:
            raise RuntimeError(f"{name}: empty response")
        if "error" in r:
            raise RuntimeError(f"{name}: {r['error']}")
        content = r.get("result", {}).get("content", [])
        text = "".join(c.get("text", "") for c in content if c.get("type") == "text")
        try:
            return json.loads(text)
        except Exception:
            return {"_raw": text}


# --------------------------------------------------------------------------
# Age parsing - round DOWN (assume oldest), per spec
# --------------------------------------------------------------------------
AGE_RE = re.compile(
    r"\b(?:(just now|moments ago)|(\d+)\s*(minute|hour|day|week|month)s?\s+ago)", re.I
)


def parse_age_hours(text):
    """Return assumed age in hours, or None. A job shown as 'N units ago' is
    between N and N+1 units old, so assume N+1 (the oldest possibility)."""
    if not text:
        return None
    m = AGE_RE.search(text)
    if not m:
        if re.search(r"within the past 24 hours", text, re.I):
            return 24.0
        return None
    if m.group(1):
        return 1.0 / 60.0
    n = int(m.group(2))
    unit = m.group(3).lower()
    per = {"minute": 1 / 60, "hour": 1, "day": 24, "week": 168, "month": 720}[unit]
    return (n + 1) * per


def age_label(hours):
    if hours is None:
        return "unknown"
    if hours < 1.5:
        return "~1h"
    if hours < 48:
        return "~%dh" % round(hours)
    return "~%dd" % round(hours / 24)


# --------------------------------------------------------------------------
# Applicant parsing
# --------------------------------------------------------------------------
def parse_applicants(text):
    """Return (count, is_capped, label). Handles 'N applicants',
    'N people clicked apply', 'Over N ...', 'Be among the first N ...',
    and the exact 'Candidates who clicked apply / N total' block."""
    if not text:
        return None, False, "unknown"

    m = re.search(r"Candidates who clicked apply\s*\n+\s*([\d,]+)\s*\n+\s*total", text, re.I)
    if m:
        n = int(m.group(1).replace(",", ""))
        return n, False, f"{n} clicked apply"

    m = re.search(r"be among the first\s+([\d,]+)", text, re.I)
    if m:
        n = int(m.group(1).replace(",", ""))
        return n - 1, False, f"among first {n}"

    m = re.search(r"over\s+([\d,]+)\s+(?:people clicked apply|applicants?)", text, re.I)
    if m:
        n = int(m.group(1).replace(",", ""))
        return n, True, f"over {n}"

    m = re.search(r"([\d,]+)\s+(?:people clicked apply|applicants?)", text, re.I)
    if m:
        n = int(m.group(1).replace(",", ""))
        return n, False, f"{n} clicked apply"

    return None, False, "unknown"


# --------------------------------------------------------------------------
# Search result parsing - trust job_ids, ignore recommendation blocks
# --------------------------------------------------------------------------
NOISE_MARKER = "Are these results helpful?"


def parse_search(payload):
    """Return (jobs, header_count). jobs = [{id,title,company,loc,age_h,raw}]."""
    blob = payload.get("sections", {}).get("search_results", "") or ""
    body = blob.split(NOISE_MARKER)[0]

    header_count = None
    m = re.search(r"^\s*([\d,]+)\s+results?\s*$", body, re.M)
    if m:
        header_count = int(m.group(1).replace(",", ""))

    ids = payload.get("job_ids", []) or []
    refs = [
        r
        for r in payload.get("references", {}).get("search_results", [])
        if r.get("kind") == "job"
    ]

    titles = []
    for r in refs:
        mm = re.search(r"/jobs/view/(\d+)", r.get("url", ""))
        if mm:
            titles.append((mm.group(1), (r.get("text") or "").strip()))

    # Fall back to positional pairing if references are absent.
    if not titles:
        titles = [(i, "") for i in ids]

    lines = [ln.rstrip() for ln in body.splitlines()]
    jobs = []
    for jid, title in titles:
        company, loc, age_h = "", "", None
        if title:
            idx = next((i for i, ln in enumerate(lines) if ln.strip() == title), None)
            if idx is not None:
                chunk = lines[idx + 1 : idx + 8]
                # The company is the first line after the title that is not a
                # badge. LinkedIn interleaves "Promoted", "Viewed", "Easy Apply"
                # etc., and taking chunk[0] blindly mislabels the employer.
                for ln in chunk:
                    t = ln.strip()
                    if not t:
                        continue
                    if re.match(
                        r"^(promoted|viewed|easy apply|actively reviewing|"
                        r"responses managed|be an early applicant|"
                        r"within the past|reposted|\d+ (connection|school|company))",
                        t, re.I,
                    ):
                        continue
                    company = t
                    break
                for ln in chunk:
                    if re.search(r"\((On-site|Remote|Hybrid)\)", ln, re.I) or "India" in ln:
                        if not loc:
                            loc = ln.strip()
                    if age_h is None:
                        age_h = parse_age_hours(ln)
        jobs.append(
            {"id": str(jid), "title": title, "company": company, "loc": loc, "age_h": age_h}
        )
    return jobs, header_count


# --------------------------------------------------------------------------
# Detail stripping - the single biggest token saving
# --------------------------------------------------------------------------
CUT_MARKERS = [
    "Set alert for similar jobs",
    "About the company",
    "Exclusive Job Seeker Insights",
    "More jobs",
    "Show Premium Insights",
    "Hiring, not job hunting?",
    "People also viewed",
    "Similar jobs",
    "Put your best foot forward",
]
KEEP_BLOCKS = ["Candidates who clicked apply", "Candidate seniority level"]

# Pure UI chrome in the header. These lines carry no information about the job,
# cost tokens, and actively mislead the model - it reported back that the JD
# "only shows LinkedIn UI elements ('Put your best foot forward', 'Hire a resume
# writer')". Location, work mode, age and applicant count are NOT in this list
# and are kept.
UI_NOISE = {
    "apply", "save", "easy apply", "show all", "show more", "see more",
    "use ai to assess how you fit", "show match details", "tailor my resume",
    "create cover letter", "help me stand out", "people you can reach out to",
    "hiring?", "hiring, not job hunting?", "post a job", "set alert",
    "jump to active job details", "jump to active search result",
    "put your best foot forward with your application", "hire a resume writer",
    "get a resume review", "... more", "… more", "more",
}

# Markers that indicate the actual job description has begun. LinkedIn does not
# always use "About the job" - keying off that alone meant postings without it
# fell through to a 400-char header slice with NO description at all.
JD_MARKERS = [
    "About the job", "About the role", "Job Description", "Job description",
    "About this role", "Role Summary", "Position Summary", "The Opportunity",
    "Responsibilities", "Key Responsibilities", "What You", "What you",
    "Requirements", "Qualifications", "Your role", "About Us", "Overview",
]


def has_job_description(text):
    """True when the detail response actually contains a description.

    LinkedIn sometimes returns a stub - company, title, location, badges and
    nothing else (measured: one response was 247 chars total). Sending that to
    the model wastes a call and produces a confusing 'rule score only' entry,
    so detect it up front and say so plainly instead."""
    if not text or len(text) < 700:
        return False
    return any(mk in text for mk in JD_MARKERS)


def _drop_ui_noise(block):
    out = []
    for ln in block.splitlines():
        t = ln.strip()
        if t.lower() in UI_NOISE:
            continue
        out.append(ln)
    return "\n".join(out)


def _truncate_clean(s, limit):
    """Cut at a paragraph or sentence boundary, never mid-sentence.

    A hard slice made the model report the JD 'cuts off mid-sentence' and
    refuse to score, so it must be visibly complete or visibly truncated."""
    if len(s) <= limit:
        return s
    cut = s[:limit]
    for sep in ("\n\n", ". ", "\n"):
        i = cut.rfind(sep)
        if i > limit * 0.6:
            return cut[: i + len(sep)].rstrip() + "\n\n[description truncated]"
    return cut.rstrip() + "\n\n[description truncated]"


def strip_posting(text):
    """Keep the header line, the job description, and the applicant-insight
    blocks. Drop company marketing, competitor analysis, hiring-trend charts
    and 'More jobs'.

    Sections are assembled without overlap - an earlier version appended the
    insight blocks unconditionally and produced output LARGER than the input
    when they already sat inside the description slice."""
    if not text:
        return ""

    parts = []

    # 1. Header: company, title, "location - age - applicants". UI chrome
    #    stripped out.
    head_end = -1
    for mk in JD_MARKERS:
        i = text.find(mk)
        if i != -1 and (head_end == -1 or i < head_end):
            head_end = i
    head = text[: head_end if head_end != -1 else 400][:500]
    parts.append(_drop_ui_noise(head).strip())

    # 2. The description itself, cut at the first boilerplate marker. Uses the
    #    earliest of ALL JD_MARKERS, not just "About the job" - postings
    #    lacking that exact phrase previously yielded a header and nothing else.
    if head_end != -1:
        core = text[head_end:]
        cut = len(core)
        for mk in CUT_MARKERS:
            i = core.find(mk)
            if i != -1:
                cut = min(cut, i)
        core = _drop_ui_noise(core[:cut]).strip()
        parts.append(_truncate_clean(core, 4000))

    # 3. Applicant insight blocks - only if not already captured above.
    got = "\n".join(parts)
    for blk in KEEP_BLOCKS:
        i = text.find(blk)
        if i != -1 and blk not in got:
            parts.append(text[i : i + 260].strip())

    out = "\n\n".join(p for p in parts if p)
    out = re.sub(r"[ \t]+\n", "\n", out)
    out = re.sub(r"\n{3,}", "\n\n", out)
    return _truncate_clean(out, 4500)


# Only count year figures that are actually about EXPERIENCE. A bare
# "(\d+) years" min-across-the-document grabs incidentals like "1 year of
# free training" and reports a 3-7yr role as wanting 1 year.
YEARS_RE = re.compile(
    r"(\d{1,2})\s*(?:\+|\s*(?:to|-|–)\s*\d{1,2})?\s*\+?\s*"
    r"(?:years?|yrs?)(?:\s+of)?\s+"
    r"(?:relevant\s+|applied\s+|hands[- ]on\s+|professional\s+|total\s+|overall\s+)?"
    r"(?:experience|exp\b)",
    re.I,
)


def parse_years(text):
    """Return the minimum years of EXPERIENCE required, or None.

    Takes the smallest experience-qualified figure: job ads often state a
    range ("5-10 years") or several requirements, and the lowest is the real
    entry bar."""
    vals = []
    for m in YEARS_RE.finditer(text or ""):
        v = int(m.group(1))
        if 0 <= v <= 30:
            vals.append(v)
    return min(vals) if vals else None


LOC_RE = re.compile(r"(?:position\s+)?location\s*[:\-]\s*([A-Za-z ,/()]+)", re.I)


def body_location(text):
    m = LOC_RE.search(text or "")
    return m.group(1).strip()[:60] if m else ""


# --------------------------------------------------------------------------
# Rule scoring
# --------------------------------------------------------------------------
def rule_score(job, body, cfg):
    """Heuristic screen, NOT a verdict.

    Its job is to rank candidates and decide who is worth an LLM call. Measured
    against real LLM scores it is far too generous on its own - which is why
    positives are capped hard.

    Positive keywords are table stakes in this domain: essentially every DevOps
    posting mentions aws/terraform/ci-cd/docker/python. Summing them made every
    job score 10 and destroyed all ranking signal. They are now worth at most
    +cap total, just enough to separate a real DevOps post from an unrelated
    one. The DISCRIMINATIVE signal is the negatives - wrong cloud, wrong stack,
    wrong seniority - so those keep full weight.
    """
    base = float(cfg.get("base_score", 5))
    low = (body or "").lower()
    reasons = []

    pos_cap = float(cfg.get("positive_cap", 3))
    pos = sum(w for kw, w in cfg["positive"].items() if kw in low)
    s = base + min(pos, pos_cap)
    if pos == 0:
        s -= 2
        reasons.append("no core-stack keywords")

    for kw, w in cfg["negative"].items():
        if kw in low:
            s += w
            if w <= -3:
                reasons.append(f"{kw} required")

    cp = cfg["cloud_primary"]
    if low.count("azure") >= cp["azure_threshold"] and low.count("aws") < low.count("azure"):
        s += cp["azure_penalty"]
        reasons.append("Azure-primary")
    if (low.count("gcp") + low.count("google cloud")) >= cp["gcp_threshold"] and low.count(
        "aws"
    ) < (low.count("gcp") + low.count("google cloud")):
        s += cp["gcp_penalty"]
        reasons.append("GCP-primary")

    # Kubernetes depth is a signed WEIGHT, not a fixed penalty. It was -3 when
    # K8s was working-knowledge only; with production EKS experience the same
    # requirement is a positive signal. `required_score` is the current key;
    # `required_penalty` is still read so an older config keeps working.
    k = cfg["kubernetes"]
    kw = k.get("required_score", k.get("required_penalty", 0))
    if kw and any(mk in low for mk in k["required_markers"]):
        s += kw
        reasons.append("deep K8s role" if kw > 0 else "deep K8s required")

    y = parse_years(body)
    yc = cfg["years"]
    if y is not None:
        if y > yc["band_max"] + 3:
            s += yc["far_over_penalty"]
            reasons.append(f"{y}+ yrs")
        elif y > yc["band_max"]:
            s += yc["over_band_penalty"]
            reasons.append(f"{y}+ yrs")
        elif y < 2:
            s += yc["under_band_penalty"]
            reasons.append(f"only {y} yrs wanted")

    n, capped, _ = parse_applicants(body)
    ac = cfg["applicants"]
    if n is not None:
        if n <= ac["soft_ceiling"]:
            s += ac["cold_bonus"]
        elif n > ac["near_neutral"] or capped:
            s += ac["crowded_penalty"]

    return max(1.0, min(10.0, s)), y, reasons


# --------------------------------------------------------------------------
# LLM escalation - one call, stripped inputs, JSON out
# --------------------------------------------------------------------------
LLM_PROMPT = """Score each job 1-10 as a match for this candidate. Read the BODY, not the title - titles routinely misrepresent the real role, location, or seniority.

CANDIDATE: {profile}

Return ONLY a JSON array, no prose, no markdown fence:
[{{"id":"<id>","score":<1-10>,"loc":"<real location incl Remote/Hybrid/On-site>","fit":"<one sentence>","gap":"<one sentence>","mismatch":"<omit unless title/body/location genuinely disagree>"}}]

JOBS:
{jobs}"""


def llm_env():
    """Environment for the `claude` subprocess.

    CLAUDE_CODE_OAUTH_TOKEN is stored as a Windows *User* variable. A process
    inherits its parent's environment block, so anything started before the
    token was set - or before a rotation - sees a stale one and `claude` exits
    with "Not logged in". Read the live value straight from the registry when
    it is missing from os.environ.
    """
    env = os.environ.copy()
    if env.get("CLAUDE_CODE_OAUTH_TOKEN") or env.get("ANTHROPIC_API_KEY"):
        return env
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            val, _ = winreg.QueryValueEx(k, "CLAUDE_CODE_OAUTH_TOKEN")
            if val:
                env["CLAUDE_CODE_OAUTH_TOKEN"] = val
    except Exception:
        pass
    return env


def llm_score(cands, cfg, model):
    payload = [
        {"id": c["id"], "title": c["title"], "company": c["company"], "jd": c["stripped"]}
        for c in cands
    ]
    prompt = LLM_PROMPT.format(
        profile=cfg["profile_brief"], jobs=json.dumps(payload, ensure_ascii=False)
    )
    approx = len(prompt) // 4
    log(f"  [llm] ~{approx:,} input tokens for {len(cands)} job(s)")
    try:
        p = subprocess.run(
            ["claude", "-p", prompt, "--model", model],
            capture_output=True,
            text=True,
            timeout=600,
            encoding="utf-8",
            errors="replace",
            env=llm_env(),
            shell=False,
        )
        out = (p.stdout or "").strip()
        m = re.search(r"\[.*\]", out, re.S)
        if not m:
            detail = (out or (p.stderr or "")).strip().replace("\n", " ")[:200]
            log(f"  [llm] no JSON (exit {p.returncode}): {detail} - using rule scores")
            return {}
        arr = json.loads(m.group(0))
        return {str(x["id"]): x for x in arr if "id" in x}
    except Exception as e:
        log(f"  [llm] failed ({e}) - falling back to rule scores")
        return {}


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def ps(script, *args):
    return subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
         os.path.join(ROOT, "scripts", script), *args],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )


def main():
    cfg = load_json(os.path.join(ROOT, "config.json"))
    sc = load_json(os.path.join(ROOT, "scoring.json"))
    if not cfg or not sc:
        log("FATAL: config.json or scoring.json unreadable")
        return 2

    lim = cfg["limits"]
    now = datetime.now(timezone.utc).replace(microsecond=0)
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    warnings = []

    # Always state the judging model up front, even on runs that never call it.
    # Otherwise the log is silent about which model is configured and the only
    # evidence is a stale header from an older wrapper.
    _llm = cfg_llm = sc.get("llm", {})
    if _llm.get("enabled"):
        log(f"model: {_llm.get('model')} (used only if there are new jobs)")
    else:
        log("model: DISABLED - rule scores only, zero tokens")

    # ---- health check ----------------------------------------------------
    try:
        urllib.request.urlopen(MCP_URL, timeout=10)
    except urllib.error.HTTPError as e:
        if e.code != 406:
            log(f"FATAL: hub returned HTTP {e.code}")
            return 1
    except Exception as e:
        log(f"FATAL: hub unreachable - {e}")
        result = {
            "run_utc": now_iso, "search_calls": 0,
            "searches": [], "counts": {"found": 0, "unique": 0, "new": 0,
                                       "detailed": 0, "deferred": 0, "excluded": 0},
            "warnings": [f"HUB DOWN: {e}. No search performed; last_run NOT advanced."],
            "jobs": [],
        }
        write_json_atomic(os.path.join(STATE, "run-result.json"), result)
        ps("render-shortlist.ps1", "-ResultJson", os.path.join(STATE, "run-result.json"))
        write_json_atomic(os.path.join(STATE, "pending_notify.json"),
                          [{"id": f"HUB-DOWN-{now.strftime('%Y%m%d-%H')}",
                            "title": "LinkedIn hub is DOWN", "company": "pipeline", "score": 10}])
        ps("notify.ps1", "-JobsJson", os.path.join(STATE, "pending_notify.json"))
        return 1

    # ---- state -----------------------------------------------------------
    last_run = load_json(os.path.join(STATE, "last_run.json"), {}) or {}
    seen = set(str(x) for x in (load_json(os.path.join(STATE, "seen_jobs.json"), []) or []))

    searches = []
    for entry in cfg["searches"]:
        key = f"{cfg['keywords']}|{entry['location']}"
        if entry.get("work_type"):
            key += f"|{entry['work_type']}"
        prev = last_run.get(key)
        if prev:
            try:
                lr = datetime.strptime(prev, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                cold = False
            except Exception:
                lr, cold = now - timedelta(hours=lim["cold_start_hours"]), True
        else:
            lr, cold = now - timedelta(hours=lim["cold_start_hours"]), True
        cutoff = lr - timedelta(minutes=lim["cutoff_slack_minutes"])
        label = entry["location"].split(",")[0]
        if entry.get("work_type"):
            label += f" ({entry['work_type']})"
        searches.append({"entry": entry, "key": key, "cutoff": cutoff,
                         "cold": cold, "label": label})

    # ---- connect ---------------------------------------------------------
    mcp = Mcp()
    info = mcp.connect()
    log(f"hub {info.get('name')} {info.get('version')}")

    excluded_names = [e.lower() for e in cfg.get("excluded_companies", [])]
    all_jobs, search_rows, excluded_out = {}, [], []

    for s in searches:
        entry, cutoff = s["entry"], s["cutoff"]
        catching_up = (now - cutoff) > timedelta(hours=2)
        retrieved, header, pages, stop = {}, None, 0, "exhausted"

        while pages < lim["max_pages_per_location"]:
            args = {
                "keywords": cfg["keywords"],
                "location": entry["location"],
                "date_posted": "past_24_hours",
                "sort_by": "date",
                "max_pages": pages + 1,
            }
            if entry.get("work_type"):
                args["work_type"] = entry["work_type"]

            payload = mcp.call("search_jobs", args)
            mcp.search_calls += 1
            pages += 1

            jobs, hc = parse_search(payload)
            if hc:
                header = hc
            before = len(retrieved)
            for j in jobs:
                retrieved[j["id"]] = j
            if len(retrieved) == before and pages > 1:
                stop = "exhausted"
                break

            ages = [j["age_h"] for j in retrieved.values() if j["age_h"] is not None]
            need_time = False
            if ages:
                oldest = now - timedelta(hours=max(ages))
                need_time = oldest > cutoff
            need_items = bool(header and header > len(retrieved) and catching_up)

            if not need_time and not need_items:
                stop = "fully enumerated" if (header and header <= len(retrieved)) else "cutoff reached"
                break
            if pages >= lim["max_pages_per_location"]:
                stop = "4-page cap"
                warnings.append(f"{s['label']} hit the 4-page cap - schedule may be too slow or keywords too broad")
                break

        if s["cold"]:
            warnings.append(f"{s['label']}: cold start (no prior last_run); cutoff ~24h, past_24_hours caps recovery at 24h")

        search_rows.append({"label": s["label"], "pages": pages, "stop": stop,
                            "header": header, "got": len(retrieved)})
        for jid, j in retrieved.items():
            if jid not in all_jobs:
                all_jobs[jid] = j

    found_total = sum(r["got"] for r in search_rows)
    log(f"search: {mcp.search_calls} calls, {found_total} found, {len(all_jobs)} unique")

    # Partial extraction is worse than total failure, because it looks like a
    # normal run. If LinkedIn says "68 results" and we retrieved 3, the markup
    # has drifted and most jobs are invisible - surface it rather than quietly
    # shortlisting whatever scraps came back.
    claimed_total = sum(r["header"] or 0 for r in search_rows)
    if claimed_total >= 10 and found_total < claimed_total * 0.25:
        w = (f"PARTIAL EXTRACTION: LinkedIn reported ~{claimed_total} results but only "
             f"{found_total} job IDs were retrieved ({found_total * 100 // max(claimed_total, 1)}%). "
             "The job-search markup has likely changed. Update the server "
             "(uvx mcp-server-linkedin@latest) or report upstream: "
             "https://github.com/stickerdaniel/linkedin-mcp-server/issues")
        warnings.append(w)
        log(f"WARNING: {w}")

    # ---- suspected dead session -----------------------------------------
    # An expired LinkedIn session does not error: it serves an empty, gated
    # results page, so every search returns 0 and the run looks like a quiet
    # job market. That is the exact failure the health check exists to prevent,
    # but HTTP reachability says nothing about session validity.
    #
    # Zero results across EVERY search is not credible - these queries
    # historically return 16-26 jobs per run - so treat it as an auth failure:
    # notify, and above all do NOT advance last_run, or the blind window is
    # lost permanently.
    if found_total == 0 and len(search_rows) > 0:
        # Distinguish the two causes, because the remedies are opposite.
        # If the page reported "N results" but no IDs came back, we ARE logged
        # in and LinkedIn's markup changed - the server's extractor needs
        # updating and re-logging-in would achieve nothing.
        claimed = sum(r["header"] or 0 for r in search_rows)
        if claimed > 0:
            msg = (f"EXTRACTOR BROKEN: pages reported ~{claimed} results but 0 job IDs "
                   "were extracted. You are logged in; LinkedIn's job-search markup has "
                   "changed and mcp-server-linkedin cannot parse it. Re-login will NOT "
                   "help. Update the server (uvx mcp-server-linkedin@latest) or report "
                   "upstream: https://github.com/stickerdaniel/linkedin-mcp-server/issues"
                   " - last_run NOT advanced.")
        else:
            msg = ("SUSPECTED DEAD SESSION: every search returned 0 results and the page "
                   "reported no result count. LinkedIn serves an empty page when logged "
                   "out. last_run NOT advanced. Re-login: stop the hub, run "
                   "'uvx mcp-server-linkedin@latest --login', then restart the hub.")
        log(f"FATAL: {msg}")
        result = {
            "run_utc": now_iso, "search_calls": mcp.search_calls,
            "searches": search_rows,
            "counts": {"found": 0, "unique": 0, "new": 0, "detailed": 0,
                       "deferred": 0, "excluded": 0, "saturated": 0, "stale": 0},
            "warnings": [msg], "jobs": [],
        }
        rp0 = os.path.join(STATE, "run-result.json")
        write_json_atomic(rp0, result)
        ps("render-shortlist.ps1", "-ResultJson", rp0)
        write_json_atomic(
            os.path.join(STATE, "pending_notify.json"),
            [{"id": f"AUTH-DEAD-{now.strftime('%Y%m%d-%H')}",
              "title": "LinkedIn session may have expired", "company": "pipeline", "score": 10}],
        )
        ps("notify.ps1", "-JobsJson", os.path.join(STATE, "pending_notify.json"))
        return 1

    # ---- filter ----------------------------------------------------------
    candidates = []
    for jid, j in all_jobs.items():
        if jid in seen:
            continue
        comp = (j["company"] or "").lower()
        if any(x in comp for x in excluded_names):
            excluded_out.append({"id": jid, "company": j["company"], "title": j["title"]})
            continue
        if j["age_h"] is not None and j["age_h"] > lim["max_posted_age_days"] * 24:
            continue
        title_low = (j["title"] or "").lower()
        if any(t in title_low for t in sc["title_reject"]):
            j["_prereject"] = True
        candidates.append(j)

    prerejected = [c for c in candidates if c.get("_prereject")]
    to_detail = [c for c in candidates if not c.get("_prereject")]

    # ---- freshness gate --------------------------------------------------
    # Applied here, BEFORE details, whenever the search page gave us an age -
    # those cost nothing to reject. Jobs whose age is unknown ("Viewed") fall
    # through and are re-checked after the detail call.
    stale = []
    fr = sc.get("freshness", {})
    if fr.get("enabled"):
        max_h = fr.get("max_age_minutes", 30) / 60.0
        keep = []
        for c in to_detail:
            if c["age_h"] is not None and c["age_h"] > max_h:
                stale.append({
                    "id": c["id"], "title": c["title"], "company": c["company"],
                    "age": age_label(c["age_h"]), "detail_spent": False,
                    "url": f"https://www.linkedin.com/jobs/view/{c['id']}/",
                })
            else:
                keep.append(c)
        to_detail = keep

    to_detail.sort(key=lambda x: x["age_h"] if x["age_h"] is not None else 999)

    cap = lim["max_job_details_per_run"]
    deferred = max(0, len(to_detail) - cap)
    to_detail = to_detail[:cap]

    log(f"filter: {len(candidates)} new, {len(prerejected)} title-rejected, "
        f"{len(to_detail)} to detail, {deferred} deferred, {len(excluded_out)} excluded")

    # ---- details + rule score -------------------------------------------
    scored = []
    saturated = []
    stub_ids = []
    sat = sc.get("saturation", {})
    for c in to_detail:
        d = mcp.call("get_job_details", {"job_id": c["id"]})
        mcp.detail_calls += 1
        raw = d.get("sections", {}).get("job_posting", "") or d.get("_raw", "")

        # LinkedIn sometimes returns a stub with no description (measured: 247
        # chars - company, title, badges, nothing else). Do not spend a model
        # call on it: the model correctly refuses to score a header, which then
        # surfaced as an unexplained "rule score only" entry.
        no_jd = not has_job_description(raw)
        stripped = "" if no_jd else strip_posting(raw)
        rs, yrs, reasons = rule_score(c, raw, sc)
        if no_jd:
            reasons.insert(0, "LinkedIn returned no job description")
            # TRANSIENT, not a property of the posting: the same job returned
            # 5388 chars with a full JD and 204 chars minutes later. The page
            # simply had not rendered. So do NOT mark it seen - let a later run
            # re-fetch it. Repeat cost is bounded, because once it ages past the
            # freshness window it is rejected from the search page for free.
            stub_ids.append(c["id"])
        n, capped, alabel = parse_applicants(raw)
        ah = c["age_h"] if c["age_h"] is not None else parse_age_hours(raw[:400])
        bloc = body_location(raw)

        # Freshness re-check for jobs whose age the search page withheld
        # ("Viewed"). We already paid for the detail call, so mark these seen -
        # otherwise we re-fetch the same stale job every 30 minutes forever.
        if fr.get("enabled") and ah is not None and ah > fr.get("max_age_minutes", 30) / 60.0:
            stale.append({
                "id": c["id"], "title": c["title"], "company": c["company"],
                "age": age_label(ah), "detail_spent": True,
                "url": f"https://www.linkedin.com/jobs/view/{c['id']}/",
            })
            continue

        # Applicant VELOCITY gate. 20+ applicants inside the first hour means
        # the pool is already saturated; the same count over 24h would be a
        # cold posting worth applying to. Dropped BEFORE the LLM call, so these
        # cost no tokens. Applicant counts only exist in get_job_details, so
        # the detail call itself cannot be avoided.
        if (
            sat.get("enabled")
            and ah is not None
            and ah < sat.get("max_age_hours", 1)
            and n is not None
            and n > sat.get("applicant_threshold", 20)
        ):
            saturated.append({
                "id": c["id"], "title": c["title"], "company": c["company"],
                "applicants": alabel, "age": age_label(ah),
                "url": f"https://www.linkedin.com/jobs/view/{c['id']}/",
            })
            continue

        scored.append({
            "id": c["id"], "title": c["title"], "company": c["company"],
            "loc": bloc or c["loc"] or "-", "applicants": alabel,
            "applicants_n": n, "applicants_capped": capped,
            "age": age_label(ah), "age_hours": round(ah, 2) if ah is not None else None,
            "score": round(rs), "rule_score": round(rs, 1),
            "years": yrs, "reasons": reasons, "stripped": stripped,
            "url": f"https://www.linkedin.com/jobs/view/{c['id']}/",
        })

    # Title-rejected jobs are recorded, never detailed - they cost 0 calls.
    for c in prerejected:
        scored.append({
            "id": c["id"], "title": c["title"], "company": c["company"],
            "loc": c["loc"] or "-", "applicants": "not fetched",
            "age": age_label(c["age_h"]), "score": 2, "rule_score": 2,
            "years": None, "reasons": ["title-rejected, body not fetched"],
            "stripped": "", "fit": "-",
            "gap": "Title matched the reject list; body not fetched to save a call.",
            "url": f"https://www.linkedin.com/jobs/view/{c['id']}/",
        })

    # ---- LLM escalation --------------------------------------------------
    lc = sc["llm"]
    if lc.get("enabled") and to_detail:
        cands = [s for s in scored if s["stripped"] and s["rule_score"] >= lc["min_rule_score"]]
        cands.sort(key=lambda x: -x["rule_score"])
        cands = cands[: lc["max_candidates"]]
        if cands:
            log(f"llm: judging {len(cands)} candidate(s) via {lc['model']}")
            verdicts = llm_score(cands, sc, lc["model"])
            for s in scored:
                v = verdicts.get(s["id"])
                if v:
                    s["score"] = int(v.get("score", s["score"]))
                    s["loc"] = v.get("loc") or s["loc"]
                    s["fit"] = v.get("fit", "")
                    s["gap"] = v.get("gap", "")
                    if v.get("mismatch"):
                        s["mismatch"] = v["mismatch"]
    else:
        log("llm: skipped (nothing to judge)" if not to_detail else "llm: disabled")

    # Anything the model did not cover keeps its rule score, labelled honestly.
    # Explain WHY a job has no model verdict rather than printing a bare
    # "rule score only", which gave no clue whether the cause was a missing
    # description, a failed model call, or the candidate cap.
    for s in scored:
        had_jd = bool(s.pop("stripped", None))
        if "fit" not in s:
            if not had_jd:
                s["fit"] = "Not judged - LinkedIn returned no job description for this posting."
            elif not lc.get("enabled"):
                s["fit"] = "Not judged - model scoring is disabled in scoring.json."
            else:
                s["fit"] = ("Not judged - model returned no verdict for this job "
                            "(call failed, or beyond llm.max_candidates).")
        if "gap" not in s:
            s["gap"] = ", ".join(s["reasons"]) if s["reasons"] else "No rule penalties triggered."
        s.pop("reasons", None)
        s.pop("rule_score", None)
        s.pop("years", None)

    # ---- write result + render ------------------------------------------
    result = {
        "run_utc": now_iso,
        "search_calls": mcp.search_calls,
        "searches": search_rows,
        "counts": {
            "found": found_total, "unique": len(all_jobs), "new": len(candidates),
            "detailed": mcp.detail_calls, "deferred": deferred,
            "excluded": len(excluded_out), "saturated": len(saturated),
            "stale": len(stale),
        },
        "jobs": scored,
    }
    if stub_ids:
        warnings.append(
            f"{len(stub_ids)} job(s) returned no description (page had not rendered). "
            "Left UNSEEN so a later run retries them. If this is frequent, raise "
            "--timeout in start-linkedin-hub.bat and restart the hub."
        )
    if warnings:
        result["warnings"] = warnings
    if excluded_out:
        result["excluded"] = excluded_out
    if saturated:
        result["saturated"] = saturated
    if stale:
        result["stale"] = stale
        result["stale_window"] = fr.get("max_age_minutes", 30)

    rp = os.path.join(STATE, "run-result.json")
    write_json_atomic(rp, result)
    r = ps("render-shortlist.ps1", "-ResultJson", rp)
    shortlist = (r.stdout or "").strip().splitlines()[-1] if r.stdout.strip() else "(render failed)"
    if r.returncode != 0:
        log(f"FATAL: renderer failed: {r.stderr.strip()[:300]}")
        return 1
    log(f"shortlist: {shortlist}")

    # ---- state: ONLY after the shortlist exists --------------------------
    # Stub responses are excluded so a later run can re-fetch the real body.
    detailed_ids = [s["id"] for s in scored if s["id"] not in stub_ids]
    if detailed_ids:
        ps("state-commit.ps1", "-AddSeen", ",".join(detailed_ids))
    if excluded_out:
        ps("state-commit.ps1", "-AddSeen", ",".join(e["id"] for e in excluded_out))
    # Saturated jobs MUST be marked seen. Leave them out and next hour they are
    # no longer "<1h old", so they sail through the velocity gate and get scored
    # and possibly notified - the exact opposite of the intent. They were
    # saturated at posting time; that verdict does not expire.
    if saturated:
        ps("state-commit.ps1", "-AddSeen", ",".join(s["id"] for s in saturated))

    # Stale jobs: mark seen ONLY where we already spent a detail call, so we do
    # not re-fetch the same stale posting every 30 minutes. Ones rejected for
    # free from the search page are deliberately left UNSEEN - re-checking them
    # costs nothing, and if the freshness window is later widened they become
    # eligible again instead of being permanently lost.
    paid_stale = [s["id"] for s in stale if s.get("detail_spent")]
    if paid_stale:
        ps("state-commit.ps1", "-AddSeen", ",".join(paid_stale))
    ps("state-commit.ps1", "-AdvanceLastRun", "-AllPairs", "-RunUtc", now_iso)

    # ---- notify ----------------------------------------------------------
    # A toast means "stop what you are doing and apply", so the bar is higher
    # than the shortlist's: high score AND a confirmed-small applicant pool AND
    # still fresh. Anything that scores high but fails a condition stays in the
    # shortlist with the reason shown - never silently dropped.
    nc = cfg.get("notify", {})
    min_score = nc.get("min_score", lim.get("notify_score_threshold", 8))
    max_appl = nc.get("max_applicants", 20)
    max_age_h = nc.get("max_age_minutes", 30) / 60.0
    need_known = nc.get("require_known_applicants", True)

    high, held = [], []
    for s in scored:
        if s["score"] < min_score:
            continue
        n_appl, capped, ah = s.get("applicants_n"), s.get("applicants_capped"), s.get("age_hours")

        if n_appl is None:
            if need_known:
                held.append((s, "applicant count unknown"))
                continue
        elif capped or n_appl >= max_appl:
            held.append((s, f"{s['applicants']} (ceiling {max_appl})"))
            continue

        if ah is not None and ah > max_age_h:
            held.append((s, f"posted {s['age']} (window {nc.get('max_age_minutes', 30)}m)"))
            continue

        high.append({"id": s["id"], "title": s["title"],
                     "company": s["company"], "score": s["score"]})

    if held:
        result["notify_held"] = [
            {"title": s["title"], "company": s["company"], "score": s["score"], "reason": why}
            for s, why in held
        ]
        write_json_atomic(rp, result)
        ps("render-shortlist.ps1", "-ResultJson", rp, "-OutFile", shortlist)
        for s, why in held:
            log(f"  [notify] held {s['title']} ({s['score']}/10): {why}")

    pn = os.path.join(STATE, "pending_notify.json")
    write_json_atomic(pn, high)
    n = ps("notify.ps1", "-JobsJson", pn)
    log(f"notify: {(n.stdout or '').strip()[:160]}")

    log(f"done. search={mcp.search_calls} details={mcp.detail_calls} "
        f"new={len(candidates)} stale={len(stale)} saturated={len(saturated)} "
        f"deferred={deferred} high={len(high)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log(f"FATAL: {e}")
        sys.exit(1)
