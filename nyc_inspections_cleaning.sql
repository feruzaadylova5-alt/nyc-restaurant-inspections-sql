-- =============================================
-- NYC Restaurant Inspections: Data Cleaning
-- =============================================

-- 1. Load raw data
-- Create database and raw table (all columns as text to avoid data loss on import)
-- Load CSV into raw table
-- Check load: total row count
-- Check load: CAMIS must be exactly 8 digits (detects shifted columns)
-- Check load: no Windows line endings (\r) left in the last column
CREATE DATABASE IF NOT EXISTS nyc_inspections;
USE nyc_inspections;
SET GLOBAL local_infile = 1;

CREATE TABLE raw_inspections (
  row_id INT NOT NULL AUTO_INCREMENT,
  camis VARCHAR(20) DEFAULT NULL,
  dba VARCHAR(255) DEFAULT NULL,
  boro VARCHAR(50) DEFAULT NULL,
  building VARCHAR(50) DEFAULT NULL,
  street VARCHAR(255) DEFAULT NULL,
  zipcode VARCHAR(20) DEFAULT NULL,
  phone VARCHAR(50) DEFAULT NULL,
  cuisine_description VARCHAR(255) DEFAULT NULL,
  inspection_date VARCHAR(30) DEFAULT NULL,
  action VARCHAR(255) DEFAULT NULL,
  violation_code VARCHAR(20) DEFAULT NULL,
  violation_description TEXT,
  critical_flag VARCHAR(50) DEFAULT NULL,
  score VARCHAR(20) DEFAULT NULL,
  grade VARCHAR(20) DEFAULT NULL,
  grade_date VARCHAR(30) DEFAULT NULL,
  record_date VARCHAR(30) DEFAULT NULL,
  inspection_type VARCHAR(255) DEFAULT NULL,
  latitude VARCHAR(30) DEFAULT NULL,
  longitude VARCHAR(30) DEFAULT NULL,
  community_board VARCHAR(20) DEFAULT NULL,
  council_district VARCHAR(20) DEFAULT NULL,
  census_tract VARCHAR(20) DEFAULT NULL,
  bin VARCHAR(20) DEFAULT NULL,
  bbl VARCHAR(20) DEFAULT NULL,
  nta VARCHAR(20) DEFAULT NULL,
  location_point TEXT,
  PRIMARY KEY (row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

LOAD DATA LOCAL INFILE 'path/to/NYC_Restaurant_Inspection.csv'
INTO TABLE raw_inspections
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(camis, dba, boro, building, street, zipcode, phone, cuisine_description,
 inspection_date, action, violation_code, violation_description, critical_flag,
 score, grade, grade_date, record_date, inspection_type, latitude, longitude,
 community_board, council_district, census_tract, bin, bbl, nta, location_point);
 
SELECT COUNT(*) FROM raw_inspections;
 
SELECT camis, dba, boro, inspection_date, grade, location_point
FROM raw_inspections
LIMIT 10;

SELECT COUNT(*) AS bad_camis
FROM raw_inspections
WHERE camis NOT REGEXP '^[0-9]{8}$';

SELECT COUNT(*) AS rows_with_cr
FROM raw_inspections
WHERE location_point LIKE CONCAT('%', CHAR(13));

-- 2. Create working copy (raw table stays untouched)
CREATE TABLE stg_inspections AS
SELECT * FROM raw_inspections;

-- 3. Profiling
-- Total rows vs. unique restaurants
SELECT COUNT(*) AS number_rows, COUNT(distinct camis) AS number_rest FROM stg_inspections;

 SELECT camis, dba, inspection_date, violation_code, grade FROM stg_inspections
 where dba like "%Katz%"
 order by inspection_date DESC;
 
 -- Look at one restaurant: one row = one violation per inspection
 SELECT camis, dba, inspection_date, violation_code, grade FROM stg_inspections
 where camis = 50062888
 order by inspection_date DESC; 

-- 4. inspection_date
-- Test conversion from text (MM/DD/YYYY) to DATE
SELECT camis, dba, inspection_date, STR_TO_DATE(inspection_date, '%m/%d/%Y') AS inspection_date_clean
FROM stg_inspections
WHERE camis = '50062888'
ORDER BY inspection_date_clean DESC;

-- Check that all values convert (0 NULLs expected)
SELECT COUNT(*) FROM stg_inspections
WHERE STR_TO_DATE(inspection_date, '%m/%d/%Y') IS NULL;

-- Placeholder date 01/01/1900: count rows and restaurants
SELECT COUNT(*) AS rows_1900, COUNT(DISTINCT camis) AS restourants_1900  FROM stg_inspections
WHERE inspection_date = '01/01/1900';

--  Verify placeholder rows have no grade, score or violations
-- Result: 0/0/0 -> restaurants not yet inspected
SELECT SUM(grade<> ''), SUM(score<> ''), SUM(violation_code<> '') FROM stg_inspections
WHERE inspection_date = '01/01/1900';

-- Add clean date column; placeholder 1900 -> NULL
ALTER TABLE stg_inspections ADD COLUMN inspection_date_clean DATE; 
UPDATE stg_inspections
SET inspection_date_clean = CASE
WHEN inspection_date = '01/01/1900' THEN NULL
ELSE STR_TO_DATE(inspection_date, '%m/%d/%Y')
END;

-- Verify: NULL count must equal 3,808
SELECT COUNT(*) FROM stg_inspections
WHERE inspection_date_clean IS NULL;

-- 5. Restaurant Status. 
-- Add inspection status flag based on clean date
-- Verify: Inspected = 291,142 / Not Inspected = 3,808
ALTER TABLE stg_inspections ADD COLUMN if_inspected varchar(30); 

SELECT inspection_date_clean, CASE
WHEN inspection_date_clean IS NULL THEN 'Not Inspected'
ELSE 'Inspected' End AS if_inspected from stg_inspections
ORDER by inspection_date_clean DESC;

UPDATE stg_inspections
SET if_inspected = CASE
WHEN inspection_date_clean IS NULL THEN 'Not Inspected'
ELSE 'Inspected' 
END;

-- 6. GRADE DATE
SELECT camis, dba, grade_date FROM stg_inspections
LIMIT 50;

ALTER TABLE stg_inspections ADD COLUMN grade_date_clean DATE;
UPDATE stg_inspections
SET grade_date_clean = CASE
WHEN grade_date <> '' THEN str_to_date(grade_date, '%m/%d/%Y')
ELSE NULL
END;

SELECT COUNT(*) FROM stg_inspections
WHERE grade_date <> '' AND grade_date_clean IS NULL;


-- 7. Restaurants with no recent inspection
-- Find restaurants whose last inspection was before 2020
-- Result: 188 restaurants (grouping by dba gives 164 -> 24 hidden by shared names)
SELECT dba, MAX(inspection_date_clean) AS latest_inspection FROM stg_inspections
GROUP BY dba
HAVING latest_inspection < '2020-01-01';

-- Count rows belonging to these restaurants (expected rows to update: 1,720)
SELECT COUNT(*) FROM stg_inspections
WHERE camis IN ( SELECT camis FROM stg_inspections
GROUP BY camis
HAVING MAX(inspection_date_clean) < '2020-01-01');

-- Flag them as 'No inspection since 2020'
-- Subquery wrapped in a derived table (old_rest) to avoid MySQL Error 1093
-- Result: 1,720 rows changed
UPDATE stg_inspections
SET if_inspected = 'No inspection since 2020'
WHERE camis IN (SELECT camis FROM (SELECT camis FROM stg_inspections
GROUP BY camis
HAVING MAX(inspection_date_clean) < '2020-01-01') AS Old_rest);

-- Verify flag distribution
-- Inspected 289,422 / No inspection since 2020 1,720 / Not Inspected 3,808 = 294,950
SELECT if_inspected, COUNT(if_inspected)
FROM stg_inspections
GROUP BY if_inspected;

ALTER TABLE stg_inspections RENAME column if_inspected to restaurant_status;

SELECT COUNT(*) FROM stg_inspections
WHERE str_to_date(record_date, '%m/%d/%Y') IS NOT NULL;

-- 8. RECORD_DATE
-- Same value in all 294,950 rows: 2026-09-24 (dataset extract date)
-- Converted to DATE (record_date) for consistency
-- Check: 294,950 converted, 0 NULL
UPDATE stg_inspections
SET record_date= str_to_date(record_date, '%m/%d/%Y');


-- 9. BORO
-- Invalid value '0': 340 rows, 88 restaurants
-- Zip codes point to New Jersey / Connecticut (52 rows without zip); no coordinates
-- Borough cannot be recovered -> set to 'Unknown'
-- Check: 340 rows updated
SELECT boro, count(*), count(*)/SUM(COUNT(*)) OVER ()*100  AS procent_boro from stg_inspections
GROUP BY boro
ORDER BY count(*) DESC;

UPDATE stg_inspections
SET boro = 'Unknown'
Where boro = '0';

-- 10. ZipCodes
SELECT COUNT(zipcode) FROM stg_inspections
WHERE zipcode = '';

SELECT COUNT(zipcode) FROM stg_inspections
WHERE zipcode NOT REGEXP '^[0-9]{5}$';

SELECT boro, COUNT(camis) FROM stg_inspections
WHERE LEFT(zipcode, 3) NOT IN ('100', '101', '102', '103', '104') AND LEFT(zipcode, 2) <> '11'
AND zipcode <> ''
GROUP BY boro;

SELECT boro, zipcode, count(distinct camis) FROM stg_inspections
WHERE boro = 'Unknown' AND (LEFT(zipcode, 3) IN ('100', '101', '102', '103', '104')
 OR LEFT(zipcode, 2) = '11')
GROUP BY boro, zipcode;

SELECT zipcode, count(boro) from stg_inspections
where boro <> 'Unknown' and zipcode<>''
group by zipcode;

SELECT zipcode, count( boro) from stg_inspections
where boro <> 'Unknown' and zipcode<>'' 
group by zipcode
having count(distinct boro)>1;

SELECT boro, count(boro), dba, street FROM stg_inspections
WHERE zipcode = '11371' AND (street LIKE '%TERMINAL%' OR street LIKE '%AIRPORT%')
GROUP BY boro, dba, street;

SELECT boro, count(boro), street, dba FROM stg_inspections
WHERE zipcode = '11371' AND (street NOT LIKE '%TERMINAL%' AND street NOT LIKE '%AIRPORT%' 
AND street NOT LIKE '%GUARDIA%' AND dba NOT LIKE '%Lounge%' )
GROUP BY boro, dba, street;

SELECT dba, street, boro
FROM stg_inspections
WHERE zipcode = '11371' AND boro = 'Manhattan';

-- zip 11371 (LaGuardia Airport, Queens): 7 rows labeled Manhattan
-- All 98 rows are airport locations (terminals, lounges) -> corrected to Queens
UPDATE stg_inspections
SET boro = 'Queens'
WHERE zipcode = '11371' AND boro = 'Manhattan';


-- 11. BORO RECOVERY VIA ZIP LOOKUP
-- Built lookup table zip_boro: 226 NYC zip codes, each mapped to exactly 1 borough
-- (zip 11371 had 2 boroughs: fixed 7 LaGuardia rows Manhattan -> Queens first)
-- Joined Unknown rows to lookup: 50 rows (6 restaurants) recovered
-- Remaining Unknown: 290 rows (82 restaurants) - NJ/CT/Long Island zips or no zip
-- Note: UPDATE with JOIN was slow without index -> added PRIMARY KEY on zip_boro

CREATE TABLE zip_boro AS
SELECT zipcode, MAX(boro) AS boro
FROM stg_inspections
WHERE boro <> 'Unknown' AND zipcode <> ''
GROUP BY zipcode;

SELECT zipcode from stg_inspections
WHERE boro <> 'Unknown' AND zipcode <> ''
GROUP BY zipcode;

ALTER TABLE zip_boro ADD PRIMARY KEY (zipcode);

UPDATE stg_inspections AS s
JOIN zip_boro AS z
  ON s.zipcode = z.zipcode
SET s.boro= z.boro
WHERE s.boro = 'Unknown';

SELECT boro,
       COUNT(*) AS rows_cnt,
       ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 2) AS pct_boro
FROM stg_inspections
GROUP BY boro
ORDER BY rows_cnt DESC;


-- 12. CUISINE_DESCRIPTION
-- 91 distinct values; blank in 3,888 rows (3,810 restaurants)
-- 3,808 of them are never-inspected restaurants; 2 are 'No inspection since 2020'
-- Blank -> 'Unknown' (consistent with boro)
-- 'Other' and 'Not Listed/Not Applicable' kept as is: inspector's own categories
SELECT Count(distinct cuisine_description) FROM stg_inspections;

SELECT ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT camis) DESC) AS rn, 
	   cuisine_description, Count(distinct camis) AS camis_dist
