// Real production requests, no fixture substitution. Node >= 24 and Python 3.
// npm install first to use the official @rexnow/libs adaptor and schema.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const path=require('node:path'),os=require('node:os'),{spawn,spawnSync}=require('node:child_process');
const {pathToFileURL}=require('node:url');
const dependencyRoot=process.env.REX_LIBS_ROOT||path.join(__dirname,'node_modules');
function request(url,options={}) {
 return new Promise((resolve,reject)=>{
  const child=spawn(process.env.PYTHON||'python3',[path.join(__dirname,'http-bridge.py')],{stdio:['pipe','pipe','pipe']});
  let output='',error='';child.stdout.on('data',x=>output+=x);child.stderr.on('data',x=>error+=x);
  child.on('error',reject);child.on('close',code=>{
   if(code) return reject(new Error('Transport failed; no request body is logged.'));
   try {const r=JSON.parse(output);resolve(new Response(r.bodyBase64?Buffer.from(r.bodyBase64,'base64'):r.text,{status:r.status,headers:r.headers}));}catch(e){reject(e);}
  });
  child.stdin.end(JSON.stringify({url:String(url),method:options.method||'GET',headers:options.headers||{},body:options.body}));
 });
}
(async()=>{
 const {WidgetAdaptor}=await import(pathToFileURL(path.join(dependencyRoot,'@rexnow/libs/dist/widget-adaptor.js')));
 const schemaSource=fs.readFileSync(path.join(dependencyRoot,'@rexnow/libs/dist/env.zod/index.ts'),'utf8');
 // Node's type stripping is disabled inside node_modules. This schema contains
 // only the two ZodTypeAny annotations; remove them in an isolated temp copy.
 const zodUrl=pathToFileURL(path.join(dependencyRoot,'zod/index.js')).href;
 const schemaFile=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'yqk-schema-')),'schema.mjs');
 fs.writeFileSync(schemaFile,schemaSource.replace('from "zod"',`from ${JSON.stringify(zodUrl)}`).replace(/: z\.ZodTypeAny/g,''));
 const schemas=await import(pathToFileURL(schemaFile));
 globalThis.fetch=request;
 const Widget={...WidgetAdaptor};
 // Keep official async/string storage behavior; isolate test keys from other widgets.
 const namespace='yqk-live-'+Date.now()+'.';
 Widget.storage={get:k=>WidgetAdaptor.storage.get(namespace+k),set:(k,v)=>WidgetAdaptor.storage.set(namespace+k,v)};
 const ctx=vm.createContext({console,Widget});vm.runInContext(fs.readFileSync(__dirname+'/yqk.js','utf8'),ctx);
 const report={time:new Date().toISOString(),version:ctx.WidgetMetadata.version,checks:[]};
 async function check(name,fn){const result=await fn();report.checks.push({name,result});console.log('PASS '+name+' '+JSON.stringify(result));}
 function videos(items){for(const item of items) schemas.videoItemSchema.parse(item);return items;}
 await check('official metadata schema',()=>{schemas.widgetMetadataSchema.parse(ctx.WidgetMetadata);return true;});

 for(const [channelId,genre,area] of [[2,'科幻','美国'],[3,'剧情','大陆'],[8,'动画','日本'],[10,'真人秀','大陆']]){
  await check('real combined filters '+channelId,async()=>{const r=videos(await ctx.loadFiltered({channelId,genre,area,sortType:1}));assert(r.length>0);return {channelId,genre,area,count:r.length,sample:r[0].title,flags:r[0].genreTitle};});
 }
 await check('real latest pages with array cursor',async()=>{const a=videos(await ctx.loadLatest({channelId:3,page:1})),b=videos(await ctx.loadLatest({channelId:3,page:2}));assert(a.length&&b.length);assert.notEqual(a[0].id,b[0].id);return {pageOne:a.length,pageTwo:b.length,titles:a.slice(0,3).map(x=>x.title)};});
 await check('real current-year latest movies',async()=>{const r=videos(await ctx.loadLatest({channelId:2,year:'current'}));assert(r.length);return {count:r.length,years:[...new Set(r.map(x=>x.releaseDate))]};});
 for(const channelId of [50,65,56])await check('real latest special channel '+channelId,async()=>{const r=videos(await ctx.loadLatest({channelId}));assert(r.length);return {channelId,count:r.length};});
 await check('real Netflix current collection',async()=>{const r=videos(await ctx.loadCollection({channelId:65,collection:'latest'}));assert(r.length);return {count:r.length,sample:r[0].title,flags:r[0].genreTitle};});
 for(const [keyword,target] of [['流浪地球','流浪地球2'],['庆余年','庆余年第二季']])await check('real playback '+target,async()=>{
  const r=await ctx.search({keyword});const hit=r.find(x=>x.title===target);assert(hit);const detail=await ctx.loadDetail(hit.link);schemas.videoItemSchema.parse(detail);
  try{const sources=await ctx.loadResource({link:detail.episodeItems[0].link});sources.forEach(x=>schemas.streamSourceItemSchema.parse(x));return {title:target,status:'playlists verified',resources:sources.length,source:sources[0].description};}
  catch(e){if(e.code==='RATE_LIMIT'||target==='流浪地球2'||!/已尝试 \d+ 条同片同集线路/.test(e.message))throw e;return {title:target,status:'unavailable',reason:e.message};}
 });
 report.sourceSha256=require('node:crypto').createHash('sha256').update(fs.readFileSync(__dirname+'/yqk.js')).digest('hex');
 report.note='Production filter/latest paths and playback samples checked via official adaptor/schema. Unavailable upstream playback is reported, not counted as successful playback. No native iOS test or full media decode in this run.';
 fs.writeFileSync(__dirname+'/yqk-upgrade-validation.json',JSON.stringify(report,null,2)+'\n');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
