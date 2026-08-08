#!/usr/bin/env bash
#
# ZNC Toolbox — Telepítő, Frissítő és Eltávolító
# Debian / Ubuntu rendszerekhez
# ---------------------------------------------------------------------------
# Használat:
#   sudo ./znc-toolbox.sh              ▸ interaktív menü
#   sudo ./znc-toolbox.sh install      ▸ telepítés
#   sudo ./znc-toolbox.sh update       ▸ frissítés
#   sudo ./znc-toolbox.sh uninstall    ▸ eltávolítás
#   sudo ./znc-toolbox.sh status       ▸ állapot
# ---------------------------------------------------------------------------

set -Eeuo pipefail

# ── Változók ─────────────────────────────────────────────────────────────────
readonly ZNC_USER="znc"
readonly ZNC_HOME="/home/${ZNC_USER}"
readonly ZNC_PREFIX="${ZNC_HOME}/znc"
readonly ZNC_BIN="${ZNC_PREFIX}/bin/znc"
readonly ZNC_CONF_DIR="${ZNC_HOME}/.znc/configs"
readonly ZNC_CONF_FILE="${ZNC_CONF_DIR}/znc.conf"
readonly SERVICE_FILE="/etc/systemd/system/znc.service"
readonly API_URL="https://api.github.com/repos/znc/znc/tags"
readonly DL_BASE="https://znc.in/releases/archive"
readonly LOG_FILE="/var/log/znc-toolbox.log"

# ── Színkódok ────────────────────────────────────────────────────────────────
readonly C_RESET='\e[0m'
readonly C_BOLD='\e[1m'
readonly C_GREEN='\e[32m'
readonly C_YELLOW='\e[33m'
readonly C_RED='\e[31m'
readonly C_CYAN='\e[36m'

# ── Segédfüggvények ─────────────────────────────────────────────────────────
msg()      { echo -e "  ${1}"; }
info()     { echo -e "  ${C_CYAN}[i]${C_RESET} ${1}"; }
ok()       { echo -e "  ${C_GREEN}[✔]${C_RESET} ${1}"; }
warn()     { echo -e "  ${C_YELLOW}[!]${C_RESET} ${1}"; }
error()    { echo -e "  ${C_RED}[✘]${C_RESET} ${1}" >&2; }
header()   { echo -e "\n  ${C_BOLD}━ ${1}${C_RESET}"; }

