# Xeno Data Analyst Assignment
# Comm-Log Send Reconciliation

## What's in here

- `reconciliation_report.md` — Full analytical write-up covering the
  business question, schema, data profiling, investigation process,
  reconciliation bridge, SQL, validation, and plain-English findings.

- `reconciliation.sql` — Reproducible SQLite SQL containing commented
  sections for data profiling, campaign eligibility, retry-chain analysis,
  final target_base calculation, and validation.

- `comm_log.db` — SQLite database containing the source data.

- `campaign.csv` — Campaign table in CSV format.

- `communication_log.csv` — Communication log table in CSV format.

- `generate_dataset.py` — Script supplied with the assignment that
  generates the synthetic dataset.

---

## The Answer

**target_base = 22**

Finance's stated target_base for merchant `501` in October 2026 is `22`.

I started with the most straightforward scoped count of communication-log
rows, which returned **30**.

The reconciliation from 30 to 22 is:

| Step | Adjustment | Result | Reason |
|---|---:|---:|---|
| Naive count | — | **30** | Initial count of in-scope communication-log rows |
| Campaign eligibility | **-4** | **26** | 4 rows belong to campaign `9004`, which is still `approval_awaiting` and therefore does not qualify for official reporting |
| Retry family `9001 → 9002 → 9003` | **-3** | **23** | 13 send attempts represent 10 distinct customers within the same underlying retry communication |
| Retry family `9201 → 9202` | **-1** | **22** | 6 send attempts represent 5 distinct customers within the same underlying retry communication |
| Final | — | **22** | Reconciles to Finance's target_base |

### Important standalone-campaign exception

Campaign `9101` is a standalone campaign with no retry descendants.

Customer `C20` appears twice in this campaign at different send times. These are treated as **two legitimate send events**, rather than being collapsed into one customer count.

This is why a blanket:

```sql
COUNT(DISTINCT customer_id)
