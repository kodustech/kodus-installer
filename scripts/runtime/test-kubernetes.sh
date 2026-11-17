#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted SQL and scripts run elsewhere
# A real install of charts/kodus-runtime on a throwaway kind cluster, with
# nothing on any cloud:
#   1. kind (one node) with Calico (Apache-2.0, manifest pinned by SHA-256)
#      in place of kind's default CNI, which does not enforce egress to
#      addresses outside the pod network (the cell's preflight refuses it);
#      gVisor installed into the node from the release pinned in
#      runtime/gvisor.tsv (checked by SHA-512) and registered with containerd
#      as the runsc handler; a local registry, so every image is pulled by
#      digest as the chart requires;
#   2. a throwaway Postgres and RabbitMQ in namespace kodus (the product's
#      stores; no product runs: the exchanges its API declares and the
#      runtime_secrets table its migration makes are made by hand);
#   3. helm install without a RuntimeClass must fail and say so; then helm
#      install with the chart's RuntimeClass (handler runsc);
#   4. a registration token for a synthetic organization, recorded as the
#      runtime-worker records the API's; the cell registers, passes its
#      preflight and connects;
#   5. scripts/runtime/smoke-sandbox.js in the runtime-worker: a code sandbox
#      claim runs (its pod on the gvisor class, its kernel gVisor's), runs a
#      command, reaches the allowed host and is refused another;
#   6. helm uninstall (purgeDataOnUninstall) leaves no object of the release in
#      the cluster and no Runtime database; then the cluster goes (unless --keep).
#
# What is not the release: the hub and the runtime-worker are this branch's
# webpack bundles with only the packages they require, the cell image is the
# cell binaries built here on the release's distroless base, and the sandbox
# image is node:22 with the guest agent only.
#
# Usage (macOS or Linux with Docker, from this checkout):
#   scripts/runtime/test-kubernetes.sh --kodus-ai <kodus-ai checkout> [--keep]
# The kodus-ai checkout needs node_modules (a symlink is fine) and Go.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER=kr-k8s REGISTRY=kr-k8s-registry KEEP=0 KODUS_AI=''
NS=kodus RELEASE=kr CELL_NS=kodus-runtime-cell SBX_NS=kodus-runtime-sandboxes
while [ $# -gt 0 ]; do
    case "$1" in
        --kodus-ai) KODUS_AI=$(cd "${2:?}" && pwd); shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h | --help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -d "$KODUS_AI/apps/runtime-cell" ] && [ -d "$KODUS_AI/apps/runtime" ] || { echo "--kodus-ai must be a kodus-ai checkout with apps/runtime and apps/runtime-cell" >&2; exit 2; }
[ -d "$KODUS_AI/node_modules/@dbos-inc" ] || { echo "$KODUS_AI/node_modules must hold the Runtime's dependencies (@dbos-inc/dbos-sdk)" >&2; exit 2; }
for c in kind kubectl helm docker go shasum; do command -v "$c" >/dev/null || { echo "$c is required" >&2; exit 2; }; done

WORK="$ROOT/runtime/state/test-kubernetes"
rm -rf "$WORK" && mkdir -p "$WORK"
export KUBECONFIG="$WORK/kubeconfig"
step() { printf '\n== %s\n' "$*"; }
k() { kubectl "$@"; }
image_of() { awk -F '\t' -v c="$1" '$1 == "any" && $2 == c { print $3 }' "$ROOT/runtime/images.lock"; }

teardown() {
    if [ "$KEEP" = 0 ]; then
        kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
        docker rm -f "$REGISTRY" >/dev/null 2>&1 || true
        echo "== cluster $CLUSTER and registry $REGISTRY deleted"
    else
        echo "== kept: kind delete cluster --name $CLUSTER; docker rm -f $REGISTRY (KUBECONFIG=$KUBECONFIG)"
    fi
}
trap teardown EXIT

case "$(uname -m)" in arm64 | aarch64) ARCH=arm64 GV_ARCH=aarch64 ;; x86_64) ARCH=amd64 GV_ARCH=x86_64 ;; *) echo "unsupported architecture" >&2; exit 2 ;; esac

