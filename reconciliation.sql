-- ============================================================
-- COMM-LOG SEND RECONCILIATION
-- Merchant 501, October 2026, communication_type = '2'
-- Tested against comm_log.db. Final target_base = 22.
-- ============================================================


-- ============================================================
-- 1. DATA PROFILING
-- ============================================================

-- Row counts
SELECT (SELECT COUNT(*) FROM campaign) AS campaign_rows,
       (SELECT COUNT(*) FROM communication_log) AS log_rows;

-- Merchant / type / date range sanity check
SELECT merchant_id, communication_type, MIN(sent_time) AS first_sent, MAX(sent_time) AS last_sent
FROM communication_log
GROUP BY merchant_id, communication_type;

-- Delivery status breakdown
SELECT delivery_status, COUNT(*) AS n
FROM communication_log
GROUP BY delivery_status;

-- Distinct customers overall (raw, unscoped) — for context only, not the final metric
SELECT COUNT(DISTINCT customer_id) AS distinct_customers_raw
FROM communication_log;

-- Customers who appear under more than one campaign_id (retry candidates)
SELECT customer_id, COUNT(DISTINCT communication_id) AS n_campaigns
FROM communication_log
GROUP BY customer_id
HAVING COUNT(DISTINCT communication_id) > 1
ORDER BY customer_id;

-- Campaigns with zero associated logs (sanity check — none expected here)
SELECT c.id
FROM campaign c
LEFT JOIN communication_log l ON l.communication_id = c.id
WHERE l.id IS NULL;


-- ============================================================
-- 2. CAMPAIGN ELIGIBILITY
-- ============================================================

-- Eligibility rule: creation_status IN ('approved','aborted','resumed','stopped')
--                    AND processing_status = 'processed'
SELECT id, parent_id, creation_status, processing_status,
  CASE WHEN creation_status IN ('approved','aborted','resumed','stopped')
        AND processing_status = 'processed'
       THEN 'ELIGIBLE' ELSE 'INELIGIBLE' END AS eligibility
FROM campaign
ORDER BY id;

