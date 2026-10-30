/* 恋爱空间 Service Worker — 只缓存静态页面资源；账号数据与媒体始终在线读取。 */
/* 版本号必须与 index.html 里 style.css / app.js 的 ?v= 一致：URL 带版本参数可强制绕过一切旧缓存。
   写成常量再拼进 URL，是为了让 CORE 不可能再和 CACHE 脱钩——以前两处手写版本号，
   CACHE 已经到 v67 而 CORE 还停在 v55，预热进缓存的旧 CSS 会一直被命中。 */
const VERSION = 151;
const CACHE = `love-space-v${VERSION}`;
const CORE = [`/static/style.css?v=${VERSION}`, `/static/app.js?v=${VERSION}`, '/static/icon.svg', '/static/icon-192.png', '/static/icon-512.png', '/static/apple-touch-icon.png', '/static/garden.svg', '/manifest.webmanifest', '/'];

self.addEventListener('install', (event) => {
  /* cache:'reload' 强制从网络拉取，防止 install 时读进 HTTP 层的旧响应。 */
  event.waitUntil(caches.open(CACHE).then((cache) => Promise.all(CORE.map((u) => cache.add(new Request(u, { cache: 'reload' })))).catch(() => {})));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE && k !== 'love-space-stickers').map((k) => caches.delete(k)))));
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
  if (url.origin === self.location.origin && (req.mode === 'navigate' || url.pathname === '/static/app.js')) {
    event.respondWith(fetch(req, { cache: 'no-store' }).then((response) => {
      if (response.ok) {
        const key = req.mode === 'navigate' ? new Request(new URL('/', self.location.origin)) : req;
        caches.open(CACHE).then((cache) => cache.put(key, response.clone())).catch(() => {});
      }
      return response;
    }).catch(async () => (await caches.match(req)) || (await caches.match('/'))));
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
