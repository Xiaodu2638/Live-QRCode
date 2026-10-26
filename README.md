# Live QRCode

把手机上的内容"扫"到另一块屏幕上 —— 一个临时的二维码信道。

手机扫码（或手输文本）→ 服务端实时中转 → 另一台设备的网页上立刻渲染成二维码，再用别的设备扫走。

```
┌─────────────┐   上传      ┌──────────────┐   WebSocket   ┌─────────────┐
│   上传端     │ ─────────► │    服务端     │ ────────────► │   观看端     │
│  扫别人的码   │ 文本+token  │  内存里的频道  │    实时推送    │ 渲染成二维码  │
└─────────────┘            └──────────────┘               └─────────────┘
```

典型用法：把手机上才有的一段登录链接搬到电脑上，或者反过来。

---

## 特性

- **三页结构** —— 首页选择、扫码上传、观看端，各自独立
- **服务端渲染二维码** —— 前端只放一个 `<img>`，零依赖，中文编码不用操心
- **扫码优先取景框** —— 先只解取景框那一块，框里没有才回退全画面
- **上传鉴权** —— 知道分享码能看，但改内容需要 `uploadToken`
- **历史记录** —— 最近 200 条，点任意一条可回看当时那张码（只在内存，刷新即失）
- **全内存** —— 没有数据库，容器重启即清空，符合"临时信道"定位
- **限流** —— 上传频率、频道查询、频道总数都可配
- **两种 HTTPS** —— IP 用内部 CA 自签，域名用 Let's Encrypt 自动证书
- **镜像 60 MB** —— 压缩后体积，运行时内存约 27 MB（app 15 + edge 11）

## 目录结构

```
.
├── server.js                     # 单进程服务：HTTP + WebSocket + 静态文件
├── public/
│   ├── index.html                # 首页：选择扫码还是观看
│   ├── upload.html               # 扫码端
│   ├── view.html                 # 观看端
│   ├── favicon.svg
│   ├── apple-touch-icon.png
│   └── vendor/jsQR.js            # 二维码解码库（内联，不依赖 CDN）
├── Dockerfile                    # 应用镜像
├── docker-compose.yml            # app + edge 两个服务
├── docker-compose.domain.yml     # 域名模式覆盖（80/443 + Caddyfile.domain）
├── docker-compose.image.yml      # 用已发布镜像部署（不本地构建）
├── Caddyfile.edge                # IP 模式：内部 CA
├── Caddyfile.domain              # 域名模式：Let's Encrypt
├── setup.sh                      # 交互式安装脚本
├── publish.sh                    # 构建并推送镜像
├── .env.example                  # 配置模板
└── README.md
```

---

## 部署

### 前置条件

| 项目 | 要求 |
|---|---|
| Docker | Engine 20+，Compose v2（`docker compose` 子命令） |
| 系统 | Linux（推荐）／ macOS ／ Windows + Docker Desktop |
| 端口 | 默认 8443（可改）；域名模式需要 80 和 443 |
| 域名（可选） | 大陆节点需 ICP 备案，且 A 记录已指向本机 |

> 当前用户不在 `docker` 组里时，`setup.sh` 会自动改用 `sudo`。

### 一条命令部署

```bash
git clone git@github.com:Xiaodu2638/Live-QRCode.git
cd Live-QRCode
./setup.sh
```

脚本依次问几个问题，**直接回车就是默认值**：

| 问题 | 默认 | 说明 |
|---|---|---|
| ① 访问方式 | `1` IP | 选 `2` 走域名 + Let's Encrypt |
| ② IP 或主机名 | 自动探测的公网 IP | 决定证书签给谁 |
| ③ HTTPS 端口 | `8443` | 域名模式固定 443 |
| ④ 调试端口 | `48080` | 应用明文入口，仅供排查 |
| ⑤ 高级参数 | 不调整 | 分享码位数 / 频道有效期 / 观看人数上限 |

确认后会打印配置清单，然后自动完成：生成 `.env` → 构建镜像 → 启动容器 → 等待健康检查 → 输出访问地址。

**非交互模式**（适合脚本化）：

```bash
./setup.sh --yes     # 全用默认值；已有 .env 时直接沿用，不覆盖
./setup.sh --help
```

### 部署完成后

输出类似：

