-- BLOCK: every expected company-month must reach the mart, otherwise a
-- missing report would be invisible on the dashboard rather than flagged.

select s.company_id, s.period_month
from {{ ref('int_company_months') }} s
left join {{ ref('fct_company_kpi_monthly') }} f
    on  f.company_id   = s.company_id
    and f.period_month = s.period_month
where f.company_id is null
