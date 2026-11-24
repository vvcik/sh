#!/usr/bin/env bash
# mieru / mita 一键安装脚本
# 基于官方文档 v3.40.0
# https://github.com/enfein/mieru/blob/main/docs/server-install.md
#
# 用法：
#   curl -fSsLO https://raw.githubusercontent.com/vvcik/sh/main/mieru-install.sh && sudo bash mieru-install.sh
#   sudo bash mieru-install.sh install   # 跳过菜单，直接安装
#
# 菜单式管理：安装 / 卸载 / 启动 / 停止 / 重启 / 修改配置 / 查看配置 / 查看状态 / 开启 BBR
set -euo pipefail

VERSION="3.40.0"
REPO="enfein/mieru"
RELEASE_BASE="https://github.com/${REPO}/releases/download/v${VERSION}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
CONF_DIR="/opt/mieru"
CONF_FILE="${CONF_DIR}/server_config.json"

# ---------- 输出 ----------
info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

# ---------- 基础检查 ----------
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "请用 root 运行：sudo bash install.sh"
        exit 1
    fi
}

need_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "缺少依赖：$cmd，请先安装（Debian/Ubuntu: apt-get install $cmd）"
        exit 1
    fi
}

# ---------- 系统识别 ----------
detect_os() {
    # 输出：deb | rpm | unknown
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu|kali|raspbian) echo "deb" ;;
            rhel|centos|rocky|almalinux|fedora|ol) echo "rpm" ;;
            *)
                case "${ID_LIKE:-}" in
                    *debian*) echo "deb" ;;
                    *rhel*|*fedora*) echo "rpm" ;;
                    *) echo "unknown" ;;
                esac
                ;;
        esac
    else
        echo "unknown"
    fi
}

detect_arch() {
    # 输出：amd64 | arm64 | unknown
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "unknown" ;;
    esac
}

mita_installed() { command -v mita >/dev/null 2>&1; }

