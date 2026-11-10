#!/usr/bin/env python3
"""Run the pinned upstream's isolated JavaHost regressions on both class paths."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import zipfile

TESTS = ('HostCompatibilityTest', 'PluginLoadingTest', 'CloudDriveBridgeTest',
         'NativeLibrariesTest', 'PhiMemoryTest', 'LazyDexTest', 'FillArrayDataTest',
         'LongStringTest', 'FieldConstantTest', 'SuperSelfCallTest',
         'InterfaceDefaultMethodTest', 'PluginClassLookupTest', 'SuperclassMergeTest',
         'FongMiSdkTest', 'HandlerLifetimeTest', 'PluginWindowsTest',
         'PreparationProgressTest', 'ConversionResumeTest', 'ConvertAheadTest',
         'RequestCancellationTest', 'RequestStopTest')


def run(command, cwd, log, timeout):
    started = time.monotonic()
    timed_out = False
    with log.open('w') as output:
        process = subprocess.Popen(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            code = process.wait()
    return {'returncode': code, 'timed_out': timed_out,
            'elapsed_seconds': round(time.monotonic() - started, 3)}


def check(source, baseline, candidate, java_home, output):
    source, baseline, candidate, java_home, output = (
        p.resolve() for p in (source, baseline, candidate, java_home, output))
    output.mkdir(parents=True, exist_ok=True)
    # The pinned POM uses SLF4J 2.x. One upstream fixture still names its 1.x
    # factory package; verify the actual dependency before adapting that test.
    with zipfile.ZipFile(baseline / 'lib/slf4j-simple-2.0.13.jar') as jar:
        if 'org/slf4j/simple/SimpleLoggerFactory.class' not in jar.namelist():
            raise ValueError('Unexpected SLF4J fixture dependency')
    adjustments = ['Use org.slf4j.simple.SimpleLoggerFactory for the pinned slf4j-simple 2.0.13 fixture']
    with tempfile.TemporaryDirectory(prefix='cctv-host-compat-') as tmp:
        lab = Path(tmp)
        sources, classes = lab / 'java', lab / 'classes'
        sources.mkdir(); classes.mkdir()
        for name in (*TESTS, 'GuestLoadClass'):
            text = (source / 'Tests/Java' / (name + '.java')).read_text()
            # The upstream driver uses /private/tmp for its child JVMs. Keep all
            # processes in this lab on Linux as well as on the Apple build host.
            text = text.replace('-Djava.io.tmpdir=/private/tmp', '-Djava.io.tmpdir=' + str(lab))
            if name == 'HostCompatibilityTest':
                old = 'loader.loadClass("org.slf4j.impl.SimpleLoggerFactory")'
                if text.count(old) != 1:
                    raise ValueError('Pinned SLF4J compatibility fixture changed')
                text = text.replace(old, 'loader.loadClass("org.slf4j.simple.SimpleLoggerFactory")')
            (sources / (name + '.java')).write_text(text)
        compile_cp = str(baseline / 'host.jar') + os.pathsep + str(baseline / 'lib/*')
        compiled = run([str(java_home / 'bin/javac'), '--release', '17', '-encoding', 'UTF-8',
                        '-cp', compile_cp, '-d', str(classes),
                        *map(str, sorted(sources.glob('*.java')))], lab, output / 'compile.log', 120)
        if compiled['returncode']:
            raise RuntimeError('Pinned compatibility test compilation failed: ' + str(output / 'compile.log'))

        def profile(label, host):
            work = lab / label
            work.mkdir()
            shutil.copytree(source / 'Tests/TVCoreTests/Fixtures', work / 'Tests/TVCoreTests/Fixtures')
            home, temp = work / 'home', work / 'tmp'
            home.mkdir(); temp.mkdir()
            cp = os.pathsep.join((str(classes), str(host / 'host.jar'), str(host / 'lib/*')))
            results = []
            for name in TESTS:
                options = ['--add-opens', 'java.base/java.lang=ALL-UNNAMED',
                           '-Djava.io.tmpdir=' + str(temp), '-Duser.home=' + str(home),
                           '-Dsun.net.http.allowRestrictedHeaders=true']
                if name in ('PhiMemoryTest', 'LazyDexTest'):
                    options += ['-Xmx128m']
                if name == 'RequestCancellationTest':
                    options += ['-Dtvbox.stuckGraceMillis=500']
                if name == 'RequestStopTest':
                    options += ['-Dtvbox.ownSignInPollMillis=50']
                result = run([str(java_home / 'bin/java'), *options, '-cp', cp, name],
                             work, output / (label + '-' + name + '.log'), 90)
                result['test'] = name
                results.append(result)
            return results

        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(profile, label, host) for label, host in
                       (('baseline', baseline), ('candidate', candidate))]
            results = dict(zip(('baseline', 'candidate'), (f.result() for f in futures)))
        passed = all(row['returncode'] == 0 and not row['timed_out'] for rows in results.values() for row in rows)
        report = {'passed': passed, 'tests_per_profile': len(TESTS), 'results': results,
                  'test_fixture_adjustments': adjustments,
                  'scope': 'Pinned upstream local fixtures; desktop JVM class-path compatibility, plus separate embedded iOS smoke'}
        (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
        if not passed:
            raise RuntimeError('JavaHost compatibility failed; inspect per-test logs in ' + str(output))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--baseline-host', type=Path, required=True)
    parser.add_argument('--candidate-host', type=Path, required=True)
    parser.add_argument('--java-home', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    check(args.source, args.baseline_host, args.candidate_host, args.java_home, args.output)
