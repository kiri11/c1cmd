#!/usr/bin/env python3
"""Apply verified recipes to many photos from a JSON plan, one edit_apply per photo.

The plan is a JSON list. Each entry names one photo and its per-photo policies:

  {"sourceRef": "123", "recipeId": "<recipe SHA-256>",
   "exposure": {"mode": "relative", "value": 0.3},
   "whiteBalance": {"mode": "preserve"}, "overrides": {"clarity amount": 7},
   "geometry": {"aspectRatio": 1.5}, "preview": true, "previewSize": 800}

Only sourceRef and recipeId are required. For every entry the runner reads a fresh
`doc info` and `get --live`, then runs one `c1 recipe apply` with those tokens.

The log next to the plan (plan.log.jsonl) is append-only. A `started` record is
written durably before each apply and the result record after it. A rerun skips
entries logged `succeeded`. Any other last record blocks the whole plan: the
runner never retries or resumes a compound. After you have inspected and, where
needed, recovered that photo (restart and reconcile for uncertain outcomes),
pass --release INDEX to allow one new attempt.

The runner stops between photos when the stop file (plan.stop) exists or on
SIGINT/SIGTERM; the current photo always finishes. It stops at the first result
that is not `succeeded` and prints what to inspect. --dry-run checks the plan,
the log, the recipes' verification evidence and every pending sourceRef without
writing anything.

Exit status: 0 plan complete, 1 invalid plan or failed checks (nothing written),
2 stopped on request, 3 stopped on a result that needs attention.
"""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

ENTRY_KEYS = {'sourceRef', 'recipeId', 'exposure', 'whiteBalance', 'overrides', 'geometry', 'preview', 'previewSize'}
PREVIEW_SIZES = {400, 800, 1200, 1500}
UNCERTAIN_CODES = {'outcome-unknown', 'timeout', 'partial-failure', 'readback-mismatch'}
EXIT_DONE, EXIT_INVALID, EXIT_STOPPED, EXIT_ATTENTION = 0, 1, 2, 3


class PlanError(Exception):
    """The plan, the log or a preflight check rejects the run before any write."""


class C1Error(Exception):
    def __init__(self, words, code, payload):
        error = payload.get('error', {}) if isinstance(payload, dict) else {}
        super().__init__(f"c1 {' '.join(words)} failed ({error.get('code', f'exit {code}')}): {error.get('message', payload)}")


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def is_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def entry_problems(entry):
    """Shape checks that c1 would otherwise report only when it reaches this entry."""
    if not isinstance(entry, dict):
        return ['must be an object']
    problems = [f'unknown field {key!r}' for key in sorted(entry.keys() - ENTRY_KEYS)]
    if not isinstance(entry.get('sourceRef'), str) or not entry['sourceRef'].strip():
        problems.append('sourceRef must be a nonempty string')
    recipe = entry.get('recipeId')
    if not isinstance(recipe, str) or len(recipe) != 64 or any(c not in '0123456789abcdef' for c in recipe):
        problems.append('recipeId must be a lowercase SHA-256 recipe ID')
    for key in ['overrides', 'geometry']:
        if key in entry and not isinstance(entry[key], dict):
            problems.append(f'{key} must be an object')
    exposure = entry.get('exposure')
    if exposure is not None:
        mode = exposure.get('mode') if isinstance(exposure, dict) else None
        if mode not in ('preserve', 'absolute', 'relative') or set(exposure) - {'mode', 'value'}:
            problems.append('exposure needs mode preserve, absolute or relative')
        elif (mode == 'preserve') != ('value' not in exposure) or ('value' in exposure and not is_number(exposure['value'])):
            problems.append('exposure preserve omits value; absolute and relative need a numeric value')
    balance = entry.get('whiteBalance')
    if balance is not None:
        mode = balance.get('mode') if isinstance(balance, dict) else None
        if mode == 'preserve' and set(balance) == {'mode'}:
            pass
        elif mode != 'absolute' or set(balance) != {'mode', 'temperature', 'tint'} or not all(is_number(balance[k]) for k in ['temperature', 'tint']):
            problems.append('whiteBalance is {"mode":"preserve"} or absolute with numeric temperature and tint')
    if 'preview' in entry and not isinstance(entry['preview'], bool):
        problems.append('preview must be true or false')
    if 'previewSize' in entry and (entry.get('preview') is not True or entry['previewSize'] not in PREVIEW_SIZES):
        problems.append(f'previewSize needs preview: true and one of {sorted(PREVIEW_SIZES)}')
    return problems


