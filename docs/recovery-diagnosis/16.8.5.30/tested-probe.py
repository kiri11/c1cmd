#!/usr/bin/env python3
"""Focused, opt-in Session restart probe; does not inject timeouts or retry writes.

Requires C1_TEST_RAW_FIXTURE, exact Capture One build, zero open documents and
exclusive use. All database inspection is read-only. Retains its new Session.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

APP = '/Applications/Capture One.app'
ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def ae(body, timeout=20):
    result = subprocess.run(['osascript', '-s', 's', '-e',
                             f'tell application "{APP}"\n{body}\nend tell'],
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    value = result.stdout.strip()
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def literal(value):
    return json.dumps(str(value))


def app_pid():
    pids = subprocess.check_output(['pgrep', '-x', 'Capture One'], text=True).split()
    assert len(pids) == 1, pids
    pid = int(pids[0])
    assert subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip() == APP + '/Contents/MacOS/Capture One'
    return pid


def wait_for(predicate, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.1)
    raise TimeoutError('Diagnostic deadline; inspect evidence before continuing')


def database_snapshot(db, sidecar):
    # Private schema is diagnostic evidence on the exact build, never write authority.
    with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True) as connection:
        connection.row_factory = sqlite3.Row
        tables = {
            'images': 'SELECT Z_PK,ZIMAGEUUID,ZIMAGELOCATION,ZIMAGEFILENAME FROM ZIMAGE',
            'paths': 'SELECT Z_PK,ZMACROOT,ZRELATIVEPATH,ZISRELATIVE FROM ZPATHLOCATION',
            'variants': 'SELECT v.Z_PK,v.ZIMAGE,v.ZINDEX,v.ZVARIANTUUID,l.ZEXPOSURE,l.ZROTATION FROM ZVARIANT v LEFT JOIN ZVARIANTLAYER l ON v.ZDEFAULTLAYER=l.Z_PK',
        }
        result = {key: [dict(row) for row in connection.execute(query)] for key, query in tables.items()}
        result['quickCheck'] = connection.execute('PRAGMA quick_check').fetchone()[0]
    result['sidecarSHA256'] = sha(sidecar) if sidecar.exists() else None
    result['sidecarUUIDs'] = [v.find("E[@K='UUID']").get('V') for v in ET.parse(sidecar).getroot().findall('VAR')] if sidecar.exists() else []
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--cycles', type=int, default=2, choices=range(1, 5))
    parser.add_argument('--quit-command', choices=['quit', 'silently quit', 'sigterm'], default='quit')
    parser.add_argument('--preview-cycle', type=int, default=-1,
                        help='Create a fresh marked clone and preview it before this zero-based restart cycle')
    parser.add_argument('--delete-cycle', type=int, default=-1,
                        help='Create, edit and delete a temporary managed clone before this cycle')
    args = parser.parse_args()
    if any(cycle < -1 or cycle >= args.cycles for cycle in [args.preview_cycle, args.delete_cycle]):
        parser.error('Exercise cycles must identify a requested cycle or be -1')
    raw = Path(os.environ['C1_TEST_RAW_FIXTURE']).resolve()
    assert raw.is_file()
    original_sha = sha(raw)
    cli_path = Path(os.environ.get('C1_TEST_BIN', ROOT / '.build/release/c1')).resolve()
    assert ae('return count of documents') == 0, 'Close documents before exclusive diagnostics'
    assert ae('return version') == '16.8.5.30'
    args.parent.mkdir(parents=True, exist_ok=True)
    # Preserve the supplied spelling to compare /tmp with /private/tmp.
    work = Path(tempfile.mkdtemp(prefix='c1-restart-probe-', dir=args.parent)).absolute()
    session = work / 'diagnostic'
    db = session / 'diagnostic.cosessiondb'
    args.evidence.mkdir(parents=True, exist_ok=False)
    shutil.copy2(__file__, args.evidence / 'probe.py')
    events = args.evidence / 'events.jsonl'

    def log(event, **fields):
        data = {'event': event, 'time': time.time(), **fields}
        with events.open('a') as stream:
            stream.write(json.dumps(data) + '\n')
        print(event, flush=True)

    def cli(*argv):
        result = subprocess.run([str(cli_path), *argv, '--format', 'json', '--quiet'], capture_output=True, text=True, timeout=150)
        value = json.loads(result.stdout.strip() or result.stderr.strip())
        if result.returncode:
            log('cli-failed', args=argv, response=value)
            raise RuntimeError(value)
        return value

    def inventory():
        variants = cli('variants', 'list')
        return [{'id': row['id'], 'path': row['parentImagePath'],
                 'state': cli('get', row['id'])['adjustments']} for row in variants]

    owns = False
    try:
        ae(f'make new document with properties {{name:"diagnostic", kind:session, path:{literal(work)}}}')
        owns = True
        copied = session / 'Capture' / ('fixture' + raw.suffix)
        copied.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(raw, copied)
        sidecar = copied.parent / 'CaptureOne/Settings1680' / (copied.name + '.cos')
        ae('set current collection of first document to collection "Capture" of first document')
        health = cli('doctor')
        assert health['allChecksPassed'] and health['writesEnabled'] and health['exactBuildMatched']
        rows = wait_for(lambda: cli('variants', 'list'))
        assert len(rows) == 1
        clone = cli('variant', 'clone', rows[0]['id'])
        state = cli('get', clone['workingRef'])
        cli('set', clone['workingRef'], '--if-state', state['stateHash'], 'exposure=0.375')
        log('environment', session=str(session), cliSHA256=sha(cli_path), rawSHA256=original_sha,
            appVersion=health['appVersion'], quitCommand=args.quit_command,
            previewCycle=args.preview_cycle, deleteCycle=args.delete_cycle, probeSHA256=sha(__file__))
        for cycle in range(args.cycles):
            if cycle == args.delete_cycle:
                source = cli('variants', 'list')[0]['id']
                temporary = cli('variant', 'clone', source)
                current = cli('get', temporary['workingRef'])
                cli('set', temporary['workingRef'], '--if-state', current['stateHash'], 'exposure=0.125')
                cli('variant', 'delete', temporary['workingRef'])
                log('temporary-clone-deleted', cycle=cycle, nativeVariantId=temporary['cloneVariantId'])
            if cycle == args.preview_cycle:
                source = cli('variants', 'list')[0]['id']
                fresh = cli('variant', 'clone', source)
                current = cli('get', fresh['workingRef'])
                cli('set', fresh['workingRef'], '--if-state', current['stateHash'], 'exposure=0.625')
                rendered = cli('preview', fresh['workingRef'])
                log('preview-completed', cycle=cycle, nativeVariantId=fresh['cloneVariantId'],
                    operationId=rendered['operationId'])
            before = inventory()
            assert Path(ae('return id of first document')).resolve() == session.resolve()
            old = app_pid()
            ae('close first document')
            assert ae('return count of documents') == 0
            closed = database_snapshot(db, sidecar)
            (args.evidence / f'cycle-{cycle}-closed.json').write_text(json.dumps(closed, indent=2) + '\n')
            log('closed', cycle=cycle, before=before, images=len(closed['images']), paths=len(closed['paths']), variants=len(closed['variants']))
            started = time.monotonic()
            try:
                if args.quit_command == 'sigterm':
                    assert app_pid() == old
                    os.kill(old, signal.SIGTERM)
                else:
                    ae(args.quit_command, timeout=12)
                wait_for(lambda: subprocess.run(['kill', '-0', str(old)], capture_output=True).returncode != 0, 15)
            except subprocess.TimeoutExpired:
                subprocess.run(['sample', str(old), '3', '-file', str(args.evidence / 'quit-sample.txt')],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                log('quit-stalled', cycle=cycle, pid=old, elapsedSeconds=time.monotonic() - started)
                raise
            log('quit-completed', cycle=cycle, elapsedSeconds=time.monotonic() - started)
            terminated = database_snapshot(db, sidecar)
            (args.evidence / f'cycle-{cycle}-terminated.json').write_text(json.dumps(terminated, indent=2) + '\n')
            subprocess.run(['open', '-a', APP, str(db)], check=True)

            def ready():
                try:
                    return Path(ae('return id of first document', timeout=5)).resolve() == session.resolve()
                except (RuntimeError, subprocess.TimeoutExpired):
                    return False

            wait_for(ready, 40)
            assert app_pid() != old
            after = inventory()
            log('reopened', cycle=cycle, after=after, idsPreserved=[r['id'] for r in before] == [r['id'] for r in after],
                adjustmentsPreserved=[r['state'] for r in before] == [r['state'] for r in after])
        assert sha(raw) == original_sha == sha(copied)
        log('probe-completed', cycles=args.cycles, rawUnchanged=True)
    except BaseException as error:
        log('failed', error=repr(error))
        raise
    finally:
        # Do not send another event into a stalled quit. The log retains its PID.
        last = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
        if owns and not any(row['event'] == 'quit-stalled' for row in last):
            if Path(ae('return id of first document')).resolve() == session.resolve():
                ae('close first document')
                log('cleanup', openDocuments=ae('return count of documents'), retainedSession=str(session))


if __name__ == '__main__':
    main()
