#!/usr/bin/env python3
"""Live fault qualification of an unmodified release archive (macOS only).

Requires C1_TEST_RAW_FIXTURE, Capture One 16.8.5.30 running with ZERO documents,
and exclusive use of the application. Creates and retains a disposable Session.
Pauses Capture One with an independent resume watchdog after a write is journaled,
then interrupts the write's own c1 caller: by default it kills the caller; the
timeout cases wait for the real Apple Event timeout instead. Each fault resolves by
probe barrier (operation status, same app instance) or by restarting Capture One.
Never retries a write.
Fixtures default to .build/recovery-fixtures; C1_RECOVERY_FIXTURE_PARENT overrides
the parent with an absolute, non-aliased path outside /tmp and /private/tmp.
C1_RECOVERY_SHUTDOWN_MODE is sigterm (default) or explicit quit; no fallback.
The barrier case runs first, in its own Session, and also needs C1_TEST_PEOPLE_FIXTURE.
Compound edit cases carry a recipe: prefix and run last in their own Session; all
selects every case.
Usage: python3 Tests/recovery_integration_test.py ARCHIVE EVIDENCE_DIRECTORY [--cases tonal recipe:lens]
"""
import argparse
from dataclasses import dataclass
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
from typing import Callable, Optional
import uuid

from contract_test import complete
import stored_read

ROOT = Path(__file__).resolve().parents[1]
SHUTDOWN_MODES = {'quit': 'native-quit', 'sigterm': 'process-termination'}
LOOKUP_DRIVER = '''

on run argv
    set rows to my lookupVariantIdentities({item 1 of argv, missing value}, rest of argv)
    set output to {}
    repeat with r in rows
        set end of output to (variantId of r) & tab & ((isPresent of r) as text) & tab & (parentImagePath of r)
    end repeat
    set AppleScript's text item delimiters to linefeed
    return output as text
end run
'''
RECOVERY_CASES = ('clone-readback', 'tonal', 'timeout', 'metadata', 'native', 'native-action', 'geometry', 'orientation',
                  'lens', 'perspective', 'keystone', 'clone', 'delete', 'preview', 'late-preview', 'save-stall', 'mcp-death')
RECIPE_CASES = ('native', 'native-action', 'lens', 'layer-color', 'tonal', 'geometry', 'preview', 'late-preview', 'mcp-death')
RECIPE_PREFIX = 'recipe:'
BARRIER_CASE = 'barrier'
ALL_CASES = (BARRIER_CASE, *RECOVERY_CASES, *(RECIPE_PREFIX + case for case in RECIPE_CASES))

# How the harness interrupts a journaled write, and how the uncertain outcome resolves.
KILL, TIMEOUT = 'kill', 'timeout'
BARRIER, RESTART = 'barrier', 'restart'
# Operation status reconciles these in the same app instance after a probe barrier.
BARRIER_OPERATIONS = frozenset({'set', 'add', 'reset', 'metadata_set', 'geometry_set', 'geometry_restore',
                                'clone', 'baseline', 'delete'})
BARRIER_ACTIONS = frozenset({'layer.create', 'layer.delete', 'mask.people', 'color.create', 'color.delete',
                             'dehaze.pick', 'dehaze.recalculate', 'lens.reset', 'luma.clear', 'style.apply',
                             'mask.clear', 'mask.invert', 'mask.fill', 'mask.rasterize', 'mask.copy'})


def barrier_covered(entry):
    # A save-stalled write has finished but is unsaved; only a restart reveals what survived.
    if entry.get('saveStalledAt'):
        return False
    if entry['operationType'] == 'native':
        return entry.get('nativeAction') is None or entry['nativeAction'] in BARRIER_ACTIONS
    return entry['operationType'] in BARRIER_OPERATIONS


def selected_cases(cases):
    if list(cases) == ['all']:
        return list(RECOVERY_CASES)
    if not cases or len(set(cases)) != len(cases) or any(case not in RECOVERY_CASES for case in cases):
        raise ValueError('Select unique recovery cases, or all alone')
    # Clone stress assumes the initial one-variant fixture, before faults retain clones.
    return [case for case in RECOVERY_CASES if case in cases]


