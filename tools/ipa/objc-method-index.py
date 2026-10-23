import struct,sys,json
from pathlib import Path
b=Path(sys.argv[1]).read_bytes();segments=[];sections={};off=32;crypt=[]
for _ in range(struct.unpack_from('<I',b,16)[0]):
 cmd,size=struct.unpack_from('<II',b,off)
 if cmd==0x19:
  _,_,name,addr,vmsize,fo,fs,_,_,ns,_=struct.unpack_from('<II16sQQQQIIII',b,off);segments.append((addr,fo,fs))
  for j in range(ns):
   s=struct.unpack_from('<16s16sQQIIIIIIII',b,off+72+j*80);sections[s[0].rstrip(b'\0').decode()]=(s[2],s[3],s[4])
 if cmd in (0x21,0x2c):crypt.append(struct.unpack_from('<III',b,off+8))
 off+=size

def pos(a):
 for base,fo,fs in segments:
  if base<=a<base+fs:return fo+a-base
 raise ValueError(hex(a))
def u64(a):
 value=struct.unpack_from('<Q',b,pos(a))[0]
 try:pos(value);return value
 except ValueError:pass
 if value and not value>>63:
  target=(value&((1<<36)-1))+min(x[0] for x in segments if x[2])
  try:pos(target);return target
  except ValueError:pass
 return value
def cstr(a):
 p=pos(a);return b[p:b.index(0,p)].decode('utf8',errors='replace')
def methods(a):
 if not a:return []
 p=pos(a);flags,n=struct.unpack_from('<II',b,p);size=flags&0xffff;res=[]
 for i in range(n):
  v=a+8+i*size;q=pos(v)
  if flags&0x80000000:
   no,to,io=struct.unpack_from('<iii',b,q);name=v+no
   if not flags&0x40000000:name=u64(name)
   types=v+4+to;imp=v+8+io
  else:name,types,imp=u64(v),u64(v+8),u64(v+16)
  try:res.append({'name':cstr(name),'types':cstr(types),'imp':hex(imp)})
  except (ValueError,IndexError):pass
 return res
classes=[]
addr,sz,_=sections['__objc_classlist']
for i in range(sz//8):
 try:
  a=u64(addr+i*8);ro=u64(a+32)&~7;name=cstr(u64(ro+24));inst=methods(u64(ro+32));meta=u64(a);mro=u64(meta+32)&~7;clsm=methods(u64(mro+32));classes.append({'name':name,'instance':inst,'class':clsm})
 except (ValueError,IndexError,struct.error):pass
print(json.dumps({'crypt':crypt,'classes':classes},ensure_ascii=False))
