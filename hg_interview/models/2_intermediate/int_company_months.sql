-- Grain: one row per company_id x expected reporting month (the spine)
--
-- A company is expected every month from the later of its investment month
-- and the start of history, to the earlier of its exit month and the last
-- completed month. Exited companies therefore have no rows after exit.
-- Months with no submission still get a row, which is what lets the mart
-- say "not yet reported" / "missing" instead of showing nothing.

with params as (
    select
        cast('{{ var("as_of_date") }}' as date)    as as_of_date,
        cast('{{ var("history_start") }}' as date) as history_start,
        -- last completed month as at the extract date
        cast(date_trunc('month', cast('{{ var("as_of_date") }}' as date))
             - interval '1 month' as date)          as last_complete_month
),

-- DuckDB month series; on Snowflake use dbt_utils.date_spine
months as (
    select cast(m as date) as period_month
    from params, range(params.history_start,
                       params.last_complete_month + interval '1 month',
                       interval '1 month') as t(m)
),

bounds as (
    select
        c.company_id,
        greatest(c.investment_month, p.history_start)                   as first_month,
        least(coalesce(c.exit_month, p.last_complete_month), p.last_complete_month) as last_month,
        c.exit_month,
        p.as_of_date
    from {{ ref('stg_portfolio__companies') }} c
    cross join params p
)

select
    b.company_id,
    m.period_month,
    last_day(m.period_month)                                    as period_end_date,
    last_day(m.period_month) + {{ var("submission_due_days") }} as submission_due_date,
    coalesce(m.period_month = b.exit_month, false)              as is_exit_month,
    b.as_of_date
from bounds b
join months m
    on m.period_month between b.first_month and b.last_month
