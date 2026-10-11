#!/usr/bin/env python3
"""examples/apply-plan.py against a fake c1: resume, stop, uncertain outcomes, validation, dry run."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'examples' / 'apply-plan.py'
RECIPE = 'a' * 64
UNVERIFIED = 'b' * 64

# The fake answers doctor, doc info, get --live and recipe apply from scenario.json and
# records every call. Hooks run inside an apply, as a photographer or signal would.
FAKE_C1 = r'''#!/usr/bin/env python3
import json, os, signal, sys
from pathlib import Path
home = Path(os.environ['FAKE_C1_HOME'])
scenario = json.loads((home / 'scenario.json').read_text())
words = [w for w in sys.argv[1:] if w not in ('--format', 'json')]
call = {'words': words}
def fail(code, exit_code):
    print(json.dumps({'error': {'code': code, 'message': 'fake'}}), file=sys.stderr); finish(exit_code)
def finish(exit_code):
    with (home / 'calls.jsonl').open('a') as f: f.write(json.dumps(call) + '\n')
    sys.exit(exit_code)
doc = {'documentPath': scenario['documentPath'], 'openToken': scenario['openToken'], 'appVersion': '16.8.5.30'}
if words == ['doctor']:
    print(json.dumps({'allChecksPassed': True, 'writesEnabled': True, 'exactBuildMatched': True})); finish(0)
if words == ['doc', 'info']:
    print(json.dumps(doc)); finish(0)
if words[0] == 'get':
    if words[1] not in scenario['refs']: fail('variant-not-found', 1)
    print(json.dumps({'id': words[1], 'stateHash': 'state-' + words[1], 'geometryStateHash': 'geometry-' + words[1]})); finish(0)
if words[:2] == ['recipe', 'apply']:
    request = json.loads(Path(words[3]).read_text()); call['request'] = request
    ref = request['sourceRef']
    hooks = scenario.get('hooks', {}).get(ref, [])
    if 'stop-file' in hooks: Path(scenario['stopFile']).write_text('')
    if 'ctrl-c' in hooks: os.killpg(os.getpgid(os.getppid()), signal.SIGINT)
    if 'sigterm' in hooks: os.kill(os.getppid(), signal.SIGTERM)
    if 'reopen' in hooks:
        scenario['openToken'] = 'reopened'; (home / 'scenario.json').write_text(json.dumps(scenario))
    status = scenario.get('outcomes', {}).get(ref, 'succeeded')
    compound = 'c' * 63 + ref[-1]
    if status == 'succeeded':
        print(json.dumps({'status': 'succeeded', 'compoundId': compound, 'workingRef': 'c1_edit_' + ref,
                          'previewPath': f'/previews/{ref}.jpg', 'evidencePath': f'/evidence/{ref}.json'})); finish(0)
    print(json.dumps({'status': status, 'compoundId': compound, 'workingRef': 'c1_edit_' + ref, 'activeStep': 'settings',
                      'error': {'code': 'outcome-unknown', 'operationId': 'op-' + ref}, 'completed': [], 'plan': []})); finish(1)
fail('invalid-request', 1)
'''


class Fixture:
    def __init__(self, folder, refs, plan, **scenario):
        self.folder = Path(folder)
        self.document = self.folder / 'document'
        evidence = self.document / '.c1' / 'verified-recipes'
        evidence.mkdir(parents=True)
        (evidence / f'{RECIPE}.json').write_text(json.dumps({'recipeId': RECIPE, 'status': 'verified', 'build': '16.8.5.30'}))
        self.home = self.folder / 'fake'
        self.home.mkdir()
        self.c1 = self.home / 'c1'
        self.c1.write_text(FAKE_C1)
        self.c1.chmod(0o755)
        self.plan = self.folder / 'plan.json'
        self.plan.write_text(json.dumps(plan))
        self.log = self.folder / 'plan.log.jsonl'
        self.stop = self.folder / 'plan.stop'
        self.scenario = dict(documentPath=str(self.document), openToken='open-1', refs=refs, stopFile=str(self.stop), **scenario)
        self.save()

    def save(self):
        (self.home / 'scenario.json').write_text(json.dumps(self.scenario))

    def run(self, *options):
        (self.home / 'calls.jsonl').unlink(missing_ok=True)
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.plan), '--c1-bin', str(self.c1), *options],
                                capture_output=True, text=True, timeout=60, env={**os.environ, 'FAKE_C1_HOME': str(self.home)},
                                start_new_session=True)
        return result

    def calls(self):
        path = self.home / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def applied(self):
        return [call['request']['sourceRef'] for call in self.calls() if call['words'][:2] == ['recipe', 'apply']]

    def records(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]


def entries(*refs, **fields):
    return [dict(sourceRef=ref, recipeId=RECIPE, **fields) for ref in refs]


def test_stop_file_then_resume_skips_done():
    with tempfile.TemporaryDirectory() as tmp:
        plan = entries('101', '102', '103', exposure={'mode': 'relative', 'value': 0.25}, preview=True, previewSize=800)
        f = Fixture(tmp, ['101', '102', '103'], plan, hooks={'101': ['stop-file']})
        first = f.run()
        assert first.returncode == 2, first
        assert f.applied() == ['101'], 'a stop file created during a photo ends the run after that photo'
        request = next(c['request'] for c in f.calls() if c['words'][:2] == ['recipe', 'apply'])
        assert request == dict(recipeId=RECIPE, sourceRef='101', ifDocument='open-1', ifState='state-101', ifGeometryState='geometry-101',
                               exposure={'mode': 'relative', 'value': 0.25}, preview=True, previewSize=800), request
        f.stop.unlink()
        second = f.run()
        assert second.returncode == 0, second
        assert f.applied() == ['102', '103'], 'a rerun skips entries the log records as succeeded'
        tokens = [(c['request']['ifDocument'], c['request']['ifState'], c['request']['ifGeometryState']) for c in f.calls() if c['words'][:2] == ['recipe', 'apply']]
        assert tokens == [('open-1', 'state-102', 'geometry-102'), ('open-1', 'state-103', 'geometry-103')], 'each apply carries its own fresh tokens'
        results = [r for r in f.records() if r['status'] != 'started']
        assert [(r['index'], r['sourceRef'], r['status']) for r in results] == [(0, '101', 'succeeded'), (1, '102', 'succeeded'), (2, '103', 'succeeded')]
        assert results[1]['workingRef'] == 'c1_edit_102' and results[1]['previewPath'] == '/previews/102.jpg'
        assert results[1]['evidencePath'] == '/evidence/102.json' and results[1]['compoundId'].startswith('ccc')
        assert [r['status'] for r in f.records()[:2]] == ['started', 'succeeded'], 'a started record precedes each apply'
        third = f.run()
        assert third.returncode == 0 and f.applied() == [], 'a complete plan applies nothing again'
    print('PASS: stop file between photos, resume skips succeeded entries, log records results')


def test_signals_finish_current_photo():
    for hook in ['ctrl-c', 'sigterm']:
        with tempfile.TemporaryDirectory() as tmp:
            f = Fixture(tmp, ['101', '102'], entries('101', '102'), hooks={'101': [hook]})
            result = f.run()
            assert result.returncode == 2, (hook, result)
            assert f.applied() == ['101'], f'{hook} during a photo lets it finish and starts no other'
            assert f.records()[-1]['status'] == 'succeeded', f'{hook} never reaches c1, so the photo completes and logs its result'
    print('PASS: Ctrl-C to the process group and SIGTERM stop after the current photo')


def test_outcome_unknown_stops_and_blocks_reruns():
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp, ['101', '102', '103'], entries('101', '102', '103'), outcomes={'102': 'outcome-unknown'})
        result = f.run()
        assert result.returncode == 3, result
        assert f.applied() == ['101', '102'], 'nothing runs after an uncertain outcome'
        assert not any('103' in call['words'] for call in f.calls()), 'later entries are not even read'
        last = f.records()[-1]
        assert (last['index'], last['status'], last['operationIds']) == (1, 'outcome-unknown', ['op-102']), last
        assert 'c1 operation status op-102' in result.stderr and 'Restart Capture One' in result.stderr, result.stderr
        rerun = f.run()
        assert rerun.returncode == 3 and f.calls() == [], 'a rerun never retries the uncertain entry automatically'
        f.scenario['outcomes'] = {}
        f.save()
        released = f.run('--release', '1')
        assert released.returncode == 0, released
        assert f.applied() == ['102', '103'], 'an explicit release allows one new attempt'
        history = [r['status'] for r in f.records() if r['index'] == 1]
        assert history == ['started', 'outcome-unknown', 'released', 'started', 'succeeded'], 'the log keeps the uncertain result and the release'
    print('PASS: outcome-unknown stops the run, reruns stay blocked until an explicit release')


def test_reopened_document_stops_before_next_write():
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp, ['101', '102'], entries('101', '102'), hooks={'101': ['reopen']})
        result = f.run()
        assert result.returncode == 3 and f.applied() == ['101'], result
    print('PASS: a changed openToken stops the run before the next write')


def test_invalid_plan_writes_nothing():
    with tempfile.TemporaryDirectory() as tmp:
        plan = entries('101') + [dict(sourceRef='102', recipeId='not-a-hash', previewSize=800, exposure={'mode': 'relative'})]
        f = Fixture(tmp, ['101', '102'], plan)
        result = f.run()
        assert result.returncode == 1, result
        for problem in ['entry 1: recipeId', 'entry 1: exposure', 'entry 1: previewSize']:
            assert problem in result.stderr, (problem, result.stderr)
        assert f.calls() == [] and not f.log.exists(), 'an invalid plan contacts nothing and writes no log'
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp, ['101', '102'], entries('101') + [dict(sourceRef='102', recipeId=UNVERIFIED)])
        result = f.run()
        assert result.returncode == 1 and UNVERIFIED in result.stderr, result
        assert f.applied() == [] and not f.log.exists(), 'an unverified recipe stops the run before the first write'
    print('PASS: plan and recipe validation fail before any write')


def test_dry_run_writes_nothing():
    with tempfile.TemporaryDirectory() as tmp:
        f = Fixture(tmp, ['101'], entries('101', '102') + [dict(sourceRef='103', recipeId=UNVERIFIED)])
        result = f.run('--dry-run')
        assert result.returncode == 1, result
        assert 'entry 1: c1 get 102' in result.stderr and UNVERIFIED in result.stderr, result.stderr
        assert f.applied() == [] and not f.log.exists(), 'a dry run never applies or logs'
        f.scenario['refs'] = ['101', '102', '103']
        f.save()
        f.plan.write_text(json.dumps(entries('101', '102', '103')))
        clean = f.run('--dry-run')
        assert clean.returncode == 0, clean
        reads = [call['words'][1] for call in f.calls() if call['words'][0] == 'get']
        assert reads == ['101', '102', '103'] and f.applied() == [] and not f.log.exists(), 'a clean dry run reads every ref, writes nothing'
    print('PASS: dry run checks refs and recipes without writing')


def test_entry_fields_match_contract():
    binary = os.environ.get('C1_TEST_BIN')
    if not binary:
        print('SKIP: C1_TEST_BIN not set; entry fields not compared with the schema')
        return
    spec = importlib.util.spec_from_file_location('apply_plan', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    schema = json.loads(subprocess.run([binary, 'schema', '--format', 'json'], capture_output=True, text=True, check=True).stdout)
    request = schema['requests']['edit_apply']['properties']
    assert module.ENTRY_KEYS == set(request) - {'ifDocument', 'ifState', 'ifGeometryState', 'full'}, sorted(request)
    assert module.PREVIEW_SIZES == set(request['previewSize']['enum']), request['previewSize']
    print('PASS: plan entry fields and preview sizes match the edit_apply schema')


if __name__ == '__main__':
    test_stop_file_then_resume_skips_done()
    test_signals_finish_current_photo()
    test_outcome_unknown_stops_and_blocks_reruns()
    test_reopened_document_stops_before_next_write()
    test_invalid_plan_writes_nothing()
    test_dry_run_writes_nothing()
    test_entry_fields_match_contract()