current_status() {
    if ! mita_installed; then echo "未安装"; return; fi
    local s
    s="$(mita status 2>/dev/null || true)"
    if [[ "$s" == *RUNNING* ]]; then echo "运行中"
    elif [[ "$s" == *IDLE* ]]; then echo "已安装，未启动"
    else echo "未知（执行 mita status 查看）"; fi
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ---------- NTP：时间必须同步 ----------
# mita 与客户端用 用户名+密码+系统时间 计算密钥，时间不同步会无法解密
ensure_ntp() {
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl show 2>/dev/null | grep -q "NTPSynchronized=yes"; then
            info "NTP 已同步"
            return 0
        fi
        timedatectl set-ntp true 2>/dev/null || true
        sleep 2
        if timedatectl show 2>/dev/null | grep -q "NTPSynchronized=yes"; then
            info "NTP 已同步"
        else
            warn "NTP 未确认同步，请检查系统时间是否准确（date），否则客户端连不上"
        fi
    else
        warn "未找到 timedatectl，请确认系统时间准确（date），否则客户端连不上"
    fi
}

# ---------- 生成配置文件 ----------
gen_config() {
    local port protocol user pass dns_choice dns mtu hosts_input hosts_json
    local esc_user esc_pass esc_dns

    read -rp "监听端口 [默认 2012，范围 1025-65535]: " port
    port="${port:-2012}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1025 || port > 65535 )); then
        error "端口须为 1025-65535 之间的数字"
        return 1
    fi

    read -rp "协议 TCP/UDP [默认 TCP]: " protocol
    protocol="${protocol:-TCP}"
    protocol="${protocol^^}"
    if [[ "$protocol" != "TCP" && "$protocol" != "UDP" ]]; then
        error "协议只能是 TCP 或 UDP"
        return 1
    fi

    read -rp "用户名 [默认 mieru]: " user
    user="${user:-mieru}"

    read -rsp "密码（留空自动生成 16 位随机密码）: " pass
    echo
    if [[ -z "$pass" ]]; then
        pass="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)"
        warn "已自动生成密码：$pass（只显示一次，请记好）"
    fi

    echo "DNS 策略（服务端解析域名时用哪个 IP）："
    echo "  1 USE_FIRST_IP（默认：用 DNS 返回的第一个 IP）"
    echo "  2 PREFER_IPv4（优先 IPv4，失败再用 IPv6，官方推荐）"
    echo "  3 PREFER_IPv6（优先 IPv6，失败再用 IPv4）"
    echo "  4 ONLY_IPv4（只用 IPv4，没有就失败）"
    echo "  5 ONLY_IPv6（只用 IPv6，没有就失败）"
    read -rp "选择 [默认 2]: " dns_choice
    dns_choice="${dns_choice:-2}"
    case "$dns_choice" in
        1) dns="USE_FIRST_IP" ;;
        2) dns="PREFER_IPv4" ;;
        3) dns="PREFER_IPv6" ;;
        4) dns="ONLY_IPv4" ;;
        5) dns="ONLY_IPv6" ;;
        *) dns="PREFER_IPv4" ;;
    esac

    read -rp "MTU [默认 1400，最小 1280]: " mtu
    mtu="${mtu:-1400}"
    if ! [[ "$mtu" =~ ^[0-9]+$ ]] || (( mtu < 1280 )); then
        error "MTU 须为不小于 1280 的数字"
        return 1
    fi

    read -rp "静态 hosts 映射（可选，格式 域名=IP，多个用逗号分隔，留空跳过）: " hosts_input

    esc_user="$(json_escape "$user")"
    esc_pass="$(json_escape "$pass")"
    esc_dns="$(json_escape "$dns")"

    hosts_json=""
    if [[ -n "$hosts_input" ]]; then
        local first=1 item k v
        hosts_json=", \"hosts\": {"
        IFS=',' read -ra items <<< "$hosts_input"
        for item in "${items[@]}"; do
            k="${item%%=*}"; v="${item#*=}"
            k="$(echo "$k" | xargs)"; v="$(echo "$v" | xargs)"
            [[ -z "$k" || -z "$v" || "$k" == "$item" ]] && continue
            if [[ "$first" -eq 1 ]]; then first=0; else hosts_json+=", "; fi
            hosts_json+="\"$(json_escape "$k")\": \"$(json_escape "$v")\""
        done
        hosts_json+="}"
    fi

    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" <<EOF
{
    "portBindings": [
        {
            "port": ${port},
            "protocol": "${protocol}"
        }
    ],
    "users": [
        {
            "name": "${esc_user}",
            "password": "${esc_pass}"
        }
    ],
    "loggingLevel": "INFO",
    "mtu": ${mtu},
    "dns": {
        "dualStack": "${esc_dns}"${hosts_json}
    }
}
EOF
    info "配置已写入 $CONF_FILE"
    echo "端口：${port}/${protocol}，用户：${user}，DNS 策略：${dns}，MTU：${mtu}"
}

show_summary() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -z "$ip" ]] && ip="<服务器 IP>"
    echo
    echo "========== mita 已就绪 =========="
    echo "服务器：${ip}"
    echo "配置查看：mita describe config"
    echo "状态查看：mita status / systemctl status mita"
    echo "注意：请在防火墙 / 云厂商安全组放行监听端口，否则客户端连不上"
    echo "================================"
}

# ---------- 安装 ----------
do_install() {
    require_root
    need_cmd curl
    need_cmd openssl

    local os arch pkg url tmp
    os="$(detect_os)"
    arch="$(detect_arch)"
    [[ "$os" == "unknown" ]] && { error "无法识别系统，仅支持 Debian/Ubuntu 与 RHEL/CentOS/Rocky/Fedora 系列"; return 1; }
    [[ "$arch" == "unknown" ]] && { error "不支持的架构：$(uname -m)"; return 1; }

    if [[ "$os" == "deb" ]]; then
        pkg="mita_${VERSION}_${arch}.deb"
    else
        if [[ "$arch" == "amd64" ]]; then pkg="mita-${VERSION}-1.x86_64.rpm";
        else pkg="mita-${VERSION}-1.aarch64.rpm"; fi
    fi
    url="${RELEASE_BASE}/${pkg}"

    info "下载 ${pkg} ..."
    tmp="$(mktemp -d)"
    if ! curl -fSsL -o "${tmp}/${pkg}" "$url"; then
        error "下载失败：$url"
        rm -rf "$tmp"
        return 1
    fi

    info "安装 mita ${VERSION} ..."
    if [[ "$os" == "deb" ]]; then
        dpkg -i "${tmp}/${pkg}" || apt-get install -f -y
    else
        rpm -Uvh --force "${tmp}/${pkg}"
    fi
    rm -rf "$tmp"

    if ! mita_installed; then
        error "mita 安装失败，请检查上面的报错"
        return 1
    fi

    # 把当前登录用户加入 mita 组（需重新登录才生效，不影响本次运行）
    local login_user="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
    usermod -a -G mita "$login_user" 2>/dev/null || true

    ensure_ntp
    gen_config || return 1

    info "写入配置 ..."
    mita apply config "$CONF_FILE"
    mita stop 2>/dev/null || true
    mita start
    sleep 1
    mita status

    if mita status 2>/dev/null | grep -q "RUNNING"; then
        info "安装完成，mita 正在运行"
    else
        warn "mita 未进入 RUNNING 状态，执行 mita describe config / systemctl status mita 检查"
    fi
    show_summary
}

