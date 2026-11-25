#!/usr/bin/env bash
set -Eeuo pipefail

readonly WEBDAV_IMAGE="sigoden/dufs"
readonly CADDY_IMAGE="caddy:2"
readonly CONTAINER_NAME="webdav"
readonly CADDY_CONTAINER_NAME="webdav-caddy"
readonly CONFIG_DIR="/etc/webdav"
readonly STATE_FILE="${CONFIG_DIR}/webdav.env"
readonly CADDY_FILE="${CONFIG_DIR}/Caddyfile"
readonly CADDY_DATA_DIR="${CONFIG_DIR}/caddy-data"
readonly INFO_FILE="${CONFIG_DIR}/client-info.txt"
readonly CADDY_SNIPPET_FILE="${CONFIG_DIR}/caddy-snippet.txt"
readonly CADDY_BEGIN_MARK="# BEGIN onekey_webdav"
readonly CADDY_END_MARK="# END onekey_webdav"
readonly DEFAULT_PORT="5000"
readonly DEFAULT_USER="admin"
readonly DEFAULT_PASS="admin"
readonly DEFAULT_DIR="/data/webdav"
readonly DEFAULT_HTTPS_PORT="443"
readonly ACME_HTTP_PORT="80"
readonly RANDOM_PORT_MIN=20000
readonly RANDOM_PORT_MAX=60000
readonly RANDOM_PORT_TRIES=50
readonly LOG_MAX_SIZE="10m"
readonly LOG_MAX_FILE="3"
readonly HEALTH_WAIT_SECONDS=10

readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly RED=$'\033[0;31m'
readonly NC=$'\033[0m'

port=""
user=""
pass=""
data_dir=""
tls_choice=""
domain=""
https_port=""
default_port=$DEFAULT_PORT
default_user=$DEFAULT_USER
default_pass=$DEFAULT_PASS
default_dir=$DEFAULT_DIR
default_tls="n"
default_domain=""
default_https_port=$DEFAULT_HTTPS_PORT
installed_port=""
installed_https_port=""
server_ip=""
tmp_get_docker=""
tmp_state=""
tmp_caddyfile=""
caddy_mode="none"
external_kind=""
external_target=""
external_config=""
external_dest=""
external_bin=""
upstream_addr="127.0.0.1"
bind_addr="0.0.0.0"
old_caddy_mode=""
old_caddy_kind=""
old_caddy_target=""
old_caddy_config=""
old_caddy_dest=""
old_caddy_bin=""

step() { printf '%s\n' "${GREEN}$*${NC}"; }
info() { printf '%s\n' "${YELLOW}$*${NC}"; }
fail() {
    printf '%s\n' "${RED}错误: $*${NC}" >&2
    exit 1
}

on_error() {
    printf '%s\n' "${RED}错误: 第 $1 行命令执行失败 (退出码 $2): $3${NC}" >&2
}

cleanup() {
    if [ -n "$tmp_get_docker" ]; then rm -f "$tmp_get_docker"; fi
    if [ -n "$tmp_state" ]; then rm -f "$tmp_state"; fi
    if [ -n "$tmp_caddyfile" ]; then rm -f "$tmp_caddyfile"; fi
}

trap '[ "$BASH_SUBSHELL" -eq 0 ] && on_error "$LINENO" "$?" "$BASH_COMMAND"' ERR
trap cleanup EXIT

valid_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_account() {
    [[ $1 =~ ^[A-Za-z0-9_.-]{1,64}$ ]]
}

valid_domain() {
    local re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]$'
    [ "${#1}" -le 253 ] && [[ $1 =~ $re ]]
}

