# Air-Gapped Kafka → PostgreSQL Pipeline (Zarf)

This repository contains a single Zarf package definition to deploy an offline data pipeline on Kubernetes consisting of Apache Kafka, PostgreSQL, and a Kafka Connect JDBC Sink.

```
[ Producer ] ──(kafka-console-producer)──▶ [ Kafka Topic: "messages" ]
                                                          │
                                                          ▼
                    [ PostgreSQL Table: "messages" ] ◀──(JDBC Sink)── [ Kafka Connect ]
```

> **Air-Gap Guarantee:** Every chart, image, and manifest is bundled during the artifact generation phase (`zarf package create`). The deployment phase (`zarf package deploy`) makes zero external network calls.

---

## 📂 Repository Layout

```
.
├── zarf.yaml               # Zarf package definition (images, charts, manifests)
├── Makefile                # DevOps automation layer (Kind, Init, Deploy, Verify)
├── charts/                 # Vendored Helm charts (*.tgz) committed to source
├── values/                 # Environment-specific Helm value overrides
├── manifests/              # Kubernetes glue (Connect deployment & registration jobs)
├── kafka-connect/          # Custom Kafka Connect Dockerfile (Confluent + JDBC + PG Driver)
└── scripts/                # E2E Validation and acceptance tests
```

---

## 🏗️ CPU Architecture & Multi-Arch Support

The Zarf package configuration is decoupled from a single CPU architecture. All bundled images (the custom GHCR Connect image and upstream Bitnami images) are multi-arch compiled (amd64 + arm64).

**Default Behavior:** Running `zarf package create .` compiles the package for your current host architecture.

**Targeting Specific Architectures:** To explicitly generate an artifact for a different cluster architecture, append the `--architecture` flag:

```bash
zarf package create . --architecture amd64  # or arm64
```

> ⚠️ **Note:** The resulting tarball name embeds the chosen architecture (e.g., `zarf-package-*-amd64.tar.zst`). This string must align with the native node architecture of your target Kubernetes cluster during deployment.

---

## 🛠️ Prerequisites

Ensure the following binaries are available on your host path before executing:

- `zarf` (v0.77+)
- `kind`
- `kubectl`
- `docker`
- `make` (Optional, but highly recommended)

---

## 🚀 Quick Start (Automated Flow)

To execute the entire lifecycle (Build package ➔ Spin up local Kind cluster ➔ Bootstrap Zarf ➔ Deploy pipeline ➔ Run E2E Verification), run:

```bash
make all DB_PASSWORD=your_secure_password
```

> ⚠️ **Note:** If you omit `DB_PASSWORD` during `make all` or `make deploy`, the Zarf CLI will securely pause and prompt you to input a password manually in the terminal.

### Run Custom E2E Message Checks

```bash
make verify MSG="Testing air-gap line"
```

---

## 📖 Manual Reference Flow (Plain Zarf)

If your environment lacks `make`, execute the pipeline lifecycle step-by-step:

### 1. Build the Artifact (Requires Internet)

```bash
zarf package create . --confirm
```

### 2. Prepare Local Infrastructure (Offline Boundary)

```bash
kind create cluster --name zarf-e2e
zarf init --confirm
```

### 3. Deploy the Pipeline

```bash
ZARF_VAR_DB_PASSWORD='your_secure_password' \
  zarf package deploy zarf-package-kafka-pg-pipeline-*.tar.zst --confirm
```

Alternatively, run it bare, and type your password when prompted:

```bash
zarf package deploy zarf-package-kafka-pg-pipeline-*.tar.zst --confirm
```

### 4. Run Verification

```bash
./scripts/verify.sh "your-message"
```

---

## 🛑 Teardown

```bash
make clean
```

---

## 🩺 Troubleshooting & Diagnostics

| Symptom | Diagnosis | Action |
|---|---|---|
| Image pull error on deploy | The image tag rendered by the Helm chart differs from `zarf.yaml`. | Run `zarf dev find-images` to align strings. |
| Message never lands in DB | Check Kafka Connect sink registration status. | `make status` — or read raw connector state: `kubectl exec -n kafka deploy/kafka-connect -- wget -qO- http://localhost:8083/connectors/pg-sink/status` |
| Connector errors | Stream the runtime logs from the connect worker platform. | `make logs` |
| Postgres Pod Not Ready | Inspect the scheduling and volume mounting state. | `kubectl describe pod -n db -l app.kubernetes.io/name=postgresql` |
