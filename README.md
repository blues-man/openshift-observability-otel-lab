# OpenShift Observability with OpenTelemetry — Hands-on Lab

A multi-user workshop that teaches strategic sampling and telemetry data optimization on OpenShift using the platform's native observability stack.

**Based on** the [KubeCon EU 2026 lab](https://github.com/pavolloffay/kubecon-eu-2026-opentelemetry-observability-on-budget) by Pavol Loffay (Red Hat), adapted for OpenShift 4.22 with Red Hat operators and GitOps deployment.

| | |
|---|---|
| **Duration** | ~90 minutes |
| **Audience** | Intermediate developers and SREs |
| **Platform** | OpenShift 4.22 |
| **Showroom** | [Live site](https://blues-man.github.io/openshift-observability-otel-lab) |

## What you will learn

1. **Deploy the Observability Stack** — TempoStack, LokiStack, Cluster Observability Operator, Console UIPlugins
2. **Profile Telemetry** — Use the count connector to understand baseline trace volume and cardinality
3. **Head-Based Sampling** — Reduce ingestion at the source with SDK-level and collector-level sampling
4. **Tail-Based Sampling** — Keep only the traces that matter (errors, slow requests) using policy-based sampling
5. **Log Deduplication** — Reduce log volume with the logdedup processor

## Architecture

The lab deploys a polyglot dice game application with OpenTelemetry auto-instrumentation:

| Service | Language | Role |
|---------|----------|------|
| `frontend` | Node.js | HTTP frontend, calls backend services |
| `backend1` | Python/Flask | Dice roll service |
| `backend2` | Java/Spring Boot | Dice roll service |
| `backend3` | Go | Dice roll service |

Telemetry flows through an OpenTelemetry Collector to TempoStack (traces) and LokiStack (logs), with metrics scraped by the COO MonitoringStack.

## Repository layout

```
├── Chart.yaml                          # Root App of Apps Helm chart
├── values.yaml                         # Central configuration
├── templates/applications.yaml         # ArgoCD Application CRs (sync-waves 1-4)
├── components/
│   ├── operators/                      # OLM Subscriptions (OTel, Tempo, Loki, COO, Logging)
│   ├── observability-backend/          # TempoStack, LokiStack, MonitoringStack, UIPlugins
│   ├── dice-game/                      # App deployments, Collector, Instrumentation CR
│   └── showroom/                       # Showroom lab environment (Antora + terminal)
├── content/                            # Antora content source
│   └── modules/ROOT/
│       ├── pages/                      # Workshop modules (AsciiDoc)
│       ├── examples/                   # Collector configs applied during exercises
│       ├── partials/_attributes.adoc   # Shared attributes and placeholders
│       └── nav.adoc                    # Navigation
├── site.yml                            # Antora playbook
└── .github/workflows/deploy-pages.yml  # GitHub Pages build + deploy
```

## Deployment

### GitOps (multi-user lab on RHDP)

This repo is an ArgoCD App of Apps. Point an ArgoCD Application at the repo root:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: otel-observability-lab
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/blues-man/openshift-observability-otel-lab.git
    targetRevision: main
    path: .
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

ArgoCD deploys in order via sync-waves:
1. **Operators** — OLM Subscriptions for all 5 operators
2. **Observability Backend** — TempoStack, LokiStack, MonitoringStack, UIPlugins
3. **Dice Game** — Application + OTel Collector + auto-instrumentation
4. **Showroom** — Lab content served via Antora + web terminal

### Local preview (Antora)

```bash
podman run --rm -v $PWD:/antora:z -p 8080:8080 -it ghcr.io/juliaaano/antora-viewer
```

Open http://localhost:8080 to preview the workshop content.

## Operators installed

| Operator | Channel | Namespace |
|----------|---------|-----------|
| Red Hat build of OpenTelemetry | stable | openshift-opentelemetry-operator |
| Tempo Operator | stable | openshift-tempo-operator |
| Loki Operator | stable-6.x | openshift-operators-redhat |
| Cluster Observability Operator | stable | openshift-operators |
| Cluster Logging | stable-6.x | openshift-logging |

## References

- [OpenTelemetry Collector documentation](https://opentelemetry.io/docs/collector/)
- [Red Hat build of OpenTelemetry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/red_hat_build_of_opentelemetry/)
- [TempoStack documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/distributed_tracing/)
- [Cluster Observability Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cluster_observability_operator/)
- [Field-sourced content template](https://github.com/rhpds/field-sourced-content-template)
