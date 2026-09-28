# Data dictionary — Portfolio KPI extract (synthetic)

Three CSV files, UTF-8, comma-separated, header row, ISO dates. Extract taken 10 September 2026 from the portfolio-monitoring tool used by the (fictional) fund's finance team. All companies, funds and figures are fictional.

## companies.csv — one row per portfolio company (9 rows)

| Column | Type | Description |
|---|---|---|
| company_id | text | Stable internal identifier, `PC-nnn`. |
| company_code | text | Three-letter short code used by the finance team in KPI templates. |
| company_name | text | Legal / trading name. |
| fund | text | Fund that holds the investment. |
| sector | text | Sub-sector label. |
| hq_country | text | Country of headquarters. |
| reporting_currency | text | Currency the company reports its management accounts in (ISO 4217). |
| investment_date | date | Date of initial investment. |
| status | text | `Active` or `Exited`. |
| exit_date | date | Populated only when status = `Exited`. |

## kpi_monthly.csv — monthly KPIs as submitted by each company (203 rows)

Grain as supplied: one row per company per month per extract. Companies submit figures roughly 6–10 days after month end via a finance template; the monitoring tool appends each submission.

| Column | Type | Description |
|---|---|---|
| company_code | text | Short code — joins to `companies.company_code`. |
| period_month | text | Reporting month, `YYYY-MM`. |
| period_end_date | date | Last calendar day of the reporting month. |
| currency | text | Currency of the monetary columns on this row (ISO 4217). |
| revenue | number | Total recognised revenue for the month, in `currency`, whole units (not thousands). |
| arr | number | Annual recurring revenue at month end, in `currency`, whole units. |
| gross_churn_pct | number | Gross monthly revenue churn, in percentage points (e.g. `1.2` = 1.2 %). |
| headcount | integer | Full-time-equivalent employees at month end. |
| source_extract_date | date | Date the row was received by the monitoring tool. |

## fx_rates_monthly.csv — month-end FX rates to GBP (71 rows)

| Column | Type | Description |
|---|---|---|
| month | text | `YYYY-MM`. |
| from_ccy | text | Source currency (ISO 4217). |
| to_ccy | text | Always `GBP`. |
| rate | number | GBP per 1 unit of `from_ccy` (e.g. `0.79` means USD 1 = GBP 0.79). |
| rate_source | text | Where the rate came from. |
