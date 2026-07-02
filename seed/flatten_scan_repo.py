#!/usr/bin/env python3
"""ETL step: parse the nested 'scan-repo-nested' documents into a flat,
one-document-per-finding 'scan-repo' index that Grafana can aggregate.

For each source scan document it explodes both arrays:
  non_compliant[] -> N findings with status=non_compliant (keeps severity)
  compliant[]     -> M findings with status=compliant     (severity=none)

It also normalizes the raw fields into the dashboard's schema:
  Endpoint "POST /api/x"  ->  http_method="POST" + endpoint="/api/x"
  FileName -> filename,  Line -> line,  Reason -> reason,  Suggestion -> suggestion

Uses only the Python standard library (no pip installs), so it runs in a bare
python:3-alpine container. ES host is overridable via the ES env var.
"""
import json
import os
import urllib.request

ES = os.environ.get("ES", "http://elasticsearch:9200")
SRC = "scan-repo-nested"
DST = "scan-repo"

FLAT_MAPPING = {
    "mappings": {
        "properties": {
            "@timestamp":  {"type": "date"},
            "scan_id":     {"type": "keyword"},
            "status":      {"type": "keyword"},
            "severity":    {"type": "keyword"},
            "repoName":    {"type": "keyword"},
            "branch":      {"type": "keyword"},
            "project":     {"type": "keyword"},
            "http_method": {"type": "keyword"},
            "endpoint":    {"type": "keyword"},
            "filename":    {"type": "keyword"},
            "line":        {"type": "integer"},
            "reason":      {"type": "keyword"},
            "suggestion":  {"type": "text"},
        }
    }
}


def req(method, path, body=None, ctype="application/json"):
    data = body.encode() if isinstance(body, str) else body
    headers = {"Content-Type": ctype} if data is not None else {}
    r = urllib.request.Request(ES + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def parse_finding(meta, item, status, severity):
    """One raw finding object -> one flat document (renames + method/path split)."""
    method, _, path = (item.get("Endpoint") or "").partition(" ")
    if not path:            # no space -> treat whole value as the path
        method, path = "", method
    return {
        "@timestamp": meta["@timestamp"],
        "scan_id":   meta.get("scan_id"),
        "repoName":  meta.get("repoName"),
        "branch":    meta.get("branch"),
        "project":   meta.get("project"),
        "status":    status,
        "severity":  severity,
        "http_method": method,
        "endpoint":  path,
        "filename":  item.get("FileName"),
        "line":      item.get("Line"),
        "reason":    item.get("Reason"),
        "suggestion": item.get("Suggestion"),
    }


def main():
    # 1. (re)create the flat index
    req("DELETE", "/" + DST)
    req("PUT", "/" + DST, json.dumps(FLAT_MAPPING))

    # 2. read all nested scan documents
    _, body = req("GET", "/%s/_search?size=10000" % SRC,
                  json.dumps({"query": {"match_all": {}}}))
    hits = json.loads(body).get("hits", {}).get("hits", [])

    # 3. explode arrays -> per-finding bulk payload
    lines = []
    for h in hits:
        s = h["_source"]
        meta = {k: s.get(k) for k in ("@timestamp", "scan_id", "repoName", "branch", "project")}
        for item in (s.get("non_compliant") or []):
            doc = parse_finding(meta, item, "non_compliant", item.get("severity", "high"))
            lines.append(json.dumps({"index": {}}))
            lines.append(json.dumps(doc))
        for item in (s.get("compliant") or []):
            doc = parse_finding(meta, item, "compliant", "none")
            lines.append(json.dumps({"index": {}}))
            lines.append(json.dumps(doc))

    # 4. bulk index into the flat index
    status, _ = req("POST", "/%s/_bulk?refresh=true" % DST,
                    "\n".join(lines) + "\n", "application/x-ndjson")
    total = json.loads(req("GET", "/%s/_count" % DST)[1])["count"]
    nc = json.loads(req("GET", "/%s/_count?q=status:non_compliant" % DST)[1])["count"]
    print("flatten: %d source scans -> %d findings in '%s' "
          "(%d non_compliant) [bulk HTTP %d]" % (len(hits), total, DST, nc, status))


if __name__ == "__main__":
    main()
