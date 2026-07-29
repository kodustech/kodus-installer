# Kodus on Kubernetes & OpenShift (Helm)

[Kodus](https://github.com/kodustech/kodus-ai) is a **self-hosted AI code reviewer**
— its agent Kody reviews your pull requests in your own infrastructure. These Helm
charts deploy the full stack on Kubernetes or OpenShift, alongside the Docker
Compose option in the [repo root](../readme.md). New here? Start with the root
README, then come back for the cluster deployment.

**See also:** [Architecture](https://docs.kodus.io/how_to_deploy/en/kodus_architecture)
· [BYOK / LLM keys](https://docs.kodus.io/how_to_use/en/byok)
· [full docs](https://docs.kodus.io) ([llms.txt](https://docs.kodus.io/llms.txt)).

- `kodus/` — the deployable chart (Kubernetes **and** OpenShift, via `platform`).
- `kodus-common/` — a Helm *library* chart (shared helpers/templates). Not
  installed directly.

## Requirements

- Helm 3.8+
- Kubernetes 1.28+ or OpenShift 4.14+
- For `mode: operator` data stores, the matching operator pre-installed
  (see [Data stores](#data-stores)).

## Quick start (Kubernetes, bundled data stores)

The default `bundled` mode brings up PostgreSQL (pgvector), MongoDB and RabbitMQ
as StatefulSets this chart manages — the equivalent of docker-compose
`USE_LOCAL_DB=true`. One command, no operators:

```bash
cd charts/kodus
helm dependency build
helm install kodus . \
  -n kodus --create-namespace \
  --set imageTag=2.1.27 \
  --set global.config.WEB_HOSTNAME_API=api.kodus.example.com \
  --set global.config.NEXTAUTH_URL=https://kodus.example.com \
  --set ingress.hosts.web.host=kodus.example.com \
  --set ingress.hosts.api.host=api.kodus.example.com
```

`imageTag` sets the Kodus release for **all** services + migrations at once (like
docker-compose `IMAGE_TAG`); override one service with `services.<name>.image.tag`.
It defaults to `latest`, so a fresh install always gets the current release — the
commands above pin `2.1.27` only to show the syntax. Auth/crypto secrets are
generated automatically with the correct format and stay stable across upgrades.

**Pin a release for anything you need to reproduce, roll back, or support.** With
`latest`, three things stop working:

| | why |
| --- | --- |
| Consistent version across replicas | `imagePullPolicy: Always` + the HPA (2→4) means a replica added later pulls a **newer** image than its siblings; both then serve traffic behind the same Service. |
| Predictable upgrades | The migration Job is recreated every revision, so a `helm upgrade` intended to change one limit also pulls new app code and runs its schema migrations — and those do not auto-revert. |
| Rollback | `helm rollback` restores values, not image content; `latest` re-resolves to the same new image. Use `--set imageTag=<release>` or `image.digest`. |

### Choosing / upgrading the Kodus version

```bash
# upgrade to a new release — the migration Job runs first (a normal Job, recreated
# per revision — NOT a Helm hook), then the pods roll
helm upgrade kodus . -n kodus --reuse-values --set imageTag=2.1.28
```

Secrets are preserved across the upgrade (no re-login). Roll back pods with
`helm rollback kodus`, but note DB migrations do not auto-revert — back up the
database before a major upgrade.

### Local / trial

```bash
helm install kodus . -f values.yaml -f values-dev.yaml -n kodus-dev --create-namespace
```

`values-dev.yaml` relaxes the hardening, uses `latest`, single replicas, small
bundled stores.

### Optional services

Both ship **on** so the stack comes up complete. Trim them from a minimal install:

```bash
--set services.mcp-manager.enabled=false       # MCP servers per organization
--set services.worker-analytics.enabled=false  # WORKER_ROLE=analytics ingestion
```

`mcp-manager` needs `API_MCP_MANAGER_REDIRECT_URI` — the public URL the browser is
sent back to after the OAuth dance. The chart derives it from `NEXTAUTH_URL` (or the
web Route/Ingress host) as `<web-url>/setup/mcp/oauth`; set it explicitly when
neither is known at template time.

Both default to `replicas: 1`, so neither gets a PodDisruptionBudget — see
[Availability](#availability-replicas-hpa-and-pdb). Adding your own service under
`.Values.services` is supported, but `postgres`, `mongodb` and `rabbitmq` are
[reserved names](#reserved-service-names).

> **Git webhooks (required to trigger reviews).** Connecting a repo makes Kodus
> register a webhook on the provider using `API_<provider>_CODE_MANAGEMENT_WEBHOOK`.
> If that value is empty the app **silently skips registration** — repos connect
> but reviews never fire. The `kodus-webhooks` server serves `/github/webhook`,
> `/gitlab/webhook`, … at the root (no prefix), so it needs its **own public host**
> (not the api host under a `/webhooks` path).
>
> - **Production:** point `ingress.hosts.webhooks.host` (or `route.hosts.webhooks.host`
>   on OpenShift) at a dedicated public host. The chart then **auto-derives**
>   `API_<provider>_CODE_MANAGEMENT_WEBHOOK = https://<that-host>/<provider>/webhook`
>   — no need to set the env by hand. (Skipped when the host is empty, e.g. an
>   OpenShift router-assigned host unknown at template time, or still the
>   `example.com` placeholder; set the env(s) explicitly then.)
> - **Local testing:** front `kodus-webhooks` with a tunnel (ngrok, cloudflared)
>   and set `API_<provider>_CODE_MANAGEMENT_WEBHOOK` to the tunnel `https://` URL.
>
> `doctor-k8s.sh` flags an empty/`http`/wrong-path webhook value and tells you what
> to set.

## OpenShift

```bash
cd charts/kodus
helm dependency build
helm install kodus . -f values.yaml -f values-openshift.yaml \
  -n kodus --create-namespace \
  --set imageTag=2.1.27 \
  --set route.hosts.web.host=kodus.apps.cluster.example.com \
  --set route.hosts.api.host=kodus-api.apps.cluster.example.com \
  --set route.hosts.webhooks.host=kodus-webhooks.apps.cluster.example.com
```

> Note the flat `kodus-api` / `kodus-webhooks` hosts rather than
> `api.kodus.apps…` — see [Route hostnames must be one label
> deep](#route-hostnames-must-be-one-label-deep) below for why the nested form
> breaks TLS.

`values-openshift.yaml` sets `platform: openshift` — Routes replace Ingress, a
SCC path is wired, and pod UIDs are left to the namespace SCC (no hardcoded UIDs,
so `restricted-v2` assigns them). Leave `route.hosts.*.host` empty to let
OpenShift auto-assign the `<name>-<namespace>.apps…` hostname.

Verified on a Red Hat Developer Sandbox (`restricted-v2` SCC): every pod is
admitted under an arbitrary UID, the Routes come up with TLS edge, and the bundled
Postgres (pgvector) and RabbitMQ run fine as that UID.

The things to watch on OpenShift are the **registry** and the **certificate**, not
the SCC.

### Docker Hub mirrors break `mongo:8`

Many enterprise clusters transparently rewrite `docker.io/library/*` to an internal
mirror, so the bundled `mongo:8` fails with `ErrImagePull` — typically
`unauthorized: The client does not have permission for manifest` against a registry
you never configured. The rewrite usually targets **only** `library/*`, which is why
`pgvector/pgvector` and the Kodus images pull fine while Mongo alone fails.

The rewrite may not be visible in the cluster API at all: it can come from
`registries.conf` on the nodes (a MachineConfig) rather than an
`ImageDigestMirrorSet`, so `oc get imagedigestmirrorset` returning nothing does not
mean there is no mirror. Read the actual error on the pod:

```bash
oc describe pod <release>-mongodb-0 -n <ns> | grep -A3 Failed
```

Options:
- override just that image with a public drop-in mirror of the same image —
  `--set mongodb.bundled.image=mirror.gcr.io/library/mongo:8` — or mirror it into
  your own registry and set `global.imageRegistry`;
- or, for production, use `mode: operator` / `external` for the data stores, so the
  images come from a registry you control.

Changing the image on an already-failing StatefulSet does **not** recreate the pod:
the controller waits for the current pod to become Ready, and one stuck in
`ImagePullBackOff` never does. Delete it once after the upgrade —
`oc delete pod <release>-mongodb-0 -n <ns>`.

### Route hostnames must be one label deep

The cluster's default wildcard certificate is issued for `*.apps.<cluster-domain>`,
and **a wildcard matches exactly one DNS label**. So a host like
`api.kodus.apps.example.com` is *not* covered, while `kodus-api.apps.example.com` is.

This fails quietly in the worst way. The app answers normally (`curl -k` returns
200), the Route reports no error, and only TLS-verifying clients reject it — which
includes browsers and, critically, **GitHub/GitLab webhook delivery**. Reviews then
never trigger, with no error surfaced in Kodus.

Prefer flat hostnames under the apps domain:

```bash
--set route.hosts.web.host=kodus.apps.example.com \
--set route.hosts.api.host=kodus-api.apps.example.com \
--set route.hosts.webhooks.host=kodus-webhooks.apps.example.com
```

Verify with certificate validation **on** (no `-k`); exit code 60 means the cert
does not cover the host:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://kodus-webhooks.apps.example.com/health/ready
```

Use a custom certificate on the Route if you need deeper hostnames.

## Data stores

Each store (`postgres`, `mongodb`, `rabbitmq`) has a `mode`:

| mode | what it does | prerequisite |
|---|---|---|
| `bundled` *(default)* | a StatefulSet run by this chart, using Kodus/official images (pgvector, `kodus-rabbitmq`, mongo) | none |
| `external` | a managed/self-managed service (RDS, Atlas, CloudAMQP, …) | an `existingSecret` with the credentials |
| `operator` | a CR reconciled by a cluster operator (HA) | the operator pre-installed |

> **`bundled` is for dev / trials / evaluation** — single replica, no automated
> backups or failover, and it makes *this chart* responsible for operating a
> database (the subtle bits: Erlang cookie perms, probe tuning, PVC ownership).
> For **production**, use `external` (managed) or `operator` — they hand database
> operation to something purpose-built and remove that whole class of concerns.

Operators for `mode: operator`:

- PostgreSQL → **CloudNativePG** (`postgresql.cnpg.io`). The image **must** ship
  the `vector` extension — a stock CNPG image does not; set
  `postgres.operator.image` to a pgvector-enabled CNPG image.
- RabbitMQ → **RabbitMQ Cluster Operator** (`rabbitmq.com`). Uses the pre-built
  `kodus-rabbitmq` image (plugin + vhosts baked in).
- MongoDB → **MongoDB Community Operator** (`mongodbcommunity.mongodb.com`).

### Reusing datastores you already run

Already have Postgres/Mongo/RabbitMQ on the cluster (or managed)? Use `external`
mode. There's a ready-to-edit overlay — `charts/kodus/values-external-example.yaml`:

```bash
helm install kodus . -f values.yaml -f values-external-example.yaml \
  -n kodus --create-namespace --set imageTag=2.1.27
```

**Prerequisites on your existing infra** (the bundled images bake these in; a
vanilla install does NOT have them, and Kodus fails confusingly without them):

- **Postgres** — the `vector` (pgvector) extension must be available (managed
  PG: enable it; self-managed: install the package). Give Kodus a dedicated DB.
- **RabbitMQ** — enable the delayed-message plugin and create the two vhosts:
  ```bash
  rabbitmq-plugins enable rabbitmq_delayed_message_exchange
  rabbitmqctl add_vhost kodus-ai   && rabbitmqctl add_vhost kodus-ast
  rabbitmqctl set_permissions -p kodus-ai  <user> ".*" ".*" ".*"
  rabbitmqctl set_permissions -p kodus-ast <user> ".*" ".*" ".*"
  ```
  The URI vhost must be `kodus-ai`: `amqps://user:pass@host:5671/kodus-ai`.
- **MongoDB** — a DB + user with read/write. No extensions needed, but the app
  authenticates against the **`admin`** authSource: create the user in `admin`
  (with a role over your DB), not only inside `kodus_db`, or auth fails at runtime
  with `AuthenticationFailed`.

Mix freely (e.g. external Postgres, bundled Mongo/Rabbit) — each store's `mode`
is independent. Credentials come from Secrets you pre-create, never inline:

```bash
kubectl -n kodus create secret generic kodus-pg    --from-literal=password='...'
kubectl -n kodus create secret generic kodus-rabbit --from-literal=uri='amqps://user:pass@host:5671/kodus-ai'
```

### Datastore security in closed / high-security environments

The **bundled** stores are hardened for the common threat model — verified live on
OpenShift: authentication is enforced (`mongod --auth`; Postgres/RabbitMQ require
credentials — an unauthenticated command is rejected), passwords are auto-generated
into Secrets, Services are `ClusterIP` (never exposed), NetworkPolicy limits access
to Kodus pods, and every container runs non-root with dropped capabilities, seccomp,
and no ServiceAccount token.

What bundled does **not** provide — which is why it's dev/trial, not for locked-down
production:

- **TLS in transit** — bundled Mongo/Postgres/RabbitMQ speak plaintext in-cluster
  (isolated by NetworkPolicy, but not encrypted wire-to-wire).
- **Encryption at rest** — the community images don't encrypt data files.

For air-gapped / regulated / "encrypt everything" environments:

- **`mode: operator` or `external`** — the MongoDB Community Operator, CloudNativePG,
  and RabbitMQ Cluster Operator all support TLS; managed services add encryption at
  rest and backups.
- **An encrypted StorageClass** — encryption at rest for the PVCs, in any mode.
- **Digest-pinned images** — set the store image to a digest instead of a tag
  (`--set mongodb.bundled.image=mongo@sha256:…`) for a reproducible, tamper-evident
  supply chain; mirror them into your registry with `global.imageRegistry`.
- **Secrets via `existingSecret` / `externalSecrets`** + etcd encryption on the
  cluster, so credentials are never inline and are encrypted at rest.

## Secrets

Production should not use inline secrets. Pick one:

- `global.existingSecret: <name>` — a Secret you pre-created with all app keys.
- `global.externalSecrets.enabled: true` — generates `ExternalSecret` resources
  (external-secrets operator): AWS Secrets Manager, Vault, Azure/GCP, etc.

Left inline (dev), empty required keys are auto-generated with the correct format
(`API_CRYPTO_KEY`/`CODE_MANAGEMENT_SECRET` as 32-byte hex; JWT/NextAuth base64;
`NEXTAUTH_SECRET` mirrors `WEB_NEXTAUTH_SECRET`) and are stable across upgrades.

> Using Claude/Anthropic models? The Anthropic API key goes into
> `API_OPEN_AI_API_KEY` — Kodus reads the single LLM key from that slot and picks
> the SDK by model-id prefix.

## Air-gapped installs

No internet from the cluster? Mirror the images to your private registry and set
`global.imageRegistry` — it repoints **every** image at once (app services,
`busybox` for the wait-for-deps init, and the bundled `pgvector` / `mongo` /
`kodus-rabbitmq` images):

```bash
helm install kodus . -n kodus --create-namespace \
  --set global.imageRegistry=registry.internal:5000 \
  --set image.pullPolicy=IfNotPresent \
  ...
```

Images to mirror (tags follow your Kodus release / chart defaults):

```
ghcr.io/kodustech/kodus-ai-web
ghcr.io/kodustech/kodus-ai-api
ghcr.io/kodustech/kodus-ai-worker
ghcr.io/kodustech/kodus-ai-webhook
ghcr.io/kodustech/kodus-mcp-manager       # only if mcp-manager.enabled
ghcr.io/kodustech/kodus-rabbitmq:4.2.2-kodus
pgvector/pgvector:pg16                     # bundled Postgres
mongo:8                                    # bundled Mongo
busybox:1.37.0                             # wait-for-deps init
```

`global.imageRegistry` prepends the mirror to the full image path
(`registry.internal:5000/ghcr.io/kodustech/kodus-ai-api:…`), matching the
pull-through / project-mirror layout used by Harbor, Zarf, and most air-gapped
registries. Notes:

- The chart pulls **no** plugins/binaries at runtime — the RabbitMQ plugin and
  vhosts are baked into `kodus-rabbitmq`, and the `kodus-common` dependency is
  vendored (`helm dependency build` needs no registry beyond the mirror).
- `operator` mode also honors `global.imageRegistry` for the CNPG / RabbitMQ CR
  images — but the operators themselves must be mirrored and installed separately.
- Set `image.pullPolicy: IfNotPresent` when images are pre-loaded onto nodes
  rather than served from a registry.

## Verify the deployment

```bash
../../scripts/doctor-k8s.sh -n kodus -r kodus
```

Checks the Helm release, migration Job, workloads, pods, config/secrets (incl.
that `API_CRYPTO_KEY` is valid hex), PVCs, and the real health endpoints
(`/health`, `/health/ready`, …).

## Troubleshooting

Run `../../scripts/doctor-k8s.sh -n kodus` first — it flags most of these. For a
redacted support bundle to share with Kodus support:
`../../scripts/collect-diagnostics.sh -n kodus` (secret values are never included).
Still stuck? Reach the Kodus team at **support@kodus.io**, the
[Discord](https://discord.gg/QFzwwmNmdN), or [docs.kodus.io](https://docs.kodus.io).

| Symptom | Cause | Fix |
|---|---|---|
| UI: **"Error saving repositories"** on setup | `WEB_HOSTNAME_API` is `localhost` (or `http`), so the Git provider can't reach the webhook it tries to register | Set `WEB_HOSTNAME_API` to a public hostname and the `API_*_CODE_MANAGEMENT_WEBHOOK` to `https://<host>/<provider>/webhook`. For local testing, front it with a public tunnel/edge. |
| App pods `Init:CreateContainerConfigError` | a container has `runAsNonRoot` but the image runs as root | ensure images run non-root; the bundled busybox init pins `runAsUser`. |
| `mongodb` CrashLoopBackOff, "failed liveness probe" | (fixed) `mongosh --eval` is a heavy Node shell whose cold start blew the exec timeout under load, so liveness SIGKILL'd a healthy mongod | probes now use `tcpSocket` (the port is the signal for a standalone DB) — see [probes](#probe-design). If you re-add an exec probe, keep it out of the liveness hot path. |
| `rabbitmq` CrashLoopBackOff, `Cookie file ... must be accessible by owner only` | (fixed) `fsGroup` re-adds group-rw to the persisted `.erlang.cookie` on every mount → `0660`, which Erlang refuses | an initContainer `chmod 600`s the cookie after the fsGroup relabel. Only bites bundled mode; `operator` mode has none of this. |
| Pods `Pending` forever | no default StorageClass / PVC unbound | set `*.bundled.storage.storageClass`, or use `external`/`operator`. |
| Migration Job never completes | (fixed) the app image entrypoint runs migrations then `exec`s the app, which runs forever — a Job needs its process to exit | the Job overrides only the CMD so the entrypoint still migrates, then exits 0. App pods also self-heal (wait-for-deps + retry); check `kubectl logs -l app.kubernetes.io/component=migrations`. |
| PRs not reviewed / **"No LLM provider configured"** banner | self-hosted requires your own LLM key (BYOK) — the cloud "first 5 reviews free" trial does not apply | set `global.secrets.API_OPEN_AI_API_KEY` (Anthropic keys go here too) or add it in the BYOK settings UI. |
| `ImagePullBackOff` | private images / air-gapped | set `imagePullSecrets` and/or `global.imageRegistry` (see Air-gapped). |
| Browser can't reach `localhost` after port-forward | Chrome resolves `localhost` to IPv6 `::1`; `kubectl port-forward` binds IPv4 | use `127.0.0.1`, or `kubectl port-forward --address 127.0.0.1,::1`. |
| All pods `Unhealthy`/not-ready right after enabling `networkPolicy` | a strict CNI dropped kubelet→pod health-probe traffic under `default-deny` | most CNIs (Calico failsafe, Cilium host policy) special-case node→pod; if yours doesn't, add an ingress rule allowing the node/host. Verify on your CNI before enabling in prod. |
| `helm install` (prod, bundled PG) fails: migration/api can't connect, "server does not support SSL connections" | SSL was enabled against a non-SSL Postgres | fixed — base defaults `API_DATABASE_DISABLE_SSL: "true"` for bundled/operator. For `mode: external` managed PG that enforces TLS, set it back to `"false"`. |

Common commands:

```bash
kubectl get pods,events -n kodus --sort-by=.lastTimestamp | tail
kubectl logs -n kodus -l app.kubernetes.io/name=api --tail=100
kubectl describe pod <pod> -n kodus
```

### Probe design

Health probes are built to be **deterministic**, not dependent on how fast the
node happens to be — inflating timeouts to "wait a bit longer" is an anti-pattern
that makes health flap under load:

- **`startupProbe`** absorbs the whole cold start with *retries* (Node init,
  WiredTiger recovery, Erlang + plugin boot). While it runs, Kubernetes does not
  run the other two — so liveness/readiness carry no `initialDelaySeconds`.
- **`livenessProbe`** is the cheapest deterministic check and only restarts on
  *sustained* failure. It never shells out to a heavy CLI (`mongosh`,
  `rabbitmq-diagnostics`) — a slow shell must not SIGKILL a healthy process.
  Bundled Mongo/RabbitMQ use `tcpSocket`; Postgres uses `pg_isready` (a tiny C
  binary).
- **`readinessProbe`** may run a deeper, native check (`pg_isready`,
  `rabbitmq-diagnostics check_running`, the app's `/health` that also verifies
  RabbitMQ + Postgres). Failing it only removes the pod from its Service — never a
  restart — so a transient blip is non-fatal.

These are dev-convenience defaults for **bundled** stores. In production the
`operator`/`external` stores bring their own, operator-managed health model.

### Availability: replicas, HPA and PDB

Three settings decide how many pods run and how many may be evicted at once.
They interact, and getting the combination wrong breaks node maintenance rather
than the app — which is why the failure is easy to misread.

**Replica floor.** With `autoscaling.enabled` (the default), the HPA owns the
count and a Deployment's `replicas` field is ignored — so the chart feeds each
service's `replicas` in as the HPA's `minReplicas`, keeping the declared value
meaningful instead of dead config. With autoscaling off, `replicas` is used
directly. Either way the *floor* is what matters below.

**PDBs are only generated for services whose floor is above 1.** A
`PodDisruptionBudget` caps **voluntary** disruptions — `kubectl drain`, cluster
upgrades, autoscaler compaction. It does nothing for involuntary ones (node
death, OOM kill); it is a brake on automation, not an availability guarantee.
The arithmetic is `disruptionsAllowed = currentHealthy − minAvailable`, so
`minAvailable: 1` against a single-replica service yields **zero** — evictions
are not slowed, they are forbidden outright and permanently:

```
kodus-api                minAvailable 1, healthy 2 → 1 allowed   ✅
kodus-mcp-manager        minAvailable 1, healthy 1 → 0 allowed   ❌ drain hangs
```

`oc adm drain` then blocks forever, and the error names the *pod*
(`Cannot evict pod as it would violate the pod's disruption budget`) rather than
the PDB — so a node upgrade stalls on what reads as an application problem. A PDB
that blocks every eviction is worse than no PDB: it trades seconds of downtime
for a cluster that can no longer be maintained.

`mcp-manager` and `worker-analytics` default to `replicas: 1`, so they get no
PDB. Give them a floor of 2 and they do:

```bash
--set services.mcp-manager.replicas=2
```

Raising `pdb.minAvailable` to match the floor recreates the same deadlock by
hand, so the chart refuses to render it — the error names the service and shows
the arithmetic:

```
ERROR: pdb.minAvailable is 2 and service "api" has a replica floor of 2, so
disruptionsAllowed = 2 - 2 = 0.
```

Leave it at 1 unless you have a quorum-based workload that genuinely prefers
downtime over losing quorum. If you want the budget to scale with the replica
count instead of pinning to it, use a percentage — `--set pdb.minAvailable=50%`
is accepted as-is, since a percentage can't reach zero the way an integer can.

**Memory is deliberately not an HPA metric.** Each Node process carries a
baseline heap that does not shrink as replicas are added, so `replicas × (usage /
target)` never falls back below the target: the HPA ratchets to `maxReplicas` at
idle and stays there. The visible symptom is not high memory but replica sprawl
exhausting Postgres connections, which reads as an app outage. CPU converges and
is the only metric used. Keep `autoscaling.maxReplicas` in step with
`postgres.bundled.maxConnections` — every replica holds a pool.

### Reserved service names

`postgres`, `mongodb` and `rabbitmq` cannot be used as keys under
`.Values.services`. A service's Service selector is
`{name: <svcName>, instance: <release>, part-of: kodus}`, and the bundled
datastore pods carry exactly those labels with `name` set to the store — so a
service named `postgres` would render a Service that selects the **database**
pods, silently balancing app traffic onto Postgres. The chart fails the render
with a message naming the collision instead of letting it install.

Splitting the labels apart would be the tidier fix, but `Deployment.spec.selector`
is immutable — adding a `component` label would break `helm upgrade` on every
existing release. Failing fast costs nothing and touches no selector.

### Testing the chart

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest --version v1.1.2
helm dependency build charts/kodus     # rebuilds the vendored kodus-common
helm unittest charts/kodus
```

`helm lint` and `kubeconform` validate **form** — is this a well-formed chart, is
each rendered object valid against the API schema. Neither can validate **intent**,
and every bug this chart has actually shipped lived in that gap: a PDB that
forbids every eviction is flawless YAML; so is a webhook URL pointing at the wrong
host, or a `secretKeyRef` naming a Secret no operator creates. The suites under
`charts/kodus/tests/` assert properties of the *rendered output* — the only layer
that catches those. CI runs them on every PR touching `charts/`.

They're packaged out of the release tarball via `.helmignore`; note the leading
slash on `/tests/`, since a bare `tests/` also matches `templates/tests/` and
would silently drop the `helm test` hook.

### Logs & observability (Pino + OpenTelemetry)

Kodus emits **structured Pino logs** and **OpenTelemetry** metrics — use the
structure, not keyword grep (a keyword filter hid a real "Validation Failed"
error in our own testing). In production set `API_LOG_PRETTY=false` (JSON).

```bash
# Errors/warnings only — Pino JSON levels (warn=40, error=50, fatal=60):
kubectl logs -n kodus -l app.kubernetes.io/name=api --tail=1000 \
  | grep -aE '"level":(4[0-9]|5[0-9]|6[0-9])|HttpError|Validation Failed'

# Follow ONE request across api/web/worker/webhooks by its requestId:
kubectl logs -n kodus -l app.kubernetes.io/part-of=kodus --prefix --tail=2000 \
  | grep '<requestId>'
```

- **OpenTelemetry**: point the OTel exporter at your collector (Tempo/Jaeger for
  traces, Prometheus for metrics) to trace a failing request end-to-end.
  `OBSERVABILITY_MONGO_ENABLED` persists request metrics; `LANGFUSE_TRACING`
  traces the LLM/review pipeline.
- Ship the Pino JSON logs to Loki/ELK and query by `level`, `requestId`,
  `serviceName` — far better than `grep` across pods.
- `scripts/collect-diagnostics.sh` already extracts the error/warn Pino entries
  into `08-errors-warnings.txt`.

## Security defaults (SOC 2 oriented)

TLS on by default, NetworkPolicy microsegmentation, no ServiceAccount API access,
`readOnlyRootFilesystem` + dropped capabilities + non-root + seccomp on app pods,
pinned image tags, HPA/PDB for availability. `values-dev.yaml` relaxes these for
local use.

A few defaults worth setting explicitly for a hardened production install:

- **`networkPolicy.ingressControllerLabels`** — set this to your ingress
  controller's pod labels (e.g. `app.kubernetes.io/name: ingress-nginx`). Left
  empty, the web/api/webhooks ingress policies fall back to
  `namespaceSelector: {}` (reachable from any namespace). The model is otherwise
  *deny cross-namespace, allow intra-app* — every Kodus pod (incl. the bundled
  datastores) can talk to every other, but nothing outside the release can,
  except the ingress controller into web/api/webhooks. Egress stays open (DNS,
  datastores, LLM APIs); tighten it if your profile requires east-west control.
- **No Kubernetes API access** — the app reads config from env only, so
  `rbac.create` defaults to `false` and the SA token is not mounted. Don't grant
  a namespace-wide `secrets` read "just in case"; scope tightly if a future
  component genuinely needs the API.
- **Bundled datastores** intentionally omit `readOnlyRootFilesystem` (Postgres/
  Mongo/RabbitMQ write to runtime paths outside their data volume). This is a
  dev-convenience trade-off — production should use `operator`/`external`, whose
  images are hardened by their maintainers.
- Secrets should come from `existingSecret`/`externalSecrets`, never inline, in
  production (see [Secrets](#secrets)).