valid_dir() {
    [[ $1 == /* ]] && [ "${#1}" -ge 2 ] && [[ $1 != *[[:space:]:]* ]]
}

parse_yes_no() {
    case ${1,,} in
        y | yes | 1 | true | on) printf 'y' ;;
        n | no | 0 | false | off) printf 'n' ;;
        *) return 1 ;;
    esac
}

has_tty() {
    (exec </dev/tty) 2>/dev/null
}

state_value() {
    sed -nE "s/^$1=//p" "$STATE_FILE" | head -n 1
}

image_id() {
    docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true
}

banner() {
    step "========================================"
    step "  WebDAV 一键安装脚本 (dufs)"
    step "========================================"
    echo
}

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "请使用 root 运行 (当前 uid: $(id -u))，可先执行 sudo -i"
}

require_curl() {
    command -v curl >/dev/null 2>&1 || fail "缺少 curl，请先安装 (apt-get install -y curl 或 yum install -y curl)"
}

ensure_docker() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        info "Docker 已安装并运行，跳过安装"
        return
    fi
    step "正在安装 Docker..."
    tmp_get_docker=$(mktemp)
    if curl -fsSL --max-time 60 https://get.docker.com -o "$tmp_get_docker" && sh "$tmp_get_docker"; then
        info "get.docker.com 安装完成"
    else
        info "get.docker.com 安装失败，尝试 Docker 官方 centos 源 (Rocky / AlmaLinux / Oracle Linux 等)"
        command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || fail "Docker 安装失败且无 yum/dnf 可用，请手动安装 Docker 后重试"
        curl -fsSL --max-time 60 https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo || fail "下载 Docker centos 源失败"
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y docker-ce docker-ce-cli containerd.io || fail "dnf 安装 Docker 失败"
        else
            yum install -y docker-ce docker-ce-cli containerd.io || fail "yum 安装 Docker 失败"
        fi
    fi
    rm -f "$tmp_get_docker"
    tmp_get_docker=""
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi
    docker info >/dev/null 2>&1 || fail "Docker 已安装但无法运行 (docker info 失败)，请检查 systemctl status docker"
    info "Docker 安装完成"
}

load_existing() {
    if [ ! -f "$STATE_FILE" ]; then
        info "未发现已有配置 ${STATE_FILE}，按全新安装处理"
        return
    fi
    local old_port old_user old_pass old_dir old_tls old_domain old_https_port
    old_port=$(state_value PORT)
    old_user=$(state_value USER)
    old_pass=$(state_value PASS)
    old_dir=$(state_value DIR)
    old_tls=$(state_value TLS)
    old_domain=$(state_value DOMAIN)
    old_https_port=$(state_value HTTPS_PORT)
    info "发现已有配置 ${STATE_FILE}，按重装处理，直接回车沿用已安装的值"
    if valid_port "$old_port"; then
        default_port=$((10#$old_port))
        installed_port=$default_port
        info "沿用已安装的端口作为默认值: ${default_port}"
    else
        info "已有配置中的端口不合法 (值: ${old_port:-空})，默认值仍为 ${DEFAULT_PORT}"
    fi
    if valid_account "$old_user"; then
        default_user=$old_user
    else
        info "已有配置中的用户名不合法 (值: ${old_user:-空})，默认值仍为 ${DEFAULT_USER}"
    fi
    if valid_account "$old_pass"; then
        default_pass=$old_pass
    else
        info "已有配置中的密码不合法 (值: ${old_pass:-空})，默认值仍为 ${DEFAULT_PASS}"
    fi
    if valid_dir "$old_dir"; then
        default_dir=$old_dir
        info "沿用已安装的数据目录作为默认值: ${default_dir}"
    else
        info "已有配置中的数据目录不合法 (值: ${old_dir:-空})，默认值仍为 ${DEFAULT_DIR}"
    fi
    if old_tls=$(parse_yes_no "${old_tls:-n}"); then
        default_tls=$old_tls
        info "沿用已安装的 HTTPS 状态作为默认值: ${default_tls}"
    else
        info "已有配置中的 HTTPS 状态不合法，默认值仍为不开启"
    fi
    if valid_domain "$old_domain"; then
        default_domain=$old_domain
        info "沿用已安装的域名作为默认值: ${default_domain}"
    fi
    if valid_port "$old_https_port"; then
        default_https_port=$((10#$old_https_port))
        installed_https_port=$default_https_port
    else
        info "已有配置中的 HTTPS 端口不合法 (值: ${old_https_port:-空})，默认值仍为 ${DEFAULT_HTTPS_PORT}"
    fi
    old_caddy_mode=$(state_value CADDY_MODE)
    old_caddy_kind=$(state_value CADDY_KIND)
    old_caddy_target=$(state_value CADDY_TARGET)
    old_caddy_config=$(state_value CADDY_CONFIG)
    old_caddy_dest=$(state_value CADDY_DEST)
    old_caddy_bin=$(state_value CADDY_BIN)
}

choose_port() {
    local owner
    if [ -n "${WEBDAV_PORT:-}" ]; then
        valid_port "$WEBDAV_PORT" || fail "环境变量 WEBDAV_PORT=${WEBDAV_PORT} 不是合法端口 (1-65535)"
        port=$((10#$WEBDAV_PORT))
        ensure_port_usable "$port" "$CONTAINER_NAME" WEBDAV_PORT
        info "监听端口: ${port} (来自环境变量 WEBDAV_PORT)"
        return
    fi
    if ! has_tty; then
        port=$default_port
        ensure_port_usable "$port" "$CONTAINER_NAME" WEBDAV_PORT
        info "监听端口: ${port} (无交互终端且未设置 WEBDAV_PORT，取默认值)"
        return
    fi
    while true; do
        read -r -p "监听端口 (默认 ${default_port}): " port </dev/tty || port=""
        port=${port:-$default_port}
        if ! valid_port "$port"; then
            info "${port} 不是合法端口 (1-65535)，请重新输入"
            continue
        fi
        port=$((10#$port))
        if owner=$(port_occupied "$port" "$CONTAINER_NAME"); then
            info "端口 ${port} 已被占用 (${owner})，请更换端口重新输入"
            continue
        fi
        break
    done
    info "监听端口: ${port}"
}

choose_account() {
    if [ -n "${WEBDAV_USER:-}" ]; then
        valid_account "$WEBDAV_USER" || fail "环境变量 WEBDAV_USER=${WEBDAV_USER} 不合法 (只允许字母/数字/_.-，长度 1-64)"
        user=$WEBDAV_USER
        info "用户名: ${user} (来自环境变量 WEBDAV_USER)"
    elif ! has_tty; then
        user=$default_user
        info "用户名: ${user} (无交互终端且未设置 WEBDAV_USER，取默认值)"
    else
        while true; do
            read -r -p "用户名 (默认 ${default_user}): " user </dev/tty || user=""
            user=${user:-$default_user}
            valid_account "$user" && break
            info "${user} 不合法 (只允许字母/数字/_.-，长度 1-64)，请重新输入"
        done
        info "用户名: ${user}"
    fi
    if [ -n "${WEBDAV_PASS:-}" ]; then
        valid_account "$WEBDAV_PASS" || fail "环境变量 WEBDAV_PASS 不合法 (只允许字母/数字/_.-，长度 1-64)"
        pass=$WEBDAV_PASS
        info "密码: 已设置 (来自环境变量 WEBDAV_PASS)"
    elif ! has_tty; then
        pass=$default_pass
        info "密码: 取默认值 (无交互终端且未设置 WEBDAV_PASS)"
    else
        while true; do
            read -r -p "密码 (默认 ${default_pass}): " pass </dev/tty || pass=""
            pass=${pass:-$default_pass}
            valid_account "$pass" && break
            info "密码不合法 (只允许字母/数字/_.-，长度 1-64)，请重新输入"
        done
        info "密码: 已设置"
    fi
    if [ "$user" = "$DEFAULT_USER" ] && [ "$pass" = "$DEFAULT_PASS" ]; then
        info "注意: 正在使用默认账号密码 admin/admin，公网环境建议用 WEBDAV_USER / WEBDAV_PASS 指定强密码"
    fi
}

choose_dir() {
    if [ -n "${WEBDAV_DIR:-}" ]; then
        valid_dir "$WEBDAV_DIR" || fail "环境变量 WEBDAV_DIR=${WEBDAV_DIR} 不合法 (需为绝对路径，不含空格和冒号，且不能是 /)"
        data_dir=$WEBDAV_DIR
        info "数据目录: ${data_dir} (来自环境变量 WEBDAV_DIR)"
        return
    fi
    if ! has_tty; then
        data_dir=$default_dir
        info "数据目录: ${data_dir} (无交互终端且未设置 WEBDAV_DIR，取默认值)"
        return
    fi
    while true; do
        read -r -p "数据目录 (默认 ${default_dir}): " data_dir </dev/tty || data_dir=""
        data_dir=${data_dir:-$default_dir}
        valid_dir "$data_dir" && break
        info "${data_dir} 不合法 (需为绝对路径，不含空格和冒号，且不能是 /)，请重新输入"
    done
    info "数据目录: ${data_dir}"
}

choose_tls() {
    if [ -n "${WEBDAV_TLS:-}" ]; then
        tls_choice=$(parse_yes_no "$WEBDAV_TLS") || fail "环境变量 WEBDAV_TLS=${WEBDAV_TLS} 不合法 (y / n)"
        info "是否开启 HTTPS (Caddy 自动证书): ${tls_choice} (来自环境变量 WEBDAV_TLS)"
        return
    fi
    if ! has_tty; then
        tls_choice=$default_tls
        info "是否开启 HTTPS (Caddy 自动证书): ${tls_choice} (无交互终端且未设置 WEBDAV_TLS，取默认值)"
        return
    fi
    local input
    while true; do
        read -r -p "是否开启 HTTPS (Caddy 自动申请/续期证书, 需域名, y/n, 默认 ${default_tls}): " input </dev/tty || input=""
        input=${input:-$default_tls}
        if tls_choice=$(parse_yes_no "$input"); then
            break
        fi
        info "${input} 不合法 (y / n)，请重新输入"
    done
    info "是否开启 HTTPS (Caddy 自动证书): ${tls_choice}"
}

choose_domain() {
    if [ -n "${WEBDAV_DOMAIN:-}" ]; then
        valid_domain "$WEBDAV_DOMAIN" || fail "环境变量 WEBDAV_DOMAIN=${WEBDAV_DOMAIN} 不是合法域名 (示例: dav.example.com)"
        domain=$WEBDAV_DOMAIN
        info "HTTPS 域名: ${domain} (来自环境变量 WEBDAV_DOMAIN)"
        return
    fi
    if ! has_tty; then
        if [ -n "$default_domain" ]; then
            domain=$default_domain
            info "HTTPS 域名: ${domain} (无交互终端且未设置 WEBDAV_DOMAIN，沿用已安装值)"
            return
        fi
        fail "开启 HTTPS 需要域名，请设置 WEBDAV_DOMAIN (示例: dav.example.com)，且域名需解析到本机"
    fi
    local prompt="HTTPS 域名 (需已解析到本机, 示例 dav.example.com"
    if [ -n "$default_domain" ]; then
        prompt="HTTPS 域名 (默认 ${default_domain}"
    fi
    while true; do
        read -r -p "${prompt}): " domain </dev/tty || domain=""
        domain=${domain:-$default_domain}
        valid_domain "$domain" && break
        info "${domain:-空} 不是合法域名 (示例: dav.example.com)，请重新输入"
    done
    info "HTTPS 域名: ${domain}"
}

pick_random_port() {
    local candidate i
    for ((i = 1; i <= RANDOM_PORT_TRIES; i++)); do
        candidate=$(awk -v min="$RANDOM_PORT_MIN" -v max="$RANDOM_PORT_MAX" 'BEGIN{srand(); print int(min + rand() * (max - min + 1))}')
        if ! command -v ss >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return
        fi
        if [ -z "$(ss -Htln "sport = :${candidate}" 2>/dev/null || true)" ]; then
            printf '%s' "$candidate"
            return
        fi
    done
    fail "随机挑选 ${RANDOM_PORT_TRIES} 次仍未找到空闲端口 (${RANDOM_PORT_MIN}-${RANDOM_PORT_MAX})，请手动指定"
}

choose_https_port() {
    local owner
    if [ -n "${WEBDAV_HTTPS_PORT:-}" ]; then
        valid_port "$WEBDAV_HTTPS_PORT" || fail "环境变量 WEBDAV_HTTPS_PORT=${WEBDAV_HTTPS_PORT} 不是合法端口 (1-65535)"
        https_port=$((10#$WEBDAV_HTTPS_PORT))
        if [ "$caddy_mode" = own ]; then
            ensure_port_usable "$https_port" "$CADDY_CONTAINER_NAME" WEBDAV_HTTPS_PORT
        fi
        info "HTTPS 对外端口: ${https_port} (来自环境变量 WEBDAV_HTTPS_PORT)"
    elif ! has_tty; then
        https_port=$default_https_port
        if [ "$caddy_mode" = own ]; then
            ensure_port_usable "$https_port" "$CADDY_CONTAINER_NAME" WEBDAV_HTTPS_PORT
        fi
        info "HTTPS 对外端口: ${https_port} (无交互终端且未设置 WEBDAV_HTTPS_PORT，取默认值)"
    else
        local input
        while true; do
            read -r -p "HTTPS 对外端口 (默认 ${default_https_port}, 输入 r 随机挑选一个空闲端口): " input </dev/tty || input=""
            input=${input:-$default_https_port}
            if [ "$input" = r ] || [ "$input" = random ]; then
                https_port=$(pick_random_port)
                info "已随机挑选空闲端口: ${https_port}"
                break
            fi
            if ! valid_port "$input"; then
                info "${input} 不是合法端口 (1-65535, 或 r 随机)，请重新输入"
                continue
            fi
            https_port=$((10#$input))
            if [ "$caddy_mode" = own ] && owner=$(port_occupied "$https_port" "$CADDY_CONTAINER_NAME"); then
                info "端口 ${https_port} 已被占用 (${owner})，请更换端口重新输入 (或输入 r 随机)"
                continue
            fi
            break
        done
        info "HTTPS 对外端口: ${https_port}"
    fi
    if [ "$https_port" = "$port" ]; then
        fail "HTTPS 对外端口 ${https_port} 与 dufs 监听端口 ${port} 冲突，请换一个"
    fi
    if [ "$https_port" = "$ACME_HTTP_PORT" ]; then
        fail "HTTPS 对外端口不能是 ${ACME_HTTP_PORT} (该端口用于证书申请与自动跳转)"
    fi
    if [ "$caddy_mode" != own ]; then
        info "端口 ${https_port} 由已有 Caddy 负责监听, 跳过占用检查 (请确保它对外暴露该端口)"
    fi
}

port_occupied() {
    command -v ss >/dev/null 2>&1 || return 1
    local listeners owners own_pid
    listeners=$(ss -Htlnp "sport = :${1}" 2>/dev/null || true)
    [ -n "$listeners" ] || return 1
    owners=$(sed -nE 's/.*users:\(\("([^"]+)",pid=([0-9]+).*/\2 \1/p' <<<"$listeners" | sort -u)
    own_pid=$(docker inspect -f '{{.State.Pid}}' "$2" 2>/dev/null || echo 0)
    if [ -n "$owners" ] && [ "$own_pid" != 0 ] && ! grep -qv "^${own_pid} " <<<"$owners"; then
        return 1
    fi
    printf '%s' "$(tr '\n' ';' <<<"${owners:-$listeners}")"
    return 0
}

ensure_port_usable() {
    local owner
    if owner=$(port_occupied "$1" "$2"); then
        fail "端口 $1 已被占用 (${owner})，请更换 ($3) 或先停掉占用进程"
    fi
}

check_port_free() {
    if ! command -v ss >/dev/null 2>&1; then
        info "未找到 ss 命令，跳过端口 $1 占用检查"
        return
    fi
    local owner
    if owner=$(port_occupied "$1" "$2"); then
        fail "端口 $1 已被占用 (${owner})，需空闲或仅被 $2 占用；请换端口或先停掉占用进程"
    fi
    info "端口 $1 空闲或仅由本脚本的 $2 容器占用 (重装时会先移除它)"
}

remove_old_container() {
    if docker container inspect "$1" >/dev/null 2>&1; then
        docker rm -f -v "$1" >/dev/null
        info "已移除旧容器 $1"
    fi
}

run_dufs() {
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart always \
        --net host \
        --log-driver json-file \
        --log-opt max-size="$LOG_MAX_SIZE" \
        --log-opt max-file="$LOG_MAX_FILE" \
        -v "${data_dir}:/data" \
        "$WEBDAV_IMAGE" /data -b "$bind_addr" -p "$port" -A -a "${user}:${pass}@/:rw" >/dev/null || fail "启动容器 ${CONTAINER_NAME} 失败"
    info "容器日志按 json-file 轮转，单文件上限 ${LOG_MAX_SIZE}，最多保留 ${LOG_MAX_FILE} 份"
    if [ "$tls_choice" = y ]; then
        info "HTTPS 模式: dufs 仅监听 ${bind_addr}:${port}，公网统一走 Caddy HTTPS"
    fi
}

wait_for_dufs() {
    local i status restarts code health_host=$bind_addr
    if [ "$health_host" = 0.0.0.0 ]; then
        health_host=127.0.0.1
    fi
    for ((i = 1; i <= HEALTH_WAIT_SECONDS; i++)); do
        sleep 1
        status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)
        restarts=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)
        if [ "$status" != running ] || [ "$restarts" != 0 ]; then
            docker logs --tail 20 "$CONTAINER_NAME" >&2 || true
            fail "dufs 容器未能稳定运行 (状态: ${status}, 重启次数: ${restarts})，上面是容器日志"
        fi
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://${health_host}:${port}/__dufs__/health" 2>/dev/null || true)
        if [ -n "$code" ] && [ "$code" != 000 ]; then
            info "dufs 已启动并响应 HTTP ${code} (端口 ${port}, 容器状态: ${status}, 等待 ${i}s)"
            return
        fi
    done
    docker logs --tail 20 "$CONTAINER_NAME" >&2 || true
    fail "等待 ${HEALTH_WAIT_SECONDS}s 后 dufs 仍未就绪 (端口 ${port}, 最后响应: ${code:-无})，上面是容器日志"
}

