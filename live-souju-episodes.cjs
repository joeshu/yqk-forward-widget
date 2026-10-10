// Production requests through the official Rex adapter. Reports never include
// cookies, visitor IDs, episode tokens or signed playback URLs.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path'),os=require('node:os'),{spawn}=require('node:child_process'),{pathToFileURL}=require('node:url');
function request(url,options={}){return new Promise((resolve,reject)=>{const child=spawn('python3',[path.join(__dirname,'http-bridge.py')],{stdio:['pipe','pipe','pipe']});let output='';child.stdout.on('data',x=>output+=x);child.on('error',reject);child.on('close',code=>{if(code)return reject(Error('Transport failed'));try{const r=JSON.parse(output);resolve(new Response(Buffer.from(r.bodyBase64,'base64'),{status:r.status,headers:r.headers}));}catch(e){reject(Error('Invalid transport response'));}});child.stdin.end(JSON.stringify({url:String(url),method:options.method||'GET',headers:options.headers||{},body:options.body}));});}
(async()=>{
 const {WidgetAdaptor}=await import('./node_modules/@rexnow/libs/dist/widget-adaptor.js');
 const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'souju-schema-')),file=path.join(tmp,'schema.mjs');
 const schema=fs.readFileSync(__dirname+'/node_modules/@rexnow/libs/dist/env.zod/index.ts','utf8').replace('from "zod"','from '+JSON.stringify(pathToFileURL(__dirname+'/node_modules/zod/index.js').href)).replace(/: z\.ZodTypeAny/g,'');fs.writeFileSync(file,schema);const schemas=await import(pathToFileURL(file));
 globalThis.fetch=request;const values={};const c=vm.createContext({Widget:{...WidgetAdaptor,storage:{get:async k=>values[k],set:async(k,v)=>values[k]=v}}});vm.runInContext(fs.readFileSync(__dirname+'/souju.js','utf8'),c);

 const source=fs.readFileSync(__dirname+'/souju.js'),report={time:new Date().toISOString(),version:c.WidgetMetadata.version,sourceSha256:require('node:crypto').createHash('sha256').update(source).digest('hex'),checks:[],limitations:'Official schemas and production episode/resolve/HLS checks; native iOS layout and complete media decoding not tested. No cookies, tokens or playback URLs stored.'};
 async function check(name,fn){const result=await fn();report.checks.push({name,result});console.log('PASS '+name+' '+JSON.stringify(result));}
 await check('official metadata schema',()=>{schemas.widgetMetadataSchema.parse(c.WidgetMetadata);return true;});
 const found=await c.search({keyword:'凡人修仙传'}),hit=found.find(x=>x.title==='凡人修仙传'&&x.releaseDate==='2020');assert(hit);
 const detail=await c.loadDetail(hit.link);
 await check('complete actual 194 episodes in one list',()=>{schemas.videoItemSchema.parse(detail);assert.equal(detail.episodeItems.length,194);assert.equal(new Set(detail.episodeItems.map(e=>e.id)).size,194);assert(detail.episodeItems[100].link.endsWith('?offset=100'));return {title:detail.title,available:detail.episodeItems.length,first:detail.episodeItems[0].title,boundary:detail.episodeItems[100].title,last:detail.episodeItems.at(-1).title,seasonChoices:detail.childItems.length};});
 for(const index of [100,193])await check('actual playback episode '+(index+1),async()=>{const sources=await c.loadResource({link:detail.episodeItems[index].link});sources.forEach(s=>schemas.streamSourceItemSchema.parse(s));assert(sources.length>0);return {episode:detail.episodeItems[index].title,lines:sources.length,names:sources.map(s=>s.name),hlsVerified:sources.every(s=>s.description.includes('清单已检查'))};});
 await check('old offset=100 link now shows all 194',async()=>{const d=await c.loadDetail(c.sjLink(c.sjParse(hit.link).id,100));schemas.videoItemSchema.parse(d);assert.equal(d.episodeItems.length,194);return {episodes:d.episodeItems.length};});
 fs.writeFileSync(__dirname+'/souju-episodes-validation.json',JSON.stringify(report,null,2)+'\n');fs.rmSync(tmp,{recursive:true,force:true});
})().catch(e=>{console.error(e.message);process.exitCode=1;});
