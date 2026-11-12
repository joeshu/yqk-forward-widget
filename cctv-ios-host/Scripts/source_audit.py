#!/usr/bin/env python3
"""Inventory and syntax-check all tracked app sources without executing plugins."""
import argparse
import ast
from concurrent.futures import ThreadPoolExecutor
from collections import Counter
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import tokenize

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parent
CODE={'.py','.m','.h','.c','.cpp','.java','.js','.mjs','.cjs','.sh'}
RISK=re.compile(r'dispatch_sync\s*\(|dispatch_semaphore_wait\s*\(|NSAssert\s*\(|dataWithContentsOfURL\s*:|CERT_NONE|credentialForTrust\s*:')

def inspect(path):
    file=REPO/path;raw=file.read_bytes();extension=file.suffix.lower()
    record={'path':path,'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw),'code':extension in CODE,'checks':[]}
    if extension not in CODE|{'.json','.plist'}:return record
    try:text=raw.decode('utf-8-sig')
    except UnicodeError:
        if extension=='.plist':text=''
        else:record['error']='Source is not UTF-8';return record
    record['lines']=raw.count(b'\n')+bool(raw)
    if extension in CODE:record['review_markers']=[i for i,line in enumerate(text.splitlines(),1) if RISK.search(line)]
    try:
        if extension=='.py':
            with tokenize.open(file) as stream:ast.parse(stream.read(),filename=path)
            record['checks'].append('python_ast')
        elif extension=='.json':
            try:json.loads(text)
            except json.JSONDecodeError:
                lines=text.splitlines();i=0
                while i<len(lines) and lines[i].lstrip().startswith('//'):i+=1
                json.loads('\n'.join(lines[i:]))
            record['checks'].append('json_parse')
        elif extension=='.plist':plistlib.loads(raw);record['checks'].append('plist_parse')
        elif extension=='.sh':
            run=subprocess.run(['bash','-n',str(file)],capture_output=True,text=True,timeout=15)
            if run.returncode:raise ValueError(run.stderr[:500])
            record['checks'].append('bash_syntax')
        elif extension in {'.js','.mjs','.cjs'}:
            node=shutil.which('node')
            if not node:record['checks'].append('node_unavailable');return record
            # Remote JS modules need their declared module grammar, independent of the app repo's package type.
            esm=extension=='.mjs' or re.search(r'(?:^|[;\n}])\s*(?:export\b|import\s+(?!\())',text)
            with tempfile.TemporaryDirectory() as tmp:
                target=Path(tmp)/('check.mjs' if esm else 'check.cjs');target.write_text(text)
                run=subprocess.run([node,'--check',str(target)],capture_output=True,text=True,timeout=20)
            if run.returncode:raise ValueError('\n'.join(line for line in run.stderr.splitlines() if len(line)<500)[-1000:])
            record['checks'].append('node_syntax')
        elif extension in {'.m','.h','.c','.cpp'}:record['checks'].append('native_analysis_separate')
        elif extension=='.java':record['checks'].append('dex_fixture_build_separate')
    except (SyntaxError,ValueError,subprocess.TimeoutExpired) as error:record['error']=str(error)[:600]
    return record

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',default='build/source-audit.json');args=parser.parse_args()
    listed=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','--','cctv-ios-host'],cwd=REPO,text=True).splitlines()
    paths=sorted(set(path for path in listed if (REPO/path).is_file()))
    with ThreadPoolExecutor(max_workers=4) as workers:records=list(workers.map(inspect,paths))
    errors=[{'path':r['path'],'error':r['error']} for r in records if 'error' in r]
    checks=Counter(check for r in records for check in r['checks'])
    report={'scope':'All tracked cctv-ios-host files, plus nonignored in-progress sources','files':records,'summary':{'files':len(records),'code_files':sum(r['code'] for r in records),'code_lines':sum(r.get('lines',0) for r in records if r['code']),'checks':dict(checks),'errors':errors,'native_analysis':'Separate Apple SDK static analysis; syntax checks alone do not verify behavior','binary_dependencies':'Inventoried by SHA-256; no source-level audit claim for proprietary frameworks'}}
    out=Path(args.output);out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(report['summary'],ensure_ascii=False,indent=2));return bool(errors)
if __name__=='__main__':raise SystemExit(main())
