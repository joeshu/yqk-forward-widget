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
 for(const name of (process.argv.includes('--zym-only')?['zhuiyingmiao']:process.argv.includes('--gold-only')?['gold']:['gold','zhuiyingmiao'])){const c=vm.createContext({Widget:WidgetAdaptor});vm.runInContext(fs.readFileSync(name+'.js','utf8'),c);const report={time:new Date().toISOString(),version:c.WidgetMetadata.version,sourceSha256:require('node:crypto').createHash('sha256').update(fs.readFileSync(name+'.js')).digest('hex'),checks:[],limitations:['No iPhone native TLS/import/playback test','HLS playlist checked; media segments not decoded',name==='gold'?'Login qualities excluded; guest 480P currently available':'Only adapted sources support native playback; other external sources may need dedicated webpage parsers']};
 const jobs=[['home',()=>c.loadHome()],['latest',()=>c.loadLatest({category:'2'})],['category',()=>c.loadCatalog({category:'2'})],['search',()=>c.search({keyword:'泪之女王'})],['search page 2',()=>c.search({keyword:'爱',page:2})]];
 for(const [check,job] of jobs)try{const r=await job();assert(r.length>0);report.checks.push({name:check,passed:true,count:r.length});console.log('PASS '+name+' '+check);}catch(e){report.checks.push({name:check,passed:false,error:String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]')});console.log('FAIL '+name+' '+check+' '+e.message);}
 try{const link=name==='gold'?'https://m.vv3nwjk.com/vod/play/147455/1/1323435':'https://zhuiyingmiao5.com/voddetail/1657047.html',d=await c.loadDetail(link);assert.equal(d.episodeItems.length,name==='gold'?1:16);report.checks.push({name:'complete detail',passed:true,title:d.title,count:d.episodeItems.length,firstEpisodeSourceChoices:(d.episodeItems[0].childItems||[]).length});console.log('PASS '+name+' detail');const r=await c.loadResource({link:d.episodeItems[0].link,qualityPreference:'fixed'});assert(r.length>0);report.checks.push({name:'guest media playlist',passed:true,count:r.length,names:r.map(x=>x.name)});console.log('PASS '+name+' guest media');}catch(e){report.checks.push({name:'detail or guest playback',passed:false,error:String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]')});console.log('FAIL '+name+' detail/media '+e.message);}
 fs.writeFileSync(name+'-validation.json',JSON.stringify(report,null,2)+'\n');if(report.checks.some(x=>!x.passed))process.exitCode=1;
 }
})().catch(e=>{console.error(String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]'));process.exitCode=1;});
