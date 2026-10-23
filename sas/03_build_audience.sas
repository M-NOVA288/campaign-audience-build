/*============================================================================
  03_build_audience.sas
  &campaign_id Holiday Win-Back: selection, suppression waterfall, de-dupe,
  channel assignment, segmentation and test/control split.

  Every customer is kept in AUD_STAGE and tagged with the FIRST rule that
  removed them (DROP_REASON). The waterfall is built from that one column,
  so it always reconciles back to the starting universe.
============================================================================*/

/*--------------------------------------------------------------------------
  Step 0: one row per customer with everything the rules need
--------------------------------------------------------------------------*/
proc sql;
    create table work.aud_base as
    select c.customer_id, c.first_name, c.last_name, c.email, c.phone,
           c.address, c.city, c.state, c.zip, c.loyalty_tier, c.account_status,
           m.last_purchase_date, m.recency_days,
           coalesce(m.frequency_24m, 0)    as frequency_24m,
           coalesce(m.net_sales_24m, 0)    as net_sales_24m format=dollar12.2,
           coalesce(p.email_opt_in, 0)     as email_opt_in,
           coalesce(p.sms_opt_in, 0)       as sms_opt_in,
           coalesce(p.dm_opt_in, 0)        as dm_opt_in,
           coalesce(p.do_not_contact, 0)   as do_not_contact,
           (lh.customer_id is not null)    as legal_hold,
           (se.customer_id is not null)    as employee,
           (rc.customer_id is not null)    as recent_contact,
           (bo.email       is not null)    as email_bounced
    from camp.customers c
         left join camp.cust_metrics        m  on m.customer_id = c.customer_id
         left join camp.contact_preferences p  on p.customer_id = c.customer_id
         left join (select distinct customer_id from camp.suppress_legal_hold) lh
                on lh.customer_id = c.customer_id
         left join (select distinct customer_id from camp.suppress_employees)  se
                on se.customer_id = c.customer_id
         left join (select distinct customer_id from camp.contact_history
                     where contact_date >= &as_of - &fatigue_days
                       and contact_date <  &as_of)                             rc
                on rc.customer_id = c.customer_id
         left join (select distinct email from camp.suppress_email_bounces)    bo
                on bo.email = lowcase(strip(c.email))
    order by c.customer_id;
quit;

/*--------------------------------------------------------------------------
  Steps 1-7: contactability flags, eligibility and suppressions
--------------------------------------------------------------------------*/
data camp.aud_stage;
    set work.aud_base;
    length drop_reason $30 dedupe_key $200 channel $3;

    email = lowcase(strip(email));

    valid_email   = prxmatch('/^[^@\s]+@[^@\s]+\.[^@\s]+$/', strip(email)) > 0;
    valid_address = not missing(address) and prxmatch('/^\d{5}$/', strip(zip)) > 0;
    valid_phone   = prxmatch('/^\d{10}$/', strip(phone)) > 0;

    if account_status ne 'ACTIVE'                         then drop_reason = '01_ACCOUNT_NOT_ACTIVE';
    else if missing(recency_days)                         then drop_reason = '02_NO_PURCHASE_HISTORY';
    else if not (&min_recency <= recency_days <= &max_recency)
                                                          then drop_reason = '03_OUTSIDE_RECENCY_WINDOW';
    else if legal_hold                                    then drop_reason = '04_LEGAL_HOLD';
    else if employee                                      then drop_reason = '05_EMPLOYEE';
    else if do_not_contact                                then drop_reason = '06_DO_NOT_CONTACT';
    else if recent_contact                                then drop_reason = '07_CONTACT_FATIGUE';

    /* match key for de-duplication */
    if valid_email        then dedupe_key = cats('E|', email);
    else if valid_address then dedupe_key = upcase(catx('|', 'A', first_name, last_name,
                                                        strip(address), zip));
    else                       dedupe_key = cats('ID|', customer_id);
run;

/*--------------------------------------------------------------------------
  Step 8: de-duplicate survivors - keep highest value, then most recent
--------------------------------------------------------------------------*/
proc sort data=camp.aud_stage(where=(missing(drop_reason))
                              keep=customer_id dedupe_key net_sales_24m
                                   recency_days drop_reason)
          out=work.survivors;
    by dedupe_key descending net_sales_24m recency_days customer_id;
run;

data work.dupes(keep=customer_id);
    set work.survivors;
    by dedupe_key;
    if not first.dedupe_key;
run;

