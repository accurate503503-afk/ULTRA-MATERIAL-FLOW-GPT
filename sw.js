const CACHE='ultra503-shell-v1';
const SHELL=['./','./index.html','./styles.css','./app.js','./config.js','./manifest.webmanifest'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k))))));
self.addEventListener('fetch',e=>{
  const u=new URL(e.request.url);
  // Never cache or intercept Supabase/Auth/PostgREST/Storage or any cross-origin request.
  if(u.origin!==self.location.origin)return;
  e.respondWith(caches.match(e.request).then(cached=>cached||fetch(e.request).then(res=>{if(e.request.method==='GET'&&res.ok){let copy=res.clone();caches.open(CACHE).then(c=>c.put(e.request,copy))}return res})));
});
