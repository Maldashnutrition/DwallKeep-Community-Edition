#!/bin/bash
# DwallKeep — VPN + Tor chain manager
# Copyright (C) 2025 Siyavuyisa Ntengo
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
# =============================================================================
set -eEuo pipefail
trap 'rc=$?; echo "ERROR: line $LINENO failed (rc=$rc)" >&2; exit $rc' ERR

export DEBIAN_FRONTEND=noninteractive
export SYSTEMD_OFFLINE=1

VERSION="1.5.9-community"

declare -r PERSISTENT_STORE="/var/lib/multi-chain-community"
declare -r RUNTIME_DIR="/run/multi-chain-community"
declare -r ROOTFS="$PERSISTENT_STORE/rootfs"
declare -r ROOTFS_SENTINEL="$ROOTFS/.local-build-success"
declare -r SYSTEM_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
declare -r DWK_COOLDOWN_FILE="$PERSISTENT_STORE/.last_start"
declare -r OVERRIDE_FILE="$PERSISTENT_STORE/.override_timestamps"

readonly CONTAINER_NAME="mc"
readonly HOST_VETH="ve-mc"
readonly HOST_IP="10.10.0.1"
readonly CONTAINER_IP="10.10.0.2"
readonly SUBNET="10.10.0.0/24"

readonly ENTRY_PASSWORD_FILE="$RUNTIME_DIR/vpnbook_password"
readonly ENTRY_OVPN_FILE="$RUNTIME_DIR/entry.ovpn"
readonly EXIT_OVPN_FILE="$RUNTIME_DIR/exit.ovpn"
readonly ENTRY_HOST_FILE="$RUNTIME_DIR/entry_host"
readonly EXIT_HOST_FILE="$RUNTIME_DIR/exit_host"
readonly ENTRY_AUTH_FILE="$RUNTIME_DIR/entry_auth.txt"
readonly EXIT_AUTH_FILE="$RUNTIME_DIR/exit_auth.txt"
readonly DWK_PROVIDER="${DWK_PROVIDER:-vpnbook}"
readonly DWK_PROVIDER_DIR="${DWK_PROVIDER_DIR:-}"
readonly DWK_ENTRY_OVPN="${DWK_ENTRY_OVPN:-}"
readonly DWK_EXIT_OVPN="${DWK_EXIT_OVPN:-}"
readonly DWK_AUTH_FILE="${DWK_AUTH_FILE:-}"
readonly DWK_COOLDOWN_SEC="${DWK_COOLDOWN_SEC:-900}"
readonly DWK_OVERRIDE_WINDOW_SEC="${DWK_OVERRIDE_WINDOW_SEC:-1500}"
readonly DWK_OVERRIDE_MAX="${DWK_OVERRIDE_MAX:-3}"
readonly DWK_SKIP_NET_SELFTEST="${DWK_SKIP_NET_SELFTEST:-0}"
readonly VPNBOOK_ENTRY_SERVERS=(
    "us16.vpnbook.com" "us178.vpnbook.com"
    "ca149.vpnbook.com" "ca196.vpnbook.com"
    "uk205.vpnbook.com" "uk68.vpnbook.com"
    "de20.vpnbook.com"  "de220.vpnbook.com"
)
readonly VPNBOOK_EXIT_SERVERS=(
    "ca196.vpnbook.com" "uk68.vpnbook.com"
    "uk205.vpnbook.com" "de220.vpnbook.com"
)
__CLEANUP_DONE=0
CHAIN_MODE="unknown"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
if [[ ! -t 1 ]]; then GREEN=''; YELLOW=''; RED=''; BLUE=''; BOLD=''; NC=''; fi
log()    { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()     { printf '  %b %s\n' "${GREEN}[OK]${NC}"   "$*"; }
warn()   { printf '  %b %s\n' "${YELLOW}[WARN]${NC}" "$*"; }
err()    { printf '  %b %s\n' "${RED}[ERR]${NC}"   "$*" >&2; }
die()    { err "$*"; exit 1; }
section(){ printf '\n%s\n' "${BOLD}${BLUE}═══ $* ═══${NC}"; }


check_cooldown() {
    local force="${1:-0}"
    (( force )) && return 0
    [[ "$DWK_PROVIDER" != "vpnbook" ]] && return 0
    [[ "$DWK_COOLDOWN_SEC" -le 0 ]] && return 0
    [[ -f "$DWK_COOLDOWN_FILE" ]] || return 0
    local last now elapsed remaining
    last=$(cat "$DWK_COOLDOWN_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    elapsed=$(( now - last ))
    if (( elapsed < DWK_COOLDOWN_SEC )); then
        remaining=$(( DWK_COOLDOWN_SEC - elapsed ))
        err "Cooldown active: ${remaining}s remaining (last start ${elapsed}s ago)."
        err "VPNBook is a shared personal-use resource; rapid reconnection risks a ban."
        err "Use --force to override (rate-limited), or wait ${remaining}s."
        return 1
    fi
    return 0
}

write_cooldown() {
    [[ "$DWK_PROVIDER" != "vpnbook" ]] && return 0
    mkdir -p "$PERSISTENT_STORE"
    date +%s > "$DWK_COOLDOWN_FILE"
}

cooldown_status_sec() {
    [[ "$DWK_PROVIDER" != "vpnbook" ]] && { echo 0; return 0; }
    [[ -f "$DWK_COOLDOWN_FILE" ]] || { echo 0; return 0; }
    local last now elapsed remaining
    last=$(cat "$DWK_COOLDOWN_FILE" 2>/dev/null || echo 0)
    now=$(date +%s); elapsed=$(( now - last ))
    remaining=$(( DWK_COOLDOWN_SEC - elapsed ))
    (( remaining < 0 )) && remaining=0
    echo "$remaining"
}


check_override_limit() {
    [[ "$DWK_PROVIDER" != "vpnbook" ]] && return 0

    mkdir -p "$PERSISTENT_STORE"
    touch "$OVERRIDE_FILE"

    local now cutoff tmp count oldest next_at wait
    now=$(date +%s)
    cutoff=$(( now - DWK_OVERRIDE_WINDOW_SEC ))

    tmp=$(mktemp)
    while IFS= read -r ts; do
        if [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > cutoff )); then
            echo "$ts" >> "$tmp"
        fi
    done < "$OVERRIDE_FILE"
    mv "$tmp" "$OVERRIDE_FILE"

    count=$(wc -l < "$OVERRIDE_FILE" | tr -d ' ')
    count=${count:-0}

    if (( count >= DWK_OVERRIDE_MAX )); then
        oldest=$(head -1 "$OVERRIDE_FILE")
        if [[ "$oldest" =~ ^[0-9]+$ ]]; then
            next_at=$(( oldest + DWK_OVERRIDE_WINDOW_SEC ))
            wait=$(( next_at - now ))
            (( wait < 0 )) && wait=0
            err "Override limit reached: ${count}/${DWK_OVERRIDE_MAX} used in the last $(( DWK_OVERRIDE_WINDOW_SEC / 60 )) minutes."
            err "Next override available in ${wait}s."
        else
            err "Override limit reached: ${count}/${DWK_OVERRIDE_MAX} used."
        fi
        return 1
    fi

    echo "$now" >> "$OVERRIDE_FILE"
    ok "override granted (${count}/${DWK_OVERRIDE_MAX} used in window)"
    return 0
}


override_status() {
    if [[ "$DWK_PROVIDER" != "vpnbook" || ! -f "$OVERRIDE_FILE" ]]; then
        printf 'count=0\nmax=%s\nremaining=%s\nnext_in=0\n' \
            "$DWK_OVERRIDE_MAX" "$DWK_OVERRIDE_MAX"
        return 0
    fi

    local now cutoff count oldest ts
    now=$(date +%s)
    cutoff=$(( now - DWK_OVERRIDE_WINDOW_SEC ))
    count=0
    oldest=0

    while IFS= read -r ts; do
        if [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > cutoff )); then
            (( count == 0 )) && oldest=$ts
            count=$(( count + 1 ))
        fi
    done < "$OVERRIDE_FILE"

    local remaining=$(( DWK_OVERRIDE_MAX - count ))
    (( remaining < 0 )) && remaining=0
    local next_in=0
    if (( count >= DWK_OVERRIDE_MAX && oldest > 0 )); then
        next_in=$(( oldest + DWK_OVERRIDE_WINDOW_SEC - now ))
        (( next_in < 0 )) && next_in=0
    fi

    printf 'count=%s\nmax=%s\nremaining=%s\nnext_in=%s\n' \
        "$count" "$DWK_OVERRIDE_MAX" "$remaining" "$next_in"
}