```
  部署完成
────────────────────────────────────────────
  首页     https://203.0.113.10:8443/
  上传端   https://203.0.113.10:8443/upload
  观看端   https://203.0.113.10:8443/view
  健康检查 https://203.0.113.10:8443/healthz

  根证书下载（手机可直点）：
    https://203.0.113.10:8443/ca.crt
```

### 安装根证书（IP 模式必须）

**为什么必须装**：浏览器只在**安全上下文**（`https://` 或 `localhost`）下允许调用摄像头。IP 模式用的是自签证书，不装根证书浏览器会拦，扫码功能直接不可用。

**下载**：`https://<你的IP>:8443/ca.crt`

| 平台 | 步骤 |
|---|---|
| **Windows** | 双击 `.crt` → 安装证书 → 本地计算机 → 放入「受信任的根证书颁发机构」。或用 PowerShell：<br>`Import-Certificate -FilePath ca.crt -CertStoreLocation Cert:\CurrentUser\Root` |
| **macOS** | 双击导入「钥匙串」→ 找到证书 → 双击 → 信任 → 始终信任 |
| **Android** | 设置 → 安全 → 加密与凭据 → 安装证书 → **CA 证书** |
| **iOS** | 下载后到「设置」安装描述文件，**再到「通用 → 关于本机 → 证书信任设置」手动打开开关**（这步最容易漏） |

根证书有效期 10 年，站点证书 12 小时自动续期，装一次即可。

> 微信内置浏览器不认自签证书，也没有"继续前往"按钮。请用系统浏览器或相机扫码打开。

### 用已发布的镜像部署

不想 clone 代码，可以直接用公开镜像（**拉取无需登录**）：

```bash
curl -fsSLO https://raw.githubusercontent.com/Xiaodu2638/Live-QRCode/main/docker-compose.yml
curl -fsSLO https://raw.githubusercontent.com/Xiaodu2638/Live-QRCode/main/docker-compose.image.yml
curl -fsSLO https://raw.githubusercontent.com/Xiaodu2638/Live-QRCode/main/Caddyfile.edge

export PUBLISH_IMAGE=crpi-xqw99hsrxtt1g9fq.cn-beijing.personal.cr.aliyuncs.com/liveqrcode/live-qrcode:latest
export SITE_HOST=你的公网IP

docker compose -f docker-compose.yml -f docker-compose.image.yml up -d
```

`docker-compose.image.yml` 会把 `build:` 和源码挂载整个去掉，只用镜像里的代码。

---

## 域名模式

`setup.sh` 里选 `2) 域名访问` 即可。手动配置等价于：

```bash
# .env
SITE_HOST=qr.example.com
ACME_EMAIL=you@example.com

docker compose -f docker-compose.yml -f docker-compose.domain.yml up -d
```

`docker-compose.domain.yml` 会**整体替换**两样东西：

- 端口映射 → `80:80` + `443:443`
- Caddyfile → `Caddyfile.domain`

所以不需要再改其他文件。`Caddyfile.domain` 里没有 `tls internal`、也没有 `default_sni`：有域名就有 SNI，证书由 Let's Encrypt 自动申请和续期，**客户端不用装任何证书**。

> `!override` 语法需要 Compose ≥ 2.24。

---

## 配置

所有可变项集中在 `.env`，仓库只放模板：

```bash
cp .env.example .env
docker compose up -d --build
```

| 变量 | 默认 | 作用 |
|---|---|---|
| `SITE_HOST` | 必填 | 对外访问用的 IP 或域名，决定证书签给谁 |
| `EDGE_PORT` | `8443` | 宿主机映射到 edge 的端口（容器内固定 8443） |
| `HOST_PORT` | `48080` | 宿主机映射到 app 的端口，仅调试用 |
| `CHANNEL_TTL_SECONDS` | `1800` | 频道无上传多久后过期（60–86400） |
| `CLEANUP_INTERVAL_SECONDS` | `60` | 后台清理间隔（10–3600） |
| `UPLOAD_RATE_LIMIT` | `2` | 每频道每秒最大上传次数（1–100） |
| `MAX_VIEWERS_PER_CHANNEL` | `50` | 每频道最大观看者（1–500） |
| `MAX_TEXT_LENGTH` | `2000` | 单次上传文本最大字符数（1–10000） |
| `SHARE_CODE_LENGTH` | `8` | 分享码位数（4–12），越短越好念但越易被猜 |
| `MAX_CHANNELS` | `1000` | 同时存在的频道上限，超出返回 `503` |
| `MAX_HISTORY` | `200` | 每频道保留的历史条数 |
| `VERIFY_RATE_LIMIT` | `60` | 每 IP 每分钟允许的频道查询/连接次数，超出返回 `429` |
| `TRUST_PROXY` | `true` | 是否信任 `X-Forwarded-For`。走 Caddy 必须为 `true` |
| `ACME_EMAIL` | — | 域名模式下的证书通知邮箱 |
| `PORT` | `3000` | 容器内监听端口，一般不用改 |

