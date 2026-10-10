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
 const namespace='zip0-live-'+Date.now()+'.';
 Widget.storage={get:k=>WidgetAdaptor.storage.get(namespace+k),set:(k,v)=>WidgetAdaptor.storage.set(namespace+k,v)};
 const ctx=vm.createContext({console,Widget});vm.runInContext(fs.readFileSync(__dirname+'/zip0.js','utf8'),ctx);
 const report={time:new Date().toISOString(),version:ctx.WidgetMetadata.version,checks:[]};
 async function check(name,fn){const result=await fn();report.checks.push({name,result});console.log('PASS '+name+' '+JSON.stringify(result));}
 function videos(items){for(const item of items) schemas.videoItemSchema.parse(item);return items;}
 await check('official metadata schema',()=>{schemas.widgetMetadataSchema.parse(ctx.WidgetMetadata);return true;});
 const categories=await Promise.allSettled([['movie',1],['movie',2],['tv',1]].map(async ([category,page])=>{const items=videos(await ctx.loadCatalog({category,page}));assert(items.length>0);return {category,page,count:items.length,first:items[0].title};}));
 for(let i=0;i<categories.length;i++){const x=categories[i];if(x.status==='rejected')throw x.reason;report.checks.push({name:'real category '+i,result:x.value});console.log('PASS category '+JSON.stringify(x.value));}
 let found;
 await check('real public search and official card schema',async()=>{found=videos(await ctx.search({keyword:'凡人修仙传',page:1}));assert(found.length>0);return {count:found.length,animeSources:found.filter(x=>x.releaseDate==='2020').length};});
 const anime=found.find(x=>x.releaseDate==='2020'&&x.link.includes('source=dyttzy&'))||found.find(x=>x.releaseDate==='2020');assert(anime);
 let detail;
 await check('real complete anime detail, episode 101 and last episode',async()=>{detail=await ctx.loadDetail(anime.link);schemas.videoItemSchema.parse(detail);assert(detail.episodeItems.length>100);assert(detail.episodeItems[100].link.endsWith('episode=101'));return {title:detail.title,source:ctx.zipParse(anime.link).source,episodeCount:detail.episodeItems.length,episode101:detail.episodeItems[100].title,last:detail.episodeItems.at(-1).title};});
 report.playback=[];
 for(const index of [100,detail.episodeItems.length-1]){
  try{const r=await ctx.loadResource({link:detail.episodeItems[index].link,qualityPreference:'fixed'});r.forEach(x=>schemas.streamSourceItemSchema.parse(x));const response=await Widget.http.get(r[0].url,{headers:r[0].customHeaders});assert.equal(response.statusCode,200);assert(String(response.data).startsWith('#EXTM3U'));const record={episode:detail.episodeItems[index].title,source:ctx.zipParse(anime.link).source,passed:true,hlsStatus:response.statusCode,resourceName:r[0].name};report.playback.push(record);console.log('PASS HLS '+JSON.stringify(record));}
  catch(e){const record={episode:detail.episodeItems[index].title,source:ctx.zipParse(anime.link).source,passed:false,error:String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]')};report.playback.push(record);console.log('UNAVAILABLE HLS '+JSON.stringify(record));}
 }
 if(!report.playback.some(x=>x.passed)){
  const alternatives=['ffzy','ikun'].map(source=>found.find(x=>x.title===anime.title&&x.releaseDate===anime.releaseDate&&x.genreTitle.includes('动漫')&&ctx.zipParse(x.link).source===source)).filter(Boolean);
  for(const candidate of alternatives){
   let alternate;
   try{alternate=await ctx.loadDetail(candidate.link);schemas.videoItemSchema.parse(alternate);}catch(e){report.playback.push({source:ctx.zipParse(candidate.link).source,passed:false,error:'alternate detail unavailable'});continue;}
   for(const number of [101,195]){
    const episode=alternate.episodeItems.find(x=>new RegExp('^第0*'+number+'集$').test(x.title));if(!episode)continue;
    try{const r=await ctx.loadResource({link:episode.link,qualityPreference:'fixed'});r.forEach(x=>schemas.streamSourceItemSchema.parse(x));const response=await Widget.http.get(r[0].url,{headers:r[0].customHeaders});assert.equal(response.statusCode,200);assert(String(response.data).startsWith('#EXTM3U'));const record={episode:episode.title,source:ctx.zipParse(candidate.link).source,passed:true,hlsStatus:response.statusCode,resourceName:r[0].name};report.playback.push(record);console.log('PASS alternate HLS '+JSON.stringify(record));}
    catch(e){const record={episode:episode.title,source:ctx.zipParse(candidate.link).source,passed:false,error:String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]')};report.playback.push(record);console.log('UNAVAILABLE alternate HLS '+JSON.stringify(record));}
   }
   if(report.playback.some(x=>x.passed))break;
  }
 }
 report.sourceSha256=require('node:crypto').createHash('sha256').update(fs.readFileSync(__dirname+'/zip0.js')).digest('hex');
 report.note='Real public website/API requests and official Rex schemas; per-source HLS availability is reported separately. No media segments or keys downloaded; no full decode or native iOS UI test. Only public discovery and guest playback, no login or AI consumption.';
 fs.writeFileSync(__dirname+'/zip0-validation.json',JSON.stringify(report,null,2)+'\n');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
