const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {build}=require('./deploy.cjs');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'yqk-deploy-test-'));let passed=0;
function test(name,fn){fn();passed++;console.log('PASS '+name);}
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
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
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
