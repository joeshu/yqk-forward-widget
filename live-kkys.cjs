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
 const schemaFile=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'kk-live-schema-')),'schema.mjs');fs.writeFileSync(schemaFile,fs.readFileSync(path.join(dependencyRoot,'@rexnow/libs/dist/env.zod/index.ts'),'utf8').replace('from "zod"','from '+JSON.stringify(pathToFileURL(path.join(dependencyRoot,'zod/index.js')).href)).replace(/: z\.ZodTypeAny/g,''));const schemas=await import(pathToFileURL(schemaFile));
 const storage=new Map(),c=vm.createContext({Widget:{...WidgetAdaptor,storage:{get:k=>storage.get(k),set:(k,v)=>storage.set(k,v)}}});vm.runInContext(fs.readFileSync('kkys.js','utf8'),c);schemas.widgetMetadataSchema.parse(c.WidgetMetadata);
 const report={time:new Date().toISOString(),version:c.WidgetMetadata.version,sourceSha256:require('node:crypto').createHash('sha256').update(fs.readFileSync('kkys.js')).digest('hex'),checks:[],limitations:['No native iPhone TLS/import/playback test','Device mode returns original media candidate, not proven playback','No third-party TVBox webpage parser; blank source fails explicitly','Keep original 4K label, not a claim of measured 4K','Follow actual next links, at most 20 pages per request']};
 for(const [name,fn] of [['home',()=>c.loadHome()],['latest',()=>c.loadLatest()],['latest page 2',()=>c.loadLatest({page:2})],['movie catalog page 2',()=>c.loadCatalog({category:'1',page:2})],['animation catalog',()=>c.loadCatalog({category:'3'})],['series category page 2',()=>c.loadCatalog({category:'2',page:2})],['variety category page 2',()=>c.loadCatalog({category:'4',page:2})],['short category page 2',()=>c.loadCatalog({category:'6',page:2})],['search',()=>c.search({keyword:'凡人修仙传'})],['search page 2',()=>c.search({keyword:'凡人修仙传',page:2})],['original IP homepage',()=>c.loadHome({origin:c.KK_IP})]])try{const r=await fn();assert(r.length>0);r.forEach(x=>schemas.videoItemSchema.parse(x));report.checks.push({name,passed:true,count:r.length,samples:r.slice(0,2).map(x=>x.title)});console.log('PASS '+name+' '+r.length);}catch(e){report.checks.push({name,passed:false,error:String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]')});console.log('FAIL '+name+' '+e.message);}
 try{const d=await c.loadDetail(c.KK_SITE+'/detail/26654.html');schemas.videoItemSchema.parse(d);assert.equal(d.episodeItems.length,195);assert(d.episodeItems[194].childItems.some(x=>x.title.startsWith('4K')));report.checks.push({name:'full 195 detail and retained 4K',passed:true,title:d.title,count:195,firstEpisodeSources:d.episodeItems[0].childItems.length});console.log('PASS detail 195 and all source choices');const link=c.KK_SITE+'/play/26654-4-225202.html',r=await c.loadResource({link,mediaCheck:'device'});r.forEach(x=>schemas.streamSourceItemSchema.parse(x));assert(r[0].name.includes('待设备验证'));report.checks.push({name:'exact original player source handed to device',passed:true,names:r.map(x=>x.name),mediaVerified:false});console.log('PASS original source extraction (device unverified)');try{await c.loadResource({link,mediaCheck:'verified'});report.checks.push({name:'checked HLS on this network',passed:true});}catch(e){report.limitations.push('Checked playback on current network failed: '+String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]'));console.log('LIMIT current-network media '+e.message);}}catch(e){report.checks.push({name:'detail and original source',passed:false,error:String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]')});console.log('FAIL detail/source '+e.message);}
 fs.writeFileSync('kkys-validation.json',JSON.stringify(report,null,2)+'\n');if(report.checks.some(x=>!x.passed))process.exitCode=1;
})().catch(e=>{console.error(e);process.exitCode=1;});
