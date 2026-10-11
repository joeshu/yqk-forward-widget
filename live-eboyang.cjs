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
 const {WidgetAdaptor}=await import(pathToFileURL(path.join(dependencyRoot,'@rexnow/libs/dist/widget-adaptor.js')));globalThis.fetch=request;const c=vm.createContext({Widget:WidgetAdaptor});vm.runInContext(fs.readFileSync('eboyang.js','utf8'),c);
 const report={time:new Date().toISOString(),version:c.WidgetMetadata.version,checks:[],limitations:['No iPhone native TLS/import/playback test','No media segments decoded','Search and category page 2 may return upstream HTTP errors']};
 const home=await c.loadHome();assert(home.length>0);report.checks.push({name:'real home',count:home.length});console.log('PASS real home');
 const latest=await c.loadLatest();assert(latest.length>0);report.checks.push({name:'real recent updates',count:latest.length});console.log('PASS real latest');
 const cat=await c.loadCatalog({category:'2'});assert(cat.length>0);report.checks.push({name:'real TV category',count:cat.length});console.log('PASS real category');
 for(const [name,job] of [['real category page 2',()=>c.loadCatalog({category:'2',page:2})],['real search',()=>c.search({keyword:'雷霆令'})]])try{const items=await job();assert(items.length>0);report.checks.push({name,count:items.length,passed:true});console.log('PASS '+name);}catch(e){report.checks.push({name,passed:false,error:String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]')});console.log('LIMITATION '+name);}
 const detail=await c.loadDetail('https://www.eboyang.com/bovod/3896.html');assert.equal(detail.episodeItems.length,34);report.checks.push({name:'real complete detail',title:detail.title,count:detail.episodeItems.length,lines:detail.episodeItems[0].childItems.length});console.log('PASS real detail');
 try{const sources=await c.loadResource({link:detail.episodeItems[0].link,qualityPreference:'fixed'});assert(sources.length>0);report.checks.push({name:'real HLS checks',passed:true,count:sources.length,names:sources.map(x=>x.name)});console.log('PASS real HLS');}catch(e){report.checks.push({name:'real HLS checks',passed:false,error:String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]')});console.log('LIMITATION real HLS');}
 fs.writeFileSync('eboyang-validation.json',JSON.stringify(report,null,2)+'\n');
})().catch(e=>{console.error(String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]'));process.exitCode=1;});