def load_plan(path):
    try:
        plan = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise PlanError(f'Cannot read plan {path}: {error}')
    if not isinstance(plan, list) or not plan:
        raise PlanError('The plan must be a nonempty JSON list of entries.')
    problems = [f'entry {i}: {p}' for i, entry in enumerate(plan) for p in entry_problems(entry)]
    refs = [entry['sourceRef'] for entry in plan if isinstance(entry, dict) and isinstance(entry.get('sourceRef'), str)]
    problems += [f'sourceRef {ref!r} appears more than once' for ref in sorted({r for r in refs if refs.count(r) > 1})]
    if problems:
        raise PlanError('Invalid plan:\n  ' + '\n  '.join(problems))
    return plan


def load_log(path, plan):
    """The last record per entry index; a damaged or mismatched log fails closed."""
    last = {}
    if not path.exists():
        return last
    for number, line in enumerate(path.read_text().splitlines(), 1):
        try:
            record = json.loads(line)
            index, ref, status = record['index'], record['sourceRef'], record['status']
        except (ValueError, KeyError, TypeError):
            raise PlanError(f'{path} line {number} is not a log record. Keep the file as evidence and inspect it; the runner will not guess.')
        if not isinstance(index, int) or not 0 <= index < len(plan) or plan[index]['sourceRef'] != ref:
            raise PlanError(f'{path} line {number} records sourceRef {ref!r} at entry {index}, which the plan no longer has there. '
                            'Do not reorder or remove entries of a plan with a log; start a new plan file for new work.')
        last[index] = record
    return last


def state(record):
    if record is None or record['status'] == 'released':
        return 'pending'
    return 'done' if record['status'] == 'succeeded' else 'blocked'


class Log:
    def __init__(self, path, document_path):
        self.path, self.document_path = path, document_path

    def append(self, record):
        record = {'time': now(), 'documentPath': self.document_path, **record}
        created = not self.path.exists()
        with self.path.open('a') as f:
            f.write(json.dumps(record, sort_keys=True) + '\n')
            f.flush()
            os.fsync(f.fileno())
        if created:
            fd = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)


class C1:
    def __init__(self, binary):
        self.binary = binary

    def call(self, *words):
        # A new session keeps the terminal's Ctrl-C away from c1, which would otherwise
        # cancel the compound at its next boundary; the runner stops between photos instead.
        result = subprocess.run([self.binary, *words, '--format', 'json'], capture_output=True, text=True,
                                stdin=subprocess.DEVNULL, start_new_session=True)
        def parse(text):
            try:
                return json.loads(text) if text.strip() else None
            except ValueError:
                return None
        return result.returncode, parse(result.stdout), parse(result.stderr)

    def read(self, *words):
        code, out, err = self.call(*words)
        if code:
            raise C1Error(words, code, err if err is not None else out)
        return out

    def doctor(self):
        code, out, err = self.call('doctor')
        if not isinstance(out, dict):
            raise C1Error(('doctor',), code, err)
        return out


def doctor_problems(report):
    return [f'doctor reports {key} false' + (f" ({report['writesDisabledReason']})" if key == 'writesEnabled' and report.get('writesDisabledReason') else '')
            for key in ['allChecksPassed', 'writesEnabled', 'exactBuildMatched'] if report.get(key) is not True]


def recipe_problems(doc, recipe_ids):
    """Reads the documented verification evidence (recipes.md, Verify before reuse)."""
    problems = []
    for recipe in sorted(recipe_ids):
        path = Path(doc['documentPath']) / '.c1' / 'verified-recipes' / f'{recipe}.json'
        try:
            evidence = json.loads(path.read_text())
        except (OSError, ValueError):
            evidence = {}
        if evidence.get('recipeId') != recipe or evidence.get('status') != 'verified' or evidence.get('build') != doc.get('appVersion'):
            problems.append(f'recipe {recipe} has no verification evidence for build {doc.get("appVersion")}; '
                            'verify it on a disposable managed clone first (AGENT_GUIDE invariant 8)')
    return problems


