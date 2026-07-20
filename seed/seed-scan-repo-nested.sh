#!/bin/sh
# Index 1 of 2: the REALISTIC source-of-truth shape.
# One document per repo scan. compliant / non_compliant are ARRAYS of objects
# with the fields you specified: Endpoint, FileName, Line, Reason, Suggestion
# (non_compliant also carries a severity). Stored as ES "object" (the default):
# ES flattens each array into multi-valued fields at the document level, which
# lets Grafana aggregate them directly (terms/value_count on non_compliant.*).
# This is what makes the aggregation panels work WITHOUT the old flatten ETL.
# object-flattening loses per-element correlation for the native ES datasource
# (a raw_data query returns each array as one JSON cell), so the two per-finding
# detail tables instead read _source via the Infinity datasource and explode the
# arrays into one row per finding with a JSONata root_selector.
set -e

ES="${ES:-http://elasticsearch:9200}"
INDEX="scan-repo-nested"

echo ">> (re)creating index '$INDEX' on $ES ..."
curl -s -o /dev/null -X DELETE "$ES/$INDEX"
curl -s -o /dev/null -w "create index -> HTTP %{http_code}\n" \
  -X PUT "$ES/$INDEX" -H 'Content-Type: application/json' -d '{
  "mappings": {
    "properties": {
      "@timestamp": { "type": "date" },
      "scan_id":    { "type": "keyword" },
      "repoName":   { "type": "keyword" },
      "branch":     { "type": "keyword" },
      "project":    { "type": "keyword" },
      "compliant": {
        "type": "object",
        "properties": {
          "Endpoint":   { "type": "keyword" },
          "FileName":   { "type": "keyword" },
          "Line":       { "type": "integer" },
          "Reason":     { "type": "keyword" },
          "Suggestion": { "type": "text" }
        }
      },
      "non_compliant": {
        "type": "object",
        "properties": {
          "Endpoint":   { "type": "keyword" },
          "FileName":   { "type": "keyword" },
          "Line":       { "type": "integer" },
          "Reason":     { "type": "keyword" },
          "Suggestion": { "type": "text" },
          "severity":   { "type": "keyword" }
        }
      }
    }
  }
}'

# spread each repo scan across the last few hours so the time series is meaningful
N=$(date -u +%s)
t() { date -u -d "@$(( N - $1 ))" +"%Y-%m-%dT%H:%M:%SZ"; }
TS0=$(t 600); TS1=$(t 3600); TS2=$(t 7200); TS3=$(t 10800); TS4=$(t 14400); TS5=$(t 18000)

