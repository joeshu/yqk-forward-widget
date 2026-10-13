import fastify from 'fastify';
import {createServer} from 'node:http';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import widgetSources from 'widget-sources';
import {nativeSources,createNativeAdapter} from './native/index.js';
import {referenceSources,createReferenceAdapter} from './reference/adapter.js';
const sources=[...widgetSources,...nativeSources,...referenceSources];
import {PersistentStorage,errorMessage} from './runtime.js';
import {createAdapter} from './adapter.js';
import {withOperation,operationContext,auditBlocked} from './operation.js';
import {createDiagnostics,normalizeHome,normalizeCards,contentClasses,STATUS_ID,sourceLayout} from './presentation.js';
import buildIdentity from 'catpaw-build-identity';

export function createService({storage,config={},request,serverFactory}={}){
  const controllers=new Set(),server=fastify({logger:false,forceCloseConnections:true,bodyLimit:256*1024,serverFactory:serverFactory||((handle)=>createServer(handle))}),adapters=new Map(),diagnostics=createDiagnostics(storage,buildIdentity),homeCache=new Map(),healthScopes=new Map();
  function adapter(source){if(!adapters.has(source.key))adapters.set(source.key,source.kind==='reference-adapter'?createReferenceAdapter(source,storage,request,controllers):source.kind?createNativeAdapter(source,storage,request,controllers):createAdapter(source,storage,config,request,controllers));return adapters.get(source.key);}
  server.setErrorHandler((e,_req,reply)=>reply.code(e.statusCode===400?400:502).send({err:errorMessage(e),code:e.code||'SOURCE_ERROR'}));
  async function rawCall(source,action,req,reply){return source.kind==='reference-adapter'?adapter(source).invoke(action,req,reply):adapter(source)[action==='homeVideo'?'homeVod':action](req.body||{});}
  async function sourceHome(source,req,reply){const old=homeCache.get(source.key);if(old&&Date.now()-old.at<15000)return old.promise;const promise=Promise.resolve().then(()=>rawCall(source,'home',req,reply)).then(normalizeHome);homeCache.set(source.key,{at:Date.now(),promise});promise.catch(()=>homeCache.delete(source.key));return promise;}
  async function call(source,action,req,reply){const scope=operationContext();if(scope?.readOnly&&!['home','homeVod','homeVideo','category','detail','search'].includes(action))throw auditBlocked('只读检查不执行初始化、播放或代理');if(action==='category'&&req.body?.id===STATUS_ID)return diagnostics.category(source);if(action==='category'&&req.body?.id==='__play'&&scope?.readOnly)throw auditBlocked('只读检查不修改播放设置');const started=Date.now();try{let out;if(action==='home'){const home=await sourceHome(source,req,reply);if(!contentClasses(home).length){const error=new Error('原站暂无可浏览分类');if(!scope?.readOnly)await diagnostics.record(source,'home',null,error,Date.now()-started);out={...await diagnostics.home(source,home),catalogueError:error.message,code:'SOURCE_EMPTY'};}else out=await diagnostics.home(source,home);}else {out=await rawCall(source,action,req,reply);if(['homeVod','homeVideo'].includes(action)&&Array.isArray(out?.list)&&!out.list.length){const h=await sourceHome(source,req,reply),first=contentClasses(h)[0];if(first){const selected=Object.fromEntries((h.filters?.[first.type_id]||[]).map(f=>[f.key,f.init??f.value?.[0]?.v??'']));out=await rawCall(source,'category',{...req,body:{id:first.type_id,page:1,filters:selected,extend:selected}},reply);}}if(action==='category'&&req.body?.id==='__play')homeCache.delete(source.key);if(['category','homeVod','homeVideo','search'].includes(action))out=normalizeCards(out,source);}
    if(!scope?.readOnly&&!(action==='category'&&req.body?.id==='__play'))await diagnostics.record(source,action,out,null,Date.now()-started);return out;
  }catch(error){if(scope?.blockedError)error=scope.blockedError;if(!scope?.readOnly)await diagnostics.record(source,action,null,error,Date.now()-started);if(action==='home')return {...await diagnostics.home(source,{class:[],filters:{}}),catalogueError:errorMessage(error),code:error.code||'SOURCE_ERROR'};throw error;}}
  const scopedCall=(source,action,req,reply)=>{const scope=healthScopes.get(req.headers?.['x-catpaw-health-scope']);return scope?withOperation(scope,()=>call(source,action,req,reply)):call(source,action,req,reply);};
  server.decorate('healthAction',async(site,action,payload,{signal}={})=>{const token=randomUUID();healthScopes.set(token,{readOnly:true,signal});try{return await server.inject({method:'POST',url:site.api+'/'+action,headers:{'x-catpaw-health-scope':token},payload});}finally{healthScopes.delete(token);}});
  server.get('/check',async()=>({run:true,build:buildIdentity}));
  server.get('/diagnostics/:key',async req=>{const source=sources.find(s=>s.key===req.params.key);if(!source){const e=new Error('来源不存在');e.statusCode=400;throw e;}return diagnostics.get(source);});
  const enabledSources=sources.filter(s=>s.enabled!==false);
  server.get('/config',async()=>({video:{sites:enabledSources.map(s=>({key:'nodejs_'+s.key,name:s.title,type:3,enable:true,searchable:1,quickSearch:1,filterable:1,style:sourceLayout(s).style,api:'/spider/'+s.key+'/3'}))},read:{sites:[]},comic:{sites:[]},music:{sites:[]},pan:{sites:[]},color:[]}));
  for(const source of sources){const prefix='/spider/'+source.key+'/3';for(const action of ['init','home','homeVod','homeVideo','category','detail','play','search'])server.post(prefix+'/'+action,async (req,reply)=>scopedCall(source,action,req,reply));if(source.kind==='reference-adapter'){server.get(prefix+'/proxy/:provider/:sessionId',async(req,reply)=>scopedCall(source,'proxy',req,reply));server.get(prefix+'/proxy/*',async(req,reply)=>scopedCall(source,'proxy',req,reply));}}
  server.addHook('preClose',async()=>{for(const controller of controllers)controller.abort();});
  server.addHook('onClose',async()=>{for(const controller of controllers)controller.abort();for(const agent of controllers.agents||[])agent.destroy();await storage.flush?.();adapters.clear();});
  return server;
}
let active=null,lifecycle=Promise.resolve();
async function close(){if(active){const previous=active;active=null;await previous.close();}}
export function start(input={}){const config=input.default||input;const run=lifecycle.then(async()=>{await close();const folder=process.env.CATPAW_DATA_DIR||process.env.NODE_PATH||'.',storage=await new PersistentStorage(path.join(folder,'joeshu-catpaw-storage.json')).init();active=createService({storage,config,serverFactory:typeof catServerFactory==='function'?catServerFactory:undefined});await active.listen({host:'127.0.0.1',port:Number(process.env.DEV_HTTP_PORT||0)});});lifecycle=run.catch(()=>{});return run;}
export function stop(){const run=lifecycle.then(close);lifecycle=run.catch(()=>{});return run;}
