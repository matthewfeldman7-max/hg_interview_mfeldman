# Task 2 — Model design

## Design choices that drive everything else

1. **The mart grain is company × month over a spine of *expected* months, not over submitted rows.** "Which companies have not yet reported?" and "no silent gaps" can only be answered if a missing month exists as a row with a status. A fact built from submissions can't show what isn't there.
2. **Key on `company_id`, never `company_code`.** Codes change (TLR → TAL) and get mistyped. `company_id` is the stable identifier.
3. **Keep every submission version and pick the latest downstream.** Restatements are expected, and the business wants both the latest view *and* the size of each change. Dropping old versions early would make the second impossible.
4. **Put each kind of cleansing where the information to do it first exists** (see the table below). Row-level fixes and lookups that resolve what a supplied value means (a code to its `company_id`) happen in staging; fixes that infer a missing value from another table, or compare across rows, happen in intermediate models; business definitions live in the marts.
5. **Define the metrics once, in dbt, not in each Sigma workbook.** ARR-weighted churn, like-for-like growth and LTM are easy to get subtly wrong in a spreadsheet-style tool used by ~40 people. They're computed and tested in the marts, and Sigma mostly filters and displays.

## Layering

```
 SOURCES (raw, all text,          SEEDS (reviewed config, each row
 append-only, + load metadata)    has a reason and an approver)
 ─────────────────────────        ──────────────────────────────
 raw.kpi_monthly                  company_code_aliases
 raw.companies                    currency_aliases
 raw.fx_rates_monthly             kpi_overrides  (confirmed value corrections)
          │                       fx_rate_overrides
          ▼                                 │
 STAGING  ◄─────────────────────────────────┘
 stg_portfolio__companies        1 row per company_id
 stg_portfolio__kpi_submissions  1 row per company_id × period_month × source_extract_date
 stg_portfolio__fx_rates         1 row per month × currency
          │
          ▼
 INTERMEDIATE
 int_kpi_submissions_versioned   1 row per company_id × period_month × source_extract_date
 int_kpi_restatements            1 row per superseded version
 int_fx_rates                    1 row per month × currency (incl. GBP = 1)
 int_company_months              1 row per company_id × expected month  (the spine)
 int_kpi_monthly_latest          1 row per company_id × reported month
          │
          ▼
 MARTS (consumed by Sigma)
 dim_company                     1 row per company_id
 fct_company_kpi_monthly         1 row per company_id × expected month
 agg_portfolio_kpi_monthly       1 row per month × hierarchy node (portfolio, each fund)
 fct_kpi_restatements            1 row per company_id × period_month × restatement
```

## Where each kind of cleansing belongs

| Layer | Rule of thumb | What happens here |
|---|---|---|
| **Staging** | Anything decidable from the row itself, reviewed config, and key lookups that say what a supplied value *means* (code → `company_id`) | Cast types; trim and upper-case codes; resolve `company_id` via the company master and the alias seed; map `US$` → `USD`; derive `period_end_date` from `period_month`; apply value corrections confirmed with the company (`kpi_overrides`); apply FX overrides; collapse exact duplicates; start the `dq_flags` array |
| **Intermediate** | Anything that *infers* a missing value from another table, or compares across rows | Infer blank currency from `companies`; rank versions and compute restatement deltas; build the expected-month spine; convert to GBP; flag outliers against the business range and the company's own history (e.g. NIM headcount, BRV churn) |
| **Marts** | Business definitions and presentation | Reporting status; month-on-month and year-on-year growth; LTM revenue; revenue per head; ARR-weighted churn; portfolio and fund roll-ups; denormalised company attributes for Sigma |

Staging deliberately makes no judgement calls. Every adjustment there is either a mechanical type fix or an explicit, reviewed config entry, so the full set of changes to source data can be read in a few seed files.

## Models

### Staging

**`stg_portfolio__kpi_submissions`**. Grain: one row per `company_id` × `period_month` × `source_extract_date`.
- Keeps `raw_company_code` alongside the resolved `company_id`, so any alias can be traced back.
- `period_month` becomes a date (the first of the month); `period_end_date` is derived from it.
- Exact duplicate rows are collapsed with `select distinct`.
- Metrics stay in local currency.

