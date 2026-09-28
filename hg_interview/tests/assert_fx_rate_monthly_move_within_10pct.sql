-- BLOCK (Task 1, issue 1): an FX rate that moves more than 10% in a month is
-- almost certainly wrong (inverted, mis-keyed) and would silently corrupt the
-- GBP figures of every company in that currency. Fix at source or add a
-- reviewed row to seeds/reference/fx_rate_overrides.csv.

select
    rate_month,
    from_ccy,
    rate,
    prev_rate,
    rate / prev_rate - 1 as pct_change
from (
    select
        *,
        lag(rate) over (partition by from_ccy order by rate_month) as prev_rate
    from {{ ref('stg_portfolio__fx_rates') }}
)
where abs(rate / prev_rate - 1) > 0.10
