#!/bin/sh
# Live QRCode 交互式安装 / 重配脚本
#   ./setup.sh          交互式（问几个问题，回车用默认值）
#   ./setup.sh --yes    全用默认值，不提问（适合自动化）
set -eu
cd "$(dirname "$0")"

INTERACTIVE=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--non-interactive) INTERACTIVE=0 ;;
    -h|--help)
      echo "用法: ./setup.sh [--yes]"
      echo "  --yes  使用默认值，不交互"
      exit 0
      ;;
  esac
done
[ -t 0 ] || INTERACTIVE=0

hr() { printf '%s\n' "────────────────────────────────────────────"; }
say() { printf '%s\n' "$*"; }

# 提示写 stderr，答案写 stdout，方便 $( ) 取值
ask() {
  _prompt=$1; _def=$2; _ans=""
  if [ "$INTERACTIVE" = "1" ]; then
    printf '  %s [%s]: ' "$_prompt" "$_def" >&2
    read -r _ans || true
  fi
  [ -z "$_ans" ] && _ans=$_def
  printf '%s' "$_ans"
}

yes_no() {
  _a=$(ask "$1" "$2")
  case "$_a" in y|Y|yes|YES|是) return 0 ;; *) return 1 ;; esac
}

is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

detect_ip() {
  for url in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
    _ip=$(curl -fsS --max-time 4 "$url" 2>/dev/null || true)
    case "$_ip" in
      *[!0-9.]*|"") _ip="" ;;
      *) printf '%s' "$_ip"; return 0 ;;
    esac
  done
  return 0
}

# ── 环境检查 ────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || { say "✗ 没有找到 docker，请先安装 Docker Engine 或 Docker Desktop"; exit 1; }

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    DOCKER="sudo docker"
    say "· 当前用户没有 docker 权限，将使用 sudo"
  else
    say "✗ 当前用户没有 docker 权限，也没有 sudo"
    exit 1
  fi
fi
$DOCKER compose version >/dev/null 2>&1 || { say "✗ 需要 Docker Compose v2"; exit 1; }

hr
say "  Live QRCode 安装向导"
hr

if [ -f .env ]; then
  if [ "$INTERACTIVE" = "0" ]; then
    SKIP_CONFIG=1              # --yes 且已有配置：沿用，不覆盖
    say "· 已有 .env，非交互模式下令其沿用"
  elif ! yes_no "检测到已有 .env，要重新配置吗？" "n"; then
    say "· 保留现有配置，直接部署"
    SKIP_CONFIG=1
  fi
fi
SKIP_CONFIG=${SKIP_CONFIG:-0}

if [ "$SKIP_CONFIG" = "0" ]; then
  say ""
  say "① 对外访问方式"
  say "   1) IP 访问   —— 自签证书，客户端需装一次根证书"
  say "   2) 域名访问 —— Let's Encrypt 自动证书（需已解析 + 80/443 放行）"
  MODE_CHOICE=$(ask "选择" "1")

  if [ "$MODE_CHOICE" = "2" ]; then
    CADDY_MODE="domain"
    say ""
    say "② 域名配置"
    SITE_HOST=$(ask "域名" "")
    if [ -z "$SITE_HOST" ]; then say "✗ 域名不能为空"; exit 1; fi
    ACME_EMAIL=$(ask "证书通知邮箱（可留空）" "")
    EDGE_PORT=443
  else
    CADDY_MODE="edge"
    say ""
    say "② 访问地址"
    DETECTED_IP=$(detect_ip)
    [ -n "$DETECTED_IP" ] && say "   检测到公网 IP：$DETECTED_IP"
    SITE_HOST=$(ask "IP 或主机名" "${DETECTED_IP:-127.0.0.1}")
    ACME_EMAIL=""
    EDGE_PORT=$(ask "HTTPS 端口" "8443")
    is_number "$EDGE_PORT" || { say "✗ 端口必须是数字"; exit 1; }
  fi

  say ""
  say "③ 调试端口（应用明文入口，只为排查用）"
  HOST_PORT=$(ask "端口" "48080")
  is_number "$HOST_PORT" || { say "✗ 端口必须是数字"; exit 1; }

  SHARE_CODE_LENGTH=8
  CHANNEL_TTL_MIN=30
  MAX_VIEWERS=50
  say ""
  if yes_no "④ 要调整高级参数吗？（分享码位数 / 有效期 / 观看人数）" "n"; then
    SHARE_CODE_LENGTH=$(ask "分享码位数 (4-12)" "8")
    CHANNEL_TTL_MIN=$(ask "频道有效期（分钟）" "30")
    MAX_VIEWERS=$(ask "每频道最大观看人数" "50")
  fi
  is_number "$SHARE_CODE_LENGTH" || SHARE_CODE_LENGTH=8
  is_number "$CHANNEL_TTL_MIN" || CHANNEL_TTL_MIN=30
  is_number "$MAX_VIEWERS" || MAX_VIEWERS=50