cat > /tmp/nested-bulk.ndjson <<EOF
{"index":{}}
{"@timestamp":"$TS0","scan_id":"payments-service-master","repoName":"payments-service","branch":"master","project":"testing","non_compliant":[{"Endpoint":"POST /api/payments","FileName":"PaymentController.java","Line":88,"Reason":"SQL injection","Suggestion":"Use parameterized queries / prepared statements","severity":"high"},{"Endpoint":"POST /api/payments/refund","FileName":"PaymentController.java","Line":142,"Reason":"Hardcoded credentials","Suggestion":"Move secrets to a secrets manager","severity":"high"}],"compliant":[{"Endpoint":"GET /api/payments/{id}","FileName":"PaymentController.java","Line":51,"Reason":"Parameterized query used","Suggestion":"No action needed"},{"Endpoint":"GET /api/health","FileName":"HealthController.java","Line":12,"Reason":"Authentication enforced","Suggestion":"No action needed"}]}
{"index":{}}
{"@timestamp":"$TS1","scan_id":"auth-gateway-master","repoName":"auth-gateway","branch":"master","project":"testing","non_compliant":[{"Endpoint":"POST /api/login","FileName":"AuthController.java","Line":34,"Reason":"Missing authentication","Suggestion":"Require a valid session / JWT","severity":"high"},{"Endpoint":"POST /api/login","FileName":"AuthController.java","Line":77,"Reason":"Sensitive data in logs","Suggestion":"Redact passwords and tokens before logging","severity":"medium"}],"compliant":[{"Endpoint":"POST /api/logout","FileName":"AuthController.java","Line":98,"Reason":"Authentication enforced","Suggestion":"No action needed"}]}
{"index":{}}
{"@timestamp":"$TS2","scan_id":"auth-gateway-develop","repoName":"auth-gateway","branch":"develop","project":"testing","non_compliant":[{"Endpoint":"POST /api/login","FileName":"AuthController.java","Line":34,"Reason":"SQL injection","Suggestion":"Use parameterized queries / prepared statements","severity":"high"},{"Endpoint":"POST /api/login","FileName":"AuthController.java","Line":120,"Reason":"Missing rate limiting","Suggestion":"Add throttling / rate limiting","severity":"low"}],"compliant":[{"Endpoint":"GET /api/token/verify","FileName":"TokenService.java","Line":23,"Reason":"Output properly encoded","Suggestion":"No action needed"}]}
{"index":{}}
{"@timestamp":"$TS3","scan_id":"user-profile-api-master","repoName":"user-profile-api","branch":"master","project":"testing","non_compliant":[{"Endpoint":"GET /api/users","FileName":"UserRepository.java","Line":203,"Reason":"SQL injection","Suggestion":"Use parameterized queries / prepared statements","severity":"high"},{"Endpoint":"GET /api/users","FileName":"UserController.java","Line":45,"Reason":"Cross-site scripting (XSS)","Suggestion":"Encode output and set a strict CSP","severity":"medium"}],"compliant":[{"Endpoint":"PUT /api/users/{id}","FileName":"UserController.java","Line":88,"Reason":"Input validated","Suggestion":"No action needed"},{"Endpoint":"DELETE /api/users/{id}","FileName":"UserController.java","Line":110,"Reason":"Authentication enforced","Suggestion":"No action needed"}]}
{"index":{}}
{"@timestamp":"$TS4","scan_id":"inventory-service-master","repoName":"inventory-service","branch":"master","project":"sandbox","non_compliant":[{"Endpoint":"GET /api/files","FileName":"FileController.java","Line":67,"Reason":"Path traversal","Suggestion":"Canonicalize and validate paths against an allowlist","severity":"high"},{"Endpoint":"POST /api/inventory","FileName":"InventoryRepository.java","Line":156,"Reason":"Insecure deserialization","Suggestion":"Avoid native deserialization of untrusted input","severity":"medium"}],"compliant":[{"Endpoint":"GET /api/inventory","FileName":"InventoryRepository.java","Line":40,"Reason":"Parameterized query used","Suggestion":"No action needed"}]}
{"index":{}}
{"@timestamp":"$TS5","scan_id":"notification-worker-develop","repoName":"notification-worker","branch":"develop","project":"sandbox","non_compliant":[{"Endpoint":"POST /api/notifications","FileName":"NotificationHandler.java","Line":91,"Reason":"Sensitive data in logs","Suggestion":"Redact recipient PII before logging","severity":"low"}],"compliant":[{"Endpoint":"POST /api/notifications","FileName":"NotificationHandler.java","Line":44,"Reason":"Output properly encoded","Suggestion":"No action needed"},{"Endpoint":"GET /api/notifications/status","FileName":"NotificationHandler.java","Line":60,"Reason":"Authentication enforced","Suggestion":"No action needed"}]}
EOF

echo ">> bulk indexing nested scan documents ..."
curl -s -o /dev/null -w "bulk -> HTTP %{http_code}\n" \
  -X POST "$ES/$INDEX/_bulk?refresh=true" \
  -H 'Content-Type: application/x-ndjson' \
  --data-binary "@/tmp/nested-bulk.ndjson"

echo ">> nested scan doc count: $(curl -s "$ES/$INDEX/_count" | grep -o '"count":[0-9]*')"
