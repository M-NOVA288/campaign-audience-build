/*============================================================================
  04_qa_checks.sas
  Reusable QA macros and the &campaign_id release checks.
  %qa_gate stops the batch job with a non-zero return code if anything
  fails, so the Unix runner never ships a file that didn't pass QA.
============================================================================*/

%macro qa_init;
    data camp.qa_results;
        length check_id $6 check_name $80 expected $30 actual $30 status $4;
        stop;
    run;
%mend qa_init;

/* Log one result. If STATUS is not given, PASS when ACTUAL = EXPECTED. */
%macro qa_log(id=, name=, expected=0, actual=, status=);
    %if %length(&status) = 0 %then %do;
        %if %superq(actual) = %superq(expected) %then %let status = PASS;
        %else %let status = FAIL;
    %end;
    proc sql;
        insert into camp.qa_results
        values ("&id", "&name", "&expected", "&actual", "&status");
    quit;
    %if &status = FAIL %then %put WARNING: QA &id FAILED - &name (expected &expected, got &actual);
    %else %put NOTE: QA &id passed - &name;
%mend qa_log;

/* Count rows matching a condition that should never happen. */
%macro qa_zero(id=, name=, from=, where=);
    %local n;
    proc sql noprint;
        select count(*) into :n trimmed from &from where &where;
    quit;
    %qa_log(id=&id, name=&name, expected=0, actual=&n);
%mend qa_zero;

/* Stop the job if any check failed. */
%macro qa_gate;
    %local fails;
    proc sql noprint;
        select count(*) into :fails trimmed from camp.qa_results where status = 'FAIL';
    quit;
    proc print data=camp.qa_results noobs;
        title "&campaign_id QA results";
    run;
    title;
    %if &fails > 0 %then %do;
        %put ERROR: &fails QA check(s) failed. Files will NOT be released.;
        %abort abend 3;
    %end;
    %else %put NOTE: All QA checks passed. Audience cleared for release.;
%mend qa_gate;

/* Checks are wrapped in a macro so %if logic works on any SAS 9.4 release */
%macro run_release_qa;
    %local aud n pmin pmax aud_n wf_n st;
    %let aud = camp.&campaign_id._audience;

%qa_init;

/* QA01 one row per customer */
proc sql noprint;
    select count(*) - count(distinct customer_id) into :n trimmed from &aud;
quit;
%qa_log(id=QA01, name=No duplicate customer_id in audience, actual=&n);

/* QA02 no duplicate emails to the ESP */
proc sql noprint;
    select count(*) - count(distinct email) into :n trimmed from &aud where channel = 'EM';
quit;
%qa_log(id=QA02, name=No duplicate email addresses in email channel, actual=&n);

/* QA03 suppression leakage */
%qa_zero(id=QA03, name=No suppressed records in audience (legal/employee/DNC/bounce),
         from=&aud a,
         where=%str(a.customer_id in (select customer_id from camp.suppress_legal_hold)
                 or a.customer_id in (select customer_id from camp.suppress_employees)
                 or a.customer_id in (select customer_id from camp.contact_preferences
                                       where do_not_contact = 1)
                 or (a.channel = 'EM' and a.email in (select email from camp.suppress_email_bounces))));

/* QA04 opt-in compliance */
%qa_zero(id=QA04, name=Every record opted in to its assigned channel,
         from=%str(&aud a inner join camp.contact_preferences p on p.customer_id = a.customer_id),
         where=%str((a.channel = 'EM'  and p.email_opt_in = 0)
                 or (a.channel = 'DM'  and p.dm_opt_in    = 0)
                 or (a.channel = 'SMS' and p.sms_opt_in   = 0)));

/* QA05 usable contact data */
%qa_zero(id=QA05, name=Valid email / address / phone for assigned channel,
         from=&aud,
         where=%str((channel = 'EM'  and prxmatch('/^[^@\s]+@[^@\s]+\.[^@\s]+$/', strip(email)) = 0)
                 or (channel = 'DM'  and (missing(address) or prxmatch('/^\d{5}$/', strip(zip)) = 0))
                 or (channel = 'SMS' and prxmatch('/^\d{10}$/', strip(phone)) = 0)));

/* QA06 selection criteria */
%qa_zero(id=QA06, name=All records inside recency window,
         from=&aud,
         where=%str(not (&min_recency <= recency_days <= &max_recency)));

/* QA07 campaign codes */
%qa_zero(id=QA07, name=Cell code populated and offer code on all test records,
         from=&aud,
         where=%str(missing(cell_code)
                 or (test_control = 'T' and missing(offer_code))
                 or (test_control = 'C' and not missing(offer_code))));

/* QA08 holdout within +/- 1.5 points in every segment */
proc sql noprint;
    select min(pct), max(pct) into :pmin trimmed, :pmax trimmed
    from (select segment, round(100 * mean(test_control = 'C'), .1) as pct
          from &aud group by segment);
quit;
%if %sysevalf(&pmin >= &holdout_pct - 1.5 and &pmax <= &holdout_pct + 1.5)
    %then %let st = PASS;
    %else %let st = FAIL;
%qa_log(id=QA08, name=Control group within tolerance in every segment,
        expected=&holdout_pct.pct +/-1.5, actual=&pmin.-&pmax.pct, status=&st);

/* QA09 waterfall reconciles */
proc sql noprint;
    select count(*) into :aud_n trimmed from &aud;
    select remaining into :wf_n trimmed from camp.&campaign_id._waterfall
     where step = '09_NO_CONTACTABLE_CHANNEL';
quit;
%qa_log(id=QA09, name=Waterfall reconciles to final audience count,
        expected=&aud_n, actual=&wf_n);

/* QA10 size inside the range agreed with Marketing */
%if 6000 <= &aud_n and &aud_n <= 12000 %then %let st = PASS;
%else %let st = FAIL;
%qa_log(id=QA10, name=Audience size within expected range,
        expected=%str(6,000-12,000), actual=&aud_n, status=&st);

%qa_gate;
%mend run_release_qa;

%run_release_qa;
