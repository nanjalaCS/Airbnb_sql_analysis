--------------------------------------------------------------------------------
-- COMPREHENSIVE ANALYSIS — NYC AIRBNB OPEN DATA 2019 (AB_NYC_2019.csv)
-- Target: Oracle SQL Developer / Oracle Database 19c+ (works on 12c+ too,
--         FETCH FIRST / WITH clauses require 12c+; comments note alternatives)
--------------------------------------------------------------------------------
-- Sections:
--   1. Table Creation (DDL)
--   2. Loading the CSV (SQL Developer Import Wizard + SQL*Loader alternative)
--   3. Data Quality Checks
--   4. Data Cleaning / Standardized View
--   5. Descriptive Statistics
--   6. Distribution & Outlier Analysis
--   7. Group Comparisons (Borough / Room Type)
--   8. Correlation Analysis
--   9. Window Functions & Ranking
--  10. Host & Neighbourhood Analysis
--  11. Statistical Tests via SQL (Chi-square contribution, Z-scores)
--  12. ROLLUP / CUBE Summary Reporting
--------------------------------------------------------------------------------


--================================================================================
-- 1. TABLE CREATION (DDL)
--================================================================================
DROP TABLE airbnb_nyc PURGE;

CREATE TABLE airbnb_nyc (
    id                              NUMBER          PRIMARY KEY,
    name                            VARCHAR2(400),
    host_id                         NUMBER,
    host_name                       VARCHAR2(200),
    neighbourhood_group             VARCHAR2(50),
    neighbourhood                   VARCHAR2(100),
    latitude                        NUMBER(9,6),
    longitude                       NUMBER(9,6),
    room_type                       VARCHAR2(50),
    price                           NUMBER(10,2),
    minimum_nights                  NUMBER,
    number_of_reviews               NUMBER,
    last_review                     DATE,
    reviews_per_month               NUMBER(6,2),
    calculated_host_listings_count  NUMBER,
    availability_365                NUMBER
);

-- Helpful indexes for the analytical queries below
CREATE INDEX ix_airbnb_borough   ON airbnb_nyc(neighbourhood_group);
CREATE INDEX ix_airbnb_roomtype  ON airbnb_nyc(room_type);
CREATE INDEX ix_airbnb_price     ON airbnb_nyc(price);
CREATE INDEX ix_airbnb_host      ON airbnb_nyc(host_id);


--================================================================================
-- 2. LOADING THE CSV
--================================================================================
-- OPTION A — SQL Developer GUI (simplest):
--   Right-click airbnb_nyc table in the Connections tree -> Import Data...
--   -> select AB_NYC_2019.csv -> map columns 1:1 -> set last_review format
--      to YYYY-MM-DD -> Finish.
--
-- OPTION B — SQL*Loader (for repeatable / large-batch loads), run from OS shell:
--   sqlldr userid=<user>/<pwd>@<tns> control=airbnb_nyc.ctl log=airbnb_nyc.log
--
-- Save the following as airbnb_nyc.ctl alongside the CSV:
--
-- LOAD DATA
-- INFILE 'AB_NYC_2019.csv'
-- APPEND INTO TABLE airbnb_nyc
-- FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
-- TRAILING NULLCOLS
-- (
--   id, name, host_id, host_name, neighbourhood_group, neighbourhood,
--   latitude, longitude, room_type, price, minimum_nights, number_of_reviews,
--   last_review DATE "YYYY-MM-DD" NULLIF last_review=BLANKS,
--   reviews_per_month, calculated_host_listings_count, availability_365
-- )
--
-- (Skip the header row with SKIP=1 on the sqlldr command line.)


--================================================================================
-- 3. DATA QUALITY CHECKS
--================================================================================

-- Row count & basic sanity
SELECT COUNT(*) AS total_rows FROM airbnb_nyc;

-- Missing values per nullable column
SELECT
    SUM(CASE WHEN name                IS NULL THEN 1 ELSE 0 END) AS missing_name,
    SUM(CASE WHEN host_name           IS NULL THEN 1 ELSE 0 END) AS missing_host_name,
    SUM(CASE WHEN last_review         IS NULL THEN 1 ELSE 0 END) AS missing_last_review,
    SUM(CASE WHEN reviews_per_month   IS NULL THEN 1 ELSE 0 END) AS missing_reviews_per_month
FROM airbnb_nyc;

