-- Grain: one row per company_id x period_month that has at least one submission
--
-- Latest version only, converted to GBP at the month-end rate for that month.
-- Also flags values that are implausible (Task 1, issues 6 and 7: churn and
-- headcount). Flagged values are warned on, not excluded, until the business
-- decides how they should be treated (Task 5, Q6).

with latest as (
    select * from {{ ref('int_kpi_submissions_versioned') }}
    where is_latest
),

fx as (
    select rate_month, from_ccy, rate, is_overridden
    from {{ ref('stg_portfolio__fx_rates') }}
),

converted as (
    select
        l.*,
        case when l.currency = 'GBP' then 1.0 else fx.rate end as fx_rate,
        coalesce(fx.is_overridden, false)                      as is_fx_rate_overridden
    from latest l
    left join fx
        on  fx.rate_month = l.period_month
        and fx.from_ccy   = l.currency
),

with_history as (
    select
        *,
        -- trailing median of the previous 12 submitted months (DuckDB supports a
        -- framed median; on Snowflake compute it via a self-join instead)
        median(headcount) over w_trailing       as headcount_trailing_median,
        median(gross_churn_pct) over w_trailing as churn_trailing_median
    from converted
    window w_trailing as (
        partition by company_id order by period_month
        rows between 12 preceding and 1 preceding
    )
),

flagged as (
    select
        *,
        -- Thresholds are placeholders until the business sets them (dbt_project.yml vars)
        coalesce(headcount > {{ var('outlier_multiple') }} * headcount_trailing_median
              or headcount < headcount_trailing_median / {{ var('outlier_multiple') }}, false)
            as is_headcount_outlier,
        -- Task 1, issue 6: outside the business range, or a big move against the
        -- company's own history. Zero churn is a genuine month, never an outlier.
        coalesce(gross_churn_pct <> 0 and (
                   gross_churn_pct not between {{ var('churn_pct_min') }} and {{ var('churn_pct_max') }}
                or gross_churn_pct > {{ var('outlier_multiple') }} * churn_trailing_median
                or gross_churn_pct < churn_trailing_median / {{ var('outlier_multiple') }}), false)
            as is_churn_value_outlier
    from with_history
)

select
    * exclude (dq_flags),
    list_filter(
        list_concat(dq_flags, [
            case when fx_rate is null then 'fx_rate_missing' end,
            case when is_fx_rate_overridden then 'fx_rate_overridden' end,
            case when is_headcount_outlier then 'headcount_outlier' end,
            case when is_churn_value_outlier then 'churn_value_outlier' end
        ]),
        lambda f: f is not null
    ) as dq_flags
from flagged