FROM stg_inspections
GROUP BY cuisine_description
ORDER BY  camis_dist DESC;

SELECT restaurant_status, COUNT(DISTINCT camis) AS restaurants, COUNT(*) AS rows_cnt
FROM stg_inspections
WHERE cuisine_description = ''
GROUP BY restaurant_status;

UPDATE stg_inspections
SET cuisine_description = 'Unknown'
WHERE cuisine_description = '';

-- Checked: no case/whitespace duplicates, no encoding issues (LENGTH = CHAR_LENGTH)
SELECT DISTINCT cuisine_description, length(cuisine_description) AS len FROM stg_inspections
ORDER BY len DESC;


-- 13. PHONE. Clean phone numbers: keep digits only,
-- standardize to 10 digits, invalid values -> NULL
SELECT phone,
       REGEXP_REPLACE(phone, '[^0-9]', '') AS phone_digits,
       LENGTH(REGEXP_REPLACE(phone, '[^0-9]', '')) AS digits_len
FROM stg_inspections
WHERE  phone NOT regexp '^[0-9]{10}$' AND phone<>'';

WITH p AS (
   SELECT phone,
       REGEXP_REPLACE(phone, '[^0-9]', '') AS phone_digits,
       LENGTH(REGEXP_REPLACE(phone, '[^0-9]', '')) AS digits_len
FROM stg_inspections
WHERE  phone NOT regexp '^[0-9]{10}$' AND phone<>''
)
SELECT
    CASE
        WHEN digits_len = 10 AND phone_digits NOT REGEXP '^0+$' THEN 'fixable'
        WHEN digits_len = 0 OR phone_digits REGEXP '^0+$' THEN 'placeholder'
        ELSE 'invalid'
    END AS phone_type,
    COUNT(*) AS rows_cnt
