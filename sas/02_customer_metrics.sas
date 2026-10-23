/*============================================================================
  02_customer_metrics.sas
  One row per customer with RFM metrics as of &as_of_date.
    - returns (negative amounts) reduce net sales but are not a "purchase"
    - only transactions before the as-of date are used (no look-ahead)
============================================================================*/

proc sql;
    create table camp.cust_metrics as
    select customer_id,
           max(case when amount > 0 then txn_date end)
               as last_purchase_date format=yymmdd10.,
           &as_of - calculated last_purchase_date
               as recency_days,
           sum(case when amount > 0
                     and txn_date >= intnx('month', &as_of, -24, 's')
                    then 1 else 0 end)
               as frequency_24m,
           round(sum(case when txn_date >= intnx('month', &as_of, -24, 's')
                          then amount else 0 end), .01)
               as net_sales_24m format=dollar12.2,
           count(distinct channel)
               as channels_used
    from camp.transactions
    where txn_date < &as_of
    group by customer_id;
quit;

/* recency profile for the log */
proc format;
    value recband
        low -  90 = '1) Active 0-90'
         91 - 180 = '2) At-risk 91-180'
        181 - 365 = '3) Lapsed 181-365'
        366 - high = '4) Dormant 366+'
        other      = '5) No purchase';
run;

proc freq data=camp.cust_metrics;
    title "Customers by recency band as of &as_of_date";
    tables recency_days / nocum;
    format recency_days recband.;
run;
title;
