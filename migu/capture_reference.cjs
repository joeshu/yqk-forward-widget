// Developer-only capture of reviewed, hash-pinned reference functions. No network or account access.
const fs=require('node:fs'),vm=require('node:vm'),crypto=require('node:crypto');
const path=require('node:path');
if(!process.argv[2]) throw new Error('Usage: node migu/capture_reference.cjs /path/to/iptv');
const base=path.join(process.argv[2],'extractors','migu')+path.sep;
const approved={"androidURL.js": "880256bc796919f632e7aca6034c8ce78ef632d542defc777142983096e00b83", "ddCalcuURL.js": "3500d9a2c064af9ccf4748a969abb2955c7821961d882ce91cc322f8495552cb"};
for(const [name,digest] of Object.entries(approved)){if(crypto.createHash('sha256').update(fs.readFileSync(base+name)).digest('hex')!==digest)throw new Error('Reference changed; review before executing: '+name);}
const src=fs.readFileSync(base+'androidURL.js','utf8'),dd=fs.readFileSync(base+'ddCalcuURL.js','utf8');
const helper=src.slice(src.indexOf('function getSaltAndSign('),src.indexOf('async function getAndroidURL('));
const modern=src.slice(src.indexOf('async function getAndroidURL('),src.indexOf('async function getAndroidURL720p('));
const legacy=src.slice(src.indexOf('async function getAndroidURL720p('),src.indexOf('async function get302URL('));
const proof=dd.slice(dd.indexOf('const list ='),dd.indexOf('export {'));
const stamp=1792454400000,seed='0123456789abcdef0123456789abcdef';
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
(async()=>{
 const cases=[['guest_hd',false,3,3,'631780532'],['account_hd',true,3,3,'631780532'],['account_guest_downgrade',true,3,2,'631780532'],['guest_sd',false,2,2,'631780532'],['account_sports',true,3,3,'641886683']];let results=[];
 for(const [name,account,requested,returned,pid]of cases){
  const isLegacy=!account&&requested>=3, calls=[];
  const sandbox={getStringMD5:x=>crypto.createHash('md5').update(x).digest('hex'),Date:class extends Date{constructor(...args){super(...(args.length?args:[stamp]));}static now(){return stamp;}},Math:Object.create(Math),enableHDR:true,enableH265:true,userId:'',process:{env:{}},getDateString:()=> '20261020',printDebug:()=>{},printYellow:()=>{},printGreen:()=>{},printRed:()=>{},fetchUrl:async(url,opts)=>{calls.push({url,headers:opts.headers});return {rid:'SUCCESS',code:'200',body:{content:{contId:pid},urlInfo:{url:'http://gslbmgsplive.miguvideo.com/live/index.m3u8?timestamp=20261020064125&ProgramID='+pid+'&puData='+seed,rateType:returned}}};}};
  sandbox.Math.random=()=>.123456;
  const context=vm.createContext(sandbox,{codeGeneration:{strings:false,wasm:false}});
  vm.runInContext(proof+'\n'+helper+'\n'+modern+'\n'+legacy,context,{timeout:1000});
  const expr=isLegacy?`getAndroidURL720p('${pid}',{enableHDR:true,enableH265:true})`:`getAndroidURL('${account?'123456789':''}','${account?'synthetic-token':''}','${pid}',${requested},{enableHDR:true,enableH265:true})`;
  const reply=await vm.runInContext(expr,context,{timeout:1000});
  const req=calls[0];const headers=Object.fromEntries(Object.entries(req.headers).map(([k,v])=>[k,String(v)]).sort(([a],[b])=>a.localeCompare(b,'en')));
  // Hash the URL and sorted header entries separately; do not publish signed addresses.
  results.push({name,account,requested,returned,pid,timestamp_ms:stamp,salt_prefix:123456,request_hash:hash(req.url),headers_hash:hash(JSON.stringify(Object.entries(req.headers).map(([k,v])=>[k.toLowerCase(),String(v)]).sort())),stream_hash:hash(reply.url)});
 }
 process.stdout.write(JSON.stringify({reference_commit:'e475b2f6d24029f844ada2b362d703c8b88c2e9b',cases:results},null,2));
})().catch(e=>{process.stderr.write(e.name+': '+e.message);process.exitCode=1;});
