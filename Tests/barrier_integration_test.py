#!/usr/bin/env python3
"""Probe-barrier qualification with raw Apple Events (macOS only; no c1, no restart).

Question (issue #51): once a later Apple Event gets an answer, has an earlier write
whose sender timed out (-1712) finished? Queued mode pauses Capture One (SIGSTOP,
with an independent resume watchdog), sends the write with a 3-second instrument
timeout so it is queued, sends a probe from another process, resumes, and reads the
target as soon as the probe answers and then for a watch window. Running mode does
not pause: the writer times out while Capture One executes an AI operation. The
export control must break the barrier, which shows the method can detect a failure.

Each write statement mirrors the one the production handler sends. Mask feather and
refine are excluded: no scriptable property changes when they run, so they stay
restart-only.

Run through recovery_integration_test.py with --cases barrier. Requires
C1_TEST_RAW_FIXTURE, C1_TEST_PEOPLE_FIXTURE and Capture One 16.8.5.30 with zero
documents. C1_BARRIER_TRIALS sets the queued trials per kind (default 3).
"""
from dataclasses import dataclass
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from typing import Callable, Optional
import uuid

import recovery_integration_test as harness

APP = '/Applications/Capture One.app'
QUEUED, RUNNING, CONTROL = 'queued', 'running', 'control'
WRITER_TIMEOUT = {QUEUED: 3, CONTROL: 3, RUNNING: 2}
RUNNING_TRIALS = 2


def wrapped(body, seconds):
    return f'tell application "{APP}"\nwith timeout of {seconds} seconds\n{body}\nend timeout\nend tell'


def osa(body, seconds=60):
    start = time.monotonic()
    p = subprocess.run(['osascript', '-s', 's', '-e', wrapped(body, seconds)],
                       capture_output=True, text=True, timeout=seconds + 60)
    return dict(code=p.returncode, out=p.stdout.strip(), err=p.stderr.strip(),
                elapsed=round(time.monotonic() - start, 3))


def ok(body, seconds=60):
    result = osa(body, seconds)
    assert result['code'] == 0, (body, result)
    return result['out']


def text(value):
    return json.loads(value) if value.startswith('"') else value


def as_list(value):
    # osascript -s s renders a list of plain strings as {"a", "b"}.
    return json.loads('[' + value[1:-1] + ']')


@dataclass(frozen=True)
class Kind:
    """One write kind: AppleScript built from a trial (t.v variant, t.i index, t.target from setup)."""
    base: str
    write: Callable
    read: Optional[Callable]
    setup: Optional[Callable] = None
    watch: float = 5


def layer_named(kind):
    return lambda t: (f'make new layer at {t.v} with properties {{name:"barrier-{t.i}", kind:{kind}}}\n'
                      f'return count of layers of {t.v}')


def layer_kind(t):
    return f'return kind of layer {t.target} of {t.v}'


def layer_count(t):
    return f'return count of layers of {t.v}'


def color_count(t):
    return f'return count of advanced color corrections of color editor settings of adjustments of {t.v}'


def siblings(t):
    return f'return count of variants of parent image of {t.v}'


def dehaze_color(t):
    return f'return dehaze color of adjustments of {t.v}'


def odd_dehaze(t):
    return f'set dehaze color of adjustments of {t.v} to {{100, 200, 300}}'