def campaign(cases):
    """Split one fault list into the barrier, generic and compound (recipe:) groups."""
    if list(cases) == ['all']:
        return [BARRIER_CASE], list(RECOVERY_CASES), list(RECIPE_CASES)
    if not cases or len(set(cases)) != len(cases) or any(case not in ALL_CASES for case in cases):
        raise ValueError('Select unique recovery cases, or all alone')
    compound = {case[len(RECIPE_PREFIX):] for case in cases if case.startswith(RECIPE_PREFIX)}
    generic = [case for case in cases if not case.startswith(RECIPE_PREFIX) and case != BARRIER_CASE]
    return ([BARRIER_CASE] if BARRIER_CASE in cases else [], (selected_cases(generic) if generic else []),
            [case for case in RECIPE_CASES if case in compound])


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('evidence', type=Path)
    parser.add_argument('--cases', nargs='+', choices=[*ALL_CASES, 'all'], default=['all'])
    args = parser.parse_args(argv)
    try:
        args.cases = campaign(args.cases)
    except ValueError as error:
        parser.error(str(error))
    if args.cases[0] and not Path(os.environ.get('C1_TEST_PEOPLE_FIXTURE', '')).is_file():
        parser.error('The barrier case needs C1_TEST_PEOPLE_FIXTURE, an existing RAW with people')
    return args


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


def launch_session(db):
    # An exited PID can still have a stale Launch Services registration (-600).
    # Request a fresh launch only after proving there is no running C1 process.
    running = subprocess.run(['pgrep', '-x', 'Capture One'], capture_output=True, text=True)
    assert running.returncode == 1 and not running.stdout.strip(), 'Cannot prove Capture One is stopped; do not launch another instance'
    subprocess.run(['open', '-n', '-a', '/Applications/Capture One.app', str(db)], check=True)


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


def adjustments_snapshot(run, ref):
    return run.cli('get', ref, '--native-targets', '[{"scope":"adjustments"}]')['nativeSnapshots'][0]


def tonal_command(run, clone, current):
    return ['set', clone['workingRef'], '--if-state', current['stateHash'], 'exposure=0.625']


def metadata_command(run, clone, current):
    return ['metadata', 'set', clone['workingRef'], '--if-metadata-state', current['metadataStateHash'],
            '--rating', str((current['metadata']['rating'] + 1) % 6),
            '--color-tag', str((current['metadata']['colorTag'] + 1) % 8)]


def native_property_command(run, clone, current):
    state = adjustments_snapshot(run, clone['workingRef'])
    return ['native', 'set', clone['workingRef'], '--if-native-state', state['nativeStateHash'], '--json',
            '{"clarity amount":12,"color balance shadow hue":237,"color balance shadow saturation":0.2}']


def native_action_command(run, clone, current):
    state = adjustments_snapshot(run, clone['workingRef'])
    return ['native', 'action', clone['workingRef'], 'layer.create', '--if-native-state', state['nativeStateHash'],
            '--json', '{"name":"Recovery layer","kind":"filled"}']


def geometry_command(*extra, crop=True):
    def command(run, clone, current):
        return (['geometry', 'set', clone['workingRef'], '--if-geometry-state', current['geometryStateHash'],
                 '--rotation', '3'] + (['--aspect-ratio', '1.5'] if crop else []) + list(extra))
    return command


def clone_command(run, clone, current):
    return ['variant', 'clone', run.source]


def delete_command(run, clone, current):
    return ['variant', 'delete', clone['workingRef']]


def corrected_lens(run, clone):
    return run.enable_lens_correction(clone)


def perspective_lens(run, clone):
    return run.enable_lens_correction(clone, perspective=True)


def check_geometry(reconciled):
    assert reconciled.get('beforeGeometry') and reconciled.get('intendedGeometry') and reconciled.get('afterGeometry'), reconciled


def check_corrected_geometry(reconciled):
    assert reconciled.get('beforeGeometry') and reconciled.get('requestedGeometry') and reconciled.get('afterGeometry'), reconciled
    assert reconciled['requestedGeometry']['rotation'] == 3
    assert reconciled['afterGeometry']['lensGeometry'] == reconciled['beforeGeometry']['lensGeometry']
    assert reconciled['afterGeometry']['keystone'] == reconciled['beforeGeometry']['keystone']


def check_rotation_only(reconciled):
    # Capture One's automatic crop is unknown until observed; only the request is journaled.
    assert reconciled.get('beforeGeometry') and reconciled.get('requestedGeometry') and reconciled.get('afterGeometry'), reconciled
    assert reconciled['requestedGeometry']['rotation'] == 3 and reconciled['requestedGeometry'].get('crop') is None
    assert reconciled['afterGeometry']['rotation'] in (reconciled['beforeGeometry']['rotation'], 3)


def orientation_command(planned):
    # 'planned' crops the oriented canvas through applyGeometry; otherwise Capture One's turned
    # crop stays, through applyCorrectedGeometry.
    def command(run, clone, current):
        return (['geometry', 'set', clone['workingRef'], '--if-geometry-state', current['geometryStateHash'],
                 '--orientation', '90'] + (['--aspect-ratio', '0.75'] if planned else []))
    return command


