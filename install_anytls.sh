#!/usr/bin/env bash
#
# AnyTLS-Go 一键安装脚本（重写版）
# 说明：本脚本尽量兼容常见 Linux 发行版并实现 README 中描述的功能。
#
set -euo pipefail
IFS=$'\n\t'

# -----------------------
# 日志函数
# -----------------------
log_info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }

# -----------------------
# 清理
# -----------------------
TEMP_DIR=""
cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    log_info "删除临时目录 $TEMP_DIR"
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

# -----------------------
# 默认配置
# -----------------------
REPO_OWNER="anytls"
REPO_NAME="anytls-go"
SERVICE_NAME="anytls"
INSTALL_BIN="/usr/local/bin/anytls-server"
ETC_DIR="/etc/anytls"
ENV_FILE="$ETC_DIR/anytls.env"
SYSTEMD_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/post/anytls_renew.sh"

# CLI 参数（可覆盖）
OPT_PORT=""
OPT_PASSWORD=""
OPT_TLS=false
OPT_MENU=false
OPT_UPDATE=false
OPT_UNINSTALL=false
OPT_CHECK_STATUS=false

# -----------------------
# 小工具
# -----------------------
require_root() {
  if [ "$EUID" -ne 0 ]; then
    log_error "此脚本需要以 root 或 sudo 运行。请使用 sudo ./install_anytls.sh"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

get_public_ip() {
  local ip=""
  for svc in "https://api.ipify.org" "https://ifconfig.me" "https://ip.seeip.org"; do
    ip=$(curl -s --max-time 5 "$svc" || true)
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  done
  echo ""
  return 1
}

prompt_yesno() {
  local prompt="${1:-Confirm?}"
  local default="${2:-y}"
  read -r -p "$prompt (Y/n): " ans
  ans=${ans:-$default}
  case "$ans" in
    [Yy]* ) return 0;;
    * ) return 1;;
  esac
}

# -----------------------
# 解析参数
# -----------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --port) OPT_PORT="$2"; shift 2;;
    --password) OPT_PASSWORD="$2"; shift 2;;
    --tls) OPT_TLS=true; shift;;
    --menu) OPT_MENU=true; shift;;
    --update) OPT_UPDATE=true; shift;;
    --uninstall) OPT_UNINSTALL=true; shift;;
    --check-status) OPT_CHECK_STATUS=true; shift;;
    --help|-h) cat <<'EOF'
使用:
  --port <port>         指定监听端口
  --password <pwd>      指定连接密码
  --tls                 尝试使用 Let's Encrypt 自动申请证书（需 certbot）
  --menu                显示交互式管理菜单
  --update              更新已安装的 anytls-server 到最新版本
  --uninstall           卸载 anytls 服务与文件
  --check-status        显示服务状态
  --help                显示帮助
EOF
  exit 0;;
    *) log_warn "未知参数: $1"; shift;;
  esac
done

# -----------------------
# 发行版检测与依赖安装
# -----------------------
install_dependencies() {
  log_info "安装必要依赖 (curl, wget, unzip, ca-certificates)"
  if command_exists apt-get; then
    apt-get update -y
    apt-get install -y curl wget unzip ca-certificates gnupg2 lsb-release || true
    # certbot optional
    if ! command_exists certbot; then
      apt-get install -y certbot || true
    fi
  elif command_exists yum || command_exists dnf; then
    if command_exists dnf; then
      dnf install -y curl wget unzip ca-certificates lsb-release || true
      dnf install -y certbot || true
    else
      yum install -y curl wget unzip ca-certificates redhat-lsb-core || true
      yum install -y certbot || true
    fi
  elif command_exists pacman; then
    pacman -Sy --noconfirm curl wget unzip ca-certificates lsb-release || true
    pacman -Sy --noconfirm certbot || true
  elif command_exists apk; then
    apk add --no-cache curl wget unzip ca-certificates coreutils || true
    apk add --no-cache certbot || true
  else
    log_warn "无法识别包管理器，请手动确保 curl/wget/unzip 可用"
  fi
}

detect_arch_tag() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "linux_amd64";;
    i386|i686) echo "linux_386";;
    armv7*|armv7l) echo "linux_armv7";;
    aarch64|arm64) echo "linux_arm64";;
    *) log_error "不支持的系统架构: $arch";;
  esac
}

