#!/usr/bin/env bash
# The Kody Runtime cell host (docs/runtime.md, "Cell host"): checks a host
# against its profile, installs gVisor's runsc by checksum and registers it
# with Docker, installs the cell release's binaries, writes the cell's
# configuration, enrolls the cell with a one-time token, and installs the
# systemd units for the cell, the egress (proxy and resolver), the injector
# and the reaper. Linux, as root.
#
# Usage: cell-host.sh <command> [options]
#   check     --profile <p> [--workdir DIR] [--bundle DIR | --hub-url URL --hub-ca FILE]
#             Names every requirement of the profile this host misses; exit 1 if any.
#   install   --profile <p> --bundle DIR [--token-file FILE] [options below]
#   upgrade   [--release R] [--cell-image REF | --cell-bin-dir DIR]
#             Installs another cell release beside the current one and restarts on it.
#   rollback  Restarts on the release installed before the current one.
#   rotate-local-pki   Re-issues the egress, injector and observer certificates.
#   status    The units, the release, the cell id and the agent's metrics.
#   backup    --out FILE   The cell's identity, local PKI, config and bake catalog.
#   uninstall [--purge] [--remove-runsc]
#
# Profiles: docker-gvisor (the cell runs here, under runsc), docker-firecracker
# (checks only: the backend is phase P2), kubernetes (checks only: no chart
# runs a cell yet).
#
# install options:
#   --bundle DIR        runtime/state/cell-host/ of the control plane (hub CA,
#                       OpenBao CA and the injector's AppRole, addresses)
#   --token-file FILE   the registration token (scripts/runtime/cell-token.sh);
#                       or KODUS_CELL_REGISTRATION_TOKEN. Not needed when the
#                       cell is already registered.
#   --release R         cell release (default: the bundle's, else `unreleased`)
#   --cell-image REF    the cell image (default: images.lock for the release, or
#                       KODUS_RUNTIME_CELL_IMAGE); its binaries are copied out
#   --cell-bin-dir DIR  the cell's static binaries instead of an image (local builds)
#   --workdir DIR       claims' scratch and state (default /var/lib/kodus-cell)
#   --egress-allow LIST hosts every claim may reach (default: image registry,
#                       npm and the Debian, Ubuntu and Alpine mirrors)
#   --upstream-dns ADDR resolver the egress forwards to (default 1.1.1.1:53)
#   --sandbox-pool N    blank sandboxes kept ready (default 0)
#   --gvisor-archive F  gvisor.tar.bz2 already downloaded (offline); still
#                       checked against runtime/gvisor.tsv
#   --reinstall-runsc   replace a runsc that is already registered
#   --min-free-gb N     free disk under --workdir below which the check fails
#                       (default 20, the cell's -gvisor-build-state-min-free-gb)
#   --dry-run           print what would change the host (Docker, systemd,
#                       runsc install, cell register) instead of doing it
#
# Test hooks (never needed on a real host): KODUS_CELL_ROOT (a prefix for
# every path written), KODUS_CELL_DOCKER, KODUS_CELL_SYSTEMCTL,
# KODUS_CELL_KVM_DEVICE, KODUS_CELL_CGROUP_ROOT, KODUS_CELL_SYSTEMD_RUN.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'; }

PREFIX="${KODUS_CELL_ROOT:-}"
DOCKER="${KODUS_CELL_DOCKER:-docker}"
SYSTEMCTL="${KODUS_CELL_SYSTEMCTL:-systemctl}"
KVM_DEVICE="${KODUS_CELL_KVM_DEVICE:-/dev/kvm}"
CGROUP_FS="${KODUS_CELL_CGROUP_ROOT:-/sys/fs/cgroup}"
SYSTEMD_RUN="${KODUS_CELL_SYSTEMD_RUN:-/run/systemd/system}"

# Real paths (what the units and the config name) and where they are written.
ETC_R=/etc/kodus/cell
OPT_R=/opt/kodus-cell
ETC="$PREFIX$ETC_R"
OPT="$PREFIX$OPT_R"
UNITS="$PREFIX/etc/systemd/system"
REAPER_ENV="$PREFIX/etc/kodus/cell-reaper.env"
LOCAL_BIN="$PREFIX/usr/local/bin"
UNIT_NAMES="kodus-cell-injector.service kodus-cell-egress.service kodus-cell.service kodus-cell.target kodus-cell-reaper.service kodus-cell-reaper.timer"
EGRESS_NAME=kodus-cell-egress
INJECTOR_NAME=kodus-cell-injector
# The internal network the egress reaches the injector on, with fixed
# addresses: outside the claims' pool (10.213.0.0/16) and this host's other
# networks (kodus-ai apps/runtime-cell/scripts/dev-gvisor-cell.sh).
ENFORCERS_NAME=kodus-cell-enforcers
DEFAULT_ENFORCERS_SUBNET=10.214.0.0/29 DEFAULT_EGRESS_ENFORCER_IP=10.214.0.2 DEFAULT_INJECTOR_ENFORCER_IP=10.214.0.3
GVISOR_BASE=https://storage.googleapis.com/gvisor/releases/release
DEFAULT_EGRESS_ALLOW=registry-1.docker.io,auth.docker.io,production.cloudfront.docker.com,registry.npmjs.org,deb.debian.org,security.debian.org,archive.ubuntu.com,security.ubuntu.com,ports.ubuntu.com,dl-cdn.alpinelinux.org

