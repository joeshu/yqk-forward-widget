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
 const namespace='auete-live-'+Date.now()+'.';
 Widget.storage={get:k=>WidgetAdaptor.storage.get(namespace+k),set:(k,v)=>WidgetAdaptor.storage.set(namespace+k,v)};
 function context(prefix){const ctx=vm.createContext({console,Widget});vm.runInContext(fs.readFileSync(__dirname+'/'+prefix+'.js','utf8'),ctx);schemas.widgetMetadataSchema.parse(ctx.WidgetMetadata);return ctx;}
 function videos(items){items.forEach(x=>schemas.videoItemSchema.parse(x));return items;}
 async function xiaobao(){const c=context('xiaobao'),report={time:new Date().toISOString(),version:c.WidgetMetadata.version,checks:[],limitations:['No media segments decoded','No iPhone import/playback test']};
 const home=videos(await c.loadHome());assert(home.length>0);report.checks.push({name:'real homepage',count:home.length});
 const catalogs=await Promise.allSettled(['1','2','3','4'].map(async category=>{const a=videos(await c.loadCatalog({category}));assert(a.length>0);return {name:'real category',category,count:a.length,first:a[0].title};}));for(const r of catalogs){if(r.status==='rejected')throw r.reason;report.checks.push(r.value);}
 const second=videos(await c.loadCatalog({category:'2',page:2}));assert(second.length>0);assert.notEqual(second[0].title,catalogs[1].value.first);report.checks.push({name:'real category page 2',count:second.length});
 const found=videos(await c.search({keyword:'凡人'}));assert(found.length>0);report.checks.push({name:'real search',count:found.length,first:found[0].title});
 const detail=await c.loadDetail('https://xiaoheimi.cc/index.php/vod/detail/id/2675.html');schemas.videoItemSchema.parse(detail);assert.equal(detail.episodeItems.length,36);report.checks.push({name:'real complete detail',title:detail.title,episodes:detail.episodeItems.length});
 const sources=await c.loadResource({link:detail.episodeItems[0].link,qualityPreference:'fixed'});assert(sources.length>0);sources.forEach(x=>schemas.streamSourceItemSchema.parse(x));report.checks.push({name:'real HLS main and child',count:sources.length,names:sources.map(x=>x.name)});
 fs.writeFileSync('xiaobao-validation.json',JSON.stringify(report,null,2)+'\n');console.log('PASS XiaoBao live');}
 async function anime1(){const c=context('anime1'),report={time:new Date().toISOString(),version:c.WidgetMetadata.version,checks:[],limitations:['Media HEAD only; no MP4 bytes downloaded or decoded','No iPhone import/playback test','Cookies/temporary source URLs not recorded']};
 const items=videos(await c.loadCatalog({year:'2026',season:'秋'}));assert(items.length>0);assert(items.every(x=>x.releaseDate==='2026'));report.checks.push({name:'real catalogue and year/season filter',count:items.length,first:items[0].title,rows:c.anCatalogue.rows.length});
 const latest=videos(await c.loadLatest());assert(latest.length>0);report.checks.push({name:'real recent updates',count:latest.length});
 const result=videos(await c.search({keyword:'轉生'}));assert(result.length>0);report.checks.push({name:'real search',count:result.length});
 const detail=await c.loadDetail('https://anime1.me/?cat=1974');schemas.videoItemSchema.parse(detail);assert(detail.episodeItems.length>=3);report.checks.push({name:'real complete archive',title:detail.title,count:detail.episodeItems.length});
 const sources=await c.loadResource({link:'https://anime1.me/30334'});assert(sources.length>0);sources.forEach(x=>schemas.streamSourceItemSchema.parse(x));assert(sources.every(x=>x.customHeaders.Cookie));report.checks.push({name:'real issued API plus scoped cookies plus MP4 HEAD',count:sources.length,passed:true});
 fs.writeFileSync('anime1-validation.json',JSON.stringify(report,null,2)+'\n');console.log('PASS Anime1 live');}
 const jobs=[['XiaoBao',xiaobao],['Anime1',anime1]].filter(x=>!process.env.LIVE_SOURCE||process.env.LIVE_SOURCE===x[0]);const results=await Promise.allSettled(jobs.map(x=>x[1]()));for(let i=0;i<results.length;i++)if(results[i].status==='rejected')throw new Error(jobs[i][0]+': '+String(results[i].reason.message).replace(/https?:\/\/\S+/g,'[URL omitted]'));
})().catch(e=>{console.error(String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]'));process.exitCode=1;});