FROM p
GROUP BY phone_type;


WITH p AS (
   SELECT phone,
       REGEXP_REPLACE(phone, '[^0-9]', '') AS phone_digits,
       LENGTH(REGEXP_REPLACE(phone, '[^0-9]', '')) AS digits_len
FROM stg_inspections
WHERE  phone NOT regexp '^[0-9]{10}$' AND phone<>''
)
SELECT digits_len, COUNT(*) AS rows_cnt, MAX(phone) FROM p
WHERE digits_len<>10 AND digits_len<>0
GROUP BY digits_len;

ALTER TABLE stg_inspections ADD column phone_clean VARCHAR(30);
UPDATE stg_inspections
SET phone_clean = CASE
	WHEN LENGTH(REGEXP_REPLACE(phone, '[^0-9]', '')) = 10 
	AND RIGHT(REGEXP_REPLACE(phone, '[^0-9]', ''), 10) <> '0000000000'
    THEN REGEXP_REPLACE(phone, '[^0-9]', '')
    WHEN LENGTH(REGEXP_REPLACE(phone, '[^0-9]', '')) = 11 
    AND REGEXP_REPLACE(phone, '[^0-9]', '') LIKE '1%' 
    THEN right(REGEXP_REPLACE(phone, '[^0-9]', ''), 10)
    ELSE NULL
    END;
    