COMMAND=${1:-}
[ $# -gt 0 ] && shift
PROFILE='' BUNDLE='' TOKEN_FILE='' RELEASE='' CELL_IMAGE_ARG='' CELL_BIN_DIR='' WORKDIR_R=/var/lib/kodus-cell
EGRESS_ALLOW='' UPSTREAM_DNS='' SANDBOX_POOL='' GVISOR_ARCHIVE='' REINSTALL_RUNSC=0
ENFORCERS_SUBNET='' EGRESS_ENFORCER_IP='' INJECTOR_ENFORCER_IP=''
DRY_RUN=0 HUB_URL='' HUB_CA='' OUT='' PURGE=0 REMOVE_RUNSC=0 THIN_POOL='' RUNTIME_CLASS=gvisor MIN_FREE_GB=20
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE=${2:?}; shift 2 ;;
        --bundle) BUNDLE=${2:?}; shift 2 ;;
        --token-file) TOKEN_FILE=${2:?}; shift 2 ;;
        --release) RELEASE=${2:?}; shift 2 ;;
        --cell-image) CELL_IMAGE_ARG=${2:?}; shift 2 ;;
        --cell-bin-dir) CELL_BIN_DIR=${2:?}; shift 2 ;;
        --workdir) WORKDIR_R=${2:?}; shift 2 ;;
        --egress-allow) EGRESS_ALLOW=${2:?}; shift 2 ;;
        --upstream-dns) UPSTREAM_DNS=${2:?}; shift 2 ;;
        --sandbox-pool) SANDBOX_POOL=${2:?}; shift 2 ;;
        --gvisor-archive) GVISOR_ARCHIVE=${2:?}; shift 2 ;;
        --reinstall-runsc) REINSTALL_RUNSC=1; shift ;;
        --min-free-gb) MIN_FREE_GB=${2:?}; shift 2 ;;
        --hub-url) HUB_URL=${2:?}; shift 2 ;;
        --hub-ca) HUB_CA=${2:?}; shift 2 ;;
        --thin-pool) THIN_POOL=${2:?}; shift 2 ;;
        --runtime-class) RUNTIME_CLASS=${2:?}; shift 2 ;;
        --out) OUT=${2:?}; shift 2 ;;
        --purge) PURGE=1; shift ;;
        --remove-runsc) REMOVE_RUNSC=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) rt_die "unknown option $1 (see --help)" ;;
    esac
done
WORKDIR="$PREFIX$WORKDIR_R"

# settings_defaults [from-installed]: what a flag did not set comes from the
# installed cell (upgrade) or the default.
settings_defaults() {
    if [ "${1:-}" = from-installed ] && [ -s "$ETC/cell.env" ]; then
        [ -n "$EGRESS_ALLOW" ] || EGRESS_ALLOW=$(rt_env_get "$ETC/cell.env" KODUS_CELL_EGRESS_ALLOW)
        [ -n "$UPSTREAM_DNS" ] || UPSTREAM_DNS=$(rt_env_get "$ETC/cell.env" UPSTREAM_DNS)
        [ -n "$SANDBOX_POOL" ] || SANDBOX_POOL=$(rt_env_get "$ETC/cell.env" KODUS_CELL_SANDBOX_POOL)
        [ -n "$RELEASE" ] || RELEASE=$(rt_env_get "$ETC/cell.env" KODUS_CELL_RELEASE)
        [ -n "$ENFORCERS_SUBNET" ] || ENFORCERS_SUBNET=$(rt_env_get "$ETC/cell.env" ENFORCERS_SUBNET)
        [ -n "$EGRESS_ENFORCER_IP" ] || EGRESS_ENFORCER_IP=$(rt_env_get "$ETC/cell.env" EGRESS_ENFORCER_IP)
        [ -n "$INJECTOR_ENFORCER_IP" ] || INJECTOR_ENFORCER_IP=$(rt_env_get "$ETC/cell.env" INJECTOR_ENFORCER_IP)
    fi
    ENFORCERS_SUBNET=${ENFORCERS_SUBNET:-$DEFAULT_ENFORCERS_SUBNET}
    EGRESS_ENFORCER_IP=${EGRESS_ENFORCER_IP:-$DEFAULT_EGRESS_ENFORCER_IP}
    INJECTOR_ENFORCER_IP=${INJECTOR_ENFORCER_IP:-$DEFAULT_INJECTOR_ENFORCER_IP}
    EGRESS_ALLOW=${EGRESS_ALLOW:-$DEFAULT_EGRESS_ALLOW}
    UPSTREAM_DNS=${UPSTREAM_DNS:-1.1.1.1:53}
    SANDBOX_POOL=${SANDBOX_POOL:-0}
}

run() { # run CMD...: changes the host; printed instead under --dry-run
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
bytes_free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }'; }
existing_parent() {
    local d=$1
    while [ ! -e "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); done
    printf '%s' "$d"
}

# --- bundle ----------------------------------------------------------------
load_bundle() {
    [ -n "$BUNDLE" ] || return 0
    [ -f "$BUNDLE/cell-host.conf" ] || rt_die "$BUNDLE/cell-host.conf not found: --bundle is runtime/state/cell-host/ of the control plane"
    local v
    v=$(rt_env_get "$BUNDLE/cell-host.conf" HUB_URL)
    [ -n "$HUB_URL" ] || HUB_URL=$v
    [ -n "$HUB_CA" ] || HUB_CA="$BUNDLE/hub-ca.pem"
    OPENBAO_ADDR=$(rt_env_get "$BUNDLE/cell-host.conf" OPENBAO_ADDR)
    GIT_API=$(rt_env_get "$BUNDLE/cell-host.conf" GIT_API)
    v=$(rt_env_get "$BUNDLE/cell-host.conf" KODUS_RUNTIME_CELL_RELEASE)
    [ -n "$RELEASE" ] || RELEASE=$v
}
OPENBAO_ADDR='' GIT_API=''

hub_https() { # wss://host:port/cells -> https://host:port
    local hp=${HUB_URL#*://}
    printf 'https://%s' "${hp%%/*}"
}

# --- checks -----------------------------------------------------------------
MISSING=() WARNINGS=() OKS=()
miss() { MISSING+=("$1"); }
warn() { WARNINGS+=("$1"); }
ok() { OKS+=("$1"); }

check_common_linux() {
    local kernel arch os
    os=$(uname -s)
    if [ "$os" != Linux ]; then
        miss "Linux is required (this host runs $os)"
        return 1
    fi
    arch=$(uname -m)
    case "$arch" in
        x86_64 | aarch64) ok "architecture $arch" ;;
        *) miss "architecture $arch is not supported: x86_64 or aarch64" ;;
    esac
    kernel=$(uname -r)
    KERNEL_VERSION=${kernel%%-*}
    ok "kernel $kernel"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        ok "distribution $(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$ID}")"
    fi
    if [ -d "$SYSTEMD_RUN" ]; then
        ok "systemd"
    else
        miss "systemd is not running ($SYSTEMD_RUN is absent): the cell, egress, injector and reaper run as systemd units"
    fi
}

check_tools() {
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || miss "command '$t' is not installed"
    done
}

