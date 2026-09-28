## Summary (prioritised)

| # | Issue | Where | Dashboard impact | Action |
|---|---|---|---|---|
| 1 | presumed Inverted USD→GBP rate | FX USD 2025-03 | CAS GBP revenue and ARR overstated by 58% | **Block** |
| 2 | Company code renamed TLR → TAL | 8 KPI rows | 8 months of Tallow & Reed history orphaned | Auto-fix + flag; **block** on any *new* unmapped code |
| 3 | Lower-case code and a Cyrillic homoglyph | `kor` ×4, `CАS` ×2 | 6 more orphaned rows; CAS shows as "not reported" when it did report | Auto-fix + flag; **block** on any *new* unmapped code |
| 4 | Exact duplicate submissions | 5 pairs | Revenue, ARR and headcount double-counted; LTM inflated | Auto-fix |
| 5 | Restatements | LUM 2026-01 to 2026-03 | Old and new values summed if both kept| Keep all versions in database; latest shown in mart with delta surfaced |
| 6 | Churn appears very low for BRV, potentially sent as fraction instead of percentage | BRV, all 24 rows | ARR-weighted churn would be understated (Halcyon II by ~0.2pp) | Auto-fix (if a problem) via override + flag |
| 7 | Headcount 10× (probable typo) | NIM 2025-09 | Portfolio headcount +44% that month; revenue per head wrong | Flag, query with the company |
| 8 | Missing and non-ISO currency codes | ORQ ×2 blank, CAS ×3 `US$` | Rows can't be converted to GBP | Auto-fix + flag |
| 9 | Missing FX rate | SEK 2026-08 | BRV Aug 2026 can't be converted | Status `reported_not_convertible` |
| 10 | `period_end_date` is the first of the next month | VEL ×3 | Wrong month if joins use the date | Auto-fix (derive) + flag |
| 11 | Missing months | VEL 2025-07/08; ORQ 2026-08; PEL 2025-03 | Gaps in trends; LTM incomplete | Status `missing` / `not_yet_reported` / `not_expected` |


## Detail

### 1. Presumed Inverted USD rate — BLOCK

- **What:** `fx_rates_monthly.csv` line 21 has USD 2025-03 = **1.257692**. Every other USD month sits between 0.78 and 0.81. The value is the GBP→USD rate: its reciprocal is 0.7951, which fits between Feb (0.7946) and Apr (0.7904).
- **Impact:** Very incorrect numbers shown
- **Detect:**
  - A dbt test failing when any rate moves more than 10% month-on-month for its currency (would get clarity from finance).
- **Fix:** Ideally it would be corrected at source and re-ingested. If the source can't be fixed before the deadline, add a row to an `fx_rate_overrides` seed with the correct rate, a reason and an approver. Don't have an auto-applied fix as there could be many reasons for a rate failing this test not just the inverse rate used.
- **Why block:** The result would end up on the dashboard and would skew the numbers massively

### 2 & 3. Company codes that don't join to `companies`

| Raw code | Lines | Months | Cause |
|---|---|---|---|
| `TLR` | 6, 13, 26, 36, 45, 49, 62, 65 | 2024-09 to 2025-04 | Code used before Tallow & Reed was renamed (the company name records "formerly Tallow Ledger Reed"); `TAL` from 2025-05 |
| `kor` | 41, 54, 57, 71 | 2025-01 to 2025-04 | Lower case |
| `CАS` | 148, 154 | 2026-02, 2026-03 | The second letter is **Cyrillic А (U+0410)**: bytes `43 D0 90 53`. It looks identical on screen |

- **Impact:** 14 rows in KPI monthly fail to join to their value in the company table. With an inner join they vanish, with a left join they carry no fund or company. Either way the dashboard would show TAL, KOR and CAS as "not yet reported" for months they did report, which breaks the "no silent gaps" rule.
- **Detect:**
  - In staging, test the code against `^[A-Z]{3}$` (Exactly 3 characters, ASCII only). This catches case, homoglyph and length problems.
  - In staging, a `relationships` test on the *resolved* `company_id` → `companies.company_id` (error severity).
- **Fix:**
  - Apply `upper(trim())`.
  - Then resolve through a `company_code_aliases` seed (`raw_code`, `company_id`, `valid_from`, `valid_to`, `reason`) with rows for `TLR` → PC-106 and `CАS` → PC-105.
  - Key everything downstream on `company_id`, the stable identifier, never on `company_code`.
  - Add `code_aliased` to `dq_flags`.
  - Raise the `CАS` rows with the monitoring-tool owner. A free-text code field in the template is likely the root cause.
- **Why block on new unmapped codes:** An unknown code means a company's data wouldn't join to the companies table and silently disappear from the dashboard. The fix is a one-row seed change and a re-run, or adding a new companies entry to the seed if its a new company in the portfolio. 

### 4. Exact duplicate submissions — auto-fix

