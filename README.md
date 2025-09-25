# Hello Flask – Production Container, Kubernetes, Helm, and Optional Observability

This repository packages the minimal Flask app in `app.py` into a **production-ready** container and provides
both **raw Kubernetes manifests** and a **Helm chart** for deployment. It also includes a **metrics addon**
based on a **Blackbox (synthetic) probe** measuring user-perceived availability and latency at the edge.

- App: minimal Flask returning **“Hello World!”** on `/`.
- Instructions: Dockerize the app, create production-grade K8s manifests (HA/scalable), incorporate a dummy URL,
  avoid host port pinning, and ensure reproducibility & cost efficiency for scaling to ~20+ similar apps.

---

## What’s included

```
hello-flask-deployable/
|-- app.py
|-- instructions.txt
|-- Dockerfile
|-- requirements.txt
|-- README.md  <-- this file
|-- k8s/                         # Raw Kubernetes (prod-grade)
|  |-- namespace.yaml            # PSA labels (restricted), app namespace
|  |-- serviceaccount.yaml       # Explicit SA; automount=false
|  |-- deployment.yaml           # 3 replicas, zone+node spread, probes, preStop
|  |-- service.yaml              # ClusterIP (no hostPort)
|  |-- ingress.yaml              # Dummy host w/ TLS + SSL redirect/HSTS
|  |-- hpa.yaml                  # CPU-based autoscaling (3..10)
|  |-- pdb.yaml                  # minAvailable=2
|  |-- networkpolicy.yaml        # Restrict ingress to ingress-nginx; allow DNS
|  |-- limitrange.yaml           # Default requests/limits
|  |-- resourcequota.yaml        # Namespace cost guardrails
|  |-- monitoring/
|  |  |-- probe.yaml             # Preferred: Prometheus Operator Probe (shared exporter)
|  |  |-- local-blackbox/        # Optional: per-namespace exporter
|  |     |-- blackbox-exporter-deployment.yaml
|  |     |--blackbox-exporter-service.yaml
|  |     |-- blackbox-exporter-servicemonitor.yaml
|  |-- gateway/                  # Optional: Gateway API example
|     |-- gateway.yaml           # Sample Gateway (edit GatewayClass)
|     |-- httproute.yaml         # HTTPRoute to the Service
|-- helm/
   |-- hello-flask/
      |-- Chart.yaml
      |-- values.yaml
      |-- templates/
         |-- _helpers.tpl
         |-- serviceaccount.yaml
         |-- deployment.yaml
         |-- service.yaml
         |-- ingress.yaml                  # Auto-defaults path="/" when omitted
         |-- gateway-httproute.yaml        # Optional (gatewayApi.enabled)
         |-- hpa.yaml
         |-- pdb.yaml
         |-- networkpolicy.yaml
         |-- metrics-blackbox-deployment.yaml      # Optional local exporter
         |-- metrics-blackbox-service.yaml
         |-- metrics-blackbox-servicemonitor.yaml
         |-- metrics-blackbox-probe.yaml           # Shared exporter via Probe CRD
         |-- NOTES.txt
```

---

## Approache & Why it addresses the provided instructions

### Baseline: Ingress metrics + **Blackbox synthetic probe**
- **No code changes** to `app.py`.
- Measures actual user path (DNS > TLS > Ingress > Service > Pod).
- **Cost-efficient** across many apps: one Ingress controller; cheap per-host probe.
- **Reproducible**: standardized in raw YAML and Helm.

### Security & HA
- **PSA (restricted)** on the Namespace; **non-root**, **seccomp**, and **caps dropped** at pod level.
- **HA:** 3 replicas + **PDB**; **preStop** (drain) + probes for graceful rollouts.
- **Spread across zones and nodes** via `topologySpreadConstraints` for failure isolation.

### Cost & reproducibility
- **ClusterIP + shared Ingress** (one LB, many apps).
- **LimitRange** sets **default requests/limits** > predictable bin-packing if teams forget to set resources.
- **ResourceQuota** caps total cores/memory and pods per namespace > prevents runaway spend.
- **HPA** auto-scales for actual load; **stateless** (no PVs).
- **Helm chart** drives consistent deployments; now supports **image digests** for immutability.

### Optional depth (off by default)
- **Gateway API** (HTTPRoute) if that's your platform standard-can be toggled instead of Ingress.
- **Local blackbox exporter** if you don't have a shared one; otherwise use **Probe CRD** against shared exporter (preferred for cost).

---

## How ResourceQuota & LimitRange manage costs (and why)

- **LimitRange (`k8s/limitrange.yaml`)** sets **defaultRequest** and **default limits** for every container that doesn't specify them.  
  - *Effect:* workloads get a small, sane footprint by default (`50m/64Mi` request; `250m/256Mi` limit) > better **bin-packing** and fewer oversized pods consuming nodes.
- **ResourceQuota (`k8s/resourcequota.yaml`)** caps the **sum** of requests/limits and the **pod count** per namespace.  
  - *Effect:* protects the cluster budget and other teams by enforcing hard ceilings (e.g., `limits.cpu: 10`, `pods: 20`).  
