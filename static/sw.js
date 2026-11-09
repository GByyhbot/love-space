/* 恋爱空间 Service Worker — 只缓存静态页面资源；账号数据与媒体始终在线读取。 */
/* 版本号必须与 index.html 里 style.css / app.js 的 ?v= 一致：URL 带版本参数可强制绕过一切旧缓存。
   写成常量再拼进 URL，是为了让 CORE 不可能再和 CACHE 脱钩——以前两处手写版本号，
   CACHE 已经到 v67 而 CORE 还停在 v55，预热进缓存的旧 CSS 会一直被命中。 */
const VERSION = 281;
const CACHE = `love-space-v${VERSION}`;
/* 首页封面单独一个命名空间：跨版本保留（内容由 URL 里的媒体 id 唯一决定），
   换封面时由下面 fetch 分支整桶顶替，所以永远不会攒下多张。 */
const COVER_CACHE = 'love-space-cover-v1';
/* 自有的前端 bundle。加文件时两处都要动：CORE 预热 + 下面的 network-first 判定，
   漏了 CORE 是旧 worker 拿不到新文件，漏了 network-first 是拿到上一版。
   index.html 的 <script> 与这里由 tests/test_version_consistency.py 钉住。 */
const BUNDLES = ['/static/app.js', '/static/chat.js', '/static/music.js', '/static/period.js'];
const CORE = [`/static/style.css?v=${VERSION}`, ...BUNDLES.map((p) => `${p}?v=${VERSION}`), '/static/icon.svg', '/static/icon-192.png', '/static/icon-512.png', '/static/apple-touch-icon.png', '/static/garden.svg', '/manifest.webmanifest', '/'];

self.addEventListener('install', (event) => {
  /* cache:'reload' 强制从网络拉取，防止 install 时读进 HTTP 层的旧响应。 */
  event.waitUntil(caches.open(CACHE).then((cache) => Promise.all(CORE.map((u) => cache.add(new Request(u, { cache: 'reload' })))).catch(() => {})));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE && k !== 'love-space-stickers' && k !== COVER_CACHE).map((k) => caches.delete(k)))));
  self.clients.claim();
});

self.addEventListener('push', (event) => {
  event.waitUntil((async () => {
    let payload = {};
    try { payload = event.data ? event.data.json() : {}; } catch {}
    const title = typeof payload.title === 'string' ? payload.title.slice(0, 60) : '恋爱空间';
    const body = typeof payload.body === 'string' ? payload.body.slice(0, 140) : '你有一条新的提醒，打开空间查看。';
    let target = new URL('/#notices', self.location.origin);
    try {
      const candidate = new URL(payload.url || '/#notices', self.location.origin);
      if (candidate.origin === self.location.origin) target = candidate;
    } catch {}
    await self.registration.showNotification(title, {
      body,
      icon: '/static/icon-192.png',
      badge: '/static/icon-192.png',
      tag: typeof payload.tag === 'string' ? payload.tag.slice(0, 80) : 'love-space-notice',
      data: { url: target.href },
      renotify: false,
    });
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    let target = new URL('/#notices', self.location.origin);
    try {
      const candidate = new URL(event.notification.data?.url || '/#notices', self.location.origin);
      if (candidate.origin === self.location.origin) target = candidate;
    } catch {}
    const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of clients) {
      if (new URL(client.url).origin !== self.location.origin) continue;
      if ('navigate' in client) await client.navigate(target.href);
      return client.focus();
    }
    return self.clients.openWindow(target.href);
  })());
});

// A logout can happen while this worker is controlling the page. Remove any
// sensitive entries left by older worker versions from every cache namespace.
self.addEventListener('message', (event) => {
  if (event.data?.type !== 'CLEAR_PRIVATE_CACHE') return;
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.map(async (key) => {
      const cache = await caches.open(key);
      const requests = await cache.keys();
      await Promise.all(requests.filter((request) => {
        const path = new URL(request.url).pathname;
        return path.startsWith('/api/') || path.startsWith('/media/');
      }).map((request) => cache.delete(request)));
    }));
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.pathname.toLowerCase().endsWith('.apk')) return;

  // The shell and main bundle must check the server first. A newly installed
  // worker can otherwise copy an older response from the previous worker's cache.
  if (url.origin === self.location.origin && (req.mode === 'navigate' || BUNDLES.indexOf(url.pathname) !== -1)) {
    const isShell = url.pathname === '/' || url.pathname === '/index.html';
    // 子页面导航（iframe 里的 /pose-gallery/poses 等）不走缓存、也不写缓存：
    // 以前这里对**所有**导航都用 '/' 当 cache key，于是进过一次图库，首页的缓存条目
    // 就被图库 HTML 顶替了——弱网/离线打开主站会直接变成图库页，正在跑的出图任务全断。
    if (req.mode === 'navigate' && !isShell) {
      event.respondWith(fetch(req, { cache: 'no-store' }));
      return;
    }
    event.respondWith(fetch(req, { cache: 'no-store' }).then((response) => {
      if (response.ok) {
        const key = isShell ? new Request(new URL('/', self.location.origin)) : req;
        caches.open(CACHE).then((cache) => cache.put(key, response.clone())).catch(() => {});
      }
      return response;
    }).catch(async () => (await caches.match(req)) || (await caches.match('/'))));
    return;
  }

  // 首页封面：cache-first，命中就完全不碰网络。
  // 换了封面 → URL 里的媒体 id 变了 → 必然未命中 → 拉一次并把旧条目顶掉；
  // 没换 → 一直吃本地这份，刷新一百次也不下载（原图常有几 MB，apk 里这条最省流量）。
  // 服务端对所有 /media/ 都返回 private, max-age=0, must-revalidate —— Cache API 会拒绝 no-store 的响应。
  // 非封面的附件不走 SW 缓存，交给浏览器 HTTP 缓存 + ETag 换 304。
  // 登出时 CLEAR_PRIVATE_CACHE 按 /media/ 前缀清理，会一并删掉这里。
  if (url.origin === self.location.origin && url.pathname.startsWith('/media/') && url.searchParams.get('role') === 'cover') {
    event.respondWith((async () => {
      const cache = await caches.open(COVER_CACHE);
      const hit = await cache.match(req);
      if (hit) return hit;
      const resp = await fetch(req);
      if (resp && resp.ok) {
        const olds = await cache.keys();
        await Promise.all(olds.map((k) => cache.delete(k)));
        await cache.put(req, resp.clone()).catch(() => {});
      }
      return resp;
    })());
    return;
  }

  // 贴纸包：独立命名空间缓存，跨版本保留（内容不变），命中即本地秒开
  if (url.origin === self.location.origin && url.pathname.startsWith('/static/stickers/')) {
    event.respondWith((async () => {
      const cache = await caches.open('love-space-stickers');
      const hit = await cache.match(req);
      if (hit) return hit;
      const resp = await fetch(req);
      if (resp && resp.ok) cache.put(req, resp.clone());
      return resp;
    })());
    return;
  }

  // 同源静态资源：cache-first
  if (url.origin === self.location.origin && (url.pathname.startsWith('/static/') || url.pathname === '/' || url.pathname === '/manifest.webmanifest' || url.pathname === '/health')) {
    event.respondWith(caches.match(req).then((cached) => cached || fetch(req).then((resp) => {
      const copy = resp.clone();
      caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
      return resp;
    }).catch(() => cached || caches.match('/'))));
    return;
  }

  // Authenticated APIs and media always go to the server. They must never be
  // cached because another person may use this device after logout.
});
