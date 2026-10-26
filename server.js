'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const QRCode = require('qrcode');
const { WebSocketServer } = require('ws');

const PORT = Number(process.env.PORT || 3000);
const CHANNEL_TTL_SECONDS = Number(process.env.CHANNEL_TTL_SECONDS || 1800);
const CLEANUP_INTERVAL_SECONDS = Number(process.env.CLEANUP_INTERVAL_SECONDS || 60);
const UPLOAD_RATE_LIMIT = Number(process.env.UPLOAD_RATE_LIMIT || 2);
const MAX_VIEWERS_PER_CHANNEL = Number(process.env.MAX_VIEWERS_PER_CHANNEL || 50);
const MAX_TEXT_LENGTH = Number(process.env.MAX_TEXT_LENGTH || 2000);

// 分享码位数：4–12。位数越短越好念，但可猜测空间越小
const SHARE_CODE_LENGTH = Math.min(12, Math.max(4, Number(process.env.SHARE_CODE_LENGTH || 8)));
// 同时存在的频道上限，防止内存被打满
const MAX_CHANNELS = Math.max(1, Number(process.env.MAX_CHANNELS || 1000));
// 每个频道保留多少条历史
const MAX_HISTORY = Math.max(1, Number(process.env.MAX_HISTORY || 200));
// 每个 IP 每分钟允许查询/连接多少次（防枚举分享码）
const VERIFY_RATE_LIMIT = Math.max(1, Number(process.env.VERIFY_RATE_LIMIT || 60));
// 是否信任反向代理传来的 X-Forwarded-For
const TRUST_PROXY = String(process.env.TRUST_PROXY || 'true').toLowerCase() !== 'false';

const CODE_SPACE = 10 ** SHARE_CODE_LENGTH;
const RE_CHANNEL = new RegExp(`^\\/api\\/channel\\/(\\d{${SHARE_CODE_LENGTH}})$`);
const RE_UPLOAD = new RegExp(`^\\/api\\/channel\\/(\\d{${SHARE_CODE_LENGTH}})\\/upload$`);
const RE_QR = new RegExp(`^\\/api\\/channel\\/(\\d{${SHARE_CODE_LENGTH}})\\/qr\\.svg$`);

const PUBLIC_DIR = path.join(__dirname, 'public');
const startedAt = Date.now();

/** @type {Map<string, {code:string, token:string, text:string, updatedAt:number, viewers:Set, uploads:number[]}>} */
const channels = new Map();

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  });
  res.end(body);
}

function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        req.pause();
        reject(Object.assign(new Error('payload too large'), { status: 413 }));
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function newCode() {
  for (;;) {
    const code = String(crypto.randomInt(0, CODE_SPACE)).padStart(SHARE_CODE_LENGTH, '0');
    if (!channels.has(code)) return code;
  }
}

// ── 每 IP 的验证限流（防止穷举分享码）──

const verifyHits = new Map(); // ip -> { count, resetAt }

function clientIp(req) {
  if (TRUST_PROXY) {
    const xff = req.headers['x-forwarded-for'];
    if (typeof xff === 'string' && xff.length > 0) return xff.split(',')[0].trim();
  }
  return req.socket.remoteAddress || 'unknown';
}

function allowVerify(req) {
  const ip = clientIp(req);
  const now = Date.now();
  const hit = verifyHits.get(ip);
  if (!hit || now > hit.resetAt) {
    verifyHits.set(ip, { count: 1, resetAt: now + 60000 });
    return true;
  }
  if (hit.count >= VERIFY_RATE_LIMIT) return false;
  hit.count += 1;
  return true;
}

function isExpired(ch) {
  return Date.now() - ch.updatedAt > CHANNEL_TTL_SECONDS * 1000;
}

function dropChannel(code, reason) {
  const ch = channels.get(code);
  if (!ch) return;
  for (const ws of ch.viewers) {
    try {
      ws.send(JSON.stringify({ type: 'expired', reason }));
      ws.close();
    } catch {
      /* ignore */
    }
  }
  channels.delete(code);
}

function broadcast(ch, payload) {
  const data = JSON.stringify(payload);
  for (const ws of ch.viewers) {
    if (ws.readyState === ws.OPEN) ws.send(data);
  }
}

