// Shared with the standalone Forward builds; keep this module free of Node APIs.
export function createAsyncCache({ttlMs=30000,maxEntries=64}={}) {
  const entries=new Map();
  return function read(key,fetch) {
    const old=entries.get(key),now=Date.now();
    if(old&&(!old.settled||(now>=old.at&&now-old.at<ttlMs)))return old.promise;
    if(old)entries.delete(key);
    if(entries.size>=maxEntries) {
      for(const [key,entry] of entries)if(entry.settled){entries.delete(key);break;}
    }
    const entry={settled:false,at:0};
    entry.promise=Promise.resolve().then(fetch).then(value=>{
      entry.settled=true;entry.at=Date.now();return value;
    },error=>{
      if(entries.get(key)===entry)entries.delete(key);
      throw error;
    });
    // Never evict an in-flight entry just to cache a different request.
    if(entries.size<maxEntries)entries.set(key,entry);
    return entry.promise;
  };
}

export function pageSignature(items) {
  return JSON.stringify([...new Set(items.map(v=>String(v.vod_id||v.link||v.id||'')))].sort());
}

export async function nextPage(list,load,{timeoutMs=500}={}) {
  let timer;
  try {
    const next=await Promise.race([Promise.resolve().then(load),new Promise(resolve=>{
      timer=setTimeout(()=>resolve(null),timeoutMs);
    })]);
    if(next===null)return {more:false,msg:'当前页已加载；下一页仍在检查，稍后刷新可确认翻页'};
    if(next.length&&pageSignature(next)!==pageSignature(list))return {more:true};
    return {more:false,...(next.length?{msg:'原站下一页重复，已停止继续翻页'}:{})};
  } catch(error) {
    return {more:false,msg:'下一页暂未确认',error};
  } finally {clearTimeout(timer);}
}
