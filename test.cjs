const fs=require('node:fs'), vm=require('node:vm'), assert=require('node:assert/strict'), crypto=require('node:crypto');
const store=new Map(), calls=[];
let handler;
const ctx=vm.createContext({console, Widget:{storage:{get:async k=>store.get(k),set:async(k,v)=>{assert.equal(typeof v,'string');store.set(k,v);}},http:{
 get:async url=>({statusCode:200,data:url.includes('/js/baseUrlList.js')?'var baseApiList = ["https://api.example.org"];':'#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:6,\nsegment.ts'}),
 post:async(url,body)=>{calls.push({url,body});return handler(url,body);}
}}});
vm.runInContext(fs.readFileSync(__dirname+'/yqk.js','utf8'),ctx);
let passed=0;
async function test(name,fn){store.clear();ctx.yqkMemory={};ctx.yqkMemoryOrder=[];ctx.yqkInFlight={};ctx.yqkQueues={};ctx.yqkLineHints={};ctx.YQK.detailTTL=60000;
 ctx.Widget.http.get=async url=>({statusCode:200,data:url.includes('/js/baseUrlList.js')?'var baseApiList = ["https://api.example.org"];':'#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:6,\nsegment.ts'});
 await fn();passed++;console.log('PASS '+name);}
const item={vodId:12,vodName:'测试电影',coverImg:'https://images.example.org/a.jpg',intro:'<p>介绍</p>'};
const good=data=>({statusCode:200,data:{result:true,data}});
(async()=>{
 await test('MD5 matches independent Node crypto, including Unicode and long input',()=>{
  for(const s of ['', 'abc', '中文关键词', 'x'.repeat(1000)]) assert.equal(ctx.md5(s),crypto.createHash('md5').update(s).digest('hex'));
 });
 await test('signature includes sorted fields, skips empty string, preserves zero',async()=>{
  const body=await ctx.makeBody({keyword:'中文',nextVal:'',nextCount:0}),sign=body.sign;delete body.sign;
  const text=Object.keys(body).sort().filter(k=>body[k]!=='').map(k=>k+'='+body[k]+'&').join('')+'appKey='+ctx.YQK.appKey;
  assert.equal(sign,crypto.createHash('md5').update(text).digest('hex'));
 });
 await test('landing-page search with unset or invisible input is idle without HTTP or storage',async()=>{
  calls.length=0;let gets=0;
  ctx.Widget.http.get=async()=>{gets++;throw new Error('empty search must not request network');};
  for(const params of [undefined,null,{}, {keyword:''},{keyword:'  \t\n'},{keyword:'\u200b\ufeff'}, {keyword:'',page:2}]) {
   assert.equal((await ctx.search(params)).length,0);
  }
  assert.equal(gets,0);assert.equal(calls.length,0);assert.equal(store.size,0);
 });
 await test('empty search does not prevent entering a keyword or change its pagination',async()=>{
  calls.length=0;
  handler=(_,body)=>good({items:[item],hasNext:body.nextVal==='',nextVal:body.nextVal===''?'next-search':''});
  assert.equal((await ctx.search({keyword:''})).length,0);
  assert.equal((await ctx.search({keyword:'测试电影',page:1})).length,1);
  assert.equal((await ctx.search({keyword:'  ',page:2})).length,0);
  assert.equal((await ctx.search({keyword:'测试电影',page:2})).length,1);
  assert.deepEqual(calls.map(c=>c.body.nextVal),['','next-search']);
 });
 await test('normalization preserves stable url identity and removes HTML',()=>{
  const x=ctx.normalize(item);assert.equal(x.id,x.link);assert.equal(x.type,'url');assert.equal(x.description,'介绍');
 });
 await test('cursor pagination replays page one when page two requested first',async()=>{
  calls.length=0;handler=(_,body)=>good({items:[item],nextVal:body.nextVal===''?'cursor-2':'',hasNext:body.nextVal===''});
  const result=await ctx.search({keyword:'跨页',page:2});assert.equal(result.length,1);
  assert.deepEqual(calls.map(c=>c.body.nextVal),['','cursor-2']);
  const count=calls.length;assert.equal((await ctx.search({keyword:'跨页',page:3})).length,0);assert.equal(calls.length,count);
 });
 await test('site business errors are not concealed as empty lists or retried',async()=>{
  calls.length=0;handler=()=>({data:{result:false,operateCode:10001,msg:'not printed'}});
  await assert.rejects(()=>ctx.search({keyword:'登录'}),/10001/);assert.equal(calls.length,1);
 });
 await test('HTML interface failure reported explicitly',async()=>{
  handler=()=>({data:'<h1>Site Unavailable</h1>'});await assert.rejects(()=>ctx.search({keyword:'网络'}),/HTML/);
 });
 await test('malformed list data rejected',async()=>{
  handler=()=>good({rows:[item]});await assert.rejects(()=>ctx.search({keyword:'格式'}),/data.items/);
 });
 await test('detail uses vodId and deduplicates episodes across player groups',async()=>{
  handler=(_,b)=>{assert.equal(b.vodId,12);return good({...item,playerList:[{epList:[{epId:31,epName:'第1集'}]},{epList:[{epId:31,epName:'第1集'}]}]});};
  const detail=await ctx.loadDetail('https://m.yqk3hxe.com/play/12');assert.equal(detail.episodeItems.length,1);
  assert.equal(detail.episodeItems[0].link,'https://m.yqk3hxe.com/play/12?epId=31');
 });
 await test('external or malformed detail links rejected',()=>assert.throws(()=>ctx.parseLink('https://evil.example/play/12'),/详情链接/));
 await test('play request uses observed epDetail/playUrl parameter names',async()=>{
  handler=(url,b)=>url.endsWith('/index')?good({...item,playerList:[{epList:[{epId:31,epName:'第1集'}]}]}):url.endsWith('/epDetail')?(assert.equal(b.vodEpId,31),good([{canPlay:true,vodResolution:720,showName:'高清'}])):
   (assert.equal(b.epId,31),assert.equal(b.vodResolution,720),good({playUrl:'https://media.example.org/video.m3u8'}));
  const r=await ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31'});assert.equal(r[0].name,'高清');assert.equal(r[0].url,'https://media.example.org/video.m3u8');
 });
 await test('unavailable guest resource is never requested for playback',async()=>{
  calls.length=0;handler=url=>url.endsWith('/index')?good({...item,playerList:[{epList:[{epId:31,epName:'第1集'}]}]}):good([{canPlay:false,vodResolution:1080}]);
  await assert.rejects(()=>ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31'}),/访客/);assert(!calls.some(c=>c.url.endsWith('/playUrl')));
 });
 await test('array cursor survives asynchronous string storage',async()=>{
  calls.length=0;handler=(_,b)=>good({items:[item],nextVal:b.nextVal===''?[1,2,3]:[],hasNext:b.nextVal===''});
  await ctx.search({keyword:'数组游标',page:1});await ctx.search({keyword:'数组游标',page:2});
  assert.equal(JSON.stringify(calls[1].body.nextVal),'[1,2,3]');
 });
 await test('unchanged array cursor rejected by value',async()=>{
  handler=(_,b)=>good({items:[item],nextVal:[4,5,6],hasNext:true});
  await ctx.search({keyword:'重复游标',page:1});
  await assert.rejects(()=>ctx.search({keyword:'重复游标',page:2}),/未推进/);
 });
 await test('failover reaches fourth origin, unlike the initial broken version',async()=>{
  store.clear();ctx.yqkMemory={};
  await ctx.setStored('bases',{time:Date.now(),urls:['https://bad1.example.org','https://bad2.example.org','https://bad3.example.org','https://good4.example.org']});
  calls.length=0;handler=(url)=>url.startsWith('https://good4')?good({items:[item],hasNext:false,nextVal:''}):({statusCode:405,data:'unavailable'});
  assert.equal((await ctx.search({keyword:'故障转移'})).length,1);assert.equal(calls.length,4);
 });
 await test('home deduplicates actual vodTopicList/vodList structure',async()=>{
  handler=()=>good({vodTopicList:[{vodList:[item]},{vodList:[item]}]});assert.equal((await ctx.loadHome()).length,1);
 });
 await test('home topic selection preserves grouping instead of mixing unrelated lists',async()=>{
  handler=()=>good({vodTopicList:[{vodTopicId:93,vodList:[item,item]},{vodTopicId:77,vodList:[{...item,vodId:13,vodName:'另一专题'}]}]});
  const r=await ctx.loadHome({topicId:'93'});assert.equal(r.length,1);assert.equal(r[0].title,'测试电影');
  assert.equal((await ctx.loadHome({topicId:'all'})).length,2);
 });
 await test('category modules expose parent-specific names and pass child ID through pagination',async()=>{
  const movie=ctx.WidgetMetadata.modules.find(m=>m.id==='channel2'),tv=ctx.WidgetMetadata.modules.find(m=>m.id==='channel3');
  assert.equal(movie.params[1].enumOptions.length,19);assert.equal(tv.params[1].enumOptions.length,9);
  calls.length=0;handler=(_,b)=>{assert.equal(b.parentChannelId,2);assert.equal(b.childChannelId,9);return good({items:[item],hasNext:false});};
  assert.equal((await ctx.loadCategory({parentChannelId:'2',childChannelId:'9'})).length,1);
 });
 await test('poster and card details retain source URL, year and update status',()=>{
  const r=ctx.normalize({...item,flags:'2026 / 国产剧 / 大陆',remark:'更4集',watchingCountDesc:'4万人次在看',score:'0.0'});
  assert.equal(r.posterPath,item.coverImg);assert.equal(r.releaseDate,'2026');assert(r.description.includes('更4集'));assert.equal(r.rating,'');
 });
 await test('topics use the observed numbered-page API without replaying cursor pages',async()=>{
  calls.length=0;handler=(url,b)=>{assert(url.endsWith('/vodTopic/getVodList'));assert.equal(b.pageSize,18);return good({items:[item],totalPages:3});};
  await ctx.loadTopic({topicId:'77',page:2});await ctx.loadTopic({topicId:'93',page:1});
  assert.deepEqual(calls.map(c=>[c.body.vodTopicId,c.body.pageIndex]),[[77,2],[93,1]]);
 });
 await test('Netflix latest month is discovered from live catalogue instead of a stale month ID',async()=>{
  handler=(url,b)=>url.endsWith('/topicListView')?good({topicList:[{vodTopicId:5,topicName:'NetflixTOP100'},{vodTopicId:118,topicName:'新月份'}]}):(()=>{assert.equal(b.vodTopicId,118);return good({items:[item]});})();
  assert.equal((await ctx.loadCollection({channelId:'65',collection:'latest'})).length,1);
 });
 await test('alternate player sources stay separate from coherent episodes',async()=>{
  handler=()=>good({...item,playerList:[
   {playerName:'线路A',epList:[{epId:31,epName:'第1集'},{epId:32,epName:'第2集'}]},
   {playerName:'线路B',epList:[{epId:41,epName:'第1集'},{epId:42,epName:'第2集'}]}
  ]});
  const d=await ctx.loadDetail('https://m.yqk3hxe.com/play/12');assert.equal(d.episodeItems.length,2);assert.equal(d.childItems.length,2);
  const alternate=await ctx.loadDetail(d.childItems[1].link);assert(alternate.episodeItems[0].link.endsWith('epId=41'));
 });
 await test('simultaneous signatures initialize one stable device identifier',async()=>{
  const bodies=await Promise.all(Array.from({length:8},()=>ctx.makeBody({nextVal:''})));
  assert.equal(new Set(bodies.map(b=>b.udid)).size,1);
 });
 await test('identical concurrent read requests coalesce',async()=>{
  calls.length=0;handler=async()=>{await new Promise(r=>setTimeout(r,5));return good([item]);};
  await Promise.all([ctx.loadHotSearch({channelId:0}),ctx.loadHotSearch({channelId:0})]);assert.equal(calls.length,1);
 });
 await test('concurrent pages serialize cursor writes and avoid replay duplication',async()=>{
  calls.length=0;handler=async(_,b)=>{await new Promise(r=>setTimeout(r,5));const n=b.nextVal===''?0:b.nextVal[0];return good({items:[item],nextVal:[n+1],hasNext:n<2});};
  const results=await Promise.all([ctx.search({keyword:'并发翻页',page:2}),ctx.search({keyword:'并发翻页',page:3})]);
  assert(results.every(r=>r.length===1));assert.equal(calls.length,3);assert.equal(JSON.stringify(calls.map(c=>c.body.nextVal)),JSON.stringify(['',[1],[2]]));
 });
 await test('failed queue releases and subsequent request succeeds',async()=>{
  handler=()=>good({items:'bad',hasNext:false,nextVal:''});await assert.rejects(()=>ctx.search({keyword:'重试'}),/data.items/);
  handler=()=>good({items:[item],hasNext:false,nextVal:''});assert.equal((await ctx.search({keyword:'重试'})).length,1);
 });
 await test('obsolete cached origins refresh once without reattempting old hosts',async()=>{
  await ctx.setStored('bases',{time:Date.now(),urls:['https://obsolete.example.org']});
  let gets=0;ctx.Widget.http.get=async()=>{gets++;return {data:'var baseApiList = ["https://obsolete.example.org","https://fresh.example.org"];'};};
  calls.length=0;handler=url=>url.startsWith('https://fresh')?good([item]):({statusCode:405,data:'bad'});
  assert.equal((await ctx.loadHotSearch({})).length,1);assert.equal(gets,1);assert.equal(calls.length,2);
 });
 await test('corrupted API cache recovers instead of throwing indexOf error',async()=>{
  await ctx.setStored('bases',{time:Date.now(),urls:{bad:true}});handler=()=>good([item]);assert.equal((await ctx.loadHotSearch({})).length,1);
 });
 await test('details cache reduces repeated source navigation without storing signed media URLs',async()=>{
  calls.length=0;handler=()=>good({...item,playerList:[{checkM3u8:'https://media.example.org/signed-url',epList:[{epId:31,epName:'第1集'}]}]});
  await ctx.loadDetail('https://m.yqk3hxe.com/play/12');await ctx.loadDetail('https://m.yqk3hxe.com/play/12?epId=31');
  assert.equal(calls.length,1);assert(!Array.from(store.values()).some(v=>v.includes('signed-url')));
 });
 await test('foreign episode rejected before quality or playback request',async()=>{
  calls.length=0;handler=()=>good({...item,playerList:[{epList:[{epId:31,epName:'第1集'}]}]});
  await assert.rejects(()=>ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=999'}),/不属于/);assert.equal(calls.length,2);
  assert(calls.every(c=>c.url.endsWith('/index')));
 });
 await test('partial quality failure preserves successful default resource and URLs are freshly generated',async()=>{
  let issued=0;calls.length=0;
  handler=(url,b)=>url.endsWith('/index')?good({...item,playerList:[{epList:[{epId:31,epName:'第1集'}]}]}):url.endsWith('/epDetail')?good([
   {canPlay:true,vodResolution:2,showName:'另一个'}, {canPlay:true,defaultSelect:true,vodResolution:1,showName:'默认'}
  ]):b.vodResolution===1?good({playUrl:'https://media.example.org/'+(++issued)+'.m3u8'}):({data:{result:false,operateCode:10001}});
  const first=await ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31'}),second=await ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31'});
  assert.equal(first.length,1);assert.equal(first[0].name,'默认');assert.notEqual(first[0].url,second[0].url);
  assert.equal(calls.filter(c=>c.url.endsWith('/index')).length,1);
 });
 await test('malformed detail cache is refreshed before source selection',async()=>{
  calls.length=0;ctx.yqkMemory['detail.12']={time:Date.now(),data:{vodId:12,vodName:'错误缓存',playerList:{}}};
  handler=()=>good({...item,playerList:[{epList:[{epId:31,epName:'正片'}]}]});
  const detail=await ctx.loadDetail('https://m.yqk3hxe.com/play/12');assert.equal(detail.title,item.vodName);assert.equal(calls.length,1);
 });
 await test('expired detail metadata refreshes instead of selecting removed episodes',async()=>{
  calls.length=0;ctx.yqkMemory['detail.12']={time:Date.now()-61000,data:{...item,playerList:[{epList:[{epId:30}]}]}};
  handler=()=>good({...item,playerList:[{epList:[{epId:31,epName:'新分集'}]}]});
  const detail=await ctx.loadDetail('https://m.yqk3hxe.com/play/12');assert(detail.episodeItems[0].link.endsWith('epId=31'));assert.equal(calls.length,1);
 });
 await test('concurrent different API reads share one origin discovery',async()=>{
  let gets=0;ctx.Widget.http.get=async()=>{gets++;await new Promise(r=>setTimeout(r,5));return {data:'var baseApiList = ["https://api.example.org"];'};};
  handler=url=>url.endsWith('/getRankList')?good([item]):good({vodTopicList:[{vodList:[item]}]});
  await Promise.all([ctx.loadHome(),ctx.loadHotSearch({channelId:0})]);assert.equal(gets,1);
 });
 await test('malformed items do not commit pagination state',async()=>{
  calls.length=0;handler=(_,b)=>good({items:b.nextVal===''?[item]:[{vodName:'缺少ID'}],nextVal:b.nextVal===''?[1]:[2],hasNext:true});
  await ctx.search({keyword:'事务',page:1});
  const key=Object.keys(ctx.yqkMemory).find(k=>k.startsWith('cursor.')),before=JSON.stringify(ctx.yqkMemory[key]);
  await assert.rejects(()=>ctx.search({keyword:'事务',page:2}),/vodId/);
  assert.equal(JSON.stringify(ctx.yqkMemory[key]),before);
 });
 await test('changing a middle page invalidates obsolete downstream cursors and end marker',async()=>{
  let revision=0;calls.length=0;handler=(_,b)=>good({items:[item],nextVal:b.nextVal===''?[1]:b.nextVal[0]===1?[revision?20:2]:'',hasNext:b.nextVal===''||b.nextVal[0]===1});
  await ctx.search({keyword:'改页',page:3});revision=1;
  await ctx.search({keyword:'改页',page:2});await ctx.search({keyword:'改页',page:3});
  assert.equal(JSON.stringify(calls[calls.length-1].body.nextVal),'[20]');
 });
 await test('cyclic cursors rejected before repeated-page replay can grow',async()=>{
  handler=(_,b)=>good({items:[item],nextVal:b.nextVal===''?[1]:b.nextVal[0]===1?[2]:[1],hasNext:true});
  await assert.rejects(()=>ctx.search({keyword:'循环',page:3}),/循环/);
 });
 await test('menus use named choices and preserve module identities',()=>{
  const category=ctx.WidgetMetadata.modules.find(x=>x.id==='category'),hot=ctx.WidgetMetadata.modules.find(x=>x.id==='hotSearch');
  assert.equal(category.params.find(x=>x.name==='childChannelId').type,'constant');
  assert.equal(hot.params[0].type,'enumeration');assert.equal(hot.params[0].enumOptions.length,5);
 });
 await test('failed persistent writes cannot overwrite fresh session data on next read',async()=>{
  store.set('yqk.v2.detail.12',JSON.stringify({version:'old'}));
  const setter=ctx.Widget.storage.set;ctx.Widget.storage.set=async()=>{throw new Error('disk full');};
  try {await ctx.setStored('detail.12',{version:'new'});assert.equal((await ctx.getStored('detail.12')).version,'new');}
  finally {ctx.Widget.storage.set=setter;}
 });
 await test('large browsing sessions bound in-memory detail and cursor caches',async()=>{
  await ctx.setStored('udid','stable-device-id-for-test');
  for(let i=0;i<100;i++) await ctx.setStored('detail.'+i,{time:Date.now(),data:{}});
  assert.equal(Object.keys(ctx.yqkMemory).filter(k=>k.startsWith('detail.')).length,80);
  assert.equal(ctx.yqkMemory.udid,'stable-device-id-for-test');assert.equal(ctx.yqkMemory['detail.0'],undefined);
 });
 await test('copied search text removes invisible separators and repeated spaces',async()=>{
  handler=(_,body)=>{assert.equal(body.keyword,'流浪地球 2');return good({items:[item],hasNext:false});};
  await ctx.search({keyword:'  流浪\u200b地球\t  2 \ufeff'});
 });
 await test('HTTP rate limit stops requests instead of hammering other hosts',async()=>{
  calls.length=0;await ctx.setStored('bases',{time:Date.now(),urls:['https://one.example.org','https://two.example.org']});
  handler=()=>({statusCode:429,data:'limited'});
  await assert.rejects(()=>ctx.loadHome(),/过于频繁/);assert.equal(calls.length,1);
 });
 await test('new episode absent from cached metadata refreshes once then plays',async()=>{
  calls.length=0;let details=0;
  handler=url=>url.endsWith('/index')?good({...item,playerList:[{epList:[{epId:++details===1?31:32,epName:'新集'}]}]}):url.endsWith('/epDetail')?good([{canPlay:true,vodResolution:1}]):good({playUrl:'https://media.example.org/new.m3u8'});
  await ctx.loadDetail('https://m.yqk3hxe.com/play/12');
  const resources=await ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=32'});
  assert.equal(resources.length,1);assert.equal(details,2);
 });
 await test('broken optional players and invalid episodes do not hide valid sources',async()=>{
  handler=()=>good({...item,playerList:[null,{epList:[null,{epId:0},{epId:'nope'}]},
   {playerName:'线路 A',epList:[null,{epId:31,epName:''},{epId:'31',epName:'重复'}]},
   {playerName:'线路 B',epList:[{epId:41,epName:'正片'}]}]});
  const d=await ctx.loadDetail('https://m.yqk3hxe.com/play/12');
  assert.equal(d.episodeItems.length,1);assert.equal(d.episodeItems[0].title,'第 1 集');assert.equal(d.childItems.length,2);
  assert.equal(d.childItems[0].title,'线路 A（当前）');assert(d.childItems[1].description.startsWith('1 集'));
  const other=await ctx.loadDetail(d.childItems[1].link);assert.equal(other.childItems[1].title,'线路 B（当前）');
 });
 await test('null and duplicate quality entries preserve distinct available resolutions',async()=>{
  calls.length=0;handler=url=>url.endsWith('/index')?good({...item,playerList:[{epList:[{epId:31}]}]}):url.endsWith('/epDetail')?good([null,
   {canPlay:true,vodResolution:1,showName:'普通'}, {canPlay:true,vodResolution:1,defaultSelect:true,showName:'默认'},
   {canPlay:true,vodResolution:2,showName:'备用'}]):good({playUrl:'https://media.example.org/'+calls[calls.length-1].body.vodResolution+'.m3u8'});
  const resources=await ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31'});
  assert.equal(resources.length,2);assert.equal(resources[0].name,'默认');assert.equal(calls.filter(c=>c.url.endsWith('/playUrl')).length,2);
 });
 await test('highest allowed quality is preferred while restricted qualities stay unrequested',async()=>{
  calls.length=0;handler=(url,b)=>url.endsWith('/epDetail')?good([
   {canPlay:true,vodResolution:99,showName:'流畅',defaultSelect:true},
   {canPlay:false,vodResolution:5,showName:'4K'},
   {canPlay:true,vodResolution:2,showName:'1080P'},
   {canPlay:true,vodResolution:1,showName:'720P'}
  ]):good({playUrl:'https://media.example.org/'+b.vodResolution+'.m3u8'});
  const r=await ctx.resourcesForEpisode(31,{playerName:'A'},false);
  assert.deepEqual(Array.from(r,x=>x.name),['1080P','720P','流畅']);
  assert.deepEqual(calls.filter(c=>c.url.endsWith('/playUrl')).map(c=>c.body.vodResolution),[2,1,99]);
  calls.length=0;const d=await ctx.resourcesForEpisode(31,{playerName:'A'},false,'default');assert.equal(d[0].name,'流畅');
 });
 await test('failed highest quality retains the lower working option',async()=>{
  handler=(url,b)=>url.endsWith('/epDetail')?good([{canPlay:true,vodResolution:1,showName:'1080P'},{canPlay:true,vodResolution:2,showName:'720P'}]):b.vodResolution===1?({statusCode:503,data:'bad'}):good({playUrl:'https://media.example.org/working.m3u8'});
  const r=await ctx.resourcesForEpisode(31,{playerName:'A'},false);assert.equal(r.length,1);assert.equal(r[0].name,'720P');
 });
 await test('bad HLS movie sources automatically reach fourth matching feature source',async()=>{
  calls.length=0;ctx.Widget.http.get=async url=>url.includes('/js/baseUrlList.js')?({data:'var baseApiList = ["https://api.example.org"];'}):({statusCode:url.includes('/61.')?200:403,data:url.includes('/61.')?'#EXTM3U\n#EXTINF:6,\nsegment.ts':'forbidden'});
  handler=(url,b)=>url.endsWith('/index')?good({...item,playerList:[31,41,51,61].map((id,i)=>({playerName:'线路'+i,epList:[{epId:id,epName:i===0?'HD中字':'正片'}]}))}):url.endsWith('/epDetail')?good([{canPlay:true,vodResolution:1,showName:'标清'}]):good({playUrl:'https://media.example.org/'+b.epId+'.m3u8'});
  const r=await ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31'});
  assert.equal(r[0].name,'线路3 · 标清');assert.equal(r[0].description,'线路3');
  assert.deepEqual(calls.filter(c=>c.url.endsWith('/playUrl')).map(c=>c.body.epId),[31,41,51,61]);
 });
 await test('TV fallback matches actual episode label including leading zeros',async()=>{
  calls.length=0;ctx.Widget.http.get=async url=>url.includes('/js/baseUrlList.js')?({data:'var baseApiList = ["https://api.example.org"];'}):({statusCode:url.includes('/41.')?200:403,data:'#EXTM3U\n#EXTINF:6,\nsegment.ts'});
  handler=(url,b)=>url.endsWith('/index')?good({...item,playerList:[
   {playerName:'A',epList:[{epId:31,epName:'第01集'},{epId:32,epName:'第02集'}]},
   {playerName:'B',epList:[{epId:41,epName:'第1集'},{epId:42,epName:'第2集'}]}
  ]}):url.endsWith('/epDetail')?good([{canPlay:true,vodResolution:1}]):good({playUrl:'https://media.example.org/'+b.epId+'.m3u8'});
  await ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31'});
  assert.deepEqual(calls.filter(c=>c.url.endsWith('/playUrl')).map(c=>c.body.epId),[31,41]);
 });
 await test('single-episode TV sources cannot switch to a different episode',async()=>{
  calls.length=0;ctx.Widget.http.get=async url=>url.includes('/js/baseUrlList.js')?({data:'var baseApiList = ["https://api.example.org"];'}):({statusCode:403,data:'denied'});
  handler=(url,b)=>url.endsWith('/index')?good({...item,playerList:[{epList:[{epId:31,epName:'第1集'}]},{epList:[{epId:41,epName:'第2集'}]}]}):url.endsWith('/epDetail')?good([{canPlay:true,vodResolution:1}]):good({playUrl:'https://media.example.org/'+b.epId+'.m3u8'});
  await assert.rejects(()=>ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31'}),/尝试 1 条/);
  assert.deepEqual(calls.filter(c=>c.url.endsWith('/playUrl')).map(c=>c.body.epId),[31]);
 });
 await test('HTML masquerading as a playlist rejected with a four-source attempt cap',async()=>{
  calls.length=0;ctx.Widget.http.get=async url=>url.includes('/js/baseUrlList.js')?({data:'var baseApiList = ["https://api.example.org"];'}):({statusCode:200,data:'<html>login</html>'});
  handler=(url,b)=>url.endsWith('/index')?good({...item,playerList:[31,41,51,61,71].map(epId=>({epList:[{epId,epName:'HD'}]}))}):url.endsWith('/epDetail')?good([{canPlay:true,vodResolution:1}]):good({playUrl:'https://media.example.org/'+b.epId+'.m3u8'});
  await assert.rejects(()=>ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31',sourceLimit:4}),/尝试 4 条/);
  assert.equal(calls.filter(c=>c.url.endsWith('/playUrl')).length,4);
 });
 await test('HLS rate limiting stops quality and source fallback immediately',async()=>{
  calls.length=0;ctx.Widget.http.get=async url=>url.includes('/js/baseUrlList.js')?({data:'var baseApiList = ["https://api.example.org"];'}):({statusCode:429,data:'limited'});
  handler=(url,b)=>url.endsWith('/index')?good({...item,playerList:[31,41].map(epId=>({epList:[{epId,epName:'HD'}]}))}):url.endsWith('/epDetail')?good([{canPlay:true,vodResolution:1},{canPlay:true,vodResolution:2}]):good({playUrl:'https://media.example.org/'+b.epId+'.m3u8'});
  await assert.rejects(()=>ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31'}),/过于频繁/);
  assert.equal(calls.filter(c=>c.url.endsWith('/playUrl')).length,1);
 });
 await test('non-HLS resources never trigger full media downloads for probing',async()=>{
  const gets=[];ctx.Widget.http.get=async url=>{gets.push(url);return {data:'var baseApiList = ["https://api.example.org"];'};};
  handler=url=>url.endsWith('/index')?good({...item,playerList:[{epList:[{epId:31,epName:'HD'}]}]}):url.endsWith('/epDetail')?good([{canPlay:true,vodResolution:1}]):good({playUrl:'https://media.example.org/video.mp4'});
  await ctx.loadResource({link:'https://m.yqk3hxe.com/play/12?epId=31'});assert.equal(gets.length,1);assert(gets[0].endsWith('/baseUrlList.js'));
 });
 console.log(passed+' mock tests passed; run live-test.cjs for production API checks.');
})().catch(e=>{console.error(e);process.exitCode=1;});