check_docker() {
    local server rootless
    if ! command -v "$DOCKER" >/dev/null 2>&1; then
        miss "Docker Engine is not installed (docker CLI not found)"
        return 1
    fi
    if ! server=$("$DOCKER" version --format '{{.Server.Version}}' 2>/dev/null) || [ -z "$server" ]; then
        miss "the Docker daemon does not answer ('docker version' failed): start it, and run this as root"
        return 1
    fi
    if ver_ge "$server" 24.0; then
        ok "Docker Engine $server"
        ver_ge "$server" 25.0 || warn "Docker Engine $server: below 25.0 (API 1.44) healthchecks get no start_interval, so boots and resets are slower"
    else
        miss "Docker Engine $server is too old: 24.0 or later"
    fi
    rootless=$("$DOCKER" info --format '{{json .SecurityOptions}}' 2>/dev/null || true)
    case "$rootless" in
        *rootless*) miss "Docker runs rootless: the cell needs rootful Docker (it runs containers with --runtime runsc and owns their networks)" ;;
    esac
}

runsc_registered() {
    "$DOCKER" info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"runsc"'
}

check_runsc() {
    if runsc_registered; then
        ok "runsc registered as a Docker runtime"
    else
        miss "runsc is not registered as a Docker runtime named \"runsc\" (Docker's daemon.json \"runtimes\"): 'cell-host.sh install' installs gVisor $(gvisor_release) and registers it; without it the cell refuses to start"
    fi
}

check_cgroup_v2() { # check_cgroup_v2 required|optional
    local fs
    fs=$(stat -f -c %T "$CGROUP_FS" 2>/dev/null || echo unknown)
    if [ "$fs" = cgroup2fs ]; then
        ok "cgroup v2"
    elif [ "$1" = required ]; then
        miss "cgroup v2 is required ($CGROUP_FS is $fs): boot with systemd.unified_cgroup_hierarchy=1"
    else
        warn "cgroup v1 ($CGROUP_FS is $fs): per-claim aggregate limits (-gvisor-claim-limits required) stay off"
    fi
}

workdir_fs() { stat -f -c %T "$(existing_parent "$WORKDIR")" 2>/dev/null || echo unknown; }

check_disk_gvisor() {
    local fs free
    fs=$(workdir_fs)
    case "$fs" in
        xfs | btrfs) ok "$WORKDIR_R on $fs (reflink: a pull request's build reads the environment's build state through a clone)" ;;
        *) warn "$WORKDIR_R is on $fs: build state is read through the kernel's overlay, where most Node builds fail once and run again cold; XFS or btrfs avoids it" ;;
    esac
    free=$(bytes_free_gb "$(existing_parent "$WORKDIR")")
    if [ -n "$free" ] && [ "$free" -lt "$MIN_FREE_GB" ]; then
        miss "$WORKDIR_R has ${free} GB free: at least $MIN_FREE_GB GB (the build state's floor), 100 GB recommended"
    elif [ -n "$free" ] && [ "$free" -lt 100 ]; then
        warn "$WORKDIR_R has ${free} GB free: 100 GB recommended (images, build state, the registry mirror)"
    fi
}

check_memory() {
    local mb
    mb=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$mb" -lt 6144 ]; then
        miss "${mb} MB of memory: at least 6 GB (one claim of the default size, 4 GB, plus 1 GB for the host)"
    elif [ "$mb" -lt 16384 ]; then
        warn "${mb} MB of memory: 16 GB recommended for more than one claim at a time"
    else
        ok "${mb} MB of memory"
    fi
}

check_hub() {
    [ -n "$HUB_URL" ] || return 0
    if [ -z "$HUB_CA" ] || [ ! -s "$HUB_CA" ]; then
        miss "the hub CA ($HUB_CA) is missing: copy runtime/state/cell-host/ from the control plane"
        return 0
    fi
    if curl -fsS --max-time 10 --cacert "$HUB_CA" "$(hub_https)/health" >/dev/null 2>&1; then
        ok "hub $(hub_https) answers /health with the hub CA"
    elif [ "$DRY_RUN" = 1 ]; then
        warn "the hub at $(hub_https) does not answer /health (dry run: nothing contacts it)"
    else
        miss "the hub at $(hub_https) does not answer /health with the CA in $HUB_CA (port 3410 reachable? RUNTIME_HUB_HOST in the hub's certificate?)"
    fi
}

check_kvm() {
    if [ -c "$KVM_DEVICE" ]; then
        if [ -r "$KVM_DEVICE" ] && [ -w "$KVM_DEVICE" ]; then
            ok "$KVM_DEVICE"
        else
            miss "$KVM_DEVICE exists but is not readable and writable by $(id -un)"
        fi
    else
        miss "$KVM_DEVICE is missing: the firecracker backend needs KVM (bare metal, or an instance type with nested virtualization)"
    fi
}

check_cow_disks() {
    local fs dir
    if [ -n "$THIN_POOL" ]; then
        if command -v lvs >/dev/null 2>&1 && lvs --noheadings -o lv_attr "$THIN_POOL" 2>/dev/null | grep -q '^ *t'; then
            ok "LVM thin pool $THIN_POOL"
        else
            miss "LVM thin pool $THIN_POOL not found (lvs)"
        fi
        return 0
    fi
    fs=$(workdir_fs)
    dir=$(existing_parent "$WORKDIR")
    if [ "$fs" = xfs ] && command -v xfs_info >/dev/null 2>&1 && xfs_info "$dir" 2>/dev/null | grep -q 'reflink=1'; then
        ok "$WORKDIR_R on XFS with reflink"
    else
        miss "copy-on-write disks need XFS with reflink=1 under $WORKDIR_R (it is on $fs) or an LVM thin pool (--thin-pool vg/pool)"
    fi
}

check_firecracker_release() {
    local rel backends kit
    rel=${RELEASE:-unreleased}
    backends=$(rt_cell_backends "$rel")
    if rt_protocol_fits firecracker "$backends"; then
        ok "cell release $rel has the firecracker backend"
    else
        miss "cell release $rel has no firecracker backend (phase P2): the cell refuses -isolation-backend firecracker"
    fi
    kit=$(rt_lock_field "$rel" microvm-kit 4)
    [ "$kit" = published ] || miss "the microVM kit (firecracker + jailer, guest kernel, base rootfs images) is not published for cell release $rel"
}