render_caddyfile() {
    cat <<EOF
${domain}:${https_port} {
    reverse_proxy 127.0.0.1:${port}
}
EOF
}

run_caddy() {
    tmp_caddyfile=$(mktemp)
    render_caddyfile >"$tmp_caddyfile"
    mv -f "$tmp_caddyfile" "$CADDY_FILE"
    tmp_caddyfile=""
    mkdir -p "$CADDY_DATA_DIR"
    docker run -d \
        --name "$CADDY_CONTAINER_NAME" \
        --restart always \
        --net host \
        --log-driver json-file \
        --log-opt max-size="$LOG_MAX_SIZE" \
        --log-opt max-file="$LOG_MAX_FILE" \
        -v "${CADDY_FILE}:/etc/caddy/Caddyfile:ro" \
        -v "${CADDY_DATA_DIR}:/data" \
        "$CADDY_IMAGE" >/dev/null || fail "启动容器 ${CADDY_CONTAINER_NAME} 失败"
    info "Caddyfile 已写入 ${CADDY_FILE}，证书数据保存在 ${CADDY_DATA_DIR} (自动申请/续期 Let's Encrypt 证书)"
}

wait_for_caddy() {
    local i status restarts
    for ((i = 1; i <= HEALTH_WAIT_SECONDS; i++)); do
        sleep 1
        status=$(docker inspect -f '{{.State.Status}}' "$CADDY_CONTAINER_NAME" 2>/dev/null || echo missing)
        restarts=$(docker inspect -f '{{.RestartCount}}' "$CADDY_CONTAINER_NAME" 2>/dev/null || echo 0)
        if [ "$status" != running ] || [ "$restarts" != 0 ]; then
            docker logs --tail 20 "$CADDY_CONTAINER_NAME" >&2 || true
            fail "Caddy 容器未能稳定运行 (状态: ${status}, 重启次数: ${restarts})，上面是容器日志"
        fi
        if ! command -v ss >/dev/null 2>&1; then
            if [ "$i" -ge 3 ]; then
                info "Caddy 容器已稳定运行 ${i}s (无 ss 命令，未校验端口监听)"
                return
            fi
            continue
        fi
        if [ -n "$(ss -Htln "sport = :${https_port}" 2>/dev/null || true)" ]; then
            info "Caddy 已启动并监听 TCP ${https_port} (等待 ${i}s)"
            return
        fi
    done
    info "注意: Caddy 运行中但 ${HEALTH_WAIT_SECONDS}s 内端口 ${https_port} 尚未监听，可能仍在申请证书 (域名需解析到本机且 80/443 可达)；查看进度: docker logs ${CADDY_CONTAINER_NAME}"
}

