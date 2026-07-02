#!/bin/sh
# Creates the "logs" index with an explicit mapping, then bulk-loads sample
# documents with @timestamp values spread over the last ~100 minutes so they
# show up in Grafana's default "Last 6 hours" time range.
set -e

ES="http://elasticsearch:9200"
INDEX="logs"

echo ">> Creating index '$INDEX' ..."
# ignore 400 (index already exists) so re-runs don't fail
curl -s -o /dev/null -w "create index -> HTTP %{http_code}\n" \
  -X PUT "$ES/$INDEX" -H 'Content-Type: application/json' -d '{
  "mappings": {
    "properties": {
      "@timestamp":        { "type": "date" },
      "level":             { "type": "keyword" },
      "service":           { "type": "keyword" },
      "message":           { "type": "text" },
      "response_time_ms":  { "type": "integer" }
    }
  }
}'

echo ">> Building bulk payload ..."
NOW=$(date -u +%s)
LEVELS="INFO INFO INFO WARN ERROR DEBUG"
SERVICES="auth-api orders-api payments-api web-frontend"

BULK_FILE=/tmp/bulk.ndjson
: > "$BULK_FILE"

i=0
while [ "$i" -lt 60 ]; do
  EPOCH=$(( NOW - i * 100 ))                                   # one doc every 100s going back in time
  TS=$(date -u -d "@$EPOCH" +"%Y-%m-%dT%H:%M:%SZ")

  # rotate through levels / services deterministically
  lvl_idx=$(( i % 6 + 1 ));  LEVEL=$(echo $LEVELS   | cut -d' ' -f$lvl_idx)
  svc_idx=$(( i % 4 + 1 ));  SERVICE=$(echo $SERVICES | cut -d' ' -f$svc_idx)
  RT=$(( (i * 37) % 500 + 10 ))                                # pseudo-random response time

  printf '{"index":{}}\n' >> "$BULK_FILE"
  printf '{"@timestamp":"%s","level":"%s","service":"%s","message":"request handled by %s","response_time_ms":%s}\n' \
    "$TS" "$LEVEL" "$SERVICE" "$SERVICE" "$RT" >> "$BULK_FILE"

  i=$(( i + 1 ))
done

echo ">> Bulk indexing $((i)) documents ..."
curl -s -o /dev/null -w "bulk -> HTTP %{http_code}\n" \
  -X POST "$ES/$INDEX/_bulk?refresh=true" \
  -H 'Content-Type: application/x-ndjson' \
  --data-binary "@$BULK_FILE"

echo ">> Done. Document count:"
curl -s "$ES/$INDEX/_count"
echo ""
