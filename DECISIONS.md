# Decision Log

This log documents the design choices, architectural trade-offs, and scaling boundaries engineered into this air-gapped data pipeline package.

---

## 1. Artifact Isolation & Air-Gap Boundary

**Context:** The system must install and initialize inside an environment with absolute network egress restrictions (zero internet access).

**Decision:** We bundle all OCI container images and Helm configurations at the artifact generation stage (`zarf package create`). Upstream Helm charts are pulled and vendored locally into `charts/` as versioned `.tgz` archives. The bitnami images are pinned to the bitnamilegacy/* registry, because Bitnami moved its free image catalogue there in August 2025. The single custom image — Kafka Connect with the JDBC sink connector (kafka-connect/Dockerfile) — is built multi-arch (amd64/arm64) and pushed once to a public GHCR repository (ghcr.io/hassata/kafka-connect-jdbc), from where zarf package create bundles it. The package is not pinned to a CPU architecture, so create builds for the host (or an explicit --architecture).

**Consequences:**

- **Local Test Cluster:** `zarf package create` requires internet access to fetch dependencies, but `zarf package deploy` runs 100% offline. Committing binary `.tgz` blobs to the repository scales repository footprint but guarantees a completely immutable, reproducible offline build.
- **Production Escalation:** For enterprise delivery, binary artifacts should not be committed directly to Git source control. They should be mirrored into a secured, internal private registry (e.g., Harbor or Nexus) inside the air-gapped network perimeter.

---

## 2. Service Orchestration & Boot Ordering

**Context:** Distributed components must stabilize sequentially. Naive deployments suffer from race conditions (e.g., Kafka Connect listening on port 8083 before its internal plugins are loaded). Additionally, waiting on ephemeral pod labels during deploy is brittle, and Kubernetes `StatefulSet` resources lack a native controller-level `Ready` condition.

**Decision:** We orchestrate startup gates using Zarf component ordering. For StatefulSets (`postgresql`, `kafka`), we wait directly on the deterministic Pod names (`postgresql-0`, `kafka-controller-0`) rather than loose label selectors. For the `kafka-connect` Deployment, we wait on the controller-level `Available` condition. A hardened batch `Job` handles final API-level verification.


```
postgresql (Ready) ➔ kafka (Ready) ➔ kafka-connect (Readiness Probe) ➔ register-connector (Job Execution)
```

**Consequences:**

- **Local Test Cluster:** The deployment blocks deterministically using exact Pod names and Deployment conditions. The registration job loops on the `/connector-plugins` endpoint to guarantee the worker is active before registering the config.
- **Production Escalation:** For HA scaling, wait steps should be transitioned to target high-level controller scale metrics (e.g., checking StatefulSet `.status.readyReplicas` replicas via custom JSONPath queries) to support multi-replica architectures.

---

## 3. Secret Management & Dynamic Credentials

**Context:** Credentials must never be statically hardcoded or leaked into the source repository history.

**Decision:** We parameterize the DB password using Zarf deploy-time variables (`###ZARF_VAR_DB_PASSWORD###`) and inject them securely into a base64-encoded Kubernetes Secret (`stringData`).

**Consequences:**

- **Local Test Cluster:** Credentials are obfuscated inside etcd, preventing plain-text exposure in ConfigMaps. Zarf successfully injects variables at deployment.
- **Production Escalation:** Move to a native `FileConfigProvider` (`config.providers=file`) to pull credentials dynamically from an external secrets provider (e.g., HashiCorp Vault) mounted securely, bypassing Kubernetes manifests entirely.

---

## 4. Data Persistence & Compute Constraints

**Context:** State must survive rescheduling events. Concurrently, unconstrained containers on local developer machines can cause resource starvation, and JVM-based workers are susceptible to thread locks or heap exhaustion.

**Decision:** We back Kafka and PostgreSQL with `StatefulSets` bound to local PVCs. To ensure cluster stability, we define conservative resource requests/limits across all components and enforce a liveness probe on the Kafka Connect worker.

**Consequences:**

- **Local Test Cluster:** The platform runs on a single KRaft broker and PostgreSQL instance to fit developer laptops. Resource limits (e.g., Connect memory capped at 1.5Gi) prevent local cluster crashes. The liveness probe automatically restarts the Connect container if the JVM enters a deadlocked state.
- **Production Escalation:** Scale to ≥ 3 Kafka brokers (Replication Factor 3), multi-instance PostgreSQL replica clustering, dedicated production storage classes, and scale up resource limits to accommodate actual streaming throughput.

---

## 5. Serialization Strategy (Schema Registry Overhead)

**Context:** The database JDBC sink must dynamically read explicitly typed payloads to populate destination tables without requiring a pre-defined database schema to be built manually.

**Decision:** We leverage `JsonConverter` with structural schemas enabled (`value.converter.schemas.enable=true`). Every single message dispatched down the pipeline encapsulates its own structural schema meta-block alongside the data payload.

**Consequences:**

- **Local Test Cluster:** This enables the database sink to auto-create and structure the target PostgreSQL table completely on the fly without deploying a heavy, independent Schema Registry service on a local machine.
- **Production Escalation:** Wrapping an identical schema configuration block inside every single event creates massive data serialization and network bandwidth overhead. Real production streams should strip inline schemas and utilize a compact binary standard (such as Avro or Protobuf) managed by a centralized, air-gapped Schema Registry cluster.