def document_problems(doc, last):
    paths = {r['documentPath'] for r in last.values() if r.get('documentPath')}
    return [f'the log was written for {p}, but the open document is {doc["documentPath"]}' for p in sorted(paths - {doc['documentPath']})]


def build_request(entry, doc, source):
    request = {key: entry[key] for key in ENTRY_KEYS - {'sourceRef', 'recipeId'} if key in entry}
    request.update(recipeId=entry['recipeId'], sourceRef=entry['sourceRef'], ifDocument=doc['openToken'],
                   ifState=source['stateHash'], ifGeometryState=source['geometryStateHash'])
    return request


def outcome(code, out, err):
    """One log record from one `c1 recipe apply` call."""
    if code == 0 and isinstance(out, dict) and out.get('status') == 'succeeded':
        return {key: out.get(key) for key in ['status', 'compoundId', 'workingRef', 'previewPath', 'evidencePath']}
    if isinstance(out, dict) and 'status' in out:
        status = out['status'] if out['status'] in ('failed', 'outcome-unknown', 'interrupted') else 'outcome-unknown'
        error = out.get('error') or {}
        operations = [op.get('operationId') for op in out.get('childOperations') or []]
        return {'status': status, 'compoundId': out.get('compoundId'), 'workingRef': out.get('workingRef'),
                'activeStep': out.get('activeStep'), 'unattempted': out.get('unattempted'), 'error': error,
                'operationIds': sorted({i for i in operations + [error.get('operationId')] if i})}
    error = (err or {}).get('error') or {}
    uncertain = code == 4 or not error or error.get('code') in UNCERTAIN_CODES or 'compoundId' in error or 'operationId' in error
    return {'status': 'outcome-unknown' if uncertain else 'failed', 'compoundId': error.get('compoundId'), 'error': error or {'exitCode': code},
            'operationIds': [error['operationId']] if error.get('operationId') else []}


