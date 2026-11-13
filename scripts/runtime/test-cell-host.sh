#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted scripts run in the container's sh
# Tests scripts/runtime/cell-host.sh in a throwaway Ubuntu container: nothing
# is installed on the machine that runs it, and the container never sees this
# machine's Docker (a stub answers `docker info`).
#   - the profile checks: a Docker without runsc and a host without /dev/kvm
#     each fail naming that requirement; kubernetes names what it misses;
#   - a dry run of `install --profile docker-gvisor`: gVisor's archive
#     downloaded and checked against the pinned SHA-512 (a corrupted one is
#     refused), runsc unpacked and run, the cell's PKI, config and units
#     written, the units accepted by systemd-analyze;
#   - the real cell release binaries (--cell-bin-dir) take the generated
#     config and flags: the agent refuses to start for the missing runsc, the
#     egress and the injector start with the units' arguments and serve TLS
#     with the cell-local CA.
# Usage: scripts/runtime/test-cell-host.sh [--cell-bin-dir DIR]
#   DIR holds cell, egress, injector, observer and reaper for linux/<this
#   machine's arch>, e.g. copied out of a local build of the cell image:
#     docker buildx build --load -t kodus-runtime-cell:local -f apps/runtime-cell/Dockerfile apps/runtime-cell
#     id=$(docker create kodus-runtime-cell:local); docker cp "$id":/usr/local/bin/. DIR; docker rm "$id"
#   Without it the binary checks are skipped.
set -euo pipefail
UBUNTU=docker.io/library/ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5

if [ "${1:-}" != --inside ]; then
    SRC="$(cd "$(dirname "$0")/../.." && pwd)"
    BIN=''
    [ "${1:-}" = --cell-bin-dir ] && BIN="$(cd "${2:?}" && pwd)"
    exec docker run --rm -v "$SRC:/installer:ro" ${BIN:+-v "$BIN:/cellbin:ro"} "$UBUNTU" \
        bash /installer/scripts/runtime/test-cell-host.sh --inside
fi

# --- inside the container ---------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends curl ca-certificates openssl bzip2 systemd jq >/dev/null 2>&1
mkdir -p /tmp/cp && (cd /installer && tar -cf - --exclude ./runtime/state .) | tar -C /tmp/cp -xf -
CH=/tmp/cp/scripts/runtime/cell-host.sh

# A docker that answers like a rootful Engine 27 whose runtimes are STUB_RUNTIMES.
mkdir -p /opt/stub
cat >/opt/stub/docker <<'EOF'
#!/bin/sh
RUNTIMES=${STUB_RUNTIMES:-}
[ -n "$RUNTIMES" ] || RUNTIMES='{"io.containerd.runc.v2":{},"runc":{}}'
case "$1 $2" in
    "version --format") echo 27.3.1 ;;
    "info --format")
        case "$3" in
            *Runtimes*) echo "$RUNTIMES" ;;
            *SecurityOptions*) echo '["name=seccomp,profile=builtin","name=cgroupns"]' ;;
            *) echo '{}' ;;
        esac ;;
    "info "*) echo "Runtimes: $RUNTIMES" ;;
    *) echo "docker stub: $*" >&2; exit 1 ;;
esac
EOF
chmod 755 /opt/stub/docker
ln -sf /opt/stub/docker /usr/bin/docker
mkdir -p /tmp/fake-systemd-run
export KODUS_CELL_SYSTEMD_RUN=/tmp/fake-systemd-run

pass=0 fail=0
t() {
    local name=$1
    shift
    if "$@" >/tmp/out 2>&1; then
        pass=$((pass + 1)); printf 'ok    %s\n' "$name"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n' "$name"; sed 's/^/      /' /tmp/out | tail -20
    fi
}
fails_with() { # the command exits non-zero and its output holds every TEXT
    local out rc=0
    out=$("${@:2}" 2>&1) || rc=$?
    [ "$rc" != 0 ] || { echo "exit 0, expected a failure"; printf '%s\n' "$out"; return 1; }
    printf '%s\n' "$out" | grep -qF -- "$1" || { printf 'no "%s" in:\n%s\n' "$1" "$out"; return 1; }
}
has() { grep -qF -- "$1" "$2" || { echo "no \"$1\" in $2"; cat "$2"; return 1; }; }

