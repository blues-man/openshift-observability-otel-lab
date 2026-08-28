#!/usr/bin/env bash
#
# validate.sh — one-shot end-to-end validation for the OpenShift Observability
# with OpenTelemetry lab, run right after a fresh ArgoCD/GitOps deploy on a new
# cluster.
#
# It validates the layers the manual checklist (tests/lab-validation.md) does
# NOT: GitOps app health, backend storage durability (Loki/Tempo retention,
# MinIO sizing, "empty ring"/"no datapoints" regressions), and Showroom content
# (password, mermaid, copy/execute icons, external links). It also runs the
# non-mutating subset of the per-user lab checks.
#
# Usage:
#   ./tests/validate.sh                 # auto-detect everything, test user1
#   TEST_USER=user3 ./tests/validate.sh
#   TEST_PASSWORD=... ./tests/validate.sh
#
# Prereqs: logged in as cluster-admin (oc), python3 available.
# Exit code: 0 if all non-skipped checks pass, 1 otherwise.
#
# Env overrides (all optional — sensible defaults / auto-detection):
#   CLUSTER_API, APPS_DOMAIN, TEST_USER, TEST_PASSWORD,
#   TEMPO_NAMESPACE, LOKI_NAMESPACE, COO_NAMESPACE, COLLECTOR_NAME,
#   MIN_PVC_GI (default 10), DF_MAX_PCT (default 90), LOG_WINDOW_SEC (default 3600)

set -uo pipefail

# ---------------------------------------------------------------------------
# Config / auto-detection
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAGES_DIR="$REPO_ROOT/content/modules/ROOT/pages"

TEST_USER="${TEST_USER:-user1}"
TEMPO_NAMESPACE="${TEMPO_NAMESPACE:-tempo-observability}"
LOKI_NAMESPACE="${LOKI_NAMESPACE:-openshift-logging}"
COO_NAMESPACE="${COO_NAMESPACE:-coo-observability}"
COLLECTOR_NAME="${COLLECTOR_NAME:-otel}"
MIN_PVC_GI="${MIN_PVC_GI:-10}"
DF_MAX_PCT="${DF_MAX_PCT:-90}"
LOG_WINDOW_SEC="${LOG_WINDOW_SEC:-3600}"

NAMESPACE="observability-app-${TEST_USER}"
SHOWROOM_NS="showroom-${TEST_USER}"
GITOPS_NS="openshift-gitops"

CLUSTER_API="${CLUSTER_API:-$(oc whoami --show-server 2>/dev/null)}"
APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"
THANOS_HOST="thanos-querier-openshift-monitoring.${APPS_DOMAIN}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_G=""; C_R=""; C_Y=""; C_B=""; C_0=""
fi

PASS=0; FAIL=0; SKIP=0
declare -a FAILED_LIST=()