function checkToken(expected, given) {
  if (typeof given !== 'string') return false;
  const a = Buffer.from(expected);
  const b = Buffer.from(given);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function allowUpload(ch) {
  const now = Date.now();
  ch.uploads = ch.uploads.filter((t) => now - t < 1000);
  if (ch.uploads.length >= UPLOAD_RATE_LIMIT) return false;
  ch.uploads.push(now);
  return true;
}

function serveStatic(req, res, urlPath) {
  const rel = urlPath === '/' ? '/index.html' : urlPath;
  const target = path.join(PUBLIC_DIR, path.normalize(rel));
  if (!target.startsWith(PUBLIC_DIR)) {
    sendJson(res, 403, { error: 'forbidden' });
    return;
  }
  fs.stat(target, (err, stat) => {
    if (err || !stat.isFile()) {
      // 两个子页面：/view 和 /upload
      if (rel === '/view' || rel === '/view/') {
        fs.createReadStream(path.join(PUBLIC_DIR, 'view.html'))
          .on('error', () => sendJson(res, 500, { error: 'view page missing' }))
          .pipe(res.writeHead(200, { 'content-type': MIME['.html'] }));
        return;
      }
      if (rel === '/upload' || rel === '/upload/') {
        fs.createReadStream(path.join(PUBLIC_DIR, 'upload.html'))
          .on('error', () => sendJson(res, 500, { error: 'upload page missing' }))
          .pipe(res.writeHead(200, { 'content-type': MIME['.html'] }));
        return;
      }
      // 只有这三个页面，其余未知路径一律 404，不再回退到 index
      sendJson(res, 404, { error: 'not found' });
      return;
    }
    const type = MIME[path.extname(target).toLowerCase()] || 'application/octet-stream';
    res.writeHead(200, { 'content-type': type, 'content-length': stat.size });
    if (req.method === 'HEAD') return res.end();
    fs.createReadStream(target).pipe(res);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const { pathname } = url;

  try {
    if (pathname === '/healthz') {
      return sendJson(res, 200, {
        status: 'ok',
        uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
        port: PORT,
        channels: channels.size,
        ttlSeconds: CHANNEL_TTL_SECONDS,
        codeLength: SHARE_CODE_LENGTH,
        limits: {
          uploadRatePerSecond: UPLOAD_RATE_LIMIT,
          maxViewersPerChannel: MAX_VIEWERS_PER_CHANNEL,
          maxTextLength: MAX_TEXT_LENGTH,
          maxChannels: MAX_CHANNELS,
          maxHistory: MAX_HISTORY,
          verifyRatePerMinute: VERIFY_RATE_LIMIT,
        },
      });
    }

    if (pathname === '/api/channel' && req.method === 'POST') {
      if (channels.size >= MAX_CHANNELS) {
        return sendJson(res, 503, { error: 'CHANNEL_LIMIT_REACHED', max: MAX_CHANNELS });
      }
      const code = newCode();
      const token = crypto.randomBytes(16).toString('hex');
      channels.set(code, {
        code,
        token,
        text: '',
        seq: 0,
        updatedAt: Date.now(),
        viewers: new Set(),
        uploads: [],
        history: [],
      });
      return sendJson(res, 201, {
        code,
        uploadToken: token,
        expiresInSeconds: CHANNEL_TTL_SECONDS,
      });
    }

    const verifyMatch = pathname.match(RE_CHANNEL);
    if (verifyMatch && req.method === 'GET') {
      if (!allowVerify(req)) {
        return sendJson(res, 429, { error: 'VERIFY_RATE_LIMITED', retryAfterSeconds: 60 });
      }
      const code = verifyMatch[1];
      const ch = channels.get(code);
      if (!ch || isExpired(ch)) {
        if (ch) dropChannel(code, 'expired');
        return sendJson(res, 404, { error: 'CHANNEL_NOT_FOUND' });
      }
      return sendJson(res, 200, { code, hasText: ch.text.length > 0, viewers: ch.viewers.size });
    }

    const qrMatch = pathname.match(RE_QR);
    if (qrMatch && req.method === 'GET') {
      const code = qrMatch[1];
      const ch = channels.get(code);
      if (!ch || isExpired(ch)) {
        if (ch) dropChannel(code, 'expired');
        return sendJson(res, 404, { error: 'CHANNEL_NOT_FOUND' });
      }
      if (!ch.text) return sendJson(res, 404, { error: 'NO_TEXT' });

      // ?seq=N 渲染历史里第 N 条；不带该参数则渲染最新内容。
      // 历史正文只存在服务端内存，客户端点开时按序号现取，不落本地。
      let qrText = ch.text;
      const seqParam = url.searchParams.get('seq');
      if (seqParam !== null) {
        const seq = Number(seqParam);
        const entry = ch.history.find((item) => item.seq === seq);
        if (!entry) return sendJson(res, 404, { error: 'HISTORY_NOT_FOUND' });
        qrText = entry.text;
      }

      try {
        const svg = await QRCode.toString(qrText, {
          type: 'svg',
          margin: 1,
          width: 512,
          errorCorrectionLevel: 'M',
        });
        res.writeHead(200, {
          'content-type': 'image/svg+xml; charset=utf-8',
          'cache-control': 'no-store',
        });
        return res.end(svg);
      } catch (err) {
        return sendJson(res, 500, { error: 'QR_RENDER_FAILED', message: err.message });
      }
    }

    const uploadMatch = pathname.match(RE_UPLOAD);
    if (uploadMatch && req.method === 'POST') {
      const code = uploadMatch[1];
      const ch = channels.get(code);
      if (!ch || isExpired(ch)) {
        if (ch) dropChannel(code, 'expired');
        return sendJson(res, 404, { error: 'CHANNEL_NOT_FOUND' });
      }
      if (!checkToken(ch.token, req.headers['x-upload-token'])) {
        return sendJson(res, 403, { error: 'INVALID_UPLOAD_TOKEN' });
      }
      const raw = await readBody(req);
      let text = '';
      try {
        const parsed = JSON.parse(raw || '{}');
        text = typeof parsed.text === 'string' ? parsed.text : '';
      } catch {
        return sendJson(res, 400, { error: 'INVALID_JSON' });
      }
      if (text.trim().length === 0) return sendJson(res, 400, { error: 'TEXT_EMPTY' });
      if (text.length > MAX_TEXT_LENGTH) return sendJson(res, 400, { error: 'TEXT_TOO_LONG' });
      if (!allowUpload(ch)) return sendJson(res, 429, { error: 'RATE_LIMITED' });

      ch.text = text;
      ch.updatedAt = Date.now();
      ch.seq += 1;
      ch.history.push({ seq: ch.seq, text, at: ch.updatedAt });
      if (ch.history.length > MAX_HISTORY) ch.history.shift();
      broadcast(ch, { type: 'update', seq: ch.seq, text, at: ch.updatedAt });
      return sendJson(res, 200, { ok: true, viewers: ch.viewers.size });
    }

    if (req.method === 'GET' || req.method === 'HEAD') {
      return serveStatic(req, res, pathname);
    }

    return sendJson(res, 405, { error: 'method not allowed' });
  } catch (err) {
    const status = err && err.status ? err.status : 500;
    return sendJson(res, status, { error: err && err.message ? err.message : 'internal error' });
  }
});

const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  if (url.pathname !== '/ws') {
    socket.destroy();
    return;
  }
  const code = url.searchParams.get('code') || '';
  if (!new RegExp(`^\\d{${SHARE_CODE_LENGTH}}$`).test(code)) {
    socket.write('HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n');
    socket.destroy();
    return;
  }
  if (!allowVerify(req)) {
    socket.write('HTTP/1.1 429 Too Many Requests\r\nretry-after: 60\r\ncontent-length: 0\r\n\r\n');
    socket.destroy();
    return;
  }
  const ch = channels.get(code);
  if (!ch || isExpired(ch)) {
    socket.write('HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n');
    socket.destroy();
    return;
  }
  if (ch.viewers.size >= MAX_VIEWERS_PER_CHANNEL) {
    socket.write('HTTP/1.1 429 Too Many Requests\r\ncontent-length: 0\r\n\r\n');
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    ch.viewers.add(ws);
    ws.isAlive = true;
    ws.on('pong', () => {
      ws.isAlive = true;
    });
    ws.on('close', () => ch.viewers.delete(ws));
    ws.on('error', () => ch.viewers.delete(ws));
    ws.send(JSON.stringify({
      type: 'init',
      text: ch.text,
      seq: ch.seq,
      at: ch.updatedAt,
      history: ch.history,
      ttlSeconds: CHANNEL_TTL_SECONDS,
    }));
  });
});

const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.isAlive === false) {
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    try {
      ws.ping();
    } catch {
      /* ignore */
    }
  }
}, 30000);

const cleaner = setInterval(() => {
  for (const [code, ch] of channels) {
    if (isExpired(ch)) dropChannel(code, 'expired');
  }
  // 顺手清掉过期的限流窗口，避免 Map 无限增长
  const now = Date.now();
  for (const [ip, hit] of verifyHits) {
    if (now > hit.resetAt) verifyHits.delete(ip);
  }
}, CLEANUP_INTERVAL_SECONDS * 1000);

function shutdown(signal) {
  console.log(JSON.stringify({ event: 'shutdown', signal }));
  clearInterval(heartbeat);
  clearInterval(cleaner);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

server.listen(PORT, '0.0.0.0', () => {
  console.log(
    JSON.stringify({
      event: 'server_start',
      listen: `0.0.0.0:${PORT}`,
      ttlSeconds: CHANNEL_TTL_SECONDS,
      hint: '摄像头需要 HTTPS 或 localhost，http:// 下无法调起 getUserMedia',
    })
  );
});

