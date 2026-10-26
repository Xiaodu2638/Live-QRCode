#!/bin/sh
# 构建并推送镜像到镜像仓库
#
#   ./publish.sh                               # 用 .env 里的 PUBLISH_IMAGE
#   ./publish.sh registry.cn-hangzhou.aliyuncs.com/your-ns/live-qrcode
#
# 会打两个 tag：latest 和 日期，例如
#   .../live-qrcode:latest
#   .../live-qrcode:20261026
set -eu
cd "$(dirname "$0")"

IMAGE=${1:-}
if [ -z "$IMAGE" ]; then
  IMAGE=$(sed -n 's/^PUBLISH_IMAGE=//p' .env 2>/dev/null | head -1)
fi
if [ -z "$IMAGE" ]; then
  echo "用法: ./publish.sh <registry>/<namespace>/<name>"
  echo "例如: ./publish.sh registry.cn-hangzhou.aliyuncs.com/myns/live-qrcode"
  exit 1
fi

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  DOCKER="sudo docker"
fi

REGISTRY=$(printf '%s' "$IMAGE" | cut -d/ -f1)
TAG_DATE=$(date +%Y%m%d)

echo "· 目标镜像: ${IMAGE}"
echo "· Registry: ${REGISTRY}"

echo "· 构建镜像…"
$DOCKER compose -f docker-compose.yml build

echo "· 打标签…"
$DOCKER tag live-qrcode-app:latest "${IMAGE}:latest"
$DOCKER tag live-qrcode-app:latest "${IMAGE}:${TAG_DATE}"

echo "· 推送（如果没登录会失败，先执行: $DOCKER login ${REGISTRY}）…"
if ! $DOCKER push "${IMAGE}:latest"; then
  echo ""
  echo "✗ 推送失败。常见原因："
  echo "  1) 没有登录：$DOCKER login ${REGISTRY}"
  echo "  2) 命名空间不存在或无推送权限"
  echo "  3) 网络不通（Docker Hub 在国内 ECS 上经常超时）"
  exit 1
fi

$DOCKER push "${IMAGE}:${TAG_DATE}"

echo ""
echo "  推送完成"
echo "    ${IMAGE}:latest"
echo "    ${IMAGE}:${TAG_DATE}"
echo ""
echo "  在别的机器上部署："
echo "    PUBLISH_IMAGE=${IMAGE}:latest \\"
echo "    docker compose -f docker-compose.yml -f docker-compose.image.yml up -d"