def check_orientation(reconciled):
    # Planned before dispatch: the oriented 3:4 target is journaled as intendedGeometry.
    assert reconciled.get('beforeGeometry') and reconciled.get('intendedGeometry') and reconciled.get('afterGeometry'), reconciled
    assert reconciled['beforeGeometry']['orientation'] == 0 and reconciled['intendedGeometry']['orientation'] == 90, reconciled
    assert reconciled['afterGeometry']['orientation'] in (0, 90), reconciled


def check_orientation_only(reconciled):
    # Capture One's turned crop is unknown until observed; only the request is journaled.
    assert reconciled.get('beforeGeometry') and reconciled.get('requestedGeometry') and reconciled.get('afterGeometry'), reconciled
    assert reconciled['requestedGeometry']['orientation'] == 90 and reconciled['requestedGeometry'].get('crop') is None, reconciled
    assert reconciled['beforeGeometry']['orientation'] == 0 and reconciled['afterGeometry']['orientation'] in (0, 90), reconciled
    assert reconciled['afterGeometry']['rotation'] == reconciled['beforeGeometry']['rotation'], reconciled


def check_keystone(reconciled):
    assert reconciled.get('beforeGeometry') and reconciled.get('requestedGeometry') and reconciled.get('afterGeometry'), reconciled
    assert reconciled['requestedGeometry']['keystone'] == {'vertical': 12, 'horizontal': -7}
    before_geometry, after_geometry = reconciled['beforeGeometry'], reconciled['afterGeometry']
    assert after_geometry['lensGeometry'] == before_geometry['lensGeometry']
    # Observations only: an interruption can land between setters.
    requested = [before_geometry['keystone'][0], 12, -7, before_geometry['keystone'][3], before_geometry['keystone'][4]]
    for index, value in enumerate(requested):
        assert after_geometry['keystone'][index] in (before_geometry['keystone'][index], value)


def check_metadata(reconciled):
    assert reconciled.get('beforeMetadata') and reconciled.get('intendedMetadata') and reconciled.get('afterMetadata'), reconciled
    # Observations only: an interruption can land between the rating and color tag setters.
    for field in ('rating', 'colorTag'):
        assert reconciled['afterMetadata'][field] in (reconciled['beforeMetadata'][field], reconciled['intendedMetadata'][field])


def check_native(reconciled):
    assert reconciled.get('beforeNative') and reconciled.get('afterNative'), reconciled


def check_clone(reconciled):
    assert 'observedVariantIds' in reconciled and reconciled.get('variantIdsBefore'), reconciled


def resume_geometry(prepare=None):
    def resume(run, fresh):
        if prepare:
            prepare(run, fresh)
        state = run.cli('get', fresh['workingRef'])['geometryStateHash']
        run.cli('geometry', 'set', fresh['workingRef'], '--if-geometry-state', state, '--rotation', '2', '--aspect-ratio', '1.5')
    return resume


def resume_orientation(run, fresh):
    state = run.cli('get', fresh['workingRef'])['geometryStateHash']
    turned = run.cli('geometry', 'set', fresh['workingRef'], '--if-geometry-state', state, '--orientation', '270')
    assert turned['after']['orientation'] == 270 and run.cli('get', fresh['workingRef'])['geometry']['orientation'] == 270, turned


def resume_metadata(run, fresh):
    token = run.cli('get', fresh['workingRef'])['metadataStateHash']
    rated = run.cli('metadata', 'set', fresh['workingRef'], '--if-metadata-state', token, '--rating', '2')
    assert rated['after']['rating'] == 2, rated


def resume_native_property(run, fresh):
    state = adjustments_snapshot(run, fresh['workingRef'])
    resumed = run.cli('native', 'set', fresh['workingRef'], '--if-native-state', state['nativeStateHash'], '--json', '{"clarity amount":5}')
    assert resumed['after']['values']['clarity amount'] == 5


def resume_native_action(run, fresh):
    state = adjustments_snapshot(run, fresh['workingRef'])
    resumed = run.cli('native', 'action', fresh['workingRef'], 'layer.create', '--if-native-state', state['nativeStateHash'],
                      '--json', '{"name":"Fresh recovered layer","kind":"filled"}')
    assert len(resumed['after']['layers']) == len(state['layers']) + 1


@dataclass(frozen=True)
class Fault:
    """One interrupted write: what it sends, how it is interrupted, how it resolves."""
    label: str
    command: Callable
    interruption: str = KILL
    resolution: str = BARRIER
    prepare: Optional[Callable] = None
    check: Optional[Callable] = None
    resume: Optional[Callable] = None