CALICO_VERSION=v3.30.3
CALICO_SHA256=9382d2b27a76f40c170454b408653e6d71e2205ef0aef069e942bb690e7381d0
step "kind cluster $CLUSTER (one node, Calico $CALICO_VERSION), containerd reading registry hosts from certs.d and knowing the runsc handler"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
cat >"$WORK/kind.yaml" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
      runtime_type = "io.containerd.runsc.v1"
networking:
  disableDefaultCNI: true
  podSubnet: 10.244.0.0/16
nodes:
  - role: control-plane
EOF
kind create cluster --name "$CLUSTER" --config "$WORK/kind.yaml" --kubeconfig "$KUBECONFIG"
curl -fsSL -o "$WORK/calico.yaml" "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml"
[ "$(shasum -a 256 "$WORK/calico.yaml" | cut -d' ' -f1)" = "$CALICO_SHA256" ] || { echo "FAILED calico.yaml is not the pinned $CALICO_VERSION"; exit 1; }
# The pool is kind's pod subnet (Calico's default, 192.168.0.0/16, is where Docker puts kind's network).
sed -e 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' -e 's|#   value: "192.168.0.0/16"|  value: "10.244.0.0/16"|' "$WORK/calico.yaml" | k apply -f - >/dev/null
k -n kube-system rollout status ds/calico-node --timeout=300s
k wait --for=condition=Ready node --all --timeout=300s
NODE="$CLUSTER-control-plane"
echo "node: $(k get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion} {.items[0].status.nodeInfo.containerRuntimeVersion} {.items[0].status.nodeInfo.architecture}')"

step "gVisor into the node: the release runtime/gvisor.tsv pins, checked by SHA-512"
read -r GV_RELEASE GV_SHA < <(awk -F '\t' -v a="$GV_ARCH" '!/^#/ && $2 == a { print $1, $3 }' "$ROOT/runtime/gvisor.tsv" | tail -1)
mkdir -p "$WORK/gvisor"
curl -fsSL -o "$WORK/gvisor/gvisor.tar.bz2" "https://storage.googleapis.com/gvisor/releases/release/$GV_RELEASE/$GV_ARCH/gvisor.tar.bz2"
[ "$(shasum -a 512 "$WORK/gvisor/gvisor.tar.bz2" | cut -d' ' -f1)" = "$GV_SHA" ] || { echo "FAILED gvisor.tar.bz2 is not the pinned $GV_RELEASE"; exit 1; }
(cd "$WORK/gvisor" && tar -xjf gvisor.tar.bz2 runsc containerd-shim-runsc-v1 gvisor-bin)
# runsc looks for its sidecars (gvisor_sentry and the rest) in gvisor-bin next to it.
(cd "$WORK/gvisor" && COPYFILE_DISABLE=1 tar -cf - runsc containerd-shim-runsc-v1 gvisor-bin) | docker exec -i "$NODE" tar -C /usr/local/bin -xf - 2>/dev/null
docker exec "$NODE" sh -c 'chmod 0755 /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 && runsc --version | head -1'

step "local registry $REGISTRY: the node pulls localhost:5001 from it"
docker rm -f "$REGISTRY" >/dev/null 2>&1 || true
docker run -d --name "$REGISTRY" --network kind -p 127.0.0.1:5001:5000 "$(image_of registry)" >/dev/null
docker exec "$NODE" sh -c 'mkdir -p /etc/containerd/certs.d/localhost:5001 && printf "[host.\"http://'"$REGISTRY"':5000\"]\n" > /etc/containerd/certs.d/localhost:5001/hosts.toml'

