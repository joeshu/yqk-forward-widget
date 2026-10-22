"""Development-only reproducibility check; never imported by the phone entry."""
import argparse,ast,base64,hashlib,re,subprocess,tempfile
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--wat2wasm',default='wat2wasm');parser.add_argument('--entry',type=Path,default=Path(__file__).resolve().parents[1]/'cctv-app-udrm.py');args=parser.parse_args()
tree=ast.parse(args.entry.read_text());sources=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='JS_SOURCES' for t in n.targets))
embedded=base64.b64decode(re.search(r"const bytes=Uint8Array.from\(atob\('([^']+)'\)",sources['koo_vm.js'])[1],validate=True)
with tempfile.TemporaryDirectory() as folder:
 out=Path(folder)/'memory_ops.wasm'
 subprocess.run([args.wat2wasm,str(Path(__file__).with_name('memory_ops.wat')),'-o',str(out)],check=True)
 assert out.read_bytes()==embedded,'WAT source does not match embedded WASM'
print('Embedded WASM matches source:',len(embedded),'bytes, SHA256',hashlib.sha256(embedded).hexdigest())
