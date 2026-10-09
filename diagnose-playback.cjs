// Read-only production diagnosis. No signed URLs or request identities are logged.
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),{spawn}=require('node:child_process'),{pathToFileURL}=require('node:url');
function transport(url,options={}){return new Promise((resolve,reject)=>{
 const p=spawn('python3',[path.join(__dirname,'http-bridge.py')],{stdio:['pipe','pipe','pipe']});let s='';p.stdout.on('data',x=>s+=x);p.stderr.on('data',()=>{});p.on('error',reject);
 p.on('close',code=>{try{if(code)throw Error('Transport failed');const r=JSON.parse(s);resolve(new Response(r.text,{status:r.status,headers:r.headers}));}catch(e){reject(e);}});
 p.stdin.end(JSON.stringify({url:String(url),method:options.method||'GET',headers:options.headers||{},body:options.body}));
});}
(async()=>{
 globalThis.fetch=transport;
 const {WidgetAdaptor}=await import(pathToFileURL(path.join(__dirname,'node_modules/@rexnow/libs/dist/widget-adaptor.js')));
 const prefix='yqk-diagnose-'+Date.now()+'.',Widget={...WidgetAdaptor,storage:{get:k=>WidgetAdaptor.storage.get(prefix+k),set:(k,v)=>WidgetAdaptor.storage.set(prefix+k,v)}};
 const ctx=vm.createContext({console,Widget});vm.runInContext(fs.readFileSync(__dirname+'/yqk.js','utf8'),ctx);
 const root=await ctx.loadDetail('https://m.yqk3hxe.com/play/118292');
 console.log(JSON.stringify({version:ctx.WidgetMetadata.version,title:root.title,sources:root.childItems.map(x=>({title:x.title,link:x.link}))}));
 const results=[];
 for(const source of root.childItems.slice(0,5)) {
  try {
   const detail=await ctx.loadDetail(source.link),resources=await ctx.loadResource({link:detail.episodeItems[0].link});
   const resource=resources[0],base=await Widget.http.get(resource.url,{headers:resource.customHeaders});
   const record={source:source.title,status:base.statusCode,hls:String(base.data).startsWith('#EXTM3U')};
   if(base.statusCode!==200){const phone=await Widget.http.get(resource.url,{headers:{...resource.customHeaders,'User-Agent':'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148'}});record.phoneStatus=phone.statusCode;record.phoneHls=String(phone.data).startsWith('#EXTM3U');}
   results.push(record);console.log(JSON.stringify(record));
  }catch(e){const record={source:source.title,error:e.message};results.push(record);console.log(JSON.stringify(record));}
 }
 fs.writeFileSync(__dirname+'/playback-diagnosis.json',JSON.stringify({time:new Date().toISOString(),version:ctx.WidgetMetadata.version,results},null,2)+'\n');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
