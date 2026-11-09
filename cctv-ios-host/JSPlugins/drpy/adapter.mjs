import engine from './upstream/drpy2.js'

function stripDrpyImportsAndExports(raw){
  let s=String(raw??'')
  for(let pass=0;pass<8;pass++){
    const next=s.replace(/(^|[\r\n;}]|\*\/)\s*import\b[^;\r\n]*;?/g,'$1;')
    if(next===s)break
    s=next
  }
  return s
    .replace(/(^|[\r\n;}]|\*\/)\s*export\s+default(?:\s+|(?=[{[(]))/g,'$1var __drpyDefault=')
    .replace(/(^|[\r\n;}]|\*\/)\s*export\s*\{[^}]*\}\s*;?/g,'$1;')
    .replace(/(^|[\r\n;}]|\*\/)\s*export\s+(?=(?:var|let|const|function|async|class)\b)/g,'$1')
}

function loadRuleFromExt(ext){
  const code=/^https?:\/\//i.test(ext)?(typeof globalThis.request==='function'?globalThis.request(ext,{method:'GET'}):''):ext
  if(!code||typeof code!=='string'||!code.trim()||/^\s*<(?:!doctype|html)/i.test(code)){
    throw new Error('DRPY 站点规则加载失败或远端返回了非脚本内容：'+ext)
  }
  const cleanExt=stripDrpyImportsAndExports(code).replace(/\b(?:var|let|const)\s+rule\s*=/g,'rule =')
  const parsed=new Function(`var rule;\n${cleanExt}\nreturn typeof rule!=='undefined'&&rule&&Object.keys(rule).length?rule:(typeof __drpyDefault!=='undefined'?__drpyDefault:undefined);`)()
  if(!parsed||typeof parsed!=='object'||!Object.keys(parsed).length){
    throw new Error('DRPY 站点规则未定义有效 rule 对象：'+ext)
  }
  return parsed
}

export function load(source,options){
  if(source&&typeof source==='object'){
    engine.init(Object.assign({},source,options&&typeof options==='object'?options:{}))
    return {...engine,init(){},detail:ids=>engine.detail(Array.isArray(ids)?ids[0]:ids)}
  }
  const text=String(source??'')
  const isEngineShell=text.includes('assets://js/lib/cheerio.min.js')||((text.includes('cheerio.min.js')||text.includes('crypto-js.js'))&&(/\b(?:let|var|const)\s+rule\s*=\s*\{\s*\}|[,;]\s*rule\s*=\s*\{\s*\}/.test(text)||text.includes('DRPY')||text.includes('gbk.js')||text.includes('init_test')))
  const rawExt=typeof options==='string'?options.trim():(options&&typeof options==='object'?String(options.ext??options.extend??options.rule??'').trim():'')
  if(isEngineShell){
    if(rawExt){
      const ext=loadRuleFromExt(rawExt)
      engine.init(ext)
      return {...engine,init(){},detail:ids=>engine.detail(Array.isArray(ids)?ids[0]:ids)}
    }
    if(options&&typeof options==='object'&&(options.host||options.title||options.一级||options.二级)){
      engine.init(options)
      return {...engine,init(){},detail:ids=>engine.detail(Array.isArray(ids)?ids[0]:ids)}
    }
    throw new Error('此 drpy 站点仅提供引擎壳（drpy2.min.js），未在合集 ext 中提供规则地址或内容')
  }
  const cleanText=stripDrpyImportsAndExports(text)
  const rule=new Function(`${cleanText}\nreturn typeof rule!=='undefined'&&rule&&Object.keys(rule).length?rule:(typeof __drpyDefault!=='undefined'?__drpyDefault:(typeof plugin!=='undefined'?plugin:undefined));`)()
  if(!rule||typeof rule!=='object'||!Object.keys(rule).length){
    if(rawExt){
      const ext=loadRuleFromExt(rawExt)
      engine.init(ext)
      return {...engine,init(){},detail:ids=>engine.detail(Array.isArray(ids)?ids[0]:ids)}
    }
    throw new Error('文件未定义 drpy rule 对象')
  }
  engine.init(Object.assign(rule,options&&typeof options==='object'?options:{}))
  return {...engine,init(){},detail:ids=>engine.detail(Array.isArray(ids)?ids[0]:ids)}
}
