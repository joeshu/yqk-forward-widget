import fastify from 'fastify';
import {createServer} from 'node:http';
import path from 'node:path';
import widgetSources from 'widget-sources';
import {nativeSources,createNativeAdapter} from './native/index.js';
const sources=[...widgetSources,...nativeSources];
import {PersistentStorage,errorMessage} from './runtime.js';
import {createAdapter} from './adapter.js';

export function createService({storage,config={},request,serverFactory}={}){
  const controllers=new Set(),server=fastify({logger:false,forceCloseConnections:true,bodyLimit:256*1024,serverFactory:serverFactory||((handle)=>createServer(handle))}),adapters=new Map();
  function adapter(source){if(!adapters.has(source.key))adapters.set(source.key,source.kind?createNativeAdapter(source,storage,request,controllers):createAdapter(source,storage,config,request,controllers));return adapters.get(source.key);}
  server.setErrorHandler((e,_req,reply)=>reply.code(e.statusCode===400?400:502).send({err:errorMessage(e),code:e.code||'SOURCE_ERROR'}));
  server.get('/check',async()=>({run:true}));
  server.get('/config',async()=>({video:{sites:sources.map(s=>({key:'nodejs_'+s.key,name:s.title,type:3,api:'/spider/'+s.key+'/3'}))},read:{sites:[]},comic:{sites:[]},music:{sites:[]},pan:{sites:[]},color:[]}));
  for(const source of sources){const prefix='/spider/'+source.key+'/3';for(const action of ['init','home','homeVod','category','detail','play','search'])server.post(prefix+'/'+action,async req=>adapter(source)[action](req.body||{}));}
  server.addHook('preClose',async()=>{for(const controller of controllers)controller.abort();});
  server.addHook('onClose',async()=>{for(const controller of controllers)controller.abort();for(const agent of controllers.agents||[])agent.destroy();await storage.flush?.();adapters.clear();});
  return server;
}
let active=null,lifecycle=Promise.resolve();
async function close(){if(active){const previous=active;active=null;await previous.close();}}
export function start(input={}){const config=input.default||input;const run=lifecycle.then(async()=>{await close();const folder=process.env.CATPAW_DATA_DIR||process.env.NODE_PATH||'.',storage=await new PersistentStorage(path.join(folder,'joeshu-catpaw-storage.json')).init();active=createService({storage,config,serverFactory:typeof catServerFactory==='function'?catServerFactory:undefined});await active.listen({host:'127.0.0.1',port:Number(process.env.DEV_HTTP_PORT||0)});});lifecycle=run.catch(()=>{});return run;}
export function stop(){const run=lifecycle.then(close);lifecycle=run.catch(()=>{});return run;}