check_kubernetes() {
    if ! command -v kubectl >/dev/null 2>&1; then
        miss "kubectl is not installed"
    elif ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
        miss "kubectl cannot reach a cluster (current context: $(kubectl config current-context 2>/dev/null || echo none))"
    elif kubectl get runtimeclass "$RUNTIME_CLASS" >/dev/null 2>&1; then
        ok "RuntimeClass $RUNTIME_CLASS ($(kubectl get runtimeclass "$RUNTIME_CLASS" -o jsonpath='{.handler}' 2>/dev/null))"
    else
        miss "RuntimeClass $RUNTIME_CLASS does not exist: a node pool with gVisor (handler runsc) or Kata, and runtime/kubernetes/runtimeclass-*.yaml"
    fi
    miss "no cell runs on Kubernetes yet: kodus-ai deploy/chart/runtime-cell renders only the reaper, the RuntimeClass and RBAC, and cmd/cell cannot select the k8s-sandbox driver (cell-distribution.md item 5)"
}

run_checks() { # run_checks PROFILE [skip-runsc]
    MISSING=() WARNINGS=() OKS=()
    KERNEL_VERSION=0
    case "$1" in
        docker-gvisor)
            if check_common_linux; then
                ver_ge "$KERNEL_VERSION" 4.14.77 || miss "kernel $KERNEL_VERSION is older than gVisor's minimum, 4.14.77"
                ver_ge "$KERNEL_VERSION" 5.10 || warn "kernel $KERNEL_VERSION: 5.10 or later recommended"
                check_tools curl openssl tar bzip2 sha512sum
                check_docker && [ "${2:-}" != skip-runsc ] && check_runsc
                check_cgroup_v2 optional
                check_disk_gvisor
                check_memory
                check_hub
            fi
            ;;
        docker-firecracker)
            if check_common_linux; then
                ver_ge "$KERNEL_VERSION" 5.10 || miss "kernel $KERNEL_VERSION: firecracker hosts need 5.10 or later"
                check_tools curl openssl
                check_docker
                check_kvm
                check_cgroup_v2 required
                check_cow_disks
                check_memory
                check_hub
                check_firecracker_release
            fi
            ;;
        kubernetes) check_kubernetes ;;
        '') rt_die "--profile is required: docker-gvisor, docker-firecracker or kubernetes" ;;
        *) rt_die "unknown profile '$1': docker-gvisor, docker-firecracker or kubernetes" ;;
    esac
}

report() { # report PROFILE: prints the result; true when nothing is missing
    local m
    printf 'cell host check, profile %s:\n' "$1"
    for m in ${OKS[@]+"${OKS[@]}"}; do printf '  ok       %s\n' "$m"; done
    for m in ${WARNINGS[@]+"${WARNINGS[@]}"}; do printf '  warning  %s\n' "$m"; done
    for m in ${MISSING[@]+"${MISSING[@]}"}; do printf '  missing  %s\n' "$m"; done
    if [ "${#MISSING[@]}" -gt 0 ]; then
        printf '%s%d requirement(s) missing: the cell does not start on this host.%s\n' "$RT_RED" "${#MISSING[@]}" "$RT_NC"
        return 1
    fi
    printf '%sAll requirements of %s met.%s\n' "$RT_GREEN" "$1" "$RT_NC"
}

# --- gVisor -----------------------------------------------------------------
gvisor_release() { rt_rows "$RT_GVISOR" | awk -F '\t' 'NR == 1 { print $1 }'; }
gvisor_sha() { rt_rows "$RT_GVISOR" | awk -F '\t' -v r="$1" -v a="$2" '$1 == r && $2 == a { print $3; exit }'; }

install_gvisor() {
    local arch rel sha tmp published have
    if runsc_registered && [ "$REINSTALL_RUNSC" = 0 ]; then
        have=$(runsc --version 2>/dev/null | head -n1 || true)
        case "$have" in
            *"$(gvisor_release)"*) rt_info "runsc already registered ($have)." ;;
            *) rt_warn "runsc already registered (${have:-unknown version}), not the pinned $(gvisor_release); kept (--reinstall-runsc replaces it)" ;;
        esac
        return 0
    fi
    arch=$(uname -m)
    rel=$(gvisor_release)
    sha=$(gvisor_sha "$rel" "$arch")
    [ -n "$sha" ] || rt_die "runtime/gvisor.tsv pins no gVisor $rel for $arch"
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    if [ -n "$GVISOR_ARCHIVE" ]; then
        cp "$GVISOR_ARCHIVE" "$tmp/gvisor.tar.bz2"
    else
        rt_info "Downloading gVisor $rel ($arch)..."
        curl -fsSL --retry 3 -o "$tmp/gvisor.tar.bz2" "$GVISOR_BASE/$rel/$arch/gvisor.tar.bz2"
        published=$(curl -fsSL --retry 3 "$GVISOR_BASE/$rel/$arch/gvisor.tar.bz2.sha512" | awk '{ print $1 }')
        [ "$published" = "$sha" ] || rt_die "gVisor $rel $arch: the published SHA-512 differs from the one pinned in runtime/gvisor.tsv"
    fi
    printf '%s  %s\n' "$sha" "$tmp/gvisor.tar.bz2" | sha512sum -c --quiet - ||
        rt_die "gVisor $rel $arch: the archive does not match the SHA-512 pinned in runtime/gvisor.tsv"
    mkdir -p "$tmp/x" "$LOCAL_BIN"
    tar -xjf "$tmp/gvisor.tar.bz2" -C "$tmp/x" runsc containerd-shim-runsc-v1
    install -m 0755 "$tmp/x/runsc" "$LOCAL_BIN/runsc"
    install -m 0755 "$tmp/x/containerd-shim-runsc-v1" "$LOCAL_BIN/containerd-shim-runsc-v1"
    rt_ok "gVisor $rel installed in /usr/local/bin (SHA-512 verified)."
    # Adds "runsc" to /etc/docker/daemon.json's runtimes, then Docker reloads
    # its runtimes on SIGHUP without restarting containers.
    run "$LOCAL_BIN/runsc" install --runtime runsc
    run "$SYSTEMCTL" reload docker
}