-- Log rows that sit under an ineligible campaign
-- (proves a log row can exist even when its campaign isn't reportable)
SELECT c.id AS campaign_id, COUNT(l.id) AS log_rows
FROM campaign c
JOIN communication_log l ON l.communication_id = c.id
WHERE NOT (c.creation_status IN ('approved','aborted','resumed','stopped')
           AND c.processing_status = 'processed')
GROUP BY c.id;


-- ============================================================
-- 3. RETRY CHAIN ANALYSIS
-- ============================================================

-- Step 0: naive count, scope only, no eligibility or dedup logic
SELECT COUNT(*) AS naive_count
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01' AND sent_time < '2026-11-01';

-- Step 1: eligibility-filtered count
SELECT COUNT(*) AS eligible_count
FROM communication_log l
JOIN campaign c ON c.id = l.communication_id
WHERE l.merchant_id = 501
  AND l.communication_type = '2'
  AND l.sent_time >= '2026-10-01' AND l.sent_time < '2026-11-01'
  AND c.creation_status IN ('approved','aborted','resumed','stopped')
  AND c.processing_status = 'processed';

-- Recursive CTE: map every campaign to its ultimate root ancestor.
-- Anchor: campaigns with no parent (chain roots).
-- Recursive member: walk children down to any depth via parent_id.
-- Terminates naturally when no more children reference a given id.
WITH RECURSIVE campaign_root(id, root_id) AS (
  SELECT id, id FROM campaign WHERE parent_id IS NULL
  UNION ALL
  SELECT c.id, cr.root_id
  FROM campaign c
  JOIN campaign_root cr ON c.parent_id = cr.id
)
SELECT * FROM campaign_root ORDER BY root_id, id;

-- Family size per root — tells us whether a root is a real retry chain (>1)
-- or a standalone campaign (exactly 1)
WITH RECURSIVE campaign_root(id, root_id) AS (
  SELECT id, id FROM campaign WHERE parent_id IS NULL
  UNION ALL
  SELECT c.id, cr.root_id
  FROM campaign c
  JOIN campaign_root cr ON c.parent_id = cr.id
)
SELECT root_id, COUNT(*) AS n_campaigns_in_family
FROM campaign_root
GROUP BY root_id
ORDER BY root_id;


-- ============================================================
-- 4. FINAL TARGET_BASE
-- ============================================================
-- Rule: within a real retry chain (family size > 1), count DISTINCT
-- customers (a retried customer = one underlying communication).
-- Within a standalone campaign (family size = 1), keep raw COUNT(*)
-- so legitimate independent repeat sends are NOT collapsed.

WITH RECURSIVE campaign_root(id, root_id) AS (
  SELECT id, id FROM campaign WHERE parent_id IS NULL
  UNION ALL
  SELECT c.id, cr.root_id
  FROM campaign c
  JOIN campaign_root cr ON c.parent_id = cr.id
),
eligible_campaign AS (
  SELECT id FROM campaign
  WHERE creation_status IN ('approved','aborted','resumed','stopped')
    AND processing_status = 'processed'
),
scoped_logs AS (
  SELECT l.*, cr.root_id
  FROM communication_log l
  JOIN campaign_root cr ON cr.id = l.communication_id
  JOIN eligible_campaign ec ON ec.id = l.communication_id
  WHERE l.merchant_id = 501
    AND l.communication_type = '2'
    AND l.sent_time >= '2026-10-01' AND l.sent_time < '2026-11-01'
),
family_size AS (
  SELECT root_id, COUNT(DISTINCT id) AS n_campaigns
  FROM campaign_root
  GROUP BY root_id
),
per_root AS (
  SELECT sl.root_id,
    fs.n_campaigns,
    COUNT(*) AS raw_rows,
    COUNT(DISTINCT sl.customer_id) AS distinct_customers,
    CASE WHEN fs.n_campaigns > 1 THEN COUNT(DISTINCT sl.customer_id)
         ELSE COUNT(*) END AS counted_value
  FROM scoped_logs sl
  JOIN family_size fs ON fs.root_id = sl.root_id
  GROUP BY sl.root_id
)
SELECT * FROM per_root ORDER BY root_id;

-- Final single number
WITH RECURSIVE campaign_root(id, root_id) AS (
  SELECT id, id FROM campaign WHERE parent_id IS NULL
  UNION ALL
  SELECT c.id, cr.root_id
  FROM campaign c
  JOIN campaign_root cr ON c.parent_id = cr.id
),
eligible_campaign AS (
  SELECT id FROM campaign
  WHERE creation_status IN ('approved','aborted','resumed','stopped')
    AND processing_status = 'processed'
),
scoped_logs AS (
  SELECT l.*, cr.root_id
  FROM communication_log l
  JOIN campaign_root cr ON cr.id = l.communication_id
  JOIN eligible_campaign ec ON ec.id = l.communication_id
  WHERE l.merchant_id = 501
    AND l.communication_type = '2'
    AND l.sent_time >= '2026-10-01' AND l.sent_time < '2026-11-01'
),
family_size AS (
  SELECT root_id, COUNT(DISTINCT id) AS n_campaigns
  FROM campaign_root
  GROUP BY root_id
),
per_root AS (
  SELECT sl.root_id, fs.n_campaigns,
    CASE WHEN fs.n_campaigns > 1 THEN COUNT(DISTINCT sl.customer_id)
         ELSE COUNT(*) END AS counted_value
  FROM scoped_logs sl
  JOIN family_size fs ON fs.root_id = sl.root_id
  GROUP BY sl.root_id
)
SELECT SUM(counted_value) AS target_base FROM per_root;
-- Expected result: 22


-- ============================================================
-- 5. VALIDATION
-- ============================================================

-- V1: Eligibility — confirm exactly one ineligible campaign and its row count
SELECT c.id, COUNT(l.id) AS excluded_rows
FROM campaign c JOIN communication_log l ON l.communication_id = c.id
WHERE NOT (c.creation_status IN ('approved','aborted','resumed','stopped')
           AND c.processing_status = 'processed')
GROUP BY c.id;
-- Expect: 9004 -> 4

-- V2: Retry-family counts (raw vs. counted) — see section 4 per_root query above

-- V3: Standalone campaign check — 9101 has no parent and no children
SELECT * FROM campaign WHERE id = 9101 OR parent_id = 9101;
-- Expect: only the row for 9101 itself, no children

-- V4: Customer-level duplicate trace for the three multi-campaign customers
SELECT customer_id, communication_id, delivery_status, sent_time
FROM communication_log
WHERE customer_id IN ('C2','C3','D1','C20')
ORDER BY customer_id, sent_time;

-- V5: Known-wrong "naive global dedup" comparison — should NOT equal target_base
SELECT COUNT(DISTINCT l.customer_id) AS naive_global_distinct
FROM communication_log l
JOIN campaign c ON c.id = l.communication_id
WHERE l.merchant_id = 501
  AND l.communication_type = '2'
  AND l.sent_time >= '2026-10-01' AND l.sent_time < '2026-11-01'
  AND c.creation_status IN ('approved','aborted','resumed','stopped')
  AND c.processing_status = 'processed';
-- Expect: 21 (one less than the correct 22 — proves global dedup is wrong
-- because it incorrectly collapses C20's two legitimate standalone sends)