echo "== profile checks"
t "docker-gvisor without runsc fails naming runsc" fails_with 'missing  runsc is not registered as a Docker runtime named "runsc"' $CH check --profile docker-gvisor
t "docker-firecracker without /dev/kvm fails naming /dev/kvm" fails_with "missing  /dev/kvm is missing: the firecracker backend needs KVM" $CH check --profile docker-firecracker
t "docker-firecracker names the unreleased backend" fails_with "has no firecracker backend (phase P2)" $CH check --profile docker-firecracker
t "docker-firecracker names the unpublished microVM kit" fails_with "the microVM kit (firecracker + jailer" $CH check --profile docker-firecracker
t "kubernetes names kubectl and the missing chart" fails_with "no cell runs on Kubernetes yet" $CH check --profile kubernetes
t "docker-gvisor with runsc registered passes the runsc check" sh -c "STUB_RUNTIMES='{\"runc\":{},\"runsc\":{\"path\":\"/usr/local/bin/runsc\"}}' $CH check --profile docker-gvisor | grep -q 'ok       runsc registered'"
t "rootless Docker is refused" sh -c "cp /opt/stub/docker /opt/stub/docker-rootless && sed -i 's/name=cgroupns/name=rootless/' /opt/stub/docker-rootless && KODUS_CELL_DOCKER=/opt/stub/docker-rootless $CH check --profile docker-gvisor | grep -q 'Docker runs rootless'"
t "no systemd is refused" sh -c "KODUS_CELL_SYSTEMD_RUN=/nonexistent $CH check --profile docker-gvisor | grep -q 'systemd is not running'"

echo "== control-plane bundle"
cp /tmp/cp/.env.example /tmp/cp/.env
t "generate.sh as root" /tmp/cp/scripts/runtime/generate.sh --hub-host hub.example.internal --openbao-host 10.20.30.40
t "state owned by uid 1000" sh -c '[ "$(stat -c %u /tmp/cp/runtime/state/secrets.env)" = 1000 ]'
BUNDLE=/tmp/cp/runtime/state/cell-host

echo "== install --dry-run (docker-gvisor)"
KODUS_RUNTIME_BUILDER_IMAGE="example.invalid/kodus-runtime-builder@sha256:$(printf '%064d' 1)"
KODUS_RUNTIME_SANDBOX_IMAGE="example.invalid/kodus-runtime-sandbox@sha256:$(printf '%064d' 2)"
export KODUS_RUNTIME_BUILDER_IMAGE KODUS_RUNTIME_SANDBOX_IMAGE
BIN_ARGS=()
if [ -d /cellbin ]; then BIN_ARGS=(--cell-bin-dir /cellbin); else
    mkdir -p /tmp/fakebin && for b in cell egress injector observer reaper; do printf '#!/bin/sh\nexit 0\n' >/tmp/fakebin/$b; chmod 755 /tmp/fakebin/$b; done
    BIN_ARGS=(--cell-bin-dir /tmp/fakebin)
fi
t "install --dry-run succeeds" sh -c "$CH install --profile docker-gvisor --bundle $BUNDLE ${BIN_ARGS[*]} --min-free-gb 1 --dry-run >/tmp/install.log 2>&1"
sed "s/^/      | /" /tmp/install.log | head -60
t "gVisor archive verified against the pin" has "SHA-512 verified" /tmp/install.log
t "runsc registered with Docker (dry run)" has "[dry-run] /usr/local/bin/runsc install --runtime runsc" /tmp/install.log
t "Docker reloaded, not restarted (dry run)" has "[dry-run] systemctl reload docker" /tmp/install.log
t "cell register with the token in the env, topology self_hosted" has "[dry-run] KODUS_CELL_REGISTRATION_TOKEN=<token> /opt/kodus-cell/current/bin/cell register -hub https://hub.example.internal:3410" /tmp/install.log
t "units enabled and started (dry run)" has "[dry-run] systemctl restart kodus-cell.target" /tmp/install.log
t "runsc runs" sh -c '/usr/local/bin/runsc --version | grep -q "release-20261026.0"'
t "containerd shim installed" test -x /usr/local/bin/containerd-shim-runsc-v1
printf 'not the archive' >/tmp/bad.tar.bz2
t "a corrupted gVisor archive is refused" fails_with "does not match the SHA-512 pinned in runtime/gvisor.tsv" \
    $CH install --profile docker-gvisor --bundle $BUNDLE "${BIN_ARGS[@]}" --min-free-gb 1 --gvisor-archive /tmp/bad.tar.bz2 --dry-run