-- Duplicate IDs (should be 0 — id is PK, but useful pre-load check on staging table)
SELECT id, COUNT(*) cnt
FROM airbnb_nyc
GROUP BY id
HAVING COUNT(*) > 1;

-- Listings priced at $0 (data anomalies)
SELECT COUNT(*) AS zero_price_listings FROM airbnb_nyc WHERE price = 0;

-- Extreme minimum_nights values
SELECT id, name, minimum_nights
FROM airbnb_nyc
WHERE minimum_nights > 365
ORDER BY minimum_nights DESC;


--================================================================================
-- 4. DATA CLEANING / STANDARDIZED VIEW
--================================================================================
-- Exclude $0-price listings; impute reviews_per_month = 0 when NULL;
-- this view is the base for all downstream analytical queries.
CREATE OR REPLACE VIEW v_airbnb_clean AS
SELECT
    a.*,
    NVL(reviews_per_month, 0)                       AS reviews_per_month_clean,
    CASE WHEN minimum_nights > 365 THEN 365
         ELSE minimum_nights END                     AS minimum_nights_capped
FROM airbnb_nyc a
WHERE price > 0;


--================================================================================
-- 5. DESCRIPTIVE STATISTICS
--================================================================================

-- Overall summary statistics for price
SELECT
    COUNT(price)                              AS n,
    ROUND(MIN(price),2)                       AS min_price,
    ROUND(MAX(price),2)                       AS max_price,
    ROUND(AVG(price),2)                       AS mean_price,
    ROUND(MEDIAN(price),2)                    AS median_price,
    ROUND(STDDEV(price),2)                    AS stddev_price,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY price),2) AS q1_price,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY price),2) AS q3_price
FROM v_airbnb_clean;

-- Same summary stats, broken out by room_type
SELECT
    room_type,
    COUNT(*)                                   AS n,
    ROUND(AVG(price),2)                        AS mean_price,
    ROUND(MEDIAN(price),2)                     AS median_price,
    ROUND(STDDEV(price),2)                     AS stddev_price
FROM v_airbnb_clean
GROUP BY room_type
ORDER BY mean_price DESC;

-- Same summary stats, broken out by borough
SELECT
    neighbourhood_group,
    COUNT(*)                                   AS n,
    ROUND(AVG(price),2)                        AS mean_price,
    ROUND(MEDIAN(price),2)                     AS median_price,
    ROUND(STDDEV(price),2)                     AS stddev_price,
    ROUND(AVG(minimum_nights_capped),1)        AS avg_min_nights,
    ROUND(AVG(number_of_reviews),1)            AS avg_reviews,
    ROUND(AVG(availability_365),1)             AS avg_availability
FROM v_airbnb_clean
GROUP BY neighbourhood_group
ORDER BY mean_price DESC;


--================================================================================
-- 6. DISTRIBUTION & OUTLIER ANALYSIS (IQR method)
--================================================================================
WITH bounds AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY price) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY price) AS q3
    FROM v_airbnb_clean
)
SELECT
    b.q1, b.q3,
    (b.q3 - b.q1)                              AS iqr,
    (b.q3 + 1.5*(b.q3 - b.q1))                 AS upper_outlier_bound,
    GREATEST(b.q1 - 1.5*(b.q3 - b.q1), 0)      AS lower_outlier_bound
FROM bounds b;

-- Listings flagged as price outliers (above the IQR upper bound)
WITH bounds AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY price) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY price) AS q3
    FROM v_airbnb_clean
)
SELECT a.id, a.name, a.neighbourhood_group, a.room_type, a.price
FROM v_airbnb_clean a, bounds b
WHERE a.price > b.q3 + 1.5*(b.q3 - b.q1)
ORDER BY a.price DESC
FETCH FIRST 20 ROWS ONLY;          -- pre-12c alternative: WHERE ROWNUM <= 20

-- Price bucket distribution (histogram via WIDTH_BUCKET)
SELECT
    WIDTH_BUCKET(price, 0, 1000, 20) AS price_bucket,
    MIN(price) AS bucket_min, MAX(price) AS bucket_max,
    COUNT(*)   AS listing_count
FROM v_airbnb_clean
WHERE price <= 1000
GROUP BY WIDTH_BUCKET(price, 0, 1000, 20)
ORDER BY price_bucket;


