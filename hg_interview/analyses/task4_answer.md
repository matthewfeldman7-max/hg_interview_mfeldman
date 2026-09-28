# Task 4 — Ingestion specification: portfolio KPI extract → Mantle staging

## Context

- Portfolio companies submit monthly KPIs to a portfolio-monitoring tool. The tool exports a monthly extract of three CSV files.
- You are building the load from that extract into Mantle (AWS, Terraform, dbt, Snowflake), up to and including the dbt **staging** layer. Hg builds the intermediate and mart layers, and the Sigma dashboard.
- The data is **known to contain quality issues** (see the attached Task 1 profile). Your job is to land it faithfully and apply the staging rules below. **Do not fix data during loading.**

## Scope

**In scope**
- Landing the files in S3.
- Loading them into a Snowflake `RAW` schema.
- Three dbt staging models, with their tests.
- Alerting.
- Terraform for all infrastructure.
- A runbook.

**Out of scope**
- Intermediate and mart models, Sigma, and any business logic.

## Source

**Files**

| File | Grain | Rows in sample |
|---|---|---|
| `kpi_monthly.csv` | One row per company, per month, per submission | 203 |
| `companies.csv` | One row per company | 9 |
| `fx_rates_monthly.csv` | One row per month × currency | 71 |

**Format**
- UTF-8, comma-separated, header row, ISO dates.
- The column definitions are in the attached data dictionary.

**Delivery (assumption; please confirm with the tool owner)**
- One extract a month, around 10 days after month end.
- Occasional ad hoc re-runs when a company submits late.
- Each extract contains the **full history**, not only new rows.

## Requirements

**Raw layer**
- **Load every column as text.** Do not use type inference: values must stay exactly as supplied, including case, whitespace and non-ASCII characters. For example, one company code contains a Cyrillic letter that must survive the load.
- **Store empty fields as NULL** consistently in every column.
- **Append only.** Never update or delete. Keep every extract. Restatements can already be seen inside a single extract (a second `source_extract_date` for the same company-month), but only comparing extracts tells us what changed since the last load, for the "what's changed since we last looked" view. It also catches rows that were edited in place or deleted in the monitoring tool.
- **Add metadata columns to every row:**
  - `_file_name`
  - `_file_checksum`
  - `_extract_date` (from the file name or manifest, not the load time)
  - `_loaded_at`
  - `_row_number`
- **Make loads idempotent at file level.** A file whose checksum has already been loaded is skipped.
  - Do **not** deduplicate rows. Raw must be a faithful copy of each file; staging collapses identical rows.
- **Fail the whole file if the layout changes.** A missing, extra or renamed column, or non-UTF-8 content, fails the file with an alert. Never load part of a file.

**Staging (dbt)**
- Build `stg_portfolio__kpi_submissions`, `stg_portfolio__companies` and `stg_portfolio__fx_rates` to the supplied reference implementation. That implementation is working dbt in DuckDB, and needs porting to Snowflake.
- **All corrections come from the four reference seeds** (code aliases, currency aliases, KPI overrides and FX overrides). Do not hard-code company or currency values in SQL.
- **Never filter rows out.** If a row can't be resolved, a test must fail; the row must not be dropped.
- **Test severity is part of the spec** (error = block the build, warn = load and flag). Implement it exactly as supplied.

**Operations**
- **Everything is deployed through Terraform and CI.** No manually created objects in any environment.
- **Alert on failure within 1 hour.** Any load failure, error-severity test failure, or missing monthly extract (none by day 12 after month end) alerts the named support channel.
- **Re-runs must be deterministic.** Rebuilding staging from raw must give identical output. No `current_date` logic.

## Acceptance criteria

Each criterion is tested in the dev environment using the sample extract plus the edge-case files we supply.

1. **Row counts:** the sample loads 203 / 9 / 71 rows into `RAW`, and a per-column checksum matches the source file.
2. **Idempotence:** re-loading the same file adds 0 rows.
3. **Restatements are kept:** a second extract containing a restated row is appended, and both versions are present in `RAW`.
4. **Characters preserved:** the company code `CАS` is stored byte-for-byte (hex `43D09053`), and `kor` keeps its lower case.
5. **Bad files rejected whole:** a file with a missing column, or one that isn't UTF-8, is rejected entirely (0 rows loaded) and an alert fires.
6. **Staging output matches the reference:** `stg_portfolio__kpi_submissions` has 198 rows (203 minus 5 collapsed duplicates), and a row-by-row comparison against the reference output shows 0 differences.
7. **Unknown codes block the build:** adding an unmapped company code to a test file makes the dbt build fail with an error, not a warning.
8. **Tests match the reference:** all staging tests pass on the sample extract, with the same warning counts as the reference run.
9. **Alerting:** an alert reaches the support channel within 1 hour of an induced failure.
10. **Reproducibility:** tearing down and redeploying from Terraform, then rebuilding from `RAW`, reproduces identical staging tables.

## How we'll QA before sign-off

- **Watch the acceptance tests run** in your dev environment. We supply the edge-case files: a duplicate file, a restated row, a schema change, a non-UTF-8 file and an unknown code.
- **Compare outputs:** we diff your staging tables against our reference output. Any difference must be explained or fixed.
- **Review the code:** Review the dbt and Terraform pull requests against Mantle standards before they are merged.
- **Parallel run:** one live monthly extract runs through your pipeline while Portfolio Operations still builds the manual spreadsheet. Figures must reconcile before sign-off.
- **Handover:** we won't sign off without these deliverables:
  - a runbook covering re-running for a late submission, adding an alias or override seed row, and responding to each alert;
  - documented alert ownership;
  - a walkthrough session with the Hg team.