echo "== what install wrote"
for u in kodus-cell-injector.service kodus-cell-egress.service kodus-cell.service kodus-cell.target kodus-cell-reaper.service kodus-cell-reaper.timer; do
    t "unit $u" test -s /etc/systemd/system/$u
done
t "units name the real docker path" sh -c '! grep -l @DOCKER@ /etc/systemd/system/kodus-cell-*.service && grep -q "ExecStart=/usr/bin/docker start -a" /etc/systemd/system/kodus-cell-egress.service'
t "reaper runs the binary the release ships (not /usr/local/bin/kodus-reaper)" has "ExecStart=/opt/kodus-cell/current/bin/reaper -once" /etc/systemd/system/kodus-cell-reaper.service
t "reaper binary exists at that path" test -x /opt/kodus-cell/current/bin/reaper
printf '[Unit]\nDescription=stub\n[Service]\nExecStart=/bin/true\n' >/etc/systemd/system/docker.service
t "systemd-analyze verify accepts the units" sh -c 'cd /etc/systemd/system && systemd-analyze verify kodus-cell.target kodus-cell.service kodus-cell-egress.service kodus-cell-injector.service kodus-cell-reaper.service kodus-cell-reaper.timer'
t "cell.yaml names the hub and the trust bundle" sh -c 'grep -q "hubUrl: wss://hub.example.internal:3410/cells" /etc/kodus/cell/cell.yaml && grep -q "ca: /etc/kodus/cell/trust.pem" /etc/kodus/cell/cell.yaml'
t "trust.pem holds the hub CA and the cell-local CA" sh -c '[ "$(grep -c "BEGIN CERTIFICATE" /etc/kodus/cell/trust.pem)" = 2 ]'
t "egress and injector trust the hub's issuer for the agent" sh -c 'cmp /etc/kodus/cell/egress/ca.pem /etc/kodus/cell/identity/issuer.pem && cmp /etc/kodus/cell/injector/ca.pem /etc/kodus/cell/identity/issuer.pem'
t "egress certificate chains to the cell-local CA" openssl verify -CAfile /etc/kodus/cell/local-ca.pem /etc/kodus/cell/egress/cert.pem
t "injector holds the OpenBao AppRole, 0600" sh -c '[ "$(stat -c %a /etc/kodus/cell/injector/openbao-injector-secret-id)" = 600 ]'
t "private keys are 0600" sh -c '! find /etc/kodus/cell -name "*.key*" ! -perm 600 | grep -q .'
t "cell.env names OpenBao for the injector" has "-openbao-addr https://10.20.30.40:8200" /etc/kodus/cell/cell.env
t "cell.env pins the sandbox and builder images by digest" sh -c 'grep -q "gvisor-sandbox-image example.invalid/kodus-runtime-sandbox@sha256:" /etc/kodus/cell/cell.env && grep -q "gvisor-builder-image example.invalid/kodus-runtime-builder@sha256:" /etc/kodus/cell/cell.env'
t "cell.env names the enforcers network the egress reaches the injector on" sh -c 'grep -qx ENFORCERS_SUBNET=10.214.0.0/29 /etc/kodus/cell/cell.env && grep -qx EGRESS_ENFORCER_IP=10.214.0.2 /etc/kodus/cell/cell.env && grep -qx INJECTOR_ENFORCER_IP=10.214.0.3 /etc/kodus/cell/cell.env'
t "the injector listens on that network and trusts the egress's address only" sh -c 'U=/etc/systemd/system/kodus-cell-injector.service; grep -qF -- "-listen \${INJECTOR_ENFORCER_IP}:8443 -trusted-proxies \${EGRESS_ENFORCER_IP}" $U && grep -qF "network connect --ip \${INJECTOR_ENFORCER_IP} kodus-cell-enforcers kodus-cell-injector" $U && grep -q "ExecStart=/usr/bin/docker start -a kodus-cell-injector" $U'
t "the egress sends credentialed hosts to the injector there" sh -c 'U=/etc/systemd/system/kodus-cell-egress.service; grep -qF -- "-injector-addr \${INJECTOR_ENFORCER_IP}:8443" $U && grep -qF "network connect --ip \${EGRESS_ENFORCER_IP} kodus-cell-enforcers kodus-cell-egress" $U'
t "cell.env gives the cell the injector's CA for claims with secrets" has "-cell-ca-cert /etc/kodus/cell/injector/cell-ca.pem" /etc/kodus/cell/cell.env
t "that file is the CA certificate alone" sh -c 'openssl x509 -in /etc/kodus/cell/injector/cell-ca.pem -noout -ext basicConstraints | grep -q "CA:TRUE" && ! grep -q PRIVATE /etc/kodus/cell/injector/cell-ca.pem'
t "the host check finds the public roots the cell bundles" has "public roots for claims with secrets: /etc/ssl/certs/ca-certificates.crt" /tmp/install.log
t "reaper env" sh -c 'grep -qx CELL_ID=cell-dry-run /etc/kodus/cell-reaper.env && grep -qx EGRESS=kodus-cell-egress /etc/kodus/cell-reaper.env'

