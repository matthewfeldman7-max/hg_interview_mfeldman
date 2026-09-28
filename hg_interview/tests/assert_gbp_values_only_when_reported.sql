-- BLOCK: "no guessed numbers". GBP values may only exist for company-months
-- that are fully reported and convertible, and must exist for all of them.

select company_id, period_month, reporting_status, revenue_gbp, arr_gbp
from {{ ref('fct_company_kpi_monthly') }}
where (reporting_status <> 'reported' and (revenue_gbp is not null or arr_gbp is not null))
   or (reporting_status = 'reported' and (revenue_gbp is null or arr_gbp is null))
