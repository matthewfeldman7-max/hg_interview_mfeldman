# Hg Data Engineer — take-home submission

My Answers to the questions are inside the analyses folder, with the models, tests, seeds etc built in their respective folders/files.

I spent somewhere around 2 hours on this project

## Running it

Requires [uv](https://docs.astral.sh/uv/). The three supplied CSVs are loaded as dbt seeds, so nothing else is needed.

```bash
uv sync
cd hg_interview
uv run dbt build
```

dbt needs a profile. Put this in `~/.dbt/profiles.yml`, or in `hg_interview/profiles.yml`:

```yaml
hg_interview:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: dev.duckdb
      threads: 1
```

**Expected result:** `PASS=38 WARN=4 ERROR=0`. The four warnings are deliberate, because they surface known issues without blocking the load:
- lower-case and lookalike-character company codes;
- NIM's headcount outlier;
- BRV's churn outlier (possibly supplied as a fraction, pending confirmation);
- VEL's two missing months.

## Layout

```
hg_interview/
├── analyses/          Task answers + exploration SQL
├── models/
│   ├── 1_staging/       row-level cleansing (types, codes, currencies, dates, overrides)
│   ├── 2_intermediate/  versions/restatements, expected-month spine, GBP conversion
│   └── 3_marts/         fct_company_kpi_monthly, agg_portfolio_kpi_monthly (for Sigma)
├── seeds/
│   ├── data/            the supplied extract
│   └── reference/       reviewed config: code/currency aliases, KPI and FX overrides
└── tests/             singular tests (FX sanity, GBP-only-when-reported, reconciliation)
```