-- 14. SCORE
-- Text -> INT (score_clean), blank -> NULL
-- Range 0-214: high scores are real (many violations), not errors
-- Closure (action) depends on health hazards, not on score
alter table stg_inspections ADD COLUMN score_clean INT;

UPDATE stg_inspections
SET score_clean = CASE 
WHEN score='' then NULL
ELSE CAST(score AS UNSIGNED) END;

SELECT score_clean, count(*) FROM stg_inspections
group by score_clean
order by score_clean desc
;

SELECT camis, dba, inspection_date_clean, score_clean, action
FROM stg_inspections
WHERE action LIKE 'Establishment Closed%'
ORDER BY score_clean DESC
;

-- 15. GRADE
-- Blank -> NULL (no grade issued: non-cycle inspections,
-- initial with 14+ points, closures)
-- 2,462 cycle initial rows with score <= 13 and no grade: data gap, left as NULL
-- 6 rows with C at initial: one inspection, kept as is
UPDATE stg_inspections 
SET grade = null
WHERE grade = '';

Select camis, dba, inspection_date_clean, score_clean, inspection_type from stg_inspections
where grade = 'C' AND inspection_type LIKE '%Initial Inspection%';


-- 16. CRITICAL FLAG
-- Values valid: Critical / Not Critical / Not Applicable, no blanks
-- Not Applicable = no violation, or codes 15-xx/16-xx (non-food-safety rules)
SELECT critical_flag, COUNT(violation_code) FROM stg_inspections
WHERE violation_code = ''
GROUP BY critical_flag;

