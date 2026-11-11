"""Run the shipped DOM selector against controlled frames, without remote content."""
import json
import pathlib
import re
import shutil
import subprocess
import unittest

class WebMediaExtractionTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'requires Node.js')
    def test_ten_media_and_frame_cases(self):
        source = (pathlib.Path(__file__).resolve().parents[1] / 'Sources/MediaWebViewController.m').read_text()
        match = re.search(r'NSString \*script=@("(?:[^"\\]|\\.)*");', source)
        self.assertIsNotNone(match)
        script = json.loads(match.group(1))
        runner = r'''
const assert=require('node:assert/strict');
const frame=(videos=[],frames=[])=>({document:{querySelectorAll:()=>videos},frames});
const blocked={get document(){throw Error('cross origin');}};
const cases=[
[frame([{currentSrc:'https://media.test/a.m3u8'}]),'https://media.test/a.m3u8'],
[frame([{src:'http://media.test/a.mp4'}]),'http://media.test/a.mp4'],
[frame([{currentSrc:'https://media.test/a?sig=a%2Bb&x=1'}]),'https://media.test/a?sig=a%2Bb&x=1'],
[frame([{currentSrc:'blob:local'}]),''],
[frame([{src:'javascript:invalid'}]),''],
[frame([]),''],
[frame([],[frame([{src:'https://media.test/child.m3u8'}])]),'https://media.test/child.m3u8'],
[frame([],[blocked]),''],
[frame([],[blocked,frame([{src:'https://media.test/next.mp4'}])]),'https://media.test/next.mp4'],
[frame([{currentSrc:'https://media.test/active.mp4',src:'https://media.test/old.mp4'}]),'https://media.test/active.mp4']];
for(const [window,expected] of cases)assert.equal(eval(SCRIPT),expected);
process.stdout.write(JSON.stringify({passed:cases.length}));
'''.replace('SCRIPT',json.dumps(script))
        result=subprocess.run(['node','-e',runner],capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['passed'],10)