**`stg_portfolio__fx_rates`**. Grain: one row per month × `from_ccy`. Applies `fx_rate_overrides` so a corrected rate is visible as an override, not a silent edit.

**`stg_portfolio__companies`**. Grain: one row per `company_id`. Casts dates and validates `status` against `exit_date`.

### Intermediate

**`int_kpi_submissions_versioned`**. Grain: one row per submission version.
- Fills blank currency from `companies.reporting_currency` and flags it `currency_inferred`.
- Adds `version_number`, where 1 is the latest by `source_extract_date`, plus `is_latest`.

**`int_kpi_restatements`**. Grain: one row per superseded version. Holds the old and new values, the absolute and percentage delta per metric, and `restated_at`.

**`int_fx_rates`**. Grain: one row per month × currency. Adds GBP = 1.0 so every row converts through a single join.

**`int_company_months`**. Grain: one row per `company_id` × expected month.
- Runs from the later of the investment month and the start of history, to the earlier of the exit month and the current reporting month.
- Carries a `submission_due_date`.
- Exited companies simply have no rows after exit, which meets the requirement to show them in history up to exit and not after.

**`int_kpi_monthly_latest`**. Grain: one row per `company_id` × reported month.
- Takes the latest version and converts to GBP at that month's rate.
- Adds outlier flags: a headcount or churn value more than 3× away from the trailing 12-month median, or churn outside the range the business sets. The thresholds are dbt vars.
- Flagged values (NIM headcount, BRV churn) stay in the data and in the totals, with a warning. Whether they should be held out until confirmed is a business decision (Task 5, Q6); if so, per-metric `include_in_aggregates` flags would do it without deleting anything.

### Marts

**`fct_company_kpi_monthly`** is the core table for Sigma. Grain: one row per `company_id` × expected month (the spine, left-joined to `int_kpi_monthly_latest`).

| Column group | Contents |
|---|---|
| Keys and attributes | `company_id`, `period_month`, and fund / company name / sector / code, denormalised so Sigma users don't need joins |
| Status | `reporting_status`: `reported` / `reported_not_convertible` / `reported_under_query` / `not_yet_reported` / `missing` / `not_expected` (an exit month with no submission, e.g. PEL March 2025) |
| Local values | `currency`, `revenue_local`, `arr_local`, `headcount`, `gross_churn_pct` |
| GBP values | `fx_rate`, `revenue_gbp`, `arr_gbp`. Null unless the status is `reported`, so no guessed numbers |
| Growth | `arr_gbp_prior_month`, `arr_gbp_prior_year`, and MoM / YoY % |
| Derived | `revenue_ltm_gbp` (null unless all 12 months are reported and convertible) with `revenue_ltm_complete`; `revenue_per_head_gbp` |
| Transparency | `dq_flags`; `is_restated` plus a per-metric flag, `restated_at`, and the original value and delta for every metric (revenue, ARR, churn, headcount); outlier warning flags (`is_headcount_outlier`, `is_churn_value_outlier`) |

Two decisions worth calling out:
- **Growth is computed over the spine (month − 1 and month − 12), not over submitted rows.** VEL is missing 2025-07 and 2025-08, so a `lag()` over its submissions would compare September with June and call it month-on-month growth. Over the gap-free spine, `lag(1)` and `lag(12)` are exact.
- **Status is calculated against an `as_of_date`** taken from the extract's load metadata, not from `current_date`. Re-running for a late submission then produces the same answer every time, and "not yet reported" vs "missing" doesn't change just because the job ran a day later.

**`agg_portfolio_kpi_monthly`** holds the headline figures for the portfolio and each fund. Grain: one row per month × hierarchy node (`node_type` = portfolio / fund).
- **ARR-weighted churn:** `sum(churn × arr_gbp) / sum(arr_gbp)` over rows included in aggregates. A simple average would give a small company the same weight as CAS.
- **Revenue per head:** `sum(revenue) / sum(headcount)`, not an average of company ratios, over the same companies on both top and bottom.
- **Warnings travel with the totals:** `companies_headcount_flagged` and `companies_churn_flagged` count the flagged values inside each figure, so a tile can say "includes 1 value under query".
- **Growth is like-for-like:** comparisons use only companies reported and convertible in *both* months, stored alongside `companies_expected` and `companies_reported`. Without this, VEL's missing months or PEL's exit would show up as falls in portfolio ARR.

