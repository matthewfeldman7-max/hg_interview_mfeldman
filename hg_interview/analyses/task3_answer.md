# Task 3 — Code

All code is working dbt, built and tested end to end on the supplied files. The dialect is DuckDB, because that's what I could run locally. The Snowflake differences are small and listed at the end.

## What's included

Three snippets are the answer to the task. The other models exist so that those three run for real rather than as pseudo-code.

| | Model | Role |
|---|---|---|
| **1. Cleansing** | [stg_portfolio__kpi_submissions.sql](../models/1_staging/stg_portfolio__kpi_submissions.sql) | Task 1 issues 2, 3, 4, 6, 8 and 10 in one staging model |
| **2. Mart** | [fct_company_kpi_monthly.sql](../models/3_marts/fct_company_kpi_monthly.sql) | Company × expected month: reporting status, GBP conversion, growth, LTM, restatements |
| **3. Mart** | [agg_portfolio_kpi_monthly.sql](../models/3_marts/agg_portfolio_kpi_monthly.sql) | Portfolio and fund headline figures: ARR-weighted churn, like-for-like growth |
| Supporting | [stg_portfolio__companies](../models/1_staging/stg_portfolio__companies.sql), [stg_portfolio__fx_rates](../models/1_staging/stg_portfolio__fx_rates.sql) | Casting; FX overrides |
| Supporting | [int_kpi_submissions_versioned](../models/2_intermediate/int_kpi_submissions_versioned.sql), [int_company_months](../models/2_intermediate/int_company_months.sql), [int_kpi_monthly_latest](../models/2_intermediate/int_kpi_monthly_latest.sql) | Versions and currency inference; the expected-month spine; latest version in GBP with outlier flags |
| Config | [seeds/reference/](../seeds/reference/) | `company_code_aliases`, `currency_aliases`, `kpi_overrides`, `fx_rate_overrides`: every non-mechanical fix, with a reason and an approver |
| Tests | [_staging.yml](../models/1_staging/_staging.yml), [_intermediate.yml](../models/2_intermediate/_intermediate.yml), [_marts.yml](../models/3_marts/_marts.yml), [tests/](../tests/) | Error tests are the Task 1 load-blockers; warn tests surface issues without stopping the load |

## Snippet 1: cleansing (`stg_portfolio__kpi_submissions`)

Each step fixes one Task 1 issue and records what it did:

1. **Collapse exact duplicates** with `select distinct` (issue 4). Rows that share a key but *differ* survive as separate rows, so the uniqueness test blocks the build instead of a random row being kept.
2. **Normalise and resolve company codes** with `upper(trim())`, then map to `company_id` through the company master and the reviewed alias seed (issues 2 and 3). The alias seed has validity dates, so `TLR` only maps for the months it was actually in use.
3. **Map currency symbols** (`US$` → `USD`) via the alias seed (issue 8).
4. **Treat `period_month` as authoritative and derive `period_end_date`** (issue 10):
   - a one-day slip is flagged `period_end_derived`;
   - any other mismatch, or a period ending after the row was received, is flagged `period_under_query`. The mart then shows it as `reported_under_query` rather than guessing.
5. **Apply confirmed value corrections** from `kpi_overrides` (issues 6 and 7): one row per company, month and metric, holding the corrected value. The seed is empty for now, because neither BRV's churn nor NIM's headcount has been confirmed. Nothing is corrected on a guess.

Every fix sets a boolean *and* adds an entry to `dq_flags`, so the dashboard can show exactly what was changed. The raw values (`raw_company_code`, `raw_currency`, `raw_period_end_date`, `raw_revenue`, `raw_arr`, `raw_gross_churn_pct`, `raw_headcount`) are kept alongside the cleaned ones.

Values that look wrong but aren't confirmed are flagged in `int_kpi_monthly_latest`, not corrected. Headcount or churn more than 3× above or below the company's trailing 12-month median, or churn outside the 0.1–10 range, gets `headcount_outlier` or `churn_value_outlier`. Nothing is excluded: the value stays in the company row and in the portfolio and fund totals. The mart carries `is_headcount_outlier` / `is_churn_value_outlier`, and the roll-up counts flagged companies (`companies_headcount_flagged`, `companies_churn_flagged`) so the dashboard can show the warning next to the figure. What to do with flagged values is Task 5, Q6. The thresholds are dbt vars and are placeholders until the business sets them.

Nothing is filtered out. An unrecognised code leaves `company_id` null, and the `not_null` and `relationships` tests on this model stop the build. That is the Task 1 rule of blocking rather than letting a company silently disappear.

## Snippet 2: company-month mart (`fct_company_kpi_monthly`)

Built on the spine of *expected* months, so a month with no submission is a row with a status rather than a gap:

```sql
case
    when l.source_extract_date is not null and l.is_period_under_query then 'reported_under_query'
    when l.source_extract_date is not null and l.fx_rate is null       then 'reported_not_convertible'
    when l.source_extract_date is not null                            then 'reported'
    when sp.is_exit_month                                              then 'not_expected'
    when sp.as_of_date <= sp.submission_due_date                       then 'not_yet_reported'
    else 'missing'
end as reporting_status
```

