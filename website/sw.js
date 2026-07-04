/* Quenderin marketing site — service worker.
 * Network-first with a same-origin cache fallback: online visitors always get fresh content,
 * and once you've loaded the site it keeps working with no connection — fitting for an
 * offline-first product. Same-origin only, so the "nothing loads from a third party" promise holds. */
var CACHE = "quenderin-v2";

self.addEventListener("install", function () {
  self.skipWaiting();
});

self.addEventListener("activate", function (e) {
  e.waitUntil(
    caches.keys()
      .then(function (keys) {
        return Promise.all(keys.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); }));
      })
      .then(function () { return self.clients.claim(); })
  );
});

self.addEventListener("fetch", function (e) {
  if (e.request.method !== "GET") return;
  if (new URL(e.request.url).origin !== location.origin) return; // first-party only
  e.respondWith(
    fetch(e.request)
      .then(function (res) {
        // Cache ONLY a genuine same-origin 200. Caching an error page (404/500), a redirect, or an
        // opaque response would pin it as the offline fallback — stale-error poisoning (audit re-sweep).
        if (res && res.ok && res.status === 200 && res.type === "basic") {
          var copy = res.clone();
          caches.open(CACHE).then(function (c) { c.put(e.request, copy); });
        }
        return res;
      })
      .catch(function () {
        return caches.match(e.request).then(function (cached) {
          return cached || (e.request.mode === "navigate" ? caches.match("./") : Response.error());
        });
      })
  );
});
