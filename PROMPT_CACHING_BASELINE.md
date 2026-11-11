# Baseline Prompt Caching — 2026-11-11

Item 4 of [PROMPT_CACHING_PLAN.md](PROMPT_CACHING_PLAN.md): the numbers the plan's
changes are measured against. Recorded before any provider change, from the
session archive as it stood, read-only.

## How it was taken

```
cp ~/.rubot/sessions.db /tmp/baseline.db
bin/cache_baseline.rb /tmp/baseline.db
```

The archive predates `request_cache`, so this reads what the session meta
already kept: token totals per session and the per-request hit rates of the
last twelve requests. That is enough for a distribution and a total, and not
enough to attribute a single miss — which is what the probe and the labels in
items 2 and 3 are for.

## Headline

| figure | value |
|---|---|
| sessions with usage | 92 |
| requests | 9,174 |
| prompt tokens | 681,954,978 |
| cached tokens | 594,306,627 |
| **weighted hit rate** | **87.1%** |
| uncached prompt tokens | 87,648,351 |
| cache writes reported | 0 |
| per-request hit rate (n=371 samples) | median **99.2%**, mean 89.5% |

Distribution of the 371 sampled requests: **325 at ≥90%** · 11 at 50–90% ·
13 at <50% · **22 at exactly 0%**.

The gap between the 87.1% weighted rate and the 99.2% median is the shape of
the problem: most requests hit almost completely, and a handful of very large
sessions carry the misses.

## Where the uncached tokens are

| provider | sessions | requests | hit | median |
|---|---|---|---|---|
| deepseek (`deepseek-v4.1-flash`) | 29 | 5,066 | 94.7% | 99.3% |
| *(no pinned prompt — pre-pin era)* | 59 | 3,865 | 72.0% | n/a |
| other (`glm-5.3-flash`, `mimo-v2.6-flash`) | 4 | 243 | 76.5% | 98.4% |

The top ten sessions hold **77.3%** of all uncached tokens, and the first four
of them are pre-pin:

| session | uncached | hit | messages | last used |
|---|---|---|---|---|
| `web_rubot~20261109-174557` | 25,176,916 | 45.5% | 400 | 2026-11-09 |
| `web_rubot~20261109-214833` | 18,228,032 | 49.3% | 399 | 2026-11-10 |
| `tg_-1004335078450_2` | 6,954,679 | 23.0% | 99 | 2026-11-07 |
| `default-20261109-111106` | 3,059,517 | 79.0% | 400 | 2026-11-09 |

**70.7% of all uncached tokens sit in the 59 sessions that predate the pinned
prompt** (last used 2026-11-07 to 2026-11-10 01:38). Those four sessions are
the "before" of a fix that already landed, not a current leak: with the prompt
pinned, the current-era sessions (500 to 960 messages) run at 92–96%.

So the baseline splits in two:

- **pre-pin era** (59 sessions, 62.0M uncached): historical, not a target.
- **current era** (deepseek/other, 33 sessions): 94–96% weighted, with
  22 zero-hit requests and 13 sub-50% requests across 17 sessions to explain.

## What this says about the plan

1. **There is no Anthropic traffic at all.** Every request in the archive went
   to an OpenAI-compatible gateway (`deepseek-v4.1-flash`, `glm-5.3-flash`,
   `mimo-v2.6-flash`). The plan's largest item — `cache_control` for the
   Anthropic provider (Fase 1) — has nothing to improve on this account today
   and nothing to measure against. Implementing it stays correct (the provider
   is shipped and a persona can be pointed at Claude), but it must be done as a
   correctness fix with a test session, not as a measured optimization.

2. **No cache writes are reported anywhere** (`cache_creation_tokens` sums to
   0 over 9,174 requests). The gateway does not report write cost, so the
   write-cost half of item 10 cannot be validated on this traffic — only the
   read side.

3. **The misses worth chasing are the zeros, not the average.** 22 of 371
   sampled requests read nothing from the cache. With DeepSeek's automatic
   cache those are most likely prefix churn (a rewritten message, a trim, a
   prompt epoch) rather than anything the provider did. That is exactly what
   `request_cache` plus the labels now answer, and the answer is the next
   baseline: re-run this script after a week of records and compare the
   distribution, not the average.

4. **The target for this traffic** is not "median ≥ 85%" (already 99.2%) but:
   - zero-hit share of sampled requests down from 5.9%,
   - uncached tokens per current-era session down from 1.2–2.8M,
   - every zero explained by a label that is not `unknown`.