FAULTS = {
    'tonal': (Fault('tonal', tonal_command),),
    # The shipped -1712 path: c1's own timer must fire and journal outcome-unknown.
    'timeout': (Fault('tonal-apple-event-timeout', tonal_command, TIMEOUT, RESTART),),
    'metadata': (Fault('metadata', metadata_command, check=check_metadata, resume=resume_metadata),),
    'native': (Fault('native-property', native_property_command, check=check_native, resume=resume_native_property),),
    'native-action': (Fault('native-action', native_action_command, check=check_native, resume=resume_native_action),),
    'geometry': (Fault('geometry', geometry_command(), check=check_geometry, resume=resume_geometry()),
                 Fault('rotation-only-geometry', geometry_command(crop=False), check=check_rotation_only, resume=resume_geometry())),
    'orientation': (Fault('orientation-geometry', orientation_command(True), check=check_orientation, resume=resume_orientation),
                    Fault('orientation-only-geometry', orientation_command(False), check=check_orientation_only,
                          resume=resume_orientation)),
    'lens': (Fault('corrected-geometry', geometry_command(), prepare=corrected_lens, check=check_corrected_geometry,
                   resume=resume_geometry(corrected_lens)),),
    'perspective': (Fault('perspective-geometry', geometry_command(), prepare=perspective_lens, check=check_corrected_geometry,
                          resume=resume_geometry(perspective_lens)),),
    'keystone': (Fault('keystone-geometry', geometry_command('--keystone-vertical=12', '--keystone-horizontal=-7'),
                       check=check_keystone, resume=resume_geometry()),),
    'clone': (Fault('clone', clone_command, check=check_clone),),
    'delete': (Fault('delete', delete_command),),
}


def native_projection(snapshot):
    # Native state tokens carry journal revisions; compare the observed values only.
    return {key: snapshot.get(key) for key in ('values', 'layers', 'unavailable', 'basicColorCount', 'advancedColorCount')}