# --- images and binaries ------------------------------------------------------
# cell_ref COMPONENT [optional]: like rt_image, but an unpublished pin that
# this Docker already holds (built locally under the pinned name) is accepted.
cell_ref() {
    local var ref
    var=$(rt_override_var "$1")
    if [ -z "${!var:-}" ]; then
        ref=$(rt_lock_field "$RELEASE" "$1" 3)
        if [ "$(rt_lock_field "$RELEASE" "$1" 4)" != published ] && [ -n "$ref" ] && [ "$ref" != - ] &&
            "$DOCKER" image inspect "$ref" >/dev/null 2>&1; then
            printf '%s\n' "$ref"
            return 0
        fi
    fi
    rt_image "$RELEASE" "$1" "${2:-}"
}

ensure_image() { # ensure_image REF: present locally, pulled when not
    "$DOCKER" image inspect "$1" >/dev/null 2>&1 && return 0
    run "$DOCKER" pull -q "$1" >/dev/null
}

release_id() { # a short, stable id of what is installed
    local ref=$1 id
    case "$ref" in
        bin:*) id=$(sha256sum "${ref#bin:}/cell" | cut -c1-12) ;;
        *@sha256:*) id=${ref##*@sha256:}; id=${id:0:12} ;;
        *) id=$("$DOCKER" image inspect --format '{{.Id}}' "$ref" 2>/dev/null || echo "sha256:unknown000000"); id=${id#sha256:}; id=${id:0:12} ;;
    esac
    printf '%s' "$id"
}