if [ -d /cellbin ]; then
    echo "== the real cell release binaries with the generated config"
    # A synthetic identity in place of what `cell register` writes, signed by
    # the dry run's throwaway issuer.
    I=/etc/kodus/cell/identity
    openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -out $I/key.pem
    openssl req -new -key $I/key.pem -subj "/O=kodus-runtime/OU=cell/CN=cell-dry-run" -out /tmp/c.csr
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' >/tmp/c.ext
    openssl x509 -req -in /tmp/c.csr -CA $I/issuer.pem -CAkey $I/.dry-ca.key -CAcreateserial -days 1 -extfile /tmp/c.ext -out $I/cert.pem 2>/dev/null
    # shellcheck source=/dev/null
    set -a && . /etc/kodus/cell/cell.env && set +a
    # The docker -v mounts of the units, as paths on this container.
    ln -sfn /etc/kodus/cell/egress /etc/kodus/egress
    ln -sfn /etc/kodus/cell/injector /etc/kodus/injector
    mkdir -p /var/cache/kodus-mirror
    # shellcheck disable=SC2086 # split like systemd splits $CELL_ARGS
    timeout 30 /opt/kodus-cell/current/bin/cell -config /etc/kodus/cell/cell.yaml $CELL_ARGS >/tmp/cell.log 2>&1 || true
    sed 's/^/      | /' /tmp/cell.log | tail -8
    t "cell: every flag and config key is known" sh -c '! grep -qiE "flag provided but not defined|unknown field|field .* not found" /tmp/cell.log'
    t "cell: refuses to start without runsc, and says so" grep -qi runsc /tmp/cell.log
    t "cell: bundles the host's public roots with the injector's CA" bash -c 'grep -q machine_trust.ready /tmp/cell.log && [ "$(grep -c "BEGIN CERTIFICATE" /var/lib/kodus-cell/work/trust/ca-bundle.pem)" -gt 1 ] && cmp -s <(openssl x509 -in /var/lib/kodus-cell/work/trust/cell-ca.pem) <(openssl x509 -in /etc/kodus/cell/injector/cell-ca.pem)'
    # shellcheck disable=SC2086
    /opt/kodus-cell/current/bin/egress -listen-tls :443 -listen-http :80 -dns-listen :53 -control :9443 \
        -mirror-listen :8080 -upstream-dns "$UPSTREAM_DNS" -transparent=false -injector-addr 127.0.0.1:8443 \
        -mirror-cache-dir /var/cache/kodus-mirror -mirror-cache-max-gb "$MIRROR_CACHE_GB" -agent-cn "$CELL_ID" $EGRESS_ARGS >/tmp/egress.log 2>&1 &
    EG=$!
    # shellcheck disable=SC2086
    /opt/kodus-cell/current/bin/injector -listen 127.0.0.1:8443 -trusted-proxies 127.0.0.1 -control :9445 -agent-cn "$CELL_ID" $INJECTOR_ARGS >/tmp/injector.log 2>&1 &
    IN=$!
    sleep 3
    t "egress: starts with the unit's arguments" kill -0 $EG
    t "injector: starts with the unit's arguments" kill -0 $IN
    t "egress control port: TLS verifies with the cell's trust bundle" sh -c 'echo | openssl s_client -connect 127.0.0.1:9443 -servername kodus-egress -CAfile /etc/kodus/cell/trust.pem -verify_return_error 2>&1 | grep -q "Verify return code: 0"'
    t "injector control port: TLS verifies with the cell's trust bundle" sh -c 'echo | openssl s_client -connect 127.0.0.1:9445 -servername kodus-injector -CAfile /etc/kodus/cell/trust.pem -verify_return_error 2>&1 | grep -q "Verify return code: 0"'
    t "egress control port refuses a client without the agent's certificate" sh -c '! curl -fsS --max-time 5 --cacert /etc/kodus/cell/trust.pem https://127.0.0.1:9443/metrics >/dev/null 2>&1'
    t "egress control port takes the agent's certificate" curl -fsS --max-time 5 --cacert /etc/kodus/cell/trust.pem --cert $I/cert.pem --key $I/key.pem https://127.0.0.1:9443/metrics
    kill $EG $IN 2>/dev/null || true
    t "injector: the OpenBao secret store is configured from the unit's flags" sh -c '! grep -q injector.secrets.unconfigured /tmp/injector.log' 
    sed 's/^/      | /' /tmp/egress.log | head -4
    sed 's/^/      | /' /tmp/injector.log | head -4
    timeout 20 /opt/kodus-cell/current/bin/reaper -once -driver docker-gvisor -cell-id "$CELL_ID" -workdir /var/lib/kodus-cell/work -gvisor-egress-container kodus-cell-egress >/tmp/reaper.log 2>&1 || true
    t "reaper: takes the unit's flags" sh -c '! grep -q "flag provided but not defined" /tmp/reaper.log'