--================================================================================
-- 7. GROUP COMPARISONS (Borough x Room Type)
--================================================================================

-- Pivoted average price: boroughs as rows, room types as columns
-- (PIVOT only accepts a bare aggregate_function(expr) internally, so rounding
--  is applied in the outer SELECT rather than inside the PIVOT clause itself)
SELECT
    neighbourhood_group,
    ROUND(entire_home_avg_price)  AS entire_home_avg_price,  entire_home_n,
    ROUND(private_room_avg_price) AS private_room_avg_price, private_room_n,
    ROUND(shared_room_avg_price)  AS shared_room_avg_price,  shared_room_n
FROM (
    SELECT neighbourhood_group, room_type, price
    FROM v_airbnb_clean
)
PIVOT (
    AVG(price) AS avg_price, COUNT(*) AS n
    FOR room_type IN (
        'Entire home/apt' AS entire_home,
        'Private room'    AS private_room,
        'Shared room'     AS shared_room
    )
)
ORDER BY neighbourhood_group;

-- Borough ranked by median price (cheapest to priciest)
SELECT
    neighbourhood_group,
    ROUND(MEDIAN(price),2) AS median_price,
    RANK() OVER (ORDER BY MEDIAN(price)) AS price_rank
FROM v_airbnb_clean
GROUP BY neighbourhood_group
ORDER BY median_price;


--================================================================================
-- 8. CORRELATION ANALYSIS
--================================================================================
-- Pairwise Pearson correlation between price and other numeric variables
SELECT
    ROUND(CORR(price, minimum_nights_capped),3)                AS corr_price_minnights,
    ROUND(CORR(price, number_of_reviews),3)                    AS corr_price_reviews,
    ROUND(CORR(price, reviews_per_month_clean),3)               AS corr_price_revpm,
    ROUND(CORR(price, calculated_host_listings_count),3)       AS corr_price_hostlistings,
    ROUND(CORR(price, availability_365),3)                     AS corr_price_availability,
    ROUND(CORR(number_of_reviews, reviews_per_month_clean),3)   AS corr_reviews_revpm
FROM v_airbnb_clean;

-- Simple linear regression of price on availability_365 (slope/intercept/R²)
SELECT
    ROUND(REGR_SLOPE(price, availability_365),4)     AS slope,
    ROUND(REGR_INTERCEPT(price, availability_365),4) AS intercept,
    ROUND(REGR_R2(price, availability_365),4)        AS r_squared
FROM v_airbnb_clean;


--================================================================================
-- 9. WINDOW FUNCTIONS & RANKING
--================================================================================

-- Top 5 most expensive listings per borough
SELECT *
FROM (
    SELECT
        neighbourhood_group, name, room_type, price,
        RANK() OVER (PARTITION BY neighbourhood_group ORDER BY price DESC) AS rnk
    FROM v_airbnb_clean
)
WHERE rnk <= 5
ORDER BY neighbourhood_group, rnk;

-- Each listing's price vs the average price of its neighbourhood (% deviation)
SELECT
    id, name, neighbourhood, price,
    ROUND(AVG(price) OVER (PARTITION BY neighbourhood),2)            AS nbhd_avg_price,
    ROUND(100*(price - AVG(price) OVER (PARTITION BY neighbourhood))
              / AVG(price) OVER (PARTITION BY neighbourhood), 1)     AS pct_vs_nbhd_avg
FROM v_airbnb_clean
ORDER BY pct_vs_nbhd_avg DESC
FETCH FIRST 20 ROWS ONLY;

-- Running cumulative share of listings by descending price (concentration curve)
SELECT
    price,
    listing_rank,
    ROUND(100 * cum_listings / total_listings, 2) AS cum_pct_listings
FROM (
    SELECT
        price,
        ROW_NUMBER() OVER (ORDER BY price DESC)        AS listing_rank,
        SUM(1) OVER (ORDER BY price DESC)               AS cum_listings,
        COUNT(*) OVER ()                                 AS total_listings
    FROM v_airbnb_clean
)
WHERE MOD(listing_rank, 5000) = 0;


--================================================================================
-- 10. HOST & NEIGHBOURHOOD ANALYSIS
--================================================================================

-- Top 10 hosts by total listing count
SELECT
    host_id, MAX(host_name) AS host_name, COUNT(*) AS listing_count,
    ROUND(AVG(price),2) AS avg_price