def guidance(index, record):
    """What the photographer or agent does next; the runner itself never retries."""
    lines = [f'Entry {index} ({record["sourceRef"]}) is {record["status"]}.']
    compound = record.get('compoundId')
    if record.get('error'):
        lines.append(f'  Error: {json.dumps(record["error"], sort_keys=True)}')
    if compound:
        lines.append(f"  Inspect the compound: echo '{{\"compoundId\":\"{compound}\"}}' > status.json && c1 recipe status --file status.json")
    for operation in record.get('operationIds') or []:
        lines.append(f'  Inspect the child operation: c1 operation status {operation}')
    if record['status'] == 'failed' and compound:
        lines.append('  Completed steps stay applied. Review a fresh preview and restore explicitly if needed (AGENT_GUIDE workflow step 6).')
    elif record['status'] == 'failed':
        lines.append('  c1 rejected the request without starting a compound. Fix the cause before releasing the entry.')
    else:
        lines += ['  The outcome is uncertain and c1 blocks writes (AGENT_GUIDE invariant 4). Do not repeat the command.',
                  '  Restart Capture One, reopen the same document, check the operation and compound status again,',
                  '  and prepare fresh references; old ones stay invalid.']
        if record['status'] == 'started':
            lines.append('  The runner stopped before recording a result; its started record holds the request. Run `c1 doctor` first.')
    lines.append(f'  Only after that, rerun with --release {index} to allow one new attempt at this entry.')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('plan', type=Path)
    parser.add_argument('--c1-bin', default='c1')
    parser.add_argument('--log', type=Path, help='Append-only per-photo log (default: PLAN.log.jsonl).')
    parser.add_argument('--stop-file', type=Path, help='Stop between photos while this file exists (default: PLAN.stop).')
    parser.add_argument('--dry-run', action='store_true', help='Check the plan, recipes and sourceRefs; write nothing.')
    parser.add_argument('--release', type=int, action='append', default=[], metavar='INDEX',
                        help='Allow one new attempt at a blocked entry after you have inspected and recovered it.')
    args = parser.parse_args()
    log_path = args.log or args.plan.with_suffix('.log.jsonl')
    stop_file = args.stop_file or args.plan.with_suffix('.stop')
    c1 = C1(args.c1_bin)

    stop = []
    def request_stop(number, _frame):
        if not stop:
            print(f'\n{signal.Signals(number).name}: stopping after the current photo.', file=sys.stderr, flush=True)
        stop.append(number)
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    try:
        plan = load_plan(args.plan)
        last = load_log(log_path, plan)
        if args.dry_run and args.release:
            raise PlanError('--release writes to the log; it cannot be combined with --dry-run.')
        for index in args.release:
            if index not in last or state(last[index]) != 'blocked':
                raise PlanError(f'--release {index}: only an entry whose last result needs attention can be released.')
            last[index] = {**last[index], 'status': 'released'}
        blocked = [i for i in range(len(plan)) if state(last.get(i)) == 'blocked']
        if blocked:
            print('\n'.join(guidance(i, last[i]) for i in blocked), file=sys.stderr)
            return EXIT_ATTENTION
        problems = []
        doctor = c1.doctor()
        problems += doctor_problems(doctor)
        doc = c1.read('doc', 'info')
        problems += document_problems(doc, last)
        pending = [i for i in range(len(plan)) if state(last.get(i)) == 'pending']
        problems += recipe_problems(doc, {plan[i]['recipeId'] for i in pending})
        if args.dry_run:
            for i in pending:
                try:
                    c1.read('get', plan[i]['sourceRef'], '--live')
                except C1Error as error:
                    problems.append(f'entry {i}: {error}')
            for i, entry in enumerate(plan):
                print(f"{i:>5}  {state(last.get(i)):<8} {entry['sourceRef']}")
            if stop_file.exists():
                print(f'Note: the stop file {stop_file} exists; a run would stop before the first photo.')
        if problems:
            raise PlanError('Preflight checks failed:\n  ' + '\n  '.join(problems))
    except (PlanError, C1Error) as error:
        print(error, file=sys.stderr)
        return EXIT_INVALID
    if args.dry_run:
        print(f'Dry run passed: {len(pending)} pending of {len(plan)} entries. Nothing was written.')
        return EXIT_DONE

    log = Log(log_path, doc['documentPath'])
    for index in args.release:
        log.append({'index': index, 'sourceRef': plan[index]['sourceRef'], 'status': 'released'})

    applied = 0
    for index, entry in enumerate(plan):
        if state(last.get(index)) == 'done':
            continue
        if stop or stop_file.exists():
            print(f'Stopped before entry {index} on request; {applied} applied this run. Rerun to continue.')
            return EXIT_STOPPED
        ref = entry['sourceRef']
        try:
            current = c1.read('doc', 'info')
            if current['openToken'] != doc['openToken']:
                raise PlanError('The open document changed since the run started; nothing more was applied.')
            source = c1.read('get', ref, '--live')
        except (PlanError, C1Error) as error:
            print(f'Entry {index} ({ref}): {error}\nNo write was dispatched for this entry.', file=sys.stderr)
            return EXIT_ATTENTION
        request = build_request(entry, current, source)
        log.append({'index': index, 'sourceRef': ref, 'status': 'started', 'request': request})
        with tempfile.TemporaryDirectory(prefix='c1-apply-plan-') as folder:
            request_file = Path(folder) / 'request.json'
            request_file.write_text(json.dumps(request))
            result = outcome(*c1.call('recipe', 'apply', '--file', str(request_file)))
        record = {'index': index, 'sourceRef': ref, 'recipeId': entry['recipeId'], **result}
        log.append(record)
        if record['status'] != 'succeeded':
            print(guidance(index, record), file=sys.stderr)
            return EXIT_ATTENTION
        applied += 1
        print(f"{index:>5}  succeeded  {ref}  {record['workingRef']}  {record.get('previewPath') or '-'}", flush=True)
    print(f'Plan complete: {applied} applied this run, {len(plan)} entries succeeded. Log: {log_path}')
    return EXIT_DONE


if __name__ == '__main__':
    sys.exit(main())