die() {
    error "$1"
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ── Ideiglenes könyvtár takarítás ───────────────────────────────────────────
trap_cleanup() {
    local ec=$?
    if [[ -n "${TMP_DIR:-}" ]] && [[ -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR" 2>/dev/null
    fi
    exit "$ec"
}
trap trap_cleanup EXIT

# ── Root ellenőrzés ─────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "A scriptet root jogosultsággal kell futtatni! (sudo $0 ${*:-})"
    fi
}

# ── OS ellenőrzés ───────────────────────────────────────────────────────────
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Nem található az /etc/os-release fájl. Csak Debian / Ubuntu támogatott."
    fi
    source /etc/os-release 2>/dev/null || die "Nem sikerült beolvasni az /etc/os-release fájlt."
    if [[ "$ID" != "debian" ]] && [[ "$ID" != "ubuntu" ]]; then
        die "Csak Debian vagy Ubuntu rendszereken használható. (Érzékelt: ${ID})"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  GET_LATEST_VERSION — GitHub tags API-n keresztül
# ══════════════════════════════════════════════════════════════════════════════
get_latest_version() {
    local tag
    tag="$(wget -qO- \
        --timeout=15 --tries=1 --dns-timeout=5 --connect-timeout=5 \
        --header="User-Agent: znc-toolbox/2.0" \
        "$API_URL" 2>/dev/null \
        | grep -Po '"name":\s*"\Kznc-[0-9]+\.[0-9]+\.[0-9]+(?=")' \
        | head -1 || true)"
    if [[ -z "$tag" ]]; then
        error "Nem sikerült lekérdezni a legfrissebb ZNC verziót."
        return 1
    fi
    echo "${tag#znc-}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  GET_INSTALLED_VERSION — ha telepítve van
# ══════════════════════════════════════════════════════════════════════════════
get_installed_version() {
    if [[ -x "$ZNC_BIN" ]]; then
        local ver
        ver="$("$ZNC_BIN" --version 2>&1 | grep -Po '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        echo "$ver"
    else
        echo ""
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL_DEPS — függőségek telepítése
# ══════════════════════════════════════════════════════════════════════════════
install_deps() {
    header "Függőségek telepítése"
    apt-get update -qq
    local pkgs=(build-essential cmake pkg-config libssl-dev libsasl2-dev
                libicu-dev libzstd-dev wget tar)
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
    for pkg in "${pkgs[@]}"; do
        dpkg -s "$pkg" &>/dev/null && ok "$pkg" || warn "$pkg"
    done
    log "Függőségek telepítve: ${pkgs[*]}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  BUILD_ZNC — ZNC letöltése, fordítása, telepítése
# ══════════════════════════════════════════════════════════════════════════════

# Parancs futtatása pont-animációval, kimenet a log fájlba
_spin() {
    local desc="$1"; shift
    local pid
    printf "  ${C_CYAN}[i]${C_RESET} %s..." "$desc"
    ("$@" >> "$LOG_FILE" 2>&1) &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf "."
        sleep 1
    done
    wait "$pid"
    local ec=$?
    if [[ $ec -eq 0 ]]; then
        printf " ${C_GREEN}kész.${C_RESET}\n"
    else
        printf " ${C_RED}hiba!${C_RESET}\n"
        return 1
    fi
}

build_znc() {
    local version="$1"
    local enable_ipv6="${2:-yes}"

    header "ZNC ${version} letöltése"
    TMP_DIR="$(mktemp -d)"
    local tarball="znc-${version}.tar.gz"
    local url="${DL_BASE}/${tarball}"

    info "Letöltés: $url"
    wget -q --show-progress --timeout=60 --tries=3 -O "${TMP_DIR}/${tarball}" "$url" \
        || die "Letöltés sikertelen."
    ok "Letöltés kész."

    header "Forráskód kibontása"
    tar -xzf "${TMP_DIR}/${tarball}" -C "$TMP_DIR"
    local src_dir="${TMP_DIR}/znc-${version}"
    ok "Kibontva: $src_dir"

    header "ZNC fordítása"
    local build_dir="${src_dir}/build"
    local cmake_opts="-DCMAKE_INSTALL_PREFIX=${ZNC_PREFIX}"
    if [[ ! "$enable_ipv6" =~ ^[iIyY] ]]; then
        cmake_opts="${cmake_opts} -DWANT_IPV6=OFF"
    fi

    _spin "CMake konfigurálása" \
        cmake -S "$src_dir" -B "$build_dir" $cmake_opts -Wno-dev \
        || die "CMake konfigurálás sikertelen."

    _spin "Fordítás, ez eltarthat néhány percig" \
        make -C "$build_dir" -j"$(nproc)" \
        || die "Fordítás sikertelen."
    ok "ZNC ${version} sikeresen lefordult."

    header "ZNC telepítése"
    _spin "Telepítés (make install)" \
        make -C "$build_dir" install \
        || die "Telepítés (make install) sikertelen."
    ok "Telepítve: ${ZNC_PREFIX}"
    log "ZNC ${version} lefordítva és telepítve a(z) ${ZNC_PREFIX} könyvtárba."

    rm -rf "$TMP_DIR"
    TMP_DIR=""
}

# ══════════════════════════════════════════════════════════════════════════════
#  CREATE_USER — znc rendszerfelhasználó
# ══════════════════════════════════════════════════════════════════════════════
create_user() {
    header "Rendszerfelhasználó"
    if id "$ZNC_USER" &>/dev/null; then
        ok "A '${ZNC_USER}' felhasználó már létezik."
        # Home könyvtár létezését biztosítjuk
        if [[ ! -d "$ZNC_HOME" ]]; then
            mkdir -p "$ZNC_HOME"
        fi
    else
        local group_opt=""
        if getent group "$ZNC_USER" &>/dev/null; then
            group_opt="-g ${ZNC_USER}"
        fi
        if [[ -d "$ZNC_HOME" ]]; then
            info "A(z) ${ZNC_HOME} könyvtár már létezik, --no-create-home használata."
            # shellcheck disable=SC2086
            useradd --system --home-dir "$ZNC_HOME" --shell /bin/bash \
                --no-create-home $group_opt "$ZNC_USER" \
                || die "Felhasználó létrehozása sikertelen."
        else
            # shellcheck disable=SC2086
            useradd --system --home-dir "$ZNC_HOME" --shell /bin/bash \
                --create-home $group_opt "$ZNC_USER" \
                || die "Felhasználó létrehozása sikertelen."
        fi
        ok "A '${ZNC_USER}' felhasználó létrehozva."
    fi
    chown -R "${ZNC_USER}:${ZNC_USER}" "$ZNC_HOME"
    chmod 750 "$ZNC_HOME"
    log "Felhasználó beállítva: ${ZNC_USER}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAKE_CONFIG — konfigurációs varázsló
# ══════════════════════════════════════════════════════════════════════════════
make_config() {
    header "ZNC konfiguráció"
    if [[ -f "$ZNC_CONF_FILE" ]]; then
        ok "Meglévő konfiguráció található — érintetlenül hagyjuk."
        return 0
    fi

    warn "Nincs konfiguráció. A --makeconf varázsló elindul..."

    echo ""
    msg "  ${C_BOLD}── ZNC Konfigurációs Varázsló ──${C_RESET}"
    echo ""
    msg "  A varázsló végigvezet a szükséges beállításokon."
    echo ""

    read -r -p "  Folytatás? [Enter] "

    sudo -u "$ZNC_USER" mkdir -p "${ZNC_HOME}/.znc"

    local makeconf_rc
    while true; do
        echo ""
        set +e
        sudo -u "$ZNC_USER" env HOME="$ZNC_HOME" "$ZNC_BIN" --makeconf
        makeconf_rc=$?
        set -e

        if [[ $makeconf_rc -eq 0 ]] || [[ $makeconf_rc -eq 130 ]]; then
            ok "Konfigurációs varázsló befejeződött."
        else
            warn "A varázsló ${makeconf_rc} hibakóddal ért véget."
        fi

        if [[ -f "$ZNC_CONF_FILE" ]]; then
            ok "Konfigurációs fájl létrejött: ${ZNC_CONF_FILE}"
            break
        fi

        error "A konfigurációs fájl nem jött létre (${ZNC_CONF_FILE})"
        read -r -p "  Újra próbálod? [I/n] " retry
        if [[ "$retry" =~ ^[nN]$ ]]; then
            die "Konfiguráció nélkül a ZNC nem indítható."
        fi
    done
    log "Konfiguráció létrehozva: ${ZNC_CONF_FILE}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  SERVICE_SETUP — systemd szolgáltatás létrehozása és indítása
# ══════════════════════════════════════════════════════════════════════════════
service_setup() {
    header "Systemd szolgáltatás"

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=ZNC — Advanced IRC Bouncer
Documentation=https://wiki.znc.in/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ZNC_USER}
Group=${ZNC_USER}
ExecStart=${ZNC_BIN} --foreground
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=znc

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${ZNC_HOME}/.znc
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes

[Install]
WantedBy=multi-user.target
EOF

    ok "Szolgáltatásfájl: $SERVICE_FILE"

    systemctl daemon-reload
    ok "daemon-reload"

    systemctl enable znc.service
    ok "Engedélyezve (enable)"

    # Leállítunk minden esetlegesen futó ZNC-t
    pkill -u "$ZNC_USER" znc 2>/dev/null || true
    sleep 1

    info "ZNC indítása..."
    systemctl start znc.service || true
    sleep 2

    if systemctl is-active --quiet znc.service; then
        ok "A ZNC szolgáltatás sikeresen fut."
    else
        error "A ZNC szolgáltatás nem tudott elindulni."
        echo ""
        journalctl -u znc.service --no-pager -n 20 2>&1 || true
        echo ""

        if [[ ! -f "$ZNC_CONF_FILE" ]]; then
            warn "A konfigurációs fájl hiányzik. Futtasd:"
            msg   "  sudo -u ${ZNC_USER} ${ZNC_BIN} --makeconf"
        else
            warn "Ellenőrizd a konfigurációt: ${ZNC_CONF_FILE}"
        fi
    fi
    log "Systemd szolgáltatás beállítva és elindítva."
}

# ══════════════════════════════════════════════════════════════════════════════
#  PRINT_SUMMARY — telepítési / frissítési összegzés
# ══════════════════════════════════════════════════════════════════════════════
print_summary() {
    local ver status port web_url ip ssl
    ver="$("$ZNC_BIN" --version 2>&1 | head -1 || echo "ismeretlen")"

    if systemctl is-active --quiet znc.service 2>/dev/null; then
        status="${C_GREEN}fut${C_RESET}"
    else
        status="${C_RED}nem fut${C_RESET}"
    fi

    # Port és SSL kiolvasása a konfigból
    if [[ -f "$ZNC_CONF_FILE" ]]; then
        port="$(grep -Po '^\s*Port\s*=\s*\K[0-9]+' "$ZNC_CONF_FILE" | head -1)"
        if grep -qP '^\s*SSL\s*=\s*true' "$ZNC_CONF_FILE"; then
            ssl="s"
        fi
    fi
    port="${port:-?}"

    # Port figyelés ellenőrzése
    local port_status
    if [[ "$port" != "?" ]] && ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        port_status="${C_GREEN}nyitva${C_RESET}"
    elif [[ "$port" != "?" ]]; then
        port_status="${C_RED}zárva${C_RESET}"
    else
        port_status="?"
    fi

    # Külső IP cím lekérése
    ip="$(wget -qO- --timeout=5 --tries=1 ipinfo.io/ip 2>/dev/null || echo "<IP>")"

    if [[ -n "${ssl:-}" ]]; then
        web_url="https://${ip}:${port}/"
    else
        web_url="http://${ip}:${port}/"
    fi

    local title="${1:-telepítve}"
    local ver_extra="${2:-}"

    echo ""
    echo -e "  ${C_GREEN}${C_BOLD}═══ ZNC ${title} ═══${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}Bináris   ${C_RESET} ${ZNC_BIN}"
    echo -e "  ${C_BOLD}Konfig    ${C_RESET} ${ZNC_CONF_FILE}"
    echo -e "  ${C_BOLD}Szolg.    ${C_RESET} znc.service (${status})"
    echo -e "  ${C_BOLD}Verzió    ${C_RESET} ${ver_extra:-${ver}}"
    echo -e "  ${C_BOLD}Port      ${C_RESET} ${port} (${port_status})"
    echo -e "  ${C_BOLD}Webadmin  ${C_RESET} ${web_url}"
    echo ""
    echo -e "  ${C_YELLOW}Parancsok:${C_RESET}"

    if [[ "$title" == "frissítve" ]]; then
        echo -e "  systemctl restart znc     \e[2m▸ újraindítás\e[0m"
        echo -e "  systemctl status znc      \e[2m▸ állapot lekérése\e[0m"
        echo -e "  journalctl -u znc -f      \e[2m▸ napló követése\e[0m"
    else
        echo -e "  systemctl start znc       \e[2m▸ indítás\e[0m"
        echo -e "  systemctl stop znc        \e[2m▸ leállítás\e[0m"
        echo -e "  systemctl restart znc     \e[2m▸ újraindítás\e[0m"
        echo -e "  systemctl status znc      \e[2m▸ állapot lekérése\e[0m"
        echo -e "  journalctl -u znc -f      \e[2m▸ napló követése\e[0m"
        echo -e "  sudo -u ${ZNC_USER} ${ZNC_BIN} --makeconf  \e[2m▸ újrakonfigurálás\e[0m"
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  STATUS — aktuális ZNC állapot kiírása
# ══════════════════════════════════════════════════════════════════════════════
show_status() {
    echo -e "\n  ${C_BOLD}═══ ZNC Állapot ═══${C_RESET}\n"

    local latest_fallback
    latest_fallback="$(get_latest_version 2>/dev/null || echo '?')"

    local installed_ver
    installed_ver="$(get_installed_version)"
    if [[ -n "$installed_ver" ]]; then
        msg "Telepített verzió: ${C_BOLD}${installed_ver}${C_RESET}"
    else
        msg "Telepített verzió: ${C_BOLD}nincs telepítve${C_RESET}"
    fi
    msg "Elérhető verzió:  ${C_BOLD}${latest_fallback}${C_RESET}"

    if [[ -x "$ZNC_BIN" ]]; then
        ok "ZNC bináris: ${ZNC_BIN}"
    else
        warn "ZNC bináris nem található: ${ZNC_BIN}"
    fi

    if [[ -f "$ZNC_CONF_FILE" ]]; then
        ok "Konfiguráció: ${ZNC_CONF_FILE}"
    else
        warn "Konfiguráció nem található."
    fi

    if id "$ZNC_USER" &>/dev/null; then
        ok "Felhasználó: ${ZNC_USER}"
    else
        warn "Felhasználó '${ZNC_USER}' nem létezik."
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        ok "Systemd szolgáltatás: telepítve"
        if systemctl is-active --quiet znc.service 2>/dev/null; then
            ok "Szolgáltatás: ${C_GREEN}fut${C_RESET}"
        else
            warn "Szolgáltatás: ${C_RED}nem fut${C_RESET}"
        fi
    else
        warn "Systemd szolgáltatás nincs telepítve."
    fi

    local installed
    installed="$(get_installed_version)"
    if [[ -n "$installed" ]] && [[ "$latest_fallback" != "?" ]]; then
        if [[ "$installed" != "$latest_fallback" ]]; then
            warn "Frissítés elérhető: ${installed} ▸ ${latest_fallback}"
            echo ""
            msg "        sudo $0 update"
        fi
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL — teljes telepítés
# ══════════════════════════════════════════════════════════════════════════════
do_install() {
    echo -e "\n  ${C_BOLD}═══ ZNC Telepítő ═══${C_RESET}\n"

    local installed
    installed="$(get_installed_version)"

    if [[ -n "$installed" ]]; then
        warn "ZNC ${installed} már telepítve van!"
        warn "Használd a 'update' parancsot a frissítéshez."
        warn "Vagy futtasd előbb a 'uninstall'-t a tiszta telepítéshez."
        return 0
    fi

    check_os

    read -r -p "  IPv6 engedélyezése? [I/n] " enable_ipv6
    enable_ipv6="${enable_ipv6:-i}"

    local version
    version="$(get_latest_version)"
    info "Legfrissebb verzió: ${C_BOLD}${version}${C_RESET}"

    read -r -p "  Más verziót szeretnél? (pl. 1.9.1) [Enter a ${version} elfogadásához] " custom_ver
    version="${custom_ver:-$version}"

    log "=== TELEPÍTÉS START: ZNC ${version} ==="

    install_deps
    create_user
    build_znc "$version" "$enable_ipv6"
    make_config

    # IPv6 beállítás mentése frissítéshez
    echo "$enable_ipv6" > "${ZNC_HOME}/.znc/toolbox-flags"

    service_setup
    print_summary

    log "=== TELEPÍTÉS KÉSZ: ZNC ${version} ==="
}

# ══════════════════════════════════════════════════════════════════════════════
#  UPDATE — meglévő ZNC frissítése (konfig megtartásával)
# ══════════════════════════════════════════════════════════════════════════════
do_update() {
    local installed latest
    installed="$(get_installed_version)"
    latest="$(get_latest_version)"

    if [[ -z "$installed" ]]; then
        error "A ZNC nincs telepítve. Használd az 'install' parancsot."
        return 0
    fi

    check_os

    echo -e "\n  ${C_BOLD}═══ ZNC Frissítő ═══${C_RESET}\n"
    msg "Telepített verzió: ${C_YELLOW}${installed}${C_RESET}"
    msg "Elérhető verzió:  ${C_GREEN}${latest}${C_RESET}"

    if [[ "$installed" == "$latest" ]]; then
        ok "Már a legfrissebb verzió van telepítve."
        return 0
    fi

    echo ""
    read -r -p "  Frissíted ${installed} ▸ ${latest} ? [I/n] " confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        info "Frissítés megszakítva."
        return 0
    fi

    log "=== FRISSÍTÉS START: ${installed} ▸ ${latest} ==="

    # Biztonsági mentés a konfigurációról
    if [[ -f "$ZNC_CONF_FILE" ]]; then
        local backup="${ZNC_CONF_DIR}/znc.conf.bak-$(date +%Y%m%d-%H%M%S)"
        info "Konfiguráció biztonsági mentése..."
        cp "$ZNC_CONF_FILE" "$backup"
        ok "Mentve: $backup"
    fi

    # Szolgáltatás leállítása
    if systemctl is-active --quiet znc.service 2>/dev/null; then
        info "ZNC leállítása..."
        systemctl stop znc.service
        ok "Szolgáltatás leállítva."
    fi

    # Régi bináris törlése
    if [[ -d "$ZNC_PREFIX" ]]; then
        info "Régi binárisok törlése..."
        rm -rf "$ZNC_PREFIX"
        ok "Törölve: ${ZNC_PREFIX}"
    fi

    install_deps
    create_user

    # Eredeti IPv6 beállítás visszaolvasása
    local enable_ipv6="i"
    if [[ -f "${ZNC_HOME}/.znc/toolbox-flags" ]]; then
        enable_ipv6="$(<"${ZNC_HOME}/.znc/toolbox-flags")"
        info "IPv6 beállítás megtartva: ${enable_ipv6}"
    fi

    build_znc "$latest" "$enable_ipv6"

    # IPv6 flag frissítése
    mkdir -p "${ZNC_HOME}/.znc"
    echo "$enable_ipv6" > "${ZNC_HOME}/.znc/toolbox-flags"

    # Konfigurációt NEM bántjuk, csak a binárist cseréltük
    ok "Konfiguráció megtartva."

    service_setup
    print_summary "frissítve" "${installed} ${C_YELLOW}▸${C_RESET} ${latest}"

    log "=== FRISSÍTÉS KÉSZ: ${installed} ▸ ${latest} ==="
}

# ══════════════════════════════════════════════════════════════════════════════
#  UNINSTALL — teljes eltávolítás
# ══════════════════════════════════════════════════════════════════════════════
do_uninstall() {
    # Ha semmi sincs telepítve
    if [[ ! -f "$SERVICE_FILE" ]] && [[ ! -d "$ZNC_PREFIX" ]] && ! id "$ZNC_USER" &>/dev/null; then
        info "Eltávolítás megszakítva — a ZNC nincs telepítve."
        return 0
    fi

    echo -e "\n  ${C_BOLD}═══ ZNC Eltávolító ═══${C_RESET}\n"

    warn "${C_RED}FIGYELEM:${C_RESET} Ez törli a ZNC-t, a konfigurációt és a felhasználót!"
    read -r -p "  Biztosan folytatod? (írd be: IGEN) " confirm
    if [[ "$confirm" != "IGEN" ]]; then
        info "Eltávolítás megszakítva."
        return 0
    fi
    echo ""

    log "=== ELTÁVOLÍTÁS START ==="

    # Systemd
    if [[ -f "$SERVICE_FILE" ]]; then
        info "Szolgáltatás leállítása és eltávolítása..."
        systemctl stop znc.service 2>/dev/null || true
        systemctl disable znc.service 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload 2>/dev/null || true
        ok "Systemd szolgáltatás eltávolítva."
    fi

    # ZNC folyamatok
    pkill -9 -u "$ZNC_USER" 2>/dev/null || true
    sleep 1

    # Minden znc user alatt futó folyamat leállítása
    pkill -9 -u "$ZNC_USER" 2>/dev/null || true
    sleep 1

    # Binárisok
    if [[ -d "$ZNC_PREFIX" ]]; then
        rm -rf "$ZNC_PREFIX"
        ok "Binárisok törölve: ${ZNC_PREFIX}"
    fi

    # Konfiguráció
    if [[ -d "${ZNC_HOME}/.znc" ]]; then
        rm -rf "${ZNC_HOME}/.znc"
        ok "Konfiguráció törölve."
    fi

    # Root alá került konfig takarítása
    if [[ -d /root/.znc ]]; then
        warn "Konfiguráció található a root home-jában: /root/.znc"
        read -r -p "  Töröljük? [I/n] " del
        if [[ ! "$del" =~ ^[nN]$ ]]; then
            rm -rf /root/.znc
            ok "Törölve: /root/.znc"
        fi
    fi

    # Felhasználó
    if id "$ZNC_USER" &>/dev/null; then
        userdel -f "$ZNC_USER" 2>/dev/null || true
        ok "Felhasználó törölve: ${ZNC_USER}"
    fi

    # Home könyvtár mindenképp törölve, akkor is ha a userdel nem takarított
    if [[ -d "$ZNC_HOME" ]]; then
        info "Home könyvtár törlése: ${ZNC_HOME}"
        cd /tmp
        if rm -rf "$ZNC_HOME"; then
            ok "Home könyvtár törölve."
        else
            warn "Nem sikerült törölni: ${ZNC_HOME}"
        fi
    fi

    echo ""
    echo -e "  ${C_GREEN}${C_BOLD}═══ Eltávolítás kész ═══${C_RESET}"
    log "=== ELTÁVOLÍTÁS KÉSZ ==="
}


# ══════════════════════════════════════════════════════════════════════════════
#  USER MANAGEMENT — felhasználók kezelése
# ══════════════════════════════════════════════════════════════════════════════

# Jelszó hash generálása (znc --makepass)
hash_password() {
    local pass="$1" output
    output="$(printf '%s\n%s\n' "$pass" "$pass" | sudo -u "$ZNC_USER" "$ZNC_BIN" --makepass 2>/dev/null)"
    if [[ -z "$output" ]]; then
        die "Nem sikerült a jelszó hash generálása."
    fi
    method="$(echo "$output" | grep -Po 'Method\s*=\s*\K\S+')"
    hash="$(echo "$output" | grep -Po 'Hash\s*=\s*\K\S+')"
    salt="$(echo "$output" | grep -Po 'Salt\s*=\s*\K\S+')"
    if [[ -z "$method" ]] || [[ -z "$hash" ]] || [[ -z "$salt" ]]; then
        die "Nem sikerült a jelszó hash értelmezése."
    fi
}

# Felhasználók listázása
do_user_list() {
    if [[ ! -f "$ZNC_CONF_FILE" ]]; then
        warn "ZNC konfiguráció nem található."
        return 0
    fi
    local users
    users="$(grep -Po '<User \K[^>]+' "$ZNC_CONF_FILE")"
    if [[ -z "$users" ]]; then
        msg "Nincsenek felhasználók."
        return 0
    fi
    echo ""
    while IFS= read -r name; do
        local admin
        admin="$(sed -n "/<User ${name}>/,/<\/User>/p" "$ZNC_CONF_FILE" | grep -Po '^\s*Admin\s*=\s*\K\w+' | head -1)"
        if [[ "$admin" == "true" ]]; then
            echo -e "  ${C_BOLD}${name}${C_RESET} ${C_GREEN}(admin)${C_RESET}"
        else
            echo -e "  ${name}"
        fi
    done <<< "$users"
    echo ""
}

# Új felhasználó hozzáadása
do_user_add() {
    if [[ ! -f "$ZNC_CONF_FILE" ]]; then
        warn "ZNC nincs telepítve. Először futtasd: $0 install"
        return 0
    fi

    header "Felhasználó létrehozása"
    echo ""

    local TAB=$'\t'
    local username admin nick altnick ident realname bindhost network_name server ssl port server_pass channels

    read -r -p "  Felhasználónév: " username
    if [[ -z "$username" ]]; then
        error "A felhasználónév nem lehet üres."
        return 0
    fi
    if grep -q "<User ${username}>" "$ZNC_CONF_FILE"; then
        error "A(z) '${username}' felhasználó már létezik."
        return 0
    fi

    local pass1 pass2
    while true; do
        read -r -s -p "  Jelszó (rejtett): " pass1
        echo ""
        read -r -s -p "  Jelszó újra: " pass2
        echo ""
        if [[ "$pass1" == "$pass2" ]] && [[ -n "$pass1" ]]; then
            break
        fi
        error "A jelszavak nem egyeznek vagy üresek."
    done

    read -r -p "  Admin? [i/N] " yn
    if [[ "$yn" =~ ^[iI]$ ]]; then
        admin="true"
    else
        admin="false"
    fi

    read -r -p "  Nick [${username}]: " nick
    nick="${nick:-$username}"
    read -r -p "  AltNick [${username}_]: " altnick
    altnick="${altnick:-${username}_}"

    local default_ident
    default_ident="$(echo "$username" | tr '[:upper:]' '[:lower:]')"
    read -r -p "  Ident [${default_ident}]: " ident
    ident="${ident:-$default_ident}"

    read -r -p "  RealName [${username}]: " realname
    realname="${realname:-$username}"
    read -r -p "  Bind host (opcionális): " bindhost

    # Hálózatok bekérése
    local network_xml=""
    msg "  ${C_BOLD}── Hálózat ──${C_RESET}"
    read -r -p "  Hálózat neve [IRCnet]: " network_name
    network_name="${network_name:-IRCnet}"
    read -r -p "  Szerver cím [irc.ircnet.com]: " server
    server="${server:-irc.ircnet.com}"
    read -r -p "  SSL? [i/N] " ssl
    if [[ "$ssl" =~ ^[iI]$ ]]; then
        read -r -p "  Port [6697]: " port
        port="${port:-6697}"
        read -r -p "  Server password (opcionális): " server_pass
        network_xml+="

${TAB}<Network ${network_name}>
${TAB}${TAB}LoadModule = simple_away
${TAB}${TAB}LoadModule = ssl
${TAB}${TAB}Server     = ${server} +${port} 
"
    else
        read -r -p "  Port [6667]: " port
        port="${port:-6667}"
        read -r -p "  Server password (opcionális): " server_pass
        network_xml+="

${TAB}<Network ${network_name}>
${TAB}${TAB}LoadModule = simple_away
${TAB}${TAB}Server     = ${server} ${port} 
"
    fi
    if [[ -n "$server_pass" ]]; then
        network_xml+="
${TAB}${TAB}ServerPass  = ${server_pass}"
    fi
    read -r -p "  Csatornák (vesszővel): " channels
    IFS=',' read -ra chan_arr <<< "$channels"
    for chan in "${chan_arr[@]}"; do
        chan="$(echo "$chan" | xargs)"
        [[ -n "$chan" ]] && network_xml+="
${TAB}${TAB}<Chan ${chan}>
${TAB}${TAB}</Chan>"
    done
    network_xml+="
${TAB}</Network>"

    # Álljunk le a ZNC-vel
    info "ZNC leállítása..."
    if ! systemctl stop znc.service 2>/dev/null; then
        warn "ZNC leállítása sikertelen — próbáljuk folytatni..."
    fi
    sleep 1

    # Biztonsági mentés
    local backup="${ZNC_CONF_DIR}/znc.conf.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$ZNC_CONF_FILE" "$backup"
    ok "Konfiguráció mentve: $backup"

    # Jelszó hash
    info "Jelszó hash generálása..."
    hash_password "$pass1"

    # User blokk összeállítása
    local user_block="
<User ${username}>
<Pass password>
${TAB}Method = ${method}
${TAB}Hash = ${hash}
${TAB}Salt = ${salt}
</Pass>
${TAB}Admin      = ${admin}
${TAB}Nick       = ${nick}
${TAB}AltNick    = ${altnick}
${TAB}Ident      = ${ident}
${TAB}RealName   = ${realname}"
    if [[ -n "$bindhost" ]]; then
        user_block+="
${TAB}BindHost    = ${bindhost}"
    fi
    user_block+="
${TAB}LoadModule = chansaver
${TAB}LoadModule = controlpanel${network_xml}
</User>"

    # Beszúrás az utolsó </User> után
    local last_user_line tmp_conf
    last_user_line="$(grep -n '</User>' "$ZNC_CONF_FILE" | tail -1 | cut -d: -f1)"
    tmp_conf="$(mktemp)"
    head -n "$last_user_line" "$ZNC_CONF_FILE" > "$tmp_conf"
    printf '%s\n' "$user_block" >> "$tmp_conf"
    tail -n +$((last_user_line + 1)) "$ZNC_CONF_FILE" >> "$tmp_conf"
    cp "$tmp_conf" "$ZNC_CONF_FILE"
    rm -f "$tmp_conf"
    chown "${ZNC_USER}:${ZNC_USER}" "$ZNC_CONF_FILE"

    ok "Felhasználó hozzáadva: ${username}"

    # ZNC újraindítás
    info "ZNC indítása..."
    if ! systemctl start znc.service; then
        error "ZNC nem tudott elindulni a módosítás után. Visszaállítás a mentésből..."
        cp "$backup" "$ZNC_CONF_FILE"
        systemctl start znc.service || true
        return 0
    fi
    sleep 1

    if systemctl is-active --quiet znc.service; then
        ok "ZNC sikeresen fut."
    else
        error "ZNC nem indult el. Visszaállítás..."
        cp "$backup" "$ZNC_CONF_FILE"
        systemctl start znc.service || true
        journalctl -u znc.service --no-pager -n 10 2>&1 || true
        return 0
    fi

    echo ""
    msg "  ${C_GREEN}Felhasználó létrehozva:${C_RESET}"
    echo -e "  ${C_BOLD}Név       ${C_RESET} ${username}"
    echo -e "  ${C_BOLD}Admin     ${C_RESET} ${admin}"
    echo -e "  ${C_BOLD}Nick      ${C_RESET} ${nick}"
    echo -e "  ${C_BOLD}Ident     ${C_RESET} ${ident}"
    echo ""
}

# Felhasználó törlése
do_user_del() {
    if [[ ! -f "$ZNC_CONF_FILE" ]]; then
        warn "ZNC nincs telepítve."
        return 0
    fi

    local users
    users="$(grep -Po '<User \K[^>]+' "$ZNC_CONF_FILE")"
    if [[ -z "$users" ]]; then
        msg "Nincsenek felhasználók."
        return 0
    fi

    header "Felhasználó törlése"
    do_user_list

    local input
    read -r -p "  Törlendő felhasználók (vesszővel vagy szóközzel): " input
    if [[ -z "${input// /}" ]]; then
        info "Törlés megszakítva."
        return 0
    fi

    # Bemenet feldolgozása: vessző vagy szóköz szerint
    local -a del_users
    IFS=', ' read -ra del_users <<< "$input"
    local -a valid_users=()
    for name in "${del_users[@]}"; do
        [[ -z "$name" ]] && continue
        if grep -q "<User ${name}>" "$ZNC_CONF_FILE"; then
            valid_users+=("$name")
        else
            warn "A(z) '${name}' felhasználó nem létezik — kihagyva."
        fi
    done

    if [[ ${#valid_users[@]} -eq 0 ]]; then
        error "Nincs érvényes felhasználónév."
        return 0
    fi

    # Megerősítés
    echo ""
    msg "  Törlésre kerül: ${C_BOLD}${valid_users[*]}${C_RESET}"
    local confirm
    read -r -p "  Írd be mégegyszer a neveket a törléshez: " confirm

    # Ellenőrzés: a megerősített lista egyezik-e
    local -a confirm_arr
    IFS=', ' read -ra confirm_arr <<< "$confirm"
    local -a clean_confirm=()
    for name in "${confirm_arr[@]}"; do
        [[ -z "$name" ]] && continue
        clean_confirm+=("$name")
    done
    if [[ "${#valid_users[@]}" -ne "${#clean_confirm[@]}" ]]; then
        info "Törlés megszakítva — a nevek száma nem egyezik."
        return 0
    fi
    for i in "${!valid_users[@]}"; do
        if [[ "${valid_users[$i]}" != "${clean_confirm[$i]}" ]]; then
            info "Törlés megszakítva — a nevek nem egyeznek."
            return 0
        fi
    done

    # ZNC leállítás
    info "ZNC leállítása..."
    systemctl stop znc.service 2>/dev/null || true
    sleep 1

    local backup="${ZNC_CONF_DIR}/znc.conf.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$ZNC_CONF_FILE" "$backup"
    ok "Konfiguráció mentve: $backup"

    # User-ek törlése egyesével
    for username in "${valid_users[@]}"; do
        sed -i "/<User ${username}>/,/<\/User>/d" "$ZNC_CONF_FILE"
        ok "Felhasználó törölve: ${username}"
    done

    # Üres sorok eltávolítása a fájl végéről
    sed -i ':a; /^\n*$/ { $d; N; ba; }' "$ZNC_CONF_FILE"

    # Moddata törlés felajánlva
    read -r -p "  Töröljük a moddata könyvtárakat is? [I/n] " yn
    if [[ ! "$yn" =~ ^[nN]$ ]]; then
        for username in "${valid_users[@]}"; do
            rm -rf "${ZNC_HOME}/.znc/users/${username}" 2>/dev/null || true
            ok "Moddata törölve: ${ZNC_HOME}/.znc/users/${username}"
        done
    fi

    # ZNC indítás
    info "ZNC indítása..."
    if ! systemctl start znc.service; then
        error "ZNC nem indult el. Visszaállítás..."
        cp "$backup" "$ZNC_CONF_FILE"
        systemctl start znc.service || true
        return 0
    fi
    sleep 1
    ok "ZNC sikeresen fut."
    echo ""
}

# Felhasználó almenü
user_menu() {
    local box_w=38

    while true; do
        echo ""
        printf "  ${C_BOLD}┌─ Felhasználók ─%s┐${C_RESET}\n" "$(printf '─%.0s' $(seq 1 $((box_w - 16))))"
        _box_line "  1) Listázás"                     "$box_w"
        _box_line "  2) Új felhasználó hozzáadása"    "$box_w"
        _box_line "  3) Felhasználó törlése"          "$box_w"
        _box_line "  0) Vissza"                       "$box_w"
        printf "  ${C_BOLD}└%s┘${C_RESET}\n" "$(printf '─%.0s' $(seq 1 $box_w))"
        echo ""
        read -r -p "  Válassz [0-3]: " choice
        case "$choice" in
            1) header "Felhasználók listája"; do_user_list ;;
            2) do_user_add ;;
            3) do_user_del ;;
            0) return 0 ;;
            *) warn "Érvénytelen választás." ;;
        esac
    done
}



# ══════════════════════════════════════════════════════════════════════════════
#  INTERACTIVE MENU
# ══════════════════════════════════════════════════════════════════════════════

# ── Doboz-építő segédfüggvények ──────────────────────────────────────────────

# Adott szélességre jobbról párnázott doboz-sor
_box_line() {
    local raw="$1" box_w="$2" plain pad
    plain="$(sed 's/\\e\[[0-9;]*m//g' <<< "$raw")"
    pad=$(( box_w - ${#plain} ))
    (( pad < 0 )) && pad=0
    printf "  ${C_BOLD}│${C_RESET}%b%*s${C_BOLD}│${C_RESET}\n" "$raw" "$pad" ""
}

# Középre igazított doboz-sor
_center_line() {
    local raw="$1" box_w="$2" plain lpad rpad
    plain="$(sed 's/\\e\[[0-9;]*m//g' <<< "$raw")"
    lpad=$(( (box_w - ${#plain}) / 2 ))
    rpad=$(( box_w - ${#plain} - lpad ))
    (( lpad < 0 )) && lpad=0
    (( rpad < 0 )) && rpad=0
    printf "  ${C_BOLD}│${C_RESET}%*s%b%*s${C_BOLD}│${C_RESET}\n" "$lpad" "" "$raw" "$rpad" ""
}

# Vízszintes elválasztóvonal (tele ─ karaktersor)
_hrule() {
    local w="$1"
    printf "  ${C_BOLD}├%s┤${C_RESET}\n" "$(printf '─%.0s' $(seq 1 "$w"))"
}

show_menu() {
    local installed latest box_w
    installed="$(get_installed_version)"
    latest="$(get_latest_version 2>/dev/null || echo '?')"
    box_w=44

    local top_hr bot_hr
    top_hr="$(printf '─%.0s' $(seq 1 $box_w))"
    bot_hr="$(printf '─%.0s' $(seq 1 $box_w))"

    echo ""
    printf "  ${C_BOLD}┌%s┐${C_RESET}\n" "$top_hr"
    _center_line "${C_CYAN}${C_BOLD}ZNC Toolbox - By Doky${C_RESET}" "$box_w"
    _hrule "$box_w"

    if [[ -n "$installed" ]]; then
        _center_line "Telepítve: ${C_GREEN}${installed}${C_RESET}   Friss: ${C_GREEN}${latest}${C_RESET}" "$box_w"
        if [[ "$latest" != "?" ]] && [[ "$installed" != "$latest" ]]; then
            _center_line "${C_YELLOW}◈  Frissítés elérhető!${C_RESET}" "$box_w"
        fi
    else
        _center_line "${C_YELLOW}ZNC nincs telepítve${C_RESET}" "$box_w"
    fi

    _hrule "$box_w"
    _box_line "  ${C_BOLD}1${C_RESET}) Telepítés"               "$box_w"
    _box_line "  ${C_BOLD}2${C_RESET}) Frissítés"               "$box_w"
    _box_line "  ${C_BOLD}3${C_RESET}) Eltávolítás"             "$box_w"
    _box_line "  ${C_BOLD}4${C_RESET}) Állapot"                 "$box_w"
    _box_line "  ${C_BOLD}5${C_RESET}) Felhasználók"              "$box_w"
    _box_line "  ${C_BOLD}0${C_RESET}) Kilépés"                 "$box_w"
    printf "  ${C_BOLD}└%s┘${C_RESET}\n" "$bot_hr"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  HASZNÁLATI ÚTMUTATÓ
# ══════════════════════════════════════════════════════════════════════════════
usage() {
    echo ""
    echo "  ZNC Toolbox — Telepítő, Frissítő és Eltávolító"
    echo ""
    echo "  Használat:"
    echo "    $0                Interaktív menü"
    echo "    $0 install        ZNC telepítése"
    echo "    $0 update         ZNC frissítése (konfig megtartva)"
    echo "    $0 uninstall      ZNC és minden adat törlése"
    echo "    $0 status         Telepítés állapota"
    echo "    $0 user list      Felhasználók listázása"
    echo "    $0 user add       Új felhasználó hozzáadása"
    echo "    $0 user del       Felhasználó törlése"
    echo "    $0 help           Ez a súgó"
    echo ""
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  INTERACTIVE — menü vezérelt mód
# ══════════════════════════════════════════════════════════════════════════════
interactive() {
    while true; do
        show_menu
        read -r -p "  Válassz [0-5]: " choice
        case "$choice" in
            1) do_install ;;
            2) do_update ;;
            3) do_uninstall ;;
            4) show_status ;;
            5) user_menu ;;
            0) info "Kilépés."; exit 0 ;;
            *) warn "Érvénytelen választás." ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  BELÉPÉSI PONT
# ══════════════════════════════════════════════════════════════════════════════
require_root "$@"

case "${1:-}" in
    install)   do_install ;;
    update)    do_update ;;
    uninstall) do_uninstall ;;
    status)    show_status ;;
    user)
        case "${2:-list}" in
            list) do_user_list ;;
            add)  do_user_add ;;
            del)  do_user_del ;;
            *)    warn "Használd: $0 user list|add|del";;
        esac
        ;;
    help|-h|--help) usage ;;
    "")        interactive ;;
    *)         warn "Ismeretlen parancs: $1"; usage ;;
esac
