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
 const namespace='4kvm-live-'+Date.now()+'.';
 Widget.storage={get:k=>WidgetAdaptor.storage.get(namespace+k),set:(k,v)=>WidgetAdaptor.storage.set(namespace+k,v)};
 const ctx=vm.createContext({console,Widget});vm.runInContext(fs.readFileSync(__dirname+'/4kvm.js','utf8'),ctx);

 const report={time:new Date().toISOString(),version:ctx.WidgetMetadata.version,checks:[],playback:[],limitations:['No media segments or decoding checked','No iPhone import/playback test']};
 function videos(items){for(const item of items)schemas.videoItemSchema.parse(item);return items;}
 schemas.widgetMetadataSchema.parse(ctx.WidgetMetadata);report.checks.push({name:'official metadata',passed:true});
 const categories=await Promise.allSettled([['1',1],['1',2],['2',1],['3',1],['4',1]].map(async([category,page])=>{const items=videos(await ctx.loadCatalog({category,page}));if(category!=='4')assert(items.length>0);return {category,page,count:items.length,first:items[0]?.title||null,firstLink:items[0]?.link||null};}));
 for(const c of categories){if(c.status==='rejected')throw c.reason;console.log('PASS category '+JSON.stringify(c.value));report.checks.push({name:'real catalog',...c.value});}
 assert.notEqual(categories[0].value.firstLink,categories[1].value.firstLink);
 const home=videos(await ctx.loadHome());assert(home.length>0);report.checks.push({name:'real homepage',count:home.length});
 const search=videos(await ctx.search({keyword:'凡人修仙传',page:1}));assert(search.length>0);report.checks.push({name:'real search',count:search.length});
 const anime=search.find(x=>x.link.endsWith('/play/cgzq7f3tf'));assert(anime);
 const detail=await ctx.loadDetail(anime.link);schemas.videoItemSchema.parse(detail);assert(detail.episodeItems.length>=195);assert(detail.episodeItems.some(x=>x.title==='第101集'));assert(detail.episodeItems.some(x=>x.title==='第195集'));report.checks.push({name:'complete detail',count:detail.episodeItems.length,title:detail.title});
 const playback=await Promise.allSettled([1,101,195].map(async(number)=>{const ep=detail.episodeItems.find(x=>x.title==='第'+number+'集');const sources=await ctx.loadResource({link:ep.link,qualityPreference:'fixed'});assert(sources.length>0);sources.forEach(x=>schemas.streamSourceItemSchema.parse(x));assert(sources.every(x=>!x.name.includes('4K')));return {episode:number,passed:true,sourceCount:sources.length,name:sources[0].name};}));
 for(const p of playback){if(p.status==='rejected')throw p.reason;console.log('PASS HLS '+JSON.stringify(p.value));report.playback.push(p.value);}

 const movie=await ctx.loadDetail(categories[0].value.firstLink);schemas.videoItemSchema.parse(movie);assert(movie.episodeItems.length>0);report.checks.push({name:'real movie detail',title:movie.title,count:movie.episodeItems.length});
 const nextSearch=await ctx.search({keyword:'凡人修仙传',page:2});assert.equal(nextSearch.length,0);report.checks.push({name:'single-page search does not duplicate results',count:nextSearch.length});
 const mirror=videos(await ctx.search({site:'https://www.4kvms.com',keyword:'凡人修仙传'}));assert(mirror.length>0);assert(mirror.every(x=>x.link.startsWith('https://www.4kvms.com/')));report.checks.push({name:'alternate published entry search',site:'https://www.4kvms.com',count:mirror.length});

 const filtered=videos(await ctx.loadLatest({category:'3',area:'中国',genre:'动画',year:'2020'}));assert(filtered.length>0);assert(filtered.every(x=>x.releaseDate==='2020'));assert(filtered.some(x=>x.description.includes('集')));const maps=ctx.vm4FacetCache['https://www.4kvms.org'].maps;report.checks.push({name:'real combined taxonomy and recent updates',category:'3',area:'中国',genre:'动画',year:'2020',count:filtered.length,first:filtered[0].title,ids:{area:maps.areas['中国'],genre:maps.types['动画'],year:maps.years['2020']},withRating:filtered.filter(x=>x.rating).length});
 fs.writeFileSync(__dirname+'/4kvm-validation.json',JSON.stringify(report,null,2)+'\n');console.log('PASS 4K影视 live and official schemas');
})().catch(e=>{console.error(String(e.message).replace(/https?:\/\/\S+/g,'[URL omitted]'));process.exitCode=1;});
