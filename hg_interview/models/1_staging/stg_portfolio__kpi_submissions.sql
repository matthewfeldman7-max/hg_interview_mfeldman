-- Grain: one row per company_id x period_month x source_extract_date
--
-- Row-level cleansing only: every fix here is either mechanical (types,
-- case, derived dates) or an explicit, reviewed seed entry. Each fix sets a
-- boolean and a matching entry in dq_flags so the dashboard can show it.
-- Nothing is dropped: an unresolvable company code leaves company_id null,
-- and the not_null / relationships tests on this model block the build.

with source as (
    select * from {{ ref('kpi_monthly') }}
),

-- Task 1, issue 4: collapse exact duplicates.
-- Rows that share the key but differ in values survive as separate rows
-- and fail the uniqueness test (the "conflicting duplicate" block).
deduplicated as (
    select distinct
        company_code        as raw_company_code,
        period_month        as raw_period_month,
        period_end_date     as raw_period_end_date,
        currency            as raw_currency,
        revenue,
        arr,
        gross_churn_pct,
        headcount,
        source_extract_date
    from source
),

normalised as (
    select
        *,
        upper(trim(raw_company_code))                     as company_code,
        cast(raw_period_month || '-01' as date)           as period_month,
        -- Task 1, issue 10: period_month is authoritative, end date derived
        last_day(cast(raw_period_month || '-01' as date)) as period_end_date,
        nullif(upper(trim(raw_currency)), '')             as currency_clean
    from deduplicated
),

-- Task 1, issues 2 & 3 (codes) and 8 (currency symbols): resolve through
-- the company master and the reviewed alias seeds
resolved as (
    select
        n.*,
        coalesce(a.company_id, c.company_id)                 as company_id,
        a.company_id is not null                             as is_code_aliased,
        a.company_id is null and c.company_id is not null
            and n.company_code <> n.raw_company_code         as is_code_normalised,
        coalesce(ca.currency, n.currency_clean)              as currency,
        ca.currency is not null                              as is_currency_mapped
    from normalised n
    left join {{ ref('company_code_aliases') }} a
        on  a.raw_code = n.company_code
        and n.raw_period_month between coalesce(a.valid_from, '0000-00')
                                   and coalesce(a.valid_to, '9999-99')
    left join {{ ref('stg_portfolio__companies') }} c
        on c.company_code = n.company_code
    left join {{ ref('currency_aliases') }} ca
        on ca.raw_currency = n.currency_clean
),

-- Task 1, issues 6 & 7: corrections confirmed with the company (e.g. BRV
-- churn, NIM headcount). One seed row per company, month and metric holding
-- the corrected value. Nothing is corrected until it has been confirmed.
overrides as (
    select
        company_id,
        period_month,
        max(case when metric = 'revenue'         then corrected_value end) as revenue_override,
        max(case when metric = 'arr'             then corrected_value end) as arr_override,
        max(case when metric = 'gross_churn_pct' then corrected_value end) as gross_churn_pct_override,
        max(case when metric = 'headcount'       then corrected_value end) as headcount_override
    from {{ ref('kpi_overrides') }}
    group by all
),

corrected as (
    select
        r.*,
        o.revenue_override         is not null                  as is_revenue_corrected,
        o.arr_override             is not null                  as is_arr_corrected,
        o.gross_churn_pct_override is not null                  as is_churn_value_corrected,
        o.headcount_override       is not null                  as is_headcount_corrected,
        coalesce(o.revenue_override, r.revenue)                 as revenue_corrected,
        coalesce(o.arr_override, r.arr)                         as arr_corrected,
        coalesce(o.gross_churn_pct_override, r.gross_churn_pct) as gross_churn_pct_corrected,
        coalesce(o.headcount_override, r.headcount)             as headcount_corrected,
        -- one-day slip (end date = 1st of next month) is safe to derive
        r.raw_period_end_date = r.period_end_date + 1  as is_period_end_derived,
        -- anything else is ambiguous: hold for query rather than guess
        r.raw_period_end_date not in (r.period_end_date, r.period_end_date + 1)
            or r.period_end_date > r.source_extract_date as is_period_under_query
    from resolved r
    left join overrides o
        on  o.company_id   = r.company_id
        and o.period_month = r.raw_period_month
)

select
    company_id,
    company_code,
    raw_company_code,
    period_month,
    period_end_date,
    raw_period_end_date,
    currency,
    raw_currency,
    cast(revenue_corrected as bigint)            as revenue,
    cast(arr_corrected as bigint)                as arr,
    cast(gross_churn_pct_corrected as double)    as gross_churn_pct,
    cast(headcount_corrected as integer)         as headcount,
    cast(revenue as bigint)                      as raw_revenue,
    cast(arr as bigint)                          as raw_arr,
    cast(gross_churn_pct as double)              as raw_gross_churn_pct,
    cast(headcount as integer)                   as raw_headcount,
    cast(source_extract_date as date)            as source_extract_date,
    is_code_aliased,
    is_code_normalised,
    is_currency_mapped,
    is_revenue_corrected,
    is_arr_corrected,
    is_churn_value_corrected,
    is_headcount_corrected,
    is_period_end_derived,
    is_period_under_query,
    -- DuckDB list; on Snowflake: array_construct_compact(...)
    list_filter([
        case when is_code_aliased          then 'code_aliased' end,
        case when is_code_normalised       then 'code_normalised' end,
        case when is_currency_mapped       then 'currency_mapped' end,
        case when is_revenue_corrected     then 'revenue_corrected' end,
        case when is_arr_corrected         then 'arr_corrected' end,
        case when is_churn_value_corrected then 'churn_value_corrected' end,
        case when is_headcount_corrected   then 'headcount_corrected' end,
        case when is_period_end_derived    then 'period_end_derived' end,
        case when is_period_under_query    then 'period_under_query' end
    ], lambda f: f is not null)                  as dq_flags
from corrected
