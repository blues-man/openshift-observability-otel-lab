# Lab Validation Test Suite

End-to-end validation of the OpenShift Observability with OpenTelemetry lab.
Run this after any content or Helm chart change to catch regressions.

## Parameters

Set these before running. All commands use `--kubeconfig $KUBECONFIG_TEST` to avoid clobbering the admin session.

```
CLUSTER_API=https://api.<cluster>.<domain>:6443
APPS_DOMAIN=apps.<cluster>.<domain>
TEST_USER=user3
TEST_PASSWORD=<password>
KUBECONFIG_TEST=/tmp/kubeconfig-${TEST_USER}
NAMESPACE=observability-app-${TEST_USER}
TEMPO_NAMESPACE=tempo-observability
LOKI_NAMESPACE=openshift-logging
COO_NAMESPACE=coo-observability
COLLECTOR_NAME=otel
THANOS_HOST=thanos-querier-openshift-monitoring.${APPS_DOMAIN}
```

## Setup

### T0: Create test kubeconfig and login

```bash
oc login --insecure-skip-tls-verify=true $CLUSTER_API \
  --username $TEST_USER --password $TEST_PASSWORD \
  --kubeconfig $KUBECONFIG_TEST
```

**PASS:** Login successful, user has access to `$NAMESPACE`.

### T0.1: Verify pre-deployed resources

```bash
oc get pods -n $NAMESPACE --kubeconfig $KUBECONFIG_TEST
```

**PASS:** Pods `frontend`, `backend1`, `backend2`, `backend3`, `loadgen`, `${COLLECTOR_NAME}-collector-*` all Running.

---

## Module 1: Explore the Observability Stack

### T1.1: Check operator subscriptions

```bash
oc get subscriptions.operators.coreos.com -A --kubeconfig $KUBECONFIG_TEST \
  | grep -E 'opentelemetry|tempo|loki|cluster-observability|cluster-logging'
```

**PASS:** 5 subscriptions found (opentelemetry, tempo, loki, cluster-observability, cluster-logging).

### T1.2: Check CSVs

```bash
oc get csv -A --kubeconfig $KUBECONFIG_TEST \
  | grep -E 'opentelemetry|tempo|loki|observability|logging' \
  | grep -v Succeeded
```

**PASS:** No output (all CSVs are Succeeded).

### T1.3: TempoStack health

```bash
oc get tempostack -n $TEMPO_NAMESPACE --kubeconfig $KUBECONFIG_TEST
```

**PASS:** `simplest` exists with `Managed` management state.

### T1.4: Tempo pods running

```bash
oc get pods -n $TEMPO_NAMESPACE --kubeconfig $KUBECONFIG_TEST \
  | grep -E 'compactor|distributor|gateway|ingester|querier|query-frontend' \
  | grep -v Running
```

**PASS:** No output (all Tempo pods are Running).

### T1.5: LokiStack exists

```bash
oc get lokistack -n $LOKI_NAMESPACE --kubeconfig $KUBECONFIG_TEST
```

**PASS:** `logging-loki` exists.

### T1.6: ClusterLogForwarder exists

```bash
oc get clusterlogforwarder -n $LOKI_NAMESPACE --kubeconfig $KUBECONFIG_TEST
```

**PASS:** Output contains `collector`. **FAIL if:** name is `instance` (lab content is stale).

### T1.7: User Workload Monitoring enabled

```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  --kubeconfig $KUBECONFIG_TEST -o yaml | grep enableUserWorkload
```

**PASS:** Output contains `enableUserWorkload: true`.

### T1.8: MonitoringStack exists

```bash
oc get monitoringstack -n $COO_NAMESPACE --kubeconfig $KUBECONFIG_TEST
```

**PASS:** A MonitoringStack resource exists. Note the actual name — lab content must match.

### T1.9: MonitoringStack OTLP receiver

```bash
oc get monitoringstack -n $COO_NAMESPACE --kubeconfig $KUBECONFIG_TEST \
  -o yaml | grep -i otlp
```

**PASS:** Output contains `enableOtlpHttpReceiver: true` or similar OTLP config.
**FAIL if:** grep returns empty (case-sensitivity issue in lab content).

### T1.10: UIPlugins registered