FROM v_airbnb_clean
GROUP BY host_id
ORDER BY listing_count DESC
FETCH FIRST 10 ROWS ONLY;

-- Top 10 neighbourhoods by listing count
SELECT neighbourhood, COUNT(*) AS listing_count
FROM v_airbnb_clean
GROUP BY neighbourhood
ORDER BY listing_count DESC
FETCH FIRST 10 ROWS ONLY;

-- Top 10 priciest neighbourhoods (min 20 listings, avoids noise from tiny samples)
SELECT neighbourhood, COUNT(*) AS n, ROUND(AVG(price),2) AS avg_price
FROM v_airbnb_clean
GROUP BY neighbourhood
HAVING COUNT(*) >= 20
ORDER BY avg_price DESC
FETCH FIRST 10 ROWS ONLY;

-- Hosts who appear to be commercial operators (many listings, low avg availability)
SELECT
    host_id, MAX(host_name) AS host_name, COUNT(*) AS listing_count,
    ROUND(AVG(availability_365),1) AS avg_availability
FROM v_airbnb_clean
GROUP BY host_id
HAVING COUNT(*) >= 10
ORDER BY listing_count DESC;


--================================================================================
-- 11. STATISTICAL TESTS VIA SQL
--================================================================================

-- Z-scores for price within each borough (flags borough-relative outliers, |z| > 3)
SELECT *
FROM (
    SELECT
        id, neighbourhood_group, price,
        ROUND( (price - AVG(price) OVER (PARTITION BY neighbourhood_group))
               / NULLIF(STDDEV(price) OVER (PARTITION BY neighbourhood_group),0), 2) AS z_score
    FROM v_airbnb_clean
)
WHERE ABS(z_score) > 3
ORDER BY z_score DESC;

-- Chi-square style contribution table: observed vs expected counts
-- for neighbourhood_group x room_type independence check
WITH obs AS (
    SELECT neighbourhood_group, room_type, COUNT(*) AS observed
    FROM v_airbnb_clean
    GROUP BY neighbourhood_group, room_type
),
row_tot AS (
    SELECT neighbourhood_group, SUM(observed) AS row_total
    FROM obs GROUP BY neighbourhood_group
),
col_tot AS (
    SELECT room_type, SUM(observed) AS col_total
    FROM obs GROUP BY room_type
),
grand AS (
    SELECT SUM(observed) AS grand_total FROM obs
)
SELECT
    o.neighbourhood_group, o.room_type, o.observed,
    ROUND(r.row_total * c.col_total / g.grand_total, 1)                         AS expected,
    ROUND(POWER(o.observed - (r.row_total*c.col_total/g.grand_total),2)
          / (r.row_total*c.col_total/g.grand_total), 2)                         AS chi_sq_contribution
FROM obs o
JOIN row_tot r ON o.neighbourhood_group = r.neighbourhood_group
JOIN col_tot c ON o.room_type = c.room_type
CROSS JOIN grand g
ORDER BY chi_sq_contribution DESC;
-- Sum the chi_sq_contribution column to get the overall chi-square statistic;
-- compare to a chi-square table with (rows-1)*(cols-1) degrees of freedom.


--================================================================================
-- 12. ROLLUP / CUBE SUMMARY REPORTING
--================================================================================

-- Subtotals by borough, room type, AND a grand total in one query (ROLLUP)
SELECT
    NVL(neighbourhood_group, 'ALL BOROUGHS') AS neighbourhood_group,
    NVL(room_type, 'ALL ROOM TYPES')         AS room_type,
    COUNT(*)                                 AS listing_count,
    ROUND(AVG(price),2)                      AS avg_price
FROM v_airbnb_clean
GROUP BY ROLLUP(neighbourhood_group, room_type)
ORDER BY neighbourhood_group, room_type;

-- Full cross-tabulation of every combination, including marginal totals (CUBE)
SELECT
    NVL(neighbourhood_group, 'ALL BOROUGHS') AS neighbourhood_group,
    NVL(room_type, 'ALL ROOM TYPES')         AS room_type,
    COUNT(*)                                 AS listing_count,
    ROUND(AVG(price),2)                      AS avg_price
FROM v_airbnb_clean
GROUP BY CUBE(neighbourhood_group, room_type)
ORDER BY neighbourhood_group, room_type;

--------------------------------------------------------------------------------
-- END OF SCRIPT
--------------------------------------------------------------------------------
