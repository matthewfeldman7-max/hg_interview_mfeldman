-- BLOCK: fund ARR must add up to portfolio ARR each month, so the roll-up
-- logic can't drift from the company-level fact.

with totals as (
    select
        period_month,
        sum(case when node_type = 'fund' then arr_gbp end)      as fund_arr,
        sum(case when node_type = 'portfolio' then arr_gbp end) as portfolio_arr
    from {{ ref('agg_portfolio_kpi_monthly') }}
    group by period_month
)

select *
from totals
where abs(coalesce(fund_arr, 0) - coalesce(portfolio_arr, 0)) > 0.01