- **What:** Rows identical on every column, including `source_extract_date`:
  - LUM 2024-11 (lines 22–23);
  - NIM 2025-04 (68–69), 2025-05 (80–81) and 2025-06 (85–86);
  - KOR 2026-05 (170–171).
- **Impact:** Double counting in any sum (portfolio ARR, LTM revenue, headcount).
- **Detect:**.
  - `dbt_utils.unique_combination_of_columns` on (`company_id`, `period_month`, `source_extract_date`) after dedupe of exact matches (error).
- **Fix:**
  - In staging, `select distinct` over all columns.
- **Block condition:** Block only if two rows share company, month and extract date but *differ* in values. The latest version can't then be chosen deterministically. This doesn't occur in this extract.
- **Why auto-fix, not block:** Identical rows carry no competing information, so collapsing them can't pick a wrong value. Blocking would hold up the whole monthly load for something the pipeline can resolve safely.

### 5. Restatements — keep history, show latest

- **What:** LUM 2026-01, 2026-02 and 2026-03 were resubmitted on 2026-07-15 (lines 187–189), superseding lines 142, 149 and 161:

  | Month | Revenue (original → restated) | ARR (original → restated) |
  |---|---|---|
  | 2026-01 | 4,330,980 → 4,071,121 (−6.0%) | 49,737,119 → 48,991,062 (−1.5%) |
  | 2026-02 | 4,685,013 → 4,403,912 (−6.0%) | 50,680,053 → 49,919,852 (−1.5%) |
  | 2026-03 | 4,909,355 → 4,614,794 (−6.0%) | 51,613,646 → 50,839,441 (−1.5%) |


- **Impact:** The brief explicitly wants latest-by-default, with the restatement and its size visible.
- **Detect:** Count distinct `source_extract_date` values per (`company_id`, `period_month`) and flag where it is greater than 1 and the values differ. This is expected behaviour, so it's an informational signal rather than a test failure.
- **Fix:**
  - An intermediate model at submission grain keeps every version, ranked by `source_extract_date`.
  - The mart takes version 1 (latest) and carries `is_restated`, `restated_at`, `original_value` and `restatement_delta`/`pct` for each metric.
  - A separate restatement log feeds the "what changed since we last looked" view.
- **Why flag, not block:** The brief says restatements are expected, so this is normal behaviour, not an error. Blocking would stop the load every time a company resubmits.

### 6. BRV churn values look questionable — get clarification then auto-fix via explicit override if applicable

- **What:** All 24 BRV rows have `gross_churn_pct` between 0.0063 and 0.0126. Every other company is between 0.22 and 1.56, and the dictionary defines the column in percentage points. BRV is probably supplying a fraction
- **Impact:** Churn would be understated compared to actual value
- **Detect:**
  - A warn-level range test: `gross_churn_pct` value falls outside a range specified by the business and/or moved significantly when compared to previous months. 
- **Fix:**
  - Ask the company for clarification and if it was an error then fix in source if possible otherwise have a seed containing the correct value
  - Add `churn_value_outlier` flag
  - Raise it with BRV. Once confirmed, record the correction in `kpi_overrides` with `churn_value_corrected`
- **Why flag, not block:** We don't know it was a mistake until we ask them and it only affects one value for one company, it doesn't make sense to block the entire file for 1 potentially incorrect value


### 7. NIM headcount typo — flag, don't guess

