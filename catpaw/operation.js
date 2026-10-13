import {AsyncLocalStorage} from 'node:async_hooks';
const context=new AsyncLocalStorage();
export const operationContext=()=>context.getStore();
export const withOperation=(scope,fn)=>context.run(scope,fn);
export function auditBlocked(message){const e=new Error(message);e.code='AUDIT_BLOCKED';const scope=context.getStore();if(scope?.readOnly)scope.blockedError=e;return e;}
export function checkRequestBoundary(url,method,data){const scope=context.getStore();if(scope?.signal?.aborted)throw scope.signal.reason||new Error('请求已取消');if(!scope?.readOnly)return;const u=new URL(url),route=decodeURIComponent(u.pathname).replace(/[_-]/g,'/');const values=[...u.searchParams.values()].join(' ');let action='';if(data&&typeof data==='object')action=String(data.action||data.method||'');else if(typeof data==='string'&&data.length<8192){try{const x=JSON.parse(data);action=String(x.action||x.method||'');}catch{action=new URLSearchParams(data).get('action')||'';}}
 const mutations=/(?:sign\/?up|register|registration|login|logout|reward|session\/?create|create\/?session|check\/?in|purchase|payment|recharge|activate|new\/public\/init)/i;
 if(mutations.test(route)||mutations.test(action)||/^(?:login|register|reward|purchase)$/i.test(values.trim()))throw auditBlocked('只读检查跳过登录、注册、奖励或其他业务动作');
}
export function attachOperationAbort(controller){const signal=context.getStore()?.signal;if(!signal)return()=>{};const abort=()=>controller.abort(signal.reason);if(signal.aborted)abort();else signal.addEventListener('abort',abort,{once:true});return()=>signal.removeEventListener('abort',abort);}