detect_external_caddy() {
    external_kind=""
    external_target=""
    local name image p own_pid
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$name" = "$CADDY_CONTAINER_NAME" ] && continue
        image=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)
        if [[ ${image,,} == *caddy* ]]; then
            external_kind=docker
            external_target=$name
            info "检测到已有 Caddy 容器: ${name} (镜像 ${image})"
            return 0
        fi
    done < <(docker ps --format '{{.Names}}')
    if command -v pgrep >/dev/null 2>&1; then
        own_pid=$(docker inspect -f '{{.State.Pid}}' "$CADDY_CONTAINER_NAME" 2>/dev/null || echo 0)
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            [ "$p" = "$own_pid" ] && continue
            external_kind=host
            external_target=$p
            info "检测到已有 Caddy 主机进程 (pid ${p})"
            return 0
        done < <(pgrep -x caddy 2>/dev/null || true)
    fi
    return 1
}

locate_external_config() {
    external_config=""
    external_dest=""
    external_bin=""
    local args adapter network_mode gateway src dst rel
    if [ "$external_kind" = docker ]; then
        args=$(docker inspect -f '{{join .Args " "}}' "$external_target" 2>/dev/null || true)
        external_dest=$(awk '{for (i = 1; i < NF; i++) if ($i == "--config") {print $(i + 1); exit}}' <<<"$args")
        external_dest=${external_dest:-/etc/caddy/Caddyfile}
        adapter=$(awk '{for (i = 1; i < NF; i++) if ($i == "--adapter") {print $(i + 1); exit}}' <<<"$args")
        if [ -z "$adapter" ] && [[ $external_dest == */Caddyfile ]]; then
            adapter=caddyfile
        fi
        if [ "$adapter" != caddyfile ]; then
            info "已有 Caddy 的配置不是 Caddyfile 格式 (adapter: ${adapter:-未知}, config: ${external_dest})，无法自动合并"
            return 1
        fi
        while read -r src dst; do
            [ -n "$src" ] && [ -n "$dst" ] || continue
            if [ "$dst" = "$external_dest" ] && [ -f "$src" ]; then
                external_config=$src
                break
            fi
            if [[ $external_dest == "$dst"/* ]]; then
                rel=${external_dest#"$dst"/}
                if [ -f "${src}/${rel}" ]; then
                    external_config="${src}/${rel}"
                    break
                fi
            fi
        done < <(docker inspect -f '{{range .Mounts}}{{.Source}} {{.Destination}}{{"\n"}}{{end}}' "$external_target" 2>/dev/null || true)
        network_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$external_target" 2>/dev/null || true)
        if [ "$network_mode" = host ]; then
            upstream_addr=127.0.0.1
        else
            gateway=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{"\n"}}{{end}}' "$external_target" 2>/dev/null | awk 'NF {print; exit}')
            if [ -n "$gateway" ]; then
                upstream_addr=$gateway
                info "已有 Caddy 容器跑在 ${network_mode} 网络, 将改用宿主机网桥地址 ${upstream_addr} 供其反代 (公网不可达)"
            else
                upstream_addr=127.0.0.1
                info "注意: 未能取到已有 Caddy 容器的网桥网关, 暂按 127.0.0.1 处理; 若它不在 host 网络, 反代可能不通"
            fi
        fi
        if [ -z "$external_config" ]; then
            info "未能从容器 ${external_target} 的挂载中定位 Caddyfile 宿主机路径 (config: ${external_dest})，无法自动合并"
            return 1
        fi
        info "已定位已有 Caddy 配置: ${external_config} (容器内 ${external_dest})"
        return 0
    fi
    args=$(tr '\0' ' ' <"/proc/${external_target}/cmdline" 2>/dev/null || true)
    external_dest=$(awk '{for (i = 1; i < NF; i++) if ($i == "--config") {print $(i + 1); exit}}' <<<"$args")
    external_dest=${external_dest:-/etc/caddy/Caddyfile}
    adapter=$(awk '{for (i = 1; i < NF; i++) if ($i == "--adapter") {print $(i + 1); exit}}' <<<"$args")
    if [ -z "$adapter" ] && [[ $external_dest == */Caddyfile ]]; then
        adapter=caddyfile
    fi
    if [ "$adapter" != caddyfile ]; then
        info "已有 Caddy 的配置不是 Caddyfile 格式 (adapter: ${adapter:-未知}, config: ${external_dest})，无法自动合并"
        return 1
    fi
    external_bin=$(readlink -f "/proc/${external_target}/exe" 2>/dev/null || command -v caddy || true)
    if [ -z "$external_bin" ]; then
        info "未能定位已有 Caddy 的可执行文件，无法自动校验/热加载"
        return 1
    fi
    external_config=$external_dest
    upstream_addr=127.0.0.1
    if [ ! -f "$external_config" ]; then
        info "已有 Caddy 配置文件不存在或不可读: ${external_config}，无法自动合并"
        return 1
    fi
    info "已定位已有 Caddy 配置: ${external_config} (可执行文件 ${external_bin})"
    return 0
}

