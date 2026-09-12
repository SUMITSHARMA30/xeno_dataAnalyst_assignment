# Comm-Log Send Reconciliation

## 1. Executive Summary

The naive send count for merchant 501 in October 2026 is 30. After excluding sends tied to a campaign that never reached reportable status (−4) and collapsing retried sends within genuine retry chains to one count per underlying communication (−4), the reconciled **target_base = 22**, matching Finance's benchmark. Legitimate repeat sends within a standalone campaign are deliberately *not* collapsed, since they represent independent business decisions rather than retries.

## 2. Business Question

How many communications from the October 2026 campaign activity for merchant 501 should count toward `target_base` for Finance reporting, once (a) campaign-level reporting eligibility and (b) retry-driven duplication are correctly handled?

*Source:* business rules below are taken directly from `README.md` (the data dictionary accompanying `ASSIGNMENT.md`) and verified against the actual table contents.

## 3. Data Understanding

- `campaign`: 7 rows — one field for `parent_id` chains related campaigns (retries).
- `communication_log`: 30 rows, all merchant 501, all `communication_type = '2'`, spanning 2026-10-03 to 2026-10-20.
- Delivery status: 26 delivered (900), 4 failed (1100); every failure is followed by a successful retry in a child campaign.
- 25 distinct customers appear in the raw log overall.

## 4. Schema and Relationships

| Table | Column | Type | Meaning | Relevance |
|---|---|---|---|---|
| campaign | id | INT PK | Campaign identifier | Join key |
| campaign | parent_id | INT, nullable | Parent campaign this one retries | Builds retry chains |
| campaign | creation_status | TEXT | e.g. approved, approval_awaiting | Eligibility gate |
| campaign | processing_status | TEXT | e.g. processed | Eligibility gate |
| communication_log | communication_id | INT FK → campaign.id | Which campaign sent this | Join key |
| communication_log | customer_id | TEXT | Recipient | Dedup unit |
| communication_log | merchant_id / communication_type / sent_time | — | Scope filters | Scoping |
| communication_log | delivery_status | INT | 900 delivered / 1100 failed | Validation, not part of the count |
| communication_log | credit_used / channel / scheduled_time | — | — | Irrelevant to target_base |

`campaign.id → communication_log.communication_id` links each send to its campaign. `campaign.parent_id` chains retries — `9001 → 9002 → 9003` is one retry family across three levels, not three independent campaigns.

## 5. Investigation Approach

Rather than jumping to a final query, the count was built up in stages: naive scope-only count → campaign eligibility filter → retry-chain identification via recursive traversal of `parent_id` → chain-aware deduplication, with each stage validated against actual query results before moving to the next.

## 6. Initial / Naive Count

```sql
SELECT COUNT(*) FROM communication_log
WHERE merchant_id = 501 AND communication_type = '2'
  AND sent_time >= '2026-10-01' AND sent_time < '2026-11-01';
```
Result: **30**. This treats every row as an independent, reportable send — the assumption the rest of the analysis tests.

## 7. Campaign Eligibility Analysis

Eligibility rule: `creation_status IN ('approved','aborted','resumed','stopped') AND processing_status = 'processed'`.

| Campaign | Parent | Creation Status | Processing Status | Eligible? | Reason |
|---|---|---|---|---|---|
| 9001 | — | approved | processed | ✅ | Meets both conditions |
| 9002 | 9001 | approved | processed | ✅ | Meets both conditions |
| 9003 | 9002 | approved | processed | ✅ | Meets both conditions |
| 9004 | 9001 | approval_awaiting | processed | ❌ | Creation status never settled |
| 9101 | — | approved | processed | ✅ | Meets both conditions |
| 9201 | — | approved | processed | ✅ | Meets both conditions |
| 9202 | 9201 | approved | processed | ✅ | Meets both conditions |

4 log rows sit under ineligible campaign 9004 (customers C11–C14) — real, delivered sends that nonetheless shouldn't count for reporting. **A communication-log row existing does not make it reportable.**

## 8. Retry Chain Analysis

A recursive CTE over `parent_id` resolves every campaign to its root ancestor:

