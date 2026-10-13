const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto');
const {runSourceHealthCheck}=require('./health-check.cjs');
const {reportStatus}=require('./report-utils.cjs');
(async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'catpaw-live-')),entry=path.join(dir,'index.cjs');fs.copyFileSync(path.join(__dirname,'dist/index.js'),entry);
 const {createService}=require(entry),values=new Map(),storage={get:k=>values.get(k),set:async(k,v)=>values.set(k,v),remove:async k=>values.delete(k),flush:async()=>{}},server=createService({storage});
 const info=JSON.parse(fs.readFileSync(path.join(__dirname,'dist/info.json'))),build=info.build;
 const report={schemaVersion:2,mode:'catalogue-read-only',gitCommit:build.gitCommit,sourceFingerprint:build.sourceFingerprint,checkedAt:new Date().toISOString(),bundleSha256:crypto.createHash('sha256').update(fs.readFileSync(entry)).digest('hex'),checks:[],limitations:['Anonymous read-only requests from this network at check time only','Playback, guest registration, login and reward actions are not executed','No CatPaw/JSTV client import, login, CAPTCHA, paid content, or device playback test']};
 try {
  const configReply=await server.inject('/config'),conf=configReply.json(),sites=conf?.video?.sites;
  if(!Array.isArray(sites))throw new Error('Service config has no video site list');
  report.sourceCount=sites.length;
  const results=new Array(sites.length);let next=0;
  async function worker(){while(true){const i=next++;if(i>=sites.length)return;try{results[i]=await runSourceHealthCheck(server,sites[i],{timeoutMs:30000});const r=results[i];console.log(`${r.passed?'PASS':'LIMIT'} ${r.source} ${JSON.stringify(r.checks||{error:r.error})}${r.error?` error=${r.error}`:''}`);}catch(e){results[i]={source:sites[i]?.name||sites[i]?.key||`index-${i}`,key:sites[i]?.key||null,passed:false,error:String(e.message||e).slice(0,500)};console.log(`LIMIT ${results[i].source} ${results[i].error}`);}}}
  await Promise.all(Array.from({length:4},worker));report.checks=results;report.summary={notRun:results.filter(x=>x?.status==='NOT_RUN').length,passed:results.filter(x=>x?.passed).length,failed:results.filter(x=>x&&!x.passed&&x.status!=='NOT_RUN').length,unaccounted:results.filter(x=>!x).length};
 } finally {await server.close();fs.rmSync(dir,{recursive:true,force:true});}
 report.binding=reportStatus(report,{...build,bundleSha256:report.bundleSha256,enabledCount:info.summary.enabled,enabledKeys:info.sources.filter(s=>s.enabled!==false).map(s=>'nodejs_'+s.key)});
 const folder=path.join(__dirname,'reports/runtime');fs.mkdirSync(folder,{recursive:true});const reportPath=path.join(folder,build.gitCommit.slice(0,12)+'-'+report.bundleSha256.slice(0,12)+'-'+Date.now()+'.json');fs.writeFileSync(reportPath,JSON.stringify(report,null,2)+'\n');
 console.log(`Wrote ${reportPath}: ${report.sourceCount||0} sources; ${report.summary?.passed||0} list checks passed`);
})().catch(e=>{console.error(e);process.exitCode=1;});
