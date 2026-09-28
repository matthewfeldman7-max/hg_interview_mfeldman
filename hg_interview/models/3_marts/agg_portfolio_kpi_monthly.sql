-- Grain: one row per period_month x hierarchy node (the whole portfolio, and each fund)
--
-- Headline figures, defined once here rather than in each Sigma workbook:
--   * churn is ARR-weighted, not a simple average
--   * revenue per head is total revenue / total headcount, not an average of ratios
--   * growth is like-for-like: only companies with a value in both periods,
--     so a missing report (VEL) or an exit (PEL) does not look like a fall in ARR

with fct_kpi_monthly as (
    select * from {{ ref('fct_company_kpi_monthly') }}
)

select
    period_month,
    case when grouping(fund) = 1 then 'portfolio' else 'fund' end as node_type,
    coalesce(fund, 'Portfolio')                                    as node_name,

    sum(case when reporting_status <> 'not_expected' then 1 else 0 end) as companies_expected,
    sum(case when reporting_status = 'reported' then 1 else 0 end)  as companies_reported,
    -- warnings: flagged values are included in the totals below, so say so
    sum(case when is_headcount_outlier then 1 else 0 end)           as companies_headcount_flagged,
    sum(case when is_churn_value_outlier then 1 else 0 end)         as companies_churn_flagged,

    sum(arr_gbp)                                                    as arr_gbp,
    sum(revenue_gbp)                                                as revenue_gbp,
    sum(case when is_headcount_included then headcount end)         as headcount,

    sum(gross_churn_pct * arr_gbp)
        / nullif(sum(case when gross_churn_pct is not null then arr_gbp end), 0)
                                                                    as gross_churn_pct_arr_weighted,

    sum(case when is_headcount_included then revenue_gbp end)
        / nullif(sum(case when is_headcount_included then headcount end), 0)
                                                                    as revenue_per_head_gbp,

    sum(case when arr_gbp_prior_month is not null then arr_gbp end)
        / nullif(sum(case when arr_gbp is not null then arr_gbp_prior_month end), 0) - 1
                                                                    as arr_growth_mom_lfl_pct,
    sum(case when arr_gbp_prior_year is not null then arr_gbp end)
        / nullif(sum(case when arr_gbp is not null then arr_gbp_prior_year end), 0) - 1
                                                                    as arr_growth_yoy_lfl_pct,
    sum(case when revenue_gbp_prior_month is not null then revenue_gbp end)
        / nullif(sum(case when revenue_gbp is not null then revenue_gbp_prior_month end), 0) - 1
                                                                    as revenue_growth_mom_lfl_pct,
    sum(case when revenue_gbp_prior_year is not null then revenue_gbp end)
        / nullif(sum(case when revenue_gbp is not null then revenue_gbp_prior_year end), 0) - 1
                                                                    as revenue_growth_yoy_lfl_pct
from fct_kpi_monthly
group by grouping sets ((period_month), (period_month, fund))
