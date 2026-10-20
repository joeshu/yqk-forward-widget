#!/usr/bin/env python3
"""Build the readable list/native single-file release and its stable root alias."""
import argparse
import ast
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INPUTS = ('migu/core.py', 'migu/workers.py', 'migu/native.py', 'migu/android.py', 'migu/source.py', 'migu/epg.py', 'migu/service.py')
VERSION = '0.8.0'


def strip_module(text):
    tree = ast.parse(text)
    remove = set()
    for index, node in enumerate(tree.body):
        discard = index == 0 and isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)
        discard |= isinstance(node, ast.ImportFrom) and (node.module == '__future__' or node.module == 'migu' or (node.module or '').startswith('migu.'))
        discard |= isinstance(node, ast.If) and ast.unparse(node.test) in ("__name__ == '__main__'", '__name__ == "__main__"')
        if discard:
            remove.update(range(node.lineno, node.end_lineno + 1))
    return '\n'.join(line for number, line in enumerate(text.splitlines(), 1) if number not in remove).strip() + '\n'


def build():
    sources = {name: (ROOT/name).read_text(encoding='utf-8') for name in INPUTS}
    names = set()
    for source in sources.values():
        current = {node.name for node in ast.parse(source).body if isinstance(node, (ast.FunctionDef, ast.ClassDef))}
        if names & current:
            raise ValueError('Duplicate definitions in standalone modules')
        names |= current
    native_tree = ast.parse(sources['migu/native.py'])
    settings_node = next(node for node in native_tree.body if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'NATIVE_SETTINGS' for t in node.targets))
    settings_text = '\n'.join(sources['migu/native.py'].splitlines()[settings_node.lineno-1:settings_node.end_lineno])
    android_tree = ast.parse(sources['migu/android.py'])
    options_node = next(node for node in android_tree.body if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'ANDROID_OPTIONS' for t in node.targets))
    options_text = '\n'.join(sources['migu/android.py'].splitlines()[options_node.lineno-1:options_node.end_lineno])
    text = ('#!/usr/bin/env python3\n'
            f'"""Migu dynamic service {VERSION}. Standalone Python 3.10+, standard library only."""\n'
            'from __future__ import annotations\n\n'
            '# Edit only this block for protocol settings and your own credentials.\n'
            '# Environment MIGU_USER_ID / MIGU_USER_TOKEN override the two account fields.\n'
            + '# Default Android provider settings:\n' + options_text + '\n\n'
            + '# Optional native provider settings:\n' + settings_text + '\n\n'
            + '# Bounded transport and HLS validation: migu/core.py\n'
            + strip_module(sources['migu/core.py'])
            + '\nfrom types import SimpleNamespace as _SharedNamespace\n'
            + 'm = _SharedNamespace(**{key: value for key, value in globals().copy().items() if not key.startswith("__")})\n\n')
    for path in INPUTS[1:]:
        module = strip_module(sources[path])
        if path == 'migu/native.py':
            module = module.replace(settings_text, '# NATIVE_SETTINGS is defined at the top of this file.', 1)
        if path == 'migu/android.py':
            module = module.replace(options_text, '# ANDROID_OPTIONS is defined at the top of this file.', 1)
        text += f'\n# {path}\n' + module
    text += '\nif __name__ == "__main__":\n    raise SystemExit(main())\n'
    ast.parse(text)
    data = text.encode('utf-8')
    for unwanted in (b'fcntl', b'CatalogueStore', b'import update_migu', b'ThreadPoolExecutor'):
        if unwanted in data:
            raise ValueError('Unexpected dependency in standalone release')
    manifest = {'version': VERSION, 'artifact': f'migu-live-v{VERSION}.py',
                'sha256': hashlib.sha256(data).hexdigest(), 'standalone_alias': 'migu-live.py',
                'inputs': {name: hashlib.sha256(sources[name].encode()).hexdigest() for name in INPUTS}}
    return data, (json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2)+'\n').encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    artifact, manifest = build()
    paths = [(ROOT/f'migu/migu-live-v{VERSION}.py', artifact), (ROOT/f'migu/migu-live-v{VERSION}.json', manifest), (ROOT/'migu-live.py', artifact)]
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
