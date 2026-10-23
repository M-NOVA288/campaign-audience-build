/*============================================================================
  05_reports_export.sas
  Count sign-off report for Marketing and the vendor file export.
  Runs only after %qa_gate has passed.
============================================================================*/

%let aud = camp.&campaign_id._audience;

ods listing;

/* Counts by segment x channel x test/control */
proc tabulate data=&aud format=comma10.;
    class segment segment_name channel test_control;
    var net_sales_24m;
    table segment*segment_name all='Total',
          channel*test_control*n=' ' all='Total'*n=' ';
    title "&campaign_id audience counts by cell (as of &as_of_date)";
run;

proc means data=&aud n mean maxdec=2 nonobs;
    class segment;
    var recency_days frequency_24m net_sales_24m;
    title "&campaign_id segment profile";
run;

/* Prior-campaign insight: FALL26 response rate by channel and tier */
proc sql;
    title "FALL26 response rate by channel and loyalty tier";
    select h.channel, c.loyalty_tier,
           count(*)                         as contacted format=comma8.,
           sum(h.responded)                 as responders,
           mean(h.responded)                as response_rate format=percent8.2
    from camp.contact_history h
         inner join camp.customers c on c.customer_id = h.customer_id
    where h.campaign_id = 'FALL26'
    group by h.channel, c.loyalty_tier
    order by h.channel, c.loyalty_tier;
quit;
title;

/*--------------------------------------------------------------------------
  Vendor file: same layout as sql/06_export_file.sql so the Unix runner
  can split and validate it the same way regardless of engine.
  Contact fields are blanked for channels that don't need them.
--------------------------------------------------------------------------*/
proc sort data=&aud out=work.export_sorted;
    by channel segment customer_id;
run;

data work.export_file;
    retain campaign_id cell_code customer_id segment channel test_control
           offer_code first_name last_name email phone address city state zip
           loyalty_tier;
    set work.export_sorted;
    if channel ne 'EM'  then email = ' ';
    if channel ne 'SMS' then phone = ' ';
    if channel ne 'DM'  then do;
        address = ' '; city = ' '; state = ' '; zip = ' ';
    end;
    keep campaign_id cell_code customer_id segment channel test_control
         offer_code first_name last_name email phone address city state zip
         loyalty_tier;
run;

proc export data=work.export_file
            outfile="&root/output/&campaign_id._audience_&run_ymd..csv"
            dbms=csv replace;
    putnames=yes;
run;

proc sql noprint;
    select count(*) into :export_n trimmed from work.export_file;
quit;
%put NOTE: Exported &export_n records to &root/output/&campaign_id._audience_&run_ymd..csv;