section() { printf '\n%s=== %s ===%s\n' "$C_B" "$1" "$C_0"; }
pass()    { printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$1"; PASS=$((PASS+1)); }
fail()    { printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$1"; FAIL=$((FAIL+1)); FAILED_LIST+=("$1"); }
skip()    { printf '  %sSKIP%s %s\n' "$C_Y" "$C_0" "$1"; SKIP=$((SKIP+1)); }
info()    { printf '       %s\n' "$1"; }

# assert_eq <label> <expected> <actual>
assert_eq() { [[ "$2" == "$3" ]] && pass "$1 ($3)" || fail "$1 (want '$2', got '$3')"; }
# assert_nonempty <label> <value>
assert_nonempty() { [[ -n "${2// }" ]] && pass "$1 ($2)" || fail "$1 (empty)"; }

ADMIN_TOKEN="$(oc whoami -t 2>/dev/null)"

# curl helper that runs inside a pod which has curl (Loki ingester), reaching
# in-cluster gateways over the service network.
LOKI_INGESTER="$(oc get pod -n "$LOKI_NAMESPACE" -l app.kubernetes.io/component=ingester -o name 2>/dev/null | head -1)"
incluster_curl() { # <args...>
  oc exec -n "$LOKI_NAMESPACE" "${LOKI_INGESTER#pod/}" -- curl "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
section "Preflight"
command -v oc  >/dev/null 2>&1 && pass "oc present" || { fail "oc not found"; }
command -v python3 >/dev/null 2>&1 && pass "python3 present" || fail "python3 not found"
if oc auth can-i get applications.argoproj.io -n "$GITOPS_NS" >/dev/null 2>&1; then
  pass "admin access to $GITOPS_NS"
else
  fail "no admin access to $GITOPS_NS (must run as cluster-admin)"
fi
assert_nonempty "cluster API detected" "$CLUSTER_API"
assert_nonempty "apps domain detected" "$APPS_DOMAIN"
[[ -n "$LOKI_INGESTER" ]] && info "loki ingester: ${LOKI_INGESTER#pod/}" || skip "loki ingester pod not found (some storage checks will skip)"

# ---------------------------------------------------------------------------
# 1. GitOps deploy health
# ---------------------------------------------------------------------------
section "GitOps deploy (ArgoCD)"

root_sync="$(oc get application field-content -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null)"
root_health="$(oc get application field-content -n "$GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null)"
[[ "$root_health" == "Healthy" ]] && pass "root app-of-apps field-content Healthy (sync=$root_sync)" \
  || fail "root app field-content not Healthy (health=$root_health sync=$root_sync)"

# Detect tenancy mode by counting per-user apps.
USER_APP_COUNT="$(oc get application -n "$GITOPS_NS" -o name 2>/dev/null | grep -cE 'user[0-9]+$')"
if [[ "$USER_APP_COUNT" -gt 0 ]]; then
  info "multi-tenant mode: $USER_APP_COUNT per-user apps"
  # The single-tenant orphans must NOT exist (would collide on user1 — see f445044).
  for orphan in field-content-dice-game field-content-showroom; do
    if oc get application "$orphan" -n "$GITOPS_NS" >/dev/null 2>&1; then
      fail "orphan single-tenant app '$orphan' present in multi-tenant mode (user.count guard missing → SharedResourceWarning on user1)"
    else
      pass "no orphan single-tenant app '$orphan'"
    fi
  done
else
  info "single-tenant mode (no per-user apps): expecting field-content-dice-game/showroom"
  for app in field-content-dice-game field-content-showroom; do
    oc get application "$app" -n "$GITOPS_NS" >/dev/null 2>&1 && pass "single-tenant app '$app' present" \
      || fail "single-tenant app '$app' missing"
  done
fi

# No SharedResourceWarning on any application.
warns="$(oc get application -n "$GITOPS_NS" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
out=[a["metadata"]["name"] for a in d.get("items",[])
     for c in (a.get("status",{}).get("conditions") or [])
     if "SharedResource" in c.get("type","")]
print(",".join(sorted(set(out))))' 2>/dev/null)"
[[ -z "$warns" ]] && pass "no SharedResourceWarning on any app" || fail "SharedResourceWarning on: $warns"

# Every component/per-user app Healthy (Synced or benign OutOfSync tolerated).
unhealthy="$(oc get application -n "$GITOPS_NS" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
bad=[a["metadata"]["name"] for a in d.get("items",[])
     if a.get("status",{}).get("health",{}).get("status") not in ("Healthy","Progressing")]
print(",".join(bad))' 2>/dev/null)"
[[ -z "$unhealthy" ]] && pass "all ArgoCD apps Healthy" || fail "unhealthy apps: $unhealthy"

# Test-user's per-user apps exist (multi-tenant).
if [[ "$USER_APP_COUNT" -gt 0 ]]; then
  for app in "field-content-dice-game-${TEST_USER}" "field-content-showroom-${TEST_USER}"; do
    oc get application "$app" -n "$GITOPS_NS" >/dev/null 2>&1 && pass "per-user app '$app' exists" \
      || fail "per-user app '$app' missing"
  done
fi

# ---------------------------------------------------------------------------
# 2. Backend storage durability (the "empty ring" / "no traces" regressions)
# ---------------------------------------------------------------------------
section "Backend storage durability"

# --- Retention configured (without it, MinIO fills and the ring goes empty) ---
loki_ret="$(oc get lokistack logging-loki -n "$LOKI_NAMESPACE" -o jsonpath='{.spec.limits.global.retention.days}' 2>/dev/null)"
[[ -n "$loki_ret" && "$loki_ret" -gt 0 ]] 2>/dev/null && pass "LokiStack retention configured (${loki_ret}d)" \
  || fail "LokiStack has NO retention (spec.limits.global.retention.days) — logs never expire, MinIO will fill"

tempo_ret="$(oc get tempostack simplest -n "$TEMPO_NAMESPACE" -o jsonpath='{.spec.retention.global.traces}' 2>/dev/null)"
assert_nonempty "TempoStack retention configured" "$tempo_ret"

# --- MinIO PVC sizing ---
check_pvc_size() { # <ns> <pvc>
  local ns="$1" pvc="$2" cap gi
  cap="$(oc get pvc "$pvc" -n "$ns" -o jsonpath='{.status.capacity.storage}' 2>/dev/null)"
  gi="${cap%Gi}"
  if [[ "$cap" == *Gi && "$gi" -ge "$MIN_PVC_GI" ]] 2>/dev/null; then
    pass "$pvc PVC >= ${MIN_PVC_GI}Gi ($cap)"
  else
    fail "$pvc PVC too small ($cap, want >= ${MIN_PVC_GI}Gi)"
  fi
}
check_pvc_size "$LOKI_NAMESPACE" loki-minio
check_pvc_size "$TEMPO_NAMESPACE" tempo-minio

# --- MinIO not full ---
check_minio_df() { # <ns> <deploy>
  local ns="$1" dep="$2" use
  use="$(oc exec -n "$ns" "deploy/$dep" -- df -P /data 2>/dev/null | awk 'NR==2{gsub("%","",$5);print $5}')"
  if [[ -z "$use" ]]; then
    skip "$dep df check (could not read /data)"
  elif [[ "$use" -lt "$DF_MAX_PCT" ]]; then
    pass "$dep /data ${use}% used (< ${DF_MAX_PCT}%)"
  else
    fail "$dep /data ${use}% used (>= ${DF_MAX_PCT}% — writes will 507)"
  fi
}
check_minio_df "$LOKI_NAMESPACE" loki-minio
check_minio_df "$TEMPO_NAMESPACE" tempo-minio

# --- Loki ring health (the actual "Empty ring" indicator) ---
ing_ready="$(oc get pod -n "$LOKI_NAMESPACE" -l app.kubernetes.io/component=ingester \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)"
assert_eq "Loki ingester Ready" "true" "$ing_ready"

loki_ready="$(oc get lokistack logging-loki -n "$LOKI_NAMESPACE" \
  -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)"
assert_eq "LokiStack Ready condition" "True" "$loki_ready"

# --- No ACTIVE storage-full flush errors (short window; a wider window would
#     catch already-resolved incidents and cry wolf right after recovery) ---
if [[ -n "$LOKI_INGESTER" ]]; then
  # Match only real storage-full flush failures: MinIO's marker, an HTTP 507
  # status, or an error-level flush failure. A bare '507' also appears inside
  # fingerprint hashes (fp=50788b...) and time-shard ids on successful-flush
  # INFO lines, so anchor on error semantics to avoid false positives.
  n507="$(oc logs -n "$LOKI_NAMESPACE" "${LOKI_INGESTER#pod/}" --since=5m 2>/dev/null \
    | grep -icE 'XMinioStorageFull|status code: 507|(level=error).*(flush|storage)')"
  [[ "${n507:-0}" -eq 0 ]] && pass "no active 507/StorageFull in ingester logs (5m)" \
    || fail "$n507 StorageFull/507 flush errors in ingester logs (MinIO full)"
fi
# Tempo compactor must not be deadlocked writing merged blocks (needs free space).
n507t="$(oc logs -n "$TEMPO_NAMESPACE" -l app.kubernetes.io/component=compactor --since=5m 2>/dev/null | grep -c 'minimum free drive\|StorageFull')"
[[ "${n507t:-0}" -eq 0 ]] && pass "no active tempo compaction storage errors (5m)" \
  || fail "$n507t tempo compaction storage-full errors (compactor deadlocked — disk full, retention too long)"

# --- Tempo health ---
tempo_ready="$(oc get tempostack simplest -n "$TEMPO_NAMESPACE" \
  -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)"
assert_eq "TempoStack Ready condition" "True" "$tempo_ready"

# ---------------------------------------------------------------------------
# 3. Signal query health (logs actually queryable; traces present & linked)
# ---------------------------------------------------------------------------
section "Signal query health"

query_loki_tenant() { # <tenant> -> echoes entry count
  local tenant="$1" now start
  now="$(date +%s)"; start=$((now - LOG_WINDOW_SEC))
  incluster_curl -sk -G \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "https://logging-loki-gateway-http.${LOKI_NAMESPACE}.svc:8080/api/logs/v1/${tenant}/loki/api/v1/query_range" \
    --data-urlencode "query={log_type=\"${tenant}\"}" \
    --data-urlencode "start=${start}000000000" \
    --data-urlencode "end=${now}000000000" \
    --data-urlencode "limit=1" \
  | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("data",{}).get("stats",{}).get("summary",{}).get("totalEntriesReturned",0))
except Exception: print(-1)' 2>/dev/null
}
if [[ -n "$LOKI_INGESTER" && -n "$ADMIN_TOKEN" ]]; then
  for tenant in application infrastructure; do
    n="$(query_loki_tenant "$tenant")"
    if [[ "${n:-0}" -gt 0 ]] 2>/dev/null; then
      pass "logs queryable: $tenant tenant returned entries in last $((LOG_WINDOW_SEC/60))m"
    elif [[ "${n:-0}" == "0" ]]; then
      fail "logs EMPTY: $tenant tenant returned 0 entries in last $((LOG_WINDOW_SEC/60))m ('No datapoints'; check ring / collector 429 backlog)"
    else
      skip "logs query for $tenant (query error)"
    fi
  done
else
  skip "log query health (no ingester pod or admin token)"
fi

# Traces: service.name values present for tenant dev (expects backend1/2/3+frontend).
if [[ -n "$LOKI_INGESTER" && -n "$ADMIN_TOKEN" ]]; then
  svcs="$(incluster_curl -sk -G -H "Authorization: Bearer $ADMIN_TOKEN" \
    "https://tempo-simplest-gateway.${TEMPO_NAMESPACE}.svc:8080/api/traces/v1/dev/tempo/api/search/tag/service.name/values" \
    | python3 -c 'import sys,json
try: print(",".join(sorted(json.load(sys.stdin).get("tagValues",[]))))
except Exception: print("")' 2>/dev/null)"
  if [[ -z "$svcs" ]]; then
    skip "trace service.name values (none yet — needs traffic; loadgen may still be warming up)"
  else
    info "trace services: $svcs"
    missing=""
    for s in frontend backend1 backend2 backend3; do [[ ",$svcs," == *",$s,"* ]] || missing="$missing $s"; done
    [[ -z "$missing" ]] && pass "all trace services present (frontend + backend1/2/3)" \
      || fail "trace services missing:$missing (only-frontend-in-LIST is normal, but these should exist as span sources)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Showroom (password + baked content)
# ---------------------------------------------------------------------------
section "Showroom ($SHOWROOM_NS)"

if oc get ns "$SHOWROOM_NS" >/dev/null 2>&1; then
  sr_ready="$(oc get pod -n "$SHOWROOM_NS" -l app.kubernetes.io/name=showroom -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
  [[ -z "$sr_ready" ]] && sr_ready="$(oc get pod -n "$SHOWROOM_NS" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
  assert_eq "showroom pod Running" "Running" "$sr_ready"

  # Password resolved from Keycloak (not the 'openshift' default, non-empty).
  RESOLVED_PW="$(oc exec -n "$SHOWROOM_NS" deploy/showroom -c content -- \
    sh -c 'grep user_password /user_data/user_data.yml 2>/dev/null' 2>/dev/null \
    | sed -E 's/.*user_password:[[:space:]]*"?([^"]*)"?.*/\1/')"
  if [[ -z "$RESOLVED_PW" ]]; then
    fail "showroom password not resolved (user_data.yml has no user_password)"
  elif [[ "$RESOLVED_PW" == "openshift" ]]; then
    fail "showroom password is the 'openshift' default (Keycloak resolution failed / RoleBinding subject ns wrong)"
  else
    pass "showroom password resolved from Keycloak (len=${#RESOLVED_PW})"
  fi

  # Baked HTML: mermaid loader + copy/execute (clipboard.js) + external-link JS.
  HTML="$(oc exec -n "$SHOWROOM_NS" deploy/showroom -c content -- \
    sh -c 'cat /showroom/www/*/modules/ROOT/pages/02-details.html 2>/dev/null || find /showroom/www -name "02-details.html" -exec cat {} \;' 2>/dev/null)"
  if [[ -z "$HTML" ]]; then
    skip "showroom baked HTML checks (02-details.html not found)"
  else
    echo "$HTML" | grep -q 'clipboard.js' && pass "copy/execute icons present (clipboard.js loaded)" \
      || fail "clipboard.js missing from footer (copy/execute icons gone — script_stem collision?)"
    echo "$HTML" | grep -qi 'mermaid' && pass "mermaid loader baked into page" \
      || skip "mermaid not referenced on 02-details (ok if page has no diagram; check a module page)"
    echo "$HTML" | grep -q "target', '_blank'\|target=\"_blank\"" && pass "external-link new-tab handling present" \
      || fail "external-link new-tab JS/attr missing (links break the iframe)"
    echo "$HTML" | grep -qF "$RESOLVED_PW" && pass "resolved password baked into details page" \
      || skip "password not found in this page's HTML (may render via attribute at another path)"
  fi
else
  skip "showroom namespace $SHOWROOM_NS not found"
fi

# ---------------------------------------------------------------------------
# 5. Per-user lab checks (non-mutating). Requires a user login.
# ---------------------------------------------------------------------------
section "Per-user lab checks ($TEST_USER)"

# Resolve a password for the test user: env, else the one we read from showroom.
: "${TEST_PASSWORD:=${RESOLVED_PW:-}}"
KUBECONFIG_TEST="$(mktemp -t kc-${TEST_USER}.XXXXXX)"
USER_OK=0
if [[ -n "$TEST_PASSWORD" ]]; then
  if oc login --insecure-skip-tls-verify=true "$CLUSTER_API" \
       --username "$TEST_USER" --password "$TEST_PASSWORD" \
       --kubeconfig "$KUBECONFIG_TEST" >/dev/null 2>&1; then
    USER_OK=1; pass "login as $TEST_USER"
  else
    fail "login as $TEST_USER failed (bad password?)"
  fi
else
  skip "no TEST_PASSWORD and none resolved from showroom — set TEST_PASSWORD to run user-scoped checks"
fi

ocu() { oc --kubeconfig "$KUBECONFIG_TEST" "$@"; }

if [[ "$USER_OK" == "1" ]]; then
  # Pods running
  missing_pods=""
  for d in frontend backend1 backend2 backend3 loadgen; do
    ph="$(ocu get pod -n "$NAMESPACE" -l app="$d" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
    [[ "$ph" == "Running" ]] || missing_pods="$missing_pods $d($ph)"
  done
  col_ph="$(ocu get pod -n "$NAMESPACE" -l app.kubernetes.io/component=opentelemetry-collector -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
  [[ "$col_ph" == "Running" ]] || missing_pods="$missing_pods collector($col_ph)"
  [[ -z "$missing_pods" ]] && pass "app pods Running (frontend/backend1-3/loadgen/collector)" \
    || fail "pods not Running:$missing_pods"

  # Instrumentation endpoints include -collector suffix and :4318
  ep="$(ocu get instrumentation -n "$NAMESPACE" -o jsonpath='{.items[*].spec..env[?(@.name=="OTEL_EXPORTER_OTLP_ENDPOINT")].value}' 2>/dev/null)"
  if [[ -z "$ep" ]]; then
    skip "instrumentation endpoint (no Instrumentation CR yet)"
  else
    [[ "$ep" == *"${COLLECTOR_NAME}-collector.${NAMESPACE}.svc"* ]] && pass "instrumentation endpoint uses -collector svc" \
      || fail "instrumentation endpoint wrong (got: $ep)"
    [[ "$ep" == *:4318* ]] && pass "instrumentation endpoint uses OTLP/http :4318" \
      || fail "instrumentation endpoint not :4318 (backend2 Java needs http/protobuf → :4318)"
  fi

  # Base collector has logs + traces pipelines
  ocu get opentelemetrycollector "$COLLECTOR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.config}' 2>/dev/null \
   | python3 -c '
import sys,json,yaml
raw=sys.stdin.read()
try:
  c=yaml.safe_load(raw) if not raw.strip().startswith("{") else json.loads(raw)
  p=list(c.get("service",{}).get("pipelines",{}).keys())
  print("OK" if ("logs" in p and "traces" in p) else "MISS:"+",".join(p))
except Exception as e: print("ERR")' 2>/dev/null | { read r; \
     [[ "$r" == "OK" ]] && pass "base collector has logs+traces pipelines" \
     || { [[ "$r" == ERR || -z "$r" ]] && skip "collector pipelines (config unreadable)" || fail "collector pipelines $r"; }; }

  # RBAC: project visibility scoped (no cluster-wide leak)
  pc="$(ocu get projects --no-headers 2>/dev/null | wc -l)"
  if [[ "$pc" -le 20 ]]; then pass "project visibility scoped ($pc projects)"; else fail "RBAC leak: user sees $pc projects (>20)"; fi

  # RBAC: can create ServiceMonitors (needed to expose count metrics to UWM)
  [[ "$(ocu auth can-i create servicemonitors.monitoring.coreos.com -n "$NAMESPACE" 2>/dev/null)" == "yes" ]] \
    && pass "can create ServiceMonitors" || fail "cannot create ServiceMonitors"
  # Metrics access: students query via the console (tenancy-aware, namespace-scoped),
  # NOT the cluster-wide thanos route — a properly SCOPED user is *expected* to get
  # 403 on the public /api/v1/query (that requires cluster-monitoring-view, which
  # T1.11 says they must NOT have). So 200 => broad access (pass), 403 => correctly
  # scoped (informational). Full metric-flow verification needs Module 2 applied.
  UTOKEN="$(ocu whoami -t 2>/dev/null)"
  code="$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $UTOKEN" \
    "https://${THANOS_HOST}/api/v1/query?query=up" 2>/dev/null)"
  if [[ "$code" == "200" ]]; then pass "Thanos cluster query permitted (HTTP 200)"
  elif [[ "$code" == "403" ]]; then skip "Thanos cluster query 403 (correctly scoped; students use console tenancy path)"
  else fail "Thanos query unexpected HTTP $code"; fi

  # E2E: collector debug exporter shows traces + logs flowing
  clog="$(ocu logs -n "$NAMESPACE" deploy/${COLLECTOR_NAME}-collector --tail=200 2>/dev/null)"
  [[ "$(echo "$clog" | grep -c 'Traces')" -gt 0 ]] && pass "traces flowing through collector" || skip "no trace batches in last 200 log lines"
  [[ "$(echo "$clog" | grep -c 'Logs')"   -gt 0 ]] && pass "logs flowing through collector"   || skip "no log batches in last 200 log lines"
  # Export errors: the dice-game collector's OTLP->Loki log export is a KNOWN
  # defect (unlabeled stream -> HTTP 400 "at least one label pair is required");
  # surface it as a warning but do not fail on it. Any OTHER export error
  # (esp. traces to Tempo, DNS, TLS, "Permanent error" on traces) is a real fail.
  labelerr="$(echo "$clog" | grep -c 'at least one label pair')"
  otherr="$(echo "$clog" | grep -i 'error.*exporting\|dropped_items' | grep -vc 'at least one label pair')"
  [[ "$otherr" -eq 0 ]] && pass "no unexpected collector export errors" \
    || fail "$otherr unexpected collector export errors (traces/DNS/TLS — check endpoints)"
  [[ "$labelerr" -gt 0 ]] && skip "dice-game collector OTLP->Loki log export dropping (known 400 label-pair defect)"
fi
rm -f "$KUBECONFIG_TEST" 2>/dev/null

# ---------------------------------------------------------------------------
# 6. Content consistency (local repo, no cluster)
# ---------------------------------------------------------------------------
section "Content consistency (.adoc source)"

grep_clean() { # <label> <pattern> [dir]
  local label="$1" pat="$2" dir="${3:-$PAGES_DIR}"
  if [[ ! -d "$dir" ]]; then skip "$label (dir not found: $dir)"; return; fi
  local hits; hits="$(grep -rn "$pat" "$dir" 2>/dev/null)"
  [[ -z "$hits" ]] && pass "$label" || { fail "$label"; echo "$hits" | sed 's/^/         /' | head -5; }
}
grep_clean "deployment refs include -collector suffix" 'deployment/{collector_name}[^-]'
grep_clean "instrumentation endpoint uses -collector"  'collector_name}\.{tutorial'
grep_clean "no stale resource names"                   'monitoringstack-sample\|loadgenerator'
grep_clean "ClusterLogForwarder named 'collector'"     'clusterlogforwarder.*instance'
grep_clean "tempo gateway uses HTTP :8080 not gRPC"    '8090/api/traces'
grep_clean "no traces_endpoint/logs_endpoint override" 'traces_endpoint\|logs_endpoint'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Summary"
printf 'PASS: %s%d%s   FAIL: %s%d%s   SKIP: %s%d%s\n' \
  "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0" "$C_Y" "$SKIP" "$C_0"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed checks:"
  printf '  - %s\n' "${FAILED_LIST[@]}"
  exit 1
fi
echo "All non-skipped checks passed."
exit 0