# -----------------------
# 获取最新 release 并挑选合适下载链接
# -----------------------
fetch_release_download_url() {
  local arch_tag
  arch_tag="$(detect_arch_tag)"
  log_info "检测架构: $arch_tag"
  local api="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
  local resp
  resp="$(curl -sL --connect-timeout 10 --max-time 20 "$api")" || log_error "获取 GitHub Release 失败"
  # 解析 browser_download_url 字段并挑选匹配 arch_tag 与 .zip 或 .tar.gz
  local url
  url="$(printf '%s' "$resp" | grep -Eo '"browser_download_url":[[:space:]]*"[^"]+"' | cut -d'"' -f4 | grep "$arch_tag" | grep -E '\.zip$|\.tar.gz$' | head -n1 || true)"
  if [ -z "$url" ]; then
    # 兼容：有时文件名可能不同，尝试只匹配 arch_tag
    url="$(printf '%s' "$resp" | grep -Eo '"browser_download_url":[[:space:]]*"[^"]+"' | cut -d'"' -f4 | grep "$arch_tag" | head -n1 || true)"
  fi
  if [ -z "$url" ]; then
    log_error "未找到适配 $arch_tag 的下载文件，请检查 ${REPO_OWNER}/${REPO_NAME} Releases"
  fi
  echo "$url"
}

# -----------------------
# 下载并安装二进制
# -----------------------
install_binary_from_url() {
  local url="$1"
  TEMP_DIR="$(mktemp -d)"
  chmod 700 "$TEMP_DIR"
  cd "$TEMP_DIR"
  log_info "下载: $url"
  if ! wget -q --show-progress "$url" -O package; then
    curl -L --progress-bar -o package "$url" || log_error "下载失败"
  fi
  # 解压（支持 zip 和 tar.gz）
  if file package | grep -qi zip; then
    unzip -o package >/dev/null || log_error "解压 zip 失败"
  else
    mkdir -p pkg && tar -xf package -C pkg || true
    # 如果解压到 pkg，尝试移动内容
    if [ -d pkg ]; then
      mv pkg/* . 2>/dev/null || true
    fi
  fi

  # 找到 anytls-server 可执行文件
  local bin=""
  if [ -f anytls-server ]; then
    bin="anytls-server"
  else
    # 尝试在解压目录搜索可执行文件名
    bin="$(find . -maxdepth 3 -type f -name 'anytls-server' -perm /111 | head -n1 || true)"
  fi
  if [ -z "$bin" ]; then
    log_error "未在包内找到 anytls-server 可执行文件"
  fi
  install -m 755 "$bin" "$INSTALL_BIN" || log_error "安装二进制失败"
  log_info "已安装 $INSTALL_BIN"
  cd /
}

# -----------------------
# 更新 ENV_FILE 中的键值（替换或追加）
# -----------------------
update_env_var() {
  local key="$1"
  local val="$2"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # 使用临时文件替换单行
    sed -i "s#^${key}=.*#${key}=${val}#" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

# -----------------------
# 安全写入 systemd 单元并启用服务（修复 "Unit file ... does not exist" 情况）
# 原因与解决思路：
# - 确保以 root 权限原子写入文件（使用临时文件 + install），避免重定向权限问题
# - 明确使用 .service 后缀启用 unit，先 daemon-reload 再 enable
# - 若首次 enable 失败，打印诊断信息并尝试将 unit 安装到 /lib/systemd/system/ 作为兼容 fallback
# -----------------------
write_and_enable_systemd_unit() {
  local unit_content="$1"
  local tmp_unit
  tmp_unit="$(mktemp)"
  echo "$unit_content" > "$tmp_unit"
  # 确保目录存在
  mkdir -p "$(dirname "$SYSTEMD_FILE")"
  # 使用 install 原子写入并设置权限
  install -m 644 "$tmp_unit" "$SYSTEMD_FILE" || {
    log_warn "写入 $SYSTEMD_FILE 失败，尝试直接移动"
    mv "$tmp_unit" "$SYSTEMD_FILE" || log_error "无法写入 systemd 单元文件到 $SYSTEMD_FILE"
  }
  rm -f "$tmp_unit" || true

  log_info "已写入 systemd 单元: $SYSTEMD_FILE"
  systemctl daemon-reload || log_warn "systemctl daemon-reload 失败"

  # 尝试启用并启动（使用显式 .service 后缀以避免歧义）
  if systemctl enable --now "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    log_info "服务 ${SERVICE_NAME}.service 已启用并启动（或正在运行）"
    return 0
  fi

  # 如果启用失败，输��诊断信息并尝试 fallback（有些系统搜索 /lib/systemd/system）
  log_warn "启用服务失败，开始诊断..."
  log_info "systemd unit 文件存在性检查:"
  ls -l "$SYSTEMD_FILE" || true
  log_info "systemctl list-unit-files | grep ${SERVICE_NAME}"
  systemctl list-unit-files --type=service | grep "${SERVICE_NAME}" || true
  log_info "journalctl -xe 可能包含更多信息"

  # fallback: 将 unit 复制到 /lib/systemd/system/ 并重试
  if [ -d "/lib/systemd/system" ]; then
    log_info "尝试将 unit 复制到 /lib/systemd/system/ 并重试 enable"
    install -m 644 "$SYSTEMD_FILE" "/lib/systemd/system/${SERVICE_NAME}.service" || true
    systemctl daemon-reload || true
    if systemctl enable --now "${SERVICE_NAME}.service" >/dev/null 2>&1; then
      log_info "服务在 /lib/systemd/system/ 下启用成功"
      return 0
    fi
  fi

  log_error "无法启用服务 ${SERVICE_NAME}.service。请检查 systemd 日志与路径权限。"
}

# -----------------------
# TLS (Let's Encrypt) 简单集成（需要 certbot）
# - 申请证书后会把证书复制到 /etc/anytls/certs/<domain>/ 并设置 root:anytls 组与 0640 权限
# - 安装 renewal hook，在续期后自动复制证书并重启 anytls 服务
# -----------------------
enable_tls_certbot() {
  if ! command_exists certbot; then
    log_warn "certbot 未安装，跳过自动申请证书。请手动安装 certbot 后再运行脚本或使用 --menu 进行配置。"
    return 1
  fi

  local domain
  read -r -p "请输入绑定域名（必须解析到本机公网 IP）: " domain
  if [ -z "$domain" ]; then
    log_warn "未提供域名，跳过 TLS"
    return 1
  fi

  # 检查域名解析（尽量）
  local dns_ip=""
  if command_exists dig; then
    dns_ip="$(dig +short A "$domain" | head -n1 || true)"
  elif command_exists host; then
    dns_ip="$(host "$domain" 2>/dev/null | awk '/has address/ {print $4; exit}' || true)"
  else
    dns_ip=""
  fi

  local pubip
  pubip="$(get_public_ip || true)"
  if [ -n "$dns_ip" ] && [ -n "$pubip" ] && [ "$dns_ip" != "$pubip" ]; then
    log_warn "域名解析 IP ($dns_ip) 与检测到的公网 IP ($pubip) 不一致，证书申请可能失败。"
    if ! prompt_yesno "仍然继续申请证书吗？" "n"; then
      return 1
    fi
  fi

  log_info "使用 certbot 以 standalone 模式申请证书（会短暂占用 80 端口）"
  if ! certbot certonly --standalone -d "$domain" --non-interactive --agree-tos -m "admin@${domain}"; then
    log_error "证书申请失败，请检查域名解析与端口 80 是否可用"
  fi

  local cert_src="/etc/letsencrypt/live/${domain}"
  if [ ! -f "${cert_src}/fullchain.pem" ] || [ ! -f "${cert_src}/privkey.pem" ]; then
    log_warn "未找到证书文件，申请可能失败"
    return 1
  fi

  # 将证书复制到 /etc/anytls/certs/<domain>/ 并设置权限，供 anytls 用户读取
  local dest="${ETC_DIR}/certs/${domain}"
  mkdir -p "$dest"
  cp -f "${cert_src}/fullchain.pem" "${dest}/fullchain.pem"
  cp -f "${cert_src}/privkey.pem" "${dest}/privkey.pem"
  chown -R root:anytls "$dest"
  chmod 0640 "$dest/privkey.pem" || true
  chmod 0640 "$dest/fullchain.pem" || true

  # 更新 env 文件中的 TLS 相关变量
  update_env_var "USE_TLS" "true"
  update_env_var "DOMAIN" "$domain"
  update_env_var "TLS_CERT" "$dest/fullchain.pem"
  update_env_var "TLS_KEY" "$dest/privkey.pem"
  # TLS_ARGS 会被 systemd 启动脚本 (sh -c) 展开
  update_env_var "TLS_ARGS" "--tls --cert ${dest}/fullchain.pem --key ${dest}/privkey.pem"

  # 创建 renewal hook：续期后复制证书并重启服务
  if [ -d "/etc/letsencrypt/renewal-hooks/post" ]; then
    cat > "$RENEW_HOOK" <<EOF
#!/usr/bin/env bash
set -e
DOMAIN="${domain}"
SRC="/etc/letsencrypt/live/\${DOMAIN}"
DEST="${ETC_DIR}/certs/\${DOMAIN}"
if [ -d "\${SRC}" ]; then
  mkdir -p "\${DEST}"
  cp -f "\${SRC}/fullchain.pem" "\${DEST}/fullchain.pem" || true
  cp -f "\${SRC}/privkey.pem" "\${DEST}/privkey.pem" || true
  chown -R root:anytls "\${DEST}" || true
  chmod 0640 "\${DEST}/privkey.pem" || true
  chmod 0640 "\${DEST}/fullchain.pem" || true
  systemctl restart "${SERVICE_NAME}" || true
fi
EOF
    chmod +x "$RENEW_HOOK"
    log_info "已安装 certbot renewal hook: $RENEW_HOOK"
  else
    log_warn "无法安装 renewal hook: /etc/letsencrypt/renewal-hooks/post 不存在，请手动配置续期后复制证书并重启 anytls 服务。"
  fi

  # 重新加载 systemd 单元并重启服务以使用新证书
  systemctl daemon-reload || true
  systemctl restart "${SERVICE_NAME}" || log_warn "重启服务失败，请手动检查"
  log_info "TLS 已配置并启用，证书位于 ${dest}"
  return 0
}

# -----------------------
# 交互式菜单
# -----------------------
show_menu() {
  while true; do
    cat <<EOF

AnyTLS 管理菜单:
  1) 安装 / 更新
  2) 启动服务
  3) 停止服务
  4) 重启服务
  5) 服务状态
  6) 配置 Let's Encrypt TLS
  7) 卸载
  8) 显示 /etc/anytls/anytls.env
  9) 故障排除 (journalctl)
  0) 退出
EOF
    read -r -p "选择 [0-9]: " sel
    case "$sel" in
      1)
        main_install_logic
        ;;
      2) systemctl start "${SERVICE_NAME}" || log_warn "启动失败";;
      3) systemctl stop "${SERVICE_NAME}" || log_warn "停止失败";;
      4) systemctl restart "${SERVICE_NAME}" || log_warn "重启失败";;
      5) systemctl status "${SERVICE_NAME}" --no-pager || true;;
      6) enable_tls_certbot;;
      7)
        if prompt_yesno "确认卸载 AnyTLS 并移除文件？" "n"; then
          uninstall_all
          break
        fi
        ;;
      8) cat "$ENV_FILE" || log_warn "无法读取 $ENV_FILE";;
      9) journalctl -u "${SERVICE_NAME}" -f --no-pager || true;;
      0) break;;
      *) log_warn "无效选择";;
    esac
  done
}

# -----------------------
# 卸载
# -----------------------
uninstall_all() {
  log_info "停止服务并移除 systemd 配置"
  systemctl stop "${SERVICE_NAME}" || true
  systemctl disable "${SERVICE_NAME}" || true
  rm -f "$SYSTEMD_FILE"
  # 同时尝试删除 lib 下的 unit（若存在）
  rm -f "/lib/systemd/system/${SERVICE_NAME}.service" || true
  systemctl daemon-reload || true
  log_info "移除二进制与配置"
  rm -f "$INSTALL_BIN"
  # 删除 cert 复制与 renewal hook
  rm -rf "${ETC_DIR}"
  if [ -f "$RENEW_HOOK" ]; then
    rm -f "$RENEW_HOOK"
  fi
  log_info "（可选）如果需要，请手动移除 anytls 用户与防火墙规则"
}

# -----------------------
# 主安装流程
# -----------------------
choose_port_and_password() {
  # 端口选择：优先使用 OPT_PORT，否则随机 20000-60000
  if [ -n "$OPT_PORT" ]; then
    PORT="$OPT_PORT"
  else
    if command_exists shuf; then
      PORT="$(shuf -i 20000-60000 -n 1)"
    else
      PORT=$((20000 + RANDOM % 40000))
    fi
  fi
  # 密码选择
  if [ -n "$OPT_PASSWORD" ]; then
    PASSWORD="$OPT_PASSWORD"
  else
    if command_exists openssl; then
      PASSWORD="$(openssl rand -base64 12 | tr -d '=+/' | cut -c1-16)"
    else
      PASSWORD="$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c16 || echo 'anytls_default')"
    fi
  fi
  log_info "使用端口: $PORT"
  log_info "连接密码: $PASSWORD"
  OPT_PORT="$PORT"
  OPT_PASSWORD="$PASSWORD"
}

main_install_logic() {
  require_root
  install_dependencies

  # 获取公网 IP
  SERVER_IP="$(get_public_ip || true)"
  if [ -z "$SERVER_IP" ]; then
    read -r -p "无法自动检测公网 IP，请输入服务器公网 IP: " SERVER_IP
  fi
  log_info "检测到公网 IP: $SERVER_IP"

  choose_port_and_password

  # 获取下载 URL
  DOWNLOAD_URL="$(fetch_release_download_url)"
  log_info "下载链接: $DOWNLOAD_URL"

  install_binary_from_url "$DOWNLOAD_URL"

  # 设置用户与 systemd service（ENV_FILE 先写基础变量）
  id anytls >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /nonexistent anytls || true
  mkdir -p "$ETC_DIR"
  chown root:anytls "$ETC_DIR" || true
  chmod 0750 "$ETC_DIR" || true

  # 初始 env 文件（包含 TLS 相关字段的默认值，便于后续更新）
  cat > "$ENV_FILE" <<EOV
PORT=${OPT_PORT}
PASSWORD=${OPT_PASSWORD}
USE_TLS=false
DOMAIN=
TLS_CERT=
TLS_KEY=
TLS_ARGS=
EOV
  chown root:anytls "$ENV_FILE" || true
  chmod 0640 "$ENV_FILE" || true

  # systemd 单元使用 sh -c 来依据 ENV_FILE 中的 TLS_ARGS 动态构造启动参数
  read -r -d '' unit_content <<EOF || true
[Unit]
Description=AnyTLS-Go Server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=anytls
Group=anytls
EnvironmentFile=${ENV_FILE}
ExecStart=/bin/sh -c 'exec ${INSTALL_BIN} -l 0.0.0.0:\${PORT} -p \${PASSWORD} \${TLS_ARGS}'
Restart=on-failure
RestartSec=5
LimitNPROC=10000
LimitNOFILE=1000000
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${ETC_DIR}
ProtectHome=yes
PrivateDevices=yes

[Install]
WantedBy=multi-user.target
EOF

  # 使用安全写入并尝试启用（已封装成函数，包含诊断与 fallback）
  write_and_enable_systemd_unit "$unit_content"

  # 如果用户通过 CLI 指定了 --tls，尝试自动申请证书并启用
  if [ "$OPT_TLS" = true ]; then
    enable_tls_certbot || log_warn "自动申请/配置 TLS 失败，服务仍然以非 TLS 模式运行"
  fi

  configure_firewall "$OPT_PORT"

  # 启动并检查状态
  sleep 1
  SERVICE_STATUS="$(systemctl is-active "${SERVICE_NAME}" || echo inactive)"
  log_info "服务状态: $SERVICE_STATUS"

  echo
  echo -e "\033[1;32m✅ AnyTLS 安装/更新 完成\033[0m"
  echo "服务器 IP: $SERVER_IP"
  echo "监听端口: $OPT_PORT"
  echo "连接密码: $OPT_PASSWORD"
  if ls "${ETC_DIR}/certs/"*"/fullchain.pem" 1>/dev/null 2>&1; then
    echo "TLS: 已启用（证书位于 ${ETC_DIR}/certs/）"
  else
    echo "TLS: 未启用"
  fi
}

# -----------------------
# 防火墙配置（简单）
# -----------------------
configure_firewall() {
  local port="$1"
  log_info "尝试自动添加防火墙规则（若支持）: 端口 $port"
  if command_exists ufw; then
    ufw allow "$port"/tcp || true
    ufw reload >/dev/null 2>&1 || true
    log_info "UFW 已允许端口 $port/tcp"
  elif command_exists firewall-cmd; then
    firewall-cmd --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    log_info "firewalld 已允许端口 $port/tcp"
  else
    # 尝试 iptables 添加输出/输入规则（保守）
    if command_exists iptables; then
      iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
      log_info "iptables 已添加规则（未持久化）"
    fi
  fi
}

# -----------------------
# 主程序入口
# -----------------------
if [ "$OPT_UNINSTALL" = true ]; then
  require_root
  uninstall_all
  exit 0
fi

if [ "$OPT_CHECK_STATUS" = true ]; then
  systemctl status "${SERVICE_NAME}" --no-pager || true
  exit 0
fi

if [ "$OPT_MENU" = true ]; then
  require_root
  show_menu
  exit 0
fi

if [ "$OPT_UPDATE" = true ]; then
  require_root
  log_info "开始更新 anytls-server..."
  main_install_logic
  exit 0
fi

# 默认行为：安装（或更新）
main_install_logic

exit 0