# ---------- 卸载 ----------
do_uninstall() {
    require_root
    local c
    read -rp "确认卸载 mita 服务端与配置文件？[y/N]: " c
    [[ "${c,,}" != "y" ]] && { info "已取消"; return 0; }
    mita stop 2>/dev/null || true
    if [[ "$(detect_os)" == "deb" ]]; then
        dpkg -r mita 2>/dev/null || apt-get remove -y mita 2>/dev/null || true
    else
        rpm -e mita 2>/dev/null || true
    fi
    rm -rf "$CONF_DIR"
    info "已卸载"
}

# ---------- 服务控制 ----------
do_start()   { require_root; mita start;   mita status; }
do_stop()    { require_root; mita stop;    mita status; }
do_restart() { require_root; mita stop 2>/dev/null || true; mita start; mita status; }

do_config() {
    require_root
    mita_installed || { error "mita 未安装，请先选 1 安装"; return 1; }
    gen_config || return 1
    info "写入配置 ..."
    mita apply config "$CONF_FILE"
    # 端口 / DNS / MTU 等改动需要重启才生效（只改用户或日志级别可用 mita reload）
    mita stop 2>/dev/null || true
    mita start
    sleep 1
    mita status
}

do_show_config() {
    mita_installed || { error "mita 未安装，请先选 1 安装"; return 1; }
    mita describe config
}

do_status() {
    mita_installed || { error "mita 未安装，请先选 1 安装"; return 1; }
    systemctl status mita --no-pager 2>/dev/null || true
    echo
    mita status
}

# ---------- BBR ----------
do_bbr() {
    require_root
    need_cmd python3
    local tmp
    tmp="$(mktemp -d)"
    info "下载 BBR 开启脚本 ..."
    if ! curl -fSsL -o "${tmp}/enable_tcp_bbr.py" "${RAW_BASE}/tools/enable_tcp_bbr.py"; then
        error "下载失败"
        rm -rf "$tmp"
        return 1
    fi
    chmod +x "${tmp}/enable_tcp_bbr.py"
    python3 "${tmp}/enable_tcp_bbr.py"
    rm -rf "$tmp"
    info "BBR 脚本执行完毕"
}

# ---------- 菜单 ----------
show_menu() {
    echo
    echo "===== mieru / mita 一键安装脚本 v${VERSION} ====="
    echo "状态：$(current_status)"
    echo "----------------------------------------"
    echo "1 安装 mita"
    echo "2 卸载 mita"
    echo "3 启动"
    echo "4 停止"
    echo "5 重启"
    echo "6 修改配置"
    echo "7 查看配置"
    echo "8 查看状态"
    echo "9 开启 BBR"
    echo "0 退出"
    echo "========================================"
}

main() {
    # 直接安装：sudo bash install.sh install
    if [[ "${1:-}" == "install" ]]; then
        do_install
        exit 0
    fi
    while true; do
        show_menu
        local choice
        read -rp "请选择 [0-9]: " choice
        case "$choice" in
            1) do_install ;;
            2) do_uninstall ;;
            3) do_start ;;
            4) do_stop ;;
            5) do_restart ;;
            6) do_config ;;
            7) do_show_config ;;
            8) do_status ;;
            9) do_bbr ;;
            0|00) echo "退出"; exit 0 ;;
            *) echo "无效选择" ;;
        esac
        echo
        read -rp "按回车返回菜单..." _
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
