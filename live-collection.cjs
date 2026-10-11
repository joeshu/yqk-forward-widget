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
(async()=>{const {WidgetAdaptor}=await import(pathToFileURL(path.join(dependencyRoot,'@rexnow/libs/dist/widget-adaptor.js')));globalThis.fetch=request;const entries=JSON.parse(fs.readFileSync('yqk.fwd')).widgets,report={time:new Date().toISOString(),checks:[],limits:['Independent fresh in-memory storage for each module; no imported validation credentials','List pages only; no AI parsing, media segments, or native iOS testing']};let next=0;async function worker(){while(next<entries.length){const w=entries[next++],prefix=w.id.replace('joeshu.',''),storage=new Map(),c=vm.createContext({Widget:{...WidgetAdaptor,storage:{get:async k=>storage.get(k),set:async(k,v)=>storage.set(k,v),remove:async k=>storage.delete(k)}}});vm.runInContext(fs.readFileSync(prefix+'.js','utf8'),c);const m=c.WidgetMetadata.modules.find(x=>x.id==='latest')||c.WidgetMetadata.modules.find(x=>x.functionName==='loadHome')||c.WidgetMetadata.modules.find(x=>x.functionName==='loadCatalog'),params={};(m.params||[]).forEach(p=>{if(p.value!=null)params[p.name]=p.value;});const start=Date.now(),row={id:w.id,title:w.title,version:c.WidgetMetadata.version,sourceSha256:require('node:crypto').createHash('sha256').update(fs.readFileSync(prefix+'.js')).digest('hex'),entry:m.id};try{const items=await c[m.functionName](params);assert(Array.isArray(items));row.passed=true;row.count=items.length;row.missingArt=items.filter(x=>!x.coverUrl&&!x.posterPath).length;row.samples=items.slice(0,2).map(x=>x.title);row.syntheticArt=items.filter(x=>String(x.coverUrl||'').includes('/collection-poster.png')).length;console.log('PASS '+prefix+' '+items.length+' items');}catch(e){row.passed=false;row.code=e.code||'';row.error=String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]').slice(0,240);console.log('LIMIT '+prefix+' '+row.error);}row.elapsedMs=Date.now()-start;report.checks.push(row);}}await Promise.all([worker(),worker(),worker()]);report.checks.sort((a,b)=>entries.findIndex(w=>w.id===a.id)-entries.findIndex(w=>w.id===b.id));const target=process.argv.includes('--baseline')?'collection-baseline.json':'collection-validation.json';fs.writeFileSync(target,JSON.stringify(report,null,2)+'\n');})();
