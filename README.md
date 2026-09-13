#  Comm-Log Send Reconciliation

**Task:** Reproduce Finance's reported `target_base = 22` for merchant `501`, October 2026, across all Diwali campaigns — starting from the raw `campaign` and `communication_log` tables, and explaining every gap along the way.

>  **Final result: 22** — matched exactly, with a fully documented reconciliation bridge.

---

##  What's in this repo

| File | What it is |
|---|---|
| [`investigation.md`](./investigation.md) | The full narrative — every query I tried, in order, including what didn't match and why |
| [`notebook.ipynb`](./notebook.ipynb) | Runnable, executed version of the analysis with real outputs at each step |
| [`queries.sql`](./queries.sql) | Standalone SQL — the naive-to-final query progression, plus a general-purpose recursive query |
| [`data/`](./data) | Raw data: `comm_log.db` (SQLite), `campaign.csv`, `communication_log.csv`, and the data dictionary (`README.md`) |

---

##  Reconciliation bridge

| Step | Description | Result | Reason |
|---|---|---|---|
| 0 | Naive `COUNT(*)` | **30** | Starting point — every send attempt, no logic applied |
| 1 | `COUNT(DISTINCT customer_id)` | **25** | `target_base` counts distinct customers reached, not raw send attempts — 5 rows were repeat attempts at the same customer within a retry chain |
| 2 | Exclude campaign 9004 (`creation_status = 'approval_awaiting'`) | **21** | Not yet approved, even though its sends already ran — `creation_status` is the actual reporting gate, not `processing_status`. Removes 4 customers who only appear under this ineligible campaign |
| 3 | Add back a customer's 2nd send under standalone campaign 9101 | **22** ✅ | Standalone campaigns (no parent, no retries pointing at them) count every send as its own event — they aren't deduped by customer the way retry chains are |
| **Final** | | **22** | ✓ matches Finance |

**Checked and ruled out along the way:**
- **`delivery_status`** (900 delivered / 1100 failed) — doesn't change the count in this dataset, since every chain here eventually lands a delivery for each customer. I kept the filter in the final query anyway: a customer who failed every attempt in a chain with no eventual delivery was never actually reached, and should be excluded — this dataset just doesn't happen to contain that case, but the query should still get it right if it did.
- **`processing_status`** — every row in this dataset happens to be `'processed'`, so filtering on it doesn't change the result here. I kept the filter anyway: it represents a real state (a campaign whose send pipeline hasn't finished running yet), and a campaign in that state shouldn't be counted as reported even if it clears approval — so the query should hold up correctly on a month where that case actually occurs.

---

##  Final SQL query

General-purpose — walks retry chains of any depth via a recursive CTE, not hardcoded to specific campaign IDs. Runs against `data/comm_log.db`.

```sql
WITH RECURSIVE chain_root AS (
    -- base case: a campaign with no parent is its own chain root
    SELECT id AS campaign_id, id AS root_id
    FROM campaign
    WHERE parent_id IS NULL

    UNION ALL

    -- recursive case: a campaign's root is its parent's root
    SELECT c.id, cr.root_id
    FROM campaign c
    JOIN chain_root cr ON c.parent_id = cr.campaign_id
),
eligible_campaigns AS (
    -- only campaigns whose creation workflow has cleared AND whose
    -- send pipeline has finished count toward official reporting
    SELECT c.id, cr.root_id
    FROM campaign c
    JOIN chain_root cr ON cr.campaign_id = c.id
    WHERE c.merchant_id = 501
      AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
),
is_standalone AS (
    -- a root with exactly one eligible campaign under it (itself,
    -- no retries) is a standalone communication
    SELECT root_id
    FROM eligible_campaigns
    GROUP BY root_id
    HAVING COUNT(*) = 1
),
logs AS (
    SELECT cl.*, ec.root_id
    FROM communication_log cl
    JOIN eligible_campaigns ec ON ec.id = cl.communication_id
    WHERE cl.merchant_id = 501
      AND cl.communication_type = '2'
      AND cl.sent_time >= '2026-10-01' AND cl.sent_time < '2026-11-01'
),
chain_counts AS (
    -- retry chains: one qualifying reach per distinct customer who
    -- was delivered at least once anywhere in the chain
    SELECT l.root_id, COUNT(DISTINCT l.customer_id) AS reach_count
    FROM logs l
    WHERE l.root_id NOT IN (SELECT root_id FROM is_standalone)
      AND l.delivery_status = 900
    GROUP BY l.root_id
),
standalone_counts AS (
    -- standalone campaigns: every delivered send is its own event,
    -- even if the same customer appears more than once
    SELECT l.root_id, COUNT(*) AS reach_count
    FROM logs l
    WHERE l.root_id IN (SELECT root_id FROM is_standalone)
      AND l.delivery_status = 900
    GROUP BY l.root_id
)
SELECT SUM(reach_count) AS target_base
FROM (
    SELECT * FROM chain_counts
    UNION ALL
    SELECT * FROM standalone_counts
);
```

**Result: `target_base = 22`**

Run it directly:
```bash
sqlite3 data/comm_log.db
.read queries.sql
```
or open [`notebook.ipynb`](./notebook.ipynb) to see it run interactively with intermediate outputs.

---

##  What surprised me

The part that wasn't obvious upfront: two situations that look identical in the raw data — a customer appearing twice against sends tied to the same underlying communication — are supposed to be counted in opposite ways depending on *why* they appear twice (retried after a failure inside a chain, vs. independently re-targeted under a standalone campaign). Nothing in `communication_log` itself distinguishes these cases; you have to join back to `campaign.parent_id` to know which rule applies. Also, `processing_status` looked like the natural "is this send official" flag at first glance, but it turned out to be a red herring — `creation_status` was the field that actually gated campaign 9004 out of reporting, despite its pipeline already having run.

---

## Why this was non-trivial

Two things in the data look identical on the surface but mean opposite things for counting:

- **Retry chains** (`campaign.parent_id` links back to an earlier attempt) → a customer reached across multiple attempts in the chain counts **once**.
- **Standalone campaigns** (no parent, no children) → every send is its **own** event, even for a repeat customer.

Full reasoning, including every dead end, is in [`investigation.md`](./investigation.md).

---

*Take-home assignment for Xeno's Data Analyst Internship Drive 2026.*
