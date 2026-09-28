-- =====================================================================
-- Data-quality checks (see docs/task1_data_quality.md)
-- Each statement returns the offending rows - an empty result = no issue.
-- Company codes are normalised in-line where a check needs to join:
-- upper-case, Cyrillic 'А' (chr(1040)) -> Latin 'A', and TLR -> TAL.
-- =====================================================================

-- DQ1: FX rates that move more than 10% month-on-month (catches the
-- inverted USD 2025-03 rate: 1.2577 vs ~0.79 either side)
select month, from_ccy, rate, prev_rate, round(rate / prev_rate - 1, 3) as pct_change
from (
    select *, lag(rate) over (partition by from_ccy order by month) as prev_rate
    from fx_rates_monthly
)
where abs(rate / prev_rate - 1) > 0.10
order by from_ccy, month;

-- DQ2/3: KPI company codes that do not join to companies
-- (TLR = old Tallow & Reed code, lower-case 'kor', Cyrillic 'CАS').
-- hex() makes the homoglyph visible: CAS = 434153, CАS = 43D09053
select *
from kpi_monthly
where company_code not in (select company_code from companies);

-- DQ4: exact duplicate submissions (identical on every column)
select *, count(*) as n_copies
from kpi_monthly
group by all
having count(*) > 1
order by period_month, company_code;

-- DQ5: restatements - same company-month submitted more than once with
-- different values, showing the size of the change vs the previous version
with versions as (
    select distinct company_code, period_month, source_extract_date,
           revenue, arr, gross_churn_pct, headcount
    from kpi_monthly
)
select company_code, period_month, source_extract_date,
       revenue, revenue - lag(revenue) over w as revenue_delta,
       round(revenue / lag(revenue) over w - 1, 4) as revenue_pct,
       arr, arr - lag(arr) over w as arr_delta,
       round(arr / lag(arr) over w - 1, 4) as arr_pct
from versions
window w as (partition by company_code, period_month order by source_extract_date)
qualify count(*) over (partition by company_code, period_month) > 1
order by company_code, period_month, source_extract_date;

-- DQ6: churn unit - companies whose churn looks like a fraction rather
-- than percentage points (BRV ~0.01 vs ~0.4-1.5 for everyone else)
select upper(company_code) as company_code,
       min(gross_churn_pct) as min_churn, median(gross_churn_pct) as median_churn,
       max(gross_churn_pct) as max_churn, count(*) as n_rows
from kpi_monthly
group by 1
having median(gross_churn_pct) < 0.1
order by 1;

-- DQ7: headcount moves of more than 50% month-on-month
-- (NIM 2025-09 = 1320 between 130 and 132)
with latest as (
    select *,
           case when upper(replace(company_code, chr(1040), 'A')) = 'TLR' then 'TAL'
                else upper(replace(company_code, chr(1040), 'A')) end as company_code_clean
    from kpi_monthly
    qualify row_number() over (partition by company_code_clean, period_month
                               order by source_extract_date desc) = 1
)
select company_code_clean, period_month, headcount, prev_headcount,
       round(headcount / prev_headcount - 1, 2) as headcount_pct,
       round(revenue / prev_revenue - 1, 2) as revenue_pct
from (
    select *, lag(headcount) over w as prev_headcount, lag(revenue) over w as prev_revenue
    from latest
    window w as (partition by company_code_clean order by period_month)
)
where abs(headcount / prev_headcount - 1) > 0.5
order by company_code_clean, period_month;

-- DQ8: currency blank, non-ISO, or different from the company's
-- reporting currency (ORQ blank x2, CAS 'US$' x3)
select k.company_code, k.period_month, k.currency, c.reporting_currency,
       case when k.currency is null or trim(k.currency) = '' then 'blank'
            when not regexp_full_match(k.currency, '[A-Z]{3}') then 'not ISO 4217'
            else 'differs from reporting_currency' end as problem
from kpi_monthly k
left join companies c
    on c.company_code = upper(replace(k.company_code, chr(1040), 'A'))
