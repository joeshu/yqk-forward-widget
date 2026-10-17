const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');

function sourceFingerprint(snapshotHashes) {
  const files=['runtime.js','cache.js','adapter.js','index.js','operation.js','presentation.js','health-check.cjs','report-utils.cjs','live.cjs','build.cjs','build-inputs.cjs','package.json','package-lock.json','../yqk.fwd','imported/adapter.js','imported/metadata.json','imported/provenance.json','imported/inventory.json'];
  for(const [folder,accept] of [
    ['imported/packs',n=>n.endsWith('.gz.b64')],
    ['native',n=>n.endsWith('.js')],
    ['reference',n=>n.endsWith('.js')||n==='metadata.json'],
  ])for(const name of fs.readdirSync(path.join(__dirname,folder)).filter(accept))files.push(folder+'/'+name);
  return crypto.createHash('sha256').update(files.sort().map(n=>n+'\0'+fs.readFileSync(path.join(__dirname,n),'utf8')).join('\0')+JSON.stringify(snapshotHashes)).digest('hex');
}
module.exports={sourceFingerprint};
