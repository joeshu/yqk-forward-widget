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
 const ctx=vm.createContext({console,Widget});vm.runInContext(fs.readFileSync(__dirname+'/auete.js','utf8'),ctx);

 const report={time:new Date().toISOString(),version:ctx.WidgetMetadata.version,checks:[],limitations:['No media segment download/decoding check','No iPhone import or playback test','Search may require original-site CAPTCHA; no automatic solving or browser-session sharing']};
 schemas.widgetMetadataSchema.parse(ctx.WidgetMetadata);report.checks.push({name:'official metadata',passed:true});
 const site='https://www.aeete.com';
 function videos(items){for(const x of items)schemas.videoItemSchema.parse(x);return items;}
 const requests=await Promise.allSettled(['Movie','Tv','Dm','Zy','qita'].map(async(category)=>{const items=videos(await ctx.loadCatalog({site,category}));assert(items.length>0);return {name:'real category',category,count:items.length,first:items[0].title};}));
 for(const r of requests){if(r.status==='rejected')throw r.reason;report.checks.push(r.value);console.log('PASS '+JSON.stringify(r.value));}
 const page2=videos(await ctx.loadCatalog({site,category:'Movie',page:2}));assert(page2.length>0);assert.notEqual(page2[0].title,requests[0].value.first);report.checks.push({name:'real movie page 2',count:page2.length,first:page2[0].title});
 const home=videos(await ctx.loadHome({site}));assert(home.length>0);report.checks.push({name:'real homepage',count:home.length});
 for(const list of ['new','hot']){const items=videos(await ctx.loadLatest({site,list}));assert(items.length>0);report.checks.push({name:'real latest/hot',list,count:items.length});}
 try{const result=videos(await ctx.search({site,keyword:'凡人修仙传'}));report.checks.push({name:'real search',count:result.length});}catch(e){assert.match(e.message,/验证码/);report.checks.push({name:'real search CAPTCHA explicitly reported',passed:true});}
 const detail=await ctx.loadDetail(site+'/Tv/wangju/leitingling/');schemas.videoItemSchema.parse(detail);assert(detail.episodeItems.length>=26);report.checks.push({name:'real complete detail',title:detail.title,count:detail.episodeItems.length,alternatives:detail.episodeItems[0].childItems.length});
 const playback=await ctx.loadResource({link:site+'/Tv/wangju/leitingling/play-0-0.html',qualityPreference:'fixed'});assert(playback.length>0);playback.forEach(x=>schemas.streamSourceItemSchema.parse(x));report.checks.push({name:'real same-episode HLS',passed:true,count:playback.length,names:playback.map(x=>x.name)});
 fs.writeFileSync(__dirname+'/auete-validation.json',JSON.stringify(report,null,2)+'\n');console.log('PASS Auete live and official schemas');
})().catch(e=>{console.error(String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]'));process.exitCode=1;});