fi

echo "== upgrade"
R='{"runc":{},"runsc":{"path":"/usr/local/bin/runsc"}}'
t "install --egress-allow sets the allow-list" sh -c "STUB_RUNTIMES='$R' $CH install --profile docker-gvisor --bundle $BUNDLE ${BIN_ARGS[*]} --min-free-gb 1 --egress-allow registry.example.com --dry-run >/dev/null && grep -qx KODUS_CELL_EGRESS_ALLOW=registry.example.com /etc/kodus/cell/cell.env"
t "upgrade --dry-run succeeds" sh -c "STUB_RUNTIMES='$R' $CH upgrade ${BIN_ARGS[*]} --min-free-gb 1 --dry-run >/tmp/upgrade.log 2>&1 || { tail -20 /tmp/upgrade.log; exit 1; }"
t "upgrade keeps the allow-list" sh -c "grep -qx KODUS_CELL_EGRESS_ALLOW=registry.example.com /etc/kodus/cell/cell.env && grep -q 'egress-allow registry.example.com' /etc/kodus/cell/cell.env && grep -q '\[dry-run\] systemctl restart kodus-cell.target' /tmp/upgrade.log"
t "each release keeps the settings it ran with" sh -c 'test -s "$(readlink /opt/kodus-cell/current)/cell.env"'

echo "== backup and uninstall"
t "backup writes the identity and config" sh -c "$CH backup --out /tmp/cell-backup.tgz && tar -tzf /tmp/cell-backup.tgz | grep -q etc/kodus/cell/identity/issuer.pem"
t "uninstall --purge --dry-run lists what it removes" sh -c "$CH uninstall --purge --dry-run | grep -q '\[dry-run\] rm -rf /etc/kodus/cell /opt/kodus-cell /var/lib/kodus-cell'"
t "uninstall removes the enforcers network (dry run)" sh -c "$CH uninstall --dry-run | grep -q '\[dry-run\] docker network rm kodus-cell-enforcers'"
t "nothing removed by the dry run" test -s /etc/kodus/cell/cell.yaml

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