KINDS = {
    'tonal': Kind('raw', lambda t: f'set exposure of adjustments of {t.v} to {0.1 + 0.05 * t.i}',
                  lambda t: f'return exposure of adjustments of {t.v}'),
    'rating': Kind('raw', lambda t: f'set rating of {t.v} to {t.i % 5 + 1}', lambda t: f'return rating of {t.v}'),
    'color-tag': Kind('raw', lambda t: f'set color tag of {t.v} to {t.i % 7 + 1}', lambda t: f'return color tag of {t.v}'),
    'clarity': Kind('raw', lambda t: f'set clarity amount of adjustments of {t.v} to {10 + t.i}',
                    lambda t: f'return clarity amount of adjustments of {t.v}'),
    'rotation': Kind('raw', lambda t: f'set rotation of adjustments of {t.v} to {1 + 0.25 * t.i}',
                     lambda t: f'return rotation of adjustments of {t.v}'),
    'crop': Kind('raw', lambda t: f'set crop of {t.v} to {{3000, 2000, {4000 - 200 * t.i}, {3000 - 150 * t.i}}}',
                 lambda t: f'return crop of {t.v}'),
    'distortion': Kind('raw', lambda t: f'set distortion of lens correction of {t.v} to {37 + t.i}',
                       lambda t: f'return distortion of lens correction of {t.v}'),
    'keystone': Kind('raw', lambda t: f'set keystone vertical of adjustments of {t.v} to {5 + t.i}',
                     lambda t: f'return keystone vertical of adjustments of {t.v}'),
    'layer.create': Kind('raw', lambda t: f'make new layer at {t.v} with properties {{name:"barrier-{t.i}", kind:filled}}',
                         layer_count),
    'layer.delete': Kind('raw', lambda t: f'delete layer {t.target} of {t.v}', layer_count, layer_named('adjustment')),
    'color.create': Kind('raw', lambda t: f'make new advanced color correction at color editor settings of adjustments of {t.v}',
                         color_count),
    'color.delete': Kind('raw', lambda t: f'delete advanced color correction 1 of color editor settings of adjustments of {t.v}',
                         color_count,
                         lambda t: f'make new advanced color correction at color editor settings of adjustments of {t.v}'),
    'dehaze.pick': Kind('raw', lambda t: f'pick dehaze adjustments of {t.v} at {{{1000 + 500 * t.i}, {1000 + 300 * t.i}}}',
                        dehaze_color, odd_dehaze),
    'dehaze.recalculate': Kind('raw', lambda t: f'recalculate dehaze adjustments of {t.v}', dehaze_color, odd_dehaze),
    'lens.reset': Kind('raw', lambda t: f'reset lens correction of {t.v}',
                       lambda t: f'return distortion of lens correction of {t.v}',
                       lambda t: f'set distortion of lens correction of {t.v} to {50 + t.i}'),
    'luma.clear': Kind('raw', lambda t: f'clear luma range layer {t.target} of {t.v}',
                       lambda t: f'return {{range low, range high}} of luma range of layer {t.target} of {t.v}',
                       lambda t: (f'make new layer at {t.v} with properties {{name:"barrier-luma-{t.i}", kind:adjustment}}\n'
                                  f'set n to count of layers of {t.v}\n'
                                  f'set range low of luma range of layer n of {t.v} to {20 + t.i}\n'
                                  f'set range high of luma range of layer n of {t.v} to 80\nreturn n')),
    'style.apply': Kind('raw', lambda t: f'apply style layer {t.target} of {t.v} named {json.dumps(t.style)}',
                        lambda t: f'return exposure of adjustments of layer {t.target} of {t.v}', layer_named('adjustment')),
    'mask.clear': Kind('raw', lambda t: f'clear mask layer {t.target} of {t.v}', layer_kind, layer_named('filled')),
    'mask.fill': Kind('raw', lambda t: f'fill mask layer {t.target} of {t.v}', layer_kind, layer_named('adjustment')),
    'mask.invert': Kind('raw', lambda t: f'invert mask layer {t.target} of {t.v}', layer_kind, layer_named('filled')),
    'mask.copy': Kind('raw', lambda t: f'copy mask layer ({t.target} - 1) of {t.v} to layer (layer {t.target} of {t.v})',
                      layer_kind,
                      lambda t: (f'make new layer at {t.v} with properties {{name:"barrier-source-{t.i}", kind:filled}}\n'
                                 + layer_named('adjustment')(t))),
    'mask.rasterize': Kind('people', lambda t: f'rasterize mask layer {t.target} of {t.v}', layer_kind,
                           layer_named('subject mask')),
    'baseline': Kind('raw', lambda t: f'tell parent image of {t.v} to add variant', siblings),
    'clone': Kind('raw', lambda t: f'clone variant ({t.v})', siblings),
    'variant.delete': Kind('raw', lambda t: f'delete variant id "{t.target}" of first document',
                           lambda t: f'return exists variant id "{t.target}" of first document',
                           lambda t: f'set k to clone variant ({t.v})\nreturn id of k as text'),
    'mask.subject': Kind('people', lambda t: f'make new layer at {t.v} with properties {{name:"subject-{t.i}", kind:subject mask}}',
                         layer_count, watch=15),
    'mask.people': Kind('people', lambda t: f'create people mask {t.v} areas {{face skin, body skin}} separate layers false',
                        layer_count, watch=15),
    # Export runs in Capture One's background queue: the barrier must not cover it.
    'process': Kind('raw', lambda t: f'process {t.v} recipe {json.dumps(t.recipe)}', None,
                    lambda t: f'set output sub folder of recipe {json.dumps(t.recipe)} of first document to "t{t.i}"', watch=15),
}
RUNNING_KINDS = ('mask.subject', 'mask.people')
UNQUALIFIABLE = {'mask.feather': 'no scriptable property changes', 'mask.refine': 'no scriptable property changes'}


