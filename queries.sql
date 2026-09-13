-- ============================================================
-- Comm-Log Send Reconciliation — merchant 501, October 2026, Diwali campaigns
-- Target: Finance-reported target_base = 22
-- ============================================================
-- These queries are in the order I actually ran them, from the
-- most naive interpretation of "count of qualifying sends" through
-- to the definition Finance actually uses (distinct customers
-- reached per underlying communication).
-- ============================================================


-- ------------------------------------------------------------
-- STEP 0 — Naive count: every send attempt, no logic applied
-- ------------------------------------------------------------
-- Result: 30
SELECT COUNT(*) AS naive_send_count
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01' AND sent_time < '2026-11-01';


-- ------------------------------------------------------------
-- STEP 1 — target_base is defined as DISTINCT customers reached,
-- not raw send attempts. Switch to COUNT(DISTINCT customer_id).
-- ------------------------------------------------------------
-- Result: 25 (down from 30 — 5 rows were repeat attempts at the
-- same customer within a retry chain: C2, C3, D1)
SELECT COUNT(DISTINCT customer_id) AS distinct_customers
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01' AND sent_time < '2026-11-01';


-- ------------------------------------------------------------
-- STEP 2 — Exclude campaigns that haven't cleared the approval
-- workflow (creation_status = 'approval_awaiting'), even though
-- their send pipeline already ran (processing_status = 'processed').
-- Per the README, creation_status is the gate that actually
-- determines reportability — not processing_status.
-- ------------------------------------------------------------
-- Find the offending campaign(s):
SELECT id, name, creation_status, processing_status
FROM campaign
WHERE merchant_id = 501
  AND creation_status NOT IN ('approved', 'aborted', 'resumed', 'stopped');
-- -> campaign 9004 ("Diwali Cart Recovery - Retry C (pending)")

-- Recount excluding sends against that campaign:
-- Result: 21 (down from 25 — removes customers C11-C14, who only
-- ever appear under campaign 9004)
SELECT COUNT(DISTINCT cl.customer_id) AS distinct_customers_eligible_only
FROM communication_log cl
JOIN campaign c ON c.id = cl.communication_id
WHERE cl.merchant_id = 501
  AND cl.communication_type = '2'
  AND cl.sent_time >= '2026-10-01' AND cl.sent_time < '2026-11-01'
  AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
  AND c.processing_status = 'processed';


-- ------------------------------------------------------------
-- STEP 3 — Standalone campaigns (no parent_id, and nothing else's
-- parent_id points at them) don't get deduped by customer — every
-- send under them is its own event. Step 1's DISTINCT logic wrongly
-- collapsed a customer who was legitimately re-targeted twice under
-- standalone campaign 9101 (customer C20) into a single row.
-- ------------------------------------------------------------
-- Identify standalone campaigns (root with no children, and it has
-- no parent itself):
SELECT c.id, c.name
FROM campaign c
WHERE c.merchant_id = 501
  AND c.parent_id IS NULL
  AND c.id NOT IN (SELECT parent_id FROM campaign WHERE parent_id IS NOT NULL);
-- -> campaign 9101 ("Diwali Flash Sale - Standalone")

-- Add back the extra qualifying send: +1 -> 22. See the general
-- query below for the version that computes this correctly for
-- any number of chains/standalone campaigns, not just this dataset.


-- ============================================================
-- FINAL QUERY — general-purpose, not hardcoded to specific IDs.
-- Handles retry chains of any depth via a recursive CTE, and
-- treats standalone campaigns (no parent, no children) differently
-- from chained campaigns per the rules above.
-- Result: 22  (matches Finance's reported target_base)
-- ============================================================
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


-- ------------------------------------------------------------
-- Optional: per-chain breakdown, useful for sanity-checking the
-- total above against the bridge table in investigation.md
-- ------------------------------------------------------------
-- WITH RECURSIVE chain_root AS ( ... ) -- (same CTEs as above)
-- SELECT root_id, reach_count FROM chain_counts
-- UNION ALL
-- SELECT root_id, reach_count FROM standalone_counts;
-- Expected: (9001, 10), (9201, 5), (9101, 7) -> sums to 22
