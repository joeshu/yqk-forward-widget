const assert=require('node:assert/strict');
const {runSourceHealthCheck}=require('./health-check.cjs');
let passed=0;
async function test(name,fn){await fn();passed++;console.log('PASS '+name);}
const site={key:'fixture',name:'Fixture',api:'/spider/fixture/3'};
(async()=>{
 await test('malformed home/category data is isolated as a source failure',async()=>{
  const server={inject:async({url})=>({statusCode:200,json:()=>url.endsWith('/home')?{class:null}:{list:null}})};
  const r=await runSourceHealthCheck(server,site);assert.equal(r.passed,false);assert.match(r.error,/no categories/);
 });
 await test('detail and play errors do not abort other checks',async()=>{
  const server={inject:async({url})=>({statusCode:200,json:()=>url.endsWith('/home')?{class:[{type_id:'1'}]}:url.endsWith('/category')?{list:[{vod_id:'id1',vod_name:'sample'}],pagecount:1}:url.endsWith('/detail')?{list:[{vod_play_url:'line$ep1'}]}:url.endsWith('/search')?{list:[{vod_id:'id1'}]}:{url:'https://media.test/a.m3u8'}})};
  const r=await runSourceHealthCheck(server,site);assert.equal(r.passed,true);assert.equal(r.checks.detail.passed,true);assert.equal(r.checks.play.passed,null);assert.equal(r.checks.play.status,'NOT_RUN');assert.equal(r.checks.search.passed,true);
 });
 await test('HTTP errors and malformed JSON are represented, not thrown',async()=>{
  for(const reply of [{statusCode:503,json:()=>({})},{statusCode:200,json:()=>{throw Error('bad json')}}]){
   const r=await runSourceHealthCheck({inject:async()=>reply},site);assert.equal(r.passed,false);assert.ok(r.error);
  }
 });
 await test('per-action timeout is recorded and source worker remains usable',async()=>{
  const slow={inject:()=>new Promise(()=>{})};const r=await runSourceHealthCheck(slow,site,{timeoutMs:10});assert.match(r.error,/timed out/);
  const good={inject:async({url})=>({statusCode:200,json:()=>url.endsWith('/home')?{class:[{type_id:'1'}]}:{list:[{vod_id:'x',vod_name:'x'}],pagecount:1}})};
  assert.equal((await runSourceHealthCheck(good,site,{timeoutMs:10})).passed,true);
 });
 console.log(`${passed} health-check tests passed`);
})().catch(e=>{console.error(e);process.exitCode=1;});