else
  # 沿用现有 .env
  get() { sed -n "s/^$1=//p" .env 2>/dev/null | head -1; }
  SITE_HOST=$(get SITE_HOST); SITE_HOST=${SITE_HOST:-localhost}
  CADDY_MODE=$(get CADDY_MODE); CADDY_MODE=${CADDY_MODE:-edge}
  EDGE_PORT=$(get EDGE_PORT); EDGE_PORT=${EDGE_PORT:-$([ "$CADDY_MODE" = "domain" ] && echo 443 || echo 8443)}
  HOST_PORT=$(get HOST_PORT); HOST_PORT=${HOST_PORT:-48080}
  ACME_EMAIL=$(get ACME_EMAIL)
  SHARE_CODE_LENGTH=$(get SHARE_CODE_LENGTH); SHARE_CODE_LENGTH=${SHARE_CODE_LENGTH:-8}
  _ttl=$(get CHANNEL_TTL_SECONDS)
  is_number "$_ttl" || _ttl=1800
  CHANNEL_TTL_MIN=$((_ttl / 60))
  [ "$CHANNEL_TTL_MIN" -ge 1 ] || CHANNEL_TTL_MIN=30
  MAX_VIEWERS=$(get MAX_VIEWERS_PER_CHANNEL); MAX_VIEWERS=${MAX_VIEWERS:-50}
fi

SCHEME="https"
if [ "$CADDY_MODE" = "domain" ]; then
  MODE_LABEL="域名 + 自动证书"
else
  MODE_LABEL="IP + 内部 CA"
fi
say ""
hr
say "  即将部署"
hr
say "  访问方式   ${MODE_LABEL}"
say "  地址       ${SCHEME}://${SITE_HOST}$([ "$CADDY_MODE" = "edge" ] && echo ":${EDGE_PORT}")/"
say "  调试端口   ${HOST_PORT}"
say "  分享码     ${SHARE_CODE_LENGTH} 位"
say "  有效期     ${CHANNEL_TTL_MIN} 分钟"
say "  观看上限   ${MAX_VIEWERS} 人"
hr

if [ "$INTERACTIVE" = "1" ]; then
  if ! yes_no "确认开始？" "Y"; then say "已取消"; exit 0; fi
fi

# ── 写 .env ─────────────────────────────────────────────────
if [ "$SKIP_CONFIG" = "1" ]; then
  say "· 沿用现有 .env，未改写"
else
  if [ -f .env ]; then
    cp .env .env.bak.$(date +%Y%m%d%H%M%S)
  fi

  {
    echo "# 由 setup.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "# ── 对外访问 ──"
    echo "SITE_HOST=${SITE_HOST}"
    echo "EDGE_PORT=${EDGE_PORT}"
    echo "HOST_PORT=${HOST_PORT}"
    echo "CADDY_MODE=${CADDY_MODE}"
    echo "ACME_EMAIL=${ACME_EMAIL}"
    echo ""
    echo "# ── 应用参数 ──"
    echo "CHANNEL_TTL_SECONDS=$((CHANNEL_TTL_MIN * 60))"
    echo "CLEANUP_INTERVAL_SECONDS=60"
    echo "UPLOAD_RATE_LIMIT=2"
    echo "MAX_VIEWERS_PER_CHANNEL=${MAX_VIEWERS}"
    echo "MAX_TEXT_LENGTH=2000"
    echo "SHARE_CODE_LENGTH=${SHARE_CODE_LENGTH}"
    echo "MAX_CHANNELS=1000"
    echo "MAX_HISTORY=200"
    echo "VERIFY_RATE_LIMIT=60"
    echo "TRUST_PROXY=true"
  } > .env

  say "· 已写入 .env（旧文件备份为 .env.bak.*）"