Together, these provide **predictable cost envelopes** even as teams create "20 additional similar applications."

---

## Deployment guide

### Prereqs
- Container registry, K8s 1.25+, Ingress controller, **cert-manager** for TLS.
- For metrics addon (preferred): **Prometheus Operator** (kube-prometheus-stack). If your Prometheus selects `ServiceMonitor`/`Probe` via labels, adjust labels in the manifests/values.

### Build & push the image
```bash
export IMAGE=your-registry/hello-flask
export TAG=0.1.0
docker build -t $IMAGE:$TAG .
docker push $IMAGE:$TAG
```
> **Immutable images (Helm)**: You can use a digest instead of a tag: set `image.digest=...` and omit `image.tag`.

### Deploy with **raw Kubernetes**
```bash
kubectl apply -f k8s/namespace.yaml
# (Optional) If using Ingress, ensure DNS hello.example.com points to your LB and cert-manager has an issuer.
# (Reqired) set the Image tag and version in the deployment manifest before deploying.
kubectl -n hello-flask apply -f k8s/
```
**Metrics addon (choose one) (REMINDER: Promethius operator (kube-promethius-stack) reqruired to be installed on the cluster first):**
- **Preferred (shared exporter):**
  - Ensure a cluster **blackbox-exporter** exists at `http://blackbox-exporter.monitoring.svc:9115`
  - Apply: `kubectl -n hello-flask apply -f k8s/monitoring/probe.yaml`
- **Local exporter (if no shared exporter):**
  - Apply: `kubectl -n hello-flask apply -f k8s/monitoring/local-blackbox/`

**Gateway API (optional):** If your cluster uses Gateway API, edit `k8s/gateway/gateway.yaml` to set your `gatewayClassName` (or omit if you already have a shared Gateway) and apply `gateway.yaml` + `httproute.yaml`.

### Deploy with **Helm** (recommended)
Basic:
```bash
helm upgrade --install hello-flask ./helm/hello-flask   --namespace hello-flask --create-namespace   --set image.repository=your-registry/hello-flask   --set image.tag=0.1.0   --set ingress.hosts[0].host=hello.example.com
```
> The chart now **defaults the path to "/"** if omitted, so the above works without specifying `paths`.

**Immutable image (digest):**
```bash
helm upgrade --install hello-flask ./helm/hello-flask   --namespace hello-flask --create-namespace   --set image.repository=your-registry/hello-flask   --set image.digest=sha256:YOUR_DIGEST   --set ingress.hosts[0].host=hello.example.com
```

**Use Gateway API instead of Ingress:**
```bash
helm upgrade --install hello-flask ./helm/hello-flask   --namespace hello-flask --create-namespace   --set image.repository=your-registry/hello-flask   --set image.tag=0.1.0   --set gatewayApi.enabled=true   --set gatewayApi.gatewayRef.name=web   --set gatewayApi.gatewayRef.namespace=hello-flask
```

**Metrics addon with shared exporter (Probe CRD):**
```bash
helm upgrade --install hello-flask ./helm/hello-flask   --namespace hello-flask --create-namespace   --set image.repository=your-registry/hello-flask   --set image.tag=0.1.0   --set ingress.hosts[0].host=hello.example.com   --set metrics.blackbox.enabled=true   --set metrics.blackbox.useProbe=true   --set metrics.blackbox.proberUrl="http://blackbox-exporter.monitoring.svc:9115"   --set metrics.blackbox.targetUrl="https://hello.example.com/"
```

**Metrics addon with local exporter (if no shared one):**
```bash
helm upgrade --install hello-flask ./helm/hello-flask   --namespace hello-flask --create-namespace   --set image.repository=your-registry/hello-flask   --set image.tag=0.1.0   --set ingress.hosts[0].host=hello.example.com   --set metrics.blackbox.enabled=true   --set metrics.blackbox.createExporter=true   --set metrics.blackbox.targetUrl="https://hello.example.com/"
```

### Validate
- App: `curl -I https://hello.example.com/` > HTTP 200
- Prometheus: `probe_success{}` and `probe_duration_seconds{}` for your job/instance

---

## Future work (CI/CD & GitOps - not included, but recommended)
- **GitHub Actions** to build/push image, lint YAML, and run `helm template` + schema validation.
- **Argo CD/Flux** for declarative, auditable rollouts per environment (dev/staging/prod values).

---

## Summary of Solution

- **Dockerfile** + **K8s manifests** deploy the Flask app as a web service with a **dummy URL** (Ingress or HTTPRoute).  
- Designed for **production quality, HA, and scalability** (HPA, PDB, zone/node spread, security contexts).  
- **No hostPort**; traffic via **shared Ingress** or **Gateway**.  
- **Reproducibility & cost**: Helm chart, default resource envelopes (LimitRange), namespace guardrails (ResourceQuota), shared edge, and low-overhead metrics pattern suitable for "20 additional similar applications."