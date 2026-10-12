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
 const {WidgetAdaptor}=await import(pathToFileURL(path.join(dependencyRoot,'@rexnow/libs/dist/widget-adaptor.js')));globalThis.fetch=request;
 const schemaFile=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'gg-live-schema-')),'schema.mjs');fs.writeFileSync(schemaFile,fs.readFileSync(path.join(dependencyRoot,'@rexnow/libs/dist/env.zod/index.ts'),'utf8').replace('from "zod"','from '+JSON.stringify(pathToFileURL(path.join(dependencyRoot,'zod/index.js')).href)).replace(/: z\.ZodTypeAny/g,''));const schemas=await import(pathToFileURL(schemaFile));
 const storage=new Map(),c=vm.createContext({Widget:{...WidgetAdaptor,storage:{get:k=>storage.get(k),set:(k,v)=>storage.set(k,v)}}});vm.runInContext(fs.readFileSync('ggduanju.js','utf8'),c);schemas.widgetMetadataSchema.parse(c.WidgetMetadata);
 const report={time:new Date().toISOString(),version:c.WidgetMetadata.version,sourceSha256:require('node:crypto').createHash('sha256').update(fs.readFileSync('ggduanju.js')).digest('hex'),checks:[],limitations:['No native iPhone import/TLS/playback test','Playlist inspected only; no full segment playback','Merged 全集 resource is one episode rather than invented episode splitting','Original API pagecount may cap catalog/search; follow returned pagecount']};
 for(const [name,fn] of [['home',()=>c.loadHome()],['short latest',()=>c.loadLatest()],['catalog page 2',()=>c.loadCatalog({category:'1',page:2})],['movie category',()=>c.loadCatalog({category:'2'})],['search',()=>c.search({keyword:'总裁'})],['search page 2',()=>c.search({keyword:'总裁',page:2})]])try{const r=await fn();assert(r.length>0);r.forEach(x=>schemas.videoItemSchema.parse(x));report.checks.push({name,passed:true,count:r.length,samples:r.slice(0,2).map(x=>x.title)});console.log('PASS '+name+' '+r.length);}catch(e){report.checks.push({name,passed:false,error:String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]')});console.log('FAIL '+name+' '+e.message);}
 try{const d=await c.loadDetail(c.ggLink(190184));schemas.videoItemSchema.parse(d);assert.equal(d.episodeItems.length,1);assert.equal(d.episodeItems[0].childItems.length,2);report.checks.push({name:'complete merged short detail',passed:true,count:1,title:d.title,lines:2});const r=await c.loadResource({link:d.episodeItems[0].link,qualityPreference:'fixed'});r.forEach(x=>schemas.streamSourceItemSchema.parse(x));assert(r[0].name.includes('魔都'));report.checks.push({name:'same-episode fallback and highest playlist',passed:true,names:r.map(x=>x.name)});console.log('PASS complete detail and fallback media');}catch(e){report.checks.push({name:'detail and media',passed:false,error:String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]')});console.log('FAIL detail and media '+e.message);}
 fs.writeFileSync('ggduanju-validation.json',JSON.stringify(report,null,2)+'\n');if(report.checks.some(x=>!x.passed))process.exitCode=1;
})().catch(e=>{console.error(e);process.exitCode=1;});