```bash
oc get uiplugin --kubeconfig $KUBECONFIG_TEST
```

**PASS:** Both `distributed-tracing` and `logging` present.

---

## Module 2: Deploy App and Profile Telemetry

### T2.1: Deployments exist

```bash
oc get deployments -n $NAMESPACE --kubeconfig $KUBECONFIG_TEST \
  -o custom-columns='NAME:.metadata.name' --no-headers
```

**PASS:** Output includes `frontend`, `backend1`, `backend2`, `backend3`, `loadgen`.
**FAIL if:** lab expected output says `loadgenerator` instead of `loadgen`.

### T2.2: Instrumentation CR endpoints correct

```bash
oc get instrumentation -n $NAMESPACE --kubeconfig $KUBECONFIG_TEST \
  -o yaml | grep -A1 OTEL_EXPORTER_OTLP_ENDPOINT | grep value
```

**PASS:** Endpoints contain `${COLLECTOR_NAME}-collector.${NAMESPACE}.svc`.
**FAIL if:** Endpoints use `${COLLECTOR_NAME}.${NAMESPACE}.svc` (missing `-collector` suffix).

### T2.3: Base collector has logs pipeline

```bash
oc get opentelemetrycollector $COLLECTOR_NAME -n $NAMESPACE \
  --kubeconfig $KUBECONFIG_TEST -o jsonpath='{.spec.config}' \
  | python3 -c "
import sys,json,yaml
raw=sys.stdin.read()
c = yaml.safe_load(raw) if not raw.startswith('{') else json.loads(raw)
pipes = list(c.get('service',{}).get('pipelines',{}).keys())
print('Pipelines:', pipes)
assert 'logs' in pipes, 'FAIL: no logs pipeline in base collector'
assert 'traces' in pipes, 'FAIL: no traces pipeline'
print('PASS')
"
```

**PASS:** Pipelines include `logs` and `traces`.

### T2.4: Apply profiling collector config

Apply the inline YAML from Module 2 Exercise 3 with substitutions, then verify:

```bash
oc get opentelemetrycollector $COLLECTOR_NAME -n $NAMESPACE \
  --kubeconfig $KUBECONFIG_TEST -o jsonpath='{.spec.config}' \
  | python3 -c "
import sys,json,yaml
raw=sys.stdin.read()
c = yaml.safe_load(raw) if not raw.startswith('{') else json.loads(raw)
conn = list(c.get('connectors',{}).keys())
exp = list(c.get('exporters',{}).keys())
proc = list(c.get('processors',{}).keys())
pipes = list(c.get('service',{}).get('pipelines',{}).keys())
print('Connectors:', conn)
print('Exporters:', exp)
print('Processors:', proc)
print('Pipelines:', pipes)
errors = []
if 'count' not in conn: errors.append('count connector stripped')
if 'prometheus' not in exp: errors.append('prometheus exporter stripped')
if 'metrics/count' not in pipes: errors.append('metrics/count pipeline stripped')
if any('filter' in p for p in proc):
    print('Filter processors: preserved')
else:
    errors.append('filter processors stripped')
if errors:
    print('FAIL:', '; '.join(errors))
else:
    print('PASS: all components preserved')
"
```

**PASS:** count connector, prometheus exporter, filter processors, metrics/count pipeline all preserved.
**FAIL if:** Operator stripped any components.

### T2.5: Collector rollout command uses correct name

The rollout command in the lab content must reference `deployment/${COLLECTOR_NAME}-collector`:

```bash
grep -n 'rollout status' /path/to/04-module-02-deploy-app-and-profile.adoc
```

**PASS:** Command uses `{collector_name}-collector`.
**FAIL if:** Command uses `{collector_name}` without `-collector` suffix.

### T2.6: ServiceMonitor creation permitted

```bash
oc auth can-i create servicemonitors.monitoring.coreos.com \
  -n $NAMESPACE --kubeconfig $KUBECONFIG_TEST
```

**PASS:** `yes`.

### T2.7: Prometheus API query permitted

```bash
TOKEN=$(oc whoami -t --kubeconfig $KUBECONFIG_TEST)
HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS_HOST/api/v1/query?query=up")
echo "HTTP $HTTP_CODE"
```

