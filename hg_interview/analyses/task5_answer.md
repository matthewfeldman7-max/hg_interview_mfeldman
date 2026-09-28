# Task 5 — Questions for the business




## 1. What should the dashboard do with values flagged as potentially erroneous?

- **Why I'm asking:** the pipeline flags values that look wrong but can't be proven wrong without asking the company. Today they're included everywhere, with a warning:
  - NIM's Sep 2025 headcount of 1,320 (August 130, October 132) pushes portfolio headcount to 3,879 instead of about 2,690.
  - BRV's churn (0.0063–0.0126 against 0.22–1.56 for everyone else) may be a fraction. If it is, Halcyon II's ARR-weighted churn is understated by about 0.2pp.
- **Options:**
  - **Include with a warning** (current build): nothing is hidden, but headline figures can be visibly wrong until someone follows up.
  - **Hold out of portfolio and fund totals** but show at company level: headlines stay sensible, but the total no longer covers every company.
  - **Hide entirely** until confirmed, showing "under query" in place of the value.
- **Related:**
  - What range, or what size of month-on-month move, should count as suspicious for each metric? The current thresholds are placeholders.
  - When a company confirms a flagged value is genuine, who records that, and should the warning then disappear?
- **What changes:**
  - whether the marts null or exclude flagged values;
  - the outlier thresholds;
  - a `kpi_value_confirmations` seed, so a value confirmed as genuine stops warning. It only matches that exact value, so a later resubmission is checked again.


## 2. When the set of companies changes, what should "vs last month" and "vs 12 months ago" compare?

- **Why I'm asking:**
  - Aug 2026 Halcyon II ARR reads £48.1m because only 2 of its 4 companies are reported and convertible.
  - PEL exited in March 2025, so it sits in "12 months ago" but not "this month".
  - Total-to-total growth would show these as falls in ARR, not changes in reporting or ownership.
- **Options:**
  - **Like-for-like growth** (my suggestion): compare only companies present in both periods.
  - **Reported totals:** simple, but misleading.
  - **Both, side by side.**
- **Related: should totals include a company that can only be partly counted?** BRV reported 247 FTE for Aug 2026, but there's no SEK rate, so its ARR and revenue can't be converted.
  - **Current assumption:** BRV's headcount is left out of that month's portfolio total, so every headline figure covers the same companies.
  - **Alternative:** include it, since headcount needs no FX rate. The headcount total is then complete but covers 8 companies while ARR covers 7.
- **What changes:** the growth definitions and headcount totals in the portfolio and fund mart, and what the headline tiles show.

## 3. When does a late submission become "missing", and is an exit month reportable?

- **Why I'm asking:**
  - The data dictionary says companies submit 6–10 days after month end, but the dashboard target is the 12th working day.
  - ORQ's August 2026 submission wasn't in an extract taken on day 10. Is that late or missing?
  - PEL exited on 14 March 2025 and never submitted March. Is that a gap, or expected?
- **What changes:**
  - the due-date rule (`submission_due_days`, and calendar vs working days);
  - where each company's expected months end;
  - which companies get chased, and when.

## 4. For restatements, what does "since we last looked" mean, and do published figures need to be reproducible?

- **Why I'm asking:** LUM restated Q1 2026 revenue down 6% in July. The brief asks for the restatement to be visible, but:
  - "since we last looked" could mean since the last monthly refresh, or since each user's last visit;
- **What changes:**
  - Since the last refresh is simple: it uses load timestamps.
  - Per-user tracking is a Sigma feature, not a dbt one.
  - Point-in-time reproducibility means dbt snapshots of the marts.

## 5. Who owns corrections, and can the template be fixed at source?

- **Why I'm asking:**
  - Every fix in the pipeline (code aliases, the FX override, confirming BRV's churn and NIM's headcount, the outlier thresholds) needs someone to approve it. Finance, Portfolio Operations or the deal team?
  - The underlying causes probably are template design: free-text company codes (lower case, a Cyrillic letter, a renamed code), a free-text currency (`US$`, blanks) and hand-typed dates.
  - The FX feed produced an inverted rate. Who owns it?
- **What changes:**
  - the `approved_by` owner and the review process for the override seeds;
  - whether we keep patching symptoms or fix the template (drop-down codes and currencies, a locked reporting period). A template fix removes most of Task 1's issues permanently.