class Run:
    CASES = RECOVERY_CASES

    def __init__(self, archive, evidence):
        self.shutdown_mode = os.environ.get('C1_RECOVERY_SHUTDOWN_MODE', 'sigterm')
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
        # Complete results keep the harness assertions independent of compact presentation.
        p = subprocess.run([str(self.c1), *complete(args), '--format', 'json'],
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

    def latest(self, operation):
        return [r for r in self.records() if r['operationId'] == operation][-1]

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
            def query(connection):
                connection.row_factory = sqlite3.Row
                data = {name: [dict(row) for row in connection.execute(query)] for name, query in {
                    'images': 'SELECT Z_PK,ZIMAGEUUID,ZIMAGELOCATION,ZIMAGEFILENAME FROM ZIMAGE',
                    'paths': 'SELECT Z_PK,ZMACROOT,ZRELATIVEPATH,ZISRELATIVE FROM ZPATHLOCATION',
                    'variants': 'SELECT Z_PK,ZIMAGE,ZINDEX,ZVARIANTUUID FROM ZVARIANT',
                }.items()}
                data['quickCheck'] = connection.execute('PRAGMA quick_check').fetchone()[0]
                return data
            data = stored_read.read(self.db, query)
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
        launch_session(self.db)
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

    def recovery(self, operation, clone, label, resolution, check=None, resume=None, also=()):
        entry = [r for r in self.records() if r['operationId'] == operation][-1]
        covered = barrier_covered(entry)
        assert resolution == RESTART or covered, ('Only covered kinds resolve by barrier', entry['operationType'], entry.get('nativeAction'))
        before = self.identities()
        self.log('recovery-inventory', case=label, phase='unresolved', identities=before, resolution=resolution)
        count = len(self.records())
        blocked = self.cli('variant', 'clone', self.source, ok=False)
        assert blocked['error']['code'] == 'outcome-unknown', blocked
        assert blocked['error']['operationId'] == operation
        assert len(self.records()) == count, 'Blocked operation must not dispatch or append'
        assert self.identities() == before
        if resolution == BARRIER:
            pid = self.pid()
            reconciled = self.cli('operation', 'status', operation)
            assert reconciled['status'] == 'reconciled' and reconciled.get('resolution') == 'probe-barrier', reconciled
            assert self.pid() == pid, 'Barrier reconciliation must not restart Capture One'
            self.barrier_observation(reconciled)
        else:
            # Status could resolve a landed preview without a restart, so preview cases that
            # qualify the restart path read the journal instead.
            if entry['operationType'] == 'preview':
                assert entry['status'] in ('pending', 'outcome-unknown'), entry
            elif not covered:
                state = self.cli('operation', 'status', operation)
                assert state['status'] in ('pending', 'outcome-unknown'), state
                assert len(self.records()) == count, 'Status of an uncovered kind must not reconcile before a restart'
            self.restart()
            after = self.identities()
            self.log('recovery-inventory', case=label, phase='after-restart', identities=after)
            assert after == before, 'Restart must preserve native IDs, count, and parent-image paths'
            # Restart alone is insufficient: the explicit status operation must reconcile.
            blocked = self.cli('variant', 'clone', self.source, ok=False)
            assert blocked['error']['code'] == 'outcome-unknown'
            reconciled = self.cli('operation', 'status', operation)
            assert reconciled['status'] == 'reconciled' and reconciled.get('resolution') == 'restart', reconciled
            for other in also:
                observed = self.cli('operation', 'status', other)
                assert observed['status'] == 'reconciled' and observed.get('resolution') == 'restart', observed
            stale = self.cli('get', clone['workingRef'], ok=False)
            assert stale['error']['code'] == 'document-changed', stale
        if check:
            check(reconciled)
        assert self.identities() == before, 'Recovery must not create/adopt/delete variants'
        original_now = self.cli('get', self.source)
        assert original_now['stateHash'] == self.original['stateHash']
        assert original_now.get('geometry') == self.original.get('geometry')
        assert original_now.get('metadataStateHash') == self.original.get('metadataStateHash')
        source_native = adjustments_snapshot(self, self.source)
        assert native_projection(source_native) == native_projection(self.original_native), 'Fault changed the original native state'
        assert sha(self.raw) == self.raw_hash
        fresh, current = self.clone()
        self.cli('set', fresh['workingRef'], '--if-state', current['stateHash'], 'exposure=0.125')
        if resume:
            resume(self, fresh)
        self.cli('variant', 'delete', fresh['workingRef'])
        assert self.identities() == before
        self.log('case-passed', case=label, operationId=operation, resolution=resolution,
                 rawSHA256=sha(self.raw), observations=reconciled, shutdownMode=self.shutdown_mode)

    def barrier_observation(self, reconciled):
        """The old reference reads the recorded observations right away and again later."""
        expected = self.recorded_after(reconciled)
        for phase in ('after-barrier', 'settled'):
            if phase == 'settled':
                time.sleep(2)
            observed = self.observed_after(reconciled)
            self.log('barrier-observation', phase=phase, expected=expected, observed=observed)
            assert observed == expected, ('Barrier observation differs from a later read', phase, expected, observed)

    @staticmethod
    def recorded_after(reconciled):
        if reconciled['operationType'] in ('clone', 'baseline'):
            return dict(created=sorted(reconciled['observedVariantIds']))
        # A pending delete records no after-state, so its presence is the observation.
        if reconciled['operationType'] == 'delete' and 'afterAdjustments' not in reconciled:
            return dict(present=False)
        recorded = dict(present=True, adjustments=reconciled.get('afterAdjustments'),
                        geometry=reconciled.get('afterGeometry'), metadata=reconciled.get('afterMetadata'))
        if reconciled.get('afterNative'):
            recorded['native'] = native_projection(reconciled['afterNative'])
        return recorded

    def observed_after(self, reconciled):
        siblings = {i for i, path in self.identities() if path == reconciled['parentImagePath']}
        if reconciled['operationType'] in ('clone', 'baseline'):
            return dict(created=sorted(siblings - set(reconciled['variantIdsBefore'])))
        if reconciled['nativeVariantId'] not in siblings:
            return dict(present=False)
        targets = ['--native-targets', json.dumps([reconciled['afterNative']['target']])] if reconciled.get('afterNative') else []
        current = self.cli('get', reconciled['workingRef'], *targets)
        observed = dict(present=True, adjustments=current['adjustments'], geometry=current.get('geometry'),
                        metadata={key: current['metadata'][key] for key in ('rating', 'colorTag')})
        if targets:
            observed['native'] = native_projection(current['nativeSnapshots'][0])
        return observed

    def enable_lens_correction(self, clone, perspective=False):
        current = self.cli('get', clone['workingRef'])
        entry = dict(self.records()[-1], operationId=str(uuid.uuid4()), operationType='lens-fixture',
                     status='pending', workingRef=clone['workingRef'], nativeVariantId=current['id'],
                     beforeGeometry=current['geometry'])
        def append():
            with self.journal.open('a') as stream:
                stream.write(json.dumps(entry)+'\n'); stream.flush(); os.fsync(stream.fileno())
        append()
        self.log('corrected-lens-fixture-pending', operationId=entry['operationId'], nativeVariantId=current['id'])
        script = f'set v to variant id {json.dumps(current["id"])} of current document\n'
        if perspective:
            script += '''set lens profile of lens correction of v to "Phase One 45mm TS f/3.5"
set tilt of lens correction of v to 2
set tilt direction of lens correction of v to 45
set shift of lens correction of v to 3
set shift direction of lens correction of v to 90
set shift x of lens correction of v to 2
set shift y of lens correction of v to -2
set keystone vertical of adjustments of v to 10
set keystone horizontal of adjustments of v to -5
'''
        script += 'set distortion of lens correction of v to 100'
        ae(script)
        observed = self.cli('get', clone['workingRef'])
        assert observed['geometry']['lensGeometry'][0] == 100
        if perspective:
            assert observed['geometry']['lensGeometry'][2:] == [2,45,3,90,2,-2]
            assert observed['geometry']['keystone'][1:3] == [10,-5]
        entry['status'] = 'succeeded'; entry['afterGeometry'] = observed['geometry']; append()
        return observed

    def interrupt(self, command, interruption, matches=lambda record: True):
        """Pause Capture One once the write is journaled, then kill its caller or wait for -1712."""
        known = {r['operationId'] for r in self.records()}
        pid = self.pid()
        watchdog = None
        try:
            self.child = subprocess.Popen(command + ['--format', 'json'],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            pending = wait_for(lambda: next((r for r in self.records()
                if r['operationId'] not in known and r['status'] == 'pending' and matches(r)), None), 90)
            # Watchdog is independent of this controller. Never leave the GUI suspended.
            watchdog = subprocess.Popen([sys.executable, '-c',
                'import os,signal,sys,time; time.sleep(150); os.kill(int(sys.argv[1]),signal.SIGCONT)', str(pid)])
            os.kill(pid, signal.SIGSTOP)
            self.paused = pid
            self.log('target-paused-after-pending', pid=pid, pending=pending, interruption=interruption,
                     limitation='External pause races handler execution; does not identify the particular Apple Event in flight.')
            if interruption == KILL:
                self.child.kill()
                out, err = self.child.communicate(timeout=5)
                self.log('caller-killed', code=self.child.returncode, stdout=out, stderr=err, operationId=pending['operationId'])
                assert self.child.returncode == -signal.SIGKILL, self.child.returncode
                assert not out.strip(), 'The caller already replied; this was not an interrupted write'
                latest = [r for r in self.records() if r['operationId'] == pending['operationId']][-1]
                assert latest['status'] == 'pending', ('A killed caller must leave its write pending', latest)
                return pending, None
            out, err = self.child.communicate(timeout=145)
            result = json.loads(out.strip() or err.strip())
            self.log('apple-event-timeout-reply', code=self.child.returncode, response=result)
            assert self.child.returncode != 0
            assert result['error']['code'] == 'timeout', result
            assert '-1712' in result['error']['message'], result
            assert result['error']['operationId'] == pending['operationId']
            return pending, result
        finally:
            if self.paused:
                os.kill(pid, signal.SIGCONT)
                self.paused = None
            if watchdog:
                watchdog.terminate()
                watchdog.wait(timeout=5)
            if self.child and self.child.poll() is None:
                self.child.kill()
                self.child.wait()

    def fault(self, fault):
        clone, current = self.clone()
        if fault.prepare:
            current = fault.prepare(self, clone)
        pending, _ = self.interrupt([str(self.c1), *fault.command(self, clone, current)], fault.interruption)
        self.log('target-resumed', case=fault.label)
        self.recovery(pending['operationId'], clone, fault.label, fault.resolution, fault.check, fault.resume)

    def preview_timeout(self):
        clone, _ = self.clone()
        result = self.cli('preview', clone['workingRef'], '--timeout', '0.001', ok=False)
        assert result['error']['code'] == 'timeout', result
        operation = result['error']['operationId']
        folder = Path(self.latest(operation)['previewOutputPath'])
        file = wait_for(lambda: next(folder.glob('*.jpg'), None), 60)
        wait_for(lambda: file.read_bytes().endswith(b'\xff\xd9'), 60)
        self.log('output-observed-after-timeout', path=str(file), bytes=file.stat().st_size, sha256=sha(file))
        self.recovery(operation, clone, 'preview-timeout-with-eventual-output', RESTART)

    def save_stall(self):
        """Capture One stops saving (#43). A database file backdated after Capture One saved
        stands in for the stall; nothing writes until the stall bound has passed."""
        clone, current = self.clone()
        creation = [r for r in self.records() if r['operationType'] == 'clone'][-1]
        assert creation['status'] == 'succeeded', creation
        written = self.cli('set', clone['workingRef'], '--if-state', current['stateHash'], 'exposure=0.25')
        operation = written['operationId']
        def dispatched(record):
            return datetime.datetime.fromisoformat(record['timestamp'].replace('Z', '+00:00')).timestamp()
        # Capture One saves about once a minute; the stand-in starts after that save.
        wait_for(lambda: self.db.stat().st_mtime > dispatched(self.latest(operation)), 180)
        doctor = self.cli('doctor')
        assert 'saveStall' not in doctor and doctor['writesEnabled'] and doctor['allChecksPassed'], doctor
        before = self.identities()
        # Earlier cases' writes stay saved: the journal records dispatch to the second, so the
        # stand-in falls inside the second before the clone. An earlier time would also move
        # the creation time, which is part of the database identity.
        stand_in = dispatched(creation) - .5
        born = self.db.stat().st_birthtime
        assert born < stand_in, 'The fixture database is too new for a stand-in'
        assert not [r for r in self.records() if r['operationId'] not in (creation['operationId'], operation)
                    and dispatched(r) > stand_in], 'Another write shares the stand-in second'
        os.utime(self.db, (stand_in, stand_in))
        assert self.db.stat().st_birthtime == born, 'Backdating changed the database identity'
        self.log('database-backdated', modified=stand_in, creationOperationId=creation['operationId'], operationId=operation)
        time.sleep(max(0, dispatched(creation) + 300 + 5 - time.time()))
        assert self.db.stat().st_mtime == stand_in, 'Capture One wrote the database during the stand-in; the case does not qualify'
        doctor = self.cli('doctor', ok=False)
        stall = doctor.get('saveStall') or {}
        assert doctor['writesDisabledReason'] == 'save-stalled' and not doctor['allChecksPassed'], doctor
        assert stall.get('operationIds') == [creation['operationId'], operation] and stall['oldestAgeSeconds'] >= 300, doctor
        for record in (self.latest(creation['operationId']), self.latest(operation)):
            assert record['status'] == 'outcome-unknown' and record['saveStalledAt'], record
        assert self.identities() == before
        self.recovery(creation['operationId'], clone, 'save-stall', RESTART, also=[operation])

    def blocked_by(self, operation):
        count = len(self.records())
        blocked = self.cli('variant', 'clone', self.source, ok=False)
        assert blocked['error']['code'] == 'outcome-unknown' and blocked['error']['operationId'] == operation, blocked
        assert len(self.records()) == count, 'Blocked operation must not dispatch or append'

    def resolve_late_preview(self, operation, pid):
        """Waits for the late JPEG, then requires status to resolve it in the same process."""
        entry = self.latest(operation)
        assert entry['status'] == 'outcome-unknown' and entry['operationType'] == 'preview', entry
        self.blocked_by(operation)
        folder = Path(entry['previewOutputPath'])
        file = wait_for(lambda: next(folder.glob('*.jpg'), None), 60)
        wait_for(lambda: file.read_bytes().endswith(b'\xff\xd9'), 60)
        self.log('output-observed-after-timeout', path=str(file), bytes=file.stat().st_size, sha256=sha(file))
        count = len(self.records())
        resolved = self.cli('operation', 'status', operation)
        assert resolved['status'] == 'succeeded' and resolved['resolution'] == 'late-preview', resolved
        assert Path(resolved['previewOutputPath']).resolve() == file.resolve(), resolved
        assert len(self.records()) == count + 1, 'Resolution appends exactly one snapshot'
        assert self.cli('operation', 'status', operation) == resolved and len(self.records()) == count + 1
        assert self.pid() == pid, 'Late preview resolution must not restart Capture One'
        doctor = self.cli('doctor')
        assert doctor['unresolvedOperationsCount'] == 0 and doctor['writesEnabled'] and doctor['allChecksPassed'], doctor
        return resolved

    def resume_after_late_preview(self, ref, clone, before):
        """No restart happened, so the faulted reference still takes a fresh write."""
        fresh = self.cli('get', ref)
        self.cli('set', ref, '--if-state', fresh['stateHash'], 'exposure=0.125')
        self.cli('variant', 'delete', clone['workingRef'])
        assert self.identities() == [i for i in before if i[0] != clone['cloneVariantId']]
        original_now = self.cli('get', self.source)
        assert original_now['stateHash'] == self.original['stateHash']
        assert original_now.get('geometry') == self.original.get('geometry')
        assert sha(self.raw) == self.raw_hash

    def late_preview(self):
        clone, current = self.clone()
        before = self.identities()
        pid = self.pid()
        # The poll times out long before the export lands; no Apple Event is paused.
        result = self.cli('preview', clone['workingRef'], '--timeout', '0.001', ok=False)
        assert result['error']['code'] == 'timeout' and '-1712' not in result['error']['message'], result
        operation = result['error']['operationId']
        entry = self.latest(operation)
        assert (entry['preconditionStateHash'], entry['preconditionGeometryStateHash']) == (current['stateHash'], current['geometryStateHash']), entry
        resolved = self.resolve_late_preview(operation, pid)
        self.resume_after_late_preview(clone['workingRef'], clone, before)
        self.log('case-passed', case='preview-late-output-resolved-without-restart', operationId=operation,
                 observations=resolved, pid=pid, rawSHA256=sha(self.raw))

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
        self.recovery(pending['operationId'], clone, 'mcp-death-after-export-dispatch', RESTART)

    def lookup_identities(self, ids):
        # Drives the packaged known-ID lookup handler directly; recovery reaches it
        # only after a restart, and absence must be reported, never raised.
        script = self.evidence / 'lookup-identities.applescript'
        script.write_text(self.handlers.read_text() + LOOKUP_DRIVER)
        document = ae('return id of first document')
        result = subprocess.run(['osascript', str(script), document, *ids],
                                capture_output=True, text=True, timeout=60)
        self.log('known-id-lookup', ids=ids, code=result.returncode, stdout=result.stdout, stderr=result.stderr)
        assert result.returncode == 0, result.stderr
        rows = [line.split('\t') for line in result.stdout.rstrip('\n').split('\n')]
        return [dict(variantId=row[0], isPresent=row[1] == 'true', parentImagePath=row[2]) for row in rows]

    def select_cases(self, cases):
        return selected_cases(cases)

    def run(self, cases=RECOVERY_CASES):
        cases = self.select_cases(cases)
        self.log('selected-cases', selected=cases, skipped=[case for case in self.CASES if case not in cases])
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
        self.handlers = next(package.rglob('Handlers.applescript'))
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
                 handlersSHA256=sha(self.handlers),
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
        self.original_native = adjustments_snapshot(self, self.source)
        self.run_cases(cases)
        assert sha(fixture) == self.raw_hash
        self.log('all-cases-passed' if cases == list(self.CASES) else 'selected-cases-passed',
                 cases=len([case for case in cases if case != 'clone-readback']), selected=cases,
                 rawSHA256=sha(self.raw),
                 shutdownMode=self.shutdown_mode, shutdownKind=SHUTDOWN_MODES[self.shutdown_mode])

    def clone_readback(self):
        # Repeated clone stress is useful only when its readback path changes.
        for _ in range(10):
            clone, _ = self.clone()
            self.cli('variant', 'delete', clone['workingRef'])
        assert len(self.cli('variants', 'list')) == 1
        # A deleted clone's native ID is a real, now-absent identity.
        deleted = clone['cloneVariantId']
        assert deleted != self.source
        rows = self.lookup_identities([deleted, self.source])
        assert rows == [dict(variantId=deleted, isPresent=False, parentImagePath=''),
                        dict(variantId=self.source, isPresent=True, parentImagePath=str(self.raw))], rows
        self.log('clone-readback-regression-passed', cycles=10, absentLookup=rows)

    STRUCTURAL = {'clone-readback': 'clone_readback', 'preview': 'preview_timeout', 'late-preview': 'late_preview',
                  'save-stall': 'save_stall', 'mcp-death': 'mcp_death'}

    def run_cases(self, cases):
        for case in selected_cases(cases):
            if case in self.STRUCTURAL:
                getattr(self, self.STRUCTURAL[case])()
            else:
                for fault in FAULTS[case]:
                    self.fault(fault)

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


def run_group(runner, evidence, cases):
    run = runner(evidence)
    try:
        run.run(cases)
    except BaseException as error:
        run.log('failed', error=repr(error))
        raise
    finally:
        run.finish()


def main(argv=None):
    args = parse_args(argv)
    barrier, generic, compound = args.cases
    selected = [*barrier, *generic, *(RECIPE_PREFIX + case for case in compound)]
    print('Selected recovery cases: ' + ', '.join(selected), flush=True)
    print('Skipped recovery cases: ' + (', '.join(case for case in ALL_CASES if case not in selected) or 'none'), flush=True)
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    # Each group owns a fresh Session; a failed group stops the campaign. The barrier
    # case runs first because the barrier-resolved faults rely on what it qualifies.
    if barrier:
        from barrier_integration_test import BarrierRun
        run_group(BarrierRun, evidence / 'barrier', barrier)
    if generic:
        run_group(lambda path: Run(args.archive, path), evidence / 'recovery', generic)
    if compound:
        from recipe_recovery_integration_test import RecipeRun
        run_group(lambda path: RecipeRun(args.archive, path), evidence / 'recipe-recovery', compound)
    print('PASS: selected recovery cases: ' + ', '.join(selected), flush=True)


if __name__ == '__main__':
    # The compound harness imports this module by name; share one copy.
    sys.modules.setdefault('recovery_integration_test', sys.modules[__name__])
    main()