应用参数越界会在启动时直接失败，并打印具体哪一项不对。

改完 `.env` 后必须 `docker compose up -d --force-recreate` —— `restart` 不会重新读取环境变量。`.env` 已在 `.gitignore` 里，不会进版本库。

### 改哪些文件不用重建

`docker-compose.yml` 把代码挂载进了容器：

| 改的文件 | 生效方式 |
|---|---|
| `public/*.html`、`public/vendor/*` | 保存即可，浏览器刷新就生效 |
| `server.js` | `docker compose restart app` |
| `Caddyfile.*` | `docker compose restart edge` |
| `.env` | `docker compose up -d --force-recreate app` |
| `docker-compose.yml` 本身 | `docker compose up -d` |
| `Dockerfile` / `package.json` | `docker compose up -d --build` |

挂载是只读的（`:ro`），容器里改不了源文件。镜像本身也含完整代码，所以不做挂载也能独立运行。

---

## 架构

```
浏览器 ──TLS──► edge (caddy:2-alpine :8443) ──► app (node :3000)
```

- **app** 只跑业务，完全不知道 TLS 的存在，监听 3000
- **edge** 只做 TLS 终结和反向代理，改了配置只重启它
- 两者在同一个 compose 网络里，edge 通过 service 名 `app:3000` 访问后端

这样换证书、换反向代理都不需要重新构建应用镜像。

---

## 常用命令

```bash
# 状态 / 日志
sudo docker compose ps
sudo docker compose logs -f app

# 改完 server.js
sudo docker compose restart app

# 改完 .env
sudo docker compose up -d --force-recreate app

# 重新部署（重建容器）
./setup.sh

# 重新发布镜像
sudo docker login crpi-xqw99hsrxtt1g9fq.cn-beijing.personal.cr.aliyuncs.com -u <你的ACR用户名>
sudo ./publish.sh
```

---

## HTTP 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| `POST` | `/api/channel` | 新建频道，返回 `{code, uploadToken}` |
| `GET` | `/api/channel/:code` | 校验频道是否存在 |
| `POST` | `/api/channel/:code/upload` | 上传文本，需要 `x-upload-token` 头 |
| `GET` | `/api/channel/:code/qr.svg` | 二维码 SVG，`?seq=N` 取第 N 条历史 |
| `GET` | `/ws?code=:code` | WebSocket，观看端订阅 |
| `GET` | `/healthz` | 状态摘要 |

上传需要 token、观看只需要 code —— 知道分享码的人能看，但不能往你的频道里塞内容。

WebSocket 消息格式：

```jsonc
// 服务端 → 客户端
{ "type": "init",    "text": "...", "seq": 3, "history": [ ... ] }
{ "type": "update",  "text": "...", "seq": 4, "at": 1793000000000 }
{ "type": "expired", "reason": "expired" }
```

---

## 已知限制

- **状态在内存** —— 容器重启后所有频道失效（这是设计，不是缺陷）
- **单实例** —— 不能水平扩容，多副本之间不共享频道
- **过期判定** —— "最后一次上传 + TTL"，长时间无人上传会被回收
- **分享码空间** —— 8 位数字共 1 亿种，配合 `VERIFY_RATE_LIMIT` 防穷举；想更安全可把位数调到 10–12

---

## 第三方组件

- **[jsQR](https://github.com/cozmo/jsQR)** — 前端二维码解码，Apache-2.0，以 `public/vendor/jsQR.js` 内联分发
- **[qrcode](https://github.com/soldair/node-qrcode)** — 服务端生成二维码，MIT
- **[ws](https://github.com/websockets/ws)** — WebSocket 服务端，MIT

## 许可证

[GNU Affero General Public License v3.0](LICENSE)。

与 GPL 的区别在第 13 条：**如果你把修改后的版本作为网络服务提供给别人使用，也必须向使用者提供完整源代码。**

交互设计参考了 [Dynesshely/Live-QR](https://github.com/Dynesshely/Live-QR)，代码为独立实现。
