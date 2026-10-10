const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto'),vm=require('node:vm');
const {build}=require('./deploy.cjs');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'yqk-deploy-test-'));let passed=0;
function test(name,fn){fn();passed++;console.log('PASS '+name);}
test('repository subscription versions and immutable script snapshots match current source',()=>{
 const manifest=JSON.parse(fs.readFileSync(path.join(__dirname,'yqk.fwd'),'utf8'));
 for(const [source,id,prefix] of [['yqk.js','joeshu.yqk','yqk-'],['souju.js','joeshu.souju','souju-'],['kanju.js','joeshu.kanju','kanju-'],['zip0.js','joeshu.zip0','zip0-'],['4kvm.js','joeshu.4kvm','4kvm-'],['auete.js','joeshu.auete','auete-'],['xiaobao.js','joeshu.xiaobao','xiaobao-'],['anime1.js','joeshu.anime1','anime1-']]){
  const code=fs.readFileSync(path.join(__dirname,source),'utf8'),context=vm.createContext({});
  vm.runInContext(code,context);const meta=context.WidgetMetadata,widget=manifest.widgets.find(x=>x.id===id);
  assert(widget);assert.equal(widget.version,meta.version);
  const filename=prefix+meta.version+'.js';assert(widget.url.endsWith('/'+filename));
  assert.equal(fs.readFileSync(path.join(__dirname,filename),'utf8'),code);
 }
});
test('reject HTTP, reserved placeholders, credentials, fragments and query strings',()=>{
 for(const url of ['http://widgets.test.org','https://example.invalid','https://example.com','https://u:p@widgets.test.org','https://widgets.test.org/?x=1','https://widgets.test.org/#x']) assert.throws(()=>build(url,path.join(root,'invalid')));
 assert(!fs.existsSync(path.join(root,'invalid')));
});
let release;
test('manifest links match generated script and metadata version',()=>{
 release=build('https://widgets.test.org/',path.join(root,'release'));
 const fwd=JSON.parse(fs.readFileSync(path.join(release.directory,'yqk.fwd'),'utf8'));
 assert.equal(fwd.widgets[0].url,release.scriptUrl);assert.equal(fwd.widgets[0].version,release.version);
 const code=fs.readFileSync(path.join(release.directory,'yqk-'+release.version+'.js'));
 const info=JSON.parse(fs.readFileSync(path.join(release.directory,'release.json'),'utf8'));
 assert.equal(info.sourceSha256,crypto.createHash('sha256').update(code).digest('hex'));
});
test('collection contains an independent versioned Souju widget and script',()=>{
 const fwd=JSON.parse(fs.readFileSync(path.join(release.directory,'yqk.fwd'),'utf8'));
 assert.equal(fwd.widgets.length,8);const widget=fwd.widgets[1];assert.equal(widget.id,'joeshu.souju');
 assert.equal(widget.url,'https://widgets.test.org/souju-'+widget.version+'.js');
 assert.equal(fs.readFileSync(path.join(release.directory,'souju-'+widget.version+'.js'),'utf8'),fs.readFileSync(path.join(__dirname,'souju.js'),'utf8'));
 const headers=JSON.parse(fs.readFileSync(path.join(release.directory,'vercel.json'),'utf8')).headers;
 assert(headers.some(h=>h.source==='/souju-'+widget.version+'.js'));
});
test('third Kanju widget has matching script, version, headers and release entry',()=>{
 const fwd=JSON.parse(fs.readFileSync(path.join(release.directory,'yqk.fwd'),'utf8')),widget=fwd.widgets.find(x=>x.id==='joeshu.kanju');
 assert(widget);assert.equal(widget.title,'看剧AI');assert.equal(widget.url,'https://widgets.test.org/kanju-'+widget.version+'.js');
 assert.equal(fs.readFileSync(path.join(release.directory,'kanju-'+widget.version+'.js'),'utf8'),fs.readFileSync(path.join(__dirname,'kanju.js'),'utf8'));
 assert(JSON.parse(fs.readFileSync(path.join(release.directory,'vercel.json'),'utf8')).headers.some(x=>x.source==='/kanju-'+widget.version+'.js'));
 assert(JSON.parse(fs.readFileSync(path.join(release.directory,'release.json'),'utf8')).widgets.some(x=>x.id===widget.id&&x.version===widget.version));
});
test('fourth ZIP0 widget has its own script, headers and release entry',()=>{
 const fwd=JSON.parse(fs.readFileSync(path.join(release.directory,'yqk.fwd'),'utf8')),widget=fwd.widgets.find(x=>x.id==='joeshu.zip0');
 assert(widget);assert.equal(widget.title,'ZIP0影视');assert.equal(widget.url,'https://widgets.test.org/zip0-'+widget.version+'.js');
 assert.equal(fs.readFileSync(path.join(release.directory,'zip0-'+widget.version+'.js'),'utf8'),fs.readFileSync(path.join(__dirname,'zip0.js'),'utf8'));
 assert(JSON.parse(fs.readFileSync(path.join(release.directory,'vercel.json'),'utf8')).headers.some(x=>x.source==='/zip0-'+widget.version+'.js'));
 assert(JSON.parse(fs.readFileSync(path.join(release.directory,'release.json'),'utf8')).widgets.some(x=>x.id===widget.id&&x.version===widget.version));
});
test('fifth 4K影视 widget includes its standalone guest player, headers and release entry',()=>{
 const fwd=JSON.parse(fs.readFileSync(path.join(release.directory,'yqk.fwd'),'utf8')),widget=fwd.widgets.find(x=>x.id==='joeshu.4kvm');
 assert(widget);assert.equal(widget.title,'4K影视');assert.equal(widget.url,'https://widgets.test.org/4kvm-'+widget.version+'.js');
 assert.equal(fs.readFileSync(path.join(release.directory,'4kvm-'+widget.version+'.js'),'utf8'),fs.readFileSync(path.join(__dirname,'4kvm.js'),'utf8'));
 assert(JSON.parse(fs.readFileSync(path.join(release.directory,'vercel.json'),'utf8')).headers.some(x=>x.source==='/4kvm-'+widget.version+'.js'));
 assert(JSON.parse(fs.readFileSync(path.join(release.directory,'release.json'),'utf8')).widgets.some(x=>x.id===widget.id&&x.version===widget.version));
});
test('sixth Auete widget has matching script, headers and release metadata',()=>{
 const fwd=JSON.parse(fs.readFileSync(path.join(release.directory,'yqk.fwd'),'utf8')),w=fwd.widgets.find(x=>x.id==='joeshu.auete');
 assert(w);assert.equal(w.title,'Auete影视');assert.equal(fs.readFileSync(path.join(release.directory,'auete-'+w.version+'.js'),'utf8'),fs.readFileSync(path.join(__dirname,'auete.js'),'utf8'));
 assert(JSON.parse(fs.readFileSync(path.join(release.directory,'vercel.json'),'utf8')).headers.some(x=>x.source==='/auete-'+w.version+'.js'));
 assert(JSON.parse(fs.readFileSync(path.join(release.directory,'release.json'),'utf8')).widgets.some(x=>x.id===w.id&&x.version===w.version));
});
test('XiaoBao and Anime1 independently publish scripts, headers and release entries',()=>{
 const fwd=JSON.parse(fs.readFileSync(path.join(release.directory,'yqk.fwd'),'utf8'));
 for(const prefix of ['xiaobao','anime1']){const w=fwd.widgets.find(x=>x.id==='joeshu.'+prefix);assert(w);const name=prefix+'-'+w.version+'.js';assert.equal(fs.readFileSync(path.join(release.directory,name),'utf8'),fs.readFileSync(path.join(__dirname,prefix+'.js'),'utf8'));assert(JSON.parse(fs.readFileSync(path.join(release.directory,'vercel.json'),'utf8')).headers.some(x=>x.source==='/'+name));assert(JSON.parse(fs.readFileSync(path.join(release.directory,'release.json'),'utf8')).widgets.some(x=>x.id===w.id&&x.version===w.version));}
});
test('subdirectory URL is preserved without duplicated slash',()=>{
 const r=build('https://widgets.test.org/Resource/Yqk/',path.join(root,'sub'));
 assert.equal(r.subscriptionUrl,'https://widgets.test.org/Resource/Yqk/yqk.fwd');
 assert(fs.existsSync(path.join(r.directory,'Resource/Yqk/yqk.fwd')));
 assert(JSON.parse(fs.readFileSync(path.join(r.directory,'vercel.json'),'utf8')).headers[0].source==='/Resource/Yqk/yqk.fwd');
});
test('Vercel and Cloudflare response headers explicitly describe raw files',()=>{
 const config=JSON.parse(fs.readFileSync(path.join(release.directory,'vercel.json'),'utf8'));
 assert.equal(config.framework,null);assert.equal(config.outputDirectory,'.');
 assert.equal(config.headers[0].headers.find(h=>h.key==='Content-Type').value,'application/json; charset=utf-8');
 assert(fs.readFileSync(path.join(release.directory,'_headers'),'utf8').includes('application/javascript'));
});
test('Pages repository URL maps to root artifact files without double repository prefix',()=>{
 const r=build('https://joeshu.github.io/yqk-forward-widget',path.join(root,'pages'),{pages:true});
 assert.equal(r.subscriptionUrl,'https://joeshu.github.io/yqk-forward-widget/yqk.fwd');
 assert(fs.existsSync(path.join(r.directory,'yqk.fwd')));assert(!fs.existsSync(path.join(r.directory,'yqk-forward-widget')));
 const fwd=JSON.parse(fs.readFileSync(path.join(r.directory,'yqk.fwd'),'utf8'));
 assert.equal(fwd.widgets[0].url,'https://joeshu.github.io/yqk-forward-widget/yqk-'+r.version+'.js');
 assert(fs.existsSync(path.join(r.directory,'.nojekyll')));assert(!fs.existsSync(path.join(r.directory,'vercel.json')));assert(!fs.existsSync(path.join(r.directory,'_headers')));
});
test('Pages custom domain root uses its real domain rather than a fixed GitHub username',()=>{
 const r=build('https://widgets.test.org',path.join(root,'pages-custom'),{pages:true});
 assert.equal(r.subscriptionUrl,'https://widgets.test.org/yqk.fwd');assert(fs.existsSync(path.join(r.directory,'yqk.fwd')));
});
test('Pages update retains the previously published script byte for byte',()=>{
 const r=build('https://joeshu.github.io/yqk-forward-widget',path.join(root,'pages-history'),{pages:true});
 assert.equal(fs.readFileSync(path.join(r.directory,'yqk-0.5.0.js'),'utf8'),fs.readFileSync(path.join(__dirname,'yqk-0.5.0.js'),'utf8'));
 assert.equal(fs.readFileSync(path.join(r.directory,'souju-0.1.0.js'),'utf8'),fs.readFileSync(path.join(__dirname,'souju-0.1.0.js'),'utf8'));
 assert.equal(fs.readFileSync(path.join(r.directory,'yqk-'+r.version+'.js'),'utf8'),fs.readFileSync(path.join(__dirname,'yqk.js'),'utf8'));
});
test('occupied output rejected without modifying existing files',()=>{
 const before=fs.readFileSync(path.join(release.directory,'yqk.fwd'),'utf8');
 assert.throws(()=>build('https://other.test.org',release.directory),/不是空目录/);
 assert.equal(fs.readFileSync(path.join(release.directory,'yqk.fwd'),'utf8'),before);
});
(async()=>{
 const http=require('node:http');
 const config=JSON.parse(fs.readFileSync(path.join(release.directory,'vercel.json'),'utf8'));
 const server=http.createServer((req,res)=>{
  const entry=config.headers.find(h=>h.source===req.url);
  if(!entry){res.writeHead(404);return res.end();}
  for(const header of entry.headers) res.setHeader(header.key,header.value);
  res.end(fs.readFileSync(path.join(release.directory,req.url.slice(1))));
 });
 try{await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});}
 catch(e){if(e.code==='EPERM'){console.log('SKIP local HTTP smoke test: this environment blocks loopback listeners.');console.log(passed+' deployment tests passed; no remote deployment performed.');return;}throw e;}
 try {
  const origin='http://127.0.0.1:'+server.address().port;
  const fwd=await fetch(origin+'/yqk.fwd');assert.equal(fwd.status,200);assert(fwd.headers.get('content-type').startsWith('application/json'));
  const manifest=await fwd.json(),script=await fetch(origin+new URL(manifest.widgets[0].url).pathname);
  assert.equal(script.status,200);assert(script.headers.get('content-type').startsWith('application/javascript'));
  assert.equal(await script.text(),fs.readFileSync(path.join(__dirname,'yqk.js'),'utf8'));
  passed++;console.log('PASS generated subscription and raw JS can be served together over local HTTP');
 } finally {await new Promise(r=>server.close(r));}
 console.log(passed+' deployment tests passed; no remote deployment performed.');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
