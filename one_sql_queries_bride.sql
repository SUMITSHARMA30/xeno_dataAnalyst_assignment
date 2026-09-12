WITH RECURSIVE root(id, root_id) AS (
  SELECT id, id FROM campaign WHERE parent_id IS NULL
  UNION ALL
  SELECT c.id, r.root_id FROM campaign c JOIN root r ON c.parent_id = r.id
),
scope AS (
  SELECT l.*, r.root_id,
    c.creation_status IN ('approved','aborted','resumed','stopped')
      AND c.processing_status = 'processed' AS is_eligible
  FROM communication_log l
  JOIN campaign c ON c.id = l.communication_id
  JOIN root r ON r.id = l.communication_id
  WHERE l.merchant_id = 501 AND l.communication_type = '2'
    AND l.sent_time >= '2026-10-01' AND l.sent_time < '2026-11-01'
),
family AS (
  SELECT root_id, COUNT(*) AS n_campaigns FROM root GROUP BY root_id
)

SELECT 'naive count' AS step, COUNT(*) AS value FROM scope
UNION ALL
SELECT 'after eligibility filter', COUNT(*) FROM scope WHERE is_eligible
UNION ALL
SELECT 'final target_base', SUM(counted) FROM (
  SELECT CASE WHEN f.n_campaigns > 1 THEN COUNT(DISTINCT s.customer_id) ELSE COUNT(*) END AS counted
  FROM scope s JOIN family f ON f.root_id = s.root_id
  WHERE s.is_eligible
  GROUP BY s.root_id
);