where k.currency is null
   or not regexp_full_match(k.currency, '[A-Z]{3}')
   or k.currency <> c.reporting_currency
order by k.company_code, k.period_month;

-- DQ9a: FX currency-months missing from the rate table (SEK 2026-08)
select m.month, x.from_ccy
from (select distinct month from fx_rates_monthly) m
cross join (select distinct from_ccy from fx_rates_monthly) x
anti join fx_rates_monthly f
    on f.month = m.month and f.from_ccy = x.from_ccy
order by m.month, x.from_ccy;

-- DQ9b: non-GBP KPI rows with no FX rate for their month/currency
-- (BRV 2026-08 missing rate, CAS 'US$' and ORQ blank can't match)
select k.company_code, k.period_month, k.currency
from kpi_monthly k
left join fx_rates_monthly f
    on f.month = k.period_month and f.from_ccy = k.currency
where coalesce(k.currency, '') <> 'GBP'
  and f.rate is null
order by k.period_month, k.company_code;

-- DQ10: period_end_date is not the last day of period_month
-- (VEL 2025-10..2025-12 carry the 1st of the following month)
select company_code, period_month, period_end_date,
       last_day(strptime(period_month || '-01', '%Y-%m-%d'))::date as expected_end_date
from kpi_monthly
where period_end_date <> last_day(strptime(period_month || '-01', '%Y-%m-%d'))::date
order by company_code, period_month;

-- DQ11: missing company-months - each company is expected every month
-- from the start of the extract (or investment) to its exit (or the end
-- of the extract). VEL 2025-07/08, ORQ 2026-08, PEL 2025-03 (exit month)
with months as (
    select strftime(m, '%Y-%m') as period_month
    from range(date '2024-09-01', date '2026-09-01', interval 1 month) t(m)
),
kpi as (
    select distinct period_month,
           case when upper(replace(company_code, chr(1040), 'A')) = 'TLR' then 'TAL'
                else upper(replace(company_code, chr(1040), 'A')) end as company_code_clean
    from kpi_monthly
)
select c.company_code, c.status, c.exit_date, m.period_month
from companies c
cross join months m
left join kpi k
    on k.company_code_clean = c.company_code and k.period_month = m.period_month
where k.period_month is null
  and m.period_month >= strftime(c.investment_date, '%Y-%m')
  and (c.exit_date is null or m.period_month <= strftime(c.exit_date, '%Y-%m'))
order by c.company_code, m.period_month;

-- DQ12: submissions received outside the expected 6-10 days after month
-- end (only the LUM 2026-01..03 restatements received on 2026-07-15)
select company_code, period_month, source_extract_date,
       source_extract_date
         - last_day(strptime(period_month || '-01', '%Y-%m-%d'))::date as days_after_month_end
from kpi_monthly
where source_extract_date
        - last_day(strptime(period_month || '-01', '%Y-%m-%d'))::date not between 6 and 10
order by company_code, period_month;

-- DQ13 (observation): monthly revenue vs ARR/12 by company - TAL runs at
-- 1.5-1.7x while the rest of the portfolio is ~1.0-1.25x
select case when upper(replace(company_code, chr(1040), 'A')) = 'TLR' then 'TAL'
            else upper(replace(company_code, chr(1040), 'A')) end as company_code_clean,
       round(min(revenue * 12.0 / arr), 2) as min_ratio,
       round(median(revenue * 12.0 / arr), 2) as median_ratio,
       round(max(revenue * 12.0 / arr), 2) as max_ratio
from kpi_monthly
group by 1
order by median_ratio desc;

-- DQ14 (sanity, expect 0 rows): KPI rows before investment or after exit
select k.company_code, k.period_month, c.investment_date, c.exit_date
from kpi_monthly k
join companies c
    on c.company_code = upper(replace(k.company_code, chr(1040), 'A'))
where k.period_month < strftime(c.investment_date, '%Y-%m')
   or (c.exit_date is not null and k.period_month > strftime(c.exit_date, '%Y-%m'));
