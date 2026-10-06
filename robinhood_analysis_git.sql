-- ============================================================
-- Marketing Channel Performance (Robinhood) -- Amazon Athena
-- Run top to bottom. Replace the bucket name with your own.
-- ============================================================

-- ---------- 1. Raw tables over the S3 files ----------
-- Columns are all declared as string: the OpenCSV reader returns
-- every field as text, so numbers/dates are cast later in the views.

CREATE EXTERNAL TABLE ad_spend_raw (
    event_date string, channel string, campaign string,
    impressions string, clicks string, spend string )
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ('separatorChar'=',', 'quoteChar'='"')
STORED AS TEXTFILE
LOCATION 's3://robinhood-churn-yuv/ad_spend/'
TBLPROPERTIES ('skip.header.line.count'='1');

CREATE EXTERNAL TABLE signups_raw (
    user_id string, signup_date string, channel string, campaign string,
    subscription_start_date string, plan string, revenue_first_90_days string )
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ('separatorChar'=',', 'quoteChar'='"')
STORED AS TEXTFILE
LOCATION 's3://robinhood-churn-yuv/signups/'
TBLPROPERTIES ('skip.header.line.count'='1');

-- ---------- 2. Cleaned views ----------
-- Clean once here; every query below reads the tidy, typed version.

CREATE OR REPLACE VIEW ad_clean AS
SELECT DISTINCT                                   -- drops the 7 duplicate rows
    CAST(event_date AS date)    AS event_date,
    channel, campaign,
    CAST(impressions AS integer) AS impressions,
    CAST(clicks AS integer)      AS clicks,
    CAST(spend AS double)        AS spend,
    lower(replace(channel, ' ', '_')) AS channel_key   -- 'Paid Search' -> 'paid_search'
FROM ad_spend_raw;

CREATE OR REPLACE VIEW signups_clean AS
SELECT
    CAST(user_id AS integer)     AS user_id,
    CAST(signup_date AS date)    AS signup_date,
    channel,
    NULLIF(campaign, '')         AS campaign,          -- blank -> NULL (free channels)
    CASE WHEN subscription_start_date = '' THEN NULL
         ELSE CAST(subscription_start_date AS date) END AS subscription_start_date,
    NULLIF(plan, '')             AS plan,
    CAST(revenue_first_90_days AS double) AS revenue_first_90_days
FROM signups_raw;

-- ---------- 3. Per-campaign spend metrics (CTR, CPC) ----------
SELECT channel_key, campaign,
       SUM(spend)        AS spend,
       SUM(impressions)  AS impressions,
       SUM(clicks)       AS clicks,
       ROUND(SUM(clicks) * 1.0 / SUM(impressions), 4) AS ctr,
       ROUND(SUM(spend)  / SUM(clicks), 2)            AS cpc
FROM ad_clean
GROUP BY channel_key, campaign
ORDER BY spend DESC;

-- ---------- 4. Spend -> outcomes (cost per signup / paying, ROAS) ----------
WITH outcomes AS (
    SELECT channel AS channel_key, campaign,
           COUNT(*)                        AS signups,
           COUNT(subscription_start_date)  AS paying,   -- COUNT skips NULLs = payers
           SUM(revenue_first_90_days)      AS revenue
    FROM signups_clean
    WHERE campaign IS NOT NULL                           -- paid signups only
    GROUP BY channel, campaign ),
spend AS (
    SELECT channel_key, campaign, SUM(spend) AS spend
    FROM ad_clean
    GROUP BY channel_key, campaign )
SELECT s.channel_key, s.campaign,
       ROUND(s.spend, 2)              AS spend,
       o.signups, o.paying,
       ROUND(o.revenue, 2)            AS revenue,
       ROUND(s.spend / o.signups, 2)  AS cost_per_signup,
       ROUND(s.spend / o.paying, 2)   AS cost_per_paying,
       ROUND(o.revenue / s.spend, 2)  AS roas
FROM spend s
LEFT JOIN outcomes o
    ON s.channel_key = o.channel_key AND s.campaign = o.campaign
ORDER BY roas DESC;

-- ---------- 5. Paid vs free: conversion by channel ----------
SELECT channel,
       COUNT(*)                        AS signups,
       COUNT(subscription_start_date)  AS paying,
       ROUND(COUNT(subscription_start_date) * 100.0 / COUNT(*), 1) AS conv_pct
FROM signups_clean
GROUP BY channel
ORDER BY conv_pct DESC;

-- ---------- 6. Trend by month + the stopped campaign ----------
SELECT campaign,
       date_format(event_date, '%Y-%m') AS month,
       ROUND(SUM(spend), 0)             AS spend
FROM ad_clean
GROUP BY campaign, date_format(event_date, '%Y-%m')
ORDER BY campaign, month;
-- display_network drops to ~half of May and $0 in June: it was switched off.

-- ---------- 7. The decision metric: two orderings ----------
-- Run query 4 and change ORDER BY to compare:
--   ORDER BY cost_per_signup   -- prospecting_video looks great (2nd cheapest)
--   ORDER BY cost_per_paying   -- prospecting_video falls to 2nd worst
-- Rank on cost_per_paying / roas, the metrics closest to revenue.