- **What:** NIM 2025-09 headcount = **1320** (line 109). August is 130, October is 132, and revenue moved only 4%. This is almost certainly 132 with an extra zero.
- **Impact:** Portfolio headcount for Sep 2025 reads about 3,880 instead of about 2,690
- **Detect:** A warn-level test flagging headcount values the business would percieve as worth investigating ( more than 3× above or below the company's median over the previous 12 months for example)
- **Fix:**
  - Don't auto-correct: it would be a guess to just divide by 10
  - Keep the reported value at company level with a `headcount_outlier` flag.
  - Keep it in portfolio and fund headcount for now, with the warning shown next to the total (`companies_headcount_flagged`). Whether flagged values should be excluded is a question for the business (Task 5, Q6).
  - Raise it with NIM. Once confirmed, record the correction in `kpi_overrides` with `headcount_corrected`.
- **Why flag, not block:** One value in one row is suspect; NIM's revenue, ARR and churn for that month are fine. Blocking would hold back everyone's data over one value, and the flag keeps it visible until NIM confirms.

  ### 8. Missing and non-standard currency — auto-fix + flag

- **What:**
  - ORQ 2025-05 and 2025-06 have a blank `currency` (lines 76, 89).
  - CAS 2025-10 to 2025-12 use `US$` rather than `USD` (lines 121, 122, 130).
- **Impact:** None of these rows can be joined to an FX rate, so they would drop out of GBP totals.
- **Detect:**
  - `not_null` and `accepted_values` (the ISO codes in use) on raw `currency`, warn level.
  - A consistency test that staged `currency` equals `companies.reporting_currency`.
- **Fix:**
  - Map `US$` → `USD` via a `currency_aliases` seed and flag `currency_mapped`.
  - Fill blanks from `companies.reporting_currency` and flag `currency_inferred`. 
  - Only infer when blank. If a non-blank currency *disagrees* with the reporting currency, don't overwrite it. That might be a real change of reporting currency, so warn and investigate.
- **Why auto-fix and flag, not block:** Both fixes are unambiguous. `US$` can only mean USD, and a blank has one sensible value: ORQ's reporting currency, EUR, which every other ORQ row uses. Blocking would lose otherwise good revenue and ARR, and the flag keeps the inference visible, as the brief requires.

  ### 9. Missing FX rate — status, not block

- **What:** There is no SEK rate for 2026-08 (every other currency-month is present). BRV's August 2026 submission (line 202) therefore can't be converted.
- **Detect:** A coverage check that every (currency, month) in the staged KPIs has a rate, warn level.
- **Fix:**
  - Set the row's status to `reported_not_convertible`: local-currency values, churn and headcount are shown (none of them needs an FX rate), and GBP values are null.
  - BRV is left out of that month's ARR-weighted portfolio churn and revenue per head, because both need its GBP figures.
  - Don't carry the July rate forward, because the rule is the month-end rate for the reporting month.
  - Chase the rate feed.
  - A re-run after the rate lands resolves the status automatically.
- **Why flag, not block:** BRV's KPI row is correct; only the reference rate is missing, and the brief defines "reported but not yet convertible" as a status. Blocking would hold back every other company's month over one missing rate. The status shows exactly what's missing and clears on the next run.

  ### 10. VEL period end dates — auto-fix

- **What:** VEL 2025-10, 2025-11 and 2025-12 carry `period_end_date` = 2025-11-01, 2025-12-01 and 2026-01-01 (lines 115, 126, 135). Each end date is the first day of the *following* month, so both fields still point to the same month. This is a systematic one-day error, not an ambiguous row. `period_month` is also in sequence with VEL's other submissions.
- **Detect:**
  - `period_end_date = last_day(to_date(period_month || '-01'))`, via `dbt_utils.expression_is_true`, warn level.
  - A future-period check: neither `period_month`'s last day nor `period_end_date` may be later than `source_extract_date`. A month can't be reported before it has ended, so whichever field fails this check is the wrong one.
- **Fix:** Depends on how the two fields disagree.
  - **One day off** (the end date is the 1st of the next month): derive `period_end_date` from `period_month` in staging and flag `period_end_derived`. This covers all three VEL rows.
  - **Any other mismatch** (e.g. `2026-09` vs `2026-08-31`): don't guess. Exclude the row from the marts, show the company-month as `reported_under_query`, and confirm with the company.
  - Record the resolved month in an override seed, like other manual corrections.
  - Join on `period_month` (derived or confirmed), never on the supplied date.
- **Assumption to confirm:** `period_month` is treated as authoritative because the data dictionary describes `period_end_date` as the last calendar day of the reporting month, i.e. something that can be derived. Ask the business which field the company types into the template and which the tool calculates. The hand-typed field is the more likely source of errors.
- **Why auto-fix, not block:** In a one-day slip both fields agree on the month, so deriving the end date doesn't change where the figures belong. Only a genuinely ambiguous month is a real risk, and that case is held as `reported_under_query` without blocking every other company's data.

### 11. Missing months — resolved as reporting status

The date spine is 2024-09 to 2026-08, from investment date to exit month:

| Company | Month(s) | Recommended status | Notes |
|---|---|---|---|
| VEL | 2025-07, 2025-08 | `missing` | Over a year overdue. VEL 2025-09 then jumps +15% revenue and +7% headcount, so check whether it absorbs the gap. VEL's LTM revenue is incomplete for every window from 2025-08 to 2026-07. Show it as null and flagged, not as a 10- or 11-month sum. |
| ORQ | 2026-08 | `not_yet_reported` | The extract was taken exactly 10 days after month end, and ORQ normally submits on days 6–10. This is expected lateness, not a defect. It flips to `missing` after the agreed cut-off. |
| PEL | 2025-03 | `not_expected` (proposed) | Exited on 2025-03-14, mid-month. No row is correct if the exit month isn't reportable; this needs a business decision (see below). No PEL data appears after exit. |

- **Detect:** An `int_company_months` model (companies × months, bounded by investment and exit), left-joined to the latest submissions. Status comes from whether a row exists, the extract date against a submission due date, and FX availability.
- **Test:** Warn when any company-month is `missing`.
- **Why a status, not a block:** A missing submission isn't bad data; there's nothing to load. The brief asks for late and missing companies to be shown. Blocking would hold back every company that did report, whereas a status puts the gap on the dashboard where Portfolio Operations can chase it.