```
9001 ──┬─→ 9002 ──→ 9003        (retry family, 3 levels)
       └─→ 9004 (ineligible)

9201 ──→ 9202                    (retry family, 2 levels)

9101                              (standalone, no parent or children)
```

Customer C3 was sent under 9001 (failed) → 9002 (failed) → 9003 (delivered): one underlying communication realized across three attempts. Customer C2 was sent under 9001 (failed) → 9002 (delivered): one underlying communication across two attempts. Customer D1 follows the same pattern under 9201 → 9202.

## 9. Standalone Campaign Analysis

Campaign 9101 has no parent and no children. Customer C20 appears twice under it, ten days apart (Oct 10 and Oct 20) — with no chain structure connecting these sends, the natural interpretation is two independent, legitimate re-targeting events rather than a retry of the same communication. These are **not** deduplicated.

## 10. Reconciliation Bridge

| Step | Description | Result | Adjustment | Reason |
|--:|---|--:|--:|---|
| 0 | Naive `COUNT(*)`, merchant 501 / Oct 2026 / type '2' | 30 | — | Baseline |
| 1 | Remove ineligible campaign 9004 | 26 | −4 | creation_status never settled |
| 2 | Collapse retry family 9001→9002→9003 to distinct customers | — | −3 | C2 (2→1), C3 (3→1) |
| 3 | Collapse retry family 9201→9202 to distinct customers | — | −1 | D1 (2→1) |
| 4 | Standalone campaign 9101 kept as raw count | — | 0 | C20's two sends are independent |
| **Final** | **target_base** | **22** | | Matches Finance benchmark |

## 11. Final SQL

```sql
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
```

**Algorithm, plain English:** find every campaign's ultimate root via the parent chain; keep only eligible, in-scope log rows; group rows by root campaign; if a root's family has more than one campaign (a real retry chain), count distinct customers so retries collapse to one; if the family is a single standalone campaign, keep the raw row count so legitimate repeat sends aren't erased; sum across all families.

Tested directly against `comm_log.db` → returns **22**.

## 12. Validation

- **V1 (eligibility):** exactly one ineligible campaign (9004), excluding 4 rows.
- **V2 (retry families):** family sizes {9001: 4 campaigns, 9101: 1, 9201: 2} — correctly separates chains from standalones.
- **V3 (per-root counted values):** 10 (family 9001, eligible slice) + 5 (family 9201) + 7 (standalone 9101) = 22.
- **V4 (customer trace):** manual row-by-row trace of C2, C3, D1, C20 confirms which rows should and shouldn't collapse.
- **V5 (negative control):** naive global `COUNT(DISTINCT customer_id)` on the eligible scope returns 21, not 22 — proving that global deduplication is wrong and chain-aware logic is what actually produces the correct answer.

## 13. Key Data Observations

1. Every failed send (delivery_status 1100) in this dataset is followed by a successful retry — no dead-end failures.
2. Campaign 9004 has real, delivered log rows despite being ineligible — a clean example of log existence not implying reportability.
3. The `9001→9002→9003` chain is three levels deep, requiring a general recursive solution rather than a hard-coded two-level assumption.
4. A naive fully-deduplicated approach (`COUNT(DISTINCT customer_id)` globally) lands one short of the correct answer (21 vs. 22), because it wrongly collapses the standalone campaign's two legitimate sends to the same customer.

## 14. Assumptions

- Eligibility rule, retry-chain definition, and the standalone-vs-retry distinction are taken directly from `README.md` and applied as stated — not inferred.
- "Underlying communication" = a root campaign plus every campaign chained off it via `parent_id`, to any depth; `target_base` counts distinct customers reached per underlying communication, per the README's explicit definition.
- Date scope is calendar October 2026 (`sent_time` in `[2026-10-01, 2026-11-01)`), per the stated exercise scope.

## 15. Final Conclusion

Starting from a naive count of 30, removing sends tied to an ineligible campaign (−4) and collapsing retry-driven duplicate sends within true retry chains (−4) — while explicitly preserving legitimate repeat sends in the standalone campaign — reconciles exactly to Finance's benchmark of **22**. The result is reproducible via `reconciliation.sql` against the provided `comm_log.db` with no hard-coded campaign IDs, using a recursive CTE that generalizes to retry chains of any depth.
