{{ config(severity='warn') }}

-- WARN (Task 1, issues 2 & 3): raw codes that are not exactly three ASCII
-- capital letters (lower case, look-alike characters, wrong length).
-- An early warning: the load only blocks if the code also fails to resolve
-- to a company_id (not_null / relationships tests on staging).

select
    company_code,
    hex(company_code) as code_hex,
    period_month
from {{ ref('kpi_monthly') }}
where company_code is null
   or not regexp_full_match(company_code, '[A-Z]{3}')
