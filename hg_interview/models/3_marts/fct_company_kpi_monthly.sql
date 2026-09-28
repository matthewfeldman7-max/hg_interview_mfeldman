-- Grain: one row per company_id x expected month (the spine)
--
-- The core table behind the Sigma dashboard. Built on the spine of expected
-- months, so an unreported month is a row with a status, not an absence.
-- GBP values are only populated when the status is 'reported': the dashboard
-- never shows a guessed or partly converted number.

with spine as (
    select * from {{ ref('int_company_months') }}
),

companies as (
    select * from {{ ref('stg_portfolio__companies') }}
),

latest as (
    select * from {{ ref('int_kpi_monthly_latest') }}
),

joined as (
    select
        sp.company_id,
        sp.period_month,
        sp.period_end_date,
        sp.submission_due_date,
        sp.as_of_date,
        sp.is_exit_month,
        c.company_code,
        c.company_name,
        c.fund,
        c.sector,
        c.status as company_status,
        l.source_extract_date,
        l.currency,
        l.fx_rate,
        l.revenue          as revenue_local,
        l.arr              as arr_local,
        l.gross_churn_pct,
        l.headcount,
        l.is_headcount_outlier,
        l.is_churn_value_outlier,
        l.is_period_under_query,
        l.version_count,
        l.original_revenue,
        l.original_arr,
        l.original_gross_churn_pct,
        l.original_headcount,
        l.original_extract_date,
        coalesce(l.dq_flags, [])  as dq_flags,

        case
            when l.source_extract_date is not null and l.is_period_under_query
                then 'reported_under_query'
            when l.source_extract_date is not null and l.fx_rate is null
                then 'reported_not_convertible'
            when l.source_extract_date is not null
                then 'reported'
            -- exit month with no submission: not expected (pending business decision)
            when sp.is_exit_month
                then 'not_expected'
            when sp.as_of_date <= sp.submission_due_date
                then 'not_yet_reported'
            else 'missing'
        end as reporting_status
    from spine sp
    join companies c
        on c.company_id = sp.company_id
    left join latest l
        on  l.company_id   = sp.company_id
        and l.period_month = sp.period_month
),

gbp as (
    select
        *,
        case when reporting_status = 'reported' then revenue_local * fx_rate end as revenue_gbp,
        case when reporting_status = 'reported' then arr_local * fx_rate end     as arr_gbp,
        -- churn is a percentage, so it needs no FX rate: shown when not convertible too.
        -- (Portfolio churn still excludes these rows: ARR weighting needs arr_gbp.)
        case when reporting_status in ('reported', 'reported_not_convertible')
             then gross_churn_pct end                                            as gross_churn_pct_reported,
        -- Headcount is summed only where ARR and revenue are too, so every headline
        -- figure covers the same companies (Task 5, Q2). Flagged outliers are NOT
        -- excluded: they're included and warned on until the business decides
        -- how to treat them (Task 5, Q6).
        reporting_status = 'reported'                                            as is_headcount_included
    from joined
)

select
    company_id,
    period_month,
    period_end_date,
    company_code,
    company_name,
    fund,
    sector,
    company_status,
    reporting_status,
    submission_due_date,
    source_extract_date,
    as_of_date,

    -- local currency (drill-down)
    currency,
    revenue_local,
    arr_local,
    fx_rate,

    -- GBP
    revenue_gbp,
    arr_gbp,
    gross_churn_pct_reported as gross_churn_pct,
    headcount,
    is_headcount_included,

    -- Warnings: values that look wrong but are unconfirmed. Shown, not excluded.
    coalesce(is_churn_value_outlier, false) as is_churn_value_outlier,
    coalesce(is_headcount_outlier, false)   as is_headcount_outlier,

    -- Growth. The spine has exactly one row per company per month with no
    -- gaps, so lag(1) / lag(12) here is truly month-1 / month-12. (Over
    -- submitted rows it would not be: VEL is missing 2025-07 and 2025-08.)
    lag(arr_gbp, 1)  over w as arr_gbp_prior_month,
    lag(arr_gbp, 12) over w as arr_gbp_prior_year,
    arr_gbp / nullif(lag(arr_gbp, 1)  over w, 0) - 1 as arr_growth_mom_pct,
    arr_gbp / nullif(lag(arr_gbp, 12) over w, 0) - 1 as arr_growth_yoy_pct,
    lag(revenue_gbp, 1)  over w as revenue_gbp_prior_month,
    lag(revenue_gbp, 12) over w as revenue_gbp_prior_year,
    revenue_gbp / nullif(lag(revenue_gbp, 1)  over w, 0) - 1 as revenue_growth_mom_pct,
    revenue_gbp / nullif(lag(revenue_gbp, 12) over w, 0) - 1 as revenue_growth_yoy_pct,

    -- LTM revenue: only shown when all 12 months are reported and convertible,
    -- each converted at its own month-end rate. Never a 10- or 11-month sum.
    count(revenue_gbp) over w_ltm as revenue_ltm_months_available,
    case when count(revenue_gbp) over w_ltm = 12
         then sum(revenue_gbp) over w_ltm end as revenue_ltm_gbp,

    case when is_headcount_included then revenue_gbp / nullif(headcount, 0) end
        as revenue_per_head_gbp,

    -- Restatements: latest by default, with the fact and size visible.
    -- Any metric changing counts as a restatement, flagged per metric.
    coalesce(version_count > 1 and revenue_local   is distinct from original_revenue, false)         as is_revenue_restated,
    coalesce(version_count > 1 and arr_local       is distinct from original_arr, false)             as is_arr_restated,
    coalesce(version_count > 1 and gross_churn_pct is distinct from original_gross_churn_pct, false) as is_gross_churn_restated,
    coalesce(version_count > 1 and headcount       is distinct from original_headcount, false)       as is_headcount_restated,
    coalesce(version_count > 1 and (
                revenue_local   is distinct from original_revenue
             or arr_local       is distinct from original_arr
             or gross_churn_pct is distinct from original_gross_churn_pct
             or headcount       is distinct from original_headcount), false)
        as is_restated,
    case when version_count > 1 then original_extract_date end    as original_extract_date,
    case when version_count > 1 then original_revenue end         as original_revenue_local,
    case when version_count > 1 then original_arr end             as original_arr_local,
    case when version_count > 1 then original_gross_churn_pct end as original_gross_churn_pct,
    case when version_count > 1 then original_headcount end       as original_headcount,
    case when version_count > 1 then revenue_local - original_revenue end            as revenue_restatement_delta_local,
    case when version_count > 1 then arr_local - original_arr end                    as arr_restatement_delta_local,
    case when version_count > 1 then gross_churn_pct - original_gross_churn_pct end  as gross_churn_restatement_delta_pp,
    case when version_count > 1 then headcount - original_headcount end              as headcount_restatement_delta,

    dq_flags
from gbp
window
    w     as (partition by company_id order by period_month),
    w_ltm as (partition by company_id order by period_month
              rows between 11 preceding and current row)
