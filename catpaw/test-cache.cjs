const assert=require('node:assert/strict');
(async()=>{
  const {createAsyncCache,nextPage}=await import('./cache.js'),{cachedListing}=await import('./native/common.js');
  let passed=0;
  async function test(name,fn){await fn();passed++;console.log('PASS '+name);}
  const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};

  await test('overlapping requests share pending work even beyond TTL; freshness starts on completion',async()=>{
    const now=Date.now;let time=100,calls=0;Date.now=()=>time;
    try{
      const read=createAsyncCache({ttlMs:30}),wait=deferred(),fetch=()=>{calls++;return wait.promise;};
      const first=read('one',fetch);await Promise.resolve();time=200;
      assert.equal(read('one',fetch),first);assert.equal(calls,1);
      wait.resolve('done');assert.equal(await first,'done');time=229;
      assert.equal(await read('one',()=>{throw Error('expired too early');}),'done');
      time=230;assert.equal(await read('one',()=>++calls),2);
      time=10;assert.equal(await read('one',()=>++calls),3);
    }finally{Date.now=now;}
  });
  await test('both synchronous and asynchronous failures release their cache slot for retry',async()=>{
    const read=createAsyncCache();
    await assert.rejects(read('one',()=>{throw Error('sync');}),/sync/);
    await assert.rejects(read('one',async()=>{throw Error('async');}),/async/);
    assert.equal(await read('one',()=>42),42);
  });
  await test('cache pressure evicts completed work while retaining in-flight coalescing',async()=>{
    const read=createAsyncCache({maxEntries:2}),wait=deferred();
    const pending=read('pending',()=>wait.promise);await read('old',()=>1);await read('new',()=>2);
    assert.equal(read('pending',()=>{throw Error('duplicated');}),pending);
    assert.equal(await read('old',()=>3),3);wait.resolve(4);assert.equal(await pending,4);
  });
  await test('slow native next page returns loaded cards and reuses the eventual result',async()=>{
    const wait=deferred(),calls=[],listing=cachedListing(n=>{calls.push(n);return n===2?wait.promise:[{vod_id:String(n)}];},{timeoutMs:20});
    const started=Date.now(),first=await listing(1,{});
    assert.equal(first.list[0].vod_id,'1');assert.equal(first.pagecount,1);
    assert.match(first.msg,/仍在检查/);assert(Date.now()-started<1500);
    wait.resolve([{vod_id:'2'}]);await wait.promise;
    assert.equal((await listing(1,{})).pagecount,2);assert.deepEqual(calls,[1,2]);
  });
  await test('reordered duplicate pages do not create an infinite pagination loop',async()=>{
    const listing=cachedListing(n=>n===1?[{vod_id:'a'},{vod_id:'b'}]:[{vod_id:'b'},{vod_id:'a'},{vod_id:'a'}]);
    const result=await listing(1,{});assert.equal(result.pagecount,1);assert.match(result.msg,/重复/);
  });
  await test('Forward list mode requests only the selected page and keeps repeat reads cached',async()=>{
    const calls=[],listing=cachedListing(n=>{calls.push(n);return [{vod_id:String(n)}];},{probeNext:false});
    await listing(1,{});await listing(1,{});await listing(2,{});assert.deepEqual(calls,[1,2]);
  });
  await test('the highest valid page never probes page 2001',async()=>{
    const calls=[],listing=cachedListing(n=>{calls.push(n);return [{vod_id:String(n)}];});
    assert.equal((await listing(2000,{})).pagecount,2000);assert.deepEqual(calls,[2000]);
  });
  await test('a late failed probe is handled and the next refresh can retry',async()=>{
    const wait=deferred();let attempt=0;
    const listing=cachedListing(n=>n===1?[{vod_id:'1'}]:++attempt===1?wait.promise:[{vod_id:'2'}],{timeoutMs:10});
    assert.equal((await listing(1,{})).pagecount,1);wait.reject(Error('late failure'));
    await new Promise(resolve=>setImmediate(resolve));assert.equal((await listing(1,{})).pagecount,2);
  });
  await test('failed next-page reads keep current cards and omit an invented total',async()=>{
    const listing=cachedListing(n=>{if(n>1)throw Error('offline');return [{vod_id:'1'}];});
    const result=await listing(1,{});assert.equal(result.list.length,1);assert.equal(result.pagecount,1);assert(result.msg);assert(!('total' in result));
    assert.deepEqual(await nextPage([],()=>[]),{more:false});
  });
  console.log(passed+' cache and pagination tests passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
