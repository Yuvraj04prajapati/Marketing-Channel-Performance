# Marketing Channel Performance — Robinhood (AWS Athena)

Which paid channels were worth the money over the first half of 2025, and where should the next six months of budget go? This project answers that using serverless SQL: the raw CSVs live in Amazon S3 and every number is computed in Amazon Athena.

**Stack:** Amazon S3 · Amazon Athena (Trino SQL) · AWS Glue Data Catalog

## The data

Two files, January–June 2025:

- `ad_spend.csv` — one row per paid campaign per day (1,046 rows): impressions, clicks, spend.
- `signups.csv` — one row per new free account (18,840 rows): the channel and campaign credited, whether and when they upgraded to Robinhood Gold, and their first-90-day revenue.

Two data-quality issues were handled before any totals were calculated:

1. The two files spell channels differently (`Paid Search` vs `paid_search`), so a shared `channel_key` is built from each before joining.
2. `ad_spend` contained 7 exact duplicate rows, which are removed with `SELECT DISTINCT` (1,046 → 1,039). Left in, they overstate spend by about $920.

## How it was built

The S3 files are described as external tables, then cleaned once in two views so every analysis query reads tidy, correctly typed data:

- `ad_clean` — de-duplicates, casts text to real number/date types, and builds `channel_key`.
- `signups_clean` — casts types and turns blank cells into real NULLs, so "never paid" and "free channel" behave correctly.

All SQL is in [`sql/robinhood_analysis.sql`](sql/robinhood_analysis.sql), in run order.

## Channel and campaign metrics

| Campaign | Channel | Spend | Signups | Paying | Rev (90d) | $/Signup | $/Paying | ROAS |
|---|---|--:|--:|--:|--:|--:|--:|--:|
| brand_search | paid_search | $10,197 | 2,177 | 465 | $19,470 | $4.68 | $21.93 | **1.91** |
| retargeting | paid_social | $12,987 | 2,465 | 418 | $17,411 | $5.27 | $31.07 | **1.34** |
| generic_search | paid_search | $35,939 | 2,008 | 432 | $16,941 | $17.90 | $83.19 | 0.47 |
| finance_blogs | affiliate | $15,392 | 864 | 162 | $6,316 | $17.82 | $95.02 | 0.41 |
| prospecting_video | paid_social | $33,916 | 6,484 | 213 | $8,765 | $5.23 | $159.23 | 0.26 |
| display_network | display | $16,455 | 268 | 8 | $540 | $61.40 | $2,056.83 | 0.03 |

Signup → paying conversion by channel (free channels included as a benchmark):

| Channel | Type | Signups | Paying | Convert |
|---|---|--:|--:|--:|
| paid_search | paid | 4,185 | 897 | 21.4% |
| referral | free | 1,063 | 212 | 19.9% |
| affiliate | paid | 864 | 162 | 18.8% |
| organic | free | 3,511 | 345 | 9.8% |
| paid_social | paid | 8,949 | 631 | 7.1% |
| display | paid | 268 | 8 | 3.0% |

## Which metric decides the ranking

The cheapest channel per signup is not the cheapest per paying customer, and that gap is the whole point. `prospecting_video` buys signups cheaply ($5.23, the second-lowest) and brings the most signups of any campaign (6,484), so judged on cost per signup it looks like a star. But only 3% of those signups ever pay, so per actual customer it costs $159, near the bottom. Robinhood earns from Gold subscribers, not free accounts, so the channels are ranked on **cost per paying customer and ROAS**, the metrics closest to revenue. Cost per signup is reported only to show the trap.

Referral is also worth noting: it is free and converts at 19.9%, better than every paid channel except paid_search. Paid traffic is not automatically better than organic.

## Recommendation for the next six months

Hold total spend roughly flat (about $125k) and shift it toward what produces paying customers.

| Campaign | Was | Propose | Move |
|---|--:|--:|:--|
| retargeting | $13.0k | $24k | scale up — best scalable ROAS (1.34) |
| brand_search | $10.2k | $13k | increase — best on every metric, capture all brand demand |
| generic_search | $35.9k | $34k | hold and tighten keywords — high intent, 22% convert |
| finance_blogs | $15.4k | $12k | trim and test — decent conversion, weak ROAS |
| prospecting_video | $33.9k | $17k | cut hard, keep some as a top-of-funnel feeder |
| display_network | $16.5k | $0 | leave off — already switched off in May, ROAS 0.03 |

## Risks in this plan

1. **Ninety days is not a lifetime.** ROAS here uses first-90-day revenue only. Annual plans and longer retention are not counted, so a channel below 1.0 may still be profitable over a customer's life. Do not declare channels unprofitable on 90-day numbers alone.
2. **Cutting prospecting may starve the funnel.** Retargeting only works if something fills the top of the funnel first. Prospecting_video's cheap signups may be feeding retargeting and brand search, which last-touch credit hides. Cut it gradually and watch retargeting volume.
3. **The winners are capacity-capped.** You cannot multiply brand_search fivefold, because only so many people search the brand. "Shift to the winner" has a ceiling.

## Reproduce it

1. Create an S3 bucket with two folders, `ad_spend/` and `signups/`, and upload one CSV into each.
2. In Athena, set a query-results location, then run the statements in `sql/robinhood_analysis.sql` in order (tables, then views, then the analysis queries).
3. Athena saves each result to S3 as CSV; the campaign-metrics output is in `results/campaign_metrics.csv`.
