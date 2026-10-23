/*============================================================================
  01_import_raw.sas
  Read the raw CSV extracts with explicit lengths and informats (rather than
  PROC IMPORT guessing types), so IDs, ZIPs and phones stay character where
  they should and dates come in as real SAS dates.
============================================================================*/

data camp.customers;
    infile "&root/data/customers.csv" dsd firstobs=2 truncover lrecl=2000;
    length customer_id 8 first_name last_name $40 email $120 phone $15
           address $120 city $60 state $2 zip $10 birth_date enroll_date 8
           loyalty_tier account_status $10;
    input customer_id first_name $ last_name $ email $ phone $ address $
          city $ state $ zip $ birth_date :yymmdd10. enroll_date :yymmdd10.
          loyalty_tier $ account_status $;
    format birth_date enroll_date yymmdd10.;
run;

data camp.contact_preferences;
    infile "&root/data/contact_preferences.csv" dsd firstobs=2 truncover;
    input customer_id email_opt_in sms_opt_in dm_opt_in do_not_contact
          updated_date :yymmdd10.;
    format updated_date yymmdd10.;
run;

data camp.transactions;
    infile "&root/data/transactions.csv" dsd firstobs=2 truncover;
    length txn_id customer_id txn_date 8 channel $10 amount 8 category $20;
    input txn_id customer_id txn_date :yymmdd10. channel $ amount category $;
    format txn_date yymmdd10. amount dollar12.2;
run;

data camp.contact_history;
    infile "&root/data/contact_history.csv" dsd firstobs=2 truncover;
    length customer_id 8 campaign_id $20 channel $10;
    input customer_id campaign_id $ channel $ contact_date :yymmdd10.
          responded response_date :yymmdd10.;
    format contact_date response_date yymmdd10.;
run;

data camp.suppress_email_bounces;
    infile "&root/data/suppress_email_bounces.csv" dsd firstobs=2 truncover;
    length email $120;
    input email $;
    email = lowcase(strip(email));
run;

data camp.suppress_legal_hold;
    infile "&root/data/suppress_legal_hold.csv" dsd firstobs=2 truncover;
    length reason $20;
    input customer_id reason $;
run;

data camp.suppress_employees;
    infile "&root/data/suppress_employees.csv" dsd firstobs=2 truncover;
    input customer_id;
run;

/* row counts to the log so the Unix runner can compare against wc -l */
proc sql;
    title "Raw table row counts";
    select memname, nobs format=comma12.
    from dictionary.tables
    where libname = 'CAMP'
      and memname in ('CUSTOMERS','CONTACT_PREFERENCES','TRANSACTIONS',
                      'CONTACT_HISTORY','SUPPRESS_EMAIL_BOUNCES',
                      'SUPPRESS_LEGAL_HOLD','SUPPRESS_EMPLOYEES')
    order by memname;
quit;
title;