external_caddy_exec() {
    if [ "$1" = docker ]; then
        docker exec "$2" caddy "$3" --config "$4" --adapter caddyfile
    else
        "$5" "$3" --config "$4" --adapter caddyfile
    fi
}

choose_caddy_mode() {
    local input
    if [ -n "${WEBDAV_CADDY_MODE:-}" ]; then
        case $WEBDAV_CADDY_MODE in
            merge | manual) caddy_mode=$WEBDAV_CADDY_MODE ;;
            *) fail "环境变量 WEBDAV_CADDY_MODE=${WEBDAV_CADDY_MODE} 不合法 (merge / manual)" ;;
        esac
        info "接入已有 Caddy 的方式: ${caddy_mode} (来自环境变量 WEBDAV_CADDY_MODE)"
    elif ! has_tty; then
        caddy_mode=manual
        info "接入已有 Caddy 的方式: manual (无交互终端且未设置 WEBDAV_CADDY_MODE, 不擅自改动已有 Caddy)"
    else
        while true; do
            read -r -p "如何接入已有 Caddy? 1=自动合并配置并热加载(先备份+校验, 失败自动还原) 2=只给配置片段, 你手动加到 Caddyfile (默认 2): " input </dev/tty || input=""
            input=${input:-2}
            case $input in
                1) caddy_mode=merge; break ;;
                2) caddy_mode=manual; break ;;
                *) info "${input} 不合法 (1 / 2)，请重新输入" ;;
            esac
        done
        info "接入已有 Caddy 的方式: ${caddy_mode}"
    fi
    if locate_external_config; then
        if [ "$caddy_mode" = manual ]; then
            info "手动模式: 稍后给出配置片段与热加载命令"
        fi
    else
        if [ "$caddy_mode" = merge ]; then
            info "无法自动合并, 改为手动模式 (只给配置片段)"
        fi
        caddy_mode=manual
    fi
}