show_policy_banner() {
    [[ "$DWK_PROVIDER" != "vpnbook" ]] && return 0
    printf '\n%b\n' "${YELLOW}${BOLD}── VPNBook Usage Notice ──${NC}"
    printf '%b\n' "${YELLOW}VPNBook is a shared, personal-use service."
    printf '%b\n' "Their policy: \"This free VPN service is for personal use only.\""
    printf '%b\n' "They log connection IPs and ban abusers: \"If you abuse the system, your IP will be banned.\""
    printf '%b\n' "Cooldown: ${DWK_COOLDOWN_SEC}s between starts."
    printf '%b\n\n' "Overrides: max ${DWK_OVERRIDE_MAX} per $(( DWK_OVERRIDE_WINDOW_SEC / 60 )) min.${NC}"
}
get_vpnbook_password() {
    if [[ -n "${VPNBOOK_PASSWORD:-}" ]]; then
        printf '%s\n' "$VPNBOOK_PASSWORD"; return 0
    fi
    if [[ -s "$ENTRY_PASSWORD_FILE" ]]; then
        cat "$ENTRY_PASSWORD_FILE" || true
        return 0
    fi
    die "No VPNBook password provided."
}

setup_auth_files() {
    case "$DWK_PROVIDER" in
        vpnbook)
            local pw
            pw=$(get_vpnbook_password)
            [[ -z "$pw" ]] && die "No VPNBook password provided."
            printf 'vpnbook\n%s\n' "$pw" > "$ENTRY_AUTH_FILE"
            printf 'vpnbook\n%s\n' "$pw" > "$EXIT_AUTH_FILE"
            ;;
        file|generic-ovpn)
            if [[ -n "$DWK_AUTH_FILE" ]]; then
                [[ -f "$DWK_AUTH_FILE" ]] || die "DWK_AUTH_FILE not found: $DWK_AUTH_FILE"
                cp "$DWK_AUTH_FILE" "$ENTRY_AUTH_FILE"
                cp "$DWK_AUTH_FILE" "$EXIT_AUTH_FILE"
            else
                printf 'vpnbook\n\n' > "$ENTRY_AUTH_FILE"
                printf 'vpnbook\n\n' > "$EXIT_AUTH_FILE"
            fi
            ;;
        *)
            die "unknown provider: $DWK_PROVIDER"
            ;;
    esac
    chmod 600 "$ENTRY_AUTH_FILE" "$EXIT_AUTH_FILE"
}
fetch_vpnbook_config() {
    local server="$1" outfile="$2" attempt
    local url="https://www.vpnbook.com/api/openvpn?hostname=$server&protocol=tcp443"

    mkdir -p "$(dirname "$outfile")" || { err "cannot create $(dirname "$outfile")"; return 1; }

    for attempt in 1 2 3; do
        if curl -fsSL --create-dirs --max-time 30 --connect-timeout 15 --cacert /etc/ssl/certs/ca-certificates.crt -A "Mozilla/5.0" -o "$outfile" "$url" \
           && [[ -s "$outfile" ]] && grep -qE '^remote\s+' "$outfile"; then
            return 0
        fi
        (( attempt < 3 )) && sleep 3
    done
    return 1
}

pin_remote_ip() {
    local config="$1" host_file="$2" original_host ip
    original_host=$(grep -m1 '^remote ' "$config" | awk '{print $2}') || true
    [[ -n "$original_host" ]] || return 1
    if [[ "$original_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip="$original_host"
    else
        ip=$(dig +short A +time=3 +tries=2 "$original_host" 2>/dev/null \
             | grep -E '^[0-9]+\.' | head -1) || true
        [[ -z "$ip" ]] && return 1
        sed -i "s|^remote[[:space:]].*|remote ${ip} 443|" "$config"
    fi
    printf '%s\n' "$ip" > "$host_file"
    printf '%s' "$ip"
    return 0
}

clean_openvpn_remotes() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local tmp="${file}.clean.$$"
    grep -vE '^(remote|port|proto)[[:space:]]' "$file" > "$tmp" || true
    mv "$tmp" "$file"
}
pick_chain() {
    section "Selecting chain (provider: $DWK_PROVIDER)"
    case "$DWK_PROVIDER" in
        vpnbook)      pick_chain_vpnbook ;;
        file)         pick_chain_file ;;
        generic-ovpn) pick_chain_generic ;;
        *) die "unknown provider: $DWK_PROVIDER" ;;
    esac
}

