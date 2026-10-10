const fs=require('node:fs'),path=require('node:path');
const parts=['4kvm-adapter.js','4kvm-hls.js','4kvm-player.js'];
const code=parts.map(p=>fs.readFileSync(path.join(__dirname,p),'utf8')).join('\n');
fs.writeFileSync(path.join(__dirname,'4kvm.js'),code);
console.log('Built independent 4kvm.js ('+Buffer.byteLength(code)+' bytes)');
