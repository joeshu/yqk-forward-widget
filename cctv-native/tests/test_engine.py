"""Run the Node host against a synthetic ABI; no official runtime or network."""
import base64
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


XHR = r"""
module.exports = class XHR {
  constructor() { this.events = {}; this.status = 200; }
  nodejsSet() {}
  open() {}
  addEventListener(name, callback) { this.events[name] = callback; }
  send() { setImmediate(() => this.events.loadend()); }
};
"""

RUNTIME = r"""
module.exports = options => {
  const heap = new Uint8Array(1024 * 1024);
  const expected = Buffer.from('cctv-native-player\0');
  let cursor = 16;
  const allocations = new Map();
  function check(pointer) {
    if (!Buffer.from(heap.subarray(pointer, pointer + expected.length)).equals(expected)) {
      throw Object.assign(new Error('name-buffer-reused'), {code: 'name-buffer-reused'});
    }
  }
  function active(pointer) {
    check(pointer);
    if (allocations.get(pointer) < expected.length - 1 + 2048) {
      throw new Error('player-operation-workspace-too-small');
    }
  }
  const module = {
    HEAPU8: heap,
    _jsmalloc(size) {
      const result = cursor; cursor += (size + 15) & ~15;
      allocations.set(result, size); return result;
    },
    _jsfree(pointer) { allocations.delete(pointer); },
    _CNTV_InitPlayer(pointer) {
      active(pointer);
      const request = new XMLHttpRequest();
      request.open('GET', 'https://tv.cctv.com/Library/H5player.json');
      request.send();
    },
    _CNTV_UpdatePlayer(pointer) { active(pointer); return 0; },
    _CNTV_UnInitPlayer(pointer) { active(pointer); },
    _CNTV_jsdecLive8(name, data, length) {
      check(name);
      if (allocations.get(data) < length + 65536) throw new Error('media-workspace-too-small');
      // A caller must not reuse this mutable ABI argument for later calls.
      heap[name] = 88;
      return length;
    }
  };
  setImmediate(options.onRuntimeInitialized);
  return module;
};
"""


@unittest.skipUnless(shutil.which('node'), 'Node is required for host ABI regression')
class TestEngineABI(unittest.TestCase):
    def test_mutable_player_name_is_fresh_for_every_operation_and_batch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            modules = root / 'node_modules'
            (root / 'package.json').write_text('{}')
            for name, source in [('fake-indexeddb/auto.js', ''), ('xhr2/index.js', XHR)]:
                path = modules / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source)
            for package, symbol in [('http-proxy-agent', 'HttpProxyAgent'),
                                    ('https-proxy-agent', 'HttpsProxyAgent')]:
                path = modules / package
                path.mkdir(parents=True)
                (path / 'package.json').write_text(json.dumps({'type': 'module', 'exports': './index.js'}))
                (path / 'index.js').write_text(f'export class {symbol} {{}}')
            runtime = root / 'runtime.cjs'
            runtime.write_text(RUNTIME)
            nals = [b'\x67\x64\x01SPS', b'\x65IDR', b'\x09\xf0', b'\x41PFRAME']
            requests = [{'id': index, 'nals': [base64.b64encode(n).decode() for n in nals]}
                        for index in range(3)]
            large = b'\x09' + b'L' * (256 * 1024)
            requests.append({'id': 3, 'nals': [base64.b64encode(large).decode()]})
            result = subprocess.run(
                [shutil.which('node'), str(Path(__file__).resolve().parents[1] / 'engine.cjs'),
                 '--runtime', str(runtime), '--modules', str(modules)],
                input=''.join(json.dumps(request)+'\n' for request in requests),
                text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            messages = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(messages[0], {'ready': True})
            self.assertEqual(len(messages), 5)
            for index, response in enumerate(messages[1:4]):
                self.assertEqual(response['id'], index)
                self.assertTrue(response['ok'])
                output = [base64.b64decode(value) for value in response['nals']]
                self.assertEqual(output, [b'\x67\x64\x00SPS', *nals[1:]])
            self.assertEqual(messages[4]['id'], 3)
            self.assertEqual(base64.b64decode(messages[4]['nals'][0]), large)
            self.assertEqual(result.stderr, '')