render_site_block() {
    printf '%s\n' "$CADDY_BEGIN_MARK"
    printf '%s:%s {\n    reverse_proxy %s:%s\n}\n' "$domain" "$https_port" "$upstream_addr" "$port"
    printf '%s\n' "$CADDY_END_MARK"
}

strip_marked_block() {
    local tmp
    tmp=$(mktemp)
    sed "/^${CADDY_BEGIN_MARK}/,/^${CADDY_END_MARK}/d" "$1" >"$tmp"
    cat "$tmp" >"$1"
    rm -f "$tmp"
}

merge_caddy_config() {
    local backup
    backup="${external_config}.bk.$(date +%Y%m%d%H%M%S)"
    cp -p "$external_config" "$backup"
    strip_marked_block "$external_config"
    render_site_block >>"$external_config"
    if ! external_caddy_exec "$external_kind" "$external_target" validate "$external_dest" "$external_bin" >/dev/null 2>&1; then
        cat "$backup" >"$external_config"
        info "注意: 合并后的 Caddyfile 未通过 caddy validate, 已还原原配置, 改为手动模式 (原 Caddy 不受影响)"
        caddy_mode=manual
        return
    fi
    if ! external_caddy_exec "$external_kind" "$external_target" reload "$external_dest" "$external_bin" >/dev/null 2>&1; then
        cat "$backup" >"$external_config"
        external_caddy_exec "$external_kind" "$external_target" reload "$external_dest" "$external_bin" >/dev/null 2>&1 || true
        info "注意: caddy reload 失败, 已还原原配置并尝试重新加载, 改为手动模式 (原 Caddy 不受影响)"
        caddy_mode=manual
        return
    fi
    info "已把本站点合并进 ${external_config} 并热加载 (原配置备份: ${backup})"
}

cleanup_old_merge() {
    case "$old_caddy_mode" in
        merge|manual) ;;
        *) return 0 ;;
    esac
    if [ "$caddy_mode" = merge ] && [ "$old_caddy_config" = "$external_config" ]; then
        return 0
    fi
    if [ "$old_caddy_mode" = manual ] && [ "$caddy_mode" = manual ]; then
        return 0
    fi
    if [ -z "$old_caddy_config" ] || [ ! -f "$old_caddy_config" ]; then
        return 0
    fi
    grep -q "^${CADDY_BEGIN_MARK}" "$old_caddy_config" || return 0
    local backup
    backup="${old_caddy_config}.bk.$(date +%Y%m%d%H%M%S)"
    cp -p "$old_caddy_config" "$backup"
    strip_marked_block "$old_caddy_config"
    if external_caddy_exec "$old_caddy_kind" "$old_caddy_target" validate "$old_caddy_dest" "$old_caddy_bin" >/dev/null 2>&1 &&
        external_caddy_exec "$old_caddy_kind" "$old_caddy_target" reload "$old_caddy_dest" "$old_caddy_bin" >/dev/null 2>&1; then
        info "本次不再合并到原 Caddy, 已从 ${old_caddy_config} 移除本站点块并热加载 (备份: ${backup})"
    else
        cat "$backup" >"$old_caddy_config"
        info "注意: 从原 Caddy 配置移除本站点块失败, 已还原; 请手动删除 ${old_caddy_config} 中 ${CADDY_BEGIN_MARK} 到 ${CADDY_END_MARK} 的片段"
    fi
}

write_caddy_snippet() {
    (umask 077 && render_site_block >"$CADDY_SNIPPET_FILE")
}

remind_old_port_rule() {
    local old=$1 tool=$2 status=$3
    if ! valid_port "$old"; then
        return
    fi
    if [ "$old" = "$port" ] || [ "$old" = "$https_port" ] || { [ "$tls_choice" = y ] && [ "$old" = "$ACME_HTTP_PORT" ]; }; then
        return
    fi
    if [ "$tool" = ufw ]; then
        if grep -qE "^${old}/tcp[[:space:]]" <<<"$status"; then
            info "提示: 旧端口 ${old} 的 ufw 放行规则保留未删；确认不再需要可执行: ufw delete allow ${old}/tcp"
        fi
        return
    fi
    if firewall-cmd --permanent --query-port="${old}/tcp" >/dev/null 2>&1; then
        info "提示: 旧端口 ${old} 的 firewalld 放行规则保留未删；确认不再需要可执行: firewall-cmd --permanent --remove-port=${old}/tcp && firewall-cmd --reload"
    fi
}