**PASS:** HTTP 200.
**FAIL if:** HTTP 403 (missing `cluster-monitoring-view` ClusterRole).

### T2.8: Count metrics appear in Prometheus

After applying profiling config and waiting ~60 seconds:

```bash
TOKEN=$(oc whoami -t --kubeconfig $KUBECONFIG_TEST)
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS_HOST/api/v1/query?query=telemetry_spans_count_total" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
results=d.get('data',{}).get('result',[])
print(f'Results: {len(results)}')
if results:
    print('PASS: count metrics flowing')
else:
    print('FAIL: no count metrics (check ServiceMonitor, NetworkPolicy port 8889, scrape target status)')
"
```

**PASS:** At least 1 result with `service_name` label.

---

## Module 3: Head-Based Sampling

### T3.1: Apply 50% sampling Instrumentation CR

Apply the inline YAML from Module 3 Exercise 2 with substitutions.

**PASS:** `instrumentation.opentelemetry.io/my-instrumentation configured`.

### T3.2: Instrumentation CR endpoint in lab content

```bash
grep 'OTEL_EXPORTER_OTLP_ENDPOINT' /path/to/05-module-03-head-based-sampling.adoc \
  | grep 'value:'
```

**PASS:** All values use `{collector_name}-collector.{tutorial_namespace}.svc:4318`.
**FAIL if:** Values use `{collector_name}.{tutorial_namespace}.svc:4318`.

### T3.3: Rollout restart works

```bash
oc rollout restart deployment/frontend deployment/backend1 deployment/backend2 \
  -n $NAMESPACE --kubeconfig $KUBECONFIG_TEST
oc rollout status deployment/frontend -n $NAMESPACE --kubeconfig $KUBECONFIG_TEST
```

**PASS:** `deployment "frontend" successfully rolled out`.

### T3.4: Reset to 100% sampling

Apply the reset Instrumentation CR from Exercise 4. Verify:

```bash
oc get instrumentation my-instrumentation -n $NAMESPACE \
  --kubeconfig $KUBECONFIG_TEST \
  -o jsonpath='{.spec.sampler.argument}'
```

**PASS:** Output is `1`.

---

## Module 4: Tail-Based Sampling

### T4.1: Apply tail sampling collector config

Apply the inline YAML from Module 4 Exercise 2 with substitutions, then verify:

```bash
oc get opentelemetrycollector $COLLECTOR_NAME -n $NAMESPACE \
  --kubeconfig $KUBECONFIG_TEST -o jsonpath='{.spec.config}' \
  | python3 -c "
import sys,json,yaml
raw=sys.stdin.read()
c = yaml.safe_load(raw) if not raw.startswith('{') else json.loads(raw)
proc = list(c.get('processors',{}).keys())
print('Processors:', proc)
if 'tail_sampling' in proc:
    print('PASS: tail_sampling preserved')
else:
    print('FAIL: tail_sampling stripped by operator')
"
```

**PASS:** `tail_sampling` processor preserved.

### T4.2: Rollout command uses correct name

```bash
grep 'rollout status' /path/to/06-module-04-tail-based-sampling.adoc
```

**PASS:** Uses `{collector_name}-collector`.

### T4.3: Tail sampling metrics accessible

The lab uses port-forward (not `oc exec curl`, which fails on distroless containers):

```bash
grep -A3 'port-forward' /path/to/06-module-04-tail-based-sampling.adoc
```

**PASS:** Uses `oc port-forward` + local `curl`.
**FAIL if:** Uses `oc exec ... -- curl` (distroless container has no curl/sh).

### T4.4: Tail sampling metrics present

```bash
oc port-forward -n $NAMESPACE deployment/${COLLECTOR_NAME}-collector 18888:8888 \
  --kubeconfig $KUBECONFIG_TEST &
PF_PID=$!
sleep 3
METRICS=$(curl -s localhost:18888/metrics | grep -c tail_sampling)
kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null
echo "tail_sampling metric lines: $METRICS"
```

**PASS:** Count > 0.

---

## Module 5: Log Deduplication and Wrap-Up

### T5.1: Apply logdedup collector config

Apply the inline YAML from Module 5 Exercise 2 with substitutions, then verify:

