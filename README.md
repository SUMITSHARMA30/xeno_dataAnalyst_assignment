# xeno_dataAnalyst_assignment
#  Comm-Log Send Reconciliation

#  What's in here

-'reconciliation_report.md' - the full write-up. Schema, data profiling, how I got from the naive count to the final number, the SQL, validation, and a plain-English summary.
- 'reconciliation.sql' - one SQL file, split into commented sections: profiling, eligibility, retry-chain analysis, final query, validation.

# The answer

target_base = 22

Starting point was a naive count of 30. Two things bring it down to 22:
- 4 rows belong to a campaign that never cleared approval, so they get excluded.
- 4 more rows are duplicate retry attempts within a retry chain (same customer, same underlying communication, sent more than once), so they collapse down to 1 count each.

One thing that does NOT get collapsed: a customer who was legitimately re-targeted twice under a standalone campaign (no retry chain involved). Those two sends both count, since they're separate business events, not a retry.

# How to run it

1. Open `comm_log.db` in DB Browser for SQLite, or from the terminal:
   
   sqlite3 comm_log.db
   
2. Run `reconciliation.sql` (DB Browser: File > Execute SQL script. Terminal: `.read reconciliation.sql`).
3. The last query in the file, `SELECT SUM(counted_value) AS target_base FROM per_root;`, returns 22.
4. The validation section at the bottom checks the work a few different ways: it re-confirms the 4 excluded rows, confirms the standalone campaign really has no children, and runs a naive `COUNT(DISTINCT customer_id)` on purpose to show it gives 21 (wrong) instead of 22, which is why chain-aware dedup matters and a blanket distinct-count doesn't work here.

# Where the rules came from

Everything here follows the eligibility rule, retry-chain definition, and standalone-campaign exception exactly as described in the README/data dictionary that came with the assignment data. Nothing here is guessed; every rule was checked against the actual rows in the database before being used.
