# Changelog — Kodus Helm chart

Chart versions, not Kodus releases. The Kodus release a chart version installs is
its `appVersion`, listed with each entry.

Which part gets bumped follows from what changed: **patch** when only the Kodus
release moves, **minor** for backward-compatible chart changes, **major** when a
value is renamed or removed, or when a change needs a reinstall rather than an
upgrade. See [Releasing the chart](README.md#releasing-the-chart).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.2] — 2026-07-30 · Kodus 2.1.28

Fixes a shutdown bug and exposes the settings around it. The Kodus release is unchanged.

### Fixed

- **Workers were SIGKILLed 30 seconds into a 10-minute drain.** The chart set no
  `terminationGracePeriodSeconds` at all, so Kubernetes applied its 30s default
  while the app's `API_WORKER_DRAIN_TIMEOUT_MS` was 600000. The shutdown path was
  dead code — killed twenty times over before it could finish — on every rollout,
  every HPA scale-down and every node drain, leaving in-flight jobs orphaned in
  `PROCESSING`. Nothing rendered invalid: the two numbers simply disagreed, in
  different files, one of them implicit.

  The grace period is now **derived** from the drain timeout plus a buffer, so the
  two cannot drift apart again. Draining is defined as "stop consuming and let the
  queue reclaim the work", not "finish it" — a review job may legitimately run 105
  minutes, and no grace period can accommodate that without making node drains
  take hours.

### Added

- `API_WORKER_DRAIN_TIMEOUT_MS` (60s) and `terminationGraceBufferSeconds` (30s),
  both now visible and tunable instead of implicit.
- `WORKFLOW_STALE_JOB_REAPER_CRON` and `WORKFLOW_STALE_JOB_TIMEOUT_MINUTES`, from
  Kodus 2.1.28. These matter more here than under Compose: OOMKill delivers no
  SIGTERM at all, so a worker can vanish with its job still claimed, and the
  reaper is the only thing that reclaims it. The threshold stays above the 105min
  job-abort and 150min claim timeouts — a lower one would kill live work and call
  it cleanup, surfacing as random job loss under load.

## [0.2.1] — 2026-07-30 · Kodus 2.1.28

Patch: only the Kodus release moved. No chart templates changed.

### Changed

- `appVersion` / `imageTag` → `2.1.28`. Opened by `bump-app-version.yml`, its
  first real run: it confirmed all five images exist at that version and installed
  the chart on a kind cluster with them before raising the PR.

### Fixed

- Three tests asserted the shipped `appVersion` literally, so they failed on this
  very bump — the automated PR that exists to make Kodus releases routine broke
  the build instead. One of them had also gone quietly vacuous: it used the next
  real release number as "a version different from `appVersion`", and once
  `appVersion` caught up, the assertion passed whether or not the override was
  honoured. All three now pin a version no release will carry.
- `bump-app-version.yml` validated only that the chart *installs* with the new
  images. The PR it opens receives no checks at all — GitHub does not run
  workflows on a `GITHUB_TOKEN` PR — so anything past the install check reached
  `main` unverified, which is how the above landed. It now runs lint, the unit
  tests and the schema anti-drift check before opening the PR.

### Documented

- The GitHub package page shows the cosign signature (`sha256-…`) as **Latest**
  and builds its `docker pull` snippet from it, because it renders every registry
  as if it held container images. Copying that command fails with
  `no matching manifest`. Both READMEs now say so, and say why the signatures are
  not moved elsewhere to hide it.

## [0.2.0] — 2026-07-29 · Kodus 2.1.27

First published version. Earlier chart versions existed only in git and were
installed from a checkout, so this is where the history usefully starts.

### Added

- **Published to `ghcr.io` as a signed OCI artifact.** Installing no longer needs a
  clone: `helm install kodus oci://ghcr.io/kodustech/charts/kodus --version 0.2.0`.
  Every release carries a keyless cosign signature and a provenance attestation,
  both bound to the manifest digest rather than the tag — a tag can be moved to a
  different manifest, a digest cannot. See
  [Verifying what you're about to install](README.md#verifying-what-youre-about-to-install).
- **Deployment fingerprint** on the ConfigMap — chart version, effective Kodus
  version, platform, datastore modes, per-service tags, ingress vs route, secret
  source, hardening flags. `doctor-k8s.sh` prints it ready to paste into a support
  ticket. It records which knobs are set, never what they are set to when the value
  is yours: no hostnames, no URLs, no secrets, and nothing is transmitted anywhere.
- **`helm test` hooks for the webhooks service and the datastores.** The webhooks
  hook probes `/health/ready` through the Service, which is the only way to catch a
  broken selector or an unpopulated EndpointSlice on the one service the app never
  dials itself. The datastore hook opens a TCP connection using the same env block
  the app pods get, in whatever mode each store is in.
- **`doctor-k8s.sh --profile prod|dev`.** Health checks stay strict under both;
  production-readiness findings drop to warnings under `dev`, so a local trial
  stops reporting intentional configuration as failure.

### Changed

- **`imageTag` is now pinned** (`2.1.27`) instead of `latest`, and matches
  `appVersion`. A floating tag cannot survive a published chart:
  `helm rollback kodus 0.2.0` restores values, not image content, so the images
  would re-resolve to whatever is newest and the rollback would silently do
  nothing. `values-dev.yaml` deliberately keeps `latest`.
- **`app.kubernetes.io/version` reports the image a workload is actually running**,
  resolved the same way `deployment.yaml` resolves it, rather than the chart's
  `appVersion`. Anyone who set `--set imageTag=` previously got a label confidently
  stating the wrong release. The bundled datastores keep `appVersion` — they run
  images this chart does not version.

### Fixed

- **PodDisruptionBudgets no longer forbid every eviction.** A PDB was generated for
  every service including single-replica ones, where `minAvailable: 1` against one
  healthy pod yields `disruptionsAllowed = 0` — not slower evictions but no
  evictions, ever, with `kubectl drain` hanging on the pod and naming the pod
  rather than the PDB. PDBs are now generated only above a replica floor of 1, and
  the chart refuses to render a `pdb.minAvailable` that recreates the deadlock.
- **The web liveness probe uses `/api/health`** instead of `/`. Probing `/`
  server-rendered the whole sign-in page, tying pod health to the React tree, so a
  rendering regression on one page read as a dead pod and CrashLooped the service.
- **The doctor no longer reports a healthy rollout as an outage.** Pods draining
  their `terminationGracePeriod` after `helm upgrade` counted as failures; they are
  now an informational warning.
- **A service named after a bundled datastore fails the render.** `postgres`,
  `mongodb` and `rabbitmq` under `.Values.services` would produce a Service whose
  selector matches the *database* pods, silently balancing app traffic onto
  Postgres. Splitting the labels is not possible on an existing release —
  `Deployment.spec.selector` is immutable — so the chart fails fast with a message
  naming the collision.

### Known limitations

Stated because a green CI badge does not cover these:

- The E2E installs the `values-dev` profile. **The production configuration —
  `networkPolicy`, PDB and autoscaling enabled — has never been installed on any
  cluster**, and kind's default CNI would not enforce NetworkPolicy anyway.
- OpenShift `Route` and `SecurityContextConstraints` are rendered and
  schema-validated, never installed.
- Only `bundled` datastores are exercised. `external` and `operator` modes are
  rendered only.
- The bundled datastore StatefulSets reference a ClusterIP Service rather than a
  headless one. Harmless at `replicas: 1`, and unfixable in place — both
  `serviceName` and `clusterIP` are immutable. See the comments in
  `templates/datastores/`.