This table exists so that the business definitions are implemented once and tested. Sigma can still aggregate `fct_company_kpi_monthly` for ad hoc work, but headline tiles read from here.

**`fct_kpi_restatements`** backs the "what has changed since we last looked" view. Grain: one row per company × month × restatement, with `detected_in_load` (the load it first appeared in) and the per-metric deltas. "Since we last looked" means since the previous load, which needs a load timestamp from ingestion. That requirement goes in the ingestion spec (Task 4).

**`dim_company`**. Grain: one row per `company_id`. Used for Sigma filters and the portfolio → fund → company hierarchy.

## Tests by layer

| Layer | Test | Severity | Failure it protects against |
|---|---|---|---|
| Source | Freshness on the load timestamp; row count > 0 | error | The dashboard silently showing last month's data because the extract didn't land |
| Source | Expected columns present | error | Template or tool changes shifting columns |
| Staging | `company_id` not null + `relationships` to companies | **error** | A new or mistyped code making a company's data disappear |
| Staging | Raw code matches `^[A-Z]{3}$` | warn | New case or lookalike-character variants (early warning before the relationship test) |
| Staging | Unique on company × month × extract date | **error** | Conflicting duplicates, where the latest version is ambiguous |
| Staging | FX: unique month × currency; rate > 0; month-on-month move ≤ 10% | **error** | Inverted or mis-keyed rates corrupting every company in that currency |
| Staging | Currency in the accepted ISO list (after mapping) | error | Unknown currencies that can never be converted |
| Staging | Period ends no later than `source_extract_date`; end date consistent with month | warn | Mis-keyed reporting periods |
| Staging | Metrics non-negative | warn | Template errors |
| Staging | `exit_date` populated if and only if status = Exited | error | Exited companies appearing after exit, or active ones being cut off |
| Intermediate | Exactly one `is_latest` row per company-month | **error** | Double counting across versions |
| Intermediate | Spine unique on company × month; row count matches the expected months per company | error | Companies vanishing from "not yet reported" |
| Intermediate | Every reported non-GBP month has a rate | warn | Drives `reported_not_convertible`; tells us to chase the rate feed |
| Intermediate | Headcount / churn outlier vs the business range and the company's own history | warn | Typos such as NIM's 1320, or BRV's possibly fractional churn, reaching portfolio totals |
| Mart | Unique on company × month; same row count as the spine | **error** | Fan-out from joins, or gaps that make a missing month invisible |
| Mart | `reporting_status` not null and in the accepted list | error | Rows with no explanation on the dashboard |
| Mart | GBP values null whenever status ≠ `reported` | error | Guessed or partly converted numbers being shown |
| Mart | Fund ARR sums to portfolio ARR; company ARR sums to fund ARR | error | Roll-up logic drifting from the company-level fact |
| Mart | ARR-weighted churn lies between the min and max company churn for that node | error | Weighting bugs |
| Mart | Enforced dbt model contracts (column names and types) | error | A model change silently breaking Sigma workbooks |

The block-or-flag policy from Task 1 maps directly onto severity: **error** means block the build, **warn** means load and surface the issue in `dq_flags` or `reporting_status`. The four staging and intermediate errors in bold are the load-blockers from Task 1.

## Materialisation and refresh

- **Staging:** views. **Intermediate and marts:** tables. At this volume a full rebuild takes seconds, which makes every run idempotent. A late submission is handled by a plain re-run, with no incremental state to repair.
- **Raw:** append-only, with file-level idempotency (a file already loaded is skipped; rows are not deduplicated at load, see Task 4). History is never overwritten, so restatements can always be rebuilt.
- **Future options:** switch raw → staging to incremental only if volume ever demands it. 

