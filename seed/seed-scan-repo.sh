#!/bin/sh
# Seeds the "scan-repo" index with code-compliance scan findings.
# One document = one finding. Each finding carries repo metadata (branch,
# project, repoName) + the finding fields (endpoint, filename, line, reason,
# suggestion, severity) + a status of compliant | non_compliant.
# ES host is overridable so this can run from the host (localhost) or from
# inside the compose network (service name).
set -e

ES="${ES:-http://elasticsearch:9200}"
INDEX="scan-repo"

echo ">> (re)creating index '$INDEX' on $ES ..."
curl -s -o /dev/null -X DELETE "$ES/$INDEX"           # drop for idempotent re-runs
curl -s -o /dev/null -w "create index -> HTTP %{http_code}\n" \
  -X PUT "$ES/$INDEX" -H 'Content-Type: application/json' -d '{
  "mappings": {
    "properties": {
      "@timestamp":  { "type": "date" },
      "scan_id":     { "type": "keyword" },
      "status":      { "type": "keyword" },
      "severity":    { "type": "keyword" },
      "repoName":    { "type": "keyword" },
      "branch":      { "type": "keyword" },
      "project":     { "type": "keyword" },
      "http_method": { "type": "keyword" },
      "endpoint":    { "type": "keyword" },
      "filename":    { "type": "keyword" },
      "line":        { "type": "integer" },
      "reason":      { "type": "keyword" },
      "suggestion":  { "type": "text" }
    }
  }
}'

NOW=$(date -u +%s)
BULK=/tmp/scan-bulk.ndjson
: > "$BULK"
i=0

# add STATUS SEVERITY REPO BRANCH PROJECT METHOD ENDPOINT FILENAME LINE REASON SUGGESTION
add() {
  EPOCH=$(( NOW - i * 300 ))                            # one finding every 5 min going back
  TS=$(date -u -d "@$EPOCH" +"%Y-%m-%dT%H:%M:%SZ")
  SCAN="$3-$4"
  printf '{"index":{}}\n' >> "$BULK"
  printf '{"@timestamp":"%s","scan_id":"%s","status":"%s","severity":"%s","repoName":"%s","branch":"%s","project":"%s","http_method":"%s","endpoint":"%s","filename":"%s","line":%s,"reason":"%s","suggestion":"%s"}\n' \
    "$TS" "$SCAN" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" >> "$BULK"
  i=$(( i + 1 ))
}

# ---- payments-service / master ----
add non_compliant high   payments-service master   testing POST   "/api/payments"        PaymentController.java 88  "SQL injection"              "Use parameterized queries / prepared statements instead of string concatenation"
add non_compliant high   payments-service master   testing POST   "/api/payments/refund" PaymentController.java 142 "Hardcoded credentials"      "Move secrets to environment variables or a secrets manager"
add compliant     none   payments-service master   testing GET    "/api/payments/{id}"   PaymentController.java 51  "Parameterized query used"   "No action needed"
add compliant     none   payments-service master   testing GET    "/api/health"          HealthController.java  12  "Authentication enforced"    "No action needed"

# ---- auth-gateway / master ----
add non_compliant high   auth-gateway     master   testing POST   "/api/login"           AuthController.java    34  "Missing authentication"     "Require a valid session / JWT before processing this endpoint"
add non_compliant medium auth-gateway     master   testing POST   "/api/login"           AuthController.java    77  "Sensitive data in logs"     "Redact passwords and tokens before logging"
add compliant     none   auth-gateway     master   testing POST   "/api/logout"          AuthController.java    98  "Authentication enforced"    "No action needed"
add compliant     none   auth-gateway     master   testing GET    "/api/token/verify"    TokenService.java      23  "Input validated"            "No action needed"

# ---- auth-gateway / develop ----
add non_compliant high   auth-gateway     develop  testing POST   "/api/login"           AuthController.java    34  "SQL injection"              "Use parameterized queries / prepared statements instead of string concatenation"
add non_compliant low    auth-gateway     develop  testing POST   "/api/login"           AuthController.java    120 "Missing rate limiting"      "Add throttling / rate limiting to this endpoint"
add compliant     none   auth-gateway     develop  testing GET    "/api/token/verify"    TokenService.java      23  "Output properly encoded"    "No action needed"

# ---- user-profile-api / master ----
add non_compliant medium user-profile-api master   testing GET    "/api/users"           UserController.java    45  "Cross-site scripting (XSS)" "Encode user-controlled output and set a strict Content-Security-Policy"
add non_compliant high   user-profile-api master   testing GET    "/api/users"           UserRepository.java    203 "SQL injection"              "Use parameterized queries / prepared statements instead of string concatenation"
add compliant     none   user-profile-api master   testing PUT    "/api/users/{id}"      UserController.java    88  "Input validated"            "No action needed"
add compliant     none   user-profile-api master   testing DELETE "/api/users/{id}"      UserController.java    110 "Authentication enforced"    "No action needed"

# ---- inventory-service / master ----
add non_compliant high   inventory-service master  sandbox GET    "/api/files"           FileController.java    67  "Path traversal"             "Canonicalize and validate file paths against an allowlist"
add non_compliant medium inventory-service master  sandbox POST   "/api/inventory"       InventoryRepository.java 156 "Insecure deserialization" "Avoid native deserialization of untrusted input; use safe formats like JSON"
add compliant     none   inventory-service master  sandbox GET    "/api/inventory"       InventoryRepository.java 40  "Parameterized query used"   "No action needed"
add compliant     none   inventory-service master  sandbox GET    "/api/inventory/{id}"  InventoryController.java 58 "Input validated"            "No action needed"

# ---- notification-worker / develop ----
add non_compliant low    notification-worker develop sandbox POST "/api/notifications"   NotificationHandler.java 91 "Sensitive data in logs"    "Redact recipient PII before logging"
add compliant     none   notification-worker develop sandbox POST "/api/notifications"   NotificationHandler.java 44 "Output properly encoded"   "No action needed"
add compliant     none   notification-worker develop sandbox GET  "/api/notifications/status" NotificationHandler.java 60 "Authentication enforced" "No action needed"

echo ">> bulk indexing $i findings ..."
curl -s -o /dev/null -w "bulk -> HTTP %{http_code}\n" \
  -X POST "$ES/$INDEX/_bulk?refresh=true" \
  -H 'Content-Type: application/x-ndjson' \
  --data-binary "@$BULK"

echo ">> counts:"
echo "  total:         $(curl -s "$ES/$INDEX/_count" | grep -o '"count":[0-9]*')"
echo "  non_compliant: $(curl -s "$ES/$INDEX/_count?q=status:non_compliant" | grep -o '"count":[0-9]*')"
echo "  compliant:     $(curl -s "$ES/$INDEX/_count?q=status:compliant" | grep -o '"count":[0-9]*')"