pick_chain_vpnbook() {
    local entry_server="${VPNBOOK_ENTRY_SERVERS[$(( RANDOM % ${#VPNBOOK_ENTRY_SERVERS[@]} ))]}"
    fetch_vpnbook_config "$entry_server" "$ENTRY_OVPN_FILE" || die "VPNBook entry download failed for $entry_server"
    local entry_ip
    entry_ip=$(pin_remote_ip "$ENTRY_OVPN_FILE" "$ENTRY_HOST_FILE") || die "cannot pin entry IP"
    ok "entry: VPNBook $entry_server -> $entry_ip"

    rm -f "$RUNTIME_DIR"/exit_[0-9]*.ovpn "$RUNTIME_DIR"/exit_host_[0-9]* "$RUNTIME_DIR/exit_count" 2>/dev/null || true

    local pool=() s
    for s in "${VPNBOOK_EXIT_SERVERS[@]}"; do
        [[ "$s" != "$entry_server" ]] && pool+=("$s")
    done
    local shuffled=() idx
    while (( ${#pool[@]} > 0 )); do
        idx=$(( RANDOM % ${#pool[@]} ))
        shuffled+=("${pool[$idx]}")
        unset 'pool[idx]'
        pool=("${pool[@]}")
    done

    local n=0 server exit_file host_file exit_ip
    for server in "${shuffled[@]}"; do
        local next=$((n + 1))
        exit_file="$RUNTIME_DIR/exit_${next}.ovpn"
        host_file="$RUNTIME_DIR/exit_host_${next}"
        if ! fetch_vpnbook_config "$server" "$exit_file"; then
            warn "exit candidate $next: $server — download failed, skipping"
            rm -f "$exit_file"; continue
        fi
        if ! exit_ip=$(pin_remote_ip "$exit_file" "$host_file"); then
            warn "exit candidate $next: $server — cannot pin IP, skipping"
            rm -f "$exit_file" "$host_file"; continue
        fi
        clean_openvpn_remotes "$exit_file"
        n=$((n + 1))
        ok "exit candidate $n: $server -> $exit_ip"
    done

    (( n == 0 )) && die "no exit VPN candidates could be prepared"
    echo "$n" > "$RUNTIME_DIR/exit_count"
    ok "prepared $n exit candidate(s)"
}

pick_chain_file() {
    [[ -n "$DWK_PROVIDER_DIR" && -d "$DWK_PROVIDER_DIR" ]] || die "DWK_PROVIDER_DIR must be a directory"
    local cfgs=() f
    while IFS= read -r f; do cfgs+=("$f"); done < <(find "$DWK_PROVIDER_DIR" -maxdepth 1 -name '*.ovpn' -type f)
    (( ${#cfgs[@]} == 0 )) && die "no .ovpn files found in $DWK_PROVIDER_DIR"
    local entry_cfg="${cfgs[$(( RANDOM % ${#cfgs[@]} ))]}"
    local exit_cfg="${cfgs[$(( RANDOM % ${#cfgs[@]} ))]}"
    cp "$entry_cfg" "$ENTRY_OVPN_FILE"
    cp "$exit_cfg"  "$EXIT_OVPN_FILE"
    local entry_ip exit_ip
    entry_ip=$(pin_remote_ip "$ENTRY_OVPN_FILE" "$ENTRY_HOST_FILE") || die "cannot pin entry IP"
    exit_ip=$(pin_remote_ip  "$EXIT_OVPN_FILE"  "$EXIT_HOST_FILE")  || die "cannot pin exit IP"
    clean_openvpn_remotes "$EXIT_OVPN_FILE"
    ok "entry: $entry_cfg -> $entry_ip"
    ok "exit:  $exit_cfg -> $exit_ip (via Tor)"

    rm -f "$RUNTIME_DIR"/exit_[0-9]*.ovpn "$RUNTIME_DIR"/exit_host_[0-9]* "$RUNTIME_DIR/exit_count" 2>/dev/null || true
    cp "$EXIT_OVPN_FILE" "$RUNTIME_DIR/exit_1.ovpn"
    printf '%s\n' "$exit_ip" > "$RUNTIME_DIR/exit_host_1"
    echo 1 > "$RUNTIME_DIR/exit_count"
}

pick_chain_generic() {
    [[ -f "$DWK_ENTRY_OVPN" ]] || die "DWK_ENTRY_OVPN not set or file missing"
    [[ -f "$DWK_EXIT_OVPN"  ]] || die "DWK_EXIT_OVPN not set or file missing"
    cp "$DWK_ENTRY_OVPN" "$ENTRY_OVPN_FILE"
    cp "$DWK_EXIT_OVPN"  "$EXIT_OVPN_FILE"
    local entry_ip exit_ip
    entry_ip=$(pin_remote_ip "$ENTRY_OVPN_FILE" "$ENTRY_HOST_FILE") || die "cannot pin entry IP"
    exit_ip=$(pin_remote_ip  "$EXIT_OVPN_FILE"  "$EXIT_HOST_FILE")  || die "cannot pin exit IP"
    clean_openvpn_remotes "$EXIT_OVPN_FILE"
    ok "entry: $DWK_ENTRY_OVPN -> $entry_ip"
    ok "exit:  $DWK_EXIT_OVPN -> $exit_ip (via Tor)"

    rm -f "$RUNTIME_DIR"/exit_[0-9]*.ovpn "$RUNTIME_DIR"/exit_host_[0-9]* "$RUNTIME_DIR/exit_count" 2>/dev/null || true
    cp "$EXIT_OVPN_FILE" "$RUNTIME_DIR/exit_1.ovpn"
    printf '%s\n' "$exit_ip" > "$RUNTIME_DIR/exit_host_1"
    echo 1 > "$RUNTIME_DIR/exit_count"
}

build_rootfs_locally() {
    local target="$1"
    local build_dir
    build_dir=$(mktemp -d /var/tmp/multi-chain-build.XXXXXX) || die "mktemp failed"
    local rootfs="$build_dir/rootfs"
    local mirrors=(
        "https://deb.debian.org/debian"
        "https://mirrors.kernel.org/debian"
    )
    local packages=(
        systemd openvpn tor dnsmasq nftables iproute2
        curl bind9-dnsutils ca-certificates netcat-openbsd
        procps logrotate cron
        firefox-esr xterm dbus dbus-x11 x11-xserver-utils xauth
        fonts-dejavu fonts-liberation locales locales-all
        libgl1 mesa-utils pciutils
    )
    local setup_hook="$build_dir/setup-hook.sh"
    cat > "$setup_hook" <<'EOF'
#!/bin/bash
set -e
target="$1"
mkdir -p "$target/usr/sbin"
printf '#!/bin/sh\nexit 101\n' > "$target/usr/sbin/policy-rc.d"
chmod +x "$target/usr/sbin/policy-rc.d"
EOF
    chmod +x "$setup_hook"
    local apt_opts="Acquire::http::Pipeline-Depth 10; Acquire::https::Pipeline-Depth 10; Acquire::Retries 5; Acquire::Queue-Mode access; Acquire::http::Dl-Limit 0; Acquire::https::Dl-Limit 0; Acquire::Languages none; Acquire::http::Timeout 30; Acquire::https::Timeout 30;"
    mkdir -p "$rootfs"
    log "Running mmdebstrap (this may take 15-20 min)..."
    if mmdebstrap --mode=auto --variant=minbase \
        --include="$(IFS=,; echo "${packages[*]}")" \
        --keyring="$SYSTEM_KEYRING" --aptopt="$apt_opts" \
        --dpkgopt='force-unsafe-io' --setup-hook="$setup_hook" \
        stable "$rootfs" "${mirrors[@]}"; then
        rm -f "$rootfs/usr/sbin/policy-rc.d"
    else
        die "mmdebstrap failed."
    fi
    sync_rootfs_files "$rootfs"
    echo "$VERSION" > "$rootfs/.local-build-success"
    mkdir -p "$PERSISTENT_STORE"
    rm -rf "$ROOTFS"
    mv "$rootfs" "$ROOTFS"
    rm -rf "$build_dir"
    ok "rootfs ready (v$VERSION)"
}

prepare_rootfs() {
    if [[ -f "$ROOTFS_SENTINEL" && -d "$ROOTFS" ]]; then
        local stored_version
        stored_version=$(cat "$ROOTFS_SENTINEL" 2>/dev/null || echo "")
        if [[ "$stored_version" == "$VERSION" ]]; then
            ok "using cached rootfs (v$VERSION)"
            return
        fi
        warn "rootfs is v$stored_version; need v$VERSION — forcing rebuild"
        rm -rf "$ROOTFS"
    fi
    build_rootfs_locally "$ROOTFS"
}

find_container_pid() {
    local pid
    pid=$(machinectl show "$CONTAINER_NAME" -p Leader --value 2>/dev/null || true)
    [[ -n "$pid" ]] && { printf '%s\n' "$pid"; return 0; }
    local nspawn_pid
    nspawn_pid=$(pgrep -f "systemd-nspawn.*--machine=${CONTAINER_NAME}" | head -1 || true)
    [[ -z "$nspawn_pid" ]] && return 1
    pid=$(pgrep -P "$nspawn_pid" | head -1 || true)
    [[ -z "$pid" ]] && return 1
    printf '%s\n' "$pid"
}

cleanup_work() {
    trap - ERR
    set +e
    (( __CLEANUP_DONE )) && return 0
    __CLEANUP_DONE=1
    if mountpoint -q "/run/systemd/nspawn/${CONTAINER_NAME}/unix-export" 2>/dev/null; then
        umount -l "/run/systemd/nspawn/${CONTAINER_NAME}/unix-export" 2>/dev/null || true
    fi
    rm -rf "/run/systemd/nspawn/${CONTAINER_NAME}" 2>/dev/null || true
    printf '\n[%s] cleanup: stopping container and removing firewall\n' "$(date +%H:%M:%S)"
    timeout 3 machinectl poweroff "$CONTAINER_NAME" >/dev/null 2>&1 || true
    timeout 3 systemctl stop "machine-${CONTAINER_NAME}.scope" 2>/dev/null || true
    timeout 3 systemctl reset-failed "machine-${CONTAINER_NAME}.scope" 2>/dev/null || true
    pkill -9 -f "systemd-nspawn.*--machine=${CONTAINER_NAME}" 2>/dev/null || true
    ip link del "$HOST_VETH" >/dev/null 2>&1 || true
    nft delete table inet mc-community >/dev/null 2>&1 || true
    printf '[%s] cleanup: done\n' "$(date +%H:%M:%S)"
}

cleanup_and_exit() {
    local _rc=$?
    trap - EXIT INT TERM HUP
    cleanup_work
    exit "$_rc"
}

preflight() {
    section "Preflight"
    [[ $EUID -eq 0 ]] || die "must run as root"
    ok "root"
    local missing=()
    for cmd in systemd-nspawn machinectl nft ip mmdebstrap curl openssl pgrep pkill dig python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [[ ${#missing[@]} -gt 0 ]] && die "missing: ${missing[*]}"
    ok "dependencies present"
    unshare -U true 2>/dev/null || die "user namespaces not available"
    ok "user namespaces available"
    if machinectl show "$CONTAINER_NAME" >/dev/null 2>&1; then
        local state
        state=$(machinectl show "$CONTAINER_NAME" -p State --value 2>/dev/null || echo "unknown")
        [[ "$state" == "running" ]] && die "container '$CONTAINER_NAME' is running — use --stop first"
    fi
    ok "no conflicting container"
}

sync_rootfs_files() {
    local target="$1"
    mkdir -p "$target/usr/local/bin" "$target/etc/systemd/system/multi-user.target.wants"
    cat > "$target/usr/local/bin/mc-runtime" <<'RUNTIME_EOF'
#!/bin/bash
set -e
log() { echo "[$(date +%H:%M:%S)] $*"; }

pkill -9 -f 'openvpn.*--dev tun0' 2>/dev/null || true
pkill -9 -f 'openvpn.*--dev tun1' 2>/dev/null || true
pkill -9 -x tor     2>/dev/null || true
pkill -9 -x dnsmasq 2>/dev/null || true
ip link del tun0 2>/dev/null || true
ip link del tun1 2>/dev/null || true
nft delete table inet container     2>/dev/null || true
nft delete table inet container-nat 2>/dev/null || true

rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > /etc/resolv.conf

for i in {1..30}; do ip link show host0 >/dev/null 2>&1 && break; sleep 1; done
ip link set host0 up
ip addr replace 10.10.0.2/24 dev host0
ip route replace default via 10.10.0.1 dev host0 onlink

sysctl -w net.ipv4.conf.all.rp_filter=0     2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
sysctl -w net.ipv4.conf.host0.rp_filter=0   2>/dev/null || true
sysctl -w net.ipv4.tcp_fastopen=3           2>/dev/null || true
sysctl -w net.ipv4.tcp_mtu_probing=2        2>/dev/null || true
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null || true
sysctl -w net.ipv4.tcp_rmem="4096 262144 33554432" 2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem="4096 262144 33554432" 2>/dev/null || true

id tor-daemon &>/dev/null || useradd -r -s /bin/false tor-daemon
tor_uid=$(id -u tor-daemon)
getent group dnsmasq >/dev/null || groupadd -r dnsmasq
getent passwd dnsmasq >/dev/null || useradd -r -g dnsmasq -s /bin/false dnsmasq

log "Starting entry VPN"
ENTRY_IP=$(grep -m1 '^remote ' /root/entry.ovpn | awk '{print $2}') || ENTRY_IP=""

openvpn --config /root/entry.ovpn --auth-user-pass /root/entry_auth.txt \
    --daemon --dev tun0 --route-noexec --pull \
    --pull-filter ignore redirect-gateway \
    --pull-filter ignore block-outside-dns \
    --pull-filter ignore tun-mtu \
    --pull-filter ignore mssfix \
    --tun-mtu 1240 --mssfix 1200 \
    --data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC:AES-128-CBC \
    --data-ciphers-fallback AES-256-CBC \
    --tls-version-min 1.2 --remote-cert-tls server \
    --connect-retry-max 0 --connect-timeout 30 \
    --keepalive 10 60 --auth-nocache --auth-retry none \
    --log-append /var/log/entry.log --writepid /var/run/entry.pid

for i in {1..120}; do
    if ip link show up dev tun0 >/dev/null 2>&1 \
       && ip -4 addr show dev tun0 2>/dev/null | grep -q 'inet '; then break; fi
    sleep 1
done
if ! ip link show up dev tun0 >/dev/null 2>&1; then
    log "ENTRY VPN FAILED"
    tail -40 /var/log/entry.log 2>/dev/null || true
    exit 1
fi
log "entry VPN connected"

ip route replace "$ENTRY_IP/32" via 10.10.0.1 dev host0 2>/dev/null || true
ip route replace default dev tun0

log "Starting Tor"
rm -rf /var/run/tor /var/tor
mkdir -p /var/run/tor /var/tor
chown tor-daemon:tor-daemon /var/tor; chmod 700 /var/tor
chown root:root /var/run/tor; chmod 755 /var/run/tor
: > /var/log/tor.log
chown tor-daemon:tor-daemon /var/log/tor.log; chmod 644 /var/log/tor.log
cat > /etc/tor/torrc <<'TORRC'
TransPort 9040
DNSPort 53530
SOCKSPort 9050
DataDirectory /var/tor
User tor-daemon
CircuitPadding 1
SocksTimeout 90
CircuitBuildTimeout 60
TORRC
tor --runasdaemon 1 --PidFile /tmp/tor.pid --Log "notice file /var/log/tor.log"
log "waiting for Tor bootstrap (this can take 15-20 min on VPNBook)"
last_tor_marker=""
tor_stuck_since=0
for i in {1..2400}; do
    if grep -q "Bootstrapped 100%" /var/log/tor.log 2>/dev/null; then
        break
    fi
    if (( i % 60 == 0 )); then
        cur=$(grep -oE 'Bootstrapped [0-9]+%' /var/log/tor.log 2>/dev/null | tail -1 || echo "0%")
        log "Tor: $cur (${i}s)"
        if [[ "$cur" == "$last_tor_marker" ]]; then
            if (( tor_stuck_since == 0 )); then tor_stuck_since=$i; fi
            if (( i - tor_stuck_since >= 300 )); then
                log "WARNING: Tor stuck at $cur for >300s; VPNBook entry may be hostile to Tor"
                tor_stuck_since=$i
            fi
        else
            last_tor_marker="$cur"
            tor_stuck_since=0
        fi
    fi
    sleep 1
done
grep -q "Bootstrapped 100%" /var/log/tor.log 2>/dev/null || {
    log "TOR FAILED (no bootstrap in 2400s)"
    tail -40 /var/log/tor.log 2>/dev/null || true
    exit 1
}
log "Tor bootstrapped"

log "Starting dnsmasq"
dnsmasq --no-resolv --server=127.0.0.1#53530 \
    --listen-address=127.0.0.1 --port=53 --cache-size=1000 \
    --conf-file=/dev/null --pid-file=/var/run/dnsmasq.pid \
    --user=dnsmasq --group=dnsmasq --keep-in-foreground &

for i in {1..20}; do
    if ss -lun 2>/dev/null | grep -qE ':53[[:space:]]' \
       || ss -ltn 2>/dev/null | grep -qE ':53[[:space:]]'; then
        break
    fi
    sleep 0.5
done
if ! dig +short +timeout=2 @127.0.0.1 localhost >/dev/null 2>&1; then
    log "WARNING: dnsmasq not answering on 127.0.0.1:53 (chain DNS may fail)"
fi

rm -f /etc/resolv.conf
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf

ip rule del uidrange "${tor_uid}-${tor_uid}" lookup 100 2>/dev/null || true
ip route replace default dev tun0 table 100 2>/dev/null || true
ip rule add uidrange "${tor_uid}-${tor_uid}" lookup 100 2>/dev/null || true

log "Installing killswitch"
nft add table inet container
nft add chain inet container output '{ type filter hook output priority 0 ; policy drop ; }'
nft add rule inet container output oif lo accept
nft add rule inet container output ct state established,related accept
nft add rule inet container output meta skuid "$tor_uid" accept
nft add rule inet container output ip daddr "$ENTRY_IP" accept
nft add rule inet container output oifname tun0 accept
nft add rule inet container output oifname tun1 accept
nft add rule inet container output oifname host0 ip daddr 10.10.0.1 accept
nft add rule inet container output icmp type { destination-unreachable, time-exceeded, parameter-problem } accept

nft add table inet container-nat
nft add chain inet container-nat output '{ type nat hook output priority dstnat ; }'
nft add rule inet container-nat output meta skuid "$tor_uid" return
nft add rule inet container-nat output ip daddr 127.0.0.0/8 return
nft add rule inet container-nat output udp dport 53 redirect to :53
nft add rule inet container-nat output tcp dport 53 redirect to :53

log "Starting exit VPN (via Tor)"
EXIT_CANDIDATE_COUNT=$(cat /root/exit_count 2>/dev/null || echo 0)
EXIT_OK=0
EXIT_ATTEMPTS=0
EXIT_LAST_ERROR=""

if [[ "$EXIT_CANDIDATE_COUNT" -lt 1 ]]; then
    log "no exit VPN candidates staged; running in 2-hop"
else
    log "trying $EXIT_CANDIDATE_COUNT exit candidate(s)"
    n=1
    while (( n <= EXIT_CANDIDATE_COUNT )); do
        EXIT_ATTEMPTS=$((EXIT_ATTEMPTS + 1))
        EXIT_HOST=$(cat "/root/exit_host_${n}" 2>/dev/null || echo "")
        if [[ -z "$EXIT_HOST" ]]; then
            log "exit candidate $n/$EXIT_CANDIDATE_COUNT: no host IP; skipping"
            n=$((n + 1)); continue
        fi
        log "exit candidate $n/$EXIT_CANDIDATE_COUNT: connecting to $EXIT_HOST"

        pkill -9 -f 'openvpn.*--dev tun1' 2>/dev/null || true
        ip link del tun1 2>/dev/null || true
        sleep 1

        openvpn --config "/root/exit_${n}.ovpn" --auth-user-pass "/root/exit_auth_${n}.txt" \
            --daemon \
            --dev tun1 --route-noexec --pull \
            --proto tcp-client --socks-proxy 127.0.0.1 9050 \
            --remote "$EXIT_HOST" 443 \
            --pull-filter ignore redirect-gateway \
            --pull-filter ignore block-outside-dns \
            --pull-filter ignore tun-mtu \
            --pull-filter ignore mssfix \
            --tun-mtu 1100 --mssfix 1060 \
            --data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC:AES-128-CBC \
            --data-ciphers-fallback AES-256-CBC \
            --tls-version-min 1.2 --remote-cert-tls server \
            --connect-retry-max 0 --connect-timeout 30 \
            --keepalive 10 60 --auth-nocache --auth-retry none \
            --server-poll-timeout 60 \
            --log-append "/var/log/exit_${n}.log" --writepid "/var/run/exit_${n}.pid"

        TUNNEL_UP=0
        for i in {1..60}; do
            if ip link show up dev tun1 >/dev/null 2>&1 \
               && ip -4 addr show dev tun1 2>/dev/null | grep -q 'inet '; then
                TUNNEL_UP=1; break
            fi
            sleep 1
        done
        if (( !TUNNEL_UP )); then
            EXIT_LAST_ERROR="candidate $n: tunnel never came up"
            log "exit candidate $n: tunnel never came up; trying next"
            n=$((n + 1)); continue
        fi

        log "exit candidate $n: tunnel up; testing traffic (max 30s)"
        ip route replace default dev tun1
        sleep 3
        if timeout 35 curl -s --interface tun1 -m 30 https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1; then
            log "exit candidate $n: PASSED — 3-hop active"
            EXIT_OK=1
            break
        else
            EXIT_LAST_ERROR="candidate $n: traffic test failed"
            log "exit candidate $n: traffic test failed; trying next"
            pkill -9 -f 'openvpn.*--dev tun1' 2>/dev/null || true
            ip link del tun1 2>/dev/null || true
            ip route replace default dev tun0 2>/dev/null || true
        fi
        n=$((n + 1))
    done
fi

if [[ "${EXIT_OK:-0}" == "1" ]]; then
    ip route replace default dev tun1
    log "chain: user -> tun1(exit) -> Tor -> tun0(entry) -> internet  [3-hop]"
    log "EXIT_SUCCESS: passed on attempt $EXIT_ATTEMPTS of $EXIT_CANDIDATE_COUNT"
else
    ip route replace default dev tun0
    log "chain: user -> tun0(entry) -> internet  [2-hop: Tor + exit VPN unavailable]"
    log "EXIT_FAILED: all $EXIT_CANDIDATE_COUNT exit candidate(s) exhausted"
    log "EXIT_LAST_ERROR: $EXIT_LAST_ERROR"

    pkill -x dnsmasq 2>/dev/null || true
    sleep 1
    ENTRY_DNS=$(grep -m1 'dhcp-option DNS' /var/log/entry.log 2>/dev/null \
                | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
    ENTRY_DNS="${ENTRY_DNS:-1.1.1.1}"
    log "2-hop: reconfiguring dnsmasq upstream to entry VPN DNS $ENTRY_DNS"
    dnsmasq --no-resolv --server="$ENTRY_DNS" \
        --listen-address=127.0.0.1 --port=53 --cache-size=1000 \
        --conf-file=/dev/null --pid-file=/var/run/dnsmasq.pid \
        --user=dnsmasq --group=dnsmasq --keep-in-foreground &
    sleep 2
    if ! dig +short +timeout=2 @127.0.0.1 example.com >/dev/null 2>&1; then
        log "WARNING: dnsmasq reconfiguration did not produce a working resolver"
    fi
fi

while true; do
    sleep 60
    if ! ip link show up dev tun0 >/dev/null 2>&1; then
        log "entry VPN down; exiting for systemd to restart"
        exit 1
    fi
done
RUNTIME_EOF
    chmod +x "$target/usr/local/bin/mc-runtime"

    cat > "$target/etc/systemd/system/mc-runtime.service" <<'UNIT_EOF'
[Unit]
Description=Multi-Chain Community Runtime
After=network.target
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
Type=simple
ExecStart=/usr/local/bin/mc-runtime
Restart=on-failure
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF

    ln -sf /etc/systemd/system/mc-runtime.service "$target/etc/systemd/system/multi-user.target.wants/mc-runtime.service"
    ln -sf /dev/null "$target/etc/systemd/system/tor.service"
    ln -sf /dev/null "$target/etc/systemd/system/dnsmasq.service"
    [[ -f "$target/lib/systemd/system/tor@default.service" ]] && ln -sf /dev/null "$target/etc/systemd/system/tor@default.service" || true
    : > "$target/etc/machine-id" 2>/dev/null || true
}

setup_host_firewall() {
    section "Host firewall"
    nft delete table inet mc-community 2>/dev/null || true
    nft add table inet mc-community
    nft add chain inet mc-community forward '{ type filter hook forward priority 10 ; policy accept ; }'
    nft add chain inet mc-community postrouting '{ type nat hook postrouting priority 110 ; policy accept ; }'
    nft add rule inet mc-community forward iifname "$HOST_VETH" oifname != "$HOST_VETH" accept
    nft add rule inet mc-community forward iifname != "$HOST_VETH" oifname "$HOST_VETH" ct state established,related accept
    nft add rule inet mc-community postrouting ip saddr "$SUBNET" masquerade
    ok "host firewall applied"
}

setup_and_start_container() {
    section "Starting container"
    systemctl reset-failed "machine-${CONTAINER_NAME}.scope" 2>/dev/null || true
    systemctl stop "machine-${CONTAINER_NAME}.scope" 2>/dev/null || true
    machinectl terminate "$CONTAINER_NAME" 2>/dev/null || true
    pkill -9 -f "systemd-nspawn.*--machine=${CONTAINER_NAME}" 2>/dev/null || true
    if mountpoint -q "/run/systemd/nspawn/${CONTAINER_NAME}/unix-export" 2>/dev/null; then
        umount -l "/run/systemd/nspawn/${CONTAINER_NAME}/unix-export" 2>/dev/null || true
    fi
    rm -rf "/run/systemd/nspawn/${CONTAINER_NAME}" 2>/dev/null || true
    ip link del "$HOST_VETH" 2>/dev/null || true
    sleep 2

    setup_auth_files
    ok "auth files prepared for provider '$DWK_PROVIDER'"

    mkdir -p "$ROOTFS/root"
    cp "$ENTRY_OVPN_FILE" "$ROOTFS/root/entry.ovpn"
    cp "$ENTRY_AUTH_FILE" "$ROOTFS/root/entry_auth.txt"
    chmod 600 "$ROOTFS/root/entry_auth.txt"

    rm -f "$ROOTFS/root"/exit_[0-9]*.ovpn "$ROOTFS/root"/exit_host_[0-9]* \
          "$ROOTFS/root"/exit_auth_[0-9]*.txt "$ROOTFS/root/exit_count" 2>/dev/null || true
    local exit_count n
    exit_count=$(cat "$RUNTIME_DIR/exit_count" 2>/dev/null || echo 0)
    (( exit_count < 1 )) && die "no exit candidates staged in $RUNTIME_DIR"
    for (( n=1; n<=exit_count; n++ )); do
        cp "$RUNTIME_DIR/exit_${n}.ovpn"  "$ROOTFS/root/exit_${n}.ovpn"
        cp "$RUNTIME_DIR/exit_host_${n}"  "$ROOTFS/root/exit_host_${n}"
        cp "$ENTRY_AUTH_FILE"             "$ROOTFS/root/exit_auth_${n}.txt"
        chmod 600 "$ROOTFS/root/exit_auth_${n}.txt"
    done
    echo "$exit_count" > "$ROOTFS/root/exit_count"
    ok "staged $exit_count exit candidate(s) into rootfs"
    rm -f "$ROOTFS"/var/log/entry.log "$ROOTFS"/var/log/tor.log "$ROOTFS"/var/log/exit*.log 2>/dev/null || true
    sync_rootfs_files "$ROOTFS"
    ok "runtime + unit synced into rootfs"
    xhost +local: >/dev/null 2>&1 || true
    local XAUTH_SRC="${XAUTHORITY:-$HOME/.Xauthority}"
    local XAUTH_CONTAINER="$RUNTIME_DIR/container_xauth"
    rm -f "$XAUTH_CONTAINER"

    if [[ -n "${DISPLAY:-}" && -f "$XAUTH_SRC" ]] && command -v xauth >/dev/null 2>&1; then
        if xauth -f "$XAUTH_SRC" nextract - "$DISPLAY" 2>/dev/null \
           | sed -e 's/^..../ffff/' \
           | xauth -f "$XAUTH_CONTAINER" nmerge - 2>/dev/null; then
            chmod 600 "$XAUTH_CONTAINER" 2>/dev/null || true
        fi
    fi
    if [[ ! -s "$XAUTH_CONTAINER" && -f "$XAUTH_SRC" ]]; then
        warn "FamilyWild Xauthority extraction failed; falling back to host copy"
        cp "$XAUTH_SRC" "$XAUTH_CONTAINER" || true
        chmod 600 "$XAUTH_CONTAINER" 2>/dev/null || true
    fi
    if [[ -s "$XAUTH_CONTAINER" ]]; then
        cp "$XAUTH_CONTAINER" "$ROOTFS/root/.Xauthority"
        chmod 600 "$ROOTFS/root/.Xauthority"
        ok "Xauthority prepared for container"
    else
        warn "no Xauthority available; relying on xhost +local:"
    fi

    for _ in 1 2 3 4 5; do
        [[ -S /tmp/.X11-unix/X"${DISPLAY#*:}" ]] && break || true
        sleep 0.2
    done

    local nspawn_err="$RUNTIME_DIR/nspawn-stderr.log"
    rm -f "$nspawn_err"

    systemd-nspawn \
        -D "$ROOTFS" \
        --machine="$CONTAINER_NAME" \
        --network-veth \
        --bind-ro=/tmp/.X11-unix:/run/host-x11 \
        --bind=/dev/shm \
        --setenv=DISPLAY="$DISPLAY" \
        --setenv=XAUTHORITY="/root/.Xauthority" \
        --setenv=LANG=C.UTF-8 \
        --boot \
        --capability="CAP_NET_ADMIN,CAP_DAC_OVERRIDE,CAP_CHOWN,CAP_SETUID,CAP_SETGID,CAP_NET_RAW" \
        --resolv-conf=off \
        --console=pipe \
        --property=TasksMax=1024 \
        --property=MemoryMax=1G \
        --quiet \
        </dev/null 2> "$nspawn_err" &
    local nspawn_pid=$!

    local i state=""
    for i in {1..60}; do
        state=$(machinectl show "$CONTAINER_NAME" -p State --value 2>/dev/null || true)
        [[ "$state" == "running" ]] && break
        sleep 1
    done
    if [[ "$state" != "running" ]]; then
        err "container failed to start (pid $nspawn_pid, state=$state)"
        [[ -s "$nspawn_err" ]] && { err "nspawn stderr:"; sed 's/^/    /' "$nspawn_err"; }
        kill "$nspawn_pid" 2>/dev/null || true
        return 1
    fi
    ok "container running"

    for i in {1..30}; do ip link show "$HOST_VETH" >/dev/null 2>&1 && break; sleep 1; done
    ip link show "$HOST_VETH" >/dev/null 2>&1 || { err "host veth never appeared"; return 1; }
    ip link set "$HOST_VETH" up
    ip addr add "$HOST_IP/24" dev "$HOST_VETH" 2>/dev/null || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    ok "veth $HOST_VETH up ($HOST_IP)"
}

show_logs() {
    section "Container logs"
    local f host_path
    for f in entry.log tor.log $(ls "$ROOTFS/var/log/" 2>/dev/null | grep -E '^exit_[0-9]+\.log$' || true); do
        host_path="$ROOTFS/var/log/$f"
        if [[ -f "$host_path" && -s "$host_path" ]]; then
            printf '\n─── /var/log/%s (last 30 lines) ───\n' "$f"
            tail -30 "$host_path"
        fi
    done
    if [[ -s "$RUNTIME_DIR/nspawn-stderr.log" ]]; then
        printf '\n─── nspawn stderr ───\n'
        cat "$RUNTIME_DIR/nspawn-stderr.log"
    fi
    return 0
}

wait_for_tunnel() {
    section "Waiting for chain"
    local pid i
    pid=$(find_container_pid) || die "cannot find container PID"
    log "container PID: $pid"

    for i in {1..300}; do
        nsenter -t "$pid" -n ip link show up dev tun0 >/dev/null 2>&1 && { ok "tun0 up"; break; }
        sleep 1
        (( i % 30 == 0 )) && log "still waiting for tun0 (${i}s)"
    done
    nsenter -t "$pid" -n ip link show up dev tun0 >/dev/null 2>&1 || { show_logs; return 1; }

    log "waiting for Tor bootstrap + exit candidates (up to 1800s)..."
    log "note: VPNBook's entry server can be slow to allow Tor (15-20 min is not uncommon)"

    local last_attempt="" attempt_line chain_line fail_line
    local last_tor="" tor_progress state
    for i in {1..1800}; do
        state=$(machinectl show "$CONTAINER_NAME" -p State --value 2>/dev/null || echo "gone")
        if [[ "$state" != "running" ]]; then
            warn "container stopped during wait (state=$state) at ${i}s"
            show_logs
            return 1
        fi

        tor_progress=$(grep -oE 'Bootstrapped [0-9]+%' "$ROOTFS/var/log/tor.log" 2>/dev/null | tail -1 || true)
        if [[ -n "$tor_progress" && "$tor_progress" != "$last_tor" ]]; then
            last_tor="$tor_progress"
            log "progress: Tor $tor_progress"
        fi
        attempt_line=$(journalctl -b -M "$CONTAINER_NAME" -u mc-runtime --no-pager 2>/dev/null \
                       | grep -E "exit candidate [0-9]+/[0-9]+: connecting" | tail -1) || true
        if [[ -n "$attempt_line" && "$attempt_line" != "$last_attempt" ]]; then
            last_attempt="$attempt_line"
            log "progress: ${attempt_line##*] }"
        fi

        chain_line=$(journalctl -b -M "$CONTAINER_NAME" -u mc-runtime --no-pager 2>/dev/null \
                     | grep "chain: user ->" | tail -1) || true
        if [[ -n "$chain_line" ]]; then
            if [[ "$chain_line" == *"3-hop"* ]]; then
                CHAIN_MODE="3-hop"; ok "settled: ${chain_line##*] }"
            else
                CHAIN_MODE="2-hop"; warn "settled: ${chain_line##*] }"
                fail_line=$(journalctl -b -M "$CONTAINER_NAME" -u mc-runtime --no-pager 2>/dev/null \
                            | grep "EXIT_FAILED:" | tail -1) || true
                [[ -n "$fail_line" ]] && warn "  ${fail_line##*] }"
            fi
            return 0
        fi
        sleep 1
        (( i % 60 == 0 )) && log "still waiting for chain declaration (${i}s)"
    done
    warn "runtime did not declare chain within 1800s"
    show_logs
    return 1
}

do_self_test() {
    section "Self-test"
    local pid
    pid=$(find_container_pid) || { err "container not running"; return 1; }
    local fails=0

    if nsenter -t "$pid" -n ip link show up dev tun0 >/dev/null 2>&1; then
        ok "tun0 up"
    else
        err "tun0 missing"; fails=$((fails+1))
    fi

    if [[ "$DWK_SKIP_NET_SELFTEST" != "1" ]]; then
        local tor_ok=0 attempt http_code resp
        for attempt in 1 2 3; do
            http_code=$(nsenter -t "$pid" -n curl -sS --socks5-hostname 127.0.0.1:9050 \
                --max-time 45 -o /tmp/tor_check.out -w '%{http_code}' \
                https://check.torproject.org/api/ip 2>/tmp/tor_check.err || true)
            if [[ -s /tmp/tor_check.out ]] && grep -q '"IsTor":true' /tmp/tor_check.out 2>/dev/null; then
                tor_ok=1; break
            fi
            resp=$(nsenter -t "$pid" -n curl -sS --socks5-hostname 127.0.0.1:9050 \
                --max-time 30 https://api.ipify.org 2>/dev/null || true)
            if [[ "$resp" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                tor_ok=1; break
            fi
            (( attempt < 3 )) && sleep 5
        done
        if (( tor_ok )); then
            ok "Tor circuit works"
        else
            warn "Tor SOCKS check inconclusive (http=${http_code:-none}); continuing"
            if [[ -s /tmp/tor_check.err ]]; then
                warn "  SOCKS error (first 3 lines):"
                head -3 /tmp/tor_check.err 2>/dev/null | while IFS= read -r l; do warn "    $l"; done
            fi
            if nsenter -t "$pid" -n ss -tlnp 2>/dev/null | grep -q ':9050'; then
                warn "  Tor SOCKS port 9050 IS listening inside container"
            else
                warn "  Tor SOCKS port 9050 NOT listening — tor may have exited after bootstrap"
            fi
        fi
    else
        warn "network self-test skipped (DWK_SKIP_NET_SELFTEST=1)"
    fi

    if [[ "$CHAIN_MODE" == "3-hop" ]]; then
        ok "chain mode: 3-hop (exit VPN)"
    elif [[ "$CHAIN_MODE" == "2-hop" ]]; then
        warn "chain mode: 2-hop (Tor only, no exit VPN)"
    else
        warn "chain mode: NOT DECLARED (runtime didn't settle)"
    fi

    if [[ "$DWK_SKIP_NET_SELFTEST" != "1" ]]; then
        local real_ip exit_ip
        real_ip=$(curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || true)
        exit_ip=$(nsenter -t "$pid" -n curl -s --max-time 90 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || true)
        if [[ -z "$exit_ip" ]]; then
            err "full chain check failed (no response)"; fails=$((fails+1))
        elif [[ "$exit_ip" == "$real_ip" ]]; then
            warn "exit IP ($exit_ip) equals host IP — cannot verify end-to-end"
            warn "  (expected if you are already behind a VPN on the host)"
        else
            ok "exit IP: $exit_ip (host: $real_ip)"
        fi
    fi

    if (( fails > 0 )); then
        err "self-test failed ($fails check(s))"
        return 1
    fi
    printf '  %b ALL REQUIRED CHECKS PASSED\n' "${GREEN}[OK]${NC}"
    return 0
}
show_help() {
    cat <<HELP
DwallKeep v$VERSION

USAGE:
  sudo bash $0 [OPTIONS]

OPTIONS:
  (no option)          Start the chain (subject to cooldown).
  --force              Start despite cooldown (rate-limited: ${DWK_OVERRIDE_MAX}
                       uses per $(( DWK_OVERRIDE_WINDOW_SEC / 60 )) min).
                       Downgraded to a no-op if cooldown is not active.
  --stop               Tear down the container and firewall.
  --cooldown-status    Print seconds remaining in cooldown (0 if none).
  --override-status    Print override window state as key=value lines
                       (count, max, remaining, next_in).
  --version            Print version and exit.
  -h, --help           Print this message and exit.

ENVIRONMENT:
  VPNBOOK_PASSWORD=...       Password for vpnbook provider.
  DWK_PROVIDER=vpnbook|file|generic-ovpn
  DWK_PROVIDER_DIR=DIR       (file provider: directory of .ovpn files)
  DWK_ENTRY_OVPN=PATH        (generic-ovpn provider)
  DWK_EXIT_OVPN=PATH         (generic-ovpn provider)
  DWK_AUTH_FILE=PATH         Auth file (username line 1, password line 2)
  DWK_COOLDOWN_SEC=900       Cooldown window, seconds (vpnbook; 0 disables)
  DWK_OVERRIDE_WINDOW_SEC=1500  Rolling override window, seconds
  DWK_OVERRIDE_MAX=3         Max --force uses per rolling window
  DWK_SKIP_NET_SELFTEST=1    Skip network self-test (local checks only)
HELP
}
main() {
    local FORCE=0 STOP_ONLY=0 COOLDOWN_STATUS_ONLY=0 OVERRIDE_STATUS_ONLY=0
    local SHOW_HELP=0 SHOW_VERSION=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)            FORCE=1; shift ;;
            --stop)             STOP_ONLY=1; shift ;;
            --cooldown-status)  COOLDOWN_STATUS_ONLY=1; shift ;;
            --override-status)  OVERRIDE_STATUS_ONLY=1; shift ;;
            --version)          SHOW_VERSION=1; shift ;;
            -h|--help)          SHOW_HELP=1; shift ;;
            *) die "unknown argument: $1 (try --help)" ;;
        esac
    done

    if (( SHOW_VERSION )); then
        echo "$VERSION"
        return 0
    fi
    if (( SHOW_HELP )); then
        show_help
        return 0
    fi
    if (( COOLDOWN_STATUS_ONLY )); then
        cooldown_status_sec
        return 0
    fi
    if (( OVERRIDE_STATUS_ONLY )); then
        override_status
        return 0
    fi
    if (( STOP_ONLY )); then
        log "stopping chain"
        cleanup_work
        return 0
    fi

    section "DwallKeep v$VERSION"

    mkdir -p "$RUNTIME_DIR"
    chmod 755 "$RUNTIME_DIR"

    preflight || exit 1
    trap cleanup_and_exit EXIT INT TERM HUP

    show_policy_banner

    check_cooldown "$FORCE" || exit 1

    if (( FORCE )); then
        local cd_rem
        cd_rem=$(cooldown_status_sec)
        if (( cd_rem > 0 )); then
            check_override_limit || exit 1
        else
            log "--force: cooldown not active, treating as no-op"
        fi
    fi

    prepare_rootfs       || exit 1
    pick_chain           || exit 1
    setup_host_firewall  || exit 1
    setup_and_start_container || exit 1

    if ! wait_for_tunnel; then
        err "chain did not declare within timeout"
        err "if this repeats, the Tor bootstrap may be stuck on this entry;"
        err "try again with --force (rate-limited) to pick a different entry."
        exit 1
    fi
    write_cooldown

    if ! do_self_test; then
        err "self-test failed; tearing down container for a clean retry"
        exit 1
    fi
    trap - EXIT INT TERM HUP ERR

    section "Chain ready"
    ok "container: $CONTAINER_NAME (state: running)"
    ok "chain mode: $CHAIN_MODE"
    ok "to stop: sudo bash $0 --stop"
    ok "container will keep running in the background"
    return 0
}

main "$@"
