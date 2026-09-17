#!/usr/bin/env python3
"""Live fault qualification of an unmodified release archive (macOS only).

Requires C1_TEST_RAW_FIXTURE, Capture One 16.8.5.30 running with ZERO documents,
and exclusive use of the application. Creates and retains a disposable Session.
Pauses Capture One with an independent resume watchdog; kills only its own MCP
client; restarts Capture One between fault cases. Never retries a write.
Fixtures default to .build/recovery-fixtures; C1_RECOVERY_FIXTURE_PARENT overrides
the parent with an absolute, non-aliased path outside /tmp and /private/tmp.
C1_RECOVERY_SHUTDOWN_MODE is quit (default) or explicit sigterm; no fallback.
Usage: python3 Tests/recovery_integration_test.py ARCHIVE EVIDENCE_DIRECTORY
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SHUTDOWN_MODES = {'quit': 'native-quit', 'sigterm': 'process-termination'}


def fixture_parent():
    parent = Path(os.environ.get('C1_RECOVERY_FIXTURE_PARENT', ROOT / '.build/recovery-fixtures'))
    if not parent.is_absolute() or parent != parent.resolve():
        raise ValueError('C1_RECOVERY_FIXTURE_PARENT must be an absolute path without symlink aliases')
    if any(parent == base or base in parent.parents for base in [Path('/tmp'), Path('/private/tmp')]):
        raise ValueError('Recovery fixtures must be outside /tmp and /private/tmp')
    return parent


def process_exited(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    # Permission errors are not evidence of process exit.
    return False


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def ae(body, timeout=30):
    result = subprocess.run(['osascript', '-s', 's', '-e',
        'tell application "/Applications/Capture One.app"\n' + body + '\nend tell'],
        capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr)
    value = result.stdout.strip()
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def wait_for(fn, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.002)
    raise TimeoutError('Condition not observed; do not retry the faulted operation')


class Run:
    def __init__(self, archive, evidence):
        self.shutdown_mode = os.environ.get('C1_RECOVERY_SHUTDOWN_MODE', 'quit')
        if self.shutdown_mode not in SHUTDOWN_MODES:
            raise ValueError('C1_RECOVERY_SHUTDOWN_MODE must be quit or sigterm')
        self.fixture_parent = fixture_parent()
        self.fixture_parent.mkdir(parents=True, exist_ok=True)
        self.archive = archive.resolve()
        self.evidence = evidence.resolve()
        self.evidence.mkdir(parents=True, exist_ok=False)
        self.events = self.evidence / 'events.jsonl'
        shutil.copy2(__file__, self.evidence / 'harness.py')
        patch = subprocess.check_output(['git', 'diff', 'HEAD', '--', 'Sources'], cwd=ROOT)
        # A development candidate may add source files before they are committed.
        # Include them so the recorded source patch reproduces the actual binary inputs.
        untracked = subprocess.check_output(
            ['git', 'ls-files', '--others', '--exclude-standard', '-z', '--', 'Sources'], cwd=ROOT)
        for name in untracked.split(b'\0'):
            if name:
                added = subprocess.run(['git', 'diff', '--no-index', '--', '/dev/null', os.fsdecode(name)],
                                       cwd=ROOT, capture_output=True)
                assert added.returncode in [0, 1], added.stderr
                patch += added.stdout
        (self.evidence / 'source.patch').write_bytes(patch)
        self.work = Path(tempfile.mkdtemp(prefix='c1-recovery-', dir=self.fixture_parent))
        self.session = self.work / 'recovery'
        self.db = self.session / 'recovery.cosessiondb'
        self.journal = self.session / '.c1/journal.jsonl'
        self.child = None
        self.paused = None
        self.owns_session = False
        self.hidden_bundle = None
        self.restart_in_progress = False
        self.restart_number = 0

    def log(self, event, **data):
        with self.events.open('a') as stream:
            stream.write(json.dumps(dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                         event=event, **data)) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        print(event, flush=True)

    def cli(self, *args, ok=True):
        p = subprocess.run([str(self.c1), *args, '--format', 'json'],
                           capture_output=True, text=True, timeout=180)
        value = json.loads(p.stdout.strip() or p.stderr.strip())
        self.log('cli', args=args, code=p.returncode, response=value)
        if ok:
            assert p.returncode == 0, value
        else:
            assert p.returncode != 0, value
        return value

    def records(self):
        if not self.journal.exists():
            return []
        # Only complete lines: the external observer may catch an append in progress.
        lines = self.journal.read_bytes().split(b'\n')[:-1]
        return [json.loads(line) for line in lines if line]

    def pid(self):
        pids = subprocess.check_output(['pgrep', '-x', 'Capture One'], text=True).split()
        assert len(pids) == 1, pids
        pid = int(pids[0])
        command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
        assert command == '/Applications/Capture One.app/Contents/MacOS/Capture One', command
        return pid

    def fixture_snapshot(self, phase):
        # Exact-build diagnostics only. Private database rows never authorize writes.
        destination = self.evidence / f'restart-{self.restart_number}-{phase}.json'
        try:
            with sqlite3.connect(self.db.as_uri() + '?mode=ro', uri=True) as connection:
                connection.row_factory = sqlite3.Row
                data = {name: [dict(row) for row in connection.execute(query)] for name, query in {
                    'images': 'SELECT Z_PK,ZIMAGEUUID,ZIMAGELOCATION,ZIMAGEFILENAME FROM ZIMAGE',
                    'paths': 'SELECT Z_PK,ZMACROOT,ZRELATIVEPATH,ZISRELATIVE FROM ZPATHLOCATION',
                    'variants': 'SELECT Z_PK,ZIMAGE,ZINDEX,ZVARIANTUUID FROM ZVARIANT',
                }.items()}
                data['quickCheck'] = connection.execute('PRAGMA quick_check').fetchone()[0]
            destination.write_text(json.dumps(data, indent=2) + '\n')
            self.log('fixture-snapshot', phase=phase, path=str(destination))
        except (sqlite3.Error, OSError) as error:
            self.log('fixture-snapshot-failed', phase=phase, error=repr(error))

    def restart(self):
        assert self.owns_session, 'Only the owned recovery fixture may be restarted'
        assert self.shutdown_mode in SHUTDOWN_MODES
        self.restart_in_progress = True
        self.restart_number += 1
        try:
            self._restart()
        except BaseException as error:
            # Leave cleanup suppressed: another Apple Event could reenter a stalled
            # quit or launch the application after a failed reopen.
            self.log('restart-failed', shutdownMode=self.shutdown_mode, error=repr(error))
            raise
        self.restart_in_progress = False

    def _restart(self):
        assert ae('return count of documents') == 1
        assert Path(ae('return id of first document')).resolve() == self.session.resolve()
        old = self.pid()
        self.log('restart-started', oldPid=old, shutdownMode=self.shutdown_mode,
                 shutdownKind=SHUTDOWN_MODES[self.shutdown_mode], restartNumber=self.restart_number)
        # A native quit can stall even with zero documents. Close only our fixture,
        # verify the process again, and never silently switch shutdown modes.
        ae('close first document', timeout=60)
        assert ae('return count of documents') == 0
        self.fixture_snapshot('closed')
        assert self.pid() == old, 'Application changed before shutdown'
        assert ae('return count of documents') == 0
        try:
            if self.shutdown_mode == 'quit':
                ae('quit', timeout=60)
            else:
                os.kill(old, signal.SIGTERM)
            wait_for(lambda: process_exited(old))
        except (subprocess.TimeoutExpired, TimeoutError):
            self.log('shutdown-stalled', oldPid=old, shutdownMode=self.shutdown_mode)
            try:
                # Sample only the still-running verified application, never a reused PID.
                if self.pid() == old:
                    result = subprocess.run(['sample', str(old), '3', '-file',
                        str(self.evidence / f'restart-{self.restart_number}-sample.txt')],
                        capture_output=True, text=True, timeout=10)
                    self.log('shutdown-sample', code=result.returncode, stderr=result.stderr)
            except Exception as error:
                self.log('shutdown-sample-failed', error=repr(error))
            raise
        self.log('process-exited', oldPid=old, shutdownMode=self.shutdown_mode)
        self.fixture_snapshot('terminated')
        subprocess.run(['open', '-a', '/Applications/Capture One.app', str(self.db)], check=True)
        def ready():
            try:
                return (ae('return count of documents', timeout=5) == 1 and
                        Path(ae('return id of first document', timeout=5)).resolve() == self.session.resolve())
            except (RuntimeError, subprocess.TimeoutExpired):
                return False
        wait_for(ready, 60)
        new = self.pid()
        assert new != old
        self.log('restart', oldPid=old, newPid=new, shutdownMode=self.shutdown_mode,
                 shutdownKind=SHUTDOWN_MODES[self.shutdown_mode])

    def clone(self):
        clone = self.cli('variant', 'clone', self.source)
        current = self.cli('get', clone['workingRef'])
        return clone, current

    def identities(self):
        variants = self.cli('variants', 'list')
        self.verify_image_paths(variants)
        return sorted((v['id'], v['parentImagePath']) for v in variants)

    def verify_image_paths(self, variants):
        for variant in variants:
            assert variant['parentImagePath'] == str(self.raw), (
                'Native image path differs from the fixture path; stop before further mutations', variant)

    def recovery(self, operation, clone, label):
        before = self.identities()
        self.log('recovery-inventory', case=label, phase='before-restart', identities=before)
        count = len(self.records())
        state = self.cli('operation', 'status', operation)
        assert state['status'] in ('pending', 'outcome-unknown')
        blocked = self.cli('variant', 'clone', self.source, ok=False)
        assert blocked['error']['code'] == 'outcome-unknown', blocked
        assert blocked['error']['operationId'] == operation
        assert len(self.records()) == count, 'Blocked operation must not dispatch or append'
        assert self.identities() == before
        self.restart()
        after = self.identities()
        self.log('recovery-inventory', case=label, phase='after-restart', identities=after)
        assert after == before, 'Restart must preserve native IDs, count, and parent-image paths'
        # Restart alone is insufficient: the explicit status operation must reconcile.
        blocked = self.cli('variant', 'clone', self.source, ok=False)
        assert blocked['error']['code'] == 'outcome-unknown'
        reconciled = self.cli('operation', 'status', operation)
        assert reconciled['status'] == 'reconciled'
        if label == 'geometry-apple-event-timeout':
            assert reconciled.get('beforeGeometry') and reconciled.get('intendedGeometry') and reconciled.get('afterGeometry')
        if label == 'corrected-geometry-apple-event-timeout':
            assert reconciled.get('beforeGeometry') and reconciled.get('requestedGeometry') and reconciled.get('afterGeometry')
            assert reconciled['requestedGeometry']['rotation'] == 3
            assert reconciled['afterGeometry']['lensGeometry'] == reconciled['beforeGeometry']['lensGeometry']
        stale = self.cli('get', clone['workingRef'], ok=False)
        assert stale['error']['code'] == 'document-changed', stale
        assert self.identities() == before, 'Recovery must not create/adopt/delete variants'
        original_now = self.cli('get', self.source)
        assert original_now['stateHash'] == self.original['stateHash']
        assert original_now.get('geometry') == self.original.get('geometry')
        assert sha(self.raw) == self.raw_hash
        fresh, current = self.clone()
        self.cli('set', fresh['workingRef'], '--if-state', current['stateHash'], 'exposure=0.125')
        if label in ('geometry-apple-event-timeout', 'corrected-geometry-apple-event-timeout'):
            if label == 'corrected-geometry-apple-event-timeout':
                self.enable_lens_correction(fresh)
            geometry_state = self.cli('get', fresh['workingRef'])['geometryStateHash']
            self.cli('geometry', 'set', fresh['workingRef'], '--if-geometry-state', geometry_state, '--rotation', '2', '--aspect-ratio', '1.5')
        self.cli('variant', 'delete', fresh['workingRef'])
        assert self.identities() == before
        self.log('case-passed', case=label, operationId=operation,
                 rawSHA256=sha(self.raw), observations=reconciled, shutdownMode=self.shutdown_mode)

    def enable_lens_correction(self, clone):
        current = self.cli('get', clone['workingRef'])
        entry = dict(self.records()[-1], operationId=str(uuid.uuid4()), operationType='lens-fixture',
                     status='pending', workingRef=clone['workingRef'], nativeVariantId=current['id'],
                     beforeGeometry=current['geometry'])
        def append():
            with self.journal.open('a') as stream:
                stream.write(json.dumps(entry)+'\n'); stream.flush(); os.fsync(stream.fileno())
        append()
        self.log('corrected-lens-fixture-pending', operationId=entry['operationId'], nativeVariantId=current['id'])
        ae(f'set distortion of lens correction of variant id {json.dumps(current["id"])} of current document to 100')
        observed = self.cli('get', clone['workingRef'])
        assert observed['geometry']['lensGeometry'][0] == 100
        entry['status'] = 'succeeded'; entry['afterGeometry'] = observed['geometry']; append()
        return observed

    def apple_event_timeout(self, geometry=False, corrected=False):
        clone, current = self.clone()
        if corrected:
            assert geometry
            current = self.enable_lens_correction(clone)
        known = {r['operationId'] for r in self.records()}
        pid = self.pid()
        # Watchdog is independent of this controller. Never leave the GUI suspended.
        watchdog = subprocess.Popen([sys.executable, '-c',
            'import os,signal,sys,time; time.sleep(150); os.kill(int(sys.argv[1]),signal.SIGCONT)', str(pid)])
        try:
            command = ([str(self.c1), 'geometry', 'set', clone['workingRef'], '--if-geometry-state',
                        current['geometryStateHash'], '--rotation', '3', '--aspect-ratio', '1.5'] if geometry else
                       [str(self.c1), 'set', clone['workingRef'], '--if-state', current['stateHash'], 'exposure=0.625'])
            self.child = subprocess.Popen(command + ['--format', 'json'],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            pending = wait_for(lambda: next((r for r in self.records()
                if r['operationId'] not in known and r['status'] == 'pending'), None))
            os.kill(pid, signal.SIGSTOP)
            self.paused = pid
            self.log('target-paused-after-pending', pid=pid, pending=pending,
                     limitation='External pause races handler execution; does not identify the particular Apple Event in flight.')
            out, err = self.child.communicate(timeout=145)
            result = json.loads(out.strip() or err.strip())
            self.log('apple-event-timeout-reply', code=self.child.returncode, response=result)
            assert self.child.returncode != 0
            assert result['error']['code'] == 'timeout', result
            assert '-1712' in result['error']['message'], result
            assert result['error']['operationId'] == pending['operationId']
        finally:
            if self.paused:
                os.kill(pid, signal.SIGCONT)
                self.paused = None
            watchdog.terminate()
            watchdog.wait(timeout=5)
            if self.child and self.child.poll() is None:
                self.child.kill()
                self.child.wait()
        self.log('target-resumed', current=self.cli('get', clone['workingRef']))
        label = 'corrected-geometry-apple-event-timeout' if corrected else ('geometry-apple-event-timeout' if geometry else 'real-apple-event-timeout')
        self.recovery(pending['operationId'], clone, label)

    def preview_timeout(self):
        clone, _ = self.clone()
        result = self.cli('preview', clone['workingRef'], '--timeout', '0.001', ok=False)
        assert result['error']['code'] == 'timeout', result
        operation = result['error']['operationId']
        entry = self.cli('operation', 'status', operation)
        folder = Path(entry['previewOutputPath'])
        file = wait_for(lambda: next(folder.glob('*.jpg'), None), 60)
        wait_for(lambda: file.read_bytes().endswith(b'\xff\xd9'), 60)
        self.log('output-observed-after-timeout', path=str(file), bytes=file.stat().st_size, sha256=sha(file))
        self.recovery(operation, clone, 'preview-timeout-with-eventual-output')

    def mcp_death(self):
        clone, _ = self.clone()
        known = {r['operationId'] for r in self.records()}
        self.child = subprocess.Popen([str(self.mcp)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def send(value):
            self.child.stdin.write(json.dumps(value) + '\n')
            self.child.stdin.flush()
        send(dict(jsonrpc='2.0', id=1, method='initialize', params=dict(
            protocolVersion='2024-11-05', capabilities={}, clientInfo=dict(name='recovery-qualification', version='1'))))
        import select
        assert select.select([self.child.stdout], [], [], 15)[0], 'MCP initialization deadline'
        self.log('mcp-initialize', response=json.loads(self.child.stdout.readline()))
        send(dict(jsonrpc='2.0', method='notifications/initialized'))
        arguments = dict(ref=clone['workingRef'], timeout=60)
        contract = json.loads(subprocess.check_output([str(self.c1), 'schema'], text=True))
        assert set(arguments) <= set(contract['requests']['preview']['properties'])
        send(dict(jsonrpc='2.0', id=2, method='tools/call', params=dict(name='preview', arguments=arguments)))
        pending = wait_for(lambda: next((r for r in self.records()
            if r['operationId'] not in known and r['status'] == 'pending'), None))
        folder = Path(pending['previewOutputPath'])
        file = wait_for(lambda: next(folder.glob('*.jpg'), None), 60)
        # A newly created output establishes real export dispatch. Kill before the
        # 400ms stable-file polling window and before a success journal snapshot.
        self.child.kill()
        out, err = self.child.communicate(timeout=5)
        assert self.child.returncode == -signal.SIGKILL
        assert not out.strip(), 'Preview response already delivered; this was not a lost-reply case'
        latest = [r for r in self.records() if r['operationId'] == pending['operationId']][-1]
        assert latest['status'] == 'pending', latest
        wait_for(lambda: file.read_bytes().endswith(b'\xff\xd9'), 60)
        self.log('mcp-killed-after-export-dispatch', code=self.child.returncode, stderr=err,
                 operationId=pending['operationId'], outputSHA256=sha(file),
                 limitation='File creation proves dispatch, not that rendering was still outstanding at SIGKILL.')
        self.recovery(pending['operationId'], clone, 'mcp-death-after-export-dispatch')

    def run(self):
        fixture = Path(os.environ['C1_TEST_RAW_FIXTURE']).resolve()
        assert fixture.is_file()
        digest = sha(self.archive)
        assert digest == Path(str(self.archive) + '.sha256').read_text().split()[0]
        unpack = self.work / 'archive'
        with tarfile.open(self.archive) as tf:
            for member in tf.getmembers():
                assert not member.name.startswith('/') and '..' not in Path(member.name).parts
                assert member.isfile() or member.isdir(), 'Archive links are unsupported'
            tf.extractall(unpack)
        package, = unpack.iterdir()
        self.c1, self.mcp = package / 'bin/c1', package / 'bin/c1-mcp'
        bundle = ROOT / '.build/release/c1_CaptureOneCore.bundle'
        if bundle.exists():
            hidden = bundle.with_name('c1_CaptureOneCore.bundle.recovery-hidden')
            assert not hidden.exists(), 'Previous hidden bundle needs inspection'
            bundle.rename(hidden)
            self.hidden_bundle = (hidden, bundle)
        self.log('build-resource-fallback-hidden')
        assert ae('return count of documents') == 0, 'Close documents before this exclusive fault qualification'
        assert ae('return version') == '16.8.5.30'
        self.log('environment', archive=self.archive.name, archiveSHA256=digest,
                 cliSHA256=sha(self.c1), mcpSHA256=sha(self.mcp),
                 handlersSHA256=sha(next(package.rglob('Handlers.applescript'))),
                 commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                 sourcePatchSHA256=sha(self.evidence / 'source.patch'),
                 harnessSHA256=sha(__file__), macOS=subprocess.check_output(['sw_vers'], text=True),
                 architecture=os.uname().machine, swift=subprocess.check_output(['swift', '--version'], text=True),
                 appVersion=ae('return version'), session=str(self.session), sourceRAW_SHA256=sha(fixture),
                 fixtureParent=str(self.fixture_parent), shutdownMode=self.shutdown_mode,
                 shutdownKind=SHUTDOWN_MODES[self.shutdown_mode])
        ae(f'make new document with properties {{name:"recovery", kind:session, path:{json.dumps(str(self.work))}}}')
        self.owns_session = True
        self.raw = self.session / 'Capture' / ('fixture' + fixture.suffix)
        self.raw.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(fixture, self.raw)
        self.raw_hash = sha(self.raw)
        ae('set current collection of first document to collection "Capture" of first document')
        doctor = self.cli('doctor')
        assert doctor['allChecksPassed'] and doctor['isSession'] and doctor['exactBuildMatched'] and doctor['writesEnabled']
        self.cli('doc', 'info')
        variants = wait_for(lambda: self.cli('variants', 'list'))
        assert len(variants) == 1
        self.verify_image_paths(variants)
        self.source = variants[0]['id']
        self.original = self.cli('get', self.source)
        # Regression for transient collection-scoped clone ID readback (-1700).
        for _ in range(10):
            clone, _ = self.clone()
            self.cli('variant', 'delete', clone['workingRef'])
        assert len(self.cli('variants', 'list')) == 1
        self.log('clone-readback-regression-passed', cycles=10)
        self.apple_event_timeout()
        self.apple_event_timeout(geometry=True)
        self.apple_event_timeout(geometry=True, corrected=True)
        self.preview_timeout()
        self.mcp_death()
        assert sha(fixture) == self.raw_hash
        self.log('all-cases-passed', cases=5, rawSHA256=sha(self.raw),
                 shutdownMode=self.shutdown_mode, shutdownKind=SHUTDOWN_MODES[self.shutdown_mode])

    def finish(self):
        if self.hidden_bundle:
            self.hidden_bundle[0].rename(self.hidden_bundle[1])
        if self.paused:
            os.kill(self.paused, signal.SIGCONT)
        if self.child and self.child.poll() is None:
            self.child.kill()
            self.child.wait()
        if self.journal.exists():
            shutil.copy2(self.journal, self.evidence / 'journal.jsonl')
            shutil.copy2(self.journal.with_name('provenance.json'), self.evidence / 'provenance.json')
        # Keep the Session and ambiguous clones as evidence. Never delete/adopt them.
        if self.owns_session and not self.restart_in_progress:
            try:
                if (ae('return count of documents') == 1 and
                        Path(ae('return id of first document')).resolve() == self.session.resolve()):
                    ae('close first document')
                    self.log('cleanup', openDocuments=ae('return count of documents'), retainedSession=str(self.session))
            except Exception as error:
                self.log('cleanup-failed', error=str(error))
        elif self.restart_in_progress:
            self.log('cleanup-skipped', reason='incomplete restart; no further Apple Events',
                     retainedSession=str(self.session))


if __name__ == '__main__':
    run = Run(Path(sys.argv[1]), Path(sys.argv[2]))
    try:
        run.run()
    except BaseException as error:
        run.log('failed', error=repr(error))
        raise
    finally:
        run.finish()