step "images: the cell, the test sandbox, the control plane; pushed, referenced by digest"
B="$WORK/build"
mkdir -p "$B/cell" "$B/sandbox" "$B/cp"
(cd "$KODUS_AI/apps/runtime-cell" && for c in cell egress injector reaper kody-guest; do
    CGO_ENABLED=0 GOOS=linux GOARCH=$ARCH go build -trimpath -ldflags "-s -w" -o "$B/cell/$c" "./cmd/$c"
done)
DISTROLESS=$(sed -n 's/^FROM \(gcr.io\/distroless\/static-debian12:nonroot@sha256:[0-9a-f]*\).*/\1/p' "$KODUS_AI/apps/runtime-cell/Dockerfile")
printf 'FROM %s\nCOPY cell egress injector reaper /usr/local/bin/\nUSER nonroot:nonroot\nENTRYPOINT ["/usr/local/bin/cell"]\n' "$DISTROLESS" >"$B/cell/Dockerfile"
NODE_IMAGE=docker.io/library/node:22.23.4-slim
cp "$B/cell/kody-guest" "$B/sandbox/kody-guest"
printf 'FROM %s\nCOPY kody-guest /usr/local/bin/kody-guest\nUSER 1000\n' "$NODE_IMAGE" >"$B/sandbox/Dockerfile"
# The control plane: this branch's webpack bundles (no filesystem cache, so
# the shared node_modules/.cache is not written) and the packages they require.
printf "const base = require(%s);\nmodule.exports = (o, w) => ({ ...base(o, w), cache: false });\n" "'$KODUS_AI/webpack.config.js'" >"$B/webpack.js"
WEBPACK_REL=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$B/webpack.js" "$KODUS_AI")
(cd "$KODUS_AI" && rm -rf dist/apps/runtime && for a in runtime-hub runtime-worker; do node_modules/.bin/nest build "$a" --webpack --webpackPath "$WEBPACK_REL" | tail -1; done)
cp -R "$KODUS_AI/dist/apps/runtime" "$B/cp/runtime-dist"
(cd "$KODUS_AI" && node -e '
const fs = require("fs"), builtin = require("module").builtinModules, deps = {};
// Nest loads its HTTP platform by name at runtime, not through a require webpack sees.
for (const p of ["@nestjs/platform-express"]) deps[p] = JSON.parse(fs.readFileSync(`node_modules/${p}/package.json`, "utf8")).version;
const files = ["hub", "worker"].flatMap((d) => fs.readdirSync("dist/apps/runtime/" + d).filter((f) => f.endsWith(".js")).map((f) => `dist/apps/runtime/${d}/${f}`));
for (const f of files) for (const m of fs.readFileSync(f, "utf8").matchAll(/require\("([^".][^"]*)"\)/g)) {
  const r = m[1]; if (builtin.includes(r) || r.startsWith("node:")) continue;
  const p = r.startsWith("@") ? r.split("/").slice(0, 2).join("/") : r.split("/")[0];
  deps[p] = JSON.parse(fs.readFileSync(`node_modules/${p}/package.json`, "utf8")).version;
}
fs.writeFileSync(process.argv[1], JSON.stringify({ name: "kodus-runtime-control-plane-test", private: true, dependencies: deps }, null, 1));' "$B/cp/package.json")
cat >"$B/cp/Dockerfile" <<EOF
FROM $NODE_IMAGE
WORKDIR /usr/src/app
ENV NODE_ENV=production RUNTIME_PRODUCTION_IMAGE=1 RUN_MIGRATIONS=false
COPY package.json ./
RUN npm install --omit=dev --legacy-peer-deps --ignore-scripts --no-audit --no-fund && npm cache clean --force
COPY --chown=1000:1000 runtime-dist ./dist/apps/runtime
USER 1000
EOF
digest_of() { # digest_of DIR NAME: build, push, print localhost:5001/NAME@sha256:...
    docker build -q --platform "linux/$ARCH" -t "localhost:5001/$2:test" "$1" >/dev/null
    docker push -q "localhost:5001/$2:test" >/dev/null
    docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "localhost:5001/$2:test" | grep '^localhost:5001/' | head -1
}
CELL_IMAGE=$(digest_of "$B/cell" kodus-runtime-cell)
SANDBOX_IMAGE=$(digest_of "$B/sandbox" kodus-runtime-sandbox)
CP_IMAGE=$(digest_of "$B/cp" kodus-runtime-control-plane)
printf 'cell     %s\nsandbox  %s\ncontrol  %s\n' "$CELL_IMAGE" "$SANDBOX_IMAGE" "$CP_IMAGE"

step "the product's stores in $NS: a throwaway Postgres and RabbitMQ"
PGPW=$(openssl rand -hex 16) MQPW=$(openssl rand -hex 16)
k create namespace "$NS" >/dev/null
k -n "$NS" create secret generic kodus-postgres-admin --from-literal=username=kodus --from-literal=password="$PGPW" >/dev/null
k -n "$NS" create secret generic kodus-rabbitmq-admin --from-literal=username=kodus --from-literal=password="$MQPW" >/dev/null
PG_IMAGE=docker.io/library/postgres:16-alpine@sha256:f377d590e5474681d4d7838635031a2b50647923b7abfa803ce9b5ff35d5c663
MQ_IMAGE=docker.io/library/rabbitmq:4.1-management-alpine@sha256:42c6214e0e2093caa2484718faacb733631cc9ddc869b3298397613237dbea4a
cat <<EOF | k -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: kodus-postgres, labels: { app: kodus-postgres } }
spec:
  containers:
    - name: postgres
      image: $PG_IMAGE
      env:
        - { name: POSTGRES_USER, value: kodus }
        - { name: POSTGRES_DB, value: kodus_db }
        - name: POSTGRES_PASSWORD
          valueFrom: { secretKeyRef: { name: kodus-postgres-admin, key: password } }
      readinessProbe: { exec: { command: ["pg_isready", "-U", "kodus"] }, periodSeconds: 2 }
      resources: { limits: { memory: 512Mi } }
