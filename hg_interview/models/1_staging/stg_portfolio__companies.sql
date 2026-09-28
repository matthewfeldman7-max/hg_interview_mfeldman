-- Grain: one row per company_id

select
    company_id,
    upper(trim(company_code))                      as company_code,
    company_name,
    fund,
    sector,
    hq_country,
    upper(trim(reporting_currency))                as reporting_currency,
    cast(investment_date as date)                  as investment_date,
    cast(date_trunc('month', investment_date) as date) as investment_month,
    status,
    cast(exit_date as date)                        as exit_date,
    cast(date_trunc('month', exit_date) as date)   as exit_month
from {{ ref('companies') }}
