-- =============================================
-- NYC Restaurant Inspections: Analysis
-- Business task: help a restaurant chain choose a location for a new NYC branch
-- and prepare it for health inspections.
-- Input: inspections_clean (output of nyc_inspections_cleaning.sql)
-- =============================================

USE nyc_inspections;

-- ---------------------------------------------
-- A. One row per inspection
-- inspections_clean has one row per VIOLATION, so score and action repeat
-- for every violation of the same inspection. Averages must be calculated
-- on one row per inspection (camis + inspection_date + inspection_type).
-- Result: 92,902 inspections
-- ---------------------------------------------
DROP TABLE IF EXISTS inspections;

CREATE TABLE inspections AS
SELECT camis, dba, boro, zipcode, nta, cuisine_description,
       inspection_date, inspection_type,
       MAX(score)                                    AS score,
       MAX(grade)                                    AS grade,
       SUM(violation_code <> '')                     AS violations_cnt,
       SUM(critical_flag = 'Critical')               AS critical_cnt,
       MAX(action LIKE 'Establishment Closed%')      AS is_closed
FROM inspections_clean
WHERE inspection_date IS NOT NULL
GROUP BY camis, dba, boro, zipcode, nta, cuisine_description,
         inspection_date, inspection_type;

-- Check: each inspection appears once (expected: 0 rows)
SELECT camis, inspection_date, inspection_type, COUNT(*) AS cnt
FROM inspections
GROUP BY camis, inspection_date, inspection_type
HAVING COUNT(*) > 1;

-- Check: inspections with no violations get 0, not 1
SELECT camis, inspection_date, inspection_type, violations_cnt
FROM inspections
WHERE violations_cnt = 0
LIMIT 10;


-- ---------------------------------------------
-- B. Boroughs (Key question 1) -> Insight 1
-- Only routine first inspections: re-inspections happen only after a poor
-- result and would bias the comparison. Unknown borough excluded.
-- A-level = score 0-13. Lower score = better.
-- ---------------------------------------------
SELECT boro,
       COUNT(DISTINCT camis)            AS restaurants,
       COUNT(*)                         AS inspections,
       ROUND(AVG(score), 1)             AS avg_score,
       ROUND(AVG(score <= 13) * 100, 1) AS pct_a_level,
       ROUND(AVG(is_closed) * 100, 1)   AS pct_closed
FROM inspections
WHERE inspection_type = 'Cycle Inspection / Initial Inspection'
  AND boro <> 'Unknown'
GROUP BY boro
ORDER BY avg_score;


-- ---------------------------------------------
-- C. Top 5 cuisines per borough (Key question 3) -> Insight 2
-- Active restaurants only. Share = % of all restaurants in the borough.
-- ---------------------------------------------
WITH cuisine_boro AS (
    SELECT boro,
           cuisine_description,
           COUNT(DISTINCT camis) AS restaurants,
           ROUND(COUNT(DISTINCT camis)
                 / SUM(COUNT(DISTINCT camis)) OVER (PARTITION BY boro) * 100, 1) AS pct_of_boro,
           ROW_NUMBER() OVER (PARTITION BY boro
                              ORDER BY COUNT(DISTINCT camis) DESC) AS rn
    FROM inspections_clean
    WHERE restaurant_status = 'Inspected'
      AND boro <> 'Unknown'
      AND cuisine_description <> 'Unknown'
    GROUP BY boro, cuisine_description
)
SELECT boro, rn, cuisine_description, restaurants, pct_of_boro
FROM cuisine_boro
WHERE rn <= 5
ORDER BY boro, rn;


-- ---------------------------------------------
-- D. Most common violations (Key question 2) -> Insight 3
-- ---------------------------------------------
-- Top 10 violations, % of all violations
SELECT violation_code,
       MAX(LEFT(violation_description, 80)) AS description,
       MAX(critical_flag)                   AS critical_flag,
       COUNT(*)                             AS violations,
       ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 1) AS pct_of_all
FROM inspections_clean
WHERE violation_code <> ''
GROUP BY violation_code
ORDER BY violations DESC
LIMIT 10;

-- Share of the top 10 in all violations (result: 64.3%)
WITH top10 AS (
    SELECT violation_code,
           COUNT(*) AS violations,
           ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 1) AS pct_of_all
    FROM inspections_clean
    WHERE violation_code <> ''
    GROUP BY violation_code
    ORDER BY violations DESC
    LIMIT 10
)
SELECT SUM(pct_of_all) AS top10_pct
FROM top10;

-- Preventable once (before opening) vs daily routine
SELECT CASE
         WHEN violation_code IN ('10F', '08A', '10B', '04A') THEN 'Fix once (before opening)'
         WHEN violation_code IN ('02G', '06D', '02B', '04L', '04N', '06C') THEN 'Daily routine'
         ELSE 'Other violations'
       END AS fix_type,
       COUNT(*) AS violations,
       ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 1) AS pct_of_all
FROM inspections_clean
WHERE violation_code <> ''
GROUP BY fix_type
ORDER BY violations DESC;

-- Share of critical violations (result: 53.6%)
SELECT ROUND(AVG(critical_flag = 'Critical') * 100, 1) AS pct_critical
FROM inspections_clean
WHERE violation_code <> '';


-- ---------------------------------------------
-- E. Violations at closures (Key question 4) -> Insight 4
-- All violations vs violations at inspections that ended in closure.
-- Exported as violations_compare.csv for Tableau.
-- Commas and quotes removed from descriptions so the CSV keeps its columns.
-- ---------------------------------------------
WITH all_v AS (
    SELECT violation_code,
           MAX(LEFT(REPLACE(REPLACE(violation_description, '"', ''), ',', ';'), 80)) AS description,
           MAX(critical_flag) AS critical_flag,
           COUNT(*)           AS v_all
    FROM inspections_clean
    WHERE violation_code <> ''
    GROUP BY violation_code
),
closed_v AS (
    SELECT violation_code, COUNT(*) AS v_closed
    FROM inspections_clean
    WHERE violation_code <> ''
      AND action LIKE 'Establishment Closed%'
    GROUP BY violation_code
)
SELECT a.violation_code,
       a.description,
       a.critical_flag,
       a.v_all,
       ROUND(a.v_all / SUM(a.v_all) OVER () * 100, 1) AS pct_all,
       COALESCE(c.v_closed, 0) AS v_closed,
       ROUND(COALESCE(c.v_closed, 0) / SUM(COALESCE(c.v_closed, 0)) OVER () * 100, 1) AS pct_closed
FROM all_v a
LEFT JOIN closed_v c ON a.violation_code = c.violation_code
ORDER BY a.v_all DESC;


-- ---------------------------------------------
-- F. Restaurant map data for Tableau (restaurants_map.csv)
-- One row per active restaurant with coordinates; pest codes:
-- 08A conditions for pests, 04L mice, 04M roaches, 04N flies.
-- ---------------------------------------------
SELECT camis,
       MAX(dba)                 AS dba,
       MAX(boro)                AS boro,
       MAX(nta)                 AS nta,
       MAX(cuisine_description) AS cuisine_description,
       MAX(latitude)            AS latitude,
       MAX(longitude)           AS longitude,
       SUM(violation_code <> '') AS violations,
       SUM(violation_code IN ('08A', '04L', '04M', '04N')) AS pest_violations
FROM inspections_clean
WHERE restaurant_status = 'Inspected'
  AND latitude IS NOT NULL
GROUP BY camis;
