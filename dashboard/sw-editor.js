// Minimal service worker for Christine's Studio PWA install criteria.
// Deliberately does no caching — this dashboard is live data (Supabase
// realtime chat, comments, presence) and stale-cached responses would be
// actively wrong, not just inconvenient. A registered fetch handler is
// enough to satisfy installability; everything just passes through.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', event => event.respondWith(fetch(event.request)));
