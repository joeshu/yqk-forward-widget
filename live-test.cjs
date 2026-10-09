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
 if(process.env.MEDIA_ONLY==='1') {
  await check('real movie fallback and media segment',async()=>{
   const resources=await ctx.loadResource({link:'https://m.yqk3hxe.com/play/118292'});resources.forEach(x=>schemas.streamSourceItemSchema.parse(x));
   const source=resources[0];let url=source.url,playlist;
   for(let depth=0;depth<3;depth++) {
    const response=await Widget.http.get(url,{headers:source.customHeaders});assert.equal(response.statusCode,200);playlist=String(response.data);assert(playlist.startsWith('#EXTM3U'));
    if(!playlist.includes('#EXT-X-STREAM-INF')) break;
    const next=playlist.split(/\r?\n/).map(x=>x.trim()).find(x=>x && !x.startsWith('#'));assert(next);url=new URL(next,url).href;
   }
   const segment=playlist.split(/\r?\n/).map(x=>x.trim()).find(x=>x && !x.startsWith('#'));assert(segment);
   const response=await Widget.http.get(new URL(segment,url).href,{headers:source.customHeaders,base64Data:true});assert.equal(response.statusCode,200);
   const bytes=Buffer.from(response.data,'base64');assert(bytes.length>512);assert(!/^\s*</.test(bytes.subarray(0,32).toString()));
   const result={quality:source.name,segmentStatus:response.statusCode,segmentBytes:bytes.length};
   const keyLine=playlist.split(/\r?\n/).find(x=>x.startsWith('#EXT-X-KEY:') && !x.includes('METHOD=NONE'));
   let keyBytes,keyTag;
   if(keyLine) {
    if(!keyLine.includes('METHOD=AES-128') || (/KEYFORMAT=/.test(keyLine) && !/KEYFORMAT="identity"/.test(keyLine))) {result.decode='not attempted for unsupported encryption';return result;}
    const keyUri=keyLine.match(/URI="([^"]+)"/);assert(keyUri);
    const keyResponse=await Widget.http.get(new URL(keyUri[1],url).href,{headers:source.customHeaders,base64Data:true});assert.equal(keyResponse.statusCode,200);
    keyBytes=Buffer.from(keyResponse.data,'base64');assert.equal(keyBytes.length,16);result.keyStatus=keyResponse.statusCode;
    keyTag=keyLine.replace(/URI="[^"]+"/,'URI="key.bin"');
   }
   let init=Buffer.alloc(0);const map=playlist.match(/#EXT-X-MAP:.*URI="([^"]+)"/);
   if(map){const r=await Widget.http.get(new URL(map[1],url).href,{headers:source.customHeaders,base64Data:true});assert.equal(r.statusCode,200);init=Buffer.from(r.data,'base64');}
   const dir=fs.mkdtempSync(path.join(os.tmpdir(),'yqk-media-')),file=path.join(dir,'segment.bin');
   try {
    fs.writeFileSync(file,Buffer.concat([init,bytes]));
    let input=file,args=[];
    if(keyBytes) {
     assert(!map,'Encrypted fMP4 fixture not supported by this test');fs.writeFileSync(path.join(dir,'key.bin'),keyBytes,{mode:0o600});
     const sequence=(playlist.match(/#EXT-X-MEDIA-SEQUENCE:(\d+)/)||[])[1]||'0';
     input=path.join(dir,'local.m3u8');fs.writeFileSync(input,['#EXTM3U','#EXT-X-VERSION:3','#EXT-X-TARGETDURATION:60','#EXT-X-MEDIA-SEQUENCE:'+sequence,keyTag,'#EXTINF:60,','segment.bin','#EXT-X-ENDLIST'].join('\n')+'\n');
     args=['-allowed_extensions','ALL','-protocol_whitelist','file,crypto'];
    }
    const probe=spawnSync('ffprobe',['-v','error',...args,'-show_entries','stream=codec_name,width,height','-of','json',input],{encoding:'utf8',timeout:20000});assert.equal(probe.status,0);
    result.streams=JSON.parse(probe.stdout).streams;assert(result.streams.some(x=>x.width>0));
    const decode=spawnSync('ffmpeg',['-v','error',...args,'-i',input,'-t','2','-f','null','-'],{encoding:'utf8',timeout:20000});assert.equal(decode.status,0);result.decodeLimitSeconds=2;result.ffmpegExitCode=decode.status;
   } finally {fs.rmSync(dir,{recursive:true,force:true});}
   return result;
  });
  report.sourceSha256=require('node:crypto').createHash('sha256').update(fs.readFileSync(__dirname+'/yqk.js')).digest('hex');
  fs.writeFileSync(__dirname+'/media-validation.json',JSON.stringify(report,null,2)+'\n');return;
 }
 if(process.env.HOT_ONLY==='1') {
  await check('real hot category choices',async()=>Promise.all(['0','2','3','8','10'].map(async channelId=>{
   const items=videos(await ctx.loadHotSearch({channelId}));return {channelId,count:items.length};
  })));
  report.sourceSha256=require('node:crypto').createHash('sha256').update(fs.readFileSync(__dirname+'/yqk.js')).digest('hex');
  fs.writeFileSync(__dirname+'/hot-validation.json',JSON.stringify(report,null,2)+'\n');return;
 }
 if(process.env.DETAIL_ONLY==='1') {
  await check('real film detail with separate sources',async()=>{
   const detail=await ctx.loadDetail('https://m.yqk3hxe.com/play/118292');schemas.videoItemSchema.parse(detail);
   assert.equal(detail.episodeItems.length,1);assert(detail.childItems.length>1);
   return {title:detail.title,episodeItems:detail.episodeItems.length,sources:detail.childItems.length};
  });
  let detail;
  await check('real TV detail with separate sources',async()=>{
   const list=await ctx.loadCategory({parentChannelId:'3',page:1});detail=await ctx.loadDetail(list[0].link);schemas.videoItemSchema.parse(detail);
   assert(detail.episodeItems.length>1 && detail.childItems.length>1);
   assert(detail.episodeItems.length<100);return {title:detail.title,episodeItems:detail.episodeItems.length,sources:detail.childItems.length};
  });
  await check('real TV stream and HLS playlist',async()=>{
   const resources=await ctx.loadResource({link:detail.episodeItems[0].link});resources.forEach(x=>schemas.streamSourceItemSchema.parse(x));
   const media=await Widget.http.get(resources[0].url,{headers:resources[0].customHeaders});
   assert.equal(media.statusCode,200);assert(String(media.data).startsWith('#EXTM3U'));return {resources:resources.length,hlsStatus:media.statusCode};
  });
  const previous=JSON.parse(fs.readFileSync(__dirname+'/validation.json','utf8'));
  previous.checks=previous.checks.filter(x=>!['real film detail','real TV category and detail'].includes(x.name));
  previous.checks.push(...report.checks.filter(x=>x.name!=='official metadata schema'));
  previous.time=report.time;previous.sourceSha256=require('node:crypto').createHash('sha256').update(fs.readFileSync(__dirname+'/yqk.js')).digest('hex');
  previous.note='Core production checks retained; changed detail/source grouping revalidated separately against production, including TV HLS. Native iOS App UI not tested.';
  fs.writeFileSync(__dirname+'/validation.json',JSON.stringify(previous,null,2)+'\n');return;
 }
 let searchItems,filmDetail,series;
 await check('landing-page search without keyword',async()=>{
  assert.equal(videos(await ctx.search({})).length,0);
  assert.equal(videos(await ctx.search({keyword:'\u200b  '})).length,0);
  return {count:0,behavior:'idle, no keyword required on landing page'};
 });
 await check('real search',async()=>{searchItems=videos(await ctx.search({keyword:'流浪地球',page:1}));assert(searchItems.some(x=>x.title==='流浪地球2'));return {count:searchItems.length,titles:searchItems.map(x=>x.title)};});
 await check('real home',async()=>{const r=videos(await ctx.loadHome());assert(r.length>0);return {count:r.length};});
 await check('real hot search',async()=>{const r=videos(await ctx.loadHotSearch({channelId:0}));assert(r.length>0);return {count:r.length};});
 await check('real category array cursor and page two',async()=>{
  const first=videos(await ctx.loadCategory({parentChannelId:'2',page:1}));
  const second=videos(await ctx.loadCategory({parentChannelId:'2',page:2}));
  assert(first.length>0 && second.length>0);assert.notEqual(first[0].id,second[0].id);
  return {pageOne:first.length,pageTwo:second.length,firstTitles:[first[0].title,second[0].title]};
 });
 await check('real film detail',async()=>{const film=searchItems.find(x=>x.title==='流浪地球2');filmDetail=await ctx.loadDetail(film.link);schemas.videoItemSchema.parse(filmDetail);assert.equal(filmDetail.episodeItems.length,1);return {title:filmDetail.title,episodeItems:filmDetail.episodeItems.length,sources:filmDetail.childItems.length};});
 await check('real TV category and detail',async()=>{
  const r=videos(await ctx.loadCategory({parentChannelId:'3',page:1}));assert(r.length>0);series=await ctx.loadDetail(r[0].link);schemas.videoItemSchema.parse(series);
  assert(series.episodeItems.length>1 && series.episodeItems.length<100);return {title:series.title,episodeItems:series.episodeItems.length,sources:series.childItems.length};
 });
 await check('real anime and variety categories',async()=>{
  const results=await Promise.all(['8','10'].map(async id=>{const r=videos(await ctx.loadCategory({parentChannelId:id,page:1}));assert(r.length>0);return {id,count:r.length};}));return results;
 });
 await check('real film stream and HLS playlist',async()=>{
  const resources=await ctx.loadResource({link:filmDetail.episodeItems[0].link});assert(resources.length>0);
  resources.forEach(x=>schemas.streamSourceItemSchema.parse(x));
  const media=await Widget.http.get(resources[0].url,{headers:resources[0].customHeaders});
  assert.equal(media.statusCode,200);assert(String(media.data).startsWith('#EXTM3U'));
  // Report no signed URLs, generated device IDs or request signatures.
  return {resources:resources.length,quality:resources[0].name,hlsStatus:media.statusCode};
 });
 await check('real TV stream and HLS playlist',async()=>{
  const resources=await ctx.loadResource({link:series.episodeItems[0].link});assert(resources.length>0);
  resources.forEach(x=>schemas.streamSourceItemSchema.parse(x));
  const media=await Widget.http.get(resources[0].url,{headers:resources[0].customHeaders});
  assert.equal(media.statusCode,200);assert(String(media.data).startsWith('#EXTM3U'));
  return {resources:resources.length,quality:resources[0].name,hlsStatus:media.statusCode};
 });
 report.sourceSha256=require('node:crypto').createHash('sha256').update(fs.readFileSync(__dirname+'/yqk.js')).digest('hex');
 report.note='Full production API checks and movie/TV HLS playlists verified through this final JS and official adaptor/schema; native iOS App UI not tested.';
 fs.writeFileSync(__dirname+'/validation.json',JSON.stringify(report,null,2)+'\n');
 console.log('Live checks complete. Native iOS App UI remains untested.');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
