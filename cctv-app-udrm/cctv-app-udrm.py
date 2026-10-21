#!/usr/bin/env python3
# CCTV App UDRM 0.2.2: Python + system JavaScriptCore, without a JVM or subprocess.
# Fixed official SDK / Unicorn WASM are downloaded and hash checked at first use.
# This entry runs inside APTV; no runtime HAR import or captured credentials.
import sys
import types

JS_SOURCES = {
    'koo_vm.js': (
        '/* Host-side ELF/JNI adapter. Official vendor code is never patched. */\n'
        'class KooVM {\n'
        ' constructor(uc,plan,entropy) {\n'
        '  this.uc=uc;this.plan=plan;this.e=new uc.Unicorn(uc.ARCH_ARM64,uc.MODE_ARM);\n'
        '  this.base=0x10000000;this.stub=0x20000000;this.heap=0x30000000;this.stack=0x40000000;this.stop=0x50000000;\n'
        '  this.bump=this.heap;this.allocations=new Map();this.freeBlocks=[];this.keys=new Map();this.keySequence=1;this.objects=new Map();this.objectSequence=1;this.natives={};this.states=new Map();this.trap=null;this.counts={};this.entropy=entropy;this.entropyPosition=0;this.randomSeed=1;this.files=new Map();this.nextFD=100;\n'
        '  const e=this.e;\n'
        '  for(const [address,size] of [[this.base,plan.length],[this.stub,0x20000],[this.heap,0x800000],[this.stack,0x200000],[this.stop,0x1000]])e.mem_map(address,size,uc.PROT_ALL);\n'
        '  for(const segment of plan.segments)e.mem_write(this.base+segment.address,this.unbase64(segment.data));\n'
        '  this.importAddresses={};this.addressImports={};plan.imports.forEach((name,i)=>{this.importAddresses[name]=this.stub+i*8;this.addressImports[this.stub+i*8]=name;});\n'
        '  for(const r of plan.relocations) {\n'
        '   let value;\n'
        '   if(r.type===1027)value=this.base+r.addend;\n'
        '   else if([257,1025,1026].includes(r.type))value=(r.import?this.importAddresses[r.import]:this.base+r.symbol)+r.addend;\n'
        "   else throw Error('unsupported ELF relocation '+r.type);\n"
        '   this.write64(this.base+r.offset,value);\n'
        '  }\n'
        '  e.hook_add(uc.HOOK_CODE,(_u,address)=>{this.trap=Number(address);e.emu_stop();},null,this.stub,this.stub+0x1ffff);\n'
        '  this.jniTable=this.allocate(0x1000,true);this.env=this.allocate(8,true);this.write64(this.env,this.jniTable);\n'
        '  this.jvmTable=this.allocate(0x100,true);this.jvm=this.allocate(8,true);this.write64(this.jvm,this.jvmTable);\n'
        "  for(let i=0;i<240;i++){const address=this.stub+0x4000+i*8;this.write64(this.jniTable+i*8,address);this.addressImports[address]='jni:'+i;}\n"
        "  for(let i=0;i<10;i++){const address=this.stub+0x5000+i*8;this.write64(this.jvmTable+i*8,address);this.addressImports[address]='jvm:'+i;}\n"
        '  this.errno=this.allocate(16,true);this.tls=this.allocate(0x1000,true);\n'
        '  if(uc.ARM64_REG_TPIDR_EL0)e.reg_write_i64(uc.ARM64_REG_TPIDR_EL0,BigInt(this.tls));\n'
        '  // Import data are ordinary host ABI storage, never credentials or rights state.\n'
        '  if(this.importAddresses.__stack_chk_guard)this.write64(this.importAddresses.__stack_chk_guard,0x18d4a256);\n'
        ' }\n'
        ' unbase64(text){const s=atob(text),b=new Uint8Array(s.length);for(let i=0;i<s.length;i++)b[i]=s.charCodeAt(i);return b;}\n'
        " base64(bytes){let s='';for(let i=0;i<bytes.length;i+=8192)s+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(s);}\n"
        " read(address,size){if(!Number.isSafeInteger(size)||size<0||size>16*1024*1024)throw Error('host read limit');return this.e.mem_read(address,size);}\n"
        ' write(address,bytes){this.e.mem_write(address,bytes);}\n'
        ' read32(address){return new DataView(this.read(address,4).buffer).getUint32(0,true);}\n'
        ' read64(address){return Number(new DataView(this.read(address,8).buffer).getBigUint64(0,true));}\n'
        ' write32(address,value){const b=new Uint8Array(4);new DataView(b.buffer).setUint32(0,value,true);this.write(address,b);}\n'
        ' write64(address,value){const b=new Uint8Array(8);new DataView(b.buffer).setBigUint64(0,BigInt.asUintN(64,BigInt(value)),true);this.write(address,b);}\n'
        " cbytes(address,limit=1048576){if(!address)throw Error('NULL C string');const chunks=[];let size=0;\n"
        '  while(size<limit){const n=Math.min(128,limit-size,4096-((address+size)&4095));const b=this.read(address+size,n);const end=b.indexOf(0);if(end>=0){chunks.push(b.subarray(0,end));size+=end;const out=new Uint8Array(size);let p=0;for(const c of chunks){out.set(c,p);p+=c.length;}return out;}chunks.push(b);size+=n;}\n'
        "  throw Error('unterminated C string');\n"
        ' }\n'
        " string(address,limit){const b=this.cbytes(address,limit);let s='';for(let i=0;i<b.length;i+=8192)s+=String.fromCharCode(...b.subarray(i,i+8192));return s;}\n"
        ' cstring(text){const b=new Uint8Array(text.length+1);for(let i=0;i<text.length;i++)b[i]=text.charCodeAt(i)&255;const p=this.allocate(b.length);this.write(p,b);return p;}\n'
        ' allocate(size,zero=false){\n'
        "  if(!Number.isSafeInteger(size)||size<0||size>4*1024*1024+4096)throw Error('host malloc limit');\n"
        '  size=Math.max(16,Math.ceil(size/16)*16);let pointer,index=-1,best=Infinity;\n'
        '  for(let i=0;i<this.freeBlocks.length;i++){const block=this.freeBlocks[i];if(block.size>=size&&block.size<best){index=i;best=block.size;}}\n'
        '  if(index>=0){\n'
        '   const block=this.freeBlocks.splice(index,1)[0];pointer=block.pointer;\n'
        '   if(block.size>size)this.freeBlocks.push({pointer:pointer+size,size:block.size-size});\n'
        '  }else{\n'
        "   pointer=this.bump;if(pointer+size>this.heap+0x800000)throw Error('host heap exhausted');this.bump+=size;\n"
        '  }\n'
        '  this.allocations.set(pointer,size);if(zero)this.write(pointer,new Uint8Array(size));return pointer;\n'
        ' }\n'
        ' free(pointer){\n'
        "  if(!pointer)return;const size=this.allocations.get(pointer);if(size===undefined)throw Error('host invalid free');\n"
        '  this.allocations.delete(pointer);this.freeBlocks.push({pointer,size});this.freeBlocks.sort((a,b)=>a.pointer-b.pointer);\n'
        '  const merged=[];\n'
        '  for(const block of this.freeBlocks){const last=merged[merged.length-1];if(last&&last.pointer+last.size===block.pointer)last.size+=block.size;else merged.push({...block});}\n'
        '  while(merged.length&&merged[merged.length-1].pointer+merged[merged.length-1].size===this.bump)this.bump=merged.pop().pointer;\n'
        '  this.freeBlocks=merged;\n'
        ' }\n'
        ' object(kind,value){const id=this.allocate(16,true);this.objects.set(id,{kind,value});return id;}\n'
        " reg(i){return Number(this.e.reg_read_i64(this.uc['ARM64_REG_X'+i]));}\n"
        ' result(value){this.e.reg_write_i64(this.uc.ARM64_REG_X0,BigInt.asUintN(64,BigInt(value||0)));}\n'
        ' invoke(address,args=[],nested=false){\n'
        '  const e=this.e,uc=this.uc;let context=null;\n'
        '  if(nested){context=e.context_alloc();e.context_save(context);}\n'
        '  try{\n'
        '   const sp=nested?Number(e.reg_read_i64(uc.ARM64_REG_SP))-0x2000:this.stack+0x1ff000;\n'
        '   e.reg_write_i64(uc.ARM64_REG_SP,BigInt(sp));e.reg_write_i64(uc.ARM64_REG_LR,BigInt(this.stop));\n'
        "   for(let i=0;i<args.length;i++)e.reg_write_i64(uc['ARM64_REG_X'+i],BigInt.asUintN(64,BigInt(args[i])));\n"
        '   const result=this.run(address);\n'
        "   if(nested&&result&&typeof result==='object')throw Error('unsupported nested host I/O');\n"
        '   return result;\n'
        '  }finally{if(context!==null){e.context_restore(context);e.context_free(context);}}\n'
        ' }\n'
        ' run(pc){\n'
        '  const e=this.e,uc=this.uc;let steps=0;\n'
        '  while(true){\n'
        "   if(++steps>300000)throw Error('too many host ABI calls');this.trap=null;\n"
        "   try{e.emu_start(pc,this.stop,0,0);}catch(error){throw Error('emulation fault pc=0x'+e.reg_read_i64(uc.ARM64_REG_PC).toString(16)+' '+String(error));}\n"
        "   if(this.trap===null){if(Number(e.reg_read_i64(uc.ARM64_REG_PC))!==this.stop)throw Error('instruction budget exceeded');break;}\n"
        "   const name=this.addressImports[this.trap];if(!name)throw Error('unknown host trampoline');\n"
        '   this.counts[name]=(this.counts[name]||0)+1;\n'
        '   const lr=Number(e.reg_read_i64(uc.ARM64_REG_LR));const args=Array.from({length:8},(_,i)=>this.reg(i));\n'
        '   const value=this.dispatch(name,args);\n'
        "   if(value&&typeof value==='object'&&value.host_request){this.pending={lr};return value;}\n"
        '   this.result(value);pc=lr;\n'
        '  }\n'
        '  return Number(BigInt.asIntN(64,e.reg_read_i64(uc.ARM64_REG_X0)));\n'
        ' }\n'
        ' resume(reply){\n'
        "  if(!this.pending)throw Error('no pending host I/O');const pc=this.pending.lr;this.pending=null;\n"
        '  if(reply.errno)this.write32(this.errno,reply.errno);\n'
        '  for(const write of reply.writes||[])this.write(write.address,this.unbase64(write.data));\n'
        '  this.result(reply.result);return this.run(pc);\n'
        ' }\n'
        ' dispatch(name,a){\n'
        "  if(name.startsWith('jni:'))return this.jni(Number(name.slice(4)),a);\n"
        "  if(name.startsWith('jvm:')){\n"
        '   const index=Number(name.slice(4));if(index===6){this.write64(a[1],this.env);return 0;}\n'
        "   throw Error('unsupported JavaVM entry '+index);\n"
        '  }\n'
        '  switch(name){\n'
        "   case 'malloc':return this.allocate(a[0]);\n"
        "   case 'calloc':return this.allocate(a[0]*a[1],true);\n"
        "   case 'free':this.free(a[0]);return 0;\n"
        "   case 'realloc':{if(!a[0])return this.allocate(a[1]);const n=this.allocations.get(a[0]);if(n===undefined)throw Error('invalid realloc');const p=this.allocate(a[1]);this.write(p,this.read(a[0],Math.min(n,a[1])));this.free(a[0]);return p;}\n"
        "   case 'posix_memalign':{if(a[1]>16)throw Error('unsupported alignment');this.write64(a[0],this.allocate(a[2]));return 0;}\n"
        "   case 'memcpy':case 'memmove':this.write(a[0],this.read(a[1],a[2]));return a[0];\n"
        "   case 'memset':this.write(a[0],new Uint8Array(a[2]).fill(a[1]&255));return a[0];\n"
        "   case 'strlen':return this.cbytes(a[0]).length;\n"
        "   case 'strdup':return this.cstring(this.string(a[0]));\n"
        "   case 'strcpy':{const s=this.cbytes(a[1]);this.write(a[0],s);this.write(a[0]+s.length,new Uint8Array(1));return a[0];}\n"
        "   case 'strncpy':{const s=this.cbytes(a[1]),out=new Uint8Array(a[2]);out.set(s.subarray(0,a[2]));this.write(a[0],out);return a[0];}\n"
        "   case 'strlcpy':{const s=this.cbytes(a[1]);if(a[2]){const n=Math.min(s.length,a[2]-1);this.write(a[0],s.subarray(0,n));this.write(a[0]+n,new Uint8Array(1));}return s.length;}\n"
        "   case 'strcat':{const n=this.cbytes(a[0]).length,s=this.cbytes(a[1]);this.write(a[0]+n,s);this.write(a[0]+n+s.length,new Uint8Array(1));return a[0];}\n"
        "   case 'strcmp':case 'strcasecmp':case 'strncmp':case 'strncasecmp':{\n"
        "    let x=this.string(a[0]),y=this.string(a[1]);if(name.includes('case')){x=x.toLowerCase();y=y.toLowerCase();}if(name.startsWith('strn')){x=x.slice(0,a[2]);y=y.slice(0,a[2]);}\n"
        '    for(let i=0;i<Math.max(x.length,y.length);i++){const d=(x.charCodeAt(i)||0)-(y.charCodeAt(i)||0);if(d)return d;}return 0;\n'
        '   }\n'
        "   case 'memcmp':{const x=this.read(a[0],a[2]),y=this.read(a[1],a[2]);for(let i=0;i<x.length;i++)if(x[i]!==y[i])return x[i]-y[i];return 0;}\n"
        "   case 'memchr':{const n=this.read(a[0],a[2]).indexOf(a[1]&255);return n<0?0:a[0]+n;}\n"
        "   case 'strchr':case 'strrchr':{const s=this.string(a[0]),n=(name==='strchr'?s.indexOf(String.fromCharCode(a[1]&255)):s.lastIndexOf(String.fromCharCode(a[1]&255)));return (a[1]&255)===0?a[0]+s.length:n<0?0:a[0]+n;}\n"
        "   case 'strstr':{const n=this.string(a[0]).indexOf(this.string(a[1]));return n<0?0:a[0]+n;}\n"
        "   case 'strspn':case 'strcspn':{const s=this.string(a[0]),set=new Set(this.string(a[1]));let n=0;while(n<s.length&&(set.has(s[n])===(name==='strspn')))n++;return n;}\n"
        "   case 'atoi':case 'atoll':return parseInt(this.string(a[0]),10)||0;\n"
        "   case 'strtol':case 'strtoul':case 'strtoll':case 'strtoumax':{const s=this.string(a[0]);const match=/^\\s*[+-]?(?:0[xX][0-9a-fA-F]+|[0-9a-zA-Z]+)/.exec(s);if(a[1])this.write64(a[1],a[0]+(match?match[0].length:0));return parseInt(s,a[2]||0)||0;}\n"
        "   case 'isspace':return /[\\t\\n\\v\\f\\r ]/.test(String.fromCharCode(a[0]&255))?1:0;\n"
        "   case 'isalnum':return /[a-zA-Z0-9]/.test(String.fromCharCode(a[0]&255))?1:0;\n"
        "   case 'isxdigit':return /[a-fA-F0-9]/.test(String.fromCharCode(a[0]&255))?1:0;\n"
        "   case 'isupper':return a[0]>=65&&a[0]<=90?1:0;\n"
        "   case 'toupper':return a[0]>=97&&a[0]<=122?a[0]-32:a[0];\n"
        "   case '__android_log_print':case 'printf':case 'fprintf':case 'vfprintf':case 'puts':case 'fputs':case 'putchar':case 'fflush':return 0;\n"
        "   case '__cxa_atexit':case '__cxa_finalize':return 0;\n"
        "   case 'pthread_mutex_init':case 'pthread_mutex_destroy':case 'pthread_mutex_lock':case 'pthread_mutex_unlock':case 'pthread_cond_init':case 'pthread_cond_destroy':case 'pthread_cond_signal':case 'pthread_cond_broadcast':case 'pthread_attr_init':case 'pthread_attr_setdetachstate':case 'pthread_attr_setscope':case 'pthread_detach':return 0;\n"
        "   case 'pthread_once':{if(!this.read32(a[0])){this.write32(a[0],1);this.invoke(a[1],[],true);this.write32(a[0],2);}return 0;}\n"
        "   case 'pthread_key_create':{const key=this.keySequence++;this.write32(a[0],key);return 0;}\n"
        "   case 'pthread_setspecific':this.keys.set(a[0],a[1]);return 0;\n"
        "   case 'pthread_getspecific':return this.keys.get(a[0])||0;\n"
        "   case 'pthread_self':return this.tls;\n"
        "   case 'pthread_create':return 11; // resource unavailable: this adapter is single-threaded\n"
        "   case '__errno':return this.errno;\n"
        "   case 'strerror':return this.cstring('System error '+a[0]);\n"
        "   case 'isatty':this.write32(this.errno,25);return 0;\n"
        "   case 'pow':{const x=this.e.reg_read_double(this.uc.ARM64_REG_D0),y=this.e.reg_read_double(this.uc.ARM64_REG_D1);this.e.reg_write_double(this.uc.ARM64_REG_D0,Math.pow(x,y));return 0;}\n"
        "   case 'srand':this.randomSeed=a[0]||1;return 0;\n"
        "   case 'rand':this.randomSeed=Number((BigInt(this.randomSeed)*1103515245n+12345n)&2147483647n);return this.randomSeed;\n"
        "   case 'arc4random':{const b=this.takeEntropy(4);return new DataView(b.buffer).getUint32(0,true);}\n"
        "   case 'getpid':return 23456;\n"
        "   case 'getuid':return 10000;\n"
        "   case 'getauxval':return 0;\n"
        "   case 'getenv':return 0;\n"
        "   case 'gethostbyname':{const host=this.string(a[0]);if(host!=='127.0.0.1')throw Error('non-loopback native DNS denied');\n"
        '    const entry=this.allocate(32,true),aliases=this.allocate(8,true),list=this.allocate(16,true),ip=this.allocate(4,true);\n'
        '    this.write(ip,new Uint8Array([127,0,0,1]));this.write64(entry,this.cstring(host));this.write64(entry+8,aliases);this.write32(entry+16,2);this.write32(entry+20,4);this.write64(entry+24,list);this.write64(list,ip);return entry;\n'
        '   }\n'
        "   case 'inet_ntop':{if(a[0]!==2)throw Error('unsupported native IP family');const text=Array.from(this.read(a[1],4)).join('.');if(a[3]<text.length+1){this.write32(this.errno,28);return 0;}const bytes=new Uint8Array(text.length+1);for(let i=0;i<text.length;i++)bytes[i]=text.charCodeAt(i);this.write(a[2],bytes);return a[2];}\n"
        "   case 'inet_addr':{const parts=this.string(a[0]).split('.').map(Number);if(parts.length!==4||parts.some(v=>!Number.isInteger(v)||v<0||v>255))return 0xffffffff;return (parts[0]+parts[1]*256+parts[2]*65536+parts[3]*16777216)>>>0;}\n"
        "   case 'usleep':return this.hostCall(name,[a[0]>>>0]);\n"
        "   case 'socket':case 'connect':case 'send':case 'sendto':case 'recv':case 'recvfrom':case 'setsockopt':case 'getsockopt':case 'getsockname':case 'getpeername':case 'shutdown':return this.hostCall(name,a);\n"
        "   case 'poll':{let ready=0,all=true;for(let i=0;i<a[1];i++){const fd=this.read32(a[0]+i*8);if(!this.files.has(fd)){all=false;break;}}if(!all)return this.hostCall(name,a);for(let i=0;i<a[1];i++){const p=a[0]+i*8,b=this.read(p,8),view=new DataView(b.buffer);const events=view.getInt16(4,true);const result=events&1;view.setInt16(6,result,true);this.write(p,b);if(result)ready++;}return ready;}\n"
        "   case 'fcntl':if(this.files.has(a[0]))return 0;return this.hostCall(name,a);\n"
        "   case 'write':if(a[0]===1||a[0]===2)return a[2];return this.hostCall(name,a);\n"
        '\n'
        "   case 'dlopen':{const name=a[0]?this.string(a[0]):'';return name.includes('kooplayer')||!name?this.base:0;}\n"
        "   case 'dlclose':return 0;\n"
        "   case 'dlerror':return this.cstring('Library not present in this Android compatibility profile');\n"
        "   case 'dlsym':{const name=this.string(a[1]);return this.plan.symbols[name]?this.base+this.plan.symbols[name]:this.importAddresses[name]||0;}\n"
        "   case 'dladdr':{if(a[0]<this.base||a[0]>=this.base+this.plan.length)return 0;this.write64(a[1],this.cstring('/data/app/cn.cntv/lib/arm64/libkooplayer.so'));this.write64(a[1]+8,this.base);this.write64(a[1]+16,0);this.write64(a[1]+24,0);return 1;}\n"
        '\n'
        "   case 'gettimeofday':{const ms=Date.now();if(a[0]){this.write64(a[0],Math.floor(ms/1000));this.write64(a[0]+8,(ms%1000)*1000);}return 0;}\n"
        "   case 'time':{const n=Math.floor(Date.now()/1000);if(a[0])this.write64(a[0],n);return n;}\n"
        "   case 'clock_gettime':{const ms=Date.now();this.write64(a[1],Math.floor(ms/1000));this.write64(a[1]+8,(ms%1000)*1000000);return 0;}\n"
        "   case 'qsort':{const items=[];for(let i=0;i<a[1];i++)items.push(this.read(a[0]+i*a[2],a[2]));const x=this.allocate(a[2]),y=this.allocate(a[2]);items.sort((l,r)=>{this.write(x,l);this.write(y,r);return Number(BigInt.asIntN(32,BigInt(this.invoke(a[3],[x,y],true))));});for(let i=0;i<items.length;i++)this.write(a[0]+i*a[2],items[i]);this.free(x);this.free(y);return 0;}\n"
        "   case 'open':case 'fopen':{const path=this.string(a[0]);if(path==='/dev/urandom'||path==='/dev/random'){const fd=this.nextFD++;this.files.set(fd,{kind:'entropy',position:0});return fd;}this.write32(this.errno,2);return name==='fopen'?0:-1;}\n"
        "   case 'fstat':{const file=this.files.get(a[0]);if(!file){this.write32(this.errno,9);return -1;}this.write(a[1],new Uint8Array(128));this.write32(a[1]+16,file.kind==='entropy'?0x21b6:0x81a4);this.write32(a[1]+20,1);this.write32(a[1]+56,4096);return 0;}\n"
        "   case 'read':{const file=this.files.get(a[0]);if(file?.kind==='entropy'){this.write(a[1],this.takeEntropy(a[2]));file.position+=a[2];return a[2];}return this.hostCall(name,a);}\n"
        "   case 'fread':{const file=this.files.get(a[3]);if(file?.kind==='entropy'){this.write(a[0],this.takeEntropy(a[1]*a[2]));file.position+=a[1]*a[2];return a[2];}throw Error('unsupported FILE read');}\n"
        "   case 'feof':case 'ferror':return 0;\n"
        "   case 'ftell':return this.files.get(a[0])?.position||0;\n"
        "   case 'fclose':if(this.files.delete(a[0]))return 0;this.write32(this.errno,9);return -1;\n"
        "   case 'close':if(this.files.delete(a[0]))return 0;return this.hostCall(name,a);\n"
        "   case 'access':case 'stat':case 'lstat':this.write32(this.errno,2);return -1;\n"
        "   case 'snprintf':case 'sprintf':case 'vsnprintf':return this.format(name,a);\n"
        "   case 'abort':case 'exit':case '__stack_chk_fail':throw Error('official library terminated: '+name);\n"
        "   default:throw Error('unsupported libc import '+name);\n"
        '  }\n'
        ' }\n'
        " takeEntropy(n){if(this.entropyPosition+n>this.entropy.length)throw Error('host entropy exhausted');const b=this.entropy.slice(this.entropyPosition,this.entropyPosition+n);this.entropyPosition+=n;return b;}\n"
        ' hostCall(name,args){\n'
        '  const request={name,args};\n'
        "  if(['send','sendto','write','connect'].includes(name))request.data=this.base64(this.read(args[1],args[2]));\n"
        "  if(name==='setsockopt')request.data=this.base64(this.read(args[3],args[4]));\n"
        "  if(name==='getsockopt'||name==='getsockname'||name==='getpeername')request.length=this.read32(args[name==='getsockopt'?4:2]);\n"
        "  if(name==='poll')request.data=this.base64(this.read(args[0],args[1]*8));\n"
        '  return {host_request:request};\n'
        ' }\n'
        ' format(name,a){\n'
        "  const fmt=this.string(a[name==='sprintf'?1:2]);let reg=name==='sprintf'?2:3,stack=Number(this.e.reg_read_i64(this.uc.ARM64_REG_SP));\n"
        "  let va=name==='vsnprintf'?a[3]:0;\n"
        '  const next=()=>{if(va){const off=new DataView(this.read(va+24,4).buffer).getInt32(0,true);if(off<0){const value=this.read64(this.read64(va+8)+off);this.write32(va+24,off+8);return value;}const p=this.read64(va);this.write64(va,p+8);return this.read64(p);}return reg<8?a[reg++]:this.read64(stack+(reg++-8)*8);};\n'
        '  const out=fmt.replace(/%([-+ #0]*)(\\d+|\\*)?(?:\\.(\\d+|\\*))?(hh|ll|[hljztL])?([%csdiuoxXp])/g,(whole,flags,width,precision,length,type)=>{\n'
        "   if(type==='%')return '%';if(width==='*')width=next();if(precision==='*')precision=next();const value=next();let result;\n"
        "   if(type==='s'){result=value?this.string(value):'(null)';if(precision!==undefined)result=result.slice(0,Number(precision));}\n"
        "   else if(type==='c')result=String.fromCharCode(value&255);\n"
        "   else if(type==='p')result='0x'+value.toString(16);\n"
        "   else{let v=BigInt(value);if(!['ll','l','z','t','j'].includes(length))v=BigInt.asUintN(32,v);if(type==='d'||type==='i')v=BigInt.asIntN(length==='ll'||length==='l'?64:32,v);result=v.toString(type==='x'||type==='X'?16:type==='o'?8:10);if(type==='X')result=result.toUpperCase();}\n"
        "   if(width&&result.length<Number(width))result=flags.includes('-')?result.padEnd(Number(width),' '):result.padStart(Number(width),flags.includes('0')?'0':' ');return result;\n"
        '  });\n'
        "  if(/%[^%]/.test(out))throw Error('unsupported C format');const max=name==='sprintf'?out.length+1:a[1];if(max){const n=Math.min(out.length,max-1);const b=new Uint8Array(n+1);for(let i=0;i<n;i++)b[i]=out.charCodeAt(i)&255;this.write(a[0],b);}return out.length;\n"
        ' }\n'
        ' jni(index,a){\n'
        '  switch(index){\n'
        "   case 6:return this.object('class',this.string(a[1])); // FindClass\n"
        '   case 15:return 0; // ExceptionOccurred\n'
        '   case 17:return 0; // ExceptionClear\n'
        '   case 21:case 25:return a[1]; // NewGlobalRef / NewLocalRef\n'
        '   case 22:case 23:return 0; // DeleteGlobalRef / DeleteLocalRef\n'
        '   case 24:return a[1]===a[2]?1:0;\n'
        "   case 33:case 94:case 113:case 144:return this.object('member',{owner:this.objects.get(a[1]),name:this.string(a[2]),signature:this.string(a[3])});\n"
        "   case 150:{const member=this.objects.get(a[2]);if(member?.value.name==='SDK_INT')return 23;throw Error('unsupported static int field');}\n"
        '   case 167:return this.cstring(this.string(a[1]));\n'
        '   case 168:return this.cbytes(a[1]).length;\n'
        '   case 169:if(a[2])this.write(a[2],new Uint8Array(1));return a[1];\n'
        '   case 170:return 0;\n'
        '   case 215:{for(let i=0;i<a[3];i++){const p=a[2]+i*24;const name=this.string(this.read64(p)),signature=this.string(this.read64(p+8));this.natives[name+signature]=this.read64(p+16);}return 0;}\n'
        '   case 219:this.write64(a[1],this.jvm);return 0;\n'
        '   case 228:return 0; // ExceptionCheck\n'
        "   default:throw Error('unsupported JNI entry '+index);\n"
        '  }\n'
        ' }\n'
        ' packetBinary(channel,length){\n'
        '  const data=globalThis.__mediaInput.subarray(0,length);\n'
        "  if(length<4||length>4*1024*1024||!(data[0]===0&&data[1]===0&&(data[2]===1||(data[2]===0&&data[3]===1))))throw Error('invalid Annex B media');\n"
        '  let state=this.states.get(channel);\n'
        '  if(state){this.states.delete(channel);this.states.set(channel,state);}\n'
        '  else{if(this.states.size>=8){const old=this.states.keys().next().value;this.free(this.states.get(old));this.states.delete(old);}state=this.allocate(1024,true);this.states.set(channel,state);}\n'
        '  const buffer=this.allocate(length+64,true);this.write(buffer,data);\n'
        "  try{const code=this.invoke(this.base+0xfec68,[buffer,length,0,state]);if(typeof code!=='number')throw Error('unexpected media I/O');globalThis.__mediaOutput=code===0?this.read(buffer,length):null;return {code};}\n"
        '  finally{this.free(buffer);}\n'
        ' }\n'
        ' reset(channel){const old=this.states.get(channel);if(old){this.free(old);this.states.delete(channel);}}\n'
        ' close(){this.e.close();}\n'
        '}\n'
        'globalThis.KooVM=KooVM;\n'
    )
}