---
apiVersion: v1
kind: Service
metadata: { name: kodus-postgres }
spec: { selector: { app: kodus-postgres }, ports: [{ port: 5432 }] }
---
apiVersion: v1
kind: Pod
metadata: { name: kodus-rabbitmq, labels: { app: kodus-rabbitmq } }
spec:
  containers:
    - name: rabbitmq
      image: $MQ_IMAGE
      env:
        - { name: RABBITMQ_DEFAULT_USER, value: kodus }
        - name: RABBITMQ_DEFAULT_PASS
          valueFrom: { secretKeyRef: { name: kodus-rabbitmq-admin, key: password } }
      # A TCP probe: an exec'd rabbitmq-diagnostics can write the Erlang cookie as
      # root before the server starts, which then cannot read it.
      readinessProbe: { tcpSocket: { port: 5672 }, periodSeconds: 5 }
      resources: { limits: { memory: 512Mi } }
---
apiVersion: v1
kind: Service
metadata: { name: kodus-rabbitmq }
spec: { selector: { app: kodus-rabbitmq }, ports: [{ name: amqp, port: 5672 }, { name: mgmt, port: 15672 }] }
EOF
k -n "$NS" wait --for=condition=Ready pod/kodus-postgres pod/kodus-rabbitmq --timeout=300s
# The vhost and the exchanges the product's API declares at its boot. The
# retry exchange is x-delayed-message there, which needs a plugin this image
# lacks: a direct exchange here (the worker only checks that it exists; no Run
# retries in this test).
cat <<EOF | k -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: kodus-rabbitmq-setup }
spec:
  restartPolicy: OnFailure
  containers:
    - name: setup
      image: $CP_IMAGE
      env:
        - name: PW
          valueFrom: { secretKeyRef: { name: kodus-rabbitmq-admin, key: password } }
      command: ["node", "-e", "const a='Basic '+Buffer.from('kodus:'+process.env.PW).toString('base64'); const b='http://kodus-rabbitmq:15672/api'; const put=(p,x)=>fetch(b+p,{method:'PUT',headers:{authorization:a,'content-type':'application/json'},body:JSON.stringify(x)}).then(r=>{if(r.status>=300) throw new Error(p+' '+r.status)}); (async()=>{await put('/vhosts/kodus-ai',{}); await put('/permissions/kodus-ai/kodus',{configure:'.*',write:'.*',read:'.*'}); for (const [n,t] of [['workflow.exchange','topic'],['workflow.exchange.dlx','topic'],['workflow.exchange.runtime_retry','headers'],['workflow.exchange.runtime_retry.return','direct']]) await put('/exchanges/kodus-ai/'+n,{type:t,durable:true}); console.log('vhost and exchanges declared')})().catch(e=>{console.error(e.message);process.exit(1)})"]
EOF
k -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/kodus-rabbitmq-setup --timeout=180s
k -n "$NS" logs kodus-rabbitmq-setup
k -n "$NS" delete pod kodus-rabbitmq-setup --wait=false >/dev/null
psql_admin() { k -n "$NS" exec -i kodus-postgres -- psql -U kodus -d "$1" -Atq -v ON_ERROR_STOP=1 "${@:2}"; }
# The table the product's migration makes, with the columns the hub reads; empty.
psql_admin kodus_db -c "CREATE TABLE IF NOT EXISTS public.runtime_secrets (organization_id uuid, secret_id uuid, name text, hosts text[])"

