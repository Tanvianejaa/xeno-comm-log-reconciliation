# Comm-Log Send Reconciliation

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

##  The reconciliation bridge

| Step | Description | Result | Reason |
|---|---|---|---|
| 0 | Naive `COUNT(*)` | **30** | Starting point — every send attempt, no logic applied |
| 1 | `COUNT(DISTINCT customer_id)` | **25** | `target_base` counts distinct customers reached, not raw send attempts |
| 2 | Exclude campaign 9004 (`creation_status = 'approval_awaiting'`) | **21** | Not yet approved, even though its sends already ran — `creation_status` is the actual reporting gate, not `processing_status` |
| 3 | Add back a customer's 2nd send under standalone campaign 9101 | **22**  | Standalone campaigns count every send as its own event — they aren't deduped by customer the way retry chains are |

---

##  What made this non-trivial

Two things in the data look identical on the surface but mean opposite things for counting:

- **Retry chains** (`campaign.parent_id` links back to an earlier attempt) → a customer reached across multiple attempts in the chain counts **once**.
- **Standalone campaigns** (no parent, no children) → every send is its **own** event, even for a repeat customer.

Nothing in `communication_log` itself tells you which rule applies — you have to join back to `campaign.parent_id` to know. Also easy to get fooled: `processing_status = 'processed'` looks like the "is this send official" flag, but it's actually `creation_status` that gates a campaign out of reporting.

Full reasoning, including dead ends, is in [`investigation.md`](./investigation.md).

---

##  How to reproduce

```bash
sqlite3 data/comm_log.db
.read queries.sql
```

or open `notebook.ipynb` and run all cells — it connects to `data/comm_log.db` directly and walks through the same steps interactively.

---

*Take-home assignment for Xeno's Data Analyst Internship Drive 2026.*