install_binaries() { # install_binaries SOURCE -> sets REL_DIR (real path)
    local src=$1 id dest b cid
    id=$(release_id "$src")
    REL_DIR="$OPT_R/releases/${RELEASE:-local}-$id"
    dest="$PREFIX$REL_DIR/bin"
    mkdir -p "$dest"
    case "$src" in
        bin:*) cp "${src#bin:}"/* "$dest/" ;;
        *)
            ensure_image "$src"
            if [ "$DRY_RUN" = 1 ]; then
                printf '[dry-run] docker create %s; docker cp <id>:/usr/local/bin/. %s/\n' "$src" "$dest"
            else
                cid=$("$DOCKER" create "$src")
                "$DOCKER" cp "$cid:/usr/local/bin/." "$dest/"
                "$DOCKER" rm "$cid" >/dev/null
            fi
            ;;
    esac
    if [ "$DRY_RUN" = 0 ] || [ "${src#bin:}" != "$src" ]; then
        for b in cell egress injector observer reaper; do
            [ -x "$dest/$b" ] || rt_die "the cell release has no executable $b (looked in $dest)"
        done
        chmod 0755 "$dest"/*
    fi
    printf '%s\n' "$src" >"$PREFIX$REL_DIR/source"
}

activate_release() { # current -> REL_DIR, previous -> what current was
    local cur
    cur=$(readlink "$OPT/current" 2>/dev/null || true)
    if [ -n "$cur" ] && [ "$cur" != "$REL_DIR" ]; then
        ln -sfn "$cur" "$OPT/previous"
    fi
    ln -sfn "$REL_DIR" "$OPT/current"
}

build_observer_image() { # the observer image: cmd/observer at /observer, nothing else
    OBSERVER_IMAGE="kodus-cell-observer:${REL_DIR##*-}"
    local ctx
    ctx=$(mktemp -d)
    if [ -x "$PREFIX$REL_DIR/bin/observer" ]; then cp "$PREFIX$REL_DIR/bin/observer" "$ctx/observer"; fi
    printf 'FROM scratch\nCOPY observer /observer\n' >"$ctx/Dockerfile"
    run "$DOCKER" build -q -t "$OBSERVER_IMAGE" "$ctx" >/dev/null
    rm -rf "$ctx"
}

# --- PKI on the cell host ---------------------------------------------------
pki_key() { openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -out "$1"; }
pki_ca() { # pki_ca KEY CERT CN DAYS
    pki_key "$1"
    openssl req -x509 -new -key "$1" -sha256 -days "$4" -subj "/O=kodus-runtime/CN=$3" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$2" 2>/dev/null
}
pki_leaf() { # pki_leaf KEY CERT SUBJECT EKU SAN
    pki_key "$1"
    openssl req -new -key "$1" -subj "$3" -out "$2.csr"
    {
        echo "basicConstraints=critical,CA:FALSE"
        echo "keyUsage=critical,digitalSignature"
        echo "extendedKeyUsage=$4"
        [ -n "$5" ] && echo "subjectAltName=$5"
    } >"$2.ext"
    openssl x509 -req -in "$2.csr" -CA "$ETC/local-ca.pem" -CAkey "$ETC/local-ca.key" -CAcreateserial \
        -sha256 -days 397 -extfile "$2.ext" -out "$2" 2>/dev/null
    rm -f "$2.csr" "$2.ext" "$ETC/local-ca.srl"
}

# The hub's CA pins the hub and signs this cell's certificate (identity/,
# written by `cell register`). The egress, injector and observers get their
# certificates from a CA of this host's own, which never signs a cell
# identity. The agent verifies the hub and its egress/injector control ports
# with one pool (-ca), so trust.pem holds both CAs.
write_local_pki() { # write_local_pki [rotate]
    umask 077
    mkdir -p "$ETC/egress" "$ETC/injector" "$ETC/observer-server"
    [ -s "$ETC/local-ca.pem" ] || pki_ca "$ETC/local-ca.key" "$ETC/local-ca.pem" "Kody Runtime cell-local CA" 3650
    if [ "${1:-}" = rotate ] || [ ! -s "$ETC/egress/cert.pem" ]; then
        pki_leaf "$ETC/egress/key.pem" "$ETC/egress/cert.pem" "/O=kodus-runtime/OU=kodus-egress/CN=kodus-egress" serverAuth "DNS:kodus-egress,IP:127.0.0.1"
        pki_leaf "$ETC/injector/key.pem" "$ETC/injector/cert.pem" "/O=kodus-runtime/OU=kodus-injector/CN=kodus-injector" serverAuth "DNS:kodus-injector,IP:127.0.0.1"
        pki_leaf "$ETC/observer-server/key.pem" "$ETC/observer-server/cert.pem" "/O=kodus-runtime/OU=kodus-observer/CN=kodus-observer" serverAuth "DNS:kodus-observer"
        pki_leaf "$ETC/observer-client-key.pem" "$ETC/observer-client-cert.pem" "/O=kodus-runtime/OU=cell/CN=$CELL_ID" clientAuth ""
    fi
    # The ed25519 key the agent signs every egress policy with; the enforcers hold its public half.
    if [ ! -s "$ETC/policy.key.pem" ]; then
        openssl genpkey -algorithm ed25519 -out "$ETC/policy.key.pem"
        openssl pkey -in "$ETC/policy.key.pem" -pubout -out "$ETC/policy.pub.pem"
    fi
    # The injector's own CA for the leaves it shows claims (never the hub's).
    [ -s "$ETC/injector/cell-ca.pem" ] || pki_ca "$ETC/injector/cell-ca.key.pem" "$ETC/injector/cell-ca.pem" "Kody Runtime injector CA" 1825
    cp "$ETC/policy.pub.pem" "$ETC/egress/agent.pub.pem"
    cp "$ETC/policy.pub.pem" "$ETC/injector/agent.pub.pem"
    # The enforcers accept the agent's client certificate: the hub's issuer.
    cp "$ETC/identity/issuer.pem" "$ETC/egress/ca.pem"
    cp "$ETC/identity/issuer.pem" "$ETC/injector/ca.pem"
    cp "$ETC/local-ca.pem" "$ETC/observer-server/ca.pem"
    cat "$ETC/identity/ca.pem" "$ETC/local-ca.pem" >"$ETC/trust.pem"
    if [ -n "$BUNDLE" ] && [ -n "$OPENBAO_ADDR" ]; then
        cp "$BUNDLE/openbao-ca.pem" "$ETC/injector/openbao-ca.pem"
        cp "$BUNDLE/injector-role-id" "$ETC/injector/openbao-injector-role-id"
        cp "$BUNDLE/injector-secret-id" "$ETC/injector/openbao-injector-secret-id"
    fi
    find "$ETC" -type f -name '*.key*' -exec chmod 600 {} +
    find "$ETC/injector" -type f -name 'openbao-*' -exec chmod 600 {} +
}

cell_id_of() { openssl x509 -in "$1" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p'; }

# --- configuration ----------------------------------------------------------
write_config() {
    local docker_path injector_args='' sandbox_args='' browser_args=''
    umask 077
    mkdir -p "$ETC" "$WORKDIR/work" "$WORKDIR/state" "$WORKDIR/mirror-cache"
    cat >"$ETC/cell.yaml" <<EOF
# Written by kodus-installer scripts/runtime/cell-host.sh. Paths only, no secret.
hubUrl: $HUB_URL
driver: docker-gvisor
regions: [self-hosted]
workDir: $WORKDIR_R/work
stateDir: $WORKDIR_R/state
gitApi: ${GIT_API:-https://api.github.com}
metricsAddr: 127.0.0.1:9466
autoRenew: true
tls:
  ca: $ETC_R/trust.pem
  cert: $ETC_R/identity/cert.pem
  key: $ETC_R/identity/key.pem
  issuer: $ETC_R/identity/issuer.pem
observer:
  mode: http
  ca: $ETC_R/local-ca.pem
  cert: $ETC_R/observer-client-cert.pem
  key: $ETC_R/observer-client-key.pem
EOF
    if [ -n "$OPENBAO_ADDR" ]; then
        injector_args="-openbao-addr $OPENBAO_ADDR -openbao-ca /etc/kodus/injector/openbao-ca.pem -openbao-role-id-file /etc/kodus/injector/openbao-injector-role-id -openbao-secret-id-file /etc/kodus/injector/openbao-injector-secret-id"
    fi
    [ -n "$SANDBOX_IMAGE" ] && sandbox_args="-gvisor-sandbox-image $SANDBOX_IMAGE -sandbox-pool $SANDBOX_POOL"
    [ -n "$BROWSER_IMAGE" ] && browser_args="-gvisor-browser-image $BROWSER_IMAGE"
    cat >"$ETC/cell.env" <<EOF
# Written by kodus-installer scripts/runtime/cell-host.sh; read by the kodus-cell units.
CELL_ID=$CELL_ID
KODUS_CELL_RELEASE=$RELEASE
KODUS_CELL_EGRESS_ALLOW=$EGRESS_ALLOW
KODUS_CELL_SANDBOX_POOL=$SANDBOX_POOL
HOLDER_IMAGE=$HOLDER_IMAGE
UPSTREAM_DNS=$UPSTREAM_DNS
MIRROR_CACHE_GB=20
ENFORCERS_SUBNET=$ENFORCERS_SUBNET
EGRESS_ENFORCER_IP=$EGRESS_ENFORCER_IP
INJECTOR_ENFORCER_IP=$INJECTOR_ENFORCER_IP
EGRESS_ARGS=
INJECTOR_DOCKER_ARGS=
INJECTOR_ARGS="$injector_args"
CELL_ARGS="-isolation-backend gvisor -egress-control egress=https://127.0.0.1:9443,resolver=https://127.0.0.1:9443,injector=https://127.0.0.1:9445 -policy-key $ETC_R/policy.key.pem -egress-allow $EGRESS_ALLOW -gvisor-egress-container $EGRESS_NAME -gvisor-holder-image $HOLDER_IMAGE -gvisor-builder-image $BUILDER_IMAGE -gvisor-helper-image $HELPER_IMAGE -gvisor-registry-image $REGISTRY_IMAGE -gvisor-observer-image $OBSERVER_IMAGE -gvisor-observer-tls-dir $ETC_R/observer-server -observer-server-name kodus-observer -gvisor-mirror-goproxy http://mirror.cell.internal:8080/go,off -gvisor-mirror-registry mirror.cell.internal:8080 $sandbox_args $browser_args"
EOF
    cat >"$REAPER_ENV" <<EOF
# Written by kodus-installer scripts/runtime/cell-host.sh; read by kodus-cell-reaper.service.
CELL_ID=$CELL_ID
WORKDIR=$WORKDIR_R/work
EGRESS=$EGRESS_NAME
EOF
    chmod 600 "$ETC/cell.env" "$REAPER_ENV"
    # Each release keeps the settings it ran with, for rollback.
    cp "$ETC/cell.env" "$PREFIX$REL_DIR/cell.env"
    chmod 700 "$WORKDIR/mirror-cache"
    docker_path=$(command -v "$DOCKER" || echo /usr/bin/docker)
    case "$docker_path" in /*) ;; *) docker_path=/usr/bin/docker ;; esac
    mkdir -p "$UNITS"
    local u
    for u in $UNIT_NAMES; do
        sed "s|@DOCKER@|$docker_path|g" "$RT_DATA/cell/systemd/$u" >"$UNITS/$u"
        chmod 644 "$UNITS/$u"
    done
}

# --- enrollment -------------------------------------------------------------
register_cell() {
    if [ -s "$ETC/identity/cert.pem" ]; then
        CELL_ID=$(cell_id_of "$ETC/identity/cert.pem")
        rt_info "Already registered as $CELL_ID (uninstall --purge to register again)."
        return 0
    fi
    local token=${KODUS_CELL_REGISTRATION_TOKEN:-}
    [ -z "$token" ] && [ -n "$TOKEN_FILE" ] && token=$(head -n1 "$TOKEN_FILE")
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] KODUS_CELL_REGISTRATION_TOKEN=<token> %s/current/bin/cell register -hub %s -ca %s -topology self_hosted -out %s/identity\n' \
            "$OPT_R" "$(hub_https)" "$ETC_R/hub-ca.pem" "$ETC_R"
        # What register writes, so the rest of the dry run has its inputs: a
        # throwaway identity from a throwaway CA, never sent anywhere.
        umask 077
        mkdir -p "$ETC/identity"
        pki_ca "$ETC/identity/.dry-ca.key" "$ETC/identity/issuer.pem" "dry-run hub CA" 1
        cp "$ETC/hub-ca.pem" "$ETC/identity/ca.pem"
        CELL_ID="cell-dry-run"
        return 0
    fi
    case "$token" in
        kcr_*) ;;
        *) rt_die "a registration token is required (--token-file, or KODUS_CELL_REGISTRATION_TOKEN): scripts/runtime/cell-token.sh on the control plane makes one" ;;
    esac
    umask 077
    mkdir -p "$ETC/identity"
    # The token goes in the environment, never on the command line. The
    # topology must be the token's: tokens are self_hosted or hybrid, while
    # `cell register` defaults to single-vm.
    KODUS_CELL_REGISTRATION_TOKEN=$token "$PREFIX$(readlink "$OPT/current")/bin/cell" register -hub "$(hub_https)" -ca "$ETC/hub-ca.pem" \
        -topology self_hosted -out "$ETC/identity"
    CELL_ID=$(cell_id_of "$ETC/identity/cert.pem")
    [ -n "$CELL_ID" ] || rt_die "cell register wrote no certificate"
}

start_units() {
    run "$SYSTEMCTL" daemon-reload
    run "$SYSTEMCTL" enable kodus-cell.target kodus-cell-injector.service kodus-cell-egress.service kodus-cell.service kodus-cell-reaper.timer
    run "$SYSTEMCTL" restart kodus-cell.target
    run "$SYSTEMCTL" start kodus-cell-reaper.timer
}

resolve_images() {
    [ -n "$RELEASE" ] || RELEASE=unreleased
    HOLDER_IMAGE=$(cell_ref holder)
    HELPER_IMAGE=$(cell_ref helper)
    REGISTRY_IMAGE=$(cell_ref registry)
    BUILDER_IMAGE=$(cell_ref builder)
    SANDBOX_IMAGE=$(cell_ref sandbox optional)
    BROWSER_IMAGE=$(cell_ref browser optional)
    if [ -n "$CELL_BIN_DIR" ]; then
        CELL_SOURCE="bin:$(cd "$CELL_BIN_DIR" && pwd)"
    elif [ -n "$CELL_IMAGE_ARG" ]; then
        CELL_SOURCE=$CELL_IMAGE_ARG
    else
        CELL_SOURCE=$(cell_ref cell)
    fi
    [ -n "$SANDBOX_IMAGE" ] || rt_warn "no sandbox image for release $RELEASE: this cell runs no code sandboxes (set KODUS_RUNTIME_SANDBOX_IMAGE)"
    rt_info "Cell release $RELEASE:"
    rt_info "  cell     $CELL_SOURCE"
    rt_info "  builder  $BUILDER_IMAGE"
    rt_info "  holder   $HOLDER_IMAGE"
    rt_info "  sandbox  ${SANDBOX_IMAGE:-none}"
    rt_info "  browser  ${BROWSER_IMAGE:-none}"
    local i
    for i in "$HOLDER_IMAGE" "$HELPER_IMAGE" "$REGISTRY_IMAGE" "$BUILDER_IMAGE" $SANDBOX_IMAGE $BROWSER_IMAGE; do
        ensure_image "$i"
    done
}

require_root() {
    [ "$(id -u)" = 0 ] || [ "$DRY_RUN" = 1 ] || rt_die "run as root: the cell host install changes Docker's runtimes, /etc and systemd"
}

# --- commands ---------------------------------------------------------------
cmd_check() {
    settings_defaults
    load_bundle
    run_checks "$PROFILE"
    report "$PROFILE"
}

cmd_install() {
    require_root
    settings_defaults
    load_bundle
    [ -n "$BUNDLE" ] || rt_die "--bundle is required (runtime/state/cell-host/ of the control plane)"
    case "$PROFILE" in
        docker-gvisor) ;;
        docker-firecracker | kubernetes)
            run_checks "$PROFILE"
            report "$PROFILE" || exit 1
            rt_die "profile $PROFILE has no installer yet"
            ;;
        *) rt_die "--profile is required: docker-gvisor, docker-firecracker or kubernetes" ;;
    esac
    [ -n "$HUB_URL" ] || rt_die "the bundle names no HUB_URL"
    run_checks docker-gvisor skip-runsc
    report "docker-gvisor (before runsc)" || exit 1
    install_gvisor
    if [ "$DRY_RUN" = 0 ]; then
        run_checks docker-gvisor
        report docker-gvisor || exit 1
    fi
    resolve_images
    umask 077
    mkdir -p "$ETC" "$OPT/releases"
    cp "$HUB_CA" "$ETC/hub-ca.pem"
    install_binaries "$CELL_SOURCE"
    activate_release
    build_observer_image
    register_cell
    write_local_pki
    write_config
    start_units
    rt_ok "Cell $CELL_ID installed (release $RELEASE, $(readlink "$OPT/current"))."
    rt_info "Verify: journalctl -u kodus-cell -f (cell.hello, alerts.source_available); the Runtime screens list the cell."
}

cmd_upgrade() {
    require_root
    [ -s "$ETC/cell.env" ] || rt_die "no cell installed here ($ETC_R/cell.env)"
    CELL_ID=$(rt_env_get "$ETC/cell.env" CELL_ID)
    settings_defaults from-installed
    load_bundle
    HUB_URL=$(sed -n 's/^hubUrl: //p' "$ETC/cell.yaml")
    [ -n "$HUB_CA" ] || HUB_CA="$ETC/hub-ca.pem"
    GIT_API=$(sed -n 's/^gitApi: //p' "$ETC/cell.yaml")
    local inj
    inj=$(rt_env_get "$ETC/cell.env" INJECTOR_ARGS)
    OPENBAO_ADDR=$(printf '%s' "$inj" | sed -n 's/.*-openbao-addr \([^ ]*\).*/\1/p')
    run_checks docker-gvisor
    report docker-gvisor || exit 1
    resolve_images
    install_binaries "$CELL_SOURCE"
    activate_release
    build_observer_image
    write_config
    # The deploy order of the Runtime: injector, egress, then the agent (the
    # agent refuses work until both alert feeds answer).
    run "$SYSTEMCTL" daemon-reload
    run "$SYSTEMCTL" restart kodus-cell.target
    rt_ok "Cell $CELL_ID now runs $(readlink "$OPT/current"); 'cell-host.sh rollback' returns to $(readlink "$OPT/previous" 2>/dev/null || echo none)."
}

