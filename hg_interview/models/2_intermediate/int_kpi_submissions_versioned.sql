-- Grain: one row per company_id x period_month x source_extract_date (every version)
--
-- Infers values or compares across rows, so it lives here rather than in staging
-- (staging only looks up what a supplied value means):
--   * blank currency inferred from the company master (Task 1, issue 8)
--   * versions ranked so the latest can be chosen and restatements measured (issue 5)

with submissions as (
    select * from {{ ref('stg_portfolio__kpi_submissions') }}
),

companies as (
    select company_id, reporting_currency from {{ ref('stg_portfolio__companies') }}
)

select
    s.* exclude (currency, dq_flags),
    coalesce(s.currency, c.reporting_currency)             as currency,
    s.currency is null and c.reporting_currency is not null as is_currency_inferred,
    case when s.currency is null and c.reporting_currency is not null
         then list_append(s.dq_flags, 'currency_inferred')
         else s.dq_flags end                                as dq_flags,

    row_number() over w_latest_first                        as version_number,
    row_number() over w_latest_first = 1                    as is_latest,
    count(*) over w_company_month                           as version_count,

    -- first-submitted values, so the mart can show the size of any restatement
    first_value(s.revenue)         over w_oldest_first      as original_revenue,
    first_value(s.arr)             over w_oldest_first      as original_arr,
    first_value(s.gross_churn_pct) over w_oldest_first      as original_gross_churn_pct,
    first_value(s.headcount)       over w_oldest_first      as original_headcount,
    first_value(s.source_extract_date) over w_oldest_first  as original_extract_date
from submissions s
left join companies c
    on c.company_id = s.company_id
window
    w_company_month as (partition by s.company_id, s.period_month),
    w_latest_first  as (partition by s.company_id, s.period_month
                        order by s.source_extract_date desc),
    w_oldest_first  as (partition by s.company_id, s.period_month
                        order by s.source_extract_date
                        rows between unbounded preceding and unbounded following)