VALUES="$WORK/values.yaml"
TOKEN="kcr_$(openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
ORG=$(uuidgen | tr 'A-Z' 'a-z')
cat >"$VALUES" <<EOF
images:
  hub: $CP_IMAGE
  worker: $CP_IMAGE
  cell: $CELL_IMAGE
  sandbox: $SANDBOX_IMAGE
postgres:
  host: kodus-postgres.$NS.svc
  admin: { existingSecret: kodus-postgres-admin }
rabbitmq:
  host: kodus-rabbitmq.$NS.svc
  admin: { existingSecret: kodus-rabbitmq-admin }
controlPlane:
  releaseVersion: unreleased-k8s-test
  purgeDataOnUninstall: true
  worker:
    evidence: { persistence: { size: 1Gi } }
cell:
  registration: { token: "$TOKEN" }
  sandbox: { memoryMb: 1024, cpus: 1 }
  quota: { pods: 6, cpu: "4", memory: 8Gi }
EOF

step "helm install without the RuntimeClass: refused, naming it"
if helm install "$RELEASE" "$ROOT/charts/kodus-runtime" -n "$NS" -f "$VALUES" >"$WORK/no-class.log" 2>&1; then
    echo "FAILED helm install passed without a RuntimeClass"; exit 1
fi
grep -o 'the RuntimeClass "gvisor" does not exist in this cluster[^.]*' "$WORK/no-class.log" || { cat "$WORK/no-class.log"; echo "FAILED another error than the RuntimeClass"; exit 1; }
helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true

step "helm install (the chart's RuntimeClass gvisor, handler runsc)"
helm install "$RELEASE" "$ROOT/charts/kodus-runtime" -n "$NS" -f "$VALUES" --set cell.runtimeClass.create=true
HUB=$(k -n "$NS" get deploy -l app.kubernetes.io/component=hub -o name)
WORKER=$(k -n "$NS" get deploy -l app.kubernetes.io/component=worker -o name)
CELL=$(k -n "$CELL_NS" get deploy -l app.kubernetes.io/component=cell -o name)
k -n "$NS" rollout status "$HUB" --timeout=600s
rt_sql() { psql_admin kodus_runtime -c "$1"; }

step "a registration token for organization $ORG (as the runtime-worker records the API's)"
HASH=$(printf '%s' "$TOKEN" | shasum -a 256 | cut -d' ' -f1)
for i in $(seq 1 60); do
    rt_sql "SELECT 1 FROM runtime.runtime_cell_tokens LIMIT 0" >/dev/null 2>&1 && break
    [ "$i" = 60 ] && { echo "FAILED the hub never made runtime.runtime_cell_tokens"; exit 1; }
    sleep 5
done
rt_sql "INSERT INTO runtime.runtime_cell_tokens (token_hash, organization_id, topology, expires_at, issued_by)
        VALUES ('$HASH', '$ORG', 'self_hosted', now() + interval '15 minutes', 'test-kubernetes')"

step "the cell registers, passes its preflight and connects"
for i in $(seq 1 90); do
    [ "$(rt_sql "SELECT count(*) FROM runtime.runtime_cells WHERE organization_id = '$ORG' AND status = 'connected'" 2>/dev/null)" = 1 ] && break
    [ "$i" = 90 ] && { k -n "$CELL_NS" get pods; k -n "$CELL_NS" logs "$CELL" --all-containers --tail 40 || true; echo "FAILED the cell did not connect"; exit 1; }
    sleep 5
done
CELL_ID=$(rt_sql "SELECT cell_id FROM runtime.runtime_cells WHERE organization_id = '$ORG'")
rt_sql "SELECT 'cell ' || cell_id || ': owner ' || owner || ', topology ' || topology || ', ' || status FROM runtime.runtime_cells WHERE cell_id = '$CELL_ID'"
k -n "$CELL_NS" logs "$CELL" -c cell | grep -E '"msg":"(cell.start|k8s.preflight.passed)"' | head -3
k -n "$NS" rollout status "$WORKER" --timeout=600s
for i in $(seq 1 60); do
    [ "$(rt_sql "SELECT coalesce(max(free_slots), 0) FROM runtime.runtime_cell_sessions WHERE cell_id = '$CELL_ID'")" -gt 0 ] 2>/dev/null && break
    [ "$i" = 60 ] && { echo "FAILED the cell never reported free slots"; exit 1; }
    sleep 5
