/*============================================================================
  00_config.sas
  Run parameters, libraries and options for the campaign build.

  Parameters arrive from the Unix runner through -sysparm as
      CAMPAIGN_ID|AS_OF_DATE        e.g.  HOL26|2026-11-01
  and the project root through the PROJECT_ROOT environment variable.
  Defaults let the programs also run interactively in SAS Studio / EG.
============================================================================*/

%macro init_params;
    %global root campaign_id as_of_date as_of run_ymd
            min_recency max_recency fatigue_days hv_threshold holdout_pct;

    %let root = %sysget(PROJECT_ROOT);
    %if %length(&root) = 0 %then %let root = .;

    %let campaign_id = %scan(%superq(sysparm), 1, |);
    %let as_of_date  = %scan(%superq(sysparm), 2, |);
    %if %length(&campaign_id) = 0 %then %let campaign_id = HOL26;
    %if %length(&as_of_date)  = 0 %then %let as_of_date  = 2026-11-01;

    /* numeric SAS date for comparisons, compact form for file names */
    %let as_of   = %sysfunc(inputn(&as_of_date, yymmdd10.));
    %let run_ymd = %sysfunc(putn(&as_of, yymmddn8.));

    /* selection rules - same values as run_params in the SQL version */
    %let min_recency  = 91;    /* days since last purchase, lower bound      */
    %let max_recency  = 365;   /* days since last purchase, upper bound      */
    %let fatigue_days = 14;    /* suppress anyone contacted in last N days   */
    %let hv_threshold = 500;   /* 24-month net sales for "high value"        */
    %let holdout_pct  = 10;    /* control group size, percent                */
%mend init_params;
%init_params;

options nocenter ls=180 ps=max compress=yes dlcreatedir mprint nosymbolgen;

libname camp "&root/sasdata";          /* working + final campaign datasets */

%put NOTE: ==========================================================;
%put NOTE: Campaign      = &campaign_id;
%put NOTE: As-of date    = &as_of_date (SAS date &as_of);
%put NOTE: Recency       = &min_recency - &max_recency days;
%put NOTE: Fatigue       = &fatigue_days days;
%put NOTE: High value    = &hv_threshold net sales (24m);
%put NOTE: Holdout       = &holdout_pct pct;
%put NOTE: Project root  = &root;
%put NOTE: ==========================================================;
