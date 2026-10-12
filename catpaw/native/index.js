import {createQimiao} from './qimiao.js';
import {createDuboku} from './duboku.js';
export const nativeSources=[{key:'joeshu_qimiao',title:'奇妙短剧',version:'0.1.0',kind:'qimiao',referenceKey:'duanjuqimiao'},{key:'joeshu_duboku',title:'独播库影视',version:'0.1.0',kind:'duboku',referenceKey:'wexDuBoKu'}];
export function createNativeAdapter(source,storage,request,controllers){const factory={qimiao:createQimiao,duboku:createDuboku}[source.kind];if(!factory)throw Error('未登记的原生源');return factory(source,storage,request,controllers);}
