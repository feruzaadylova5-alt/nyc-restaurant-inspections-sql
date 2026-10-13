# NYC Restaurant Inspections: Data Cleaning in SQL

Cleaning the New York City restaurant inspection dataset with **MySQL**, turning a raw public export into an analysis-ready table.

## Dataset

- **Source:** [DOHMH New York City Restaurant Inspection Results](https://data.cityofnewyork.us/Health/DOHMH-New-York-City-Restaurant-Inspection-Results/43nn-yd6z), NYC Open Data
- **Extract date:** 2026-09-24
- **Size:** 294,950 rows, 27 columns (~155 MB CSV)
- **Grain:** one row = one violation found at one inspection of one restaurant

## Tools

MySQL 8 · MySQL Workbench · `LOAD DATA` · regular expressions · CTEs · window functions · `UPDATE ... JOIN`

## Approach

1. **Load** the CSV into `raw_inspections` with every column as text, so nothing is lost on import.
2. **Work on a copy.** The raw table is never changed.
3. **Profile each column** before changing it: counts, distinct values, blanks, outliers.
4. **Fix only what the data itself can justify.** Missing values are never invented.
5. **Verify every change** with a count before and after.

## Table flow

```
raw_inspections  →  stg_inspections  →  stg_dedup  →  inspections_clean
   (as loaded)       (column fixes)     (duplicates     (final table,
                                         removed)        clean names)
```

`zip_boro` is a helper lookup table (ZIP code → borough) used to recover missing boroughs.

## Cleaning steps

| # | Column | Problem found | Fix |
|---|---|---|---|
| 4 | `inspection_date` | Text `MM/DD/YYYY`; placeholder `01/01/1900` for restaurants never inspected (3,808 rows) | Converted to `DATE`; placeholder → `NULL` |
| 5, 7 | `restaurant_status` (new) | No way to tell inspected from not inspected | Flag: *Inspected* / *Not Inspected* / *No inspection since 2020* (188 restaurants) |
| 6, 8 | `grade_date`, `record_date` | Text dates | Converted to `DATE` |
| 9, 10 | `boro` | Invalid value `'0'` (340 rows); 7 LaGuardia Airport rows (ZIP 11371) labeled Manhattan | `'0'` → `'Unknown'`; LaGuardia rows → Queens |
| 11 | `boro` | `'Unknown'` rows that still had an NYC ZIP code | Recovered 50 rows through the `zip_boro` lookup; 290 rows stay `'Unknown'` (out-of-city ZIP or none) |
| 12 | `cuisine_description` | 3,888 blanks, almost all never-inspected restaurants | → `'Unknown'` |
| 13 | `phone` | Brackets, dashes, leading country code `1`, `0000000000` | Digits only, standardized to 10 digits; invalid → `NULL` |
| 14 | `score` | Text; blanks | Converted to `INT`; blank → `NULL`. High scores (up to 214) checked and kept as real |
| 15 | `grade` | ~150k blanks | → `NULL`. Expected: grades are issued only on cycle inspections scoring A, or at re-inspection |
| 16 | `critical_flag` | — | Validated: *Not Applicable* = no violation, or codes 15-xx / 16-xx (smoking, nutrition labeling) |
| 17 | `latitude`, `longitude` | Blanks and `0` (4,719 rows, always together) | Converted to `DECIMAL(9,6)`; missing → `NULL`. All values checked to fall within NYC |
| 18 | whole row | 170 fully identical rows, duplicated in the source file (checked on all columns except the technical `row_id`) | Removed with `SELECT DISTINCT` (294,950 → 294,780) |
| 19 | `street` | Double spaces (~39k rows), mixed case, junk symbols at the edges (`- JFK AIRPORT`) | Single spaces, uppercase, edge symbols removed |
| 20 | `building`, `zipcode` | Blanks (940 / 3,091 rows) | → `NULL` |
| 21 | `bin`, `bbl` | Blanks and placeholders (borough digit + zeros, e.g. `1000000`) | → `NULL` (7,832 rows) |
| 22 | `community_board`, `council_district`, `census_tract`, `nta` | Blanks | → `NULL` (4,739 rows) |
| 23 | `location_point` | Duplicates latitude / longitude | Column dropped |

## Result

| | Before | After |
|---|---|---|
| Rows | 294,950 | 294,780 |
| Restaurants | 31,335 | 31,335 |
| Inspection dates | text, with 1900 placeholder | `DATE`, 2007-08-10 to 2026-09-22 |
| Data types | all text | `DATE`, `INT`, `DECIMAL` where needed |

**Missing values rule:** `NULL` in numeric, date and code columns; `'Unknown'` in text categories (`boro`, `cuisine_description`) so they stay visible in dashboards.

## Notable findings

- **Grades are not given at every inspection.** At an initial inspection a restaurant is graded only if it scores A (0–13); otherwise the grade comes at re-inspection.
- **2,462 cycle initial inspections scored 0–13 but have no grade.** By the rules they should be A. Left as `NULL` rather than guessed.
- **Closures don't depend on the score.** A restaurant can be closed with a low score (one public health hazard) or stay open with a very high one.

## How to reproduce

1. Download the CSV from the NYC Open Data link above.
2. In `nyc_inspections_cleaning.sql`, replace `path/to/NYC_Restaurant_Inspection.csv` with your file path.
3. Make sure `local_infile` is allowed on both the MySQL server and the Workbench connection (*Advanced → Others: `OPT_LOCAL_INFILE=1`*).
4. Run the script top to bottom.

The CSV itself is not included in this repository (over GitHub's 100 MB file limit).

## Files

- `nyc_inspections_cleaning.sql`: full cleaning script, step by step with comments
- `README.md`: this file
