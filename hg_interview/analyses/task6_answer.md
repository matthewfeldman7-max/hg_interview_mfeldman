I used Claude as a VS Code extension.

Task 1:
I used it to explore the data for me and flag any obvious data quality issues along with SQL I could run to investigate/confirm.
I also used it to write a v1 of the answer markdown which I then edited.

Task 2:
I used it to write up the design of the models by telling it what I wanted at each layer and providing it the data dictionary to sanity check.

Task 3:
The plan in task 2 was very thorough so I told Claude to write the models and then checked them. 

Task 4:
I wrote an overview of what I wanted then used Claude to do a more formal write-up.

Task 5:
Asked Claude to flesh out my questions

Where output was wrong and needed checking:
- **Making Assumptions about the data** Claude would add rules to the data to exclude certain values (such as the low churn) without notifying in the pipeline or on the dashbaord so I removed those rules and had Claude add tests with placeholder values that the business would then clarify
- **Period month vs period end date (Task 1, issue 10).** Claude's first version just treated `period_month` as correct. I asked what happens if they're a whole month apart (e.g. `2026-09` vs `2026-08-31`) and there was no way to tell which one was right. So now a one-day slip is auto-fixed, anything else is held as "under query", and there's a check that a period can't end after the date it was received.



What I deliberately did myself:

- **Final Pass** Read through everything to make sure there were no halluciantions
- **DBT build** I built the models with their tests in DBT to confirm there were no syntax errors, all the tests worked as expected.
- **DQ Inspection** While I had Claude highlight DQ errors I made sure to verify their existence using SQL on the data