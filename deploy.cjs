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
 manifest.title='joeshu 影视组件合集';
 manifest.description='一起看 + 搜剧AI + 看剧AI + ZIP0影视 + 4K影视 + Auete影视 + 小宝影院 + Anime1动漫：推荐、分类、搜索、完整分集与访客播放';
 const extraCode=fs.readFileSync(path.join(__dirname,'souju.js'),'utf8');
 const extraContext=vm.createContext({});new vm.Script(extraCode).runInContext(extraContext,{timeout:1000});
 const extraMeta=extraContext.WidgetMetadata;
 if(!extraMeta || !/^\d+\.\d+\.\d+$/.test(extraMeta.version)) throw new Error('搜剧AI版本格式错误');
 const extraName='souju-'+extraMeta.version+'.js';
 manifest.widgets=[manifest.widgets[0],{id:extraMeta.id,title:extraMeta.title,description:extraMeta.description,author:extraMeta.author,version:extraMeta.version,requiredVersion:extraMeta.requiredVersion,url:baseUrl+'/'+extraName}];
 const kanjuCode=fs.readFileSync(path.join(__dirname,'kanju.js'),'utf8'),kanjuContext=vm.createContext({});new vm.Script(kanjuCode).runInContext(kanjuContext,{timeout:1000});
 const kanjuMeta=kanjuContext.WidgetMetadata;
 if(!kanjuMeta||!/^\d+\.\d+\.\d+$/.test(kanjuMeta.version))throw new Error('看剧AI版本格式错误');
 const kanjuName='kanju-'+kanjuMeta.version+'.js';
 manifest.widgets.push({id:kanjuMeta.id,title:kanjuMeta.title,description:kanjuMeta.description,author:kanjuMeta.author,version:kanjuMeta.version,requiredVersion:kanjuMeta.requiredVersion,url:baseUrl+'/'+kanjuName});
 const zipCode=fs.readFileSync(path.join(__dirname,'zip0.js'),'utf8'),zipContext=vm.createContext({});new vm.Script(zipCode).runInContext(zipContext,{timeout:1000});
 const zipMeta=zipContext.WidgetMetadata;
 if(!zipMeta||!/^\d+\.\d+\.\d+$/.test(zipMeta.version))throw new Error('ZIP0版本格式错误');
 const zipName='zip0-'+zipMeta.version+'.js';
 manifest.widgets.push({id:zipMeta.id,title:zipMeta.title,description:zipMeta.description,author:zipMeta.author,version:zipMeta.version,requiredVersion:zipMeta.requiredVersion,url:baseUrl+'/'+zipName});
 const vm4Code=fs.readFileSync(path.join(__dirname,'4kvm.js'),'utf8'),vm4Context=vm.createContext({});new vm.Script(vm4Code).runInContext(vm4Context,{timeout:1000});
 const vm4Meta=vm4Context.WidgetMetadata;
 if(!vm4Meta||!/^\d+\.\d+\.\d+$/.test(vm4Meta.version))throw new Error('4K影视版本格式错误');
 const vm4Name='4kvm-'+vm4Meta.version+'.js';
 manifest.widgets.push({id:vm4Meta.id,title:vm4Meta.title,description:vm4Meta.description,author:vm4Meta.author,version:vm4Meta.version,requiredVersion:vm4Meta.requiredVersion,url:baseUrl+'/'+vm4Name});
 const auCode=fs.readFileSync(path.join(__dirname,'auete.js'),'utf8'),auContext=vm.createContext({});new vm.Script(auCode).runInContext(auContext,{timeout:1000});
 const auMeta=auContext.WidgetMetadata;
 if(!auMeta||!/^\d+\.\d+\.\d+$/.test(auMeta.version))throw new Error('Auete影视版本格式错误');
 const auName='auete-'+auMeta.version+'.js';
 manifest.widgets.push({id:auMeta.id,title:auMeta.title,description:auMeta.description,author:auMeta.author,version:auMeta.version,requiredVersion:auMeta.requiredVersion,url:baseUrl+'/'+auName});
 const newWidgets=['xiaobao','anime1'].map(prefix=>{
  const code=fs.readFileSync(path.join(__dirname,prefix+'.js'),'utf8'),context=vm.createContext({});new vm.Script(code).runInContext(context,{timeout:1000});const meta=context.WidgetMetadata;
  if(!meta||!/^\d+\.\d+\.\d+$/.test(meta.version))throw new Error(prefix+'版本格式错误');
  const name=prefix+'-'+meta.version+'.js';manifest.widgets.push({id:meta.id,title:meta.title,description:meta.description,author:meta.author,version:meta.version,requiredVersion:meta.requiredVersion,url:baseUrl+'/'+name});return {name,code};
 });
 const common=[{key:'Access-Control-Allow-Origin',value:'*'},{key:'X-Content-Type-Options',value:'nosniff'},{key:'Cache-Control',value:'public, max-age=60, must-revalidate'}];
 const headers=[{source:'/'+key('yqk.fwd'),headers:[...common,{key:'Content-Type',value:'application/json; charset=utf-8'}]},
 {source:'/'+key(name),headers:[...common,{key:'Content-Type',value:'application/javascript; charset=utf-8'}]},
 {source:'/'+key(extraName),headers:[...common,{key:'Content-Type',value:'application/javascript; charset=utf-8'}]},
 {source:'/'+key(zipName),headers:[...common,{key:'Content-Type',value:'application/javascript; charset=utf-8'}]},
 {source:'/'+key(vm4Name),headers:[...common,{key:'Content-Type',value:'application/javascript; charset=utf-8'}]},
 {source:'/'+key(kanjuName),headers:[...common,{key:'Content-Type',value:'application/javascript; charset=utf-8'}]}];
 headers.push({source:'/'+key(auName),headers:[...common,{key:'Content-Type',value:'application/javascript; charset=utf-8'}]});
 newWidgets.forEach(w=>headers.push({source:'/'+key(w.name),headers:[...common,{key:'Content-Type',value:'application/javascript; charset=utf-8'}]}));
 const files={
  [key(auName)]:auCode,
  [key(name)]:code,
  [key(extraName)]:extraCode,
  [key(kanjuName)]:kanjuCode,
  [key(zipName)]:zipCode,
  [key(vm4Name)]:vm4Code,
  [key('yqk.fwd')]:JSON.stringify(manifest,null,2)+'\n',
  'vercel.json':JSON.stringify({$schema:'https://openapi.vercel.sh/vercel.json',framework:null,outputDirectory:'.',headers},null,2)+'\n',
  '_headers':headers.map(h=>h.source+'\n'+h.headers.map(x=>'  '+x.key+': '+x.value).join('\n')).join('\n\n')+'\n',
  [key('release.json')]:JSON.stringify({version:meta.version,scriptUrl,subscriptionUrl:baseUrl+'/yqk.fwd',widgets:manifest.widgets.map(w=>({id:w.id,version:w.version,url:w.url})),sourceSha256:crypto.createHash('sha256').update(code).digest('hex')},null,2)+'\n'
 };
 newWidgets.forEach(w=>files[key(w.name)]=w.code);
 if(options.pages) {
  delete files['vercel.json'];delete files['_headers'];files['.nojekyll']='';
  // Pages replaces the whole artifact. Keep published scripts accessible to
  // clients that have not refreshed their subscription yet.
  for(const archived of fs.readdirSync(__dirname)) {
   if(/^(?:yqk|souju|kanju|zip0|4kvm|auete|xiaobao|anime1)-\d+\.\d+\.\d+\.js$/.test(archived) && archived!==name && archived!==extraName && archived!==kanjuName && archived!==zipName && archived!==vm4Name && archived!==auName && !newWidgets.some(w=>w.name===archived)) {
    files[archived]=fs.readFileSync(path.join(__dirname,archived),'utf8');
   }
  }
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