open_firewall() {
    local -a ports=("$port")
    if [ "$tls_choice" = y ]; then
        ports=("$ACME_HTTP_PORT" "$https_port")
        if [ "$caddy_mode" != own ]; then
            ports+=("$port")
        fi
    fi
    local p status
    if command -v ufw >/dev/null 2>&1; then
        status=$(LC_ALL=C ufw status 2>/dev/null || true)
        if [[ $status == *"Status: active"* ]]; then
            for p in "${ports[@]}"; do
                if ufw allow "${p}/tcp" >/dev/null; then
                    info "ufw 已启用，已放行 TCP ${p}"
                else
                    info "注意: ufw 放行 TCP ${p} 失败，请手动执行 ufw allow ${p}/tcp"
                fi
            done
            remind_old_port_rule "$installed_port" ufw "$status"
            remind_old_port_rule "$installed_https_port" ufw "$status"
            return
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for p in "${ports[@]}"; do
            if firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null && firewall-cmd --reload >/dev/null; then
                info "firewalld 已启用，已放行 TCP ${p}"
            else
                info "注意: firewalld 放行 TCP ${p} 失败，请手动执行 firewall-cmd --permanent --add-port=${p}/tcp && firewall-cmd --reload"
            fi
        done
        remind_old_port_rule "$installed_port" firewalld ""
        remind_old_port_rule "$installed_https_port" firewalld ""
        return
    fi
    info "未检测到启用中的 ufw / firewalld，跳过系统防火墙放行；如云厂商有安全组，请自行放行 TCP ${ports[*]}"
}

detect_server_ip() {
    server_ip=$(curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || true)
    if [ -z "$server_ip" ]; then
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    server_ip=${server_ip:-你的服务器IP}
}

check_domain_resolution() {
    command -v getent >/dev/null 2>&1 || return 0
    [[ $server_ip =~ ^[0-9.]+$ ]] || return 0
    local resolved
    resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)
    if [ -z "$resolved" ]; then
        info "注意: 域名 ${domain} 暂未解析出 IPv4 地址，证书申请会失败直到解析生效 (需 A 记录指向 ${server_ip})"
        return
    fi
    if ! grep -qx "$server_ip" <<<"$resolved"; then
        info "注意: 域名 ${domain} 解析到 $(tr '\n' ' ' <<<"$resolved")，不含本机公网 IP ${server_ip}，证书申请可能失败 (DNS 刚改可忽略, Caddy 会自动重试)"
    fi
}

write_state() {
    tmp_state=$(mktemp)
    cat >"$tmp_state" <<EOF
PORT=${port}
USER=${user}
PASS=${pass}
DIR=${data_dir}
TLS=${tls_choice}
DOMAIN=${domain}
HTTPS_PORT=${https_port:-$DEFAULT_HTTPS_PORT}
BIND=${bind_addr}
CADDY_MODE=${caddy_mode}
CADDY_KIND=${external_kind}
CADDY_TARGET=${external_target}
CADDY_CONFIG=${external_config}
CADDY_DEST=${external_dest}
CADDY_BIN=${external_bin}
EOF
    chmod 600 "$tmp_state"
    mv -f "$tmp_state" "$STATE_FILE"
    tmp_state=""
    info "安装状态已保存到 ${STATE_FILE} (重装/update 时沿用)"
}

webdav_url() {
    if [ "$tls_choice" = y ]; then
        if [ "$https_port" = 443 ]; then
            printf 'https://%s/' "$domain"
        else
            printf 'https://%s:%s/' "$domain" "$https_port"
        fi
        return
    fi
    local host=$server_ip
    if [[ $host == *:* ]]; then
        host="[${host}]"
    fi
    printf 'http://%s:%s/' "$host" "$port"
}

render_client_info() {
    local url
    url=$(webdav_url)
    cat <<EOF
WebDAV 地址:  ${url}
用户名:       ${user}
密码:         ${pass}
认证方式:     Digest / Basic 均支持 (dufs 默认发起 Digest 质询, HTTP 下建议客户端用 Digest)
数据目录:     ${data_dir}
EOF
    if [ "$tls_choice" = y ]; then
        case $caddy_mode in
            own)
                cat <<EOF
HTTPS:        Caddy 自动证书 (域名 ${domain}, 对外端口 ${https_port}, 80 端口用于签证/跳转)
EOF
                ;;
            merge)
                cat <<EOF
HTTPS:        已合并到已有 Caddy (${external_target}), 站点配置在 ${external_config}, 证书由该 Caddy 自动申请/续期
EOF
                ;;
            manual)
                cat <<EOF
HTTPS:        待手动接入已有 Caddy (${external_target:-已有实例}), 配置片段见 ${CADDY_SNIPPET_FILE}, 加入并 reload 后生效
EOF
                ;;
        esac
        cat <<EOF
本机直连:     http://${bind_addr}:${port}/ (非公网地址)
EOF
    fi
    cat <<EOF

客户端接入:
  macOS:    Finder → 前往 → 连接服务器 (⌘K)，输入上面的地址
  Windows:  此电脑 → 映射网络驱动器，输入上面的地址
  rclone:   rclone config → 类型 webdav，url 填上面的地址，vendor 选 other，填用户名密码
EOF
}

show_result() {
    (umask 077 && render_client_info >"$INFO_FILE")
    echo
    step "========================================"
    step "  安装完成！"
    step "========================================"
    echo
    render_client_info
    if [ "$tls_choice" = y ] && [ "$caddy_mode" = manual ]; then
        echo
        step "把下面的站点片段加到已有 Caddy 的 Caddyfile, 然后热加载 (片段已保存到 ${CADDY_SNIPPET_FILE}):"
        render_site_block
        if [ "$external_kind" = docker ]; then
            step "热加载: docker exec ${external_target} caddy reload --config ${external_dest:-/etc/caddy/Caddyfile}"
        else
            step "热加载: systemctl reload caddy (或 caddy reload --config <你的Caddyfile路径>)"
        fi
        step "注意: 确保已有 Caddy 对外暴露 ${https_port} (docker 部署需有对应 -p 端口映射); 片段里的反代地址 ${upstream_addr}:${port} 是 dufs 的实际监听地址, 请原样保留"
    fi
    echo
    step "以上信息已保存到 ${INFO_FILE}，随时可执行 cat ${INFO_FILE} 查看"
    step "更新服务端版本: bash <(curl -fsSL https://raw.githubusercontent.com/afret0/onekey_zsh/master/onekey_webdav.sh) update"
    step "请妥善保存以上信息！"
}

