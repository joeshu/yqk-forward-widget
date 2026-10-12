import {bad,card,client,detail,encode,decode,ids,keyword,page,text} from './common.js';

const API='https://sv.baidu.com',UA='Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
const headers={'User-Agent':UA,'Talos-Module-Version':'1.0.71.1','Talos-Module-Name':'shortDrama','Content-Type':'application/x-www-form-urlencoded; charset=utf-8'};
const arr=x=>Array.isArray(x)?x:[];

export function createBaiduDuanju(source,storage,request,controllers){
 const http=client(source,storage,request,controllers).http;
 async function post(path,body){const res=await http.request({method:'POST',url:`${API}${path}`,data:new URLSearchParams(body).toString(),headers});if(res.status<200||res.status>=300)throw Error('好看短剧请求失败：HTTP '+res.status);return typeof res.data==='string'?JSON.parse(res.data):res.data||{};}
 const shelf=()=>post('/haokan/ui-feed/playletShelfFeed?osbranch=a0',{from:'feed'});
 function rows(data){return arr(data?.data?.list).map(x=>card(source,{id:String(x.playlet_id||''),name:x.playlet_title,pic:x.playlet_poster,remarks:x.episodes_num_text})).filter(Boolean);}
 return {
  async init(){return {};},
  async home(){const d=await shelf(),classes=[];for(const group of arr(d?.data?.playlet_shelf_filter_panel))for(const t of arr(group.tag_list))if(t.tag_id&&t.name)classes.push({type_id:String(t.tag_id),type_name:text(t.name)});return {class:classes,filters:{}};},
  async homeVod(){const d=await shelf(),list=[];for(const group of arr(d?.data?.playlet_shelf_list))list.push(...rows({data:{list:group.list}}));return {list};},
  async category(body={}){const n=page(body.page),id=String(body.id||'');if(!/^\d+$/.test(id))throw bad('分类不属于此源');const d=await post('/haokan/ui-feed/playletTagsFeed?osbranch=a0',{tag_id:id,rn:'30',pn:String(n)}),list=rows(d);return {page:n,pagecount:list.length?Math.max(n+1,n):n,list};},
  async search(body={}){const q=keyword(body);if(!q)return {page:1,pagecount:1,list:[]};const d=await post('/haokan/ui-interact/playlet/search/sugs?osbranch=a0',{search_word:q}),list=arr(d?.data).map(x=>card(source,{id:String(x.id||''),name:x.title,pic:x.cover_url,remarks:x.tag})).filter(Boolean);return {page:1,pagecount:1,list};},
  async detail(body={}){const out=[];for(const id of ids(body)){const playlet=decode(source.key,'vod',id);if(!/^\d+$/.test(playlet))throw bad('短剧编号无效');let vid='';try{const common='enable_enter_playlet=0&seek_time=0&hotspot=0&auto_show_hot_point_panel=0&type=playlet&commonlist_id='+Date.now()+'&scene=&vid=&enable_atlas=0&mark_pn=&uk=&ctime=0&from=playlet_new&id='+playlet+'&rn=10&pn=1&direction=3',c=await post('/appui/api?osbranch=a0',{'video/commonlist':common});vid=String(c?.['video/commonlist']?.data?.results?.[0]?.content?.vid||'');}catch{}const d=await post('/haokan/ui-video/playlet/rec/detail?osbranch=a0',{vid,playlet_id:playlet}),data=d?.data||{},eps=arr(data.vid_list).map((v,i)=>({name:`第${i+1}集`,id:JSON.stringify({vid:String(v),playlet})}));out.push(detail(source,id,{name:data.playlet_title||'好看短剧',pic:data.playlet_poster,content:data.description,remarks:`${eps.length}集`},[{name:'好看短剧',episodes:eps}]));}return {list:out};},
  async play(body={}){let item;try{item=JSON.parse(decode(source.key,'episode',body.id));}catch{throw bad('短剧播放编号无效');}if(!item?.vid||!/^\d+$/.test(item.playlet||''))throw bad('短剧播放编号无效');const form=`method=post&vid=${encodeURIComponent(item.vid)}&immersive_mode=v4_5&tplname=feed_small_video&tag=playlet_talos&tab=detail&external_from=&is_dp_video=0&immersive_square_type=3&video_set_id=${encodeURIComponent(item.playlet)}&play_screen_type=1&play_volume_type=2&play_external_device_type=1`,d=await post('/appui/api?osbranch=a0',{'video/relate':form}),urls=arr(d?.['video/relate']?.data?.cur_video?.clarityUrl),media=urls.find(x=>x.key==='1080p')||urls.find(x=>x.key==='sc')||urls[0];if(!media?.url)throw Error('好看短剧暂未返回播放地址');return {parse:0,url:media.url,header:{'User-Agent':UA},extra:{nodanmu:true}};}
 };
}
