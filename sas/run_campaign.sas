/*============================================================================
  run_campaign.sas  -  batch driver

  Called by unix/run_campaign.sh with:
      cd $PROJECT_ROOT
      sas -sysin sas/run_campaign.sas -sysparm "HOL26|2026-11-01" \
          -log logs/HOL26_<timestamp>.log -print logs/HOL26_<timestamp>.lst

  ERRORABEND makes any ERROR stop the job with a non-zero return code, which
  the shell script checks before moving on.
============================================================================*/

options errorabend;

/* project root from the environment; falls back to the current directory */
%let _root = %sysget(PROJECT_ROOT);
%include "%sysfunc(coalescec(&_root, .))/sas/00_config.sas";
%include "&root/sas/01_import_raw.sas";
%include "&root/sas/02_customer_metrics.sas";
%include "&root/sas/03_build_audience.sas";
%include "&root/sas/04_qa_checks.sas";        /* stops here if QA fails */
%include "&root/sas/05_reports_export.sas";

%put NOTE: &campaign_id build completed successfully.;
