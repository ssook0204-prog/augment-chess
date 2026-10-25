/* 증강 체스 오프라인용 서비스 워커: 인터넷이 되면 항상 최신 파일을 받고, 안 되면 저장해 둔 파일로 열어요. */
const C='ac-offline-v1';
self.addEventListener('install',e=>{self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!=C).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
 const r=e.request;if(r.method!='GET'||r.headers.get('range'))return;
 const u=new URL(r.url);if(u.origin!=location.origin||u.pathname.endsWith('/sw.js'))return;
 e.respondWith((async()=>{
  const c=await caches.open(C);
  try{
   const ctl=new AbortController(),t=setTimeout(()=>ctl.abort(),r.mode=='navigate'?4000:8000);
   const res=await fetch(r,{signal:ctl.signal,cache:'no-store'});clearTimeout(t);
   if(res&&res.ok&&res.type=='basic')c.put(r,res.clone()).catch(()=>{});
   return res;
  }catch(err){
   let m=await c.match(r,{ignoreSearch:true});
   if(!m&&r.mode=='navigate')m=await c.match(self.registration.scope)||await c.match(self.registration.scope+'index.html');
   return m||new Response('오프라인이에요. 인터넷이 되는 곳에서 한 번 열어 두면 다음부터 오프라인으로도 열려요.',{status:503,headers:{'Content-Type':'text/plain; charset=utf-8'}});
  }
 })())});