SELECT critical_flag, COUNT(violation_code) FROM stg_inspections
GROUP BY critical_flag;

SELECT Count(*), violation_code, violation_description FROM stg_inspections
WHERE critical_flag like '%Not Appl%' AND violation_code <> ''
GROUP BY violation_code, violation_description
;

-- 17. LATITUDE / LONGITUDE
-- Text -> DECIMAL(9,6), blank and '0' -> NULL (4,719 rows, always both together)
-- Range checked: all coordinates within NYC

SELECT
  SUM(CASE WHEN latitude = '' THEN 1 ELSE 0 END) AS lat_blank,
  SUM(CASE WHEN latitude = '0' THEN 1 ELSE 0 END) AS lat_zero,
  SUM(CASE WHEN longitude = '' THEN 1 ELSE 0 END) AS long_blank,
  SUM(CASE WHEN longitude = '0' THEN 1 ELSE 0 END) AS long_zero,
  SUM(CASE WHEN longitude = '0' AND latitude = '0' THEN 1 ELSE 0 END) AS both_zero,
  SUM(CASE WHEN longitude = '' AND latitude = '' THEN 1 ELSE 0 END) AS both_blank
  FROM stg_inspections;

Alter TABLE stg_inspections ADD Column latitude_clean DECIMAL(9,6), 
	ADD Column longitude_clean DECIMAL(9,6);
	
UPDATE stg_inspections 
SET latitude_clean = CASE WHEN  
latitude = '0' OR latitude = '' THEN NULL 
ELSE latitude END,
longitude_clean = CASE WHEN
longitude = '0' OR longitude = '' THEN NULL 
ELSE longitude END;

SELECT MIN(longitude_clean) AS min_long, MAX(longitude_clean) AS max_long, 
 MIN(latitude_clean) AS min_lat, MAX(latitude_clean) AS max_lat,
 SUM(case when longitude_clean is null then 1 else 0 end) as long_null,
 SUM(case when latitude_clean is null then 1 else 0 end) as lat_null
FROM stg_inspections;


-- 18. DUPLICATES
-- 170 fully identical rows (duplicated in the source file)
-- Removed with SELECT DISTINCT into stg_dedup (294,950 -> 294,780)

SELECT camis, inspection_date_clean, violation_code,COUNT(*)
FROM stg_inspections
GROUP BY camis, inspection_date_clean, violation_code
HAVING COUNT(*) >1;

SELECT COUNT(*) FROM (
  SELECT DISTINCT
    camis, dba, boro, building, street, zipcode, phone,
    cuisine_description, inspection_date, action,
    violation_code, violation_description, critical_flag,
    score, grade, grade_date, record_date, inspection_type,
    latitude, longitude, community_board, council_district,
    census_tract, bin, bbl, nta, location_point,
    inspection_date_clean, restaurant_status, grade_date_clean,
    phone_clean, score_clean, latitude_clean, longitude_clean
  FROM stg_inspections
) AS t;


SELECT violation_code, LENGTH(violation_description), inspection_type, score from stg_inspections
WHERE camis = 40390409 AND inspection_date_clean = '2026-02-10';

DESCRIBE stg_inspections;

CREATE TABLE stg_dedup AS
SELECT DISTINCT camis, dba, boro, building, street, zipcode, phone,
    cuisine_description, inspection_date, action,
    violation_code, violation_description, critical_flag,
    score, grade, grade_date, record_date, inspection_type,
    latitude, longitude, community_board, council_district,
    census_tract, bin, bbl, nta, location_point,
    inspection_date_clean, restaurant_status, grade_date_clean,
    phone_clean, score_clean, latitude_clean, longitude_clean
FROM stg_inspections;

CREATE TABLE inspections_clean AS
SELECT DISTINCT camis, dba, boro, building, street, zipcode, phone_clean AS phone,
    cuisine_description, inspection_date_clean AS inspection_date, action,
    violation_code, violation_description, critical_flag,
    score_clean AS score, grade, grade_date_clean AS grade_date, record_date, inspection_type, 
    latitude_clean AS latitude, longitude_clean AS longitude, community_board, council_district,
    census_tract, bin, bbl, nta, location_point, restaurant_status
    FROM stg_dedup;
    
    
