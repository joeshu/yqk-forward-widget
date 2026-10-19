#!/usr/bin/env python3
"""Build a readable, deterministic single-file Migu service; no embedded eval/archive."""
import argparse
import ast
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INPUTS = ('update_migu.py', 'migu/probe.py', 'migu/service.py')
VERSION = '0.1.0'


def strip_module(text, service=False):
    tree = ast.parse(text)
    remove = set()
    for index, node in enumerate(tree.body):
        discard = index == 0 and isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)
        discard |= isinstance(node, ast.ImportFrom) and node.module == '__future__'
        discard |= isinstance(node, ast.If) and ast.unparse(node.test) in ("__name__ == '__main__'", '__name__ == "__main__"')
        if service:
            discard |= isinstance(node, ast.Import) and any(alias.name == 'update_migu' for alias in node.names)
            discard |= isinstance(node, ast.ImportFrom) and node.module == 'migu.probe'
        if discard:
            remove.update(range(node.lineno, node.end_lineno + 1))
    return '\n'.join(line for number, line in enumerate(text.splitlines(), 1) if number not in remove).strip() + '\n'


def build():
    sources = {name: (ROOT/name).read_text(encoding='utf-8') for name in INPUTS}
    upstream_names = {node.name for node in ast.parse(sources['update_migu.py']).body if isinstance(node, (ast.FunctionDef, ast.ClassDef))}
    service_names = {node.name for node in ast.parse(sources['migu/service.py']).body if isinstance(node, (ast.FunctionDef, ast.ClassDef))}
    if (upstream_names & service_names) - {'main'}:
        raise ValueError('Service shadows shared catalogue definitions')
    tree = ast.parse(sources['migu/probe.py'])
    helper = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'hls_references')
    helper_source = ast.get_source_segment(sources['migu/probe.py'], helper)
    text = (
        '#!/usr/bin/env python3\n'
        '"""Migu dynamic service 0.1.0. Generated from the project sources; Python 3.10+."""\n'
        'from __future__ import annotations\n\n'
        '# Shared catalogue validation and bounded transport: update_migu.py\n'
        + strip_module(sources['update_migu.py'])
        + '\n# Capture shared functions before defining the service CLI.\n'
        + 'from types import SimpleNamespace as _SharedNamespace\n'
        + 'm = _SharedNamespace(**{key: value for key, value in globals().copy().items() if not key.startswith("__")})\n\n'
        + '# Shared HLS validation: migu/probe.py\n' + helper_source + '\n\n'
        + '# Service implementation: migu/service.py\n' + strip_module(sources['migu/service.py'], service=True)
        + '\nif __name__ == "__main__":\n    raise SystemExit(main())\n'
    )
    ast.parse(text)
    data = text.encode('utf-8')
    manifest = {'version': VERSION, 'artifact': f'migu-live-v{VERSION}.py', 'sha256': hashlib.sha256(data).hexdigest(),
                'inputs': {name: hashlib.sha256(sources[name].encode()).hexdigest() for name in INPUTS}}
    return data, (json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2)+'\n').encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    artifact, manifest = build()
    paths = [(ROOT/f'migu/migu-live-v{VERSION}.py', artifact), (ROOT/f'migu/migu-live-v{VERSION}.json', manifest)]
    if args.check:
        if any(not path.exists() or path.read_bytes() != value for path, value in paths):
            raise SystemExit('Service release differs from the source; rebuild first.')
        print('Single-file release and source fingerprints match.')
    else:
        for path, value in paths:
            path.write_bytes(value)
        print(f'Built {paths[0][0].name} ({len(artifact)} bytes).')


if __name__ == '__main__':
    main()