done
for i in $(seq 1 60); do
    k -n "$NS" exec "$WORKER" -- node -e "require('net').connect(3430,'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))" 2>/dev/null && break
    [ "$i" = 60 ] && { echo "FAILED the runtime-worker's sandbox listener never opened"; exit 1; }
    sleep 5
done

step "a sandbox claim on the cell: scripts/runtime/smoke-sandbox.js in the runtime-worker"
# While the claim exists: its pod's class, the handler containerd ran it
# with, and the kernel it sees.
( for _ in $(seq 1 300); do
    for p in $(k -n "$SBX_NS" get pods -l kodus.io/role=workload -o name 2>/dev/null); do
        if ! grep -q "^$p " "$WORK/claim-pods.txt" 2>/dev/null; then
            id=$(docker exec "$NODE" crictl pods --name "${p#pod/}" -q 2>/dev/null | head -1)
            printf '%s class=%s handler=%s kernel=%s\n' "$p" \
                "$(k -n "$SBX_NS" get "$p" -o jsonpath='{.spec.runtimeClassName}')" \
                "$(docker exec "$NODE" crictl inspectp "$id" 2>/dev/null | grep -m1 '"runtimeHandler"' | tr -d ' ",' | cut -d: -f2)" \
                "$(k -n "$SBX_NS" exec "$p" -c sandbox -- uname -r 2>/dev/null)" >>"$WORK/claim-pods.txt"
        fi
    done
    sleep 1
done ) &
WATCH=$!
k -n "$NS" exec -i "$WORKER" -- sh -c 'cat >/tmp/smoke-sandbox.js && SMOKE_ORG="$1" SMOKE_ALLOWED_HOST=github.com SMOKE_DENIED_HOST=example.com node /tmp/smoke-sandbox.js' smoke "$ORG" <"$ROOT/scripts/runtime/smoke-sandbox.js"
sleep 2
kill "$WATCH" 2>/dev/null || true
cat "$WORK/claim-pods.txt"
grep -q 'class=gvisor handler=runsc kernel=.*gvisor' "$WORK/claim-pods.txt" || { echo "FAILED the sandbox pod did not run under runsc"; exit 1; }
k -n "$CELL_NS" logs "$CELL" -c egress 2>/dev/null | grep -m2 'example.com' || true

step "helm uninstall leaves nothing"
helm uninstall "$RELEASE" -n "$NS" --wait --timeout 300s
for i in $(seq 1 60); do
    [ -z "$(k get namespace "$CELL_NS" "$SBX_NS" --ignore-not-found -o name)" ] && break
    [ "$i" = 60 ] && { echo "FAILED the cell namespaces are still there"; exit 1; }
    sleep 3
done
left=$(k get all,configmap,secret,pvc,serviceaccount,role,rolebinding,networkpolicy,resourcequota,limitrange,cronjob,job -A -l app.kubernetes.io/instance="$RELEASE" -o name 2>/dev/null || true)
left="$left$(k get validatingadmissionpolicy,validatingadmissionpolicybinding,runtimeclass,clusterrole,clusterrolebinding -l app.kubernetes.io/instance="$RELEASE" -o name 2>/dev/null || true)"
left="$left$(k -n "$NS" get secret -o name | grep -v -e kodus-postgres-admin -e kodus-rabbitmq-admin || true)"
if [ -n "$left" ]; then echo "$left"; echo "FAILED objects of the release are left"; exit 1; fi
echo "no object of release $RELEASE is left in the cluster"
dbs=$(psql_admin postgres -c "SELECT string_agg(datname, ',') FROM pg_database WHERE datname IN ('kodus_runtime', 'kodus_openbao')")
roles=$(psql_admin postgres -c "SELECT string_agg(rolname, ',') FROM pg_roles WHERE rolname LIKE 'kodus_runtime%' OR rolname = 'openbao'")
[ -z "$dbs$roles" ] || { echo "FAILED left in Postgres: databases '$dbs' roles '$roles'"; exit 1; }
echo "no Runtime database or role is left in Postgres"
echo "PASSED helm install, registration, preflight, a sandbox claim under runsc, the egress allow-list, helm uninstall"