install_webdav() {
    banner
    require_root
    require_curl
    load_existing
    choose_port
    choose_account
    choose_dir
    choose_tls
    if [ "$tls_choice" = y ]; then
        choose_domain
        if [ "$port" = "$ACME_HTTP_PORT" ]; then
            fail "HTTPS 模式下 dufs 监听端口不能是 ${ACME_HTTP_PORT} (该端口由 Caddy 用于证书申请与跳转)，请换端口"
        fi
    fi
    ensure_docker
    if [ "$tls_choice" = y ]; then
        if detect_external_caddy; then
            choose_caddy_mode
        else
            caddy_mode=own
            info "未检测到已有 Caddy，将用脚本自带的 ${CADDY_CONTAINER_NAME} 容器"
        fi
        bind_addr=127.0.0.1
        if [ "$caddy_mode" != own ]; then
            bind_addr=$upstream_addr
        fi
        choose_https_port
    fi
    check_port_free "$port" "$CONTAINER_NAME"
    if [ "$tls_choice" = y ] && [ "$caddy_mode" = own ]; then
        check_port_free "$ACME_HTTP_PORT" "$CADDY_CONTAINER_NAME"
        check_port_free "$https_port" "$CADDY_CONTAINER_NAME"
    fi
    mkdir -p "$CONFIG_DIR" "$data_dir"
    detect_server_ip
    if [ "$tls_choice" = y ]; then
        check_domain_resolution
    fi
    cleanup_old_merge
    step "正在启动 WebDAV (dufs)..."
    remove_old_container "$CONTAINER_NAME"
    remove_old_container "$CADDY_CONTAINER_NAME"
    run_dufs
    wait_for_dufs
    if [ "$tls_choice" = y ]; then
        case $caddy_mode in
            own)
                step "正在启动 Caddy (自动 HTTPS)..."
                run_caddy
                wait_for_caddy
                ;;
            merge)
                step "正在把本站点合并进已有 Caddy..."
                merge_caddy_config
                ;;
        esac
        if [ "$caddy_mode" = manual ]; then
            write_caddy_snippet
            info "手动模式: 本站点配置片段稍后给出, 需你自行加入已有 Caddy 并热加载"
        fi
    fi
    open_firewall
    write_state
    show_result
}

load_state_strict() {
    port=$(state_value PORT)
    user=$(state_value USER)
    pass=$(state_value PASS)
    data_dir=$(state_value DIR)
    tls_choice=$(state_value TLS)
    domain=$(state_value DOMAIN)
    https_port=$(state_value HTTPS_PORT)
    valid_port "$port" || fail "已安装配置中的端口不合法 (值: ${port:-空})，请重新执行安装命令"
    port=$((10#$port))
    valid_account "$user" || fail "已安装配置中的用户名不合法，请重新执行安装命令"
    valid_account "$pass" || fail "已安装配置中的密码不合法，请重新执行安装命令"
    valid_dir "$data_dir" || fail "已安装配置中的数据目录不合法 (值: ${data_dir:-空})，请重新执行安装命令"
    tls_choice=$(parse_yes_no "${tls_choice:-n}") || fail "已安装配置中的 HTTPS 状态不合法，请重新执行安装命令"
    if [ "$tls_choice" = y ]; then
        valid_domain "$domain" || fail "已安装配置中的域名不合法 (值: ${domain:-空})，请重新执行安装命令"
        valid_port "$https_port" || fail "已安装配置中的 HTTPS 端口不合法 (值: ${https_port:-空})，请重新执行安装命令"
        https_port=$((10#$https_port))
    fi
    bind_addr=$(state_value BIND)
    [[ $bind_addr =~ ^[0-9.]+$ ]] || fail "已安装配置中的监听地址不合法 (值: ${bind_addr:-空})，请重新执行安装命令"
    caddy_mode=$(state_value CADDY_MODE)
    case $caddy_mode in
        own | merge | manual | none) ;;
        *) fail "已安装配置中的 CADDY_MODE 不合法 (值: ${caddy_mode:-空})，请重新执行安装命令" ;;
    esac
    external_kind=$(state_value CADDY_KIND)
    external_target=$(state_value CADDY_TARGET)
    external_config=$(state_value CADDY_CONFIG)
    external_dest=$(state_value CADDY_DEST)
}

update_image() {
    local image=$1 container=$2 old_id new_id
    old_id=$(image_id "$image")
    step "正在拉取最新镜像 ${image}..."
    docker pull "$image" >/dev/null || fail "拉取镜像 ${image} 失败"
    new_id=$(image_id "$image")
    if [ "$old_id" = "$new_id" ]; then
        info "镜像 ${image} 已是最新，容器 ${container} 不重建"
        return 1
    fi
    info "镜像 ${image} 有新版本，重建容器 ${container}"
    return 0
}

update_webdav() {
    banner
    require_root
    require_curl
    if [ ! -f "$STATE_FILE" ]; then
        fail "未找到已安装的配置 ${STATE_FILE}，update 只更新已安装的 WebDAV，请先执行安装命令"
    fi
    load_state_strict
    ensure_docker
    if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        fail "未找到容器 ${CONTAINER_NAME}，update 只更新已安装的 WebDAV，请先执行安装命令"
    fi
    info "update 只更新镜像与容器，端口 ${port}、账号、数据目录 ${data_dir}、HTTPS 设置均保持不变，客户端无需任何改动"
    if update_image "$WEBDAV_IMAGE" "$CONTAINER_NAME"; then
        remove_old_container "$CONTAINER_NAME"
        run_dufs
        wait_for_dufs
    fi
    if [ "$tls_choice" = y ]; then
        case $caddy_mode in
            own)
                if ! docker container inspect "$CADDY_CONTAINER_NAME" >/dev/null 2>&1; then
                    info "未找到容器 ${CADDY_CONTAINER_NAME}，按已安装配置重新拉起"
                    run_caddy
                    wait_for_caddy
                elif update_image "$CADDY_IMAGE" "$CADDY_CONTAINER_NAME"; then
                    remove_old_container "$CADDY_CONTAINER_NAME"
                    run_caddy
                    wait_for_caddy
                fi
                ;;
            merge | manual)
                info "HTTPS 由已有 Caddy (${external_target:-外部实例}) 提供, update 不改动它"
                ;;
        esac
    fi
    step "更新完成，配置与客户端信息保持不变 (cat ${INFO_FILE} 查看)"
}

case "${1:-install}" in
    install) install_webdav ;;
    update) update_webdav ;;
    *) fail "未知命令: $1 (支持 install / update)" ;;
esac