```bash
oc get opentelemetrycollector $COLLECTOR_NAME -n $NAMESPACE \
  --kubeconfig $KUBECONFIG_TEST -o jsonpath='{.spec.config}' \
  | python3 -c "
import sys,json,yaml
raw=sys.stdin.read()
c = yaml.safe_load(raw) if not raw.startswith('{') else json.loads(raw)
proc = list(c.get('processors',{}).keys())
exp = list(c.get('exporters',{}).keys())
print('Processors:', proc)
print('Exporters:', exp)
errors = []
if 'logdedup' not in proc: errors.append('logdedup stripped')
if any('filter' in p for p in proc):
    pass
else:
    errors.append('filter processors stripped')
if errors:
    print('FAIL:', '; '.join(errors))
else:
    print('PASS')
"
```

**PASS:** `logdedup` and filter processors preserved.

### T5.2: Metrics endpoint service name correct

```bash
grep 'monitoringstack' /path/to/07-module-05-log-dedup-and-wrapup.adoc
```

**PASS:** No occurrences of `monitoringstack-sample`. Should reference the actual MonitoringStack service name (e.g., `coo-observability-prometheus`).

### T5.3: Rollout command uses correct name

```bash
grep 'rollout status' /path/to/07-module-05-log-dedup-and-wrapup.adoc
```

**PASS:** Uses `{collector_name}-collector`.

### T5.4: Expected apply output matches CR name

```bash
grep 'opentelemetrycollector.opentelemetry.io/' /path/to/07-module-05-log-dedup-and-wrapup.adoc
```

**PASS:** Shows `otel configured` (matches `collector_name` attribute).

---

## End-to-End Telemetry Flow

### TE2E.1: Traces flowing

```bash
oc logs deployment/${COLLECTOR_NAME}-collector -n $NAMESPACE \
  --kubeconfig $KUBECONFIG_TEST --tail=50 | grep -c 'Traces'
```

**PASS:** Count > 0 (debug exporter logs trace batches).

### TE2E.2: Logs flowing

```bash
oc logs deployment/${COLLECTOR_NAME}-collector -n $NAMESPACE \
  --kubeconfig $KUBECONFIG_TEST --tail=50 | grep -c 'Logs'
```

**PASS:** Count > 0 (debug exporter logs log batches).

### TE2E.3: No exporter errors

```bash
oc logs deployment/${COLLECTOR_NAME}-collector -n $NAMESPACE \
  --kubeconfig $KUBECONFIG_TEST --tail=100 | grep -i 'error.*exporting\|dropped_items' | head -5
```

**PASS:** No output (no export errors).
**FAIL if:** Errors like `Exporting failed. Dropping data` appear (check endpoint URLs, DNS, TLS).

---

## Content Consistency Checks

These validate the .adoc source files without a cluster.

### TC.1: Collector deployment name consistency

```bash
cd /path/to/repo
grep -rn 'deployment/{collector_name}[^-]' content/modules/ROOT/pages/
grep -rn "deployment/otel-collector[^-]" content/modules/ROOT/pages/
```

**PASS:** No output (all deployment refs include `-collector` suffix).

### TC.2: Instrumentation endpoint consistency

```bash
grep -rn 'collector_name}.{tutorial' content/modules/ROOT/pages/
```

**PASS:** No output. All should use `{collector_name}-collector.{tutorial_namespace}`.

### TC.3: No stale resource names

```bash
grep -rn 'monitoringstack-sample\|loadgenerator' content/modules/ROOT/pages/
```

**PASS:** No output.

### TC.4: ClusterLogForwarder name

```bash
grep -n 'clusterlogforwarder.*instance' content/modules/ROOT/pages/
```

**PASS:** No output. Should reference `collector`, not `instance`.

---

## Summary Template

```
Lab Validation Report
Date:        ____
Cluster:     ____
User:        ____
Git commit:  ____

Module 1:  __ / 10 passed
Module 2:  __ /  8 passed
Module 3:  __ /  4 passed
Module 4:  __ /  4 passed
Module 5:  __ /  4 passed
E2E Flow:  __ /  3 passed
Content:   __ /  4 passed
--------------------------
Total:     __ / 37 passed

Blocking issues:
  -

Notes:
  -
```