cmd_rollback() {
    require_root
    local prev cur
    prev=$(readlink "$OPT/previous" 2>/dev/null) || rt_die "no previous release to roll back to"
    cur=$(readlink "$OPT/current")
    ln -sfn "$prev" "$OPT/current"
    ln -sfn "$cur" "$OPT/previous"
    # The images it ran with (observer, builder, sandbox) come back with it.
    [ -s "$PREFIX$prev/cell.env" ] && cp "$PREFIX$prev/cell.env" "$ETC/cell.env"
    run "$SYSTEMCTL" restart kodus-cell.target
    rt_ok "Cell restarted on $prev."
}

cmd_rotate() {
    require_root
    CELL_ID=$(rt_env_get "$ETC/cell.env" CELL_ID)
    [ -n "$CELL_ID" ] || rt_die "no cell installed here"
    write_local_pki rotate
    run "$SYSTEMCTL" restart kodus-cell.target
    rt_ok "Local certificates re-issued; the cell restarted."
}

cmd_status() {
    local u
    printf 'release:  %s\n' "$(readlink "$OPT/current" 2>/dev/null || echo 'not installed')"
    printf 'cell id:  %s\n' "$(rt_env_get "$ETC/cell.env" CELL_ID)"
    for u in kodus-cell-injector.service kodus-cell-egress.service kodus-cell.service kodus-cell-reaper.timer; do
        printf '%-28s %s\n' "$u" "$("$SYSTEMCTL" is-active "$u" 2>/dev/null || true)"
    done
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 5 http://127.0.0.1:9466/metrics 2>/dev/null | grep -E '^cell_(claims|free_slots|hub_connected|deadman)' || true
    fi
}