PYTHON_SOURCES = {
    'jsc_host': (
        '"""Callback-free JavaScriptCore host; supports embedded NUL via UTF-16 API."""\n'
        'import ctypes as c\n'
        'import json\n'
        'import threading\n'
        'import time\n'
        'from pathlib import Path\n'
        "APPLE='/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore'\n"
        'class JSCHost:\n'
        ' def __init__(self,library=APPLE):\n'
        '  self.owner=threading.get_ident();self.j=c.CDLL(str(library));p=c.c_void_p\n'
        "  for n,result,args in [('JSGlobalContextCreate',p,[p]),('JSGlobalContextRelease',None,[p]),('JSContextGetGroup',p,[p]),('JSContextGroupSetExecutionTimeLimit',None,[p,c.c_double,p,p]),('JSContextGroupClearExecutionTimeLimit',None,[p]),('JSStringCreateWithCharacters',p,[p,c.c_size_t]),('JSStringRelease',None,[p]),('JSEvaluateScript',p,[p,p,p,p,c.c_int,c.POINTER(p)]),('JSValueToStringCopy',p,[p,p,c.POINTER(p)]),('JSStringGetMaximumUTF8CStringSize',c.c_size_t,[p]),('JSStringGetUTF8CString',c.c_size_t,[p,p,c.c_size_t])]:\n"
        '   fn=getattr(self.j,n);fn.restype=result;fn.argtypes=args\n'
        "  for n,result,args in [('JSValueToObject',p,[p,p,c.POINTER(p)]),('JSObjectGetTypedArrayBytesPtr',p,[p,p,c.POINTER(p)]),('JSObjectGetTypedArrayByteLength',c.c_size_t,[p,p,c.POINTER(p)]),('JSGarbageCollect',None,[p]),('JSContextGetGlobalObject',p,[p]),('JSValueMakeFromJSONString',p,[p,p]),('JSObjectSetProperty',None,[p,p,p,p,c.c_uint,c.POINTER(p)])]:\n"
        '   fn=getattr(self.j,n);fn.restype=result;fn.argtypes=args\n'
        '  self.context=self.j.JSGlobalContextCreate(None);self.group=self.j.JSContextGetGroup(self.context)\n'
        ' def _text(self,value):\n'
        '  err=c.c_void_p();s=self.j.JSValueToStringCopy(self.context,value,c.byref(err))\n'
        "  if not s:return '<unprintable>'\n"
        '  try:\n'
        '   n=self.j.JSStringGetMaximumUTF8CStringSize(s)\n'
        "   if n>24*1024*1024:raise RuntimeError('JSC result limit')\n"
        "   b=c.create_string_buffer(n);self.j.JSStringGetUTF8CString(s,b,n);return b.value.decode('utf8')\n"
        '  finally:self.j.JSStringRelease(s)\n'
        ' def evaluate(self,source,timeout=30):\n'
        "  if self.owner!=threading.get_ident():raise RuntimeError('JSC owner thread')\n"
        "  raw=source.encode('utf-16-le');buffer=c.create_string_buffer(raw);s=self.j.JSStringCreateWithCharacters(buffer,len(raw)//2)\n"
        '  self.j.JSContextGroupSetExecutionTimeLimit(self.group,timeout,None,None)\n'
        '  try:\n'
        '   error=c.c_void_p();value=self.j.JSEvaluateScript(self.context,s,None,None,1,c.byref(error))\n'
        "   if error.value:raise RuntimeError('JSC: '+self._text(error)[:500])\n"
        "   if not value:raise RuntimeError('JSC empty result')\n"
        '   return self._text(value)\n'
        '  finally:self.j.JSStringRelease(s);self.j.JSContextGroupClearExecutionTimeLimit(self.group)\n'
        ' def install_json(self,name,text):\n'
        "  if self.owner!=threading.get_ident():raise RuntimeError('JSC owner thread')\n"
        '  strings=[]\n'
        '  try:\n'
        '   for value in [name,text]:\n'
        "    raw=value.encode('utf-16-le');buffer=c.create_string_buffer(raw)\n"
        '    strings.append(self.j.JSStringCreateWithCharacters(buffer,len(raw)//2))\n'
        '   value=self.j.JSValueMakeFromJSONString(self.context,strings[1])\n'
        "   if not value:raise RuntimeError('JSC JSON parsing failed')\n"
        '   error=c.c_void_p();obj=self.j.JSContextGetGlobalObject(self.context)\n'
        '   self.j.JSObjectSetProperty(self.context,obj,strings[0],value,0,c.byref(error))\n'
        "   if error.value:raise RuntimeError('JSC global JSON binding failed')\n"
        '  finally:\n'
        '   for value in strings:self.j.JSStringRelease(value)\n'
        ' def _media_object(self,expression):\n'
        "  if self.owner!=threading.get_ident():raise RuntimeError('JSC owner thread')\n"
        "  raw=expression.encode('utf-16-le');buffer=c.create_string_buffer(raw);source=self.j.JSStringCreateWithCharacters(buffer,len(raw)//2)\n"
        '  try:\n'
        '   error=c.c_void_p();value=self.j.JSEvaluateScript(self.context,source,None,None,1,c.byref(error))\n'
        "   if error.value or not value:raise RuntimeError('JSC media reference failed')\n"
        '   obj=self.j.JSValueToObject(self.context,value,c.byref(error))\n'
        "   if error.value or not obj:raise RuntimeError('JSC media object failed')\n"
        '   return obj\n'
        '  finally:self.j.JSStringRelease(source)\n'
        ' def put_media(self,data):\n'
        "  if not 0<len(data)<=4*1024*1024:raise ValueError('Media buffer limit')\n"
        '  # Only host-owned media buffers cross this API, never SDK heap/state pointers.\n'
        '  obj=self._media_object(\'if(typeof __mediaInput==="undefined"||__mediaInput.length<\'+str(len(data))+\')__mediaInput=new Uint8Array(\'+str(max(65536,1<<(len(data)-1).bit_length()))+\');__mediaInput\')\n'
        '  error=c.c_void_p();pointer=self.j.JSObjectGetTypedArrayBytesPtr(self.context,obj,c.byref(error))\n'
        "  if error.value or not pointer:raise RuntimeError('JSC input buffer failed')\n"
        '  c.memmove(pointer,data,len(data))\n'
        ' def read_media(self,size):\n'
        "  obj=self._media_object('__mediaOutput');error=c.c_void_p()\n"
        '  actual=self.j.JSObjectGetTypedArrayByteLength(self.context,obj,c.byref(error))\n'
        "  if error.value or actual!=size:raise RuntimeError('JSC output buffer length failed')\n"
        '  pointer=self.j.JSObjectGetTypedArrayBytesPtr(self.context,obj,c.byref(error))\n'
        "  if error.value or not pointer:raise RuntimeError('JSC output buffer failed')\n"
        '  return c.string_at(pointer,size)\n'
        ' def collect(self):self.j.JSGarbageCollect(self.context)\n'
        ' def close(self):\n'
        '  if self.context:self.j.JSGlobalContextRelease(self.context);self.context=None\n'
    ),
    'elf_image': (
        '"""Pinned AArch64 ELF description for the WASM guest, using only struct."""\n'
        'import base64\n'
        'import hashlib\n'
        'import struct\n'
        '\n'
        "SDK_SHA256='41cd081ba0348b9802cedfceedb6bfa12c4db8f7cc462ffd3b531df6874f0a9e'\n"
        'class ELFError(ValueError):pass\n'
        '\n'
        'def image_plan(data):\n'
        "    if hashlib.sha256(data).hexdigest()!=SDK_SHA256:raise ELFError('Unsupported official SDK SHA-256')\n"
        "    if data[:6]!=b'\\x7fELF\\x02\\x01':raise ELFError('Expected little-endian ELF64')\n"
        "    header=struct.unpack_from('<HHIQQQIHHHHHH',data,16)\n"
        '    kind,machine,version,entry,phoff,shoff,flags,ehsize,phsize,phnum,shsize,shnum,shstr=header\n'
        "    if machine!=183 or kind!=3 or phsize!=56 or shsize!=64 or phnum>128 or shnum>4096:raise ELFError('Unsupported ELF layout')\n"
        '    def region(offset,size):\n'
        "        if offset<0 or size<0 or offset+size>len(data):raise ELFError('ELF region out of bounds')\n"
        '        return data[offset:offset+size]\n'
        '    segments=[];limit=0\n'
        '    for i in range(phnum):\n'
        "        t,f,offset,address,physical,filesize,memsize,align=struct.unpack('<IIQQQQQQ',region(phoff+i*phsize,56))\n"
        '        if t==1:\n'
        "            if memsize<filesize or address+memsize>64*1024*1024:raise ELFError('ELF segment size invalid')\n"
        "            segments.append({'address':address,'memory':memsize,'data':base64.b64encode(region(offset,filesize)).decode()})\n"
        '            limit=max(limit,address+memsize)\n'
        "    if not segments:raise ELFError('ELF has no load segments')\n"
        "    sections=[struct.unpack('<IIQQQQIIQQ',region(shoff+i*shsize,64)) for i in range(shnum)]\n"
        '    def section(i):\n'
        "        if not 0<=i<len(sections):raise ELFError('ELF section index invalid')\n"
        '        return sections[i]\n'
        '    def symbols(i):\n'
        '        sec=section(i);strings=section(sec[6]);names=region(strings[4],strings[5]);result=[]\n'
        "        if sec[9]!=24 or sec[5]%24:raise ELFError('Unsupported symbol table')\n"
        '        for cursor in range(sec[4],sec[4]+sec[5],24):\n'
        "            offset,info,other,index,value,size=struct.unpack('<IBBHQQ',region(cursor,24))\n"
        "            end=names.find(b'\\0',offset)\n"
        "            if end<0:raise ELFError('ELF symbol name unterminated')\n"
        "            result.append((names[offset:end].decode('utf8'),index,value))\n"
        '        return result\n'
        '    symtabs={i:symbols(i) for i,s in enumerate(sections) if s[1]==11}\n'
        '    exported={name:value for table in symtabs.values() for name,index,value in table if name and index!=0}\n'
        '    relocations=[];imports=[]\n'
        '    for sec in sections:\n'
        '        if sec[1]!=4:continue\n'
        "        if sec[9]!=24 or sec[5]%24:raise ELFError('Unsupported relocation table')\n"
        '        table=symtabs.get(sec[6])\n'
        "        if table is None:raise ELFError('Relocations do not use the dynamic symbol table')\n"
        '        for cursor in range(sec[4],sec[4]+sec[5],24):\n'
        "            offset,info,addend=struct.unpack('<QQq',region(cursor,24));t=info&0xffffffff;index=info>>32\n"
        "            if t not in (257,1025,1026,1027) or offset+8>limit or index>=len(table):raise ELFError('Unsupported ELF relocation')\n"
        "            name,section_index,value=table[index];name=name if section_index==0 else ''\n"
        '            if name and name not in imports:imports.append(name)\n'
        "            relocations.append({'offset':offset,'type':t,'addend':addend,'symbol':value,'import':name})\n"
        "    return {'length':(limit+4095)&~4095,'segments':segments,'symbols':exported,'relocations':relocations,'imports':imports}\n"
    ),
    'local_tls': (
        '"""Generate only this process\'s loopback TLS certificate, with stdlib RSA.\n'
        'No vendor/device keys are read. The small certificate is never used for upstream\n'
        'trust; external HTTPS still uses the ordinary system CA verification.\n'
        '"""\n'
        'import base64\n'
        'from datetime import datetime,timedelta,timezone\n'
        'import hashlib\n'
        'import math\n'
        'import os\n'
        'from pathlib import Path\n'
        'import secrets\n'
        'import ssl\n'
        'import tempfile\n'
        '\n'
        '\n'
        'def _der(tag,body):\n'
        '    n=len(body)\n'
        "    length=bytes([n]) if n<128 else (lambda b:bytes([128|len(b)])+b)(n.to_bytes((n.bit_length()+7)//8,'big'))\n"
        '    return bytes([tag])+length+body\n'
        '\n'
        "def _seq(*items):return _der(0x30,b''.join(items))\n"
        'def _integer(n):\n'
        "    b=n.to_bytes(max(1,(n.bit_length()+7)//8),'big')\n"
        "    return _der(2,(b'\\0' if b[0]&128 else b'')+b)\n"
        'def _oid(parts):\n'
        '    values=[40*parts[0]+parts[1]]+list(parts[2:]);result=bytearray()\n'
        '    for value in values:\n'
        '        b=[value&127];value>>=7\n'
        '        while value:b.insert(0,128|(value&127));value>>=7\n'
        '        result.extend(b)\n'
        '    return _der(6,bytes(result))\n'
        'def _pem(label,data):\n'
        '    body=base64.b64encode(data)\n'
        "    return b'-----BEGIN '+label+b'-----\\n'+b'\\n'.join(body[i:i+64] for i in range(0,len(body),64))+b'\\n-----END '+label+b'-----\\n'\n"
        '\n'
        '_SMALL=(3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97)\n'
        'def _prime(bits):\n'
        '    while True:\n'
        '        n=secrets.randbits(bits)|(3<<(bits-2))|1\n'
        '        if any(n%p==0 for p in _SMALL) or math.gcd(n-1,65537)!=1:continue\n'
        '        d=n-1;s=0\n'
        '        while d%2==0:d//=2;s+=1\n'
        '        for _ in range(40):\n'
        '            x=pow(2+secrets.randbelow(n-3),d,n)\n'
        '            if x in (1,n-1):continue\n'
        '            for _ in range(s-1):\n'
        '                x=x*x%n\n'
        '                if x==n-1:break\n'
        '            else:break\n'
        '        else:return n\n'
        '\n'
        '\n'
        'def certificate_pem():\n'
        '    """Return a new local RSA-2048 key/cert. No third-party crypto package."""\n'
        '    p=_prime(1024);q=_prime(1024)\n'
        '    while p==q or (p*q).bit_length()!=2048:q=_prime(1024)\n'
        '    n=p*q;e=65537;d=pow(e,-1,math.lcm(p-1,q-1))\n'
        '    key=_seq(*map(_integer,[0,n,e,d,p,q,d%(p-1),d%(q-1),pow(q,-1,p)]))\n'
        "    null=_der(5,b'')\n"
        '    algorithm=_seq(_oid((1,2,840,113549,1,1,11)),null)\n'
        "    public=_seq(_seq(_oid((1,2,840,113549,1,1,1)),null),_der(3,b'\\0'+_seq(_integer(n),_integer(e))))\n"
        "    name=_seq(_der(0x31,_seq(_oid((2,5,4,3)),_der(12,b'Local SDK Transport'))))\n"
        '    now=datetime.now(timezone.utc)\n'
        "    validity=_seq(*[_der(0x17,t.strftime('%y%m%d%H%M%SZ').encode()) for t in (now-timedelta(days=1),now+timedelta(days=7))])\n"
        "    san=_seq(_oid((2,5,29,17)),_der(4,_seq(_der(0x87,b'\\x7f\\0\\0\\x01'))))\n"
        '    tbs=_seq(_der(0xa0,_integer(2)),_integer(secrets.randbits(127)|1),algorithm,name,validity,name,public,_der(0xa3,_seq(san)))\n'
        "    digest_info=bytes.fromhex('3031300d060960864801650304020105000420')+hashlib.sha256(tbs).digest()\n"
        "    encoded=b'\\x00\\x01'+b'\\xff'*(256-len(digest_info)-3)+b'\\x00'+digest_info\n"
        "    signature=pow(int.from_bytes(encoded,'big'),d,n).to_bytes(256,'big')\n"
        "    cert=_seq(tbs,algorithm,_der(3,b'\\0'+signature))\n"
        "    return _pem(b'CERTIFICATE',cert),_pem(b'RSA PRIVATE KEY',key)\n"
        '\n'
        '\n'
        'def make_server_context():\n'
        '    cert,key=certificate_pem()\n'
        '    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)\n'
        "    # Python's SSL API accepts certificate filenames, so use the app's writable\n"
        '    # temporary directory briefly and unlink both files immediately after load.\n'
        "    with tempfile.TemporaryDirectory(prefix='cbox-local-tls-') as name:\n"
        '        root=Path(name);root.chmod(0o700)\n'
        "        for filename,data in [('cert.pem',cert),('key.pem',key)]:\n"
        '            target=root/filename\n'
        '            fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)\n'
        "            with os.fdopen(fd,'wb') as stream:stream.write(data)\n"
        "        context.load_cert_chain(root/'cert.pem',root/'key.pem')\n"
        '    return context\n'
    ),
    'bootstrap_nojdk': (
        '"""Verified official SDK and WASM downloads; no compiler, JVM, pip or shell."""\n'
        'import base64\n'
        'import hashlib\n'
        'import io\n'
        'import logging\n'
        'import zlib\n'
        'import os\n'
        'from pathlib import Path\n'
        'import tarfile\n'
        'import tempfile\n'
        'import threading\n'
        'from urllib.request import Request,urlopen\n'
        'import zipfile\n'
        'from elf_image import SDK_SHA256\n'
        '\n'
        "APK_URL='https://download.cntv.cn/app/cntv/cbox_7.9.31_release_androidguanwang.apk'\n"
        "APK_SHA256='f6c8bde63f14b3bffb57d1e838a71e80e85abf5cbe4717b983aa787134324d75'\n"
        "SDK_MEMBER='lib/arm64-v8a/libkooplayer260728D.so'\n"
        "WASM_URL='https://cdn.jsdelivr.net/npm/@alexaltea/unicorn-js@2.1.4/dist/unicorn_aarch64.js'\n"
        "WASM_SHA256='b497aa99d973f0a5eb27fe7e14e8d32f76298bf6cc6008f9035c4a8d8b91cb37'\n"
        "NPM_URL='https://registry.npmjs.org/@alexaltea/unicorn-js/-/unicorn-js-2.1.4.tgz'\n"
        "NPM_INTEGRITY='UAml23tgHyXEuP2A7Y50qDCNYMIRHJobsjlhetPRrtH+PXg0+BNAyvPQEKoCd+VHAF1nDfPHE4yJCqSLVtOrXA=='\n"
        "LOG=logging.getLogger('cbox-app-udrm')\n"
        '_LOCK=threading.Lock();_MEMORY={};_CACHE_WARNING=False\n'
        'class BootstrapError(RuntimeError):pass\n'
        'class RangeUnavailable(BootstrapError):pass\n'
        '\n'
        '# Byte positions belong only to the pinned official 7.9.31 APK above.\n'
        '# Final uncompressed SHA-256 is mandatory, including for range downloads.\n'
        'SDK_OFFSET=1674252\n'
        'SDK_COMPRESSED_SIZE=2198880\n'
        'APK_SIZE=49271128\n'
        'SDK_SIZE=5229120\n'
        'SDK_CRC=1091805562\n'
        '\n'
        'def _get_sdk_range(progress):\n'
        '    end=SDK_OFFSET+SDK_COMPRESSED_SIZE-1\n'
        "    request=Request(APK_URL,headers={'User-Agent':'cctv-app-udrm/0.2.2',\n"
        "        'Accept-Encoding':'identity','Range':f'bytes={SDK_OFFSET}-{end}'})\n"
        '    try:\n'
        '        response=urlopen(request,timeout=30)\n'
        '    except Exception as error:\n'
        "        raise RangeUnavailable('SDK分段请求失败：'+type(error).__name__) from None\n"
        '    with response:\n'
        '        if response.status==200:\n'
        "            raise RangeUnavailable('服务器不支持分段下载')\n"
        "        if response.status!=206 or not response.geturl().startswith('https://'):\n"
        "            raise BootstrapError('SDK分段响应无效')\n"
        "        expected=f'bytes {SDK_OFFSET}-{end}/{APK_SIZE}'\n"
        "        if response.headers.get('Content-Range')!=expected:\n"
        "            raise BootstrapError('SDK分段范围不符，停止加载')\n"
        "        length=response.headers.get('Content-Length')\n"
        '        if length is not None and length!=str(SDK_COMPRESSED_SIZE):\n'
        "            raise BootstrapError('SDK分段长度不符')\n"
        "        if response.headers.get('Content-Encoding','identity').lower()!='identity':\n"
        "            raise BootstrapError('SDK分段传输编码不符')\n"
        '        chunks=[];size=0\n'
        '        while size<SDK_COMPRESSED_SIZE:\n'
        '            chunk=response.read(min(256*1024,SDK_COMPRESSED_SIZE-size))\n'
        "            if not chunk:raise BootstrapError('SDK分段下载被截断')\n"
        '            chunks.append(chunk);size+=len(chunk)\n'
        "            progress(f'官方SDK分段下载：{size*100//SDK_COMPRESSED_SIZE}%（{size//1024}/{SDK_COMPRESSED_SIZE//1024} KiB）')\n"
        "        if response.read(1):raise BootstrapError('SDK分段正文超长')\n"
        '    try:\n'
        '        decoder=zlib.decompressobj(-15)\n'
        "        sdk=decoder.decompress(b''.join(chunks),SDK_SIZE+1)\n"
        '        if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail or len(sdk)!=SDK_SIZE:\n'
        "            raise BootstrapError('SDK分段解压长度不符')\n"
        "    except zlib.error:raise BootstrapError('SDK分段解压失败') from None\n"
        '    if zlib.crc32(sdk)!=SDK_CRC or hashlib.sha256(sdk).hexdigest()!=SDK_SHA256:\n'
        "        raise BootstrapError('官方SDK分段摘要不符，停止加载')\n"
        '    return sdk\n'
        '\n'
        'def _preflight(jscore_library,notify):\n'
        '    from jsc_host import JSCHost,APPLE\n'
        '    host=None\n'
        '    try:\n'
        '        host=JSCHost(jscore_library or APPLE)\n'
        '        result=host.evaluate("(function(){var b=new Uint8Array([0,97,115,109,1,0,0,0]);new WebAssembly.Instance(new WebAssembly.Module(b));return typeof BigInt===\'function\'?\'ok\':\'missing BigInt\';})()")\n'
        "        if result!='ok':raise RuntimeError('BigInt unavailable')\n"
        '    except Exception as error:\n'
        "        raise BootstrapError('当前宿主无法运行JavaScriptCore/WebAssembly（'+type(error).__name__+'）；尚未下载SDK，请使用支持该能力的运行环境') from None\n"
        '    finally:\n'
        '        if host is not None:host.close()\n'
        "    notify('系统JavaScriptCore/WebAssembly能力检查通过')\n"
        '\n'
        '\n'
        'def _read_cached(cache,name,digest):\n'
        '    global _CACHE_WARNING\n'
        '    if cache is None:return None\n'
        '    try:\n'
        '        path=cache/name\n'
        '        if path.is_file():\n'
        '            data=path.read_bytes()\n'
        '            if hashlib.sha256(data).hexdigest()==digest:return data\n'
        '    except OSError:\n'
        "        if not _CACHE_WARNING:LOG.info('缓存不可读；使用内存');_CACHE_WARNING=True\n"
        '    return None\n'
        '\n'
        'def _cache(cache,name,data):\n'
        '    global _CACHE_WARNING\n'
        '    if cache is None:return\n'
        '    temporary=None\n'
        '    try:\n'
        '        cache.mkdir(parents=True,exist_ok=True);cache.chmod(0o700)\n'
        "        fd,name_tmp=tempfile.mkstemp(prefix='.download-',dir=cache);temporary=Path(name_tmp)\n"
        "        with os.fdopen(fd,'wb') as stream:stream.write(data)\n"
        '        temporary.chmod(0o600);os.replace(temporary,cache/name)\n'
        '    except OSError:\n'
        "        if not _CACHE_WARNING:LOG.info('缓存目录不可写；使用内存，不影响取流');_CACHE_WARNING=True\n"
        '    finally:\n'
        '        if temporary:\n'
        '            try:temporary.unlink(missing_ok=True)\n'
        '            except OSError:pass\n'
        '\n'
        'def _get(url,limit,progress,label):\n'
        '    try:\n'
        "        request=Request(url,headers={'User-Agent':'cctv-app-udrm/0.2.2','Accept-Encoding':'identity'})\n"
        '        with urlopen(request,timeout=30) as response:\n'
        "            if response.status!=200 or not response.geturl().startswith('https://'):raise BootstrapError('下载未返回有效HTTPS响应')\n"
        '            chunks=[];n=0;announced=0\n'
        '            while True:\n'
        '                chunk=response.read(512*1024)\n'
        '                if not chunk:break\n'
        '                chunks.append(chunk);n+=len(chunk)\n'
        "                if n>limit:raise BootstrapError('下载内容超过长度限制')\n"
        "                if n-announced>=1024*1024:progress(label+'：'+str(n//(1024*1024))+' MiB');announced=n\n"
        "            length=response.headers.get('Content-Length')\n"
        "            if length is not None and (not length.isdecimal() or int(length)!=n):raise BootstrapError('下载正文不完整')\n"
        "            return b''.join(chunks)\n"
        '    except BootstrapError:raise\n'
        "    except Exception as error:raise BootstrapError('下载失败：'+type(error).__name__) from None\n"
        '\n'
        'def prepare(vm_source,*,cache_dir=None,jscore_library=None,progress=None):\n'
        '    notify=progress or LOG.info\n'
        "    cache=Path(cache_dir).expanduser() if cache_dir else Path(tempfile.gettempdir())/'cctv-app-udrm-v02'\n"
        '    with _LOCK:\n'
        '        _preflight(jscore_library,notify)\n'
        "        sdk=_MEMORY.get('sdk') or _read_cached(cache,'libkooplayer260728D.so',SDK_SHA256)\n"
        '        if sdk is None:\n'
        "            notify('首次准备：下载官方App SDK并校验，运行不需要JDK')\n"
        '            try:\n'
        '                sdk=_get_sdk_range(notify)\n'
        '            except RangeUnavailable:\n'
        "                notify('分段下载不可用，回退完整官方安装包（约47 MiB）')\n"
        "                apk=_get(APK_URL,64*1024*1024,notify,'官方SDK下载')\n"
        "                if hashlib.sha256(apk).hexdigest()!=APK_SHA256:raise BootstrapError('官方APK摘要变化，停止加载')\n"
        '                try:\n'
        '                    with zipfile.ZipFile(io.BytesIO(apk)) as archive:\n'
        '                        member=archive.getinfo(SDK_MEMBER)\n'
        "                        if member.file_size!=5229120:raise BootstrapError('官方SDK大小变化')\n"
        '                        sdk=archive.read(member)\n'
        "                except (OSError,zipfile.BadZipFile,KeyError):raise BootstrapError('官方APK读取失败') from None\n"
        '                finally:del apk\n'
        "                if hashlib.sha256(sdk).hexdigest()!=SDK_SHA256:raise BootstrapError('官方SDK摘要不符')\n"
        "            _cache(cache,'libkooplayer260728D.so',sdk)\n"
        "        wasm=_MEMORY.get('wasm') or _read_cached(cache,'unicorn-aarch64-2.1.4.js',WASM_SHA256)\n"
        '        if wasm is None:\n'
        "            notify('准备无JDK的ARM64 WebAssembly解释器')\n"
        "            try:wasm=_get(WASM_URL,3*1024*1024,notify,'解释器下载')\n"
        '            except BootstrapError:\n'
        "                package=_get(NPM_URL,12*1024*1024,notify,'解释器包下载')\n"
        "                if base64.b64encode(hashlib.sha512(package).digest()).decode()!=NPM_INTEGRITY:raise BootstrapError('解释器包摘要不符')\n"
        '                try:\n'
        "                    with tarfile.open(fileobj=io.BytesIO(package),mode='r:gz') as archive:\n"
        "                        member=archive.getmember('package/dist/unicorn_aarch64.js')\n"
        "                        if not member.isfile() or member.size>3*1024*1024:raise BootstrapError('解释器包结构不符')\n"
        '                        with archive.extractfile(member) as stream:wasm=stream.read()\n'
        "                except (tarfile.TarError,KeyError,OSError):raise BootstrapError('解释器包读取失败') from None\n"
        "            if hashlib.sha256(wasm).hexdigest()!=WASM_SHA256:raise BootstrapError('解释器版本变化，停止加载')\n"
        "            _cache(cache,'unicorn-aarch64-2.1.4.js',wasm)\n"
        '        _MEMORY.update(sdk=sdk,wasm=wasm)\n'
        "        notify('官方SDK和无JDK解释器已校验就绪')\n"
        "        return {'sdk_bytes':sdk,'unicorn_source':wasm.decode('utf8'),'vm_source':vm_source,'jscore_library':jscore_library}\n"
    ),
    'wasm_sdk': (
        '"""No JVM: original ARM64 SDK under Unicorn WASM in JavaScriptCore."""\n'
        'from __future__ import annotations\n'
        'import base64\n'
        'import errno\n'
        'import json\n'
        'import os\n'
        'from pathlib import Path\n'
        'import select\n'
        'import socket\n'
        'import struct\n'
        'import time\n'
        'from jsc_host import JSCHost,APPLE\n'
        'from elf_image import image_plan\n'
        '\n'
        'class LoopbackSockets:\n'
        ' def __init__(self):self.sockets={};self.sequence=1000;self.calls={}\n'
        ' @staticmethod\n'
        " def _write(address,data):return {'address':address,'data':base64.b64encode(data).decode()}\n"
        ' def handle(self,request):\n'
        "  name=request['name'];a=request['args'];self.calls[name]=self.calls.get(name,0)+1\n"
        "  fd=struct.unpack('<i',struct.pack('<I',a[0]&0xffffffff))[0]\n"
        "  reply={'result':0,'writes':[]}\n"
        '  try:\n'
        "   if name=='usleep':\n"
        '    # Real host wait yields the GIL, allowing the loopback licensing server to run.\n'
        '    # Never busy-wait or report success without honoring the requested duration.\n'
        '    micros=a[0]\n'
        '    if not isinstance(micros,int) or not 0<=micros<=30000000:\n'
        "     raise OSError(errno.EINVAL,'SDK sleep exceeds operation budget')\n"
        '    time.sleep(micros/1000000)\n'
        "   elif name=='socket':\n"
        "    if a[0]!=2 or a[1]&15!=1:raise OSError(errno.EAFNOSUPPORT,'Only loopback IPv4 TCP')\n"
        '    sock=socket.socket(socket.AF_INET,socket.SOCK_STREAM);sock.settimeout(15)\n'
        "    fd=self.sequence;self.sequence+=1;self.sockets[fd]=sock;reply['result']=fd\n"
        "   elif name=='poll':\n"
        "    raw=bytearray(base64.b64decode(request['data'],validate=True));read=[];write=[];check=[]\n"
        "    rows=[struct.unpack_from('<ihh',raw,i*8) for i in range(a[1])]\n"
        '    invalid=False\n'
        '    for n,events,_ in rows:\n'
        '     if n<0:continue\n'
        '     sock=self.sockets.get(n)\n'
        '     if sock is None:invalid=True;continue\n'
        '     if events&1:read.append(sock)\n'
        '     if events&4:write.append(sock)\n'
        '     check.append(sock)\n'
        "    timeout=struct.unpack('<i',struct.pack('<I',a[2]&0xffffffff))[0]\n"
        '    readable,writable,errors=select.select(read,write,check,0 if invalid else min(30,max(0,timeout/1000)))\n'
        '    count=0\n'
        '    for i,(n,events,_) in enumerate(rows):\n'
        '     sock=self.sockets.get(n);revents=0\n'
        '     if n>=0 and sock is None:revents=32\n'
        '     elif sock:\n'
        '      if sock in readable:revents|=1\n'
        '      if sock in writable:revents|=4\n'
        '      if sock in errors:revents|=8\n'
        "     struct.pack_into('<h',raw,i*8+6,revents)\n"
        '     if revents:count+=1\n'
        '    reply.update(result=count,writes=[self._write(a[0],raw)])\n'
        '   else:\n'
        '    sock=self.sockets.get(fd)\n'
        "    if sock is None:raise OSError(errno.EBADF,'Unknown owned socket')\n"
        "    if name=='connect':\n"
        "     raw=base64.b64decode(request['data'],validate=True)\n"
        "     family=struct.unpack_from('<H',raw)[0];port=struct.unpack_from('>H',raw,2)[0];host=socket.inet_ntoa(raw[4:8])\n"
        "     if family!=2 or host!='127.0.0.1':raise OSError(errno.EACCES,'Native SDK network is loopback only')\n"
        '     code=sock.connect_ex((host,port));reply.update(result=0 if code==0 else -1,errno=code)\n'
        "    elif name=='fcntl':\n"
        '     command=a[1]\n'
        "     if command==3:reply['result']=2|(0x800 if sock.gettimeout()==0 else 0)\n"
        '     elif command==4:sock.setblocking(not bool(a[2]&0x800))\n'
        "     elif command==1:reply['result']=1\n"
        "     elif command!=2:raise OSError(errno.EINVAL,'Unsupported socket fcntl')\n"
        "    elif name in ('send','sendto','write'):\n"
        "     data=base64.b64decode(request['data'],validate=True)\n"
        "     if name=='sendto' and a[4]:raise OSError(errno.EOPNOTSUPP,'Explicit sendto destination unsupported')\n"
        "     reply['result']=sock.send(data,a[3] if name!='write' else 0)\n"
        "    elif name in ('recv','recvfrom','read'):\n"
        "     if not 0<=a[2]<=1024*1024:raise OSError(errno.EINVAL,'Native receive size limit')\n"
        "     data=sock.recv(a[2],a[3] if name!='read' else 0)\n"
        '     reply.update(result=len(data),writes=[self._write(a[1],data)])\n'
        "    elif name=='close':sock.close();del self.sockets[fd]\n"
        "    elif name=='shutdown':sock.shutdown(a[1])\n"
        "    elif name=='setsockopt':\n"
        "     data=base64.b64decode(request['data'],validate=True)\n"
        '     sock.setsockopt(a[1],a[2],data)\n'
        "    elif name=='getsockopt':\n"
        "     data=sock.getsockopt(a[1],a[2],min(request['length'],256))\n"
        "     reply['writes']=[self._write(a[3],data),self._write(a[4],struct.pack('<I',len(data)))]\n"
        "    elif name in ('getsockname','getpeername'):\n"
        "     host,port=sock.getsockname() if name=='getsockname' else sock.getpeername()\n"
        "     data=struct.pack('<H',2)+struct.pack('>H',port)+socket.inet_aton(host)+b'\\0'*8\n"
        "     reply['writes']=[self._write(a[1],data[:request['length']]),self._write(a[2],struct.pack('<I',16))]\n"
        "    else:raise OSError(errno.ENOSYS,'Unsupported SDK socket operation')\n"
        '  except OSError as error:reply.update(result=-1,errno=error.errno or errno.EIO)\n'
        '  return reply\n'
        ' def close(self):\n'
        '  for sock in self.sockets.values():sock.close()\n'
        '  self.sockets.clear()\n'
        '\n'
        'class WasmSDK:\n'
        ' def __init__(self,prepared):\n'
        "  self.host=JSCHost(prepared.get('jscore_library') or APPLE);self.transport=LoopbackSockets();self.licensed=False\n"
        '  try:self._initialize(prepared)\n'
        '  except BaseException:\n'
        '   self.close();raise\n'
        ' def _initialize(self,prepared):\n'
        "  self.host.evaluate('var console={log:function(){},error:function(){}};var performance={now:function(){return Date.now();}};')\n"
        '  self.host.evaluate(self._base64_host())\n'
        "  source=prepared['unicorn_source']\n"
        '  self.host.evaluate(source)\n'
        "  start=source.index('function findWasmBinary(){return binaryDecode(')+len('function findWasmBinary(){return binaryDecode(')\n"
        '  end=start+1\n'
        '  while end<len(source):\n'
        "   if source[end]=='\\\\':end+=2;continue\n"
        '   if source[end]=="\'":break\n'
        '   end+=1\n'
        '  literal=source[start:end+1]\n'
        "  self.host.evaluate('var __wtext='+literal+';var __wbytes=new Uint8Array(__wtext.length);for(var i=0;i<__wtext.length;i++){var c=__wtext.charCodeAt(i);__wbytes[i]=~c>>8&c;}__wtext=null;void 0;')\n"
        "  self.host.evaluate('var __uc=null;var __loadError=null;MUnicorn({print:function(){},printErr:function(){},instantiateWasm:function(imports,done){var mod=new WebAssembly.Module(__wbytes);var inst=new WebAssembly.Instance(mod,imports);done(inst,mod);return inst.exports;}}).then(x=>__uc=x).catch(e=>__loadError=String(e));')\n"
        '  deadline=time.monotonic()+20\n'
        '  while time.monotonic()<deadline:\n'
        "   state=json.loads(self.host.evaluate('JSON.stringify({ready:!!__uc,error:__loadError})'))\n"
        "   if state['error']:raise RuntimeError('WASM initialization failed')\n"
        "   if state['ready']:break\n"
        '   time.sleep(0.01)\n'
        "  else:raise RuntimeError('WASM initialization timeout')\n"
        "  self.host.evaluate(prepared['vm_source'])\n"
        "  plan=json.dumps(image_plan(prepared['sdk_bytes']),separators=(',',':'))\n"
        '  entropy=base64.b64encode(os.urandom(128*1024)).decode()\n'
        "  self.host.install_json('__plan',plan)\n"
        "  self.host.evaluate('var __entropy=Uint8Array.from(atob('+json.dumps(entropy)+'),c=>c.charCodeAt(0));var __vm=new KooVM(__uc,__plan,__entropy);__plan.segments=null;void 0;')\n"
        "  result=self._call('__vm.invoke(__vm.base+__plan.symbols.JNI_OnLoad,[__vm.jvm,0])')\n"
        "  if result!=65540:raise RuntimeError('Official SDK JNI initialization rejected')\n"
        '  self.host.collect()\n'
        ' def _call(self,expression):\n'
        "  result=json.loads(self.host.evaluate('JSON.stringify('+expression+')',timeout=30));deadline=time.monotonic()+45\n"
        "  while isinstance(result,dict) and 'host_request' in result:\n"
        "   if time.monotonic()>deadline:raise RuntimeError('SDK I/O deadline')\n"
        "   reply=self.transport.handle(result['host_request'])\n"
        "   result=json.loads(self.host.evaluate('JSON.stringify(__vm.resume('+json.dumps(reply,separators=(',',':'))+'))',timeout=30))\n"
        '  return result\n'
        ' def rights(self,url):\n'
        '  from urllib.parse import urlsplit\n'
        '  parsed=urlsplit(url)\n'
        "  if parsed.scheme!='https' or parsed.hostname!='127.0.0.1' or not parsed.port or parsed.username or parsed.fragment:raise ValueError('SDK transport must be loopback HTTPS')\n"
        '  self.host.evaluate(\'var __info=__vm.cstring(\'+json.dumps(\'CONTENTID=2820180516001,URI=\'+url)+\');var __context=__vm.object("player",{});var __label=__vm.cstring("OFFLINE_PROBE");\')\n'
        '  result=self._call(\'__vm.invoke(__vm.natives["drmCheckRights(Ljava/lang/String;Ljava/lang/String;)I"],[__vm.env,__context,__info,__label])\')\n'
        "  result=struct.unpack('<i',struct.pack('<I',result&0xffffffff))[0]\n"
        '  self.licensed=result==0;return result\n'
        ' def process(self,channel,data):\n'
        "  if not self.licensed:raise RuntimeError('Official license required')\n"
        "  if not isinstance(data,bytes) or not 4<=len(data)<=4*1024*1024:raise ValueError('Media size invalid')\n"
        '  self.host.put_media(data)\n'
        "  reply=self._call('__vm.packetBinary('+json.dumps(channel)+','+str(len(data))+')')\n"
        "  if reply['code']!=0:raise RuntimeError('SDK media rejected code='+str(reply['code']))\n"
        '  return self.host.read_media(len(data))\n'
        " def reset(self,channel):self.host.evaluate('__vm.reset('+json.dumps(channel)+')')\n"
        " def counts(self):return json.loads(self.host.evaluate('JSON.stringify(__vm.counts)'))\n"
        ' def close(self):\n'
        '  self.transport.close()\n'
        '  try:self.host.evaluate(\'if(typeof __vm!=="undefined")__vm.close()\')\n'
        '  finally:self.host.close()\n'
        ' @staticmethod\n'
        ' def _base64_host():\n'
        "  return '''var __b64chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';\n"
        "function atob(text){var value=0,bits=0,out='';for(var c of text){if(c==='=')break;var n=__b64chars.indexOf(c);if(n<0)throw Error('Invalid base64');value=(value<<6)|n;bits+=6;if(bits>=8){bits-=8;out+=String.fromCharCode((value>>bits)&255);}}return out;}\n"
        "function btoa(text){var out='',value=0,bits=0;for(var i=0;i<text.length;i++){var c=text.charCodeAt(i);if(c>255)throw Error('Invalid base64 byte');value=(value<<8)|c;bits+=8;while(bits>=6){bits-=6;out+=__b64chars[(value>>bits)&63];}}if(bits)out+=__b64chars[(value<<(6-bits))&63];while(out.length%4)out+='=';return out;}'''\n"
    ),
    'license_relay': (
        '"""Loopback transport for unchanged SDK license POSTs, without persistent licenses.\n'
        'External HTTPS uses inherited proxies and normal certificate verification.\n'
        '"""\n'
        'from http.server import HTTPServer, BaseHTTPRequestHandler\n'
        'from urllib.request import Request, build_opener, HTTPRedirectHandler\n'
        'from urllib.error import HTTPError\n'
        'from pathlib import Path\n'
        'import json\n'
        'import ssl\n'
        'from local_tls import make_server_context\n'
        'import threading\n'
        '\n'
        'ENDPOINTS = {\n'
        "    'primary': 'https://drm.live.cntv.cn:444/udrm/udmCNTVGetLicense',\n"
        "    'secondary': 'https://cdrm.live.cntv.cn/udrm/udmCNTVGetLicense',\n"
        '}\n'
        'LIMIT = 1024 * 1024\n'
        '\n'
        'class NoRedirect(HTTPRedirectHandler):\n'
        '    def redirect_request(self, *args):\n'
        '        return None\n'
        '\n'
        '\n'
        '\n'
        '\n'
        'class LicenseRelay:\n'
        "    def __init__(self,workdir=None,target='primary'):\n"
        '        self.records=[];self.target=ENDPOINTS[target]\n'
        '        self.opener=build_opener(NoRedirect())\n'
        '        context=make_server_context()\n'
        '        relay=self\n'
        '        class Server(HTTPServer):\n'
        '            def get_request(self):\n'
        '                connection,address=super().get_request();connection.settimeout(20)\n'
        '                try:return context.wrap_socket(connection,server_side=True),address\n'
        '                except Exception:\n'
        '                    connection.close();raise\n'
        '        class Handler(BaseHTTPRequestHandler):\n'
        '            def log_message(self,*args):pass\n'
        '            def do_POST(self):\n'
        "                if self.path!='/udrm/udmCNTVGetLicense':self.send_error(404);return\n"
        '                if len(relay.records)>=4:self.send_error(429);return\n'
        "                size=self.headers.get('Content-Length','0')\n"
        '                if not size.isdecimal() or not 0<int(size)<=LIMIT:\n'
        '                    self.send_error(413);return\n'
        '                request_body=self.rfile.read(int(size))\n'
        '                if len(request_body)!=int(size):self.send_error(400);return\n'
        "                record={'request_bytes':len(request_body)};relay.records.append(record)\n"
        '                try:\n'
        "                    request=Request(relay.target,data=request_body,method='POST',headers={\n"
        "                        'Content-Type':self.headers.get('Content-Type','application/vnd.oma.drm.roap-pdu+xml'),\n"
        "                        'Accept':'*/*'})\n"
        '                    try:response=relay.opener.open(request,timeout=15)\n'
        '                    except HTTPError as error:response=error\n'
        '                    with response:\n'
        '                        status=response.status;body=response.read(LIMIT+1)\n'
        "                        ctype=response.headers.get('Content-Type','application/octet-stream')\n"
        "                        if len(body)>LIMIT:raise ValueError('Oversized license response')\n"
        '                    record.update(http_status=status,response_bytes=len(body))\n'
        '                    try:\n'
        '                        obj=json.loads(body)\n'
        "                        record['business_status']=obj.get('status')\n"
        "                        licenses=obj.get('protectedLicenses',[])\n"
        "                        record['protected_license_count']=len(licenses) if isinstance(licenses,list) else None\n"
        '                    except (ValueError,AttributeError,TypeError):pass\n'
        '                except Exception as error:\n'
        "                    status=502;body=b'UPSTREAM_LICENSE_TRANSPORT_FAILED';ctype='text/plain'\n"
        "                    record['transport_error']=type(error).__name__\n"
        "                self.send_response(status);self.send_header('Content-Type',ctype)\n"
        "                self.send_header('Content-Length',str(len(body)));self.end_headers()\n"
        '                try:self.wfile.write(body)\n'
        '                except (OSError,ssl.SSLError):pass\n'
        "        self.server=Server(('127.0.0.1',0),Handler)\n"
        '        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True)\n'
        "        self.url=f'https://127.0.0.1:{self.server.server_port}/udrm/udmCNTVGetLicense'\n"
        '    def __enter__(self):\n'
        '        self.thread.start();return self\n'
        '    def __exit__(self,*args):\n'
        '        self.server.shutdown();self.server.server_close();self.thread.join(timeout=2)\n'
    ),
    'sdk_client': (
        '"""Serialize SDK calls on one owner thread; no subprocess or Java runtime."""\n'
        'from dataclasses import dataclass,field\n'
        'import queue\n'
        'import threading\n'
        'from wasm_sdk import WasmSDK\n'
        '\n'
        'class SDKError(RuntimeError):pass\n'
        '\n'
        '@dataclass\n'
        'class Job:\n'
        '    op: str\n'
        '    args: tuple\n'
        '    done: object=field(default_factory=threading.Event)\n'
        '    result: object=None\n'
        "    error: str=''\n"
        '\n'
        'class SDKClient:\n'
        '    def __init__(self,prepared,license_url,*,startup_timeout=60,request_timeout=20):\n'
        '        self.prepared=prepared;self.license_url=license_url\n'
        '        self.startup_timeout=startup_timeout;self.request_timeout=request_timeout\n'
        '        self.jobs=queue.Queue(maxsize=4);self.ready=threading.Event();self.stopping=threading.Event()\n'
        "        self.start_error='';self.started=False;self.lock=threading.RLock()\n"
        "        self.thread=threading.Thread(target=self._worker,name='cbox-sdk-jscore',daemon=True)\n"
        '    def start(self):\n'
        '        with self.lock:\n'
        "            if self.stopping.is_set():raise SDKError('sdk_closed')\n"
        '            if not self.started:self.thread.start();self.started=True\n'
        '        if not self.ready.wait(self.startup_timeout):\n'
        "            self.close();raise SDKError('sdk_startup_timeout')\n"
        '        if self.start_error:\n'
        '            self.close();raise SDKError(self.start_error)\n'
        '        return self\n'
        '    def _worker(self):\n'
        '        sdk=None\n'
        '        try:\n'
        '            sdk=WasmSDK(self.prepared)\n'
        '            code=sdk.rights(self.license_url)\n'
        "            if code!=0:raise SDKError('sdk_license_rejected code='+str(code))\n"
        '            self.ready.set()\n'
        '            while not self.stopping.is_set():\n'
        '                try:job=self.jobs.get(timeout=0.2)\n'
        '                except queue.Empty:continue\n'
        '                if job is None:break\n'
        '                try:\n'
        "                    if job.op=='process':job.result=sdk.process(*job.args)\n"
        "                    elif job.op=='reset':sdk.reset(*job.args)\n"
        "                    else:raise SDKError('invalid_sdk_operation')\n"
        '                except Exception as error:\n'
        "                    job.error='sdk_media_failed '+str(error)[:160]\n"
        '                    self.stopping.set()\n'
        '                finally:job.done.set()\n'
        '        except Exception as error:\n'
        "            self.start_error=str(error)[:180] if isinstance(error,SDKError) else 'sdk_initialization_failed '+str(error)[:160]\n"
        '        finally:\n'
        '            self.ready.set();self.stopping.set()\n'
        '            if sdk:\n'
        '                try:sdk.close()\n'
        '                except Exception:pass\n'
        '            while True:\n'
        '                try:job=self.jobs.get_nowait()\n'
        '                except queue.Empty:break\n'
        "                if job:job.error='sdk_closed';job.done.set()\n"
        '    def _request(self,op,args):\n'
        '        self.start()\n'
        "        if self.stopping.is_set():raise SDKError('sdk_closed')\n"
        '        job=Job(op,args)\n'
        '        try:self.jobs.put(job,timeout=1)\n'
        "        except queue.Full:raise SDKError('sdk_busy') from None\n"
        '        if not job.done.wait(self.request_timeout):\n'
        "            self.close();raise SDKError('sdk_response_timeout')\n"
        '        if job.error:raise SDKError(job.error)\n'
        '        return job.result\n'
        "    def process(self,channel,data):return self._request('process',(channel,data))\n"
        "    def reset(self,channel):self._request('reset',(channel,))\n"
        '    def close(self):\n'
        '        self.stopping.set()\n'
        '        try:self.jobs.put_nowait(None)\n'
        '        except queue.Full:pass\n'
        '        if self.started and threading.current_thread() is not self.thread:self.thread.join(timeout=3)\n'
        '    def __enter__(self):return self.start()\n'
        '    def __exit__(self,*args):self.close()\n'
    ),
    'ts_validator': (
        '"""Strict 188-byte TS, PSI and H.264 program validation. No cryptography."""\n'
        'from __future__ import annotations\n'
        'from typing import NamedTuple\n'
        '\n'
        'class TSFormatError(ValueError):\n'
        '    """Malformed, incomplete or unsupported transport-stream structure."""\n'
        '\n'
        '\n'
        'class _Packet(NamedTuple):\n'
        '    pid: int\n'
        '    pusi: bool\n'
        '    payload_offset: int\n'
        '    payload: bytes\n'
        '    discontinuity: bool\n'
        '    scrambling: int\n'
        '    duplicate: bool\n'
        '\n'
        '\n'
        'def mpeg_crc32(data: bytes) -> int:\n'
        '    """MPEG-2 PSI CRC-32 (not the reflected zlib CRC variant)."""\n'
        '    crc = 0xFFFFFFFF\n'
        '    for value in data:\n'
        '        crc ^= value << 24\n'
        '        for _ in range(8):\n'
        '            crc = ((crc << 1) ^ (0x04C11DB7 if crc & 0x80000000 else 0)) & 0xFFFFFFFF\n'
        '    return crc\n'
        '\n'
        '\n'
        'def _packets(data: bytes) -> list[_Packet]:\n'
        '    if not data or len(data) % 188:\n'
        '        raise TSFormatError("Expected a nonempty whole number of 188-byte TS packets")\n'
        '    packets = []\n'
        '    continuity: dict[int, tuple[int, bytes]] = {}\n'
        '    for offset in range(0, len(data), 188):\n'
        '        raw = data[offset : offset + 188]\n'
        '        if raw[0] != 0x47:\n'
        '            raise TSFormatError(f"TS sync byte missing at offset {offset}")\n'
        '        if raw[1] & 0x80:\n'
        '            raise TSFormatError(f"Transport error indicator at offset {offset}")\n'
        '        pid = ((raw[1] & 0x1F) << 8) | raw[2]\n'
        '        pusi = bool(raw[1] & 0x40)\n'
        '        scrambling = raw[3] >> 6\n'
        '        afc = (raw[3] >> 4) & 3\n'
        '        cc = raw[3] & 15\n'
        '        if not afc or scrambling == 1:\n'
        '            raise TSFormatError(f"Reserved TS header value at offset {offset}")\n'
        '        cursor = 4\n'
        '        discontinuity = False\n'
        '        if afc & 2:\n'
        '            adaptation_length = raw[cursor]\n'
        '            cursor += 1\n'
        '            end = cursor + adaptation_length\n'
        '            if end > 188 or (afc == 2 and end != 188) or (afc == 3 and end >= 188):\n'
        '                raise TSFormatError(f"Invalid adaptation length at offset {offset}")\n'
        '            if adaptation_length:\n'
        '                flags = raw[cursor]\n'
        '                discontinuity = bool(flags & 0x80)\n'
        '                scan = cursor + 1\n'
        '                for flag, length in ((0x10, 6), (0x08, 6), (0x04, 1)):\n'
        '                    if flags & flag:\n'
        '                        scan += length\n'
        '                for flag in (0x02, 0x01):\n'
        '                    if flags & flag:\n'
        '                        if scan >= end:\n'
        '                            raise TSFormatError(f"Truncated adaptation data at offset {offset}")\n'
        '                        scan += 1 + raw[scan]\n'
        '                if scan > end:\n'
        '                    raise TSFormatError(f"Truncated adaptation data at offset {offset}")\n'
        '            cursor = end\n'
        '        payload = raw[cursor:] if afc & 1 else b""\n'
        '        duplicate = False\n'
        '        if pid != 0x1FFF:\n'
        '            previous = continuity.get(pid)\n'
        '            if previous is not None and not discontinuity:\n'
        '                expected = (previous[0] + bool(payload)) % 16\n'
        '                if cc != expected:\n'
        '                    if payload and cc == previous[0] and raw == previous[1]:\n'
        '                        duplicate = True\n'
        '                    else:\n'
        '                        raise TSFormatError(f"TS continuity gap on PID {pid} at offset {offset}")\n'
        '            continuity[pid] = (cc, raw)\n'
        '        packets.append(_Packet(pid, pusi, offset + cursor, payload, discontinuity, scrambling, duplicate))\n'
        '    return packets\n'
        '\n'
        '\n'
        'class _SectionAssembler:\n'
        '    def __init__(self) -> None:\n'
        '        self.pending = bytearray()\n'
        '        self.sections: list[bytes] = []\n'
        '\n'
        '    def _consume(self, value: bytes) -> None:\n'
        '        self.pending.extend(value)\n'
        '        while self.pending:\n'
        '            if self.pending[0] == 0xFF:\n'
        '                if any(byte != 0xFF for byte in self.pending):\n'
        '                    raise TSFormatError("Non-stuffing bytes after PSI stuffing")\n'
        '                self.pending.clear()\n'
        '                return\n'
        '            if len(self.pending) < 3:\n'
        '                return\n'
        '            length = ((self.pending[1] & 15) << 8) | self.pending[2]\n'
        '            if not 4 <= length <= 1021:\n'
        '                raise TSFormatError("Unsupported PSI section length")\n'
        '            total = length + 3\n'
        '            if len(self.pending) < total:\n'
        '                return\n'
        '            section = bytes(self.pending[:total])\n'
        '            del self.pending[:total]\n'
        '            if mpeg_crc32(section):\n'
        '                raise TSFormatError("PSI CRC mismatch")\n'
        '            self.sections.append(section)\n'
        '\n'
        '    def feed(self, packet: _Packet) -> None:\n'
        '        if not packet.payload or packet.duplicate:\n'
        '            return\n'
        '        if packet.scrambling:\n'
        '            raise TSFormatError("Scrambled PSI is unsupported")\n'
        '        if packet.discontinuity and self.pending:\n'
        '            raise TSFormatError("PSI discontinuity inside a section")\n'
        '        if not packet.pusi:\n'
        '            if not self.pending:\n'
        '                raise TSFormatError("PSI begins with an unknown partial section")\n'
        '            self._consume(packet.payload)\n'
        '            return\n'
        '        pointer = packet.payload[0]\n'
        '        if pointer > len(packet.payload) - 1:\n'
        '            raise TSFormatError("PSI pointer exceeds packet payload")\n'
        '        if self.pending:\n'
        '            self._consume(packet.payload[1 : 1 + pointer])\n'
        '            if self.pending:\n'
        '                raise TSFormatError("New PSI section before previous section completed")\n'
        '        # A pointer may skip the end of a section that preceded the input buffer.\n'
        '        self._consume(packet.payload[1 + pointer :])\n'
        '\n'
        '    def finish(self) -> list[bytes]:\n'
        '        if self.pending:\n'
        '            raise TSFormatError("PSI section is incomplete at EOF")\n'
        '        return self.sections\n'
        '\n'
        '\n'
        'def _sections(packets: list[_Packet], pid: int, table_id: int) -> list[bytes]:\n'
        '    assembler = _SectionAssembler()\n'
        '    for packet in packets:\n'
        '        if packet.pid == pid:\n'
        '            assembler.feed(packet)\n'
        '    result = []\n'
        '    for section in assembler.finish():\n'
        '        if section[0] != table_id:\n'
        '            raise TSFormatError("Unexpected table on selected PSI PID")\n'
        '        if len(section) < 12 or section[1] & 0xF0 != 0xB0:\n'
        '            raise TSFormatError("Unsupported PSI syntax")\n'
        '        if not section[5] & 1:\n'
        '            continue\n'
        '        if section[6] or section[7]:\n'
        '            raise TSFormatError("Multi-section PAT/PMT is unsupported")\n'
        '        result.append(section)\n'
        '    if not result:\n'
        '        raise TSFormatError(f"Current PSI table {table_id} missing on PID {pid}")\n'
        '    if any(section != result[0] for section in result[1:]):\n'
        '        raise TSFormatError("PAT/PMT changes within the input buffer are unsupported")\n'
        '    return result\n'
        '\n'
        '\n'
        'def _program(\n'
        '    packets: list[_Packet], program_number: int | None, video_pid: int | None\n'
        ') -> tuple[int, int, int, int]:\n'
        '    pat = _sections(packets, 0, 0)[0]\n'
        '    if (len(pat) - 12) % 4:\n'
        '        raise TSFormatError("Malformed PAT program entries")\n'
        '    programs = {}\n'
        '    for offset in range(8, len(pat) - 4, 4):\n'
        '        number = int.from_bytes(pat[offset : offset + 2], "big")\n'
        '        if number:\n'
        '            if number in programs:\n'
        '                raise TSFormatError("Duplicate PAT program number")\n'
        '            programs[number] = ((pat[offset + 2] & 31) << 8) | pat[offset + 3]\n'
        '    if program_number is None:\n'
        '        if len(programs) != 1:\n'
        '            raise TSFormatError("Select program_number explicitly for a multi-program TS")\n'
        '        program_number = next(iter(programs))\n'
        '    if program_number not in programs:\n'
        '        raise TSFormatError("Requested program_number is absent from PAT")\n'
        '    pmt_pid = programs[program_number]\n'
        '    if pmt_pid in (0, 0x1FFF):\n'
        '        raise TSFormatError("Invalid PMT PID")\n'
        '    pmt = _sections(packets, pmt_pid, 2)[0]\n'
        '    if len(pmt) < 16 or int.from_bytes(pmt[3:5], "big") != program_number:\n'
        '        raise TSFormatError("PMT program_number mismatch")\n'
        '    pcr_pid = ((pmt[8] & 31) << 8) | pmt[9]\n'
        '    cursor = 12 + (((pmt[10] & 15) << 8) | pmt[11])\n'
        '    if cursor > len(pmt) - 4:\n'
        '        raise TSFormatError("Truncated PMT program descriptors")\n'
        '    candidates = []\n'
        '    while cursor < len(pmt) - 4:\n'
        '        if cursor + 5 > len(pmt) - 4:\n'
        '            raise TSFormatError("Truncated PMT elementary entry")\n'
        '        stream_type = pmt[cursor]\n'
        '        pid = ((pmt[cursor + 1] & 31) << 8) | pmt[cursor + 2]\n'
        '        cursor += 5 + (((pmt[cursor + 3] & 15) << 8) | pmt[cursor + 4])\n'
        '        if cursor > len(pmt) - 4:\n'
        '            raise TSFormatError("Truncated PMT elementary descriptors")\n'
        '        if stream_type == 0x1B:\n'
        '            candidates.append(pid)\n'
        '    if video_pid is None:\n'
        '        if len(candidates) != 1:\n'
        '            raise TSFormatError("Expected one H.264 stream; select video_pid explicitly")\n'
        '        video_pid = candidates[0]\n'
        '    if video_pid not in candidates or video_pid in (0, pmt_pid, 0x1FFF):\n'
        '        raise TSFormatError("Selected video_pid is not an H.264 stream in the PMT")\n'
        '    return program_number, pmt_pid, pcr_pid, video_pid\n'
        '\n'
    ),
    'ts_mapper': (
        '"""Map complete video PES to original TS slots; contains no cryptography.\n'
        'The SDK callback must preserve ES length. All audio, timestamps and TS headers stay\n'
        'in their original slots, including exact duplicate video packets.\n'
        '"""\n'
        'from dataclasses import dataclass\n'
        'from ts_validator import _packets,_program,TSFormatError\n'
        '\n'
        '@dataclass(frozen=True)\n'
        'class Frame:\n'
        '    data: bytes\n'
        '    spans: tuple\n'
        '\n'
        '@dataclass(frozen=True)\n'
        'class Plan:\n'
        '    source: bytes\n'
        '    video_pid: int\n'
        '    frames: tuple\n'
        '    duplicates: tuple\n'
        '\n'
        '\n'
        'def plan_ts(source: bytes, *, final_pes_complete=False):\n'
        '    packets=_packets(source);video_pid=_program(packets,None,None)[3]\n'
        '    frames=[];pending=bytearray();parts=[];duplicates=[];last_canonical={}\n'
        '    def flush(*,eof=False):\n'
        "        if len(pending)<9 or pending[:3]!=b'\\x00\\x00\\x01' or not 0xe0<=pending[3]<=0xef:\n"
        "            raise TSFormatError('Invalid or incomplete video PES')\n"
        '        if pending[6]&0xf0!=0x80 or pending[7]&0xc0==0x40:\n'
        "            raise TSFormatError('Unsupported PES protection/header flags')\n"
        "        declared=int.from_bytes(pending[4:6],'big')\n"
        "        if declared and declared+6!=len(pending):raise TSFormatError('Incomplete or oversized video PES')\n"
        "        if not declared and eof and not final_pes_complete:raise TSFormatError('Need next PES boundary to complete unbounded video PES')\n"
        '        header=9+pending[8]\n'
        '        needed=10 if pending[7]>>6==3 else 5 if pending[7]>>6==2 else 0\n'
        "        if pending[8]<needed or header>=len(pending):raise TSFormatError('Invalid video PES optional header')\n"
        '        payload=bytes(pending[header:])\n'
        "        if not payload.startswith((b'\\0\\0\\1',b'\\0\\0\\0\\1')):raise TSFormatError('Expected Annex B video PES')\n"
        '        spans=[]\n'
        '        for start,off,n in parts:\n'
        '            begin=max(start,header);end=min(start+n,len(pending))\n'
        '            if begin<end:spans.append((off+begin-start,end-begin))\n'
        "        if sum(n for _,n in spans)!=len(payload):raise TSFormatError('PES span mapping mismatch')\n"
        '        frames.append(Frame(payload,tuple(spans)));pending.clear();parts.clear()\n'
        '    seen=False\n'
        '    for p in packets:\n'
        '        raw_offset=p.payload_offset+len(p.payload)-188\n'
        '        if not p.duplicate:last_canonical[p.pid]=raw_offset\n'
        '        if p.pid!=video_pid:continue\n'
        "        if p.scrambling:raise TSFormatError('TS-level scrambling is unsupported')\n"
        '        if p.duplicate:\n'
        '            duplicates.append((raw_offset,last_canonical[p.pid]));continue\n'
        "        if p.discontinuity and seen:raise TSFormatError('Split/reset channel state at discontinuity')\n"
        '        if not p.payload:continue\n'
        '        seen=True\n'
        '        if p.pusi:\n'
        '            if pending:flush()\n'
        "        elif not pending:raise TSFormatError('Input starts inside video PES; retain earlier TS bytes')\n"
        '        parts.append((len(pending),p.payload_offset,len(p.payload)));pending.extend(p.payload)\n'
        '        if len(pending)>=6:\n'
        "            declared=int.from_bytes(pending[4:6],'big')\n"
        '            if declared and len(pending)>=declared+6:flush()\n'
        '    if pending:flush(eof=True)\n'
        "    if not frames:raise TSFormatError('No complete video PES found')\n"
        '    return Plan(source,video_pid,tuple(frames),tuple(duplicates))\n'
        '\n'
        '\n'
        'def transform_plan(plan,callback):\n'
        '    output=bytearray(plan.source)\n'
        '    for frame in plan.frames:\n'
        '        replacement=callback(frame.data)\n'
        '        if not isinstance(replacement,bytes) or len(replacement)!=len(frame.data):\n'
        "            raise TSFormatError('SDK must return equal-length video ES')\n"
        '        cursor=0\n'
        '        for off,n in frame.spans:output[off:off+n]=replacement[cursor:cursor+n];cursor+=n\n'
        '    for target,canonical in plan.duplicates:output[target:target+188]=output[canonical:canonical+188]\n'
        '    result=bytes(output)\n'
        '    _packets(result)\n'
        '    # Mutation is restricted to mapped video payload bytes; audio and PSI are intact.\n'
        '    for off in range(0,len(result),188):\n'
        '        pid=((plan.source[off+1]&31)<<8)|plan.source[off+2]\n'
        "        if pid!=plan.video_pid and result[off:off+188]!=plan.source[off:off+188]:raise TSFormatError('Non-video packet changed')\n"
        '    return result\n'
        '\n'
        '\n'
        'def following_proves_complete(source: bytes, following: bytes) -> bool:\n'
        '    """Prove an unbounded final PES ended at this exact HLS object boundary.\n'
        '\n'
        '    Only adjacent objects from one playlist may be passed by the caller. Check\n'
        '    continuity across both objects, stable H.264 program and an immediate PES\n'
        "    start in the next object's video PID. Never infer this from EOF or a name.\n"
        '    """\n'
        '    first=_packets(source);second=_packets(following)\n'
        '    pid=_program(first,None,None)[3]\n'
        '    if _program(second,None,None)[3]!=pid:\n'
        "        raise TSFormatError('Video PID changed at HLS object boundary')\n"
        '    _packets(source+following)\n'
        '    for packet in second:\n'
        '        if packet.pid==pid and packet.payload and not packet.duplicate:\n'
        '            return packet.pusi and not packet.discontinuity\n'
        '    return False\n'
    ),
    'service': (
        '"""Local HLS service for original App media, using the licensed official SDK."""\n'
        'from __future__ import annotations\n'
        'import argparse\n'
        'from collections import OrderedDict\n'
        'from concurrent.futures import ThreadPoolExecutor\n'
        'from dataclasses import dataclass, field\n'
        'import hashlib\n'
        'from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer\n'
        'import json\n'
        'import logging\n'
        'import math\n'
        'import os\n'
        'from pathlib import Path\n'
        'import re\n'
        'import signal\n'
        'import threading\n'
        'import time\n'
        'from urllib.error import HTTPError\n'
        'from urllib.parse import urljoin, urlsplit\n'
        'from urllib.request import Request, urlopen\n'
        '\n'
        'from bootstrap_nojdk import prepare, BootstrapError\n'
        'from license_relay import LicenseRelay\n'
        'from sdk_client import SDKClient, SDKError\n'
        'from jsc_host import JSCHost,APPLE\n'
        'from ts_mapper import plan_ts, transform_plan, following_proves_complete\n'
        'from ts_validator import TSFormatError\n'
        '\n'
        "VERSION = '0.2.2'\n"
        "LOG = logging.getLogger('cbox-app-udrm')\n"
        'DEFAULTS = {\n'
        " 'cctv1': ('CCTV-1 综合', 'https://ldncctvcpudbd.a.bdydns.com/ldncctvcpud/udrmldcctv1_1/index.m3u8'),\n"
        " 'cctv7': ('CCTV-7 国防军事', 'https://ldocctvcpudks.v.kcdnvip.com/ldocctvcpud/udrmldcctv7_1/index.m3u8'),\n"
        " 'guizhou': ('贵州卫视', 'https://wstvcpudtxy.liveplay.myqcloud.com/wstvcpud/udrmguizhou_1/index.m3u8'),\n"
        '}\n'
        'MAX_TS = 16 * 1024 * 1024\n'
        '\n'
        'class LiveError(RuntimeError):\n'
        '    pass\n'
        '\n'
        '\n'
        'def fetch(url, limit, timeout=10):\n'
        "    if urlsplit(url).scheme not in ('https', 'http'):\n"
        "        raise LiveError('Unsupported upstream URL scheme')\n"
        '    try:\n'
        "        request = Request(url, headers={'User-Agent':'Lavf/57.56.100',\n"
        "            'Referer':'https://cboxios.cctv.com/', 'Origin':'https://cboxios.cctv.com',\n"
        "            'Accept-Encoding':'identity'})\n"
        '        with urlopen(request, timeout=timeout) as response:\n'
        '            body = response.read(limit + 1)\n'
        '            if len(body) > limit:\n'
        "                raise LiveError('Upstream response exceeds limit')\n"
        "            length = response.headers.get('Content-Length')\n"
        '            if length is not None and (not length.isdecimal() or int(length) != len(body)):\n'
        "                raise LiveError('Incomplete upstream Content-Length')\n"
        '            if response.status == 206:\n'
        "                span = re.fullmatch(r'bytes 0-(\\d+)/(\\d+)', response.headers.get('Content-Range',''))\n"
        '                if not span or int(span[1])+1 != len(body) or int(span[2]) != len(body):\n'
        "                    raise LiveError('Partial upstream response is not the complete object')\n"
        '            elif response.status != 200:\n'
        "                raise LiveError('Upstream HTTP ' + str(response.status))\n"
        '            final_url = response.geturl()\n'
        "            if urlsplit(final_url).scheme not in ('https','http'):\n"
        "                raise LiveError('Unsupported upstream redirect')\n"
        '            return body, final_url\n'
        '    except HTTPError as error:\n'
        "        raise LiveError('Upstream HTTP ' + str(error.code)) from None\n"
        '    except LiveError:\n'
        '        raise\n'
        '    except Exception as error:\n'
        "        raise LiveError('Upstream transport ' + type(error).__name__) from None\n"
        '\n'
        '\n'
        '@dataclass(frozen=True)\n'
        'class Entry:\n'
        '    seq: int\n'
        '    duration: float\n'
        '    url: str\n'
        '    discontinuity: bool = False\n'
        '\n'
        '\n'
        '@dataclass(frozen=True)\n'
        'class Playlist:\n'
        '    entries: tuple\n'
        '    target: int\n'
        '    discontinuity_sequence: int\n'
        '    end: bool\n'
        '\n'
        '\n'
        'def read_playlist(url, max_bitrate):\n'
        '    for depth in range(4):\n'
        '        body, final = fetch(url, 1024 * 1024)\n'
        '        try:\n'
        "            lines = [line.strip() for line in body.decode('utf-8-sig').splitlines() if line.strip()]\n"
        '        except UnicodeError:\n'
        "            raise LiveError('Upstream playlist is not UTF-8') from None\n"
        "        if not lines or lines[0] != '#EXTM3U':\n"
        "            raise LiveError('Upstream is not an HLS playlist')\n"
        "        if any(line.startswith('#EXT-X-STREAM-INF:') for line in lines):\n"
        '            choices=[]\n'
        '            for i,line in enumerate(lines[:-1]):\n'
        "                if line.startswith('#EXT-X-STREAM-INF:'):\n"
        "                    match=re.search(r'(?:^|,)BANDWIDTH=(\\d+)',line.split(':',1)[1])\n"
        "                    if match and not lines[i+1].startswith('#'):\n"
        '                        choices.append((int(match[1]),urljoin(final,lines[i+1])))\n'
        '            if not choices:\n'
        "                raise LiveError('Master playlist has no usable video variant')\n"
        '            within=[x for x in choices if x[0]<=max_bitrate]\n'
        '            url=(max(within) if within else min(choices))[1]\n'
        '            continue\n'
        '        entries=[];seq=0;target=4;disc_seq=0;duration=None;disc=False;end=False\n'
        '        for line in lines[1:]:\n'
        "            if line.startswith('#EXT-X-MEDIA-SEQUENCE:'):\n"
        "                seq=int(line.split(':',1)[1])\n"
        "            elif line.startswith('#EXT-X-DISCONTINUITY-SEQUENCE:'):\n"
        "                disc_seq=int(line.split(':',1)[1])\n"
        "            elif line.startswith('#EXT-X-TARGETDURATION:'):\n"
        "                target=int(line.split(':',1)[1])\n"
        "            elif line.startswith('#EXTINF:'):\n"
        '                if duration is not None:\n'
        "                    raise LiveError('Playlist has EXTINF without a segment')\n"
        "                duration=float(line.split(':',1)[1].split(',',1)[0])\n"
        '                if not math.isfinite(duration) or not 0 < duration <= 60:\n'
        "                    raise LiveError('Unsupported segment duration')\n"
        "            elif line=='#EXT-X-DISCONTINUITY':disc=True\n"
        "            elif line=='#EXT-X-ENDLIST':end=True\n"
        "            elif line.startswith('#EXT-X-KEY:'):\n"
        "                if line!='#EXT-X-KEY:METHOD=NONE':\n"
        "                    raise LiveError('This bridge does not support HLS key encryption')\n"
        "            elif line.startswith(('#EXT-X-MAP:', '#EXT-X-BYTERANGE:', '#EXT-X-PART:', '#EXT-X-GAP')):\n"
        "                raise LiveError('Unsupported fMP4, byte-range, partial or missing HLS segment')\n"
        "            elif not line.startswith('#'):\n"
        '                if duration is None:\n'
        "                    raise LiveError('Segment has no EXTINF')\n"
        '                entries.append(Entry(seq,duration,urljoin(final,line),disc))\n'
        '                seq+=1;duration=None;disc=False\n'
        '        if duration is not None or not entries or len(entries)>12 or target<1 or seq<0:\n'
        "            raise LiveError('Invalid or unsupported media playlist')\n"
        '        return Playlist(tuple(entries),target,disc_seq,end)\n'
        "    raise LiveError('Too many nested master playlists')\n"
        '\n'
        '\n'
        'class MediaSDK:\n'
        '    def __init__(self, config):\n'
        "        self.config=dict(config);self.progress='尚未准备';self.error=None\n"
        "        callback=self.config.get('progress') or LOG.info\n"
        '        def progress(message):\n'
        '            self.progress=message;callback(message)\n'
        "        self.config['progress']=progress\n"
        "        self.prepared=None;self.phase='idle';self.client=None;self.relay=None\n"
        '        self.lock=threading.RLock();self.sessions=0;self.processed_frames=0\n'
        '        self.license_records=[]\n'
        '    def _start(self):\n'
        '        if self.client is not None:return\n'
        "        self.phase='preparing'\n"
        '        try:\n'
        '            if self.prepared is None:self.prepared=prepare(**self.config)\n'
        '            self.error=None\n'
        '        except Exception as error:\n'
        "            self.phase='failed';self.error=str(error);raise\n"
        "        self.phase='licensing'\n"
        '        self.relay=LicenseRelay();self.relay.__enter__()\n'
        '        try:\n'
        '            self.client=SDKClient(self.prepared,self.relay.url)\n'
        "            self.client.start();self.sessions+=1;self.phase='ready'\n"
        '            self.license_records.extend(dict(x) for x in self.relay.records)\n'
        "            LOG.info('原 App SDK 已取得许可并就绪；会话 %s',self.sessions)\n"
        '        except Exception as error:\n'
        "            self.phase='failed';self.error=str(error);self._close();raise\n"
        '    def ensure_ready(self):\n'
        "        if self.phase!='ready':\n"
        '            with self.lock:self._start()\n'
        '    def _close(self):\n'
        '        if self.client:\n'
        '            self.client.close();self.client=None\n'
        '        if self.relay:\n'
        '            self.relay.__exit__(None,None,None);self.relay=None\n'
        '    def transform(self,channel,source,reset=False,final_pes_complete=False):\n'
        '        plan=plan_ts(source,final_pes_complete=final_pes_complete)\n'
        '        with self.lock:\n'
        '            for attempt in range(2):\n'
        '                try:\n'
        '                    self._start()\n'
        '                    if reset or attempt:self.client.reset(channel)\n'
        '                    result=transform_plan(plan,lambda data:self.client.process(channel,data))\n'
        '                    self.processed_frames+=len(plan.frames)\n'
        '                    return result\n'
        '                except SDKError as error:\n'
        "                    LOG.info('SDK 当前会话停止：%s',str(error)[:180])\n"
        '                    self._close()\n'
        '                    if attempt:raise\n'
        "                    LOG.info('SDK 会话失效，重新取得许可后重试当前分片')\n"
        "        raise LiveError('SDK did not return media')\n"
        '    def close(self):\n'
        '        with self.lock:self._close()\n'
        '\n'
        '\n'
        '@dataclass\n'
        'class Channel:\n'
        '    ident: str\n'
        '    name: str\n'
        '    url: str\n'
        '    lock: object = field(default_factory=threading.RLock)\n'
        '    cache_lock: object = field(default_factory=threading.RLock)\n'
        '    cache: object = field(default_factory=OrderedDict)\n'
        '    raw: object = field(default_factory=OrderedDict)\n'
        '    history: object = field(default_factory=OrderedDict)\n'
        '    playlist: object = None\n'
        '    updated: float = 0\n'
        '    last_active: float = 0\n'
        '    last_seq: int = -1\n'
        "    error: str = ''\n"
        '    retry_at: float = 0\n'
        '    seconds: float = 0\n'
        '\n'
        '\n'
        'class LiveService:\n'
        '    def __init__(self,prepared,channels,max_bitrate=2500000):\n'
        '        self.sdk=MediaSDK(prepared);self.channels=channels;self.max_bitrate=max_bitrate\n'
        "        self.pool=ThreadPoolExecutor(max_workers=4,thread_name_prefix='upstream')\n"
        "        self.refresh_pool=ThreadPoolExecutor(max_workers=min(4,len(channels)),thread_name_prefix='refresh')\n"
        '        self.refresh_jobs={}\n'
        '        self.stopping=threading.Event();self.started=time.monotonic()\n'
        "        self.worker=threading.Thread(target=self._background,name='refresh',daemon=True)\n"
        '        self.worker.start()\n'
        '    @staticmethod\n'
        '    def token(channel,entry):\n'
        "        return hashlib.sha256((channel.ident+'\\0'+str(entry.seq)+'\\0'+entry.url).encode()).hexdigest()[:32]\n"
        '    def refresh(self,ch,*,background=False):\n'
        '        with ch.lock:\n'
        '            now=time.monotonic()\n'
        '            if not background:ch.last_active=now\n'
        '            if ch.playlist is not None and now-ch.updated<1:return\n'
        '            if now<ch.retry_at:\n'
        '                if ch.playlist and now-ch.updated<ch.playlist.target*2:return\n'
        "                raise LiveError(ch.error or 'Upstream is cooling down')\n"
        '            started=now\n'
        '            try:\n'
        '                # Prepare before acquiring a live window: a first SDK download\n'
        '                # can take minutes, while an upstream window lasts ~12 seconds.\n'
        '                self.sdk.ensure_ready()\n'
        '                media=read_playlist(ch.url,self.max_bitrate)\n'
        '                # A sequence rollback / URL change starts a separate stream timeline.\n'
        '                if (media.entries[-1].seq < ch.last_seq or any(\n'
        '                        e.seq in ch.history and ch.history[e.seq][0].url != e.url for e in media.entries)):\n'
        '                    ch.raw.clear();ch.history.clear();ch.last_seq=-1\n'
        '                    with ch.cache_lock:ch.cache.clear()\n'
        '                missing=[entry for entry in media.entries if self.token(ch,entry) not in ch.cache]\n'
        '                fetches=[entry for entry in missing if self.token(ch,entry) not in ch.raw]\n'
        '                futures={e:self.pool.submit(fetch,e.url,MAX_TS) for e in fetches}\n'
        '                for entry in fetches:ch.raw[self.token(ch,entry)]=futures[entry].result()[0]\n'
        '                decoded=[];discontinuities=media.discontinuity_sequence\n'
        '                for index,entry in enumerate(media.entries):\n'
        '                    token=self.token(ch,entry)\n'
        '                    if token not in ch.cache:\n'
        '                        source=ch.raw[token];complete=False\n'
        '                        try:plan_ts(source)\n'
        '                        except TSFormatError as error:\n'
        "                            if str(error)!='Need next PES boundary to complete unbounded video PES':raise\n"
        '                            if index+1>=len(media.entries):\n'
        '                                # Hold this object until the next playlist proves its boundary.\n'
        '                                continue\n'
        '                            following=media.entries[index+1]\n'
        '                            neighbor=ch.raw.get(self.token(ch,following))\n'
        '                            if neighbor is None or following.discontinuity or not following_proves_complete(source,neighbor):\n'
        "                                raise TSFormatError('Unbounded PES spans HLS objects; unsupported input')\n"
        '                            complete=True\n'
        '                        output=self.sdk.transform(ch.ident,source,\n'
        '                            reset=entry.discontinuity or entry.seq!=ch.last_seq+1,\n'
        '                            final_pes_complete=complete)\n'
        '                        ch.last_seq=entry.seq\n'
        '                        decoded.append((token,output))\n'
        '                        with ch.cache_lock:ch.cache[token]=output\n'
        '                    ch.history[entry.seq]=(entry,discontinuities)\n'
        '                    if entry.discontinuity:discontinuities+=1\n'
        '                # Retain the previous verified object while the newest needs its boundary.\n'
        '                history=sorted(ch.history.values(),key=lambda x:x[0].seq)\n'
        '                chosen=[]\n'
        '                for item in reversed(history):\n'
        '                    if chosen and item[0].seq!=chosen[-1][0].seq-1:break\n'
        '                    chosen.append(item)\n'
        '                    if len(chosen)>=5:break\n'
        '                chosen.reverse()\n'
        "                if not chosen:raise LiveError('Waiting for a complete PES boundary')\n"
        '                media=Playlist(tuple(item[0] for item in chosen),media.target,chosen[0][1],media.end)\n'
        '                keep={self.token(ch,e) for e in media.entries}\n'
        '                with ch.cache_lock:\n'
        '                    while len(ch.cache)>8 or sum(map(len,ch.cache.values()))>64*1024*1024:\n'
        '                        token=next(iter(ch.cache))\n'
        '                        if token in keep:break\n'
        '                        ch.cache.pop(token)\n'
        '                while len(ch.raw)>8:ch.raw.popitem(last=False)\n'
        '                while len(ch.history)>8:ch.history.popitem(last=False)\n'
        "                ch.playlist=media;ch.updated=time.monotonic();ch.error='';ch.retry_at=0\n"
        '                ch.seconds=round(ch.updated-started,3)\n'
        "                if decoded:LOG.info('%s 更新 %s 个分片，耗时 %.2fs',ch.ident,len(decoded),ch.seconds)\n"
        '            except Exception as error:\n'
        "                for future in locals().get('futures',{}).values():future.cancel()\n"
        '                ch.error=str(error) if isinstance(error,(LiveError,TSFormatError,SDKError,BootstrapError)) else type(error).__name__\n'
        '                ch.retry_at=time.monotonic()+3\n'
        "                LOG.warning('%s 暂不可用：%s',ch.ident,ch.error)\n"
        '                # A previously valid playlist can bridge one transient CDN failure.\n'
        '                if ch.playlist and time.monotonic()-ch.updated<ch.playlist.target*2:return\n'
        '                raise LiveError(ch.error) from None\n'
        '    def playlist_bytes(self,ch):\n'
        '        ch.last_active=time.monotonic()\n'
        '        p=ch.playlist\n'
        '        # Serve an immutable, recently verified playlist while refresh does I/O.\n'
        '        if p is None or time.monotonic()-ch.updated>p.target:\n'
        '            self.refresh(ch);p=ch.playlist\n'
        "        lines=['#EXTM3U','#EXT-X-VERSION:3',f'#EXT-X-TARGETDURATION:{max(p.target,math.ceil(max(e.duration for e in p.entries)))}',\n"
        "            f'#EXT-X-MEDIA-SEQUENCE:{p.entries[0].seq}',f'#EXT-X-DISCONTINUITY-SEQUENCE:{p.discontinuity_sequence}']\n"
        '        for entry in p.entries:\n'
        "            if entry.discontinuity:lines.append('#EXT-X-DISCONTINUITY')\n"
        "            lines.extend([f'#EXTINF:{entry.duration:.3f},',f'/segments/{ch.ident}/{self.token(ch,entry)}.ts'])\n"
        "        if p.end:lines.append('#EXT-X-ENDLIST')\n"
        "        return ('\\n'.join(lines)+'\\n').encode()\n"
        '    def _background(self):\n'
        '        def refresh(ch):\n'
        '            try:self.refresh(ch,background=True)\n'
        '            except LiveError:pass\n'
        '        while not self.stopping.wait(0.5):\n'
        '            for ch in self.channels.values():\n'
        '                job=self.refresh_jobs.get(ch.ident)\n'
        '                if ch.last_active and time.monotonic()-ch.last_active<30 and (job is None or job.done()):\n'
        '                    self.refresh_jobs[ch.ident]=self.refresh_pool.submit(refresh,ch)\n'
        '    def close(self):\n'
        '        self.stopping.set();self.worker.join(timeout=2)\n'
        '        self.refresh_pool.shutdown(wait=True,cancel_futures=True)\n'
        '        self.pool.shutdown(wait=True,cancel_futures=True);self.sdk.close()\n'
        '    def status(self):\n'
        "        return {'version':VERSION,'uptime_seconds':round(time.monotonic()-self.started),\n"
        "            'engine':'javascriptcore-unicorn-wasm','jdk_required':False,'sdk_phase':self.sdk.phase,\n"
        "            'preparation_progress':self.sdk.progress,'preparation_error':self.sdk.error,\n"
        "            'sdk_sessions':self.sdk.sessions,'processed_video_pes':self.sdk.processed_frames,\n"
        "            'license_exchanges':self.sdk.license_records,\n"
        "            'channels':{ch.ident:{'name':ch.name,'cached_segments':len(ch.cache),\n"
        "                'playlist_age_seconds':round(time.monotonic()-ch.updated,2) if ch.updated else None,\n"
        "                'last_refresh_seconds':ch.seconds,'error':ch.error} for ch in self.channels.values()}}\n"
        '\n'
        '\n'
        'def make_handler(service):\n'
        '    class Handler(BaseHTTPRequestHandler):\n'
        "        protocol_version='HTTP/1.1'\n"
        "        server_version='CCTV-App-Bridge/'+VERSION\n"
        '        def log_message(self,*args):pass\n'
        '        def handle(self):\n'
        '            try:super().handle()\n'
        '            except (BrokenPipeError,ConnectionResetError,TimeoutError):pass\n'
        '        def do_HEAD(self):self.dispatch(True)\n'
        '        def do_GET(self):self.dispatch(False)\n'
        '        def dispatch(self,head):\n'
        '            try:\n'
        '                path=urlsplit(self.path).path\n'
        "                if path in ('/','/all.m3u','/aptv.m3u'):\n"
        "                    host=self.headers.get('Host','127.0.0.1:8769')\n"
        "                    if not re.fullmatch(r'[A-Za-z0-9.\\-\\[\\]:]+',host):\n"
        "                        return self.respond(400,b'Invalid Host','text/plain',head)\n"
        "                    lines=['#EXTM3U']\n"
        '                    for ch in service.channels.values():\n'
        '                        lines.extend([f\'#EXTINF:-1 tvg-id="{ch.ident}" group-title="央视影音 App",{ch.name}\',\n'
        "                            f'http://{host}/live/{ch.ident}.m3u8'])\n"
        "                    return self.respond(200,('\\n'.join(lines)+'\\n').encode(),'audio/x-mpegurl',head)\n"
        "                if path=='/status':\n"
        "                    return self.respond(200,json.dumps(service.status(),ensure_ascii=False).encode(),'application/json; charset=utf-8',head)\n"
        "                match=re.fullmatch(r'/live/([a-z0-9_-]+)\\.m3u8',path)\n"
        '                if match and match[1] in service.channels:\n'
        '                    # HEAD is an existence check and never triggers network/SDK work.\n'
        "                    body=b'' if head else service.playlist_bytes(service.channels[match[1]])\n"
        "                    return self.respond(200,body,'application/vnd.apple.mpegurl',head)\n"
        "                match=re.fullmatch(r'/segments/([a-z0-9_-]+)/([0-9a-f]{32})\\.ts',path)\n"
        '                if match and match[1] in service.channels:\n'
        '                    ch=service.channels[match[1]]\n'
        '                    with ch.cache_lock:body=ch.cache.get(match[2])\n'
        '                    ch.last_active=time.monotonic()\n'
        "                    if body is None:return self.respond(404,b'Segment expired','text/plain',head)\n"
        "                    return self.respond(200,body,'video/mp2t',head,ranges=True)\n"
        "                return self.respond(404,b'Not found','text/plain',head)\n"
        '            except LiveError as error:\n'
        "                return self.respond(503,str(error).encode(),'text/plain; charset=utf-8',head,retry=True)\n"
        '            except (BrokenPipeError,ConnectionResetError):return\n'
        '            except Exception:\n'
        "                LOG.exception('Local HTTP request failed')\n"
        "                return self.respond(500,b'Internal error','text/plain',head)\n"
        '        def respond(self,status,body,ctype,head=False,*,ranges=False,retry=False):\n'
        '            total=len(body);span=None\n'
        "            if ranges and self.headers.get('Range'):\n"
        "                match=re.fullmatch(r'bytes=(\\d*)-(\\d*)',self.headers['Range'])\n"
        '                if match and (match[1] or match[2]):\n'
        '                    if not match[1]:start=max(0,total-int(match[2]));end=total-1\n'
        '                    else:start=int(match[1]);end=min(total-1,int(match[2]) if match[2] else total-1)\n'
        '                    if start<=end and start<total:\n'
        '                        span=(start,end);body=body[start:end+1];status=206\n'
        "                    else:status=416;body=b''\n"
        "                else:status=416;body=b''\n"
        "            self.send_response(status);self.send_header('Content-Type',ctype)\n"
        "            self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store')\n"
        "            if ranges:self.send_header('Accept-Ranges','bytes')\n"
        "            if span:self.send_header('Content-Range',f'bytes {span[0]}-{span[1]}/{total}')\n"
        "            if status==416:self.send_header('Content-Range',f'bytes */{total}')\n"
        "            if retry:self.send_header('Retry-After','3')\n"
        '            self.end_headers()\n'
        '            if not head:self.wfile.write(body)\n'
        '    return Handler\n'
        '\n'
        '\n'
        'def main(vm_source,argv=None):\n'
        "    parser=argparse.ArgumentParser(description='央视影音 App UDRM 手机单文件服务（系统JavaScriptCore，无JDK）')\n"
        "    parser.add_argument('port',type=int,nargs='?',default=8769)\n"
        "    parser.add_argument('--port',dest='port_override',type=int,help=argparse.SUPPRESS)\n"
        "    parser.add_argument('--host',default='127.0.0.1')\n"
        "    parser.add_argument('--cache-dir')\n"
        "    parser.add_argument('--jscore-library',default=APPLE,help=argparse.SUPPRESS)\n"
        "    parser.add_argument('--setup-only',action='store_true')\n"
        "    parser.add_argument('--doctor',action='store_true',help='只检查本机JavaScriptCore能力，不访问节目源')\n"
        "    parser.add_argument('--warmup',action=argparse.BooleanOptionalAction,default=True)\n"
        "    parser.add_argument('--max-bitrate',type=int,default=2500000)\n"
        "    parser.add_argument('--source',action='append',default=[],metavar='ID=URL')\n"
        '    args=parser.parse_args(argv)\n'
        '    if args.port_override is not None:args.port=args.port_override\n'
        "    logging.basicConfig(level=logging.INFO,format='%(asctime)s [%(levelname)s] %(message)s')\n"
        "    if not 1<=args.port<=65535 or not 100000<=args.max_bitrate<=20000000:parser.error('端口或码率不合法')\n"
        '    if args.doctor:\n'
        '        context=None\n'
        '        try:\n'
        '            context=JSCHost(args.jscore_library)\n'
        '            print(context.evaluate(\'JSON.stringify({javascriptcore:true,webassembly:typeof WebAssembly==="object",bigint:typeof BigInt==="function",jdk_required:false})\'),flush=True)\n'
        "        except Exception as error:parser.exit(1,'JavaScriptCore不可用：'+type(error).__name__+'\\n')\n"
        '        finally:\n'
        '            if context:context.close()\n'
        '        return\n'
        "    config={'vm_source':vm_source,'cache_dir':args.cache_dir,'jscore_library':args.jscore_library,'progress':LOG.info}\n"
        '    if args.setup_only:\n'
        '        try:prepare(**config)\n'
        "        except BootstrapError as error:parser.exit(1,str(error)+'\\n')\n"
        '        return\n'
        '    channels={ident:Channel(ident,name,url) for ident,(name,url) in DEFAULTS.items()}\n'
        '    for source in args.source:\n'
        "        ident,sep,url=source.partition('=')\n"
        "        if not sep or not re.fullmatch(r'[a-z0-9_-]{1,48}',ident) or urlsplit(url).scheme not in ('http','https'):\n"
        "            parser.error('--source 必须是 ID=https://.../index.m3u8')\n"
        "        channels[ident]=Channel(ident,DEFAULTS.get(ident,(ident,''))[0],url)\n"
        '    service=LiveService(config,channels,args.max_bitrate)\n'
        '    server=ThreadingHTTPServer((args.host,args.port),make_handler(service));server.daemon_threads=True\n'
        '    def stop(signum,frame):\n'
        '        threading.Thread(target=server.shutdown,daemon=True).start()\n'
        '    if threading.current_thread() is threading.main_thread():\n'
        '        signal.signal(signal.SIGINT,stop);signal.signal(signal.SIGTERM,stop)\n'
        "    else:LOG.info('APTV托管线程：跳过进程信号注册')\n"
        '    if args.warmup:\n'
        '        def warmup(ch):\n'
        '            try:service.refresh(ch)\n'
        '            except LiveError:pass\n'
        '        for ch in channels.values():service.refresh_pool.submit(warmup,ch)\n'
        "    LOG.info('原 App UDRM 无JDK版 %s；%s 台；订阅 http://127.0.0.1:%s/all.m3u',VERSION,len(channels),args.port)\n"
        "    LOG.info('首次会自动准备SDK；状态 /status；运行不读取HAR，不启动Java/Node/FFmpeg或外部命令')\n"
        '    try:server.serve_forever(poll_interval=0.3)\n'
        '    except KeyboardInterrupt:pass\n'
        '    finally:\n'
        '        server.server_close();service.close()\n'
    ),
}

def load_modules():
    for name, source in PYTHON_SOURCES.items():
        module = types.ModuleType(name)
        module.__file__ = globals().get("__file__", "cctv-app-udrm.py") + "::" + name
        sys.modules[name] = module
        exec(compile(source, module.__file__, "exec"), module.__dict__)
    return sys.modules["service"]

def start(ctx=None):
    load_modules().main(JS_SOURCES["koo_vm.js"], [])

if __name__ == "__main__":
    load_modules().main(JS_SOURCES["koo_vm.js"])
