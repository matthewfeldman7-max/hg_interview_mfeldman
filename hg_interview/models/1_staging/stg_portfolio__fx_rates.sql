-- Grain: one row per rate_month x from_ccy
-- Applies reviewed overrides (Task 1, issue 1) so a corrected rate is visible
-- as an override with a reason, never a silent edit of the source value.

with source as (
    select
        cast(month || '-01' as date) as rate_month,
        upper(trim(from_ccy))        as from_ccy,
        upper(trim(to_ccy))          as to_ccy,
        cast(rate as double)         as source_rate,
        rate_source
    from {{ ref('fx_rates_monthly') }}
),

overrides as (
    select
        cast(month || '-01' as date) as rate_month,
        upper(trim(from_ccy))        as from_ccy,
        rate,
        reason
    from {{ ref('fx_rate_overrides') }}
)

select
    s.rate_month,
    s.from_ccy,
    s.to_ccy,
    coalesce(o.rate, s.source_rate) as rate,
    s.source_rate,
    o.rate is not null              as is_overridden,
    o.reason                        as override_reason,
    s.rate_source
from source s
left join overrides o
    on  o.rate_month = s.rate_month
    and o.from_ccy   = s.from_ccy
