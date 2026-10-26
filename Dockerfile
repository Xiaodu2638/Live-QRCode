FROM node:22-alpine

WORKDIR /app

# 先只拷贝依赖清单，让 npm install 这层能命中缓存
COPY package.json ./
COPY .npmrc ./
RUN npm install --omit=dev --no-audit --no-fund

# 扫码库已随 public/vendor/jsQR.js 提交进仓库，
# 这里不再从 node_modules 里拷；挂载 public 时它会跟着一起生效
COPY server.js ./
COPY public ./public

ENV NODE_ENV=production
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