cmd_backup() {
    [ -n "$OUT" ] || rt_die "--out FILE is required"
    [ -d "$ETC" ] || rt_die "no cell installed here"
    umask 077
    # Identity (re-registering makes a new cell instead), local PKI and config,
    # and the bake catalog (kodus-ai apps/runtime-cell/README.md: preserve it
    # across upgrades). Build caches and the registry mirror are not saved.
    local paths=("${ETC_R#/}" "${REAPER_ENV#"$PREFIX"/}")
    [ -d "$WORKDIR/state/bakes" ] && paths+=("${WORKDIR_R#/}/state/bakes")
    tar -C "${PREFIX:-/}" -czf "$OUT" "${paths[@]}"
    rt_ok "Cell state saved to $OUT (0600). It holds the cell's private keys."
}

cmd_uninstall() {
    require_root
    local cell
    cell=$(rt_env_get "$ETC/cell.env" CELL_ID)
    run "$SYSTEMCTL" disable --now kodus-cell-reaper.timer kodus-cell.target kodus-cell.service kodus-cell-egress.service kodus-cell-injector.service || true
    run "$DOCKER" rm -f "$EGRESS_NAME" "$INJECTOR_NAME" || true
    run "$DOCKER" network rm "$ENFORCERS_NAME" || true
    if [ -n "$cell" ] && [ "$DRY_RUN" = 0 ]; then
        # Whatever the agent left: its machines and networks carry its label.
        "$DOCKER" ps -aq --filter "label=kodus.cell=$cell" | xargs -r "$DOCKER" rm -f -v >/dev/null 2>&1 || true
        "$DOCKER" network ls -q --filter "label=kodus.cell=$cell" | xargs -r "$DOCKER" network rm >/dev/null 2>&1 || true
    fi
    local u
    for u in $UNIT_NAMES; do run rm -f "$UNITS/$u"; done
    run "$SYSTEMCTL" daemon-reload
    if [ "$PURGE" = 1 ]; then
        run rm -rf "$ETC" "$OPT" "$WORKDIR" "$REAPER_ENV"
        rt_info "Removed $ETC_R, $OPT_R, $WORKDIR_R."
    else
        rt_info "Kept $ETC_R (identity), $OPT_R and $WORKDIR_R; --purge removes them."
    fi
    if [ "$REMOVE_RUNSC" = 1 ]; then
        run "$LOCAL_BIN/runsc" uninstall --runtime runsc || true
        run "$SYSTEMCTL" reload docker
        run rm -f "$LOCAL_BIN/runsc" "$LOCAL_BIN/containerd-shim-runsc-v1"
    fi
    rt_ok "Cell ${cell:-?} removed from this host. Revoke it in Kodus too: POST /runtime/cells/${cell:-<id>}/revoke (org owner)."
}

case "$COMMAND" in
    check) cmd_check ;;
    install) cmd_install ;;
    upgrade) cmd_upgrade ;;
    rollback) cmd_rollback ;;
    rotate-local-pki) cmd_rotate ;;
    status) cmd_status ;;
    backup) cmd_backup ;;
    uninstall) cmd_uninstall ;;
    '' | -h | --help | help) usage ;;
    *) rt_die "unknown command '$COMMAND' (see --help)" ;;
esac
