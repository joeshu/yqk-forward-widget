// Build static publishing files, without installing dependencies or deploying remotely.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
function build(base,output,options={}) {
 const url=new URL(base);
 if(url.protocol!=='https:' || url.username || url.password || url.search || url.hash ||
    !url.hostname.includes('.') || /(^|\.)(invalid|localhost)$/.test(url.hostname) ||
    /(^|\.)example\.(com|org|net)$/.test(url.hostname) || !/^\/(?:[A-Za-z0-9_-]+\/?)*$/.test(url.pathname)) throw new Error('请使用你的真实 HTTPS 服务域名，不要填示例、账号密码、查询参数或特殊路径');
 const baseUrl=url.href.replace(/\/$/,'');
 const prefix=url.pathname.replace(/^\//,'').replace(/\/$/,'');
 // Pages mounts the uploaded artifact at its repository path already.
 const key=name=>prefix && !options.pages?prefix+'/'+name:name;
 const code=fs.readFileSync(path.join(__dirname,'yqk.js'),'utf8');
 const sandbox=vm.createContext({});new vm.Script(code).runInContext(sandbox,{timeout:1000});
 const meta=sandbox.WidgetMetadata;
 if(!meta || !/^\d+\.\d+\.\d+$/.test(meta.version)) throw new Error('脚本版本格式错误');
 const name='yqk-'+meta.version+'.js',scriptUrl=baseUrl+'/'+name;
 const manifest=JSON.parse(fs.readFileSync(path.join(__dirname,'yqk.fwd.example'),'utf8'));
 Object.assign(manifest.widgets[0],{id:meta.id,title:meta.title,author:meta.author,version:meta.version,requiredVersion:meta.requiredVersion,url:scriptUrl});
 manifest.description='一起看搜索、分类、首页、详情与访客播放';
 const common=[{key:'Access-Control-Allow-Origin',value:'*'},{key:'X-Content-Type-Options',value:'nosniff'},{key:'Cache-Control',value:'public, max-age=60, must-revalidate'}];
 const headers=[{source:'/'+key('yqk.fwd'),headers:[...common,{key:'Content-Type',value:'application/json; charset=utf-8'}]},
 {source:'/'+key(name),headers:[...common,{key:'Content-Type',value:'application/javascript; charset=utf-8'}]}];
 const files={
  [key(name)]:code,
  [key('yqk.fwd')]:JSON.stringify(manifest,null,2)+'\n',
  'vercel.json':JSON.stringify({$schema:'https://openapi.vercel.sh/vercel.json',framework:null,outputDirectory:'.',headers},null,2)+'\n',
  '_headers':headers.map(h=>h.source+'\n'+h.headers.map(x=>'  '+x.key+': '+x.value).join('\n')).join('\n\n')+'\n',
  [key('release.json')]:JSON.stringify({version:meta.version,scriptUrl,subscriptionUrl:baseUrl+'/yqk.fwd',sourceSha256:crypto.createHash('sha256').update(code).digest('hex')},null,2)+'\n'
 };
 if(options.pages) {
  delete files['vercel.json'];delete files['_headers'];files['.nojekyll']='';
 }
 const target=path.resolve(output);
 // Reject an occupied directory: never overwrite someone's server config/files.
 if(fs.existsSync(target) && fs.readdirSync(target).length) throw new Error('输出目录不是空目录，请换一个目录；未覆盖任何文件');
 fs.mkdirSync(target,{recursive:true});
 for(const [name,value] of Object.entries(files)) {
  const file=path.join(target,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,value,{flag:'wx'});
 }
 return {directory:target,version:meta.version,scriptUrl,subscriptionUrl:baseUrl+'/yqk.fwd'};
}
module.exports={build};
if(require.main===module) {
 try {
  if(process.argv.length<3 || process.argv.length>5 || (process.argv[4] && process.argv[4]!=='--pages')) throw new Error('用法：node deploy.cjs https://你的域名[/目录] [空输出目录] [--pages]');
  console.log(JSON.stringify(build(process.argv[2],process.argv[3]||path.join(__dirname,'publish'),{pages:process.argv[4]==='--pages'}),null,2));
 } catch(e) { console.error(e.message);process.exitCode=1; }
}
