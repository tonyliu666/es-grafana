# Design: Replace the es-flatten ETL with Grafana-side flattening

**Date:** 2026-07-20
**Status:** Approved

## Goal

Drop the `es-flatten` Python ETL stage from `docker-compose.yml`. Feed the **raw
nested** `scan-repo-nested` documents straight to Grafana and reproduce the
current "Repo Compliance Scan" dashboard as faithfully as possible using Grafana
queries + transformations, with no per-finding flat index.

## Empirical constraints (tested against the live stack, 2026-07-20)

Two Grafana 10.4 limits are hard and cannot be worked around with transformations:

1. **The native ES datasource cannot array-explode.** A `raw_data` query returns
   each `compliant` / `non_compliant` array as a *single cell* (frame field type
   `other`) holding the whole array. No transformation turns `[{...},{...}]` into
   N rows. This is worked around with the **Infinity datasource** (see below),
   not with a transformation.
2. **`nested`-typed fields are invisible to normal aggregations.** A plain
   `terms` agg on `non_compliant.Reason` over the current `nested` mapping
   returns **empty**. All six aggregation panels would be blank.

Both are resolved (for aggregations) by changing the mapping from `nested` to
plain `object`. This does **not** change the stored JSON documents at all — the
same raw arrays are sent to Grafana — it only changes how Elasticsearch indexes
them, so it honours "keep the raw data".

### Metric accuracy (measured)

- `value_count(non_compliant.Reason)` with **no** terms bucket = **exact** finding
  count (11 non-compliant). Grafana passes `value_count` through fine.
- `count` under `terms(non_compliant.Reason)` = exact per-reason counts (sum 11).
- `count` under `terms(non_compliant.severity)` = 5/3/2 — a minor undercount vs
  the true 6/3/2, because one scan holds two `high` findings and `doc_count`
  counts that scan once. Acceptable, documented discrepancy.
- `value_count` **under** a terms bucket over-counts (9/6/3) — do **not** use it
  split by a multi-valued field.

## Changes

### 1. docker-compose.yml
- Remove the `es-flatten` service entirely (and its `depends_on` edges).
- `es-seed` still seeds `logs` + `scan-repo-nested`.

### 2. seed/seed-scan-repo-nested.sh
- Change `"type": "nested"` → `"type": "object"` for both `compliant` and
  `non_compliant`. Documents are unchanged.

### 3. seed/flatten_scan_repo.py
- Delete (no longer used).

### 4. grafana/provisioning/datasources/elasticsearch.yml
- Repoint the `es-scan-repo` datasource from index `scan-repo` →
  `scan-repo-nested`. Keep the `es-scan-repo` uid so the dashboard resolves.

### 5. grafana/dashboards/scan-repo-dashboard.json
Rebuild each panel against the nested arrays:

| Panel | Approach |
|-------|----------|
| Total findings (stat) | two targets `value_count(non_compliant.Reason)` + `value_count(compliant.Reason)`, summed via transform |
| Non-compliant (stat) | `value_count(non_compliant.Reason)` |
| Compliant (stat) | `value_count(compliant.Reason)` |
| Compliant vs non-compliant (pie) | two `value_count` targets, one per array |
| Non-compliant by reason (bar) | `count` bucketed `terms(non_compliant.Reason)` |
| Findings by repo, compliant vs non (bar) | two targets (`value_count` per array) × `terms(repoName)`, merged into a matrix by transform |
| Findings over time by severity (timeseries) | `count` bucketed `terms(non_compliant.severity)` + `date_histogram` |
| Non-compliant findings (table) | **Infinity** datasource; JSONata `root_selector` explodes `non_compliant` into **one row per finding** |
| Compliant findings (table) | **Infinity** datasource; JSONata `root_selector` explodes `compliant` into **one row per finding** |

The template variables (`project`, `repo`, `branch`) still work — the
aggregation panels aggregate on the top-level `project` / `repoName` / `branch`
keyword fields, and the Infinity tables interpolate them into the `query_string`
of the `_search` body (`${project:lucene}` etc.) plus the dashboard time range
into the `@timestamp` range (`${__from:date:iso}` / `${__to:date:iso}`).

### Detail tables via the Infinity datasource

The two per-finding tables use the `yesoreyeram-infinity-datasource` plugin
(installed via `GF_INSTALL_PLUGINS`, provisioned as uid `es-infinity` against the
same ES cluster). Each panel target:

- `type: json`, `parser: backend`, `source: url`, `format: table`
- POSTs the ES query DSL body to `.../scan-repo-nested/_search`
- `root_selector` is a JSONata expression that maps over `hits.hits`, binds
  `_source` to `$s`, and explodes the array while carrying the parent fields
  (`@timestamp` → `Time`, `repoName`, `branch`, `project`) onto each finding.
  It is guarded with `$count(hits.hits) > 0 ? … : []` so an empty result set
  renders a clean "No data" instead of a JSONata evaluation error.
- explicit `columns` fix each column's type (`Time`→timestamp, `Line`→number);
  an `organize` transform sets the per-finding column order.

## Accepted losses

- By-severity / by-repo counts undercount by 1 where a single scan repeats a
  value. Totals and by-reason remain exact.

The detail tables are **not** a loss: the Infinity datasource reproduces the
original one-row-per-finding view while ES keeps the raw nested documents.

## Verification

Bring the stack up without `es-flatten`, then confirm via Grafana's
`/api/ds/query` that each panel's target returns the expected numbers, and load
the dashboard in the browser.