def verdict(mode, records):
    """Counts per kind, and the failures that disqualify it."""
    summary = dict(trials=len(records), timedOut=0, probeAnswered=0, landed=0, informative=0, held=0, broken=0)
    for r in records:
        summary['timedOut'] += r['timedOut']
        summary['probeAnswered'] += r['probe']['code'] == 0
        summary['landed'] += r['landed']
        summary['informative'] += r['informative']
        summary['held'] += r['informative'] and r['barrierHeld']
        summary['broken'] += r['informative'] and not r['barrierHeld']
    failures = []
    if summary['probeAnswered'] != len(records):
        failures.append('probe did not answer')
    if mode in (QUEUED, CONTROL) and summary['timedOut'] != len(records):
        failures.append('writer did not time out while queued')
    if mode == QUEUED and summary['held'] != len(records):
        failures.append('write did not land before the probe answered')
    if mode == RUNNING and any(r['timedOut'] and not r['barrierHeld'] for r in records):
        failures.append('probe answered before an executing write finished')
    if mode == CONTROL and not summary['broken']:
        failures.append('control never broke the barrier; the method cannot detect a failure')
    return summary, failures


class BarrierRun:
    def __init__(self, evidence):
        self.fixture_parent = harness.fixture_parent()
        self.fixture_parent.mkdir(parents=True, exist_ok=True)
        self.raw_source = Path(os.environ['C1_TEST_RAW_FIXTURE']).resolve()
        self.people_source = Path(os.environ['C1_TEST_PEOPLE_FIXTURE']).resolve()
        self.trials = int(os.environ.get('C1_BARRIER_TRIALS', '3'))
        assert self.trials >= 1, 'C1_BARRIER_TRIALS must be at least 1'
        self.evidence = evidence.resolve()
        self.evidence.mkdir(parents=True, exist_ok=False)
        self.events = self.evidence / 'events.jsonl'
        shutil.copy2(__file__, self.evidence / 'barrier-harness.py')
        self.work = Path(tempfile.mkdtemp(prefix='c1-barrier-', dir=self.fixture_parent))
        self.session = self.work / 'barrier'
        self.recipe = 'c1-barrier-' + uuid.uuid4().hex[:12]
        self.recipe_created = False
        self.owns_session = False
        self.paused = None
        self.style = None
        self.summary = {}

    def log(self, event, **data):
        with self.events.open('a') as stream:
            stream.write(json.dumps(dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                         event=event, **data)) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        print(event, flush=True)

    def pid(self):
        pids = subprocess.check_output(['pgrep', '-x', 'Capture One'], text=True).split()
        assert len(pids) == 1, pids
        command = subprocess.check_output(['ps', '-p', pids[0], '-o', 'comm='], text=True).strip()
        assert command == APP + '/Contents/MacOS/Capture One', command
        return int(pids[0])

    def owned_document_open(self):
        return (ok('return count of documents') == '1' and
                Path(text(ok('return id of first document'))).resolve() == self.session.resolve())

    def setup(self):
        assert ok('return count of documents') == '0', 'Close documents before this exclusive qualification'
        assert text(ok('return version')) == '16.8.5.30'
        self.log('environment', appVersion='16.8.5.30', pid=self.pid(), session=str(self.session),
                 trials=self.trials, harnessSHA256=harness.sha(__file__),
                 rawSHA256=harness.sha(self.raw_source), peopleSHA256=harness.sha(self.people_source),
                 macOS=subprocess.check_output(['sw_vers'], text=True), architecture=os.uname().machine,
                 commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=harness.ROOT, text=True).strip(),
                 unqualifiable=UNQUALIFIABLE)
        ok(f'make new document with properties {{name:"barrier", kind:session, path:{json.dumps(str(self.work))}}}')
        self.owns_session = True
        assert self.owned_document_open()
        capture = self.session / 'Capture'
        capture.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.raw_source, capture / ('fixture' + self.raw_source.suffix))
        shutil.copy2(self.people_source, capture / ('people' + self.people_source.suffix))
        ok('set current collection of first document to collection "Capture" of first document')
        harness.wait_for(lambda: ok('return count of variants of first document') == '2', 60)
        rows = as_list(ok('set out to {}\nrepeat with v in variants of first document\n'
                          'set end of out to (id of v as text) & ":" & (name of parent image of v)\nend repeat\nreturn out'))
        self.base = {('people' if name.startswith('people') else 'raw'): vid
                     for vid, name in (row.split(':', 1) for row in rows)}
        assert set(self.base) == {'raw', 'people'}, rows
        self.log('setup', base=self.base)

    def create_recipe(self):
        out = self.work / 'out'
        out.mkdir()
        ok(f'set r to make new recipe at first document with properties {{name:{json.dumps(self.recipe)}}}\n'
           'set output format of r to JPEG\nset scaling method of r to Long_Edge\nset scaling unit of r to pixels\n'
           'set primary scaling value of r to 800\n'
           f'set root folder location of r to POSIX file {json.dumps(str(out))}\nset root folder type of r to custom location\n'
           'set enabled of r to false')
        self.recipe_created = True
        self.log('recipe-created', name=self.recipe, root=str(out))

    def delete_recipe(self):
        # Delete only this case's uniquely named recipe, and only while it is rooted in this fixture.
        root = text(ok(f'return POSIX path of (root folder location of recipe {json.dumps(self.recipe)} of first document as alias)'))
        assert Path(root).resolve().is_relative_to(self.work.resolve()), root
        ok(f'delete recipe {json.dumps(self.recipe)} of first document')
        self.recipe_created = False
        self.log('recipe-deleted', name=self.recipe, root=root)

    def select_style(self):
        # The style must change the observable: a fresh adjustment layer's exposure.
        styles = as_list(ok('return available styles'))
        candidates = sorted(styles, key=lambda name: not name.startswith('Exposure compensation'))
        t = SimpleNamespace(v=self.variant('raw'), i=0)
        for style in candidates[:10]:
            t.target = ok(layer_named('adjustment')(t))
            before = ok(KINDS['style.apply'].read(t))
            ok(KINDS['style.apply'].write(SimpleNamespace(**vars(t), style=style)))
            after = ok(KINDS['style.apply'].read(t))
            self.log('style-candidate', style=style, before=before, after=after)
            if after != before:
                return style
        raise AssertionError('No available style changed a fresh layer exposure')

    def variant(self, base):
        vid = text(ok(f'set c to clone variant (variant id "{self.base[base]}" of first document)\nreturn id of c as text'))
        return f'variant id "{vid}" of first document'

    def observe(self, kind, t):
        if kind.read is None:
            folder = self.work / 'out' / f't{t.i}'
            return str(len(list(folder.glob('*.jpg'))) if folder.exists() else 0)
        result = osa(kind.read(t))
        return result['out'] if result['code'] == 0 else 'ERROR ' + result['err']

    def trial(self, name, kind, t, mode):
        if kind.setup:
            t.target = text(ok(kind.setup(t), 180))
        record = dict(kind=name, mode=mode, trial=t.i, variant=t.v, target=t.target)
        record['before'] = self.observe(kind, t)
        body = kind.write(t)
        record['write'] = body
        pid = self.pid()
        # Watchdog is independent of this controller. Never leave the GUI suspended.
        watchdog = subprocess.Popen([sys.executable, '-c',
            'import os,signal,sys,time; time.sleep(60); os.kill(int(sys.argv[1]),signal.SIGCONT)', str(pid)])
        probe = None
        try:
            start = time.monotonic()
            if mode != RUNNING:
                os.kill(pid, signal.SIGSTOP)
                self.paused = pid
            record['writer'] = osa(body, WRITER_TIMEOUT[mode])
            probe = subprocess.Popen(['osascript', '-s', 's', '-e', wrapped('return count of documents', 120)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            record['probeSentAt'] = round(time.monotonic() - start, 3)
            if mode != RUNNING:
                # Let the probe reach the paused application's queue behind the write.
                time.sleep(.5)
        finally:
            if self.paused:
                os.kill(pid, signal.SIGCONT)
                self.paused = None
                record['resumedAt'] = round(time.monotonic() - start, 3)
            watchdog.terminate()
            watchdog.wait(timeout=5)
        out, err = probe.communicate(timeout=180)
        record['probe'] = dict(code=probe.returncode, out=out.strip(), err=err.strip(),
                               repliedAt=round(time.monotonic() - start, 3))
        record['afterProbe'] = self.observe(kind, t)
        record['afterProbeAt'] = round(time.monotonic() - start, 3)
        changes, last, end = [], record['afterProbe'], time.monotonic() + kind.watch
        while time.monotonic() < end:
            value = self.observe(kind, t)
            if value != last:
                changes.append(dict(at=round(time.monotonic() - start, 3), value=value))
                last = value
            time.sleep(.2)
        record.update(laterChanges=changes, final=last, pid=pid)
        record['timedOut'] = record['writer']['code'] != 0 and '-1712' in record['writer']['err']
        record['landed'] = record['final'] != record['before']
        record['barrierHeld'] = record['afterProbe'] == record['final']
        record['informative'] = record['timedOut'] and record['landed']
        assert self.pid() == pid, 'Capture One changed during a barrier trial'
        self.log('trial', **record)
        return record

    def qualify(self, name, mode, trials):
        kind = KINDS[name]
        if name == 'process' and not self.recipe_created:
            self.create_recipe()
        if name == 'style.apply' and not self.style:
            self.style = self.select_style()
            self.log('style-selected', style=self.style)
        v = self.variant(kind.base)
        self.log('target', kind=name, mode=mode, variant=v)
        records = [self.trial(name, kind, SimpleNamespace(v=v, i=i, target=None, style=self.style, recipe=self.recipe), mode)
                   for i in range(trials)]
        summary, failures = verdict(mode, records)
        self.summary[f'{mode}:{name}'] = summary
        self.log('kind-verdict', kind=name, mode=mode, summary=summary, failures=failures)
        assert not failures, (name, mode, failures)

    def run(self, cases):
        assert list(cases) == [harness.BARRIER_CASE], cases
        self.setup()
        for name in KINDS:
            if name != 'process':
                self.qualify(name, QUEUED, self.trials)
        for name in RUNNING_KINDS:
            self.qualify(name, RUNNING, RUNNING_TRIALS)
        self.qualify('process', CONTROL, self.trials)
        self.log('barrier-qualified', kinds=sorted(self.summary), unqualifiable=UNQUALIFIABLE)

    def finish(self):
        if self.paused:
            os.kill(self.paused, signal.SIGCONT)
            self.paused = None
        (self.evidence / 'summary.json').write_text(json.dumps(
            dict(kinds=self.summary, unqualifiable=UNQUALIFIABLE), indent=2) + '\n')
        if not self.owns_session:
            return
        # Keep the Session as evidence; close only this case's own document.
        try:
            if self.owned_document_open():
                if self.recipe_created:
                    self.delete_recipe()
                ok('close first document', 60)
            self.log('cleanup', openDocuments=ok('return count of documents'), retainedSession=str(self.session))
        except Exception as error:
            self.log('cleanup-failed', error=repr(error))
