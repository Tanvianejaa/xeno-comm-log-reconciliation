# Investigation: Comm-Log Send Reconciliation

**Task:** reproduce Finance's `target_base = 22` for merchant 501, October 2026,
Diwali campaigns, using `data/comm_log.db` (tables `campaign` and
`communication_log`).

This is a narrative of the actual order I worked through it in, including the
dead ends, not just the final answer. The runnable version of everything below
is in `notebook.ipynb`; the standalone SQL is in `queries.sql`.

---

## First pass: how many sends are there at all?

The most obvious starting query — just count rows for this merchant, this
campaign type, this month:

```sql
SELECT COUNT(*) FROM communication_log
WHERE merchant_id = 501 AND communication_type = '2'
  AND sent_time >= '2026-10-01' AND sent_time < '2026-11-01';
```

**30.** Finance says 22. Too high by 8.

Skimming the raw rows, a few customers appear more than once against the same
`communication_id` (e.g. customer C2 shows up under campaign 9001 *and* 9002).
The README defines `target_base` as "how many distinct customers were
reached" for a given underlying communication — not raw send attempts — so
the first thing to try is deduping by customer.

## Second pass: distinct customers

```sql
SELECT COUNT(DISTINCT customer_id) FROM communication_log
WHERE merchant_id = 501 AND communication_type = '2'
  AND sent_time >= '2026-10-01' AND sent_time < '2026-11-01';
```

**25.** Better, but still 3 too high. At this point I went back to the
`campaign` table to see if there was a reason some sends shouldn't count at
all, rather than just being duplicates.

## Checking campaign eligibility

The README calls out that a campaign only counts toward official reporting
once its `creation_status` is finalized (`approved`, `aborted`, `resumed`, or
`stopped`) **and** `processing_status = 'processed'` — and specifically warns
that the send pipeline can run ahead of the approval workflow, so rows can
exist in `communication_log` for a campaign that isn't actually reportable
yet.

Checking the `campaign` table for anything not finalized:

```sql
SELECT id, name, creation_status, processing_status FROM campaign
WHERE merchant_id = 501
  AND creation_status NOT IN ('approved','aborted','resumed','stopped');
```

Campaign **9004** ("Diwali Cart Recovery - Retry C (pending)") came back —
`creation_status = 'approval_awaiting'`. Notably, its `processing_status` is
already `'processed'`, which would fool a check that only looked at
processing status. This is exactly the scenario the README warns about: the
pipeline already ran and sent to customers C11-C14, but the campaign itself
was never approved, so Finance doesn't count it.

Recomputing distinct customers, excluding sends against non-eligible
campaigns:

**21.** Down from 25 — confirms C11-C14 were the only customers affected
(they only ever appear under 9004, so excluding it drops the count by
exactly 4).

This is where it got interesting: 21 is now **below** 22, not above it. The
first two adjustments were both "the naive number is too high, remove
something." This one flips direction, which means the initial DISTINCT dedup
(step 2) was itself too aggressive somewhere — it collapsed something that
shouldn't have been collapsed.

## Standalone campaigns don't dedupe the way retry chains do

Re-reading the README's retry-chain section more carefully: it explicitly
distinguishes two different situations that look similar in the raw data but
mean different things:

- A **retry chain** (`campaign.parent_id` points back at an earlier
  campaign): the same customer appearing across multiple campaigns in the
  chain is *one* underlying communication, attempted multiple times. Counts
  once.
- A **standalone campaign** (no parent, and nothing else points at it as a
  parent): every send under it is an independent event. If the same customer
  appears twice, that's two legitimate re-targets, not one deduped reach.

Checking which campaigns are standalone:

```sql
SELECT id, name FROM campaign
WHERE merchant_id = 501 AND parent_id IS NULL
  AND id NOT IN (SELECT parent_id FROM campaign WHERE parent_id IS NOT NULL);
```

Campaign **9101** ("Diwali Flash Sale - Standalone") is the one standalone
campaign here. Checking for repeated customers under it specifically:

```sql
SELECT customer_id, COUNT(*) FROM communication_log
WHERE communication_id = 9101 GROUP BY customer_id HAVING COUNT(*) > 1;
```

Customer **C20** was sent to twice under 9101, ten days apart — an
independent re-target, not a retry of a failed attempt. My earlier global
`COUNT(DISTINCT customer_id)` had collapsed this into one reach, which is
correct for a retry chain but wrong for a standalone campaign.

Adding that second send back: 21 + 1 = **22.** Matches Finance.

## Things I checked and ruled out

- **`delivery_status` (900 = delivered, 1100 = failed):** I checked whether
  filtering to only delivered sends would change anything, since "reached"
  implies actually delivered. In this dataset it doesn't change the final
  number — every chain here eventually lands a delivery for each customer it
  counts, and the one standalone campaign has no failed sends at all. I kept
  the filter in the final query anyway (`delivery_status = 900`), because a
  chain where a customer failed *every* attempt with no eventual delivery
  should logically be excluded, even though this dataset doesn't happen to
  test that case.
- **`processing_status`:** every row in this dataset is `'processed'`, so
  filtering on it is a no-op here. Kept it in the query anyway since it's
  part of the documented eligibility rule and might matter for other
  merchants/periods.

## Final bridge

| Step | Description | Result | Reason |
|---|---|---|---|
| 0 | Naive `COUNT(*)` | 30 | Starting point — every send attempt |
| 1 | `COUNT(DISTINCT customer_id)` | 25 | target_base counts distinct customers reached, not raw attempts |
| 2 | Exclude campaign 9004 (`creation_status = 'approval_awaiting'`) | 21 | Not yet approved, even though already sent — `creation_status` is the reporting gate, not `processing_status` |
| 3 | Add back C20's second send under standalone campaign 9101 | 22 | Standalone campaigns count every send as its own event; chain-style deduping wrongly collapsed it |
| **Final** | | **22** | ✓ matches Finance |

The general-purpose SQL that computes this for any chain structure (not
hardcoded to these specific campaign IDs) is in `queries.sql`.

## What surprised me

The part that wasn't obvious upfront: two situations that look identical in
the raw data — a customer appearing twice against sends from the same
underlying communication — are supposed to be counted in opposite ways
depending on *why* they appear twice (retried after failure inside a chain,
vs. independently re-targeted under a standalone campaign). Nothing in
`communication_log` itself distinguishes these cases; you have to join back
to `campaign.parent_id` to know which rule applies. Also, `processing_status`
looked like the natural "is this send official" flag at first glance, but it
turned out to be a red herring — `creation_status` was the field that
actually gated campaign 9004 out of reporting, despite its pipeline already
having run.
