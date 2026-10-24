import engine from './upstream/drpy2.js'

export function load(source,options){
  const rule=new Function(`${source}\nreturn typeof rule!=='undefined'?rule:undefined;`)()
  if(!rule||typeof rule!=='object')throw new Error('文件未定义 drpy rule 对象')
  engine.init(Object.assign(rule,options&&typeof options==='object'?options:{}))
  return {...engine,init(){},detail:ids=>engine.detail(ids[0])}
}