fi

# ── 启动 ────────────────────────────────────────────────────
FILES="-f docker-compose.yml"
if [ "$CADDY_MODE" = "domain" ]; then
  FILES="$FILES -f docker-compose.domain.yml"
fi
FS="$FILES"

# 部署前先校验 Caddyfile，避免带着坏配置启动后陷入重启循环
CADDYFILE="./Caddyfile.edge"
if [ "$CADDY_MODE" = "domain" ]; then
  CADDYFILE="./Caddyfile.domain"
fi

say "· 校验 Caddy 配置（${CADDYFILE}）…"
if ! $DOCKER run --rm \
     -e SITE_HOST="${SITE_HOST}" \
     -e HTTPS_PORT="${EDGE_PORT}" \
     -e ACME_EMAIL="${ACME_EMAIL}" \
     -v "$(pwd)/${CADDYFILE#./}:/etc/caddy/Caddyfile:ro" \
     caddy:2-alpine \
     caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
     >"$PWD/.caddy-validate.log" 2>&1; then
  say "✗ Caddy 配置校验失败："
  sed 's/^/    /' "$PWD/.caddy-validate.log"
  exit 1
fi
say "  ✓ 配置有效"

say "· 构建并启动容器…"
# --force-recreate: 切换 IP/域名模式时必须重建，否则会残留旧的 Caddyfile 挂载
$DOCKER compose $FILES up -d --build --remove-orphans --force-recreate

say "· 等待服务就绪…"

# 1) 先确认 edge 容器真的在跑（不是 Restarting）
i=0
while [ "$i" -lt 90 ]; do
  _st=$($DOCKER compose $FS ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$1=="edge"{print $2}')
  [ "$_st" = "running" ] && break
  i=$((i + 1))
  sleep 1
done

# 2) 再验证对外 HTTPS 入口 —— 这才是用户真正访问的路径
_ok=0
i=0
while [ "$i" -lt 90 ]; do
  if curl -fsSk --max-time 3 --resolve "${SITE_HOST}:${EDGE_PORT}:127.0.0.1" \
       "https://${SITE_HOST}:${EDGE_PORT}/healthz" >/dev/null 2>&1; then
    _ok=1
    break
  fi
  i=$((i + 1))
  sleep 1
done

if [ "$_ok" != "1" ]; then
  say ""
  say "✗ 90 秒内对外入口没有就绪，最近日志："
  $DOCKER compose $FS logs --tail=60 edge 2>&1 | sed 's/^/    /'
  exit 1
fi
say ""
say "  部署完成"
hr
if [ "$CADDY_MODE" = "domain" ]; then
  say "  首页     https://${SITE_HOST}/"
  say "  上传端   https://${SITE_HOST}/upload"
  say "  观看端   https://${SITE_HOST}/view"
  say "  健康检查 https://${SITE_HOST}/healthz"
  say ""
  say "  证书由 Let's Encrypt 自动签发，首次访问可能需要等几秒。"
else
  say "  首页     https://${SITE_HOST}:${EDGE_PORT}/"
  say "  上传端   https://${SITE_HOST}:${EDGE_PORT}/upload"
  say "  观看端   https://${SITE_HOST}:${EDGE_PORT}/view"
  say "  健康检查 https://${SITE_HOST}:${EDGE_PORT}/healthz"
  say ""
  say "  摄像头需要 HTTPS，首次访问会提示证书不受信任。"
  say "  根证书下载（手机可直点）："
  say "    https://${SITE_HOST}:${EDGE_PORT}/ca.crt"
  say ""
  say "  Windows 导入："
  say "    curl -k -o liveqr-root.crt https://${SITE_HOST}:${EDGE_PORT}/ca.crt"
  say '    Import-Certificate -FilePath liveqr-root.crt -CertStoreLocation Cert:\CurrentUser\Root'
  say ""
  say "  手机：下载后到「设置 → 安全 → 安装证书 → CA 证书」；"
  say "        iOS 还需到「关于本机 → 证书信任设置」手动打开。"
fi
hr
