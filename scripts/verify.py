#!/usr/bin/env python3
"""Run the actual CLI. --exercise briefly changes PBP and restores its layout."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import uuid
from cua_session import CuaSession

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--exercise', action='store_true')
parser.add_argument('--gui', action='store_true', help='Drive the real menu controls through background Cua Driver')
parser.add_argument('--offline', action='store_true', help='Check the real CLI and optional bundle without opening USB')
parser.add_argument('--binary', type=Path, default=root / '.build/debug/msi-screen', help='CLI executable to verify')
parser.add_argument('--app', type=Path, help='Packaged app to validate in offline mode')
args = parser.parse_args()
if args.offline and (args.gui or args.exercise):
    parser.error('--offline cannot be combined with --gui or --exercise')
if args.app and not args.offline:
    parser.error('--app requires --offline')
binary = args.binary.resolve()
output = root / '.local' / ('verify-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:6])
output.mkdir(parents=True)


def run(*command, success=True):
    proc = subprocess.run([str(binary), *command], capture_output=True, text=True, timeout=40)
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError:
        result = {'stdout': proc.stdout, 'stderr': proc.stderr}
    event = {'action': list(command), 'exitCode': proc.returncode, 'result': result}
    with (output / 'actions.jsonl').open('a') as f:
        f.write(json.dumps(event) + '\n')
    print(json.dumps(event), flush=True)
    if success and proc.returncode != 0:
        raise RuntimeError(result)
    if not success and proc.returncode == 0:
        raise RuntimeError('Invalid command was accepted')
    return result


def displays(label):
    proc = subprocess.run(['system_profiler', 'SPDisplaysDataType', '-json'], capture_output=True, text=True, timeout=8)
    proc.check_returncode()
    data = json.loads(proc.stdout)
    observed = [{'name': display.get('_name'), 'resolution': display.get('_spdisplays_resolution')}
                for gpu in data.get('SPDisplaysDataType', []) for display in gpu.get('spdisplays_ndrvs', [])]
    with (output / 'actions.jsonl').open('a') as f:
        f.write(json.dumps({'action': ['observe-displays', label], 'displays': observed}) + '\n')
    return observed


def offline():
    """Exercise executable boundaries, including the CLI embedded in release ZIPs."""
    summary = {'offline': True, 'passed': False, 'binary': str(binary)}
    try:
        help_result = run('--help')
        assert 'msi-screen fullscreen' in help_result['stdout'], 'CLI help is missing'
        capability = run('capabilities')
        assert capability['schemaVersion'] == 1
        assert capability['model'] == 'MD342CQP' and capability['protocolVersion'] == 'V20'
        assert set(capability['inputs']) == {'hdmi1', 'hdmi2', 'dp', 'usbc'}
        assert 'fullscreen INPUT' in capability['commands'] and capability['dryRun'] is True
        # These malformed requests must be rejected before opening the USB
        # controller, so CI never needs (or writes to) an attached monitor.
        for command, expected in [
            (('fullscreen', 'invalid'), 'Invalid command'),
            (('fullscreen',), 'Invalid command'),
            (('status', '--dry-run'), '--dry-run is for setting changes'),
            (('pbp', 'on', '--left'), 'Expected --left/--right'),
            (('pbp', 'on', '--left', 'dp', '--left', 'usbc'), 'Unknown or repeated option'),
            (('pbp', 'off', '--right', 'usbc'), 'Use --left/--right with pbp on'),
            (('input', 'dp', '--unknown'), 'Invalid command'),
        ]:
            failure = run(*command, success=False)
            assert failure['verified'] is False and expected in failure['error']
            assert failure.get('before') is None, 'Invalid input reached the monitor'
        if args.app:
            app = args.app.resolve()
            with (app / 'Contents/Info.plist').open('rb') as f:
                info = plistlib.load(f)
            assert info['CFBundleShortVersionString'] == (root / 'VERSION').read_text().strip()
            assert info['LSUIElement'] is True
            assert 'msi-screen' in info['CFBundleURLTypes'][0]['CFBundleURLSchemes']
            assert binary == app / 'Contents/MacOS/msi-screen', 'Smoke must run the packaged CLI'
            assert (app / 'Contents/Resources/LICENSE').read_text() == (root / 'LICENSE').read_text(), 'Packaged license is missing or stale'
            for executable in [binary, app / 'Contents/MacOS' / info['CFBundleExecutable']]:
                assert executable.is_file() and os.access(executable, os.X_OK)
                # The release must not depend on Homebrew or a developer checkout.
                dependencies = subprocess.check_output(['/usr/bin/otool', '-L', str(executable)], text=True)
                for line in dependencies.splitlines()[1:]:
                    library = line.strip().split(' (', 1)[0]
                    assert library.startswith(('/System/Library/', '/usr/lib/', '@rpath/libswift')), library
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
            summary['app'] = str(app)
        summary['passed'] = True
    except Exception as error:
        summary['error'] = str(error)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'summary': summary, 'evidence': str(output)}, indent=2), flush=True)
    return 0 if summary['passed'] else 1


if args.offline:
    sys.exit(offline())


summary = {'exercise': args.exercise, 'passed': False}
baseline = None
exercise_started = False
owned_state = None
cua = None
gui_pid = None
gui_owned = False
gui_window = None
owner = None


def owns_gui_process():
    if gui_pid is None or owner is None:
        return False
    process = subprocess.run(['ps', '-p', str(gui_pid), '-o', 'args='], capture_output=True, text=True)
    return owner in process.stdout.split()


def gui_snapshot(label, screenshot=False):
    extra = {'screenshot_out_file': str(output / (label + '.png'))} if screenshot else {'include_screenshot': False}
    result = cua.call('get_window_state', pid=gui_pid, window_id=gui_window, **extra)
    (output / (label + '.json')).write_text(json.dumps(result, indent=2))
    return result


def gui_click(label=None, role=None, occurrence=0):
    state = gui_snapshot('before-' + (label or role), screenshot=True)
    matches = [e for e in state['elements']
               if (label is None or e.get('label') == label) and (role is None or e.get('role') == role)]
    if len(matches) <= occurrence:
        raise RuntimeError(f'GUI control unavailable: {label or role}')
    result = cua.call('click', pid=gui_pid, window_id=gui_window,
                      element_token=matches[occurrence]['element_token'], delivery_mode='background')
    with (output / 'actions.jsonl').open('a') as f:
        f.write(json.dumps({'action': ['gui-click', label or role, occurrence], 'result': result}) + '\n')
    print(json.dumps({'action': ['gui-click', label or role, occurrence], 'result': result}), flush=True)
    if result.get('effect') == 'refused':
        raise RuntimeError(result)


def gui_ready(label):
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        state = gui_snapshot(label)
        tree = state.get('tree_markdown', '')
        if 'Read back from monitor' in tree:
            return gui_snapshot(label, screenshot=True)
        if 'Refresh before trying again' in tree:
            raise RuntimeError(tree)
        time.sleep(0.25)
    raise RuntimeError('GUI did not finish reading back monitor state')


def gui_input(index, value):
    gui_click(role='AXPopUpButton', occurrence=index)
    gui_click({'dp': 'DisplayPort', 'usbc': 'USB-C', 'hdmi1': 'HDMI 1', 'hdmi2': 'HDMI 2'}[value], 'AXMenuItem')


def gui_apply(label):
    gui_click('Apply layout')
    # Capture the busy controls as well as the settled result.
    gui_snapshot(label + '-busy', screenshot=True)
    gui_ready(label)
    return run('status')


try:
    baseline = run('status')  # Health-check the real USB controller before actions.
    summary['baseline'] = baseline
    summary['displaysBefore'] = displays('before')
    lock_path = Path.home() / 'Library/Caches/msi-screen-control/controller.lock'
    with lock_path.open('r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        busy = run('status', success=False)
        assert 'Another msi-screen process' in busy.get('error', '')
    assert run('status') == baseline, 'Lock test changed monitor state'
    # A valid full-screen baseline may store identical primary/secondary inputs.
    # Use the known DP + USB-C pair for the exercise, then restore that baseline.
    left = baseline['source1'] if baseline['source1'] != baseline['source2'] else ('dp' if baseline['source2'] != 'dp' else 'usbc')
    right = baseline['source2']
    plan = run('pbp', 'on', '--left', left, '--right', right, '--dry-run')
    assert plan['dryRun'] and not plan['verified']
    assert run('status') == baseline, 'Dry-run changed the monitor'
    run('pbp', 'on', '--left', baseline['source1'], '--right', baseline['source1'], success=False)
    run('pbp', 'on', '--left', 'invalid', success=False)
    full_plan = run('fullscreen', baseline['source1'], '--dry-run')
    assert full_plan['dryRun'] and not full_plan['verified']
    assert run('status') == baseline
    assert 'fullscreen INPUT' in run('capabilities')['commands']
    if args.gui:
        cua = CuaSession()
        owner = 'msi-verification-' + uuid.uuid4().hex
        launched = cua.call('launch_app', bundle_id='com.danielsivan.msi-screen.menu',
                            creates_new_application_instance=True,
                            additional_arguments=['--show-controls', '--verification-owner', owner,
                                                  '--supervisor', str(os.getpid())])
        gui_pid = launched['pid']
        # list_apps omits some accessory apps. Prove our unique launch argument
        # instead of inferring ownership from absence in an app inventory.
        gui_owned = owns_gui_process()
        if not gui_owned:
            raise RuntimeError('Launch reused an existing app; refusing to drive or quit it')
        windows = launched.get('windows', [])
        if not windows:
            windows = cua.call('list_windows', pid=gui_pid)['windows']
        gui_window = next(w['window_id'] for w in windows if w.get('title') == 'MSI Screen')
        gui_ready('gui-health')
        assert run('status') == baseline, 'Opening the app changed the monitor'
        gui_click('Refresh monitor')
        gui_ready('gui-refresh')
    if args.exercise:
        if baseline['mode'] == 'pip' or baseline['pipInput'] != baseline['source2']:
            raise RuntimeError('Exercise requires no active PIP and matching saved PIP/PBP secondary inputs so it can restore the exact baseline')
        exercise_started = True
        owned_state = baseline
        if args.gui:
            gui_click('Side by side')
            gui_input(0, left)
            gui_input(1, right)
            on_state = gui_apply('gui-pbp')
            assert on_state['mode'] == 'pbp' and on_state['source1'] == left and on_state['source2'] == right
        else:
            on = run('pbp', 'on', '--left', left, '--right', right)
            assert on['verified'] and on['after']['mode'] == 'pbp'
            on_state = on['after']
        owned_state = on_state
        # A separate process must observe the same applied state.
        assert run('status') == on_state
        summary['displaysPBP'] = displays('pbp-on')
        repeated = run('pbp', 'on', '--left', left, '--right', right)
        assert repeated['verified'] and repeated['changes'] == []
        if args.gui:
            gui_click('Swap sides')
            swapped_state = gui_apply('gui-swapped')
            assert swapped_state['source1'] == right and swapped_state['source2'] == left
            owned_state = swapped_state
        else:
            swapped = run('pbp', 'on', '--left', right, '--right', left)
            assert swapped['verified']
            assert run('status') == swapped['after']
            owned_state = swapped['after']
        restored = run('pbp', 'on', '--left', left, '--right', right)
        assert restored['verified']
        owned_state = restored['after']
        if baseline['mode'] == 'off':
            if args.gui:
                gui_click('Refresh monitor')
                gui_ready('gui-before-fullscreen')
                gui_click('Full screen')
                gui_input(0, baseline['source1'])
                assert gui_apply('gui-fullscreen') == baseline
                owned_state = baseline
            else:
                owned_state = run('fullscreen', baseline['source1'])['after']
    summary['passed'] = True
except Exception as error:
    summary['error'] = str(error)
finally:
    if baseline is not None:
        try:
            final = run('status')
            # Only the explicit exercise owns a layout change to clean up.
            if exercise_started and final != baseline and baseline['mode'] != 'pip':
                if final != owned_state:
                    raise RuntimeError('Monitor changed outside the verified exercise; refusing to overwrite that change during cleanup')
                if baseline['mode'] == 'pbp' or final['source1'] != baseline['source1'] or final['source2'] != baseline['source2']:
                    run('pbp', 'on', '--left', left, '--right', right)
                if baseline['mode'] == 'off':
                    run('fullscreen', baseline['source1'])
                final = run('status')
            summary['final'] = final
            summary['displaysAfter'] = displays('after')
            summary['restored'] = final == baseline
            if final != baseline:
                summary['passed'] = False
                summary['restoreError'] = 'Final monitor state differs from baseline'
        except Exception as error:
            summary['passed'] = False
            summary['restoreError'] = str(error)
    if cua:
        try:
            if gui_owned and owns_gui_process():
                try:
                    gui_click('Quit')
                except Exception:
                    # AXPress can lose its target as Quit exits. Prove the
                    # resulting process exit rather than accepting the receipt.
                    if owns_gui_process():
                        raise
                deadline = time.monotonic() + 3
                while owns_gui_process() and time.monotonic() < deadline:
                    time.sleep(0.1)
                if owns_gui_process():
                    raise RuntimeError('Owned GUI process did not quit')
                summary['guiProcessExited'] = True
        except Exception as error:
            summary['guiCleanupError'] = str(error)
            summary['passed'] = False
        finally:
            try:
                cua.close()
            except Exception as error:
                summary['guiSessionCleanupError'] = str(error)
                summary['passed'] = False
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'summary': summary, 'evidence': str(output)}, indent=2), flush=True)
sys.exit(0 if summary['passed'] else 1)