Points worth drawing out:
- **GBP values exist only when the status is `reported`.** A test enforces this in both directions, so the dashboard never shows a guessed or partly converted number.
- **`lag(arr_gbp, 12)` is safe here, but only because the spine has no gaps.** The same `lag()` over submitted rows would compare VEL's September with its June.
- **LTM revenue is null unless all 12 months are reported and convertible**, with `revenue_ltm_months_available` shown alongside. It's never a 10- or 11-month sum.
- **The latest version is used by default**, with `is_restated`, the original value and the delta, which is what the restatement requirement asks for. A change to any metric (revenue, ARR, churn or headcount) counts as a restatement and gets its own per-metric flag, such as `is_headcount_restated`.
- **Status is calculated against an `as_of_date` variable** (the extract date), not `current_date`, so a re-run for a late submission gives a reproducible answer.

## Snippet 3: portfolio and fund roll-up (`agg_portfolio_kpi_monthly`)

One `group by grouping sets ((period_month), (period_month, fund))` produces both the portfolio and the fund rows, so the two levels can't disagree. The business definitions live here:

```sql
-- churn weighted by ARR, not a simple average
sum(gross_churn_pct * arr_gbp)
    / nullif(sum(case when gross_churn_pct is not null then arr_gbp end), 0)

-- like-for-like growth: only companies with a value in both months
sum(case when arr_gbp_prior_month is not null then arr_gbp end)
    / nullif(sum(case when arr_gbp is not null then arr_gbp_prior_month end), 0) - 1
```

## What I actually ran

- **Versions:** dbt-core 1.12.5 with dbt-duckdb 1.11.0 (DuckDB 1.5.5), on the three supplied CSVs loaded as dbt seeds.
- **Command:** `dbt build`
- **Result:** `PASS=38 WARN=4 ERROR=0`. The four warnings are the intended ones:
  - `assert_raw_company_code_format`: 6 rows (`kor` ×4, `CАS` ×2). These are resolved by normalisation and aliases, so they don't block.
  - The headcount outlier check: NIM 2025-09.
  - The churn outlier check: all 24 BRV months (possibly supplied as fractions). No other company's churn is flagged.
  - Both stay in the data and the totals, with the warning shown, until the business answers Task 5, Q6.
  - `no_missing_company_months`: VEL 2025-07 and 2025-08.
- **FX block:** I also confirmed the FX test blocks when it should. Run over the *source* rates, without the override, it returns USD 2025-03 (+58%) and 2025-04 (−37%). With the reviewed override in place it passes.

**Reporting status across all 199 expected company-months:**

| Status | Count | Company-months |
|---|---|---|
| `reported` | 194 | |
| `missing` | 2 | VEL 2025-07, 2025-08 |
| `not_yet_reported` | 1 | ORQ 2026-08 (due 2026-09-10, the same day as the extract) |
| `reported_not_convertible` | 1 | BRV 2026-08 (no SEK rate) |
| `not_expected` | 1 | PEL 2025-03 (exit month) |

**Other spot checks against Task 1:**
- The LUM restatement deltas match exactly: revenue −259,859 / −281,101 / −294,561.
- VEL's LTM revenue is null for 2026-05 to 2026-07 and first appears for 2026-08.
- Portfolio headcount for Sep 2025 is 3,879 with `companies_headcount_flagged = 1`. It includes NIM's unconfirmed 1,320, so it's about 1,190 higher than the ~2,690 it would be if NIM's real headcount is 132. The mart shows the submitted figure with the warning rather than guessing the correction.

**Why like-for-like growth matters (Aug 2026):** Halcyon II's ARR total drops to £48.1m because only 2 of its 4 companies can be counted: ORQ hasn't reported yet and BRV has no FX rate. Like-for-like month-on-month growth is still a sensible +1.3%. A plain total-to-total comparison would have shown the fund collapsing.

## Snowflake differences

| DuckDB (as run) | Snowflake |
|---|---|
| `list_filter([...], lambda f: f is not null)`, `list_append`, `list_concat` | `array_construct_compact(...)`, `array_append`, `array_cat` |
| `range(start, stop, interval '1 month')` for the month spine | `dbt_utils.date_spine` (or a `generator` table) |
| `regexp_full_match(code, '[A-Z]{3}')` | `regexp_like(code, '[A-Z]{3}')` |
| Framed `median() over (... rows between 12 preceding and 1 preceding)` | Snowflake's `median` doesn't accept a window frame, so use a self-join over the prior 12 months |

Everything else (`qualify`, `group by all`, `exclude`, `grouping sets`, `last_day`, date + integer) works in both.

## With more time

- Enforce dbt **model contracts** on the two marts, so column changes can't silently break Sigma.
- Build `fct_kpi_restatements` for the "what changed since we last looked" view. It needs a load timestamp from ingestion (Task 4).
- Build the other Task 2 models not yet implemented:
  - `int_kpi_restatements`, one row per superseded version. Today the mart compares the latest version only with the first submission.
  - `int_fx_rates`, adding GBP = 1.0 as a row. Today it's a `case` in `int_kpi_monthly_latest`.
  - `dim_company` for Sigma filters and the hierarchy. Today company attributes are only denormalised onto the fact.- Replace the `as_of_date` variable with the extract's load metadata.
- Add unit tests (dbt 1.8+) for the status `case` statement, one fixture per status.