-- 19. STREET
-- Multiple spaces -> one space, all text -> UPPER
-- Removed junk symbols at start/end (e.g. '- JFK AIRPORT', '& GRAND CENTRAL')
-- Symbols inside kept (ST. MARK'S); typos like '0TH AVENUE' left as is

SELECT street, count(*) FROM inspections_clean
group by street;

UPDATE inspections_clean 
SET street = UPPER(REGEXP_REPLACE(street, ' +', ' '));

SELECT COUNT(*) FROM inspections_clean
WHERE street LIKE '%  %' OR street <> UPPER(street) COLLATE utf8mb4_bin;

SELECT street,
       REGEXP_REPLACE(street, '^[^A-Z0-9]+|[^A-Z0-9.]+$', '') AS street_new,
       COUNT(*)
FROM inspections_clean
WHERE street <> REGEXP_REPLACE(street, '^[^A-Z0-9]+|[^A-Z0-9.]+$', '')
GROUP BY street;

UPDATE inspections_clean
SET street = REGEXP_REPLACE(street, '^[^A-Z0-9]+|[^A-Z0-9.]+$', '');


-- 20. BUILDING / ZIPCODE
-- Blank -> NULL: building 940 rows, zipcode 3,091 rows

UPDATE inspections_clean 
SET building = (CASE WHEN building = '' THEN NULL ELSE building END),
zipcode = (CASE WHEN zipcode = '' THEN NULL ELSE zipcode END);

SELECT 
SUM(CASE WHEN building IS NULL THEN 1 ELSE 0 END) AS building_null,
SUM(CASE WHEN zipcode IS NULL THEN 1 ELSE 0 END) AS zipcode_null
FROM inspections_clean;

-- 21. BIN / BBL
-- Blank and placeholders (borough digit + zeros, e.g. 1000000, 3000000000) -> NULL
-- 7,832 rows changed
SELECT 
SUM(CASE WHEN bin = '' OR bin regexp '^[1-5]0*$' THEN 1 ELSE 0 END) AS bin,
SUM(CASE WHEN bbl = '' OR bbl regexp '^[1-5]0*$' THEN 1 ELSE 0 END) AS bbl FROM inspections_clean;

UPDATE inspections_clean
SET bin = (CASE WHEN bin = '' OR bin regexp '^[1-5]0*$' THEN NULL ELSE bin END),
bbl = (CASE WHEN bbl = '' OR bbl regexp '^[1-5]0*$' THEN NULL ELSE bbl END);

-- 22. COMMUNITY_BOARD / COUNCIL_DISTRICT / CENSUS_TRACT / NTA
-- Blank -> NULL (4,739 rows, mostly restaurants without coordinates)
UPDATE inspections_clean
SET community_board = (CASE WHEN community_board = '' THEN NULL ELSE community_board END),
	council_district = (CASE WHEN council_district = '' THEN NULL ELSE council_district END),
    census_tract = (CASE WHEN census_tract = '' THEN NULL ELSE census_tract END),
    nta = (CASE WHEN nta = '' THEN NULL ELSE nta END);
    
-- 23. FINAL COLUMNS
-- location_point dropped: duplicates latitude / longitude
-- record_date kept as DATE: dataset extract date (2026-09-24)
DESCRIBE inspections_clean;
ALTER TABLE inspections_clean DROP COLUMN location_point; 
ALTER TABLE inspections_clean MODIFY COLUMN record_date DATE;


-- 24. FINAL CHECK
-- 294,950 raw rows -> 294,780 clean rows (170 duplicates removed)
-- 31,335 restaurants, inspections 2007-08-10 to 2026-09-22
-- Missing values: NULL in numeric/date/code columns,
-- 'Unknown' in text categories (boro, cuisine_description)

SELECT COUNT(*), COUNT(DISTINCT camis), MIN(inspection_date), MAX(inspection_date),
	   SUM(CASE WHEN boro = 'Unknown' THEN 1 ELSE 0 END) AS boro_unknown,
	   SUM(CASE WHEN phone IS NULL THEN 1 ELSE 0 END) AS phone_null,
	   SUM(CASE WHEN score IS NULL THEN 1 ELSE 0 END) AS score_null,
	   SUM(CASE WHEN grade IS NULL THEN 1 ELSE 0 END) AS grade_null,
	   SUM(CASE WHEN latitude IS NULL THEN 1 ELSE 0 END) AS latitude_null
FROM inspections_clean;
       

        





