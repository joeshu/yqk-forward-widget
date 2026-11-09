import engine from './upstream/drpy2.js'

export function load(source,options){
  if(source&&typeof source==='object'){
    engine.init(Object.assign({},source,options&&typeof options==='object'?options:{}))
    return {...engine,init(){},detail:ids=>engine.detail(Array.isArray(ids)?ids[0]:ids)}
  }
  const text=String(source??'')
  const isEngineShell=text.includes('assets://js/lib/cheerio.min.js')&&(/\b(?:let|var|const)\s+rule\s*=\s*\{\s*\}|[,;]\s*rule\s*=\s*\{\s*\}/.test(text)||text.includes('DRPY')||text.includes('gbk.js')||text.includes('init_test'))
  const ext=typeof options==='string'?options.trim():(options&&typeof options==='object'?String(options.ext??options.extend??options.rule??'').trim():'')
  if(isEngineShell){
    if(ext){
      engine.init(ext)
      return {...engine,init(){},detail:ids=>engine.detail(Array.isArray(ids)?ids[0]:ids)}
    }
    if(options&&typeof options==='object'&&(options.host||options.title||options.一级||options.二级)){
      engine.init(options)
      return {...engine,init(){},detail:ids=>engine.detail(Array.isArray(ids)?ids[0]:ids)}
    }
    throw new Error('此 drpy 站点仅提供引擎壳（drpy2.min.js），未在合集 ext 中提供规则地址或内容')
  }
  const rule=new Function(`${text}\nreturn typeof rule!=='undefined'?rule:(typeof plugin!=='undefined'?plugin:undefined);`)()
  if(!rule||typeof rule!=='object'){
    if(ext){
      engine.init(ext)
      return {...engine,init(){},detail:ids=>engine.detail(Array.isArray(ids)?ids[0]:ids)}
    }
    throw new Error('文件未定义 drpy rule 对象')
  }
  engine.init(Object.assign(rule,options&&typeof options==='object'?options:{}))
  return {...engine,init(){},detail:ids=>engine.detail(Array.isArray(ids)?ids[0]:ids)}
}