proc sql;
    update camp.aud_stage
       set drop_reason = '08_DUPLICATE'
     where customer_id in (select customer_id from work.dupes);
quit;

/*--------------------------------------------------------------------------
  Step 9: channel assignment by priority  EMAIL > DIRECT MAIL > SMS
--------------------------------------------------------------------------*/
data camp.aud_stage;
    set camp.aud_stage;
    if missing(drop_reason) then do;
        if valid_email and email_opt_in and not email_bounced then channel = 'EM';
        else if valid_address and dm_opt_in                   then channel = 'DM';
        else if valid_phone and sms_opt_in                    then channel = 'SMS';
        else drop_reason = '09_NO_CONTACTABLE_CHANNEL';
    end;
run;

/*--------------------------------------------------------------------------
  Final audience: segment, holdout, cell and offer codes
    S1 Lapsed high value   181-365 days, net sales >= threshold or GOLD/PLATINUM
    S2 Lapsed standard     181-365 days
    S3 At-risk high value   91-180 days, net sales >= threshold or GOLD/PLATINUM
    S4 At-risk standard     91-180 days
  The holdout is a deterministic hash of customer_id: reruns give the same split.
--------------------------------------------------------------------------*/
data camp.&campaign_id._audience;
    length campaign_id $8 segment $2 segment_name $20 channel $3
           test_control $1 cell_code $24 offer_code $20;
    set camp.aud_stage(where=(missing(drop_reason)));

    campaign_id = "&campaign_id";
    high_value  = (net_sales_24m >= &hv_threshold) or loyalty_tier in ('GOLD', 'PLATINUM');

    if recency_days >= 181 then segment = ifc(high_value, 'S1', 'S2');
    else                        segment = ifc(high_value, 'S3', 'S4');

    select (segment);
        when ('S1') do; segment_name = 'Lapsed High Value';  offer_code = "&campaign_id.-25OFF100"; end;
        when ('S2') do; segment_name = 'Lapsed Standard';    offer_code = "&campaign_id.-20PCT";    end;
        when ('S3') do; segment_name = 'At-Risk High Value'; offer_code = "&campaign_id.-15OFF75";  end;
        otherwise   do; segment_name = 'At-Risk Standard';   offer_code = "&campaign_id.-10PCT";    end;
    end;

    test_control = ifc(mod(customer_id * 7919, 100) < &holdout_pct, 'C', 'T');
    if test_control = 'C' then offer_code = ' ';
    cell_code = catx('-', campaign_id, segment, channel, test_control);

    keep campaign_id customer_id segment segment_name channel test_control cell_code
         offer_code first_name last_name email phone address city state zip
         loyalty_tier last_purchase_date recency_days frequency_24m net_sales_24m;
run;

/*--------------------------------------------------------------------------
  Suppression waterfall
--------------------------------------------------------------------------*/
data work.wf_steps;
    length step $30 description $60;
    infile datalines dlm='|' truncover;
    input step $ description $;
datalines;
01_ACCOUNT_NOT_ACTIVE|Closed or deceased account
02_NO_PURCHASE_HISTORY|No purchase on file
03_OUTSIDE_RECENCY_WINDOW|Last purchase outside 91-365 day window
04_LEGAL_HOLD|Legal / fraud / bankruptcy hold
05_EMPLOYEE|Employee file
06_DO_NOT_CONTACT|Global do-not-contact flag
07_CONTACT_FATIGUE|Contacted in last 14 days
08_DUPLICATE|Duplicate person (email or name+address)
09_NO_CONTACTABLE_CHANNEL|No opted-in, valid channel
;
run;

proc sql noprint;
    create table work.wf_drops as
    select s.step, s.description, count(a.customer_id) as removed
    from work.wf_steps s
         left join camp.aud_stage a on a.drop_reason = s.step
    group by s.step, s.description
    order by s.step;

    select count(*) into :start_n trimmed from camp.aud_stage;
quit;

data camp.&campaign_id._waterfall;
    length step $30 description $60 removed remaining 8;
    retain remaining &start_n;
    if _n_ = 1 then do;
        step = '00_STARTING_UNIVERSE'; description = 'All customer records';
        removed = 0;
        output;
    end;
    set work.wf_drops;
    remaining = remaining - removed;
    output;
    format removed remaining comma10.;
run;

proc print data=camp.&campaign_id._waterfall noobs label;
    title "&campaign_id suppression waterfall (as of &as_of_date)";
run;
title;
