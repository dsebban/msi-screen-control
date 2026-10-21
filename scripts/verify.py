#!/usr/bin/env python3
"""Verify real controls. Exercises separately opt in to PBP, local roles/brightness, peer roles, or machine routing."""
import argparse
import copy
import datetime
import fcntl
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import time
import threading
import uuid
from cua_session import CuaSession

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--agent-skill-fixture', type=Path, help='With --gui, use an isolated app copy to install its agent skill into this user\'s ~/.agents/skills, then verify the real installed files; leave the requested skill installed')
parser.add_argument('--login-item', action='store_true', help='With --gui, toggle launch at login in the installed app and restore its baseline; verify macOS registration independently')
parser.add_argument('--update-fixture', type=Path, help='With --gui, use this release app to verify a real signed Sparkle download in isolated app copies')
parser.add_argument('--install-update', action='store_true', help='With --update-fixture, exercise Install and Relaunch; requires explicit permission for Sparkle to activate its installer')
parser.add_argument('--menu-appearance', action='store_true', help='With --gui, verify the popup and unavailable layout without requiring an attached monitor')
parser.add_argument('--permissions', action='store_true', help='Inspect the running app TCC/signing status; --gui launches and validates the permission card without changing grants')
parser.add_argument('--previous-app', type=Path, help='With --offline --app, require the new app to satisfy the previous certificate-signed app identity')
parser.add_argument('--peripherals', action='store_true', help='Read receiver topology and device details; add --gui for Machines and Peripherals screens')
parser.add_argument('--probe-pointer', action='store_true',
                    help='With --peripherals, explicitly observe pointer counts for 1 second locally; --gui also runs the 10-second mouse test when available')
parser.add_argument('--probe-controller', action='store_true',
                    help='With --peripherals, run a bounded native controller test; --gui also drives Test controls for 10 seconds')
parser.add_argument('--exercise-focus', metavar='ID', help='Focus a Linux machine with fullscreen video and USB, then return and restore; add --gui for card actions')
parser.add_argument('--exercise-kvm', metavar='ID', help='Roundtrip USB-C to a saved Linux USB-B machine and back; separate from other exercises')
parser.add_argument('--expect-usb', action='append', default=[], metavar='VID:PID',
                    help='With --exercise-kvm or --exercise-focus, require this USB device to move to Linux and return; repeatable')
parser.add_argument('--exercise', action='store_true')
parser.add_argument('--exercise-arrangement', action='store_true',
                    help='Move this MacBook to the opposite side of MSI and restore; --gui drives the position button')
parser.add_argument('--exercise-controls', action='store_true',
                    help='Change and restore this Mac main display and monitor brightness by one')
parser.add_argument('--exercise-peer-controls', action='store_true',
                    help='With --peer-host, change and restore only the other Mac main display')
parser.add_argument('--exercise-machine', metavar='ID', help='Route one saved machine full screen, left and right, restoring each time')
parser.add_argument('--exercise-machine-editor', metavar='ID',
                    help='With --gui, verify a stale machine editor rejects an external CLI rename, then restore the registry')
parser.add_argument('--peer-host', help='Read the other Mac through its installed SSH display helper')
parser.add_argument('--usb-route', action='store_true', help='With --gui, compare the read-only USB route with CLI kvm status')
parser.add_argument('--sharing', action='store_true', help='With --gui, explicitly check sharing services')
parser.add_argument('--idle-seconds', type=int, metavar='N', help='With --gui, measure the owned app with its panel closed for 10–300 seconds')
parser.add_argument('--gui', action='store_true', help='Drive the real menu controls through background Cua Driver')
parser.add_argument('--offline', action='store_true', help='Check the real CLI and optional bundle without opening USB')
parser.add_argument('--binary', type=Path, default=root / '.build/debug/msi-screen', help='CLI executable to verify')
parser.add_argument('--app', type=Path, help='Packaged app to validate in offline mode')
parser.add_argument('--dmg', type=Path, help='With --offline, mount a signed/notarized universal DMG read-only and verify its app, CLI and install shortcut')
args = parser.parse_args()
if args.install_update and not args.update_fixture:
    parser.error('--install-update requires --update-fixture and explicit foreground approval')
if args.agent_skill_fixture and (not args.gui or any((args.offline, args.login_item, args.menu_appearance,
        args.permissions, args.update_fixture, args.peripherals, args.exercise, args.exercise_controls,
        args.exercise_arrangement, args.exercise_peer_controls, args.exercise_machine, args.exercise_machine_editor,
        args.exercise_kvm, args.exercise_focus, args.peer_host, args.sharing, args.usb_route, args.idle_seconds))):
    parser.error('--agent-skill-fixture requires --gui and is separate from other checks')
if args.login_item and (not args.gui or any((args.offline, args.menu_appearance, args.permissions,
        args.update_fixture, args.peripherals, args.exercise, args.exercise_controls, args.exercise_arrangement,
        args.exercise_peer_controls, args.exercise_machine, args.exercise_machine_editor,
        args.exercise_kvm, args.exercise_focus, args.peer_host, args.sharing, args.usb_route, args.idle_seconds))):
    parser.error('--login-item requires --gui and is separate from other checks')
if args.update_fixture and (not args.gui or any((args.offline, args.menu_appearance, args.permissions,
        args.peripherals, args.exercise, args.exercise_controls, args.exercise_arrangement,
        args.exercise_peer_controls, args.exercise_machine, args.exercise_machine_editor,
        args.exercise_kvm, args.exercise_focus, args.peer_host, args.sharing, args.usb_route, args.idle_seconds))):
    parser.error('--update-fixture requires --gui and is separate from other checks')
if args.menu_appearance and (not args.gui or any((args.offline, args.permissions, args.peripherals,
        args.exercise, args.exercise_controls, args.exercise_arrangement, args.exercise_peer_controls,
        args.exercise_machine, args.exercise_machine_editor, args.exercise_kvm, args.exercise_focus,
        args.peer_host, args.sharing, args.usb_route, args.idle_seconds))):
    parser.error('--menu-appearance requires --gui and is separate from other checks')
if args.previous_app and not (args.offline and (args.app or args.dmg)):
    parser.error('--previous-app requires --offline and --app or --dmg')
if args.dmg and (not args.offline or args.app):
    parser.error('--dmg requires --offline and cannot be combined with --app')
if args.permissions and any((args.offline, args.peripherals, args.exercise, args.exercise_controls,
        args.exercise_arrangement, args.exercise_peer_controls, args.exercise_machine, args.exercise_machine_editor,
        args.exercise_kvm, args.exercise_focus, args.peer_host, args.sharing, args.usb_route, args.idle_seconds)):
    parser.error('--permissions is a separate read-only check; only --gui may be added')
if args.probe_pointer and not args.peripherals:
    parser.error('--probe-pointer requires --peripherals')
if args.probe_controller and not args.peripherals:
    parser.error('--probe-controller requires --peripherals')
if args.expect_usb and not (args.exercise_kvm or args.exercise_focus):
    parser.error('--expect-usb requires --exercise-kvm or --exercise-focus')
if any(re.fullmatch(r'[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}', value) is None for value in args.expect_usb):
    parser.error('--expect-usb requires four hexadecimal vendor and product digits, such as 1234:abcd')
args.expect_usb = list(dict.fromkeys(value.lower() for value in args.expect_usb))
if args.offline and (args.gui or args.exercise or args.exercise_controls or args.exercise_arrangement or args.exercise_peer_controls
                     or args.peer_host or args.sharing or args.exercise_machine or args.exercise_machine_editor or args.exercise_kvm or args.exercise_focus or args.peripherals):
    parser.error('--offline cannot be combined with GUI, hardware exercises, peer, or sharing checks')
if (args.exercise_kvm or args.exercise_focus) and (args.exercise or args.exercise_controls or args.exercise_arrangement or args.exercise_peer_controls
                          or args.exercise_machine or args.exercise_machine_editor or args.sharing
                          or args.usb_route or args.idle_seconds or args.peer_host or args.peripherals
                          or (args.exercise_kvm and args.exercise_focus)):
    parser.error('--exercise-kvm / --exercise-focus is separate from other exercises, peer/sharing checks and idle profiling')
if args.peripherals and (args.exercise or args.exercise_controls or args.exercise_arrangement or args.exercise_peer_controls or args.exercise_machine
                         or args.exercise_machine_editor or args.sharing or args.usb_route or args.idle_seconds or args.peer_host):
    parser.error('--peripherals is a separate read-only check; only --gui and --probe-pointer may be added')
if args.exercise_machine_editor and not args.gui:
    parser.error('--exercise-machine-editor requires --gui')
if args.exercise_machine_editor and (args.exercise or args.exercise_controls or args.exercise_arrangement
                                     or args.exercise_peer_controls or args.exercise_machine):
    parser.error('--exercise-machine-editor cannot be combined with hardware mutation exercises')
if args.exercise_peer_controls and not args.peer_host:
    parser.error('--exercise-peer-controls requires --peer-host')
if args.idle_seconds is not None and (not args.gui or not 10 <= args.idle_seconds <= 300):
    parser.error('--idle-seconds requires --gui and a duration from 10 to 300 seconds')
if args.usb_route and not args.gui:
    parser.error('--usb-route requires --gui')
if args.sharing and not args.gui:
    parser.error('--sharing requires --gui')
if args.peer_host and (len(args.peer_host) > 128 or args.peer_host.startswith('-')
                       or re.fullmatch(r'[A-Za-z0-9._-]+', args.peer_host) is None):
    parser.error('--peer-host must be an SSH host or alias using letters, digits, dots, underscores, or hyphens')
if args.app and not args.offline:
    parser.error('--app requires --offline')
binary = args.binary.resolve()
output = root / '.local' / ('verify-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:6])
output.mkdir(parents=True)


def run(*command, success=True, input=None, env=None, timeout=40):
    started = time.monotonic()
    proc = subprocess.run([str(binary), *command], input=input, capture_output=True, text=True, timeout=timeout,
                          env=None if env is None else {**os.environ, **env})
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError:
        result = {'stdout': proc.stdout, 'stderr': proc.stderr}
    event = {'action': list(command), 'exitCode': proc.returncode, 'result': result,
             'elapsedSeconds': round(time.monotonic() - started, 3)}
    if input is not None:
        event['inputBytes'] = len(input.encode())
        try:
            event['request'] = json.loads(input)
        except json.JSONDecodeError:
            pass
    with (output / 'actions.jsonl').open('a') as f:
        f.write(json.dumps(event) + '\n')
    print(json.dumps(event), flush=True)
    if success and proc.returncode != 0:
        raise RuntimeError(result)
    if success is False and proc.returncode == 0:
        raise RuntimeError('Invalid command was accepted')
    return result


def read_state(*command, timeout=40):
    """Briefly wait out another client's read, never replay a mutation."""
    allowed = command == ('status',) or (len(command) in (2, 4) and command[0] == 'kvm'
              and command[1] in ('status', 'layout')
              and (len(command) == 2 or command[2] == '--machine'))
    if not allowed:
        raise ValueError('Busy-wait is limited to status and kvm status/layout observations')
    deadline = time.monotonic() + 3
    while True:
        try:
            return run(*command, timeout=timeout)
        except RuntimeError as error:
            payload = error.args[0] if error.args else None
            if not isinstance(payload, dict) or payload.get('verified') is not False \
                    or payload.get('error') != 'Another msi-screen process is using the monitor':
                raise
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise
            time.sleep(min(0.1, remaining))


def peer_request(host, request):
    """Use the app's fixed helper command and strict, noninteractive SSH policy."""
    command = [
        '/usr/bin/ssh', '-T', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=8',
        '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2', '-o', 'LogLevel=ERROR',
        '--', host,
        'if [ ! -x "$HOME/.local/share/msi-screen-control/msi-screen" ]; then '
        "printf '%s\\n' MSI_SCREEN_HELPER_MISSING >&2; exit 127; fi; "
        'exec "$HOME/.local/share/msi-screen-control/msi-screen" display-request'
    ]
    proc = subprocess.run(command, input=json.dumps(request), capture_output=True, text=True, timeout=45)
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError:
        result = {'stdout': proc.stdout, 'stderr': proc.stderr}
    event = {'action': ['peer-display-request', host, request['action']], 'request': request,
             'exitCode': proc.returncode, 'result': result}
    with (output / 'actions.jsonl').open('a') as f:
        f.write(json.dumps(event) + '\n')
    print(json.dumps(event), flush=True)
    if proc.returncode != 0:
        raise RuntimeError(result)
    assert isinstance(result.get('computerName'), str) and isinstance(result.get('displays'), list)
    return result


def peer_status(host):
    return peer_request(host, {'schemaVersion': 1, 'action': 'status'})


def displays(label):
    proc = subprocess.run(['system_profiler', 'SPDisplaysDataType', '-json'], capture_output=True, text=True, timeout=8)
    proc.check_returncode()
    data = json.loads(proc.stdout)
    observed = [{'name': display.get('_name'), 'resolution': display.get('_spdisplays_resolution')}
                for gpu in data.get('SPDisplaysDataType', []) for display in gpu.get('spdisplays_ndrvs', [])]
    with (output / 'actions.jsonl').open('a') as f:
        f.write(json.dumps({'action': ['observe-displays', label], 'displays': observed}) + '\n')
    return observed


def offline_machine_registry():
    fixture = output / 'machine-registry-fixture.json'
    env = {'MSI_SCREEN_MACHINE_CONFIG': str(fixture)}
    def machine(*command, **kwargs):
        return run('machine', *command, env=env, **kwargs)
    empty = {'schemaVersion': 1, 'machines': []}
    assert machine('list') == empty
    local = ('add', 'local', '--name', 'Local fixture', '--platform', 'macos', '--input', 'usbc', '--local')
    preview = machine(*local, '--dry-run')
    assert preview['before'] == empty and preview['dryRun'] and not preview['verified']
    assert len(preview['after']['machines']) == 1 and not fixture.exists()
    created = machine(*local)
    assert created['verified'] and machine('list') == created['after']
    machine('add', 'linux', '--name', 'Linux fixture', '--platform', 'linux', '--input', 'dp', '--host', 'fixture-host')
    stable = machine('list')
    for command in [
        local,
        ('add', 'duplicate-input', '--name', 'Conflict', '--platform', 'linux', '--input', 'dp', '--host', 'fixture-host'),
        ('add', 'missing-host', '--name', 'Missing host', '--platform', 'linux', '--input', 'hdmi1'),
        ('update', 'linux', '--host', '-invalid'),
        ('update', 'linux', '--local'),
        ('update', 'linux', '--name', 'One', '--name', 'Two'),
        ('update', 'linux'),
        ('remove', 'linux', '--name', 'Unexpected'),
        ('fullscreen', 'missing', '--dry-run'),
    ]:
        failure = machine(*command, success=False)
        assert failure['verified'] is False and failure.get('before') is None
        assert machine('list') == stable, 'Invalid machine edit changed the registry'
    updated = machine('update', 'linux', '--name', 'Renamed fixture')
    assert updated['verified'] and updated['before'] == stable
    assert updated['after']['machines'][1]['name'] == 'Renamed fixture'
    stable = machine('list')
    assert machine('remove', 'linux', '--dry-run')['after']['machines'] == stable['machines'][:1]
    assert machine('list') == stable, 'Remove dry-run changed the registry'
    machine('remove', 'linux')
    machine('remove', 'local')
    assert machine('list') == empty


def offline():
    """Exercise executable boundaries, including the CLI embedded in release ZIPs."""
    global binary
    summary = {'offline': True, 'passed': False, 'binary': str(binary)}
    mounted_image = None
    try:
        if args.dmg:
            dmg = args.dmg.resolve()
            subprocess.run(['hdiutil', 'verify', str(dmg)], check=True)
            subprocess.run(['codesign', '--verify', '--strict', str(dmg)], check=True)
            subprocess.run(['xcrun', 'stapler', 'validate', str(dmg)], check=True)
            subprocess.run(['spctl', '--assess', '--type', 'open', '--context',
                            'context:primary-signature', '--verbose=2', str(dmg)], check=True)
            mount = output / 'dmg-volume'
            mount.mkdir()
            attached = subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse',
                        '-mountpoint', str(mount), '-plist', str(dmg)])
            mounted_image = mount
            (output / 'dmg-attachment.plist').write_bytes(attached)
            assert any(e.get('mount-point') == str(mount)
                       for e in plistlib.loads(attached)['system-entities'])
            shortcut = mount / 'Applications'
            assert shortcut.is_symlink() and os.readlink(shortcut) == '/Applications'
            args.app = mount / 'MSI Screen.app'
            binary = args.app / 'Contents/MacOS/msi-screen'
            summary.update({'dmg': str(dmg), 'binary': str(binary), 'applicationsShortcut': True})
        fixtures = subprocess.run(
            [sys.executable, '-m', 'unittest', 'discover', '-s', str(root / 'scripts/linux'), '-p', 'test_*.py', '-v'],
            capture_output=True, text=True, timeout=30
        )
        fixture_log = output / 'linux-companion-tests.log'
        fixture_log.write_text(fixtures.stdout + fixtures.stderr)
        event = {'action': ['linux-companion-fixtures'], 'exitCode': fixtures.returncode, 'log': str(fixture_log)}
        with (output / 'actions.jsonl').open('a') as f:
            f.write(json.dumps(event) + '\n')
        print(json.dumps(event), flush=True)
        if fixtures.returncode != 0:
            raise RuntimeError('Linux companion fixtures failed; see ' + str(fixture_log))
        summary['linuxCompanionFixtures'] = True
        help_result = run('--help')
        assert 'msi-screen fullscreen' in help_result['stdout'], 'CLI help is missing'
        capability = run('capabilities')
        if 'identity' in capability['commands']:
            run('identity', '--dry-run', success=False)
            run('identity', '--unknown', success=False)
        assert capability['schemaVersion'] == 1
        assert capability['model'] == 'MD342CQP' and capability['protocolVersion'] == 'V20'
        assert set(capability['inputs']) == {'hdmi1', 'hdmi2', 'dp', 'usbc'}
        assert 'fullscreen INPUT' in capability['commands'] and capability['dryRun'] is True
        assert set(capability['preserveUSBCommands']) == {'pbp on', 'pbp off', 'fullscreen INPUT', 'input INPUT'}
        assert {'displays', 'main monitor|built-in', 'display-request', 'settings', 'set SETTING VALUE'} <= set(capability['commands'])
        assert {'machine list', 'machine status ID', 'machine add ID', 'machine update ID', 'machine remove ID',
                'machine fullscreen ID', 'machine pbp-left ID', 'machine pbp-right ID'} <= set(capability['commands'])
        assert {'peripherals describe', 'peripherals mouse', 'peripherals probe [--seconds 1..15]',
                'peripherals keyboard --slot N [--machine ID]', 'peripherals app-switch',
                'peripherals wheel-action applications|spaces',
                'peripherals pin-app BUNDLE_ID --expected HEX', 'peripherals mouse-button dpi-cycle --expected HEX',
                'peripherals mouse-map PRESET --expected-left HEX --expected-right HEX'} <= set(capability['commands'])
        assert capability['displayRequestSchemaVersion'] == 1 and capability['displayRequestMaxBytes'] == 65536
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
            (('status', '--preserve-usb'), '--preserve-usb is for pbp, fullscreen, or input only'),
            (('machine', 'focus', 'fixture', '--preserve-usb'), '--preserve-usb is for pbp, fullscreen, or input only'),
            (('fullscreen', 'dp', '--preserve-usb', '--preserve-usb'), '--preserve-usb may be specified only once'),
            (('fullscreen', 'invalid', '--preserve-usb'), 'Invalid command'),
            (('pbp', 'on', '--left', '--preserve-usb'), 'Expected --left/--right'),
            (('pbp', 'off', '--right', 'dp', '--preserve-usb'), 'Use --left/--right with pbp on'),
            (('main', 'invalid'), 'Invalid command'),
            (('main',), 'Invalid command'),
            (('displays', '--dry-run'), '--dry-run is for setting changes'),
            (('settings', '--dry-run'), '--dry-run is for setting changes'),
            (('set', 'brightness', '-1'), 'Invalid setting or value'),
            (('set', 'brightness', '101'), 'Invalid setting or value'),
            (('set', 'brightness', 'not-an-integer'), 'Invalid setting or value'),
            (('peripherals', 'probe', '--seconds', '0'), 'Use peripherals probe'),
            (('peripherals', 'probe', '--seconds', '16'), 'Use peripherals probe'),
            (('peripherals', 'keyboard', '--slot', '0'), 'Use peripherals keyboard'),
            (('peripherals', 'keyboard', '--slot', '7'), 'Use peripherals keyboard'),
            (('peripherals', 'keyboard', '--slot', 'invalid'), 'Use peripherals keyboard'),
            (('peripherals', 'mouse', '--machine', 'fixture'), 'Use peripherals mouse'),
            (('peripherals', 'mouse-map', 'horizontal'), 'Use peripherals mouse-map'),
            (('peripherals', 'mouse-map', 'unknown', '--expected-left', '07000800', '--expected-right', '07000800'), 'Use peripherals mouse-map'),
            (('peripherals', 'mouse-map', 'app-switch', '--expected-left', 'not-hex!', '--expected-right', '07000800'), 'Use peripherals mouse-map'),
            (('peripherals', 'mouse-map', 'horizontal', '--expected-left', '070008', '--expected-right', '07000800'), 'Use peripherals mouse-map'),
            (('peripherals', 'mouse-map', 'horizontal', '--expected-left', '07000800', '--expected-left', '07000800'), 'Use peripherals mouse-map'),
            (('peripherals', 'mouse-map', 'horizontal', '--expected-left', '07000800', '--unexpected', '07000800'), 'Use peripherals mouse-map'),
            (('peripherals', 'mouse-map', 'horizontal', '--expected-left', '07000800'), 'Use peripherals mouse-map'),
            (('peripherals', 'app-switch', '--machine', 'fixture'), 'Use peripherals app-switch'),
            (('peripherals', 'app-switch', '--dry-run'), 'Use peripherals app-switch'),
            (('peripherals', 'controllers', '--machine', 'fixture'), 'Use peripherals controllers'),
            (('peripherals', 'controller-test', '--seconds', '0'), 'Use peripherals controller-test'),
            (('peripherals', 'controller-test', '--seconds', '16'), 'Use peripherals controller-test'),
            (('peripherals', 'controller-test', '--seconds', '1', '--extra'), 'Use peripherals controller-test'),
            (('peripherals', 'wheel-action'), 'Use peripherals wheel-action'),
            (('peripherals', 'wheel-action', 'invalid'), 'Use peripherals wheel-action'),
            (('peripherals', 'wheel-action', 'spaces', '--expected', '07000800'), 'Use peripherals wheel-action'),
            (('peripherals', 'wheel-action', 'spaces', '--dry-run'), 'Use peripherals wheel-action'),
            (('peripherals', 'pin-app', 'so.stencil.tern'), 'Use peripherals pin-app'),
            (('peripherals', 'pin-app', 'so.stencil.tern', '--expected', 'bad-hex!'), 'Use peripherals pin-app'),
            (('peripherals', 'pin-app', '/Applications/Tern.app', '--expected', '08000300'), 'Use peripherals pin-app'),
            (('peripherals', 'mouse-button', 'dpi-cycle'), 'Use peripherals mouse-button'),
            (('peripherals', 'mouse-button', 'dpi-cycle', '--unknown', '01006f00'), 'Use peripherals mouse-button'),
            (('peripherals', 'mouse-button', 'dpi-cycle', '--expected', '01006f'), 'Use peripherals mouse-button'),
        ]:
            failure = run(*command, success=False)
            assert failure['verified'] is False and expected in failure['error']
            assert failure.get('before') is None, 'Invalid input reached the monitor'
        for request in [
            '{"schemaVersion":1,"action":"status","unexpected":true}',
            '{"schemaVersion":2,"action":"status"}',
            '{"schemaVersion":1,"action":"main","target":"monitor"}',
            '{"schemaVersion":1,"action":"main","expected":null,"target":"monitor"}',
            'not-json', 'x' * 65537,
        ]:
            failure = run('display-request', input=request, success=False)
            assert failure['verified'] is False and failure.get('before') is None
        offline_machine_registry()
        if args.app:
            app = args.app.resolve()
            with (app / 'Contents/Info.plist').open('rb') as f:
                info = plistlib.load(f)
            assert info['CFBundleShortVersionString'] == (root / 'VERSION').read_text().strip()
            assert info['LSUIElement'] is True
            assert 'msi-screen' in info['CFBundleURLTypes'][0]['CFBundleURLSchemes']
            assert binary == app / 'Contents/MacOS/msi-screen', 'Smoke must run the packaged CLI'
            assert (app / 'Contents/Resources/LICENSE').read_text() == (root / 'LICENSE').read_text(), 'Packaged license is missing or stale'
            skill = root / 'skills/msi-screen-control'
            bundled_skill = app / 'Contents/Resources/AgentSkills/msi-screen-control'
            for source in skill.rglob('*'):
                if source.is_file():
                    assert (bundled_skill / source.relative_to(skill)).read_bytes() == source.read_bytes(), 'Bundled agent skill is missing or stale'
            updates = json.loads((root / 'config/updates.json').read_text())
            assert info['SUFeedURL'] == updates['feedURL']
            assert info['SUPublicEDKey'] == updates['publicKey']
            assert info['SURequireSignedFeed'] is True and info['SUAutomaticallyUpdate'] is True
            assert info['SUVerifyUpdateBeforeExtraction'] is True
            sparkle = app / 'Contents/Frameworks/Sparkle.framework'
            assert (sparkle / 'Sparkle').is_file(), 'Sparkle framework is missing'
            assert (app / 'Contents/Resources/Sparkle-LICENSE').is_file(), 'Sparkle license is missing'
            for executable in [binary, app / 'Contents/MacOS' / info['CFBundleExecutable']]:
                assert executable.is_file() and os.access(executable, os.X_OK)
                # The release must not depend on Homebrew or a developer checkout.
                dependencies = subprocess.check_output(['/usr/bin/otool', '-L', str(executable)], text=True)
                for line in dependencies.splitlines():
                    # Fat binaries emit a separate file header for each slice.
                    if line.startswith(str(executable)) and line.endswith(':'):
                        continue
                    library = line.strip().split(' (', 1)[0]
                    bundled_sparkle = executable.name == info['CFBundleExecutable'] and library == '@rpath/Sparkle.framework/Versions/B/Sparkle'
                    assert bundled_sparkle or library.startswith(('/System/Library/', '/usr/lib/', '@rpath/libswift')), library
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
            summary['app'] = str(app)
            if args.dmg:
                for executable in (binary, app / 'Contents/MacOS' / info['CFBundleExecutable']):
                    subprocess.run(['lipo', str(executable), '-verify_arch', 'arm64', 'x86_64'], check=True)
                    for arch in ('arm64', 'x86_64'):
                        signature = subprocess.check_output(['codesign', '-dvvv', '--arch', arch,
                                    str(executable)], stderr=subprocess.STDOUT, text=True)
                        assert 'Authority=Developer ID Application:' in signature
                        assert '(runtime)' in signature and 'Timestamp=' in signature
                subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
                subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)], check=True)
                summary['notarizedUniversalApp'] = True
            if args.previous_app:
                previous = args.previous_app.resolve()
                subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(previous)], check=True)
                def requirement(path):
                    text = subprocess.check_output(['/usr/bin/codesign', '-d', '-r-', str(path)],
                                                   stderr=subprocess.STDOUT, text=True)
                    return next(line.removeprefix('designated => ') for line in text.splitlines()
                                if line.startswith('designated => '))
                prior_requirement = requirement(previous)
                assert 'cdhash' not in prior_requirement and 'certificate' in prior_requirement, \
                    'Previous app needs a stable certificate-backed identity'
                subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + prior_requirement,
                                str(app)], check=True)
                old_binary = previous / 'Contents/MacOS' / info['CFBundleExecutable']
                new_binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
                summary['identityContinuity'] = {'previousApp': str(previous),
                    'requirement': prior_requirement, 'candidateRequirement': requirement(app),
                    'executableChanged': hashlib.sha256(old_binary.read_bytes()).digest() !=
                                         hashlib.sha256(new_binary.read_bytes()).digest(),
                    'candidateSatisfiesPreviousIdentity': True,
                    'tccRetention': 'Requires live grants before and after installing the changed build'}
        summary['passed'] = True
    except Exception as error:
        summary['error'] = str(error)
    finally:
        if mounted_image is not None:
            try:
                # This invocation mounted this unique path; never detach an
                # existing user volume or remove files through a live mount.
                subprocess.run(['hdiutil', 'detach', str(mounted_image)], check=True)
                summary['dmgDetached'] = True
            except Exception as error:
                summary.update({'passed': False, 'cleanupError': str(error)})
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'summary': summary, 'evidence': str(output)}, indent=2), flush=True)
    return 0 if summary['passed'] else 1


if args.offline:
    sys.exit(offline())


summary = {'exercise': args.exercise, 'exerciseControls': args.exercise_controls,
           'exercisePeerControls': args.exercise_peer_controls,
           'exerciseMachine': args.exercise_machine, 'exerciseMachineEditor': args.exercise_machine_editor,
           'exerciseFocus': args.exercise_focus, 'peripherals': args.peripherals, 'probePointer': args.probe_pointer, 'probeController': args.probe_controller,
           'sharing': args.sharing, 'passed': False}
baseline = None
kvm_local_safe = True
exercise_started = False
layout_usb_preference = None
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


def gui_snapshot(label, screenshot=False, window=None):
    # Labels may contain configured machine names; keep evidence inside output.
    label = label.replace('/', '_').replace('\\', '_')
    extra = {'screenshot_out_file': str(output / (label + '.png'))} if screenshot else {'include_screenshot': False}
    result = cua.call('get_window_state', pid=gui_pid, window_id=gui_window if window is None else window, **extra)
    (output / (label + '.json')).write_text(json.dumps(result, indent=2))
    return result


def gui_menu_bar(label):
    result = cua.call('get_desktop_state', screenshot_out_file=str(output / (label + '-menubar.png')))
    (output / (label + '-menubar.json')).write_text(json.dumps(result, indent=2))


def gui_inspect_menu_appearance():
    global gui_window
    status = run('status', success=None)
    unavailable = status.get('verified') is False and 'error' in status
    if unavailable:
        gui_wait_for('gui-unavailable', lambda tree: 'Monitor unavailable' in tree)
    else:
        gui_ready('gui-appearance-ready')
    gui_snapshot('gui-appearance-before-close', screenshot=True)
    gui_close_controls()
    assert not any(w['window_id'] == gui_window and w.get('is_on_screen')
                   for w in cua.call('list_windows', pid=gui_pid)['windows']), 'Controls did not close'
    gui_menu_bar('gui-appearance-closed')
    reopened = cua.call('launch_app', bundle_id='com.danielsivan.msi-screen.menu', urls=['msi-screen://controls'])
    assert reopened['pid'] == gui_pid, 'Reopen reached a different process'
    gui_wait_for('gui-appearance-reopened', lambda tree: 'Machines' in tree)
    if unavailable:
        gui_wait_for('gui-unavailable-reopened', lambda tree: 'Monitor unavailable' in tree)
    snapshot = gui_snapshot('gui-appearance-result', screenshot=True)
    if unavailable:
        assert 'Proposed layout:' not in snapshot.get('tree_markdown', ''), 'Unavailable monitor retained a colored draft'
    gui_menu_bar('gui-appearance-result')
    summary['menuAppearance'] = {'unavailable': unavailable, 'panelWindow': gui_window,
                               'desktopStacking': 'VISUAL_REVIEW_REQUIRED',
                               'trigger': 'msi-screen://controls', 'physicalMenuBarClickTested': False}


def prepare_update_fixture(source):
    """Serve a signed real update locally; no production app or preferences are changed."""
    fixture = output / 'update-fixture'
    fixture.mkdir()
    served = fixture / 'served'
    served.mkdir()
    handler = lambda *a, **kw: http.server.SimpleHTTPRequestHandler(*a, directory=str(served), **kw)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:' + str(server.server_port) + '/'
    bundle_id = 'com.danielsivan.msi-screen.update-fixture-' + uuid.uuid4().hex
    # Read the artifact's signer, not an unrelated running app's identity.
    signing = subprocess.run(['codesign', '-dvv', str(source)], capture_output=True, text=True, check=True)
    signers = re.findall(r'^Authority=(Developer ID Application:[^\n]+)', signing.stderr, re.MULTILINE)
    assert len(signers) == 1, 'The update fixture needs a Developer ID signed release app'
    paths = []
    latest_version = (root / 'VERSION').read_text().strip()
    for name, version in [('installed', '0.0.1'), ('release', latest_version)]:
        parent = fixture / name
        parent.mkdir()
        app = parent / 'MSI Screen.app'
        subprocess.run(['ditto', str(source), str(app)], check=True)
        plist = app / 'Contents/Info.plist'
        info = plistlib.loads(plist.read_bytes())
        info.update(CFBundleIdentifier=bundle_id, CFBundleVersion=version, CFBundleShortVersionString=version,
                    SUFeedURL=base + 'appcast.xml', SUEnableAutomaticChecks=True,
                    NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
        info.pop('CFBundleURLTypes', None)  # Keep the production URL handler unchanged.
        plist.write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--timestamp=none', '--identifier', bundle_id,
                        '--sign', signers[0], str(app)], check=True)
        paths.append(app)
    archive = served / 'MSI-Screen-update-test.zip'
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(paths[1]), str(archive)], check=True)
    settings = json.loads((root / 'config/updates.json').read_text())
    subprocess.run([str(root / '.build/artifacts/sparkle/Sparkle/bin/generate_appcast'),
                    '--account', settings['keychainAccount'], '--maximum-deltas', '0',
                    '--download-url-prefix', base, str(served)], check=True)
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                    '-f', str(paths[0])], check=True)
    return server, bundle_id


def prepare_agent_skill_fixture(source):
    app = output / 'agent-skill-fixture/MSI Screen.app'
    app.parent.mkdir()
    subprocess.run(['ditto', str(source), str(app)], check=True)
    bundle_id = 'com.danielsivan.msi-screen.skill-fixture-' + uuid.uuid4().hex
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    info.update(CFBundleIdentifier=bundle_id, SUEnableAutomaticChecks=False)
    info.pop('CFBundleURLTypes', None)  # Do not claim the installed app's URL scheme.
    plist.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                    '-f', str(app)], check=True)
    return bundle_id


def gui_inspect_agent_skill():
    gui_click('Settings', 'AXButton')
    source = args.agent_skill_fixture.resolve() / 'Contents/Resources/AgentSkills/msi-screen-control'
    destination = Path.home() / '.agents/skills/msi-screen-control'
    for label in ('installed', 'repeated'):
        gui_click('Install agent skill', 'AXButton')
        gui_wait_for('gui-agent-skill-' + label, lambda tree:
                     'Available on your next agent turn.' in tree,
                     failed=('A different skill already exists', 'The agent skill is missing'))
        gui_snapshot('gui-agent-skill-' + label, screenshot=True)
        expected = {str(p.relative_to(source)): p.read_bytes() for p in source.rglob('*') if p.is_file()}
        actual = {str(p.relative_to(destination)): p.read_bytes() for p in destination.rglob('*') if p.is_file()}
        assert actual == expected and 'SKILL.md' in actual, 'Installed skill differs from the real app resources'
    summary['agentSkill'] = {'installedForUser': True, 'destination': str(destination),
                             'filesMatched': sorted(actual), 'repeatedInstallVerified': True,
                             'productionAppModified': False}


def gui_inspect_update():
    ready = gui_wait_for('gui-update-downloaded', lambda tree: 'Update ' + (root / 'VERSION').read_text().strip() + ' ready' in tree,
                         failed=('Update Error',), timeout=90)
    assert any(e.get('label') == 'Install update' and e.get('enabled', True) for e in ready['elements'])
    gui_snapshot('gui-update-ready', screenshot=True)
    gui_menu_bar('gui-update-ready')
    # Sparkle activates its user-initiated dialog. The default check stays in
    # the background; --install-update requires separate foreground approval.
    summary['updateFixture'] = {'signedDownloadReady': True, 'installActionExposed': True,
                                'installDialogTested': False, 'installed': False,
                                'productionModified': False, 'fromVersion': '0.0.1',
                                'toVersion': (root / 'VERSION').read_text().strip(), 'feed': 'signed loopback fixture'}
    if args.install_update:
        gui_install_update()


def gui_install_update():
    gui_click('Install update', 'AXButton')
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        for window in cua.call('list_windows', pid=gui_pid)['windows']:
            if window['window_id'] == gui_window:
                continue
            state = gui_snapshot('gui-sparkle-install-dialog', screenshot=True, window=window['window_id'])
            buttons = [e for e in state['elements'] if e.get('role') == 'AXButton'
                       and e.get('label') == 'Install and Relaunch' and e.get('enabled', True)]
            if len(buttons) == 1:
                target = (window['window_id'], buttons[0]['element_token'])
                break
        else:
            time.sleep(0.2)
            continue
        break
    else:
        raise RuntimeError('Sparkle Install and Relaunch dialog did not appear')
    try:
        result = cua.call('click', pid=gui_pid, window_id=target[0], element_token=target[1],
                          delivery_mode='background')
        with (output / 'actions.jsonl').open('a') as f:
            f.write(json.dumps({'action': ['gui-click', 'Install and Relaunch'], 'result': result}) + '\n')
    except Exception:
        if owns_gui_process():
            raise
    # Sparkle launches the replacement itself. Observe that process before any
    # verifier launch, so a manual relaunch cannot masquerade as this result.
    executable = str(output / 'update-fixture/installed/MSI Screen.app/Contents/MacOS/MSIScreenMenu')
    relaunched_pid = None
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        processes = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
        matches = [int(parts[0]) for line in processes.splitlines()
                   if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == executable
                   and int(parts[0]) != gui_pid]
        if not owns_gui_process() and len(matches) == 1:
            relaunched_pid = matches[0]
            break
        time.sleep(0.2)
    assert relaunched_pid, 'Sparkle did not automatically relaunch the replacement'
    summary['guiProcessExited'] = True
    summary['updateFixture'].update(installDialogTested=True, automaticallyRelaunched=True,
                                    automaticRelaunchPID=relaunched_pid)
    print(json.dumps({'action': ['observe-sparkle-automatic-relaunch'], 'pid': relaunched_pid}), flush=True)

    def owns_relaunched_process():
        observed = subprocess.run(['ps', '-p', str(relaunched_pid), '-o', 'comm='], capture_output=True, text=True)
        return observed.stdout.strip() == executable

    # Reopen controls only in our uniquely identified fixture, then request a
    # normal Quit. The installed production app has a different bundle ID/path.
    reopened = cua.call('launch_app', bundle_id=update_bundle_id, urls=['msi-screen://controls'])
    assert reopened['pid'] == relaunched_pid and owns_relaunched_process(), 'Reopen selected a different app'
    try:
        cua.call('hotkey', pid=relaunched_pid, keys=['cmd', 'q'], delivery_mode='background')
    except Exception:
        if owns_relaunched_process():
            # Only our disposable, read-only test copy may need escalation if
            # the driver cannot target an accessory app's floating panel.
            cua.call('kill_app', pid=relaunched_pid)
    deadline = time.monotonic() + 3
    while owns_relaunched_process() and time.monotonic() < deadline:
        time.sleep(0.1)
    assert not owns_relaunched_process(), 'Automatically relaunched fixture did not exit'
    summary['updateFixture']['automaticRelaunchProcessExited'] = True


def gui_relaunch_updated_fixture(bundle_id):
    """Launch the replaced bundle in the background and drive its real Settings."""
    global cua, owner, gui_pid, gui_window, gui_owned
    cua = CuaSession()
    owner = 'msi-update-relaunch-' + uuid.uuid4().hex
    receipt_path = output / 'gui-relaunch-window.json'
    try:
        launched = cua.call('launch_app', bundle_id=bundle_id, creates_new_application_instance=True,
                           additional_arguments=['--show-controls', '--verification-owner', owner,
                                                 '--verification-window-file', str(receipt_path),
                                                 '--supervisor', str(os.getpid())])
        gui_pid = launched['pid']
        gui_owned = owns_gui_process()
        assert gui_owned, 'Relaunch did not create our owned process'
        receipt = json.loads(receipt_path.read_text())
        assert receipt['pid'] == gui_pid and receipt['owner'] == owner, 'Relaunch receipt belongs to another instance'
        gui_window = receipt['windowID']
        gui_wait_for('gui-updated-health', lambda tree: 'Machines' in tree)
        gui_click('Settings', 'AXButton')
        gui_wait_for('gui-updated-settings', lambda tree: 'Install agent skill' in tree and 'Launch at login' in tree)
        gui_snapshot('gui-updated-relaunched', screenshot=True)
        summary['updateFixture']['relaunchedUpdatedApp'] = True
    finally:
        try:
            if gui_owned and owns_gui_process():
                try:
                    gui_named_menu('App actions')
                    gui_click('Quit', 'AXMenuItem')
                except Exception:
                    if owns_gui_process():
                        raise
                deadline = time.monotonic() + 3
                while owns_gui_process() and time.monotonic() < deadline:
                    time.sleep(0.1)
                assert not owns_gui_process(), 'Relaunched fixture did not quit'
                summary['updateFixture']['relaunchedProcessExited'] = True
        finally:
            cua.close()


def login_item_registration(label):
    result = subprocess.run(['sfltool', 'dumpbtm'], capture_output=True, text=True, timeout=15, check=True)
    sections = re.split(r'(?m)^ Records for UID (-?\d+) :[^\n]*\n', result.stdout)
    records = []
    for uid, section in zip(sections[1::2], sections[2::2]):
        if int(uid) != os.getuid():
            continue
        for record in re.split(r'(?m)^ #\d+:\n', section):
            if not re.search(r'(?m)^\s*Bundle Identifier: com\.danielsivan\.msi-screen\.menu\s*$', record):
                continue
            kind = re.search(r'(?m)^\s*Type: (.+)$', record)
            if kind is None or '(0x4)' not in kind[1]:
                continue  # An app inventory record alone is not a login item.
            disposition = re.search(r'(?m)^\s*Disposition: \[([^]]*)\]', record)
            assert disposition, 'Login item has no observable disposition'
            records.append({'type': kind[1], 'flags': [s.strip() for s in disposition[1].split(',')]})
    report = {'records': records, 'enabled': any('enabled' in r['flags'] and 'allowed' in r['flags'] for r in records)}
    (output / (label + '-registration.json')).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'action': ['observe-login-item', label], **report}), flush=True)
    return report


def gui_login_item_value():
    state = gui_snapshot('gui-login-item-current', screenshot=True)
    controls = [e for e in state['elements'] if e.get('label') == 'Launch at login'
                and e.get('role') in ('AXCheckBox', 'AXSwitch')]
    assert len(controls) == 1, 'Launch at login toggle is missing or ambiguous'
    assert str(controls[0].get('value')) in ('0', '1'), 'Login item state is unobservable'
    return str(controls[0]['value']) == '1'


def gui_inspect_login_item():
    gui_click('Settings', 'AXButton')
    initial = gui_login_item_value()
    assert login_item_registration('baseline')['enabled'] == initial, 'UI differs from native login item state'
    owned = initial
    try:
        for target in (not initial, initial):
            assert gui_login_item_value() == owned, 'Login item changed outside this exercise'
            gui_click('Launch at login')
            owned = target
            label = 'enabled' if target else 'disabled'
            gui_wait_for('gui-login-item-' + label, lambda tree:
                         ('Launch at login is enabled.' if target else 'Launch at login is off.') in tree)
            assert gui_login_item_value() == target, 'Login item toggle did not change'
            assert login_item_registration(label)['enabled'] == target, 'macOS registration differs from the toggle'
        summary['loginItem'] = {'enabled': initial, 'toggledBothDirections': True,
                                'nativeRegistrationMatched': True, 'restored': True,
                                'actualLogoutTested': False}
    finally:
        current = gui_login_item_value()
        if current != initial:
            assert current == owned, 'Login item changed elsewhere; refusing to overwrite it'
            gui_click('Launch at login')
            gui_wait_for('gui-login-item-restored', lambda tree:
                         ('Launch at login is enabled.' if initial else 'Launch at login is off.') in tree)
            assert login_item_registration('restored')['enabled'] == initial


def gui_wait_across_poll(label):
    # The status timer is 30 seconds with 3 seconds of tolerance. Keep this
    # wait beyond one full cadence, with progress visible in the OMP job log.
    started = time.monotonic()
    deadline = started + 35
    while True:
        now = time.monotonic()
        event = {'action': ['gui-poll-checkpoint', label],
                 'elapsedSeconds': round(now - started, 1), 'requiredSeconds': 35}
        with (output / 'actions.jsonl').open('a') as f:
            f.write(json.dumps(event) + '\n')
        print(json.dumps(event), flush=True)
        if now >= deadline:
            return
        time.sleep(min(10, deadline - now))


def gui_click(label=None, role=None, occurrence=0, before_action=None):
    # SwiftUI may still show the previous message while an asynchronous SSH
    # read disables its buttons. Wait for an actionable target, not stale text.
    deadline = time.monotonic() + 50
    while True:
        state = gui_snapshot('before-' + (label or role), screenshot=True)
        matches = [e for e in state['elements']
                   if e.get('enabled', True)
                   and (label is None or e.get('label', '') == label) and (role is None or e.get('role') == role)]
        if len(matches) > occurrence:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(f'GUI control unavailable: {label or role}')
        time.sleep(0.25)
    if before_action is not None:
        before_action()
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
            # The status item lives outside the controls window. Capture the
            # actual bar too, for comparison with the independent USB readback.
            gui_menu_bar(label)
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
    return read_state('status')


def gui_wait_for(label, ready, failed=(), timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = gui_snapshot(label)
        tree = state.get('tree_markdown', '')
        if any(message in tree for message in failed):
            raise RuntimeError(tree)
        if ready(tree):
            return gui_snapshot(label, screenshot=True)
        time.sleep(0.25)
    raise RuntimeError(f'GUI did not reach {label}')


def gui_expand(label, expanded=True):
    deadline = time.monotonic() + 5
    clicked = False
    while True:
        snapshot = gui_snapshot('disclosure-' + label)
        matches = [e for e in snapshot['elements']
                   if e.get('role') in ('AXDisclosureTriangle', 'AXButton') and e.get('label') == label]
        assert len(matches) == 1, f'Missing or ambiguous disclosure: {label}'
        control = matches[0]
        value = str(control.get('value', '')).lower()
        assert value in ('0', '1', 'expanded', 'collapsed'), f'Unknown disclosure state: {label}: {value}'
        if (value in ('1', 'expanded')) == expanded:
            return snapshot
        if not clicked:
            gui_click(label, control['role'])
            clicked = True
        elif time.monotonic() >= deadline:
            raise RuntimeError('Disclosure did not change state: ' + label)
        time.sleep(0.1)


def gui_machines(label, registry):
    gui_click('Machines')
    gui_click('Refresh monitor')
    snapshot = gui_wait_for(label, lambda tree:
                           'Machine checks complete. Input selection is read from the monitor.' in tree,
                           timeout=55)
    names = [machine['name'] for machine in registry['machines']]
    assert all(name in snapshot.get('tree_markdown', '') for name in names), 'A saved machine card is missing'
    assert snapshot.get('tree_markdown', '').count('AXStaticText = "Main & extended displays"') == \
        sum(machine['platform'] == 'macos' for machine in registry['machines']), \
        'Mac display roles must be visible without expanding connection details'
    return snapshot


def gui_editor_window(label, timeout=5, required=True):
    """A sheet can live in its own window or in the panel's accessibility tree."""
    deadline = time.monotonic() + timeout
    while True:
        windows = cua.call('list_windows', pid=gui_pid).get('windows', [])
        candidates = list(dict.fromkeys([gui_window] + [w['window_id'] for w in windows
                                                       if w.get('is_on_screen', True)]))
        for window in candidates:
            try:
                state = gui_snapshot(label + '-window-' + str(window), window=window)
            except Exception:
                # A sheet can disappear between the inventory and state read.
                continue
            elements = state.get('elements', [])
            name_fields = [e for e in elements
                           if e.get('role') == 'AXTextField' and e.get('label') in ('Machine name', 'Name')]
            named_field_in_tree = re.search(r'AXTextField[^\n]*\(Machine name\)',
                                            state.get('tree_markdown', '')) is not None
            actions = {e.get('label') for e in elements
                       if e.get('role') == 'AXButton' and e.get('enabled', True)}
            # Cua omits disabled controls from actionable elements. An empty
            # Add sheet still needs recognition so cleanup can press Cancel.
            save_in_tree = 'AXButton (Save)' in state.get('tree_markdown', '')
            if (len(name_fields) == 1 or named_field_in_tree) and 'Cancel' in actions \
                    and ('Save' in actions or save_in_tree):
                return window
        if time.monotonic() >= deadline:
            if required:
                raise RuntimeError('Machine editor sheet was not found in the owned app')
            return None
        time.sleep(0.2)


def gui_dismiss_machine_editor(label):
    global gui_window
    assert gui_owned and owns_gui_process(), 'Cannot dismiss a sheet in an unowned process'
    panel_window = gui_window
    try:
        editor = gui_editor_window(label, timeout=1, required=False)
        if editor is not None:
            gui_window = editor
            gui_click('Cancel', 'AXButton')
            if gui_editor_window(label + '-closed', timeout=1, required=False) is not None:
                raise RuntimeError('Machine editor remained open after Cancel')
    finally:
        gui_window = panel_window


def require_editor_identity(state, machine):
    tree = state.get('tree_markdown', '')
    assert 'AXStaticText = "Edit machine"' in tree, 'Edit action opened the wrong sheet'
    fields = [e for e in state.get('elements', [])
              if e.get('role') == 'AXTextField' and e.get('label') == 'Machine name']
    assert len(fields) == 1 and fields[0].get('value') == machine['name'], \
        'Machine editor was not initialized with the selected machine name'
    if machine.get('host') is not None:
        hosts = [e for e in state.get('elements', [])
                 if e.get('role') == 'AXTextField' and e.get('label') == 'Machine SSH host']
        assert len(hosts) == 1 and hosts[0].get('value') == machine['host'], \
            'Machine editor was not initialized with the selected SSH host'


def gui_wait_machine_name(label, panel_window, name, timeout=15):
    """Observe the registry notification in the card, without reloading the editor."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = gui_snapshot(label, window=panel_window)
        # Cua's actionable elements omit static text. Its full AX tree retains
        # the visible name, including behind a sheet where controls are disabled.
        if 'AXStaticText = ' + json.dumps(name, ensure_ascii=False) in state.get('tree_markdown', ''):
            return gui_snapshot(label, screenshot=True, window=panel_window)
        time.sleep(0.2)
    raise RuntimeError('Machine card did not reflect the external registry notification: ' + name)


def gui_named_menu(label):
    # NSMenuButton's flat Cua label is "More"; the unique accessibility
    # description is retained in the tree with its element index.
    pattern = re.compile(r'^\s*-\s+\[(\d+)\]\s+AXMenuButton\b[^\n]*\('
                         + re.escape(label) + r'\)', re.MULTILINE)
    state = gui_snapshot('before-menu-' + label, screenshot=True)
    indices = [int(value) for value in pattern.findall(state.get('tree_markdown', ''))]
    assert len(indices) == 1, 'Menu is missing or ambiguous: ' + label
    matches = [element for element in state.get('elements', [])
               if element.get('element_index') == indices[0] and element.get('enabled', True)]
    assert len(matches) == 1, 'Menu is not actionable: ' + label
    result = cua.call('click', pid=gui_pid, window_id=gui_window,
                      element_token=matches[0]['element_token'], delivery_mode='background')
    event = {'action': ['gui-menu', label], 'result': result}
    with (output / 'actions.jsonl').open('a') as f:
        f.write(json.dumps(event) + '\n')
    print(json.dumps(event), flush=True)
    if result.get('effect') == 'refused':
        raise RuntimeError(result)


def gui_close_controls():
    assert gui_owned and owns_gui_process(), 'Closing controls requires the owned GUI process'
    gui_named_menu('App actions')
    gui_click('Close controls', 'AXMenuItem')


def machine_registry_rename(registry, machine_id, name):
    result = copy.deepcopy(registry)
    matches = [machine for machine in result['machines'] if machine['id'] == machine_id]
    assert len(matches) == 1, 'Editor exercise requires one existing machine ID'
    matches[0]['name'] = name
    return result


def require_registry(expected, message):
    current = run('machine', 'list')
    if current != expected:
        raise RuntimeError(message)
    return current


def exercise_machine_editor(machine_id):
    """Exercise stale-edit rejection through the real sheet; never change hardware."""
    global gui_window
    registry = run('machine', 'list')
    matches = [machine for machine in registry['machines'] if machine['id'] == machine_id]
    assert len(matches) == 1, 'Editor exercise requires one existing machine ID'
    original = matches[0]
    renamed = original['name'] + ' verification'
    if len(renamed) > 128:
        renamed = original['name'][:106] + ' verification ' + uuid.uuid4().hex[:8]
    assert renamed != original['name'], 'The verification name must differ from the original'
    owned = machine_registry_rename(registry, machine_id, renamed)
    summary['machineEditor'] = {'id': machine_id, 'baseline': registry, 'planned': owned,
                                'staleSaveRejected': False, 'restored': False}
    proof = summary['machineEditor']
    monitor = read_state('status')
    panel_window = gui_window
    editor_opened = False
    rename_attempted = False
    try:
        gui_machines('gui-editor-machines', registry)
        require_registry(registry, 'Machine registry changed before opening the editor; no edit attempted')
        gui_expand('Connection details for ' + original['name'])
        gui_named_menu('Edit ' + original['name'])
        # A click may open a sheet even if its immediate receipt or discovery
        # fails. Cleanup must attempt dismissal once presentation is requested.
        editor_opened = True
        gui_click('Edit machine…', 'AXMenuItem')
        gui_window = gui_editor_window('gui-editor-locate')
        proof['panelWindow'] = panel_window
        proof['editorWindow'] = gui_window
        editor_state = gui_snapshot('gui-editor-open', screenshot=True)
        require_editor_identity(editor_state, original)
        require_registry(registry, 'Machine registry changed while opening the editor; no rename attempted')
        preview = run('machine', 'update', machine_id, '--name', renamed, '--dry-run')
        assert preview['before'] == registry and preview['after'] == owned
        assert preview['dryRun'] and not preview['verified']
        require_registry(registry, 'Machine registry changed before the external rename; no rename attempted')
        # The CLI also compares its loaded snapshot while holding the registry
        # lock. Inspect its before-state as well as the independent readback.
        rename_attempted = True
        changed = run('machine', 'update', machine_id, '--name', renamed)
        assert changed['verified'] and changed['before'] == registry and changed['after'] == owned
        require_registry(owned, 'External rename did not preserve the complete expected registry')
        gui_wait_machine_name('gui-editor-external-name', panel_window, renamed)
        proof['notificationObserved'] = True
        gui_snapshot('gui-editor-before-stale-save', screenshot=True)
        gui_click('Save', 'AXButton')
        gui_wait_for('gui-editor-stale-save-rejected',
                     lambda tree: 'This machine changed while editing' in tree)
        require_registry(owned, 'Saving the stale editor changed the registry')
        proof['staleSaveRejected'] = True
        gui_click('Cancel', 'AXButton')
        assert gui_editor_window('gui-editor-cancelled', timeout=1, required=False) is None, \
            'Cancel did not close the machine editor'
        editor_opened = False
        gui_window = panel_window
        gui_wait_machine_name('gui-editor-renamed-card', panel_window, renamed)
        assert read_state('status') == monitor, 'Machine editor exercise changed the monitor layout'
    finally:
        dismiss_error = None
        if editor_opened:
            try:
                gui_dismiss_machine_editor('gui-editor-cleanup')
            except Exception as error:
                dismiss_error = str(error)
                proof['dismissError'] = dismiss_error
        gui_window = panel_window
        current = run('machine', 'list')
        if current != registry:
            if not rename_attempted or current != owned:
                proof['restoreError'] = 'Machine registry changed outside the exercise; refusing to overwrite it'
                raise RuntimeError(proof['restoreError'])
            preview = run('machine', 'update', machine_id, '--name', original['name'], '--dry-run')
            assert preview['before'] == owned and preview['after'] == registry
            require_registry(owned, 'Machine registry changed before restoration; refusing to overwrite it')
            restored = run('machine', 'update', machine_id, '--name', original['name'])
            assert restored['verified'] and restored['before'] == owned and restored['after'] == registry
        proof['final'] = require_registry(registry, 'Machine editor cleanup did not restore the exact registry')
        proof['restored'] = True
        gui_wait_machine_name('gui-editor-restored-card', panel_window, original['name'])
        assert read_state('status') == monitor, 'Machine editor exercise changed the monitor layout'
        if dismiss_error:
            raise RuntimeError('Registry restored, but editor dismissal failed: ' + dismiss_error)


def predict_machine_route(machine, route, baseline):
    """Independent expected monitor fields; no CLI plan is trusted as the oracle."""
    target = copy.deepcopy(baseline)
    selected = machine['input']
    if route == 'fullscreen':
        target.update(mode='off', source1=selected)
        return target
    preferred = 'source2' if route == 'pbp-left' else 'source1'
    alternate = 'source1' if route == 'pbp-left' else 'source2'
    other = next((baseline[key] for key in [preferred, alternate] if baseline[key] != selected), None)
    if other is None:
        raise ValueError('No distinct saved counterpart for PBP')
    target.update(mode='pbp', source1=selected if route == 'pbp-left' else other,
                  source2=selected if route == 'pbp-right' else other)
    target['pipInput'] = target['source2']
    return target


def verify_machine_dry_runs(registry, baseline):
    for machine in registry['machines']:
        for route in ('fullscreen', 'pbp-left', 'pbp-right'):
            try:
                expected = predict_machine_route(machine, route, baseline)
            except ValueError:
                failure = run('machine', route, machine['id'], '--dry-run', success=False)
                assert 'different input for the other side' in failure['error']
            else:
                plan = run('machine', route, machine['id'], '--dry-run')
                assert plan['schemaVersion'] == 1 and plan['machineID'] == machine['id'] and plan['route'] == route
                assert plan['before'] == baseline and plan['target'] == expected
                assert plan['dryRun'] and not plan['verified'] and plan.get('after') is None
                assert bool(plan['changes']) == (expected != baseline)
            assert read_state('status') == baseline, 'Machine route dry-run changed the monitor'
    assert run('machine', 'list') == registry, 'Machine registry changed during dry-runs'


def gui_wait_layout_readback(state, label):
    input_titles = {'hdmi1': 'HDMI 1', 'hdmi2': 'HDMI 2', 'dp': 'DisplayPort', 'usbc': 'USB-C'}
    selected = (f"Selected layout: {input_titles[state['source1']]} left, "
                f"{input_titles[state['source2']]} right") if state['mode'] == 'pbp' \
        else f"Selected layout: {input_titles[state['source1']]} full screen"
    return gui_wait_for(label, lambda tree: selected in tree and 'Read back from monitor' in tree,
                        failed=('Refresh before trying again.',), timeout=15)


def restore_machine_layout(baseline, owned):
    current = read_state('status')
    if current == baseline:
        return current
    if current != owned:
        raise RuntimeError('Monitor changed outside the machine route exercise; refusing to overwrite it')
    # Exercise entry requires distinct saved inputs and coupled secondary fields,
    # allowing the public layout commands to reproduce every baseline field.
    gui_errors = []
    intermediate = copy.deepcopy(baseline)
    intermediate['mode'] = 'pbp'
    try:
        result = run('pbp', 'on', '--left', baseline['source1'], '--right', baseline['source2'])
        assert result['after'] == intermediate and result['verified']
    except Exception:
        # A failed immediate response may follow a completed USB write. Continue
        # cleanup only when independent readback proves the exact planned step.
        if read_state('status') != intermediate:
            raise
    if args.gui:
        # The CLI notification starts the app's own USB read. Observe its new
        # state before acquiring the lock for our independent cleanup check.
        try:
            gui_wait_layout_readback(intermediate, 'gui-machine-restore-pbp-notified')
        except Exception as error:
            gui_errors.append(str(error))
    if baseline['mode'] == 'off':
        assert read_state('status') == intermediate, 'Monitor changed during restoration'
        try:
            result = run('fullscreen', baseline['source1'])
            assert result['after'] == baseline and result['verified']
        except Exception:
            if read_state('status') != baseline:
                raise
        if args.gui:
            try:
                gui_wait_layout_readback(baseline, 'gui-machine-restore-fullscreen-notified')
            except Exception as error:
                gui_errors.append(str(error))
    final = read_state('status')
    assert final == baseline, 'Machine route restore differs from the full baseline'
    if gui_errors:
        # UI evidence failure must not interrupt owned hardware restoration.
        raise RuntimeError('Monitor baseline restored, but GUI notification verification failed: '
                           + '; '.join(gui_errors))
    return final


def exercise_machine_routes(machine_id):
    registry = run('machine', 'list')
    matches = [machine for machine in registry['machines'] if machine['id'] == machine_id]
    assert len(matches) == 1, 'Unknown machine ID for the route exercise'
    machine = matches[0]
    if args.gui:
        assert sum(m['name'] == machine['name'] for m in registry['machines']) == 1, \
            'GUI route exercise requires an unambiguous machine name'
    preference = None
    if args.gui:
        gui_machines('gui-machine-routing-preference', registry)
        preference = gui_follow_usb(False)
    try:
        baseline = read_state('status')
        assert baseline['mode'] in ('off', 'pbp') and baseline['source1'] != baseline['source2'] \
            and baseline['pipInput'] == baseline['source2'], \
            'Machine route exercise requires distinct saved inputs, no active PIP, and coupled secondary fields for exact restoration'
        results = summary.setdefault('machineRoutes', [])
        for route in ('fullscreen', 'pbp-left', 'pbp-right'):
            assert read_state('status') == baseline and run('machine', 'list') == registry, 'State changed before routing'
            owned = predict_machine_route(machine, route, baseline)
            plan = run('machine', route, machine_id, '--dry-run')
            assert plan['before'] == baseline and plan['target'] == owned and not plan['verified']
            record = {'machineID': machine_id, 'route': route, 'baseline': baseline, 'planned': owned}
            results.append(record)
            try:
                if args.gui:
                    gui_machines('gui-before-machine-' + route, registry)
                    assert run('machine', 'list') == registry and read_state('status') == baseline
                    label = {'fullscreen': 'full screen', 'pbp-left': 'on left', 'pbp-right': 'on right'}[route]
                    gui_click('Show ' + machine['name'] + ' ' + label)
                    gui_snapshot('gui-machine-' + route + '-busy', screenshot=True)
                    gui_ready('gui-machine-' + route + '-applied')
                    applied = read_state('status')
                else:
                    result = run('machine', route, machine_id)
                    assert result['before'] == baseline and result['target'] == owned and result['verified']
                    applied = result['after']
                assert applied == owned and read_state('status') == owned, 'Machine route differs from independent prediction'
                record['applied'] = applied
            except Exception as error:
                record['error'] = str(error)
                raise
            finally:
                record['final'] = restore_machine_layout(baseline, owned)
                record['restored'] = record['final'] == baseline
            if args.gui:
                # The restoring CLI must notify the open app after releasing USB.
                # Do not click Refresh until this changed preview has been observed.
                gui_wait_layout_readback(baseline, 'gui-machine-' + route + '-notified')
                record['cliNotificationObserved'] = True
                gui_machines('gui-machine-' + route + '-restored', registry)

    finally:
        if preference is not None:
            assert gui_follow_usb() is False, 'Fullscreen USB preference changed outside the exercise'
            gui_follow_usb(preference)

def parse_cpu_time(value):
    parts = value.split(':')
    if len(parts) not in (2, 3):
        raise ValueError('Unexpected ps CPU time: ' + value)
    seconds = float(parts[-1])
    minutes = int(parts[-2])
    hours = int(parts[0]) if len(parts) == 3 else 0
    if not math.isfinite(seconds) or not 0 <= seconds < 60 or minutes < 0 or hours < 0 \
            or (len(parts) == 3 and minutes >= 60):
        raise ValueError('Unexpected ps CPU time: ' + value)
    return hours * 3600 + minutes * 60 + seconds


def profile_gui_idle(seconds):
    global gui_window
    assert gui_owned and owns_gui_process(), 'Idle profiling requires the owned GUI process'
    monitor_before = read_state('status')
    gui_close_controls()
    windows = cua.call('list_windows', pid=gui_pid)['windows']
    (output / 'gui-idle-closed-windows.json').write_text(json.dumps(windows, indent=2) + '\n')
    assert not any(w['window_id'] == gui_window and w.get('is_on_screen') for w in windows), \
        'Owned controls panel did not close for idle profiling'
    samples = []
    profile = {'pid': gui_pid, 'requestedSeconds': seconds, 'samples': samples, 'verdict': 'INCONCLUSIVE'}
    summary['idleProfile'] = profile
    started = time.monotonic()
    deadline = started + seconds
    while True:
        assert owns_gui_process(), 'Owned GUI process exited or changed during idle profiling'
        usage = subprocess.run(['ps', '-p', str(gui_pid), '-o', 'time=,rss='],
                               capture_output=True, text=True, timeout=5, check=True)
        fields = usage.stdout.split()
        assert len(fields) == 2, 'Unexpected ps CPU/RSS result'
        sample = {'elapsedSeconds': round(time.monotonic() - started, 3),
                  'cpuSeconds': parse_cpu_time(fields[0]), 'rssKiB': int(fields[1])}
        assert sample['rssKiB'] > 0
        samples.append(sample)
        event = {'action': ['gui-idle-sample', gui_pid], **sample}
        with (output / 'actions.jsonl').open('a') as f:
            f.write(json.dumps(event) + '\n')
        (output / 'idle-samples.json').write_text(json.dumps(samples, indent=2) + '\n')
        print(json.dumps(event), flush=True)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(5, remaining))
    elapsed = samples[-1]['elapsedSeconds'] - samples[0]['elapsedSeconds']
    cpu_delta = samples[-1]['cpuSeconds'] - samples[0]['cpuSeconds']
    assert elapsed > 0 and cpu_delta >= 0, 'Idle process counters did not advance monotonically'
    profile.update(elapsedSeconds=elapsed, cpuDeltaSeconds=round(cpu_delta, 3),
                   cpuPercentOneCore=round(100 * cpu_delta / elapsed, 3),
                   rssMinKiB=min(s['rssKiB'] for s in samples), rssMaxKiB=max(s['rssKiB'] for s in samples))
    assert owns_gui_process(), 'Owned GUI process changed before reopening'
    reopened = cua.call('launch_app', bundle_id='com.danielsivan.msi-screen.menu', urls=['msi-screen://controls'])
    assert reopened['pid'] == gui_pid, 'Idle profile reopened a different app process'
    windows = reopened.get('windows') or cua.call('list_windows', pid=gui_pid)['windows']
    gui_window = next((w['window_id'] for w in windows if w.get('title') == 'MSI Screen'), gui_window)
    gui_ready('gui-idle-reopened')
    assert read_state('status') == monitor_before, 'Monitor changed during idle profiling'
    profile['verdict'] = 'MEASURED'
    (output / 'idle-profile.json').write_text(json.dumps(profile, indent=2) + '\n')


def read_linux_usb(machine, label):
    """Fixed read-only SSH probe: USB IDs plus companion status, never input events."""
    host = machine['host']
    assert re.fullmatch(r'[A-Za-z0-9._-]{1,128}', host) and not host.startswith('-')
    script = '''import json, pathlib, subprocess
p = pathlib.Path('/sys/bus/usb/devices')
devices = []
for d in sorted(p.iterdir()):
    try:
        vendor = (d / 'idVendor').read_text().strip().lower()
        product = (d / 'idProduct').read_text().strip().lower()
    except OSError:
        continue
    devices.append({'path': d.name, 'vendor': vendor, 'product': product})
helper = pathlib.Path.home() / '.local/share/msi-screen-control/msi-screen-kvm'
r = subprocess.run([str(helper)], input='{"schemaVersion":1,"action":"status"}', text=True,
                   capture_output=True, timeout=15)
if len(r.stdout.encode()) > 65536:
    raise RuntimeError('Companion status exceeded 64 KiB')
print(json.dumps({'devices': devices, 'companionExitCode': r.returncode,
                  'companion': json.loads(r.stdout)}))
'''
    command = ['/usr/bin/ssh', '-T', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
               '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=8',
               '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2', '-o', 'LogLevel=ERROR',
               '--', host, 'python3 -c ' + shlex.quote(script)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        raise RuntimeError('Linux USB status failed: ' + result.stderr[-2048:])
    observed = json.loads(result.stdout)
    assert isinstance(observed['devices'], list) and isinstance(observed['companion'], dict)
    event = {'action': ['linux-usb-status', machine['id'], label], 'result': observed}
    with (output / 'actions.jsonl').open('a') as f:
        f.write(json.dumps(event) + '\n')
    (output / ('kvm-linux-' + label + '.json')).write_text(json.dumps(observed, indent=2) + '\n')
    print(json.dumps(event), flush=True)
    return observed


def usb_count(observed, identifier):
    vendor, product = identifier.split(':')
    return sum(d['vendor'] == vendor and d['product'] == product for d in observed['devices'])


def validate_kvm_status(state, registry, machine):
    assert state['schemaVersion'] == 1 and state['model'] == 'MD342CQP' and state['protocolVersion'] == 'V20'
    assert state['route'] in ('usbc', 'upstream', 'auto')
    local = [m for m in registry['machines'] if m['platform'] == 'macos' and m.get('host') is None]
    assert len(local) == 1 and local[0]['input'] == 'usbc', 'This Mac must be assigned to USB-C'
    expected_id = local[0]['id'] if state['controlHost'] == 'local' else machine['id']
    assert state['controlHost'] in ('local', 'upstream') and state.get('machineID') == expected_id
    return state


def gui_show_controls(labels, prefix, bottom_margin=24):
    """Ground background wheel scrolling on fresh window and control frames."""
    previous_frames = None
    unchanged_scrolls = 0
    for attempt in range(10):
        state = gui_snapshot(prefix + '-visible-' + str(attempt), screenshot=True)
        elements = state.get('elements', [])
        controls = [e for e in elements if e.get('label') in labels and e.get('frame')]
        assert len(controls) == len(labels) and {e['label'] for e in controls} == labels, 'Controls are missing or ambiguous'
        tabs = [e['frame'] for e in elements if e.get('label') in ('Layout', 'Monitor', 'Machines', 'Peripherals')
                and e.get('role') in ('AXButton', 'AXRadioButton') and e.get('frame')]
        footer = next(e['frame'] for e in elements
                      if e.get('label') in ('Refresh monitor', 'Refresh peripheral controls') and e.get('frame'))
        bounds = state['window_bounds']
        assert tabs and bounds['width'] > 0
        top = max(f['y'] + f['h'] for f in tabs) + 12
        bottom = footer['y'] - 20
        low = min(e['frame']['y'] for e in controls)
        high = max(e['frame']['y'] + e['frame']['h'] for e in controls)
        assert bottom - top > 100, 'No usable controls viewport'
        if low >= top + 28 and high <= bottom - bottom_margin:
            return gui_snapshot(prefix + '-controls-visible', screenshot=True)
        frames = (top, bottom, tuple(sorted((e['label'], tuple(sorted(e['frame'].items())))
                                           for e in controls)))
        unchanged_scrolls = unchanged_scrolls + 1 if frames == previous_frames else 0
        previous_frames = frames
        if unchanged_scrolls >= 2:
            # A preferred result margin may be impossible at the content edge.
            # Keep a real clipping guard instead of repeatedly scrolling an
            # already visible control that cannot move farther into the view.
            if low >= top + 8 and high <= bottom - 8:
                return gui_snapshot(prefix + '-controls-visible', screenshot=True)
            raise RuntimeError('Controls remain clipped after scrolling stopped; no action attempted')
        # The observed content viewport lies between the tabs and footer. Send
        # wheel events to its center; never scroll at an offscreen control.
        scale = state.get('screenshot_scale', state['screenshot_width'] / bounds['width'])
        downward = high > bottom - bottom_margin
        distance = high - (bottom - bottom_margin) if downward else top + 28 - low
        result = cua.call('scroll', pid=gui_pid, window_id=gui_window,
                          x=state['screenshot_width'] / 2,
                          y=((top + bottom) / 2 - bounds['y']) * scale,
                          direction='down' if downward else 'up',
                          by='line', amount=6 if distance > 150 else 2, delivery_mode='background')
        event = {'action': ['gui-scroll-controls', prefix, attempt], 'result': result}
        with (output / 'actions.jsonl').open('a') as f:
            f.write(json.dumps(event) + '\n')
        print(json.dumps(event), flush=True)
        if result.get('effect') == 'refused':
            raise RuntimeError(result)
        time.sleep(0.2)
    raise RuntimeError('Controls did not become visible; no action attempted')


def gui_kvm_change(machine, target, before_action=None):
    label = 'USB-C Mac' if target == 'usbc' else 'USB-B ' + machine['name']
    # Cua omits the disabled current-host button from actionable elements.
    gui_show_controls({label, 'Refresh USB route'}, 'gui-kvm', bottom_margin=100)
    title = 'USB-C' if target == 'usbc' else 'USB-B upstream'
    gui_click(label, 'AXButton', before_action=before_action)
    gui_snapshot('gui-kvm-' + target + '-busy', screenshot=True)
    gui_wait_for('gui-kvm-' + target + '-verified',
                 lambda tree: 'USB route verified: ' + title + '.' in tree,
                 failed=('usb-route-error',), timeout=55)


def exercise_kvm_roundtrip(machine_id):
    """Exactly one outbound request and at most one observed-owned return request."""
    global kvm_local_safe
    registry = run('machine', 'list')
    matches = [m for m in registry['machines'] if m['id'] == machine_id]
    assert len(matches) == 1 and matches[0]['platform'] == 'linux' and matches[0].get('host'), \
        'KVM exercise requires one saved Linux machine with an SSH host'
    machine = matches[0]
    if args.gui:
        assert [m['id'] for m in registry['machines'] if m['platform'] == 'linux'] == [machine_id], \
            'GUI KVM exercise requires exactly one configured Linux USB-B machine'
    def status():
        return validate_kvm_status(read_state('kvm', 'status', '--machine', machine_id, timeout=60), registry, machine)
    original = status()
    assert original['route'] == 'usbc' and original['controlHost'] == 'local', \
        'KVM roundtrip must start with verified USB-C and a local MSI controller'
    video_before = read_state('status')
    linux_before = read_linux_usb(machine, 'before')
    assert linux_before['companionExitCode'] == 0 and not linux_before['companion'].get('error'), \
        'Linux companion status must work before moving USB'
    peripherals = args.expect_usb
    proof = {'machineID': machine_id, 'baseline': original, 'videoBaseline': video_before,
             'linuxBefore': linux_before, 'expectedUSBDevices': peripherals,
             'peripheralEvents': 'not exercised', 'restored': False}
    summary['kvmRoundtrip'] = proof
    plan = run('kvm', 'set', 'upstream', '--expected', 'usbc', '--machine', machine_id, '--dry-run', timeout=60)
    assert plan['before'] == original and plan['target'] == 'upstream' and plan['dryRun'] \
        and not plan['verified'] and not plan['writeAttempted'] and plan.get('after') is None
    assert status() == original and read_state('status') == video_before
    if args.gui:
        gui_machines('gui-kvm-machines', registry)
        gui_click('Peripherals', 'AXButton')
        gui_show_controls({'Refresh USB route'}, 'gui-kvm-peripherals', bottom_margin=100)
        gui_click('Refresh USB route', 'AXButton')
        _, proof['peripheralsSelector'] = gui_read_usb_selector('gui-kvm-peripherals-ready', original, registry)
    attempted = False
    return_attempted = False
    owned = None
    try:
        assert run('machine', 'list') == registry and status() == original, 'State changed before the KVM exercise'
        kvm_local_safe = False  # Until an independent local return read proves availability.
        if args.gui:
            def mark_attempt():
                nonlocal attempted
                attempted = True
            gui_kvm_change(machine, 'upstream', before_action=mark_attempt)
        else:
            attempted = True
            changed = run('kvm', 'set', 'upstream', '--expected', 'usbc', '--machine', machine_id,
                          success=None, timeout=90)
            proof['outboundResult'] = changed
            if not changed.get('writeAttempted'):
                attempted = False
                raise RuntimeError('No outbound KVM write was reported; status will be inspected without sending it again')
            # An immediate ACK or unverified receipt is not the verdict. The
            # independent status below must observe the explicit target.
        owned = status()
        assert owned['route'] == 'upstream', 'Fresh status did not observe USB-B upstream'
        proof['upstream'] = owned
        linux_after = read_linux_usb(machine, 'upstream')
        proof['linuxUpstream'] = linux_after
        # Destination controller and receiver enumeration are independent
        # evidence in addition to the configured route readback.
        helper = linux_after['companion']
        controller_count = usb_count(linux_after, '1462:3fa4')
        proof['linuxControllerCount'] = controller_count
        if owned['controlHost'] == 'upstream':
            assert controller_count == 1, 'Upstream control host requires exactly one enumerated MSI controller on Linux'
        if controller_count:
            assert helper.get('present') and helper.get('accessible') and helper.get('verified') \
                and helper.get('state', {}).get('kvm') == 'upstream', 'Enumerated Linux controller lacks verified route readback'
        else:
            assert helper.get('present') is False, 'Linux USB enumeration and companion presence disagree'
        for peripheral in peripherals:
            assert usb_count(linux_after, peripheral) > usb_count(linux_before, peripheral), \
                'Expected USB device did not newly enumerate on Linux: ' + peripheral
        proof['expectedDevicesEnumeratedOnLinux'] = list(peripherals)
    except Exception as error:
        proof['exerciseError'] = str(error)
        raise
    finally:
        # A nonzero or missing response can follow a successful switch. Read
        # once afresh; never repeat the outbound request or guess its result.
        current = status()
        if current == original:
            kvm_local_safe = True
        elif attempted and current['route'] == 'upstream':
            if owned is not None and current != owned:
                raise RuntimeError('KVM control ownership changed after our observation; refusing to restore')
            assert run('machine', 'list') == registry, 'Machine assignments changed; refusing KVM cleanup'
            proof['returnExpected'] = current
            return_attempted = True
            return_error = None
            try:
                if args.gui:
                    # Return through Machines to exercise both presentations of
                    # the shared host selector in one owned roundtrip.
                    gui_click('Machines', 'AXButton')
                    gui_kvm_change(machine, 'usbc')
                else:
                    proof['returnResult'] = run('kvm', 'set', 'usbc', '--expected', 'upstream',
                                               '--machine', machine_id, success=None, timeout=90)
            except Exception as error:
                return_error = str(error)
            final = status()
            proof['final'] = final
            if final == original:
                kvm_local_safe = True
            if return_error:
                proof['returnActionError'] = return_error
            if not kvm_local_safe:
                raise RuntimeError('USB-C return was not independently verified; no return request was resent')
        else:
            raise RuntimeError('Unexpected KVM route after the exercise; refusing to overwrite it')
        proof['returnAttempted'] = return_attempted
        proof['restored'] = kvm_local_safe
        proof['final'] = status()
        assert proof['final'] == original
        proof['videoFinal'] = read_state('status')
        assert proof['videoFinal'] == video_before, 'KVM roundtrip changed the monitor video layout'
        linux_final = read_linux_usb(machine, 'returned')
        proof['linuxFinal'] = linux_final
        for peripheral in peripherals:
            assert usb_count(linux_final, peripheral) == usb_count(linux_before, peripheral), \
                'Expected USB device count did not return to baseline on Linux: ' + peripheral
        if proof.get('returnActionError'):
            raise RuntimeError('USB-C baseline restored, but GUI return verification failed: ' + proof['returnActionError'])


def validate_peripherals(snapshot, usb):
    assert snapshot['schemaVersion'] == 1 and isinstance(snapshot['hostName'], str) and snapshot['hostName']
    assert snapshot['platform'] == ('macos' if usb['controlHost'] == 'local' else 'linux')
    assert datetime.datetime.fromisoformat(snapshot['checkedAt'].replace('Z', '+00:00')).tzinfo is not None
    assert isinstance(snapshot['monitorHubPresent'], bool)
    receivers = snapshot['receivers']
    assert len(receivers) == 2 and {r['id'] for r in receivers} == {'bolt', 'rapoo'}
    for receiver in receivers:
        assert receiver['connection'] in ('monitorHub', 'elsewhere', 'notDetected')
        assert receiver['connection'] != 'monitorHub' or snapshot['monitorHubPresent']
        paired = receiver['pairedDevices']
        assert not paired or (receiver['id'] == 'bolt' and receiver['connection'] == 'monitorHub')
        assert len(paired) <= 6 and len({p['slot'] for p in paired}) == len(paired)
        for device in paired:
            assert 1 <= device['slot'] <= 6 and re.fullmatch(r'[0-9A-Fa-f]{4}', device['wirelessProductID'])
            assert device['kind'] in ('keyboard', 'mouse', 'other')
            assert device['radio'] in ('responding', 'notResponding', 'unavailable')
            assert device['radio'] == 'responding' or device.get('protocolVersion') is None
    return snapshot


def validate_pointer_descriptor(descriptor):
    assert descriptor['schemaVersion'] == 1 and descriptor['receiver'] == 'rapoo'
    assert descriptor['connection'] in ('monitorHub', 'elsewhere', 'notDetected')
    assert descriptor['access'] in ('granted', 'denied', 'unknown')
    assert datetime.datetime.fromisoformat(descriptor['checkedAt'].replace('Z', '+00:00')).tzinfo is not None
    seen = set()
    for usage in descriptor['usages']:
        pair = (usage['usagePage'], usage['usage'])
        kind = {(1, 0x30): 'x', (1, 0x31): 'y', (1, 0x38): 'verticalWheel',
                (12, 0x238): 'horizontalWheel'}.get(pair)
        if pair[0] == 9 and 1 <= pair[1] <= 32:
            kind = 'button'
        assert kind is not None and usage['kind'] == kind, 'Unexpected non-pointer HID usage'
        assert pair not in seen and isinstance(usage['relative'], bool)
        assert isinstance(usage['logicalMin'], int) and isinstance(usage['logicalMax'], int)
        seen.add(pair)
    return descriptor


def inspect_peripheral_details(snapshot, usb, options, probe):
    proof = {}
    if usb['controlHost'] == 'local':
        descriptor = validate_pointer_descriptor(run('peripherals', 'describe'))
        proof['pointerDescriptor'] = descriptor
        result = run('peripherals', 'mouse', success=None, timeout=30)
        if result.get('verified') is False:
            assert isinstance(result.get('error'), str) and result['error']
        else:
            assert result['schemaVersion'] == 1 and result['platform'] == 'macos'
            assert result['hostName'] == snapshot['hostName']
            assert result['model'] == 'MT760 Pro / MT760 NL' and result['receiver'] == '24ae:186a'
            assert datetime.datetime.fromisoformat(result['checkedAt'].replace('Z', '+00:00')).tzinfo is not None
            assert isinstance(result['errors'], list) and all(isinstance(e, str) for e in result['errors'])
            for key in ('dongleFirmware', 'mouseFirmware'):
                assert result.get(key) is None or (isinstance(result[key], str) and result[key])
            if result.get('batteryPercent') is not None:
                assert type(result['batteryPercent']) is int and 0 <= result['batteryPercent'] <= 100
            if result.get('batteryStatusRaw') is not None:
                assert type(result['batteryStatusRaw']) is int and 0 <= result['batteryStatusRaw'] <= 255
            mappings = result['sideWheelMappings']
            assert isinstance(mappings, list) and len(mappings) <= 2
            keys = [m['keyID'] for m in mappings]
            assert len(set(keys)) == len(keys) and all(type(key) is int and key in (7, 8) for key in keys)
            for mapping in mappings:
                assert mapping.get('direction') in (None, 'horizontalNegative', 'horizontalPositive')
                assert mapping['function'] in ('horizontalScroll', 'defaultHorizontalScroll', 'verticalScroll',
                                               'appSwitchPrevious', 'appSwitchNext', 'disabled', 'unknown')
                assert re.fullmatch(r'[0-9A-Fa-f]{8}', mapping['rawRecordHex']), 'Side-wheel record must contain four raw bytes'
                assert mapping.get('logicalType') is None or (type(mapping['logicalType']) is int and mapping['logicalType'] >= 0)
            if not result['errors']:
                assert set(keys) == {7, 8}, 'A complete mouse read omitted a side-wheel direction'
        proof['mouseDetails'] = result
        if probe:
            result = run('peripherals', 'probe', '--seconds', '1', success=None, timeout=20)
            if result.get('verified') is False:
                assert isinstance(result.get('error'), str) and result['error']
            else:
                assert result['schemaVersion'] == 1 and result['requestedSeconds'] == 1
                assert 0 <= result['elapsedSeconds'] <= 5, 'One-second pointer capture exceeded its bound'
                assert isinstance(result['completed'], bool) and isinstance(result['disconnected'], bool)
                observed = validate_pointer_descriptor(result['descriptor'])
                assert [c['descriptor'] for c in result['counts']] == observed['usages']
                for count in result['counts']:
                    assert all(type(count[key]) is int and count[key] >= 0 for key in
                               ('samples', 'nonzeroSamples', 'positiveSamples', 'negativeSamples'))
                    assert count['positiveSamples'] + count['negativeSamples'] == count['nonzeroSamples'] <= count['samples']
                if result['completed']:
                    assert not result['disconnected'] and not result.get('error') and result['elapsedSeconds'] >= 0.8
                else:
                    assert result.get('error'), 'Incomplete capture must explain why it stopped'
            proof['pointerProbe'] = result
    else:
        proof['pointerDescriptorSkipped'] = 'Pointer metadata and capture run on this Mac; USB is owned by Linux.'
        proof['mouseDetailsSkipped'] = 'Rapoo battery/firmware/side-wheel getters run on this Mac; USB is owned by Linux.'
        if probe:
            proof['pointerProbeSkipped'] = proof['pointerDescriptorSkipped']
    bolt = next(r for r in snapshot['receivers'] if r['id'] == 'bolt')
    candidates = [p for p in bolt['pairedDevices'] if p['kind'] == 'keyboard'
                  and p.get('name') in ('POP Keys', 'Logi POP Keys') and p['wirelessProductID'].upper() == 'B365']
    if candidates:
        paired = next((p for p in candidates if p['radio'] == 'responding'), candidates[0])
        result = run('peripherals', 'keyboard', '--slot', str(paired['slot']), *options, success=None, timeout=60)
        if result.get('verified') is False:
            assert isinstance(result.get('error'), str) and result['error']
        else:
            assert result['schemaVersion'] == 1 and result['slot'] == paired['slot']
            assert result['wirelessProductID'].upper() == paired['wirelessProductID'].upper()
            assert result['platform'] == snapshot['platform'] and result['hostName'] == snapshot['hostName']
            assert result['name'] in ('POP Keys', 'Logi POP Keys')
            assert datetime.datetime.fromisoformat(result['checkedAt'].replace('Z', '+00:00')).tzinfo is not None
            assert all(isinstance(result[key], list) for key in ('features', 'firmware', 'controls', 'errors'))
            assert all(isinstance(result[key], bool) for key in ('featureInventoryComplete', 'controlInventoryComplete'))
            if (result.get('battery') or {}).get('percentage') is not None:
                assert 0 <= result['battery']['percentage'] <= 100
        # An asleep keyboard may return an error or partial inventory; preserve
        # that result rather than claiming battery/mappings were read.
        proof['keyboardDetails'] = result
    else:
        proof['keyboardDetailsSkipped'] = 'No recognized POP Keys receiver pairing was reported.'
    return proof


def gui_peripheral_sections(tree):
    # Cua flattens SwiftUI groups and omits static-row identifiers. The actual
    # device headers provide unambiguous scopes for otherwise repeated labels.
    mouse = 'AXStaticText = "MT760 Pro"'
    keyboard = 'AXStaticText = "POP Keys"'
    assert tree.count(mouse) == tree.count(keyboard) == 1, 'Peripheral headers are missing or ambiguous'
    assert tree.index(mouse) < tree.index(keyboard), 'Peripheral section order changed'
    return {'rapoo': tree.split(mouse, 1)[1].split(keyboard, 1)[0],
            'bolt': tree.split(keyboard, 1)[1]}


def gui_peripheral_texts(section):
    return [json.loads(match.group(1)) for line in section.splitlines()
            if (match := re.search(r'\bAXStaticText = ("(?:[^"\\]|\\.)*")', line))]


def gui_usb_host_selector(state, usb, registry):
    """Check both destinations without clicking a host or inferring physical input."""
    tree = state.get('tree_markdown', '')
    local = [m for m in registry['machines'] if m.get('host') is None
             and m['platform'] == 'macos' and m['input'] == 'usbc']
    linux = [m for m in registry['machines'] if m['platform'] == 'linux']
    configured = len(local) == len(linux) == 1
    labels = {'usbc': 'USB-C Mac', 'upstream': 'USB-B ' + (linux[0]['name'] if len(linux) == 1 else 'Linux')}
    titles = {'usbc': 'USB-C', 'upstream': 'USB-B upstream', 'auto': 'Auto (follow video)'}
    # Cua exposes IDs for actionable controls, but SwiftUI static text IDs
    # can be omitted. Compare the exact rendered route text instead.
    route_text = 'AXStaticText = ' + json.dumps(titles[usb['route']])
    rows = [line for line in tree.splitlines() if line.strip() == '- ' + route_text]
    assert len(rows) == 1, \
        'USB selector route differs from independent CLI readback'
    enabled = []
    for route, label in labels.items():
        rows = [line for line in tree.splitlines() if 'AXButton' in line and '(' + label + ')' in line]
        assert len(rows) == 1, 'USB selector destination is missing or ambiguous: ' + label
        assert ('Current USB host' in rows[0]) == (usb['route'] == route), \
            'USB selector current-host indicator differs: ' + label
        actionable = [e for e in state.get('elements', []) if e.get('role') == 'AXButton'
                      and e.get('label') == label and e.get('enabled', True)]
        assert len(actionable) <= 1, 'USB selector action is ambiguous: ' + label
        expected = configured and usb['route'] != route
        assert bool(actionable) == expected, 'USB selector enabled state differs: ' + label
        if actionable:
            enabled.append(route)
    assert 'All devices on the monitor’s USB hub move together.' in tree
    return {'currentRoute': usb['route'], 'destinations': list(labels), 'enabledDestinations': enabled,
            'wholeHub': True, 'access': 'read-only'}


def gui_read_usb_selector(label, usb, registry):
    deadline = time.monotonic() + 55
    while True:
        state = gui_snapshot(label)
        ready = any(e.get('role') == 'AXButton' and e.get('label') == 'Refresh USB route'
                    and e.get('enabled', True) for e in state.get('elements', []))
        if ready:
            proof = gui_usb_host_selector(state, usb, registry)
            gui_snapshot(label + '-verified', screenshot=True)
            return state, proof
        tree = state.get('tree_markdown', '')
        if 'usb-route-error' in tree or time.monotonic() >= deadline:
            raise RuntimeError('USB host selector did not finish its read')
        time.sleep(0.2)


def gui_inspect_peripheral_details(snapshot, usb, proof, probe, controller_probe=False):
    gui_click('Peripherals', 'AXButton')
    state = gui_wait_for('gui-peripheral-screen', lambda tree:
                         'AXButton = "Selected" (Peripherals)' in tree and 'Your peripherals' in tree
                         and 'AXStaticText = "MT760 Pro"' in tree and 'AXStaticText = "POP Keys"' in tree
                         and 'Checked on ' in tree and 'Checking…' not in tree
                         and ('Declared HID controls' in tree or usb['controlHost'] != 'local'), timeout=55)
    state, host_selector = gui_read_usb_selector('gui-peripherals-host', usb, run('machine', 'list'))
    sections = gui_peripheral_sections(state.get('tree_markdown', ''))
    for receiver in snapshot['receivers']:
        rows = [text for text in gui_peripheral_texts(sections[receiver['id']]) if text.startswith('Receiver, ')]
        expected = {'monitorHub': 'Monitor hub', 'elsewhere': 'Detected outside monitor hub',
                    'notDetected': 'Not detected'}[receiver['connection']]
        assert len(rows) == 1 and rows[0].startswith('Receiver, ' + expected), 'Peripheral detail connection differs from CLI'
    descriptor = proof.get('pointerDescriptor')
    if descriptor is not None:
        texts = gui_peripheral_texts(sections['rapoo'])
        assert 'Declared HID controls' in texts
        for kind, title in [('horizontalWheel', 'Side wheel'), ('verticalWheel', 'Main wheel')]:
            present = any(u['kind'] == kind for u in descriptor['usages'])
            assert (title if present else title + ' not declared') in texts, 'Displayed HID capability differs from descriptor'
        assert str(sum(u['kind'] == 'button' for u in descriptor['usages'])) + ' buttons' in texts
    gui_proof = {'screenPresent': True, 'inputEvents': 'not exercised',
                 'usbHostSelector': host_selector}
    gui_show_controls({'Refresh game controllers'}, 'gui-game-controllers')
    gui_click('Refresh game controllers', 'AXButton')
    controller_state = gui_wait_for('gui-game-controllers-read', lambda tree:
        'Game controllers' in tree and 'This Mac · Bluetooth & USB' in tree
        and ('No controller detected on this Mac.' in tree or 'Recognized by macOS' in tree
             or 'game mode unsupported' in tree))
    controllers = run('peripherals', 'controllers')
    assert all(device['name'] in controller_state['tree_markdown'] for device in controllers['devices'])
    gui_snapshot('gui-game-controllers-result', screenshot=True)
    gui_proof['localControllers'] = controllers
    if controller_probe and controllers['profiles']:
        gui_show_controls({'Test controls · 10s'}, 'gui-controller-test', bottom_margin=60)
        gui_click('Test controls · 10s', 'AXButton')
        active = gui_wait_for('gui-controller-test-active', lambda tree:
                             'Press buttons and move both sticks. Listening for 10 seconds…' in tree)
        gui_snapshot('gui-controller-test-active', screenshot=True)
        result = gui_wait_for('gui-controller-test-ended', lambda tree:
                             'Listening for 10 seconds…' not in tree
                             and ('No input observed. This test is inconclusive.' in tree
                                  or re.search(r'\d+ changes across \d+ controls\.', tree)), timeout=20)
        texts = gui_peripheral_texts(result['tree_markdown'])
        gui_proof['controllerProbe'] = {
            'activeStateObserved': bool(active),
            'result': next(text for text in texts if text == 'No input observed. This test is inconclusive.'
                           or re.fullmatch(r'\d+ changes across \d+ controls\.', text)),
        }
        gui_snapshot('gui-controller-test-result', screenshot=True)
    elif controller_probe:
        gui_proof['controllerProbeSkipped'] = 'No native game controller connected to this Mac.'

    def enabled(state, label):
        matches = [e for e in state.get('elements', [])
                   if e.get('label') == label and e.get('role') == 'AXButton' and e.get('enabled', True)]
        assert len(matches) <= 1, 'Ambiguous peripheral action: ' + label
        return bool(matches)

    def read_detail(kind, label, disclosure, prefix, end_marker):
        def region(state):
            section = gui_peripheral_sections(state.get('tree_markdown', ''))[kind]
            start = 'AXButton (' + label + ')'
            assert section.count(start) == 1 and end_marker in section, 'Peripheral action scope changed: ' + label
            return section.split(start, 1)[1].split(end_marker, 1)[0]
        before = gui_snapshot(prefix + '-before', screenshot=True)
        previous = region(before)
        if not enabled(before, label):
            return None
        # An owned fresh app has no device details before this explicit action.
        # Reject stale content instead of treating it as this action's result.
        assert not gui_peripheral_texts(previous) and disclosure not in previous, 'Pre-existing peripheral result: ' + label
        gui_show_controls({label}, prefix, bottom_margin=170 if kind == 'rapoo' else 100)
        gui_click(label, 'AXButton')
        started = time.monotonic()
        state = gui_snapshot(prefix + '-reading', screenshot=True)
        saw_busy = False
        while True:
            result = region(state)
            texts = gui_peripheral_texts(result)
            ready = enabled(state, label)
            saw_busy |= not ready
            has_details = '(' + disclosure + ')' in result
            # The result region is empty before the click. Newly visible text
            # without the detail disclosure is the displayed unavailable error.
            if ready and texts and (has_details or all(text != 'Reading…' for text in texts)):
                break
            if time.monotonic() - started > 35:
                raise RuntimeError('Peripheral read did not finish: ' + label)
            time.sleep(0.25)
            state = gui_snapshot(prefix + '-wait')
        if has_details:
            assert any(text == 'Battery' or text.startswith('Battery, ') for text in texts), 'Battery result row missing'
            if kind == 'bolt':
                assert any(text.startswith('Receiver slot ') for text in texts)
                assert any(text.startswith('Fn row, ') for text in texts), 'Fn-row result missing'
        gui_snapshot(prefix + '-result', screenshot=True)
        return {'resultPresent': has_details, 'errorPresent': not has_details,
                'busyObserved': saw_busy, 'displayedText': texts}, state

    gui_show_controls({'Features & device controls'}, 'gui-peripheral-mouse')
    mouse = read_detail('rapoo', 'Read mouse details', 'Firmware details', 'gui-rapoo',
                        'AXStaticText = "Side wheel on this Mac"')
    if mouse is None:
        gui_proof['mouseDetailsSkipped'] = 'Read mouse details requires the monitor-hub receiver on this Mac.'
    else:
        gui_proof['mouseDetails'], state = mouse
        if gui_proof['mouseDetails']['resultPresent']:
            gui_expand('Firmware details')
            state = gui_show_controls({'Firmware details'}, 'gui-rapoo-firmware', bottom_margin=100)
            texts = gui_peripheral_texts(gui_peripheral_sections(state.get('tree_markdown', ''))['rapoo'])
            assert any(text.startswith('Mouse firmware, ') for text in texts)
            assert any(text.startswith('Receiver firmware, ') for text in texts)
            gui_snapshot('gui-rapoo-details-result', screenshot=True)
            gui_expand('Firmware details', expanded=False)
            if '(Onboard side wheel)' in state.get('tree_markdown', ''):
                gui_expand('Onboard side wheel')
                gui_show_controls({'Onboard side wheel'}, 'gui-rapoo-sidewheel', bottom_margin=120)
                gui_snapshot('gui-rapoo-sidewheel-result', screenshot=True)
                gui_expand('Onboard side wheel', expanded=False)
    if probe:
        def test_texts(state):
            section = gui_peripheral_sections(state.get('tree_markdown', ''))['rapoo']
            return gui_peripheral_texts(section.split('AXStaticText = "Wheels & buttons"', 1)[1]
                                        .split('(Features & device controls)', 1)[0])
        state = gui_snapshot('gui-pointer-before')
        if enabled(state, 'Test mouse controls'):
            previous = test_texts(state)
            assert 'Tested' not in previous, 'Pre-existing pointer test result'
            gui_show_controls({'Test mouse controls'}, 'gui-pointer', bottom_margin=180)
            gui_click('Test mouse controls', 'AXButton')
            started = time.monotonic()
            state = gui_snapshot('gui-pointer-started', screenshot=True)
            progress = 'Move both wheels and press the mouse buttons. Only event counts are kept.'
            saw_progress = False
            while True:
                texts = test_texts(state)
                active = progress in texts
                saw_progress |= active
                new_texts = [text for text in texts if text not in previous and text not in (progress, 'Testing…')]
                has_result = 'Tested' in texts
                if not active and (has_result or new_texts):
                    break
                if time.monotonic() - started > 20:
                    raise RuntimeError('GUI mouse capture did not finish within its bounded interval')
                time.sleep(0.25)
                state = gui_snapshot('gui-pointer-wait')
            if has_result:
                assert all(any(text.startswith(title + ', ') for text in texts) for title in ('Side wheel', 'Main wheel', 'Buttons'))
                assert saw_progress, 'Mouse capture did not show its active state'
            gui_snapshot('gui-pointer-result', screenshot=True)
            gui_proof['pointerProbe'] = {'elapsedSeconds': round(time.monotonic() - started, 2),
                                        'activeStateObserved': saw_progress, 'resultPresent': has_result,
                                        'displayedText': new_texts}
            gui_proof['inputEvents'] = 'bounded aggregate capture; physical controls not exercised by verifier'
        else:
            gui_proof['pointerProbeSkipped'] = 'Mouse test unavailable in this app: inspect captured host/access/descriptor diagnostics.'
    gui_show_controls({'Setup & keyboard features'}, 'gui-peripheral-keyboard')
    keyboard = read_detail('bolt', 'Read keyboard details', 'Reported mappings & firmware', 'gui-pop',
                           'AXDisclosureTriangle (Setup & keyboard features)')
    if keyboard is None:
        gui_proof['keyboardDetailsSkipped'] = 'Read keyboard details is unavailable; receiver pairing metadata is required.'
    else:
        gui_proof['keyboardDetails'], state = keyboard
        if gui_proof['keyboardDetails']['resultPresent']:
            gui_expand('Reported mappings & firmware')
            gui_show_controls({'Reported mappings & firmware'}, 'gui-pop-details', bottom_margin=160)
            gui_snapshot('gui-pop-details-result', screenshot=True)
    return gui_proof


def inspect_peripherals(machine_id=None, label='peripherals', gui=False, details=False, probe=False,
                        controller_probe=False):
    options = ['--machine', machine_id] if machine_id else []
    before = read_state('kvm', 'status', *options, timeout=60)
    snapshot = validate_peripherals(run('peripherals', *options, timeout=60), before)
    detail_proof = inspect_peripheral_details(snapshot, before, options, probe) if details else None
    if detail_proof is not None:
        summary['peripheralDetails'] = detail_proof
        controllers = run('peripherals', 'controllers')
        assert controllers['schemaVersion'] == 1
        assert isinstance(controllers['devices'], list) and isinstance(controllers['profiles'], list)
        summary['localGameControllers'] = controllers
        if controller_probe and controllers['profiles']:
            result = run('peripherals', 'controller-test', '--seconds', '1', timeout=10)
            assert result['schemaVersion'] == 1 and result['durationSeconds'] == 1
            assert result['controllerNames'] and isinstance(result['changesByControl'], dict)
            assert all(isinstance(count, int) and count > 0 for count in result['changesByControl'].values())
            summary['controllerProbe'] = result
        elif controller_probe:
            summary['controllerProbeSkipped'] = 'No native game controller connected to this Mac.'
    if gui:
        registry = run('machine', 'list')
        gui_machines('gui-' + label + '-machines', registry)
        gui_show_controls({'Refresh USB route'}, 'gui-' + label, bottom_margin=150)
        gui_click('Refresh USB route', 'AXButton')
        deadline = time.monotonic() + 55
        while True:
            shown = gui_snapshot('gui-' + label + '-read')
            tree = shown.get('tree_markdown', '')
            ready = any(e.get('label') == 'Refresh USB route' and e.get('enabled', True)
                        for e in shown.get('elements', []))
            if ready and 'USB route read:' in tree and 'Not checked' not in tree:
                break
            if 'usb-route-error' in tree or 'peripheral-error' in tree or time.monotonic() >= deadline:
                raise RuntimeError('Peripheral GUI did not finish its owner-aware read')
            time.sleep(0.2)
        assert 'Keyboard & mouse' in tree
        # Compare connection facts, not inherently time-sensitive radio replies.
        for receiver in snapshot['receivers']:
            marker = 'receiver-' + receiver['id'] + '-status'
            prefix = 'Keyboard receiver: ' if receiver['id'] == 'bolt' else 'Mouse receiver: '
            # SwiftUI combined rows can export AXUnknown with the full label
            # but omit their identifier. This is the observed Cua representation.
            rows = [line for line in tree.splitlines() if 'id=' + marker in line
                    or re.search(r'\bAXUnknown \(' + re.escape(prefix), line)]
            assert len(rows) == 1, 'Receiver status is missing or ambiguous: ' + marker
            expected = {'notDetected': 'Receiver not detected', 'elsewhere': 'Outside monitor hub',
                        'monitorHub': 'Detected ·' if receiver['id'] == 'bolt' else 'Receiver detected'}[receiver['connection']]
            if receiver['connection'] == 'monitorHub' and receiver['id'] == 'bolt':
                pairings = sum(device['kind'] == 'keyboard' for device in receiver['pairedDevices'])
                if pairings > 1:
                    expected = str(pairings) + ' pairings ·'
            assert prefix + expected in rows[0], 'GUI receiver connection differs from the CLI snapshot'
        gui_snapshot('gui-' + label + '-verified', screenshot=True)
        summary['peripheralGUI'] = {'rowsPresent': True, 'inputEvents': 'not exercised'}
        if details:
            summary['peripheralDetailGUI'] = gui_inspect_peripheral_details(
                snapshot, before, detail_proof, probe, controller_probe)
    assert read_state('kvm', 'status', *options, timeout=60) == before, 'Peripheral inspection changed or lost USB ownership'
    (output / (label + '.json')).write_text(json.dumps(snapshot, indent=2) + '\n')
    summary[label] = snapshot
    return snapshot


def gui_follow_usb(enabled=None):
    gui_expand('Connection & input management')
    try:
        state = gui_snapshot('gui-follow-fullscreen-usb', screenshot=True)
        # Native switch style exports a separate static-text title; Cua uses
        # the checkbox's identifier as its actionable label in that layout.
        labels = {'Move USB with full screen', 'follow-fullscreen-usb'}
        matches = [e for e in state.get('elements', []) if e.get('label') in labels]
        assert len(matches) == 1 and str(matches[0].get('value')) in ('0', '1'), 'Fullscreen USB toggle is missing or ambiguous'
        current = str(matches[0]['value']) == '1'
        if enabled is not None and current != enabled:
            gui_click(matches[0]['label'], matches[0]['role'])
            changed = gui_snapshot('gui-follow-fullscreen-usb-changed', screenshot=True)
            values = [str(e.get('value')) for e in changed.get('elements', [])
                      if e.get('label') in labels]
            assert values == ['1' if enabled else '0'], 'Fullscreen USB preference did not change'
        return current
    finally:
        gui_expand('Connection & input management', expanded=False)


def gui_focus_machine(machine, before_action=None, use_layout=False):
    if use_layout:
        gui_click('Layout')
        gui_click('Full screen')
        gui_input(0, machine['input'])
        label = 'Apply layout'
    else:
        gui_click('Machines')
        label = 'Show ' + machine['name'] + ' full screen'
    gui_show_controls({label}, 'gui-focus-' + machine['id'])
    gui_click(label, 'AXButton', before_action=before_action)
    gui_snapshot('gui-focus-' + machine['id'] + '-busy', screenshot=True)
    # The independent CLI reads below decide the hardware verdict. Wait until
    # the UI operation completes before competing for the controller lock.
    gui_wait_for('gui-focus-' + machine['id'] + '-finished',
                 lambda tree: machine['name'] + ' · full screen and USB verified.' in tree,
                 failed=('monitor-error', 'usb-route-error'), timeout=90)


def exercise_machine_focus(machine_id):
    global kvm_local_safe
    registry = run('machine', 'list')
    linux = [m for m in registry['machines'] if m['id'] == machine_id and m['platform'] == 'linux' and m.get('host')]
    local = [m for m in registry['machines'] if m['platform'] == 'macos' and m.get('host') is None and m['input'] == 'usbc']
    assert len(linux) == len(local) == 1, 'Focus exercise requires a saved Linux machine and this Mac assigned to USB-C'
    machine, mac = linux[0], local[0]
    def observe():
        usb = validate_kvm_status(read_state('kvm', 'status', '--machine', machine_id, timeout=60), registry, machine)
        layout = read_state('kvm', 'layout', '--machine', machine_id, timeout=60)
        assert read_state('kvm', 'status', '--machine', machine_id, timeout=60) == usb, 'USB ownership changed while reading the layout'
        return usb, layout
    original_usb, original_layout = observe()
    assert original_usb['route'] == 'usbc' and original_usb['controlHost'] == 'local'
    assert original_layout['mode'] in ('off', 'pbp') and original_layout['source1'] != original_layout['source2'] \
        and original_layout['pipInput'] == original_layout['source2'], 'Baseline cannot be restored exactly by the public layout commands'
    target = predict_machine_route(machine, 'fullscreen', original_layout)
    returned = predict_machine_route(mac, 'fullscreen', original_layout)
    before_devices = read_linux_usb(machine, 'focus-before')
    assert before_devices['companionExitCode'] == 0 and not before_devices['companion'].get('error')
    proof = {'machineID': machine_id, 'baselineUSB': original_usb, 'baselineLayout': original_layout,
             'targetLayout': target, 'returnLayout': returned, 'expectedUSBDevices': args.expect_usb,
             'inputEvents': 'not exercised', 'restored': False}
    summary['machineFocus'] = proof
    preview = run('machine', 'focus', machine_id, '--expected-usb', 'usbc', '--dry-run', timeout=90)
    assert preview['dryRun'] and not preview['verified'] and not preview['videoWriteAttempted']
    assert not any(change['writeAttempted'] for change in preview['usbChanges'])
    assert preview['targetInput'] == machine['input'] and preview['targetUSB'] == 'upstream'
    assert preview['targetLayout'] == target and observe() == (original_usb, original_layout)
    preference = None
    outbound_attempted = False
    return_attempted = False
    owned_usb = None
    owned_layouts = [target]
    try:
        if args.gui:
            gui_machines('gui-focus-machines', registry)
            preference = gui_follow_usb(True)
        assert run('machine', 'list') == registry and observe() == (original_usb, original_layout)
        kvm_local_safe = False
        def mark_outbound():
            nonlocal outbound_attempted
            outbound_attempted = True
        if args.gui:
            # Exercise the Layout entry point that previously changed only the
            # picture. The return below covers the machine-card entry point.
            gui_focus_machine(machine, before_action=mark_outbound, use_layout=True)
        else:
            mark_outbound()
            result = run('machine', 'focus', machine_id, '--expected-usb', 'usbc', success=None, timeout=120)
            proof['outboundResult'] = result
            if 'videoWriteAttempted' in result and 'usbChanges' in result:
                outbound_attempted = result['videoWriteAttempted'] or any(c['writeAttempted'] for c in result['usbChanges'])
        owned_usb, applied = observe()
        assert owned_usb['route'] == 'upstream' and owned_usb['controlHost'] == 'upstream' and applied == target
        proof['appliedUSB'], proof['appliedLayout'] = owned_usb, applied
        proof['peripheralsUpstream'] = inspect_peripherals(machine_id, 'focus-peripherals-upstream')
        devices = read_linux_usb(machine, 'focus-upstream')
        assert usb_count(devices, '1462:3fa4') == 1, 'Linux did not enumerate exactly one MSI controller'
        for identifier in args.expect_usb:
            assert usb_count(devices, identifier) > usb_count(before_devices, identifier), 'Expected USB device did not move to Linux: ' + identifier
        if args.gui:
            # A fullscreen handoff must not strand Layout controls on the Mac.
            # PBP changes picture only and must finish with the same USB owner.
            split_target = dict(target, mode='pbp', source1=machine['input'],
                                source2=mac['input'], pipInput=mac['input'])
            assert observe() == (owned_usb, target), 'Focus changed before the PBP stage'
            gui_click('Layout')
            gui_click('Side by side')
            gui_input(0, machine['input'])
            gui_input(1, mac['input'])
            gui_show_controls({'Apply layout'}, 'gui-focus-pbp')
            def mark_split():
                owned_layouts.append(split_target)
            gui_click('Apply layout', 'AXButton', before_action=mark_split)
            gui_snapshot('gui-focus-pbp-busy', screenshot=True)
            titles = {'dp': 'DisplayPort', 'usbc': 'USB-C', 'hdmi1': 'HDMI 1', 'hdmi2': 'HDMI 2'}
            selected = 'Current: ' + titles[machine['input']] + ' | ' + titles[mac['input']]
            gui_wait_for('gui-focus-pbp-finished',
                         lambda tree: selected in tree and 'APPLYING LAYOUT' not in tree,
                         failed=('monitor-error', 'usb-route-error'), timeout=120)
            split_usb, split_layout = observe()
            assert split_usb == owned_usb, 'PBP changed the selected USB owner'
            assert split_layout == split_target, 'PBP did not apply while USB belonged to Linux'
            split_devices = read_linux_usb(machine, 'focus-pbp-upstream')
            for identifier in args.expect_usb:
                assert usb_count(split_devices, identifier) == usb_count(devices, identifier), \
                    'Expected USB device did not remain on Linux after PBP: ' + identifier
            proof['pbpTarget'], proof['pbpLayout'], proof['pbpUSB'] = split_target, split_layout, split_usb
            proof['pbpPeripherals'] = inspect_peripherals(machine_id, 'focus-pbp-peripherals')
    except Exception as error:
        proof['exerciseError'] = str(error)
        raise
    finally:
        try:
            current_usb, current_layout = observe()
            assert run('machine', 'list') == registry, 'Machine assignments changed; refusing focus cleanup'
            if current_usb == original_usb and current_layout == original_layout:
                kvm_local_safe = True
            elif outbound_attempted and current_layout in owned_layouts and current_usb['route'] == 'upstream':
                if owned_usb is not None:
                    assert current_usb == owned_usb, 'USB ownership changed; refusing focus cleanup'
                returned = predict_machine_route(mac, 'fullscreen', current_layout)
                proof['returnLayout'] = returned
                return_error = None
                def mark_return():
                    nonlocal return_attempted
                    return_attempted = True
                try:
                    if args.gui:
                        gui_focus_machine(mac, before_action=mark_return)
                    else:
                        mark_return()
                        proof['returnResult'] = run('machine', 'focus', mac['id'], '--expected-usb', 'upstream', success=None, timeout=120)
                except Exception as error:
                    return_error = str(error)
                current_usb, current_layout = observe()
                if return_error:
                    proof['returnActionError'] = return_error
                assert current_usb == original_usb, 'USB return is unverified; no focus request was repeated'
                # A partial return can acquire USB before failing video. Both
                # layouts are known owned stages, and cleanup may restore either.
                assert current_layout in owned_layouts + [returned], 'Unexpected video layout after returning USB'
                if current_layout != returned:
                    proof['returnActionError'] = return_error or 'USB returned, but the local Mac fullscreen stage was not verified'
                kvm_local_safe = True
            elif outbound_attempted and current_usb == original_usb and current_layout in owned_layouts:
                kvm_local_safe = True  # Video applied, final USB stage did not persist.
            else:
                raise RuntimeError('Focus state changed outside the exercise; refusing cleanup')
            proof['returnAttempted'] = return_attempted
            if kvm_local_safe:
                proof['finalLayout'] = restore_machine_layout(original_layout, current_layout)
                proof['finalUSB'] = observe()[0]
                assert proof['finalUSB'] == original_usb
                final_devices = read_linux_usb(machine, 'focus-returned')
                for identifier in args.expect_usb:
                    assert usb_count(final_devices, identifier) == usb_count(before_devices, identifier), 'Expected USB device did not return: ' + identifier
                proof['peripheralsReturned'] = inspect_peripherals(machine_id, 'focus-peripherals-returned')
                proof['restored'] = proof['finalLayout'] == original_layout
            if proof.get('returnActionError'):
                raise RuntimeError('Baseline restored, but return action verification failed: ' + proof['returnActionError'])
        finally:
            if preference is not None:
                gui_click('Machines')
                assert gui_follow_usb() is True, 'Fullscreen USB preference changed outside the exercise'
                gui_follow_usb(preference)


def gui_inspect_usb_route():
    registry = run('machine', 'list')
    expected = read_state('kvm', 'status')
    titles = {'usbc': 'USB-C', 'upstream': 'USB-B upstream', 'auto': 'Auto (follow video)'}
    title = titles[expected['route']]
    gui_machines('gui-usb-route-machines', registry)
    gui_show_controls({'Refresh USB route'}, 'gui-usb-route', bottom_margin=150)
    gui_click('Refresh USB route', 'AXButton')
    deadline = time.monotonic() + 55
    while True:
        snapshot = gui_snapshot('gui-usb-route-read')
        tree = snapshot.get('tree_markdown', '')
        routes = [line for line in tree.splitlines()
                  if line.strip() == '- AXStaticText = ' + json.dumps(title)]
        ready = any(e.get('role') == 'AXButton' and e.get('label') == 'Refresh USB route'
                    and e.get('enabled', True) for e in snapshot.get('elements', []))
        if ready and len(routes) == 1:
            gui_snapshot('gui-usb-route-verified', screenshot=True)
            break
        if 'usb-route-error' in tree or 'peripheral-error' in tree or time.monotonic() >= deadline:
            raise RuntimeError('USB route GUI did not match the independent CLI readback')
        time.sleep(0.2)
    assert read_state('kvm', 'status') == expected, 'Reading USB routing changed or lost the route'
    summary['usbRoute'] = {'state': expected, 'guiMatched': True, 'access': 'read-only'}

def gui_inspect_extended_controls(settings, local):
    gui_click('Monitor')
    monitor = gui_wait_for('gui-monitor-controls',
                           lambda tree: 'Settings read back from monitor.' in tree,
                           failed=('Refresh controls before trying again.',))
    assert 'Settings read from your monitor' in monitor.get('tree_markdown', '')
    assert run('settings') == settings, 'Inspecting Monitor controls changed a setting'
    gui_close_controls()
    reopened = cua.call('launch_app', bundle_id='com.danielsivan.msi-screen.menu', urls=['msi-screen://controls'])
    assert reopened['pid'] == gui_pid
    gui_wait_for('gui-monitor-reopened', lambda tree: 'Settings read back from monitor.' in tree,
                 failed=('Refresh controls before trying again.',))
    registry = run('machine', 'list')
    machines = gui_machines('gui-machine-cards', registry)
    assert run('displays') == local, 'Inspecting Machines changed desktop roles'
    if args.sharing:
        # Only this explicit option runs the user's installed sharing helper.
        # Its service check does not prove keyboard or pointer transfer.
        gui_expand('Connection & input management')
        gui_expand('Universal Control · Macs only')
        sharing = gui_snapshot('gui-sharing-expanded', screenshot=True)
        labels = {element.get('label') for element in sharing.get('elements', [])}
        gui_click('Check sharing' if 'Check sharing' in labels else 'Check')
        checked = gui_wait_for(
            'gui-sharing-checked',
            lambda tree: any(message in tree for message in (
                'Sharing services are healthy.', 'Sharing could not be checked.',
                'Universal Control could not complete.', 'The script finished without',
                'The operation timed out.')),
            timeout=55)
        tree = checked.get('tree_markdown', '')
        summary['sharingServicesHealthy'] = 'Sharing services are healthy.' in tree
        summary['sharingFunctional'] = 'unverified; test pointer and keyboard across both Macs'
        assert summary['sharingServicesHealthy'], 'Sharing services were not reported healthy; inspect the GUI evidence'
    gui_click('Layout')
    gui_click('Refresh monitor')
    gui_ready('gui-layout-after-inspection')


def main_target(state):
    selected = [display for display in state['displays'] if display['isMain']]
    assert len(selected) == 1, 'Expected exactly one main display'
    if selected[0]['isBuiltIn']:
        return 'built-in'
    if selected[0]['vendor'] == 0x3669 and selected[0]['model'] == 0x30c5:
        return 'monitor'
    raise RuntimeError('Main-role exercise requires a built-in or MSI main baseline so it can restore that selection')


def predict_main_state(state, target):
    """Independent expected geometry, without executing the helper's planner."""
    displays = state['displays']
    monitors = [d for d in displays if d['vendor'] == 0x3669 and d['model'] == 0x30c5]
    assert len(monitors) == 1, 'Peer exercise requires exactly one MSI video display'
    selected = monitors if target == 'monitor' else [d for d in displays if d['isBuiltIn']]
    assert len(selected) == 1, 'Peer target display is missing or ambiguous'
    assert len({d['id'] for d in displays}) == len(displays)
    assert len({d['uuid'] for d in displays}) == len(displays)
    assert all(d['isActive'] and not d['isAsleep'] and not d['isMirrored']
               and d['mirrorsDisplay'] == 0 and d['mode'] is not None for d in displays), \
        'Peer exercise requires awake, active, extended displays'
    origin_x, origin_y = selected[0]['bounds'][0]
    expected = copy.deepcopy(state)
    for display in expected['displays']:
        x, y = display['bounds'][0]
        translated = [x - origin_x, y - origin_y]
        assert all(math.isfinite(value) and value == int(value) and -(2 ** 31) <= value < 2 ** 31
                   for value in translated), 'Peer display coordinates are not safely representable'
        display['bounds'][0] = translated
        display['isMain'] = display['id'] == selected[0]['id']
    return expected


def exercise_peer_main_role():
    host = args.peer_host
    baseline = peer_status(host)
    original_target = main_target(baseline)
    target = 'monitor' if original_target == 'built-in' else 'built-in'
    owned = predict_main_state(baseline, target)
    assert owned != baseline
    summary['peerControlsHost'] = host
    summary['peerRoleBaseline'] = baseline
    summary['peerRolePlanned'] = owned
    gui_peer_ready = False
    try:
        if args.gui:
            registry = run('machine', 'list')
            matches = [m for m in registry['machines'] if m['platform'] == 'macos' and m.get('host') == host]
            assert len(matches) == 1, 'The peer SSH alias must match one saved Mac machine'
            machine = matches[0]
            gui_machines('gui-before-peer-main', registry)
            assert run('machine', 'list') == registry, 'Saved peer assignment changed before GUI action'
            assert peer_status(host) == baseline, 'Peer arrangement changed before the GUI action'
            gui_peer_ready = True
            gui_click('Make MSI main on other Mac' if target == 'monitor' else 'Make laptop main on other Mac')
            gui_snapshot('gui-peer-main-busy', screenshot=True)
            gui_wait_for('gui-peer-main-applied', lambda tree: 'Display positions and Main/Extended roles verified.' in tree,
                         failed=('Refresh displays before trying again.',), timeout=55)
            applied = peer_status(host)
        else:
            applied = peer_request(host, {
                'schemaVersion': 1, 'action': 'main', 'expected': baseline, 'target': target})
        assert applied == owned, 'Peer main role or geometry differs from the independent prediction'
        assert peer_status(host) == owned, 'Independent peer readback differed'
        summary['peerRoleApplied'] = applied
    finally:
        current = peer_status(host)
        if current != baseline:
            # A timeout or GUI error does not prove that the helper did not write.
            # Restore only our exact planned state, including identities and modes.
            if current != owned:
                raise RuntimeError('Peer arrangement changed outside the exercise; refusing to overwrite it during cleanup')
            restored = peer_request(host, {
                'schemaVersion': 1, 'action': 'main', 'expected': current, 'target': original_target})
            assert restored == baseline, 'Peer restore did not reproduce the full baseline'
        final = peer_status(host)
        summary['peerRoleFinal'] = final
        summary['peerRoleRestored'] = final == baseline
        assert summary['peerRoleRestored'], 'Final peer arrangement differs from baseline'
        if args.gui and gui_peer_ready:
            gui_click('Refresh monitor')
            gui_wait_for('gui-peer-main-restored', lambda tree:
                         'Machine checks complete. Input selection is read from the monitor.' in tree, timeout=55)


def inspect_permissions():
    if args.gui:
        gui_click('Peripherals')
        gui_wait_for('gui-permissions-loaded', lambda tree: 'Privacy & permissions' in tree and
                     ('Stable signing identity' in tree or 'Signing needs attention' in tree))
        gui_click('Check MSI Screen permissions')
        state = gui_wait_for('gui-permissions-checked', lambda tree:
                             'Accessibility:' in tree and 'Input Monitoring:' in tree)
    status = run('permissions')
    assert status['schemaVersion'] == 1 and status['bundleIdentifier'] == 'com.danielsivan.msi-screen.menu'
    assert status['signing']['identifier'] == status['bundleIdentifier']
    assert isinstance(status['accessibilityTrusted'], bool) and isinstance(status['eventPostingAllowed'], bool)
    assert status['inputMonitoring'] in ('granted', 'denied', 'unknown')
    if args.gui:
        assert status['processID'] == gui_pid, 'CLI reported a different process permission identity'
        tree = state.get('tree_markdown', '')
        accessibility = 'Granted' if status['accessibilityTrusted'] and status['eventPostingAllowed'] else 'Not granted'
        input_access = {'granted': 'Granted', 'denied': 'Not granted', 'unknown': 'Not determined'}[status['inputMonitoring']]
        assert 'Accessibility: ' + accessibility in tree
        assert 'Input Monitoring: ' + input_access in tree
        signing = status['signing']
        stable = signing['kind'] == 'certificate' and signing['signatureValid'] and \
            signing.get('designatedRequirement') and 'cdhash' not in signing['designatedRequirement']
        assert ('Stable signing identity' if stable else 'Signing needs attention') in tree
        summary['permissionsGUIMatched'] = True
    summary['permissions'] = status
    summary['permissionsGranted'] = status['accessibilityTrusted'] and status['eventPostingAllowed'] and \
        status['inputMonitoring'] == 'granted'


def exercise_arrangement():
    baseline = run('displays')
    plans = {side: run('arrange', side, '--dry-run') for side in ('left', 'right')}
    original = [side for side, plan in plans.items() if plan['after'] == baseline]
    assert len(original) == 1, 'Arrangement exercise requires an existing top-aligned left/right pair for exact restoration'
    original = original[0]
    target = 'right' if original == 'left' else 'left'
    owned = plans[target]['after']
    assert main_target(owned) == main_target(baseline)
    try:
        if args.gui:
            registry = run('machine', 'list')
            machine = next(m for m in registry['machines'] if m['platform'] == 'macos' and m.get('host') is None)
            gui_machines('gui-arrangement-before', registry)
            label = 'Place ' + machine['name'] + ' MacBook ' + target + ' of MSI'
            gui_show_controls({label}, 'gui-arrangement-target', bottom_margin=50)
            gui_click(label)
            gui_snapshot('gui-arrangement-action', screenshot=True)
            gui_wait_for('gui-arrangement-applied', lambda tree:
                         'Display positions and Main/Extended roles verified.' in tree,
                         failed=('Refresh displays before trying again.',))
            applied = run('displays')
        else:
            applied = run('display-request', input=json.dumps({
                'schemaVersion': 1, 'action': 'arrange', 'expected': baseline, 'laptopPosition': target}))
        assert applied == owned, 'Arrangement differs from its preview'
        summary['arrangementApplied'] = applied
        assert run('displays') == owned, 'Independent display readback differs'
    finally:
        current = run('displays')
        if current != baseline:
            assert current == owned, 'Arrangement changed externally; refusing to overwrite during cleanup'
            restored = run('display-request', input=json.dumps({
                'schemaVersion': 1, 'action': 'arrange', 'expected': current, 'laptopPosition': original}))
            assert restored == baseline, 'Arrangement restore differs from baseline'
        summary['arrangementRestored'] = run('displays') == baseline
        assert summary['arrangementRestored']
        if args.gui:
            gui_click('Refresh monitor')
            gui_wait_for('gui-arrangement-restored', lambda tree:
                         'Machine checks complete. Input selection is read from the monitor.' in tree, timeout=55)


def exercise_main_role():
    baseline = run('displays')
    original_target = main_target(baseline)
    target = 'monitor' if original_target == 'built-in' else 'built-in'
    plan = run('main', target, '--dry-run')
    assert plan['before'] == baseline and plan['after'] != baseline
    owned = plan['after']
    summary['mainRoleBaseline'] = baseline
    summary['mainRolePlanned'] = owned
    try:
        if args.gui:
            registry = run('machine', 'list')
            matches = [m for m in registry['machines'] if m['platform'] == 'macos' and m.get('host') is None]
            assert len(matches) == 1, 'This Mac must be saved once in Machines'
            gui_machines('gui-before-main', registry)
            assert run('machine', 'list') == registry, 'Saved local machine changed before GUI action'
            gui_click('Make MSI main on this Mac' if target == 'monitor' else 'Make laptop main on this Mac')
            gui_wait_for('gui-main-applied', lambda tree: 'Display positions and Main/Extended roles verified.' in tree,
                         failed=('Refresh displays before trying again.',))
            applied = run('displays')
        else:
            applied = run('display-request', input=json.dumps({
                'schemaVersion': 1, 'action': 'main', 'expected': baseline, 'target': target}))
        assert applied == owned, 'Main role changed differently from the preview'
        assert run('displays') == owned, 'Separate-process main role readback differed'
        summary['mainRoleApplied'] = applied
    finally:
        current = run('displays')
        if current != baseline:
            # A failed immediate result may follow an actual successful write.
            # Only the exact planned after-state proves ownership for restoration.
            if current != owned:
                raise RuntimeError('Desktop arrangement changed outside the exercise; refusing to overwrite it during cleanup')
            restored = run('display-request', input=json.dumps({
                'schemaVersion': 1, 'action': 'main', 'expected': current, 'target': original_target}))
            assert restored == baseline, 'Main-role restore did not reproduce the baseline'
        final = run('displays')
        summary['mainRoleFinal'] = final
        summary['mainRoleRestored'] = final == baseline
        assert summary['mainRoleRestored'], 'Final desktop arrangement differs from the baseline'


def exercise_brightness():
    baseline = run('settings')
    value = baseline['values'].get('brightness')
    reason = baseline['unavailable'].get('brightness')
    if value is None or reason:
        raise RuntimeError(f'Brightness exercise unavailable: {reason or "value missing"}')
    target = value + 1 if value < 100 else value - 1
    owned = copy.deepcopy(baseline)
    owned['values']['brightness'] = target
    summary['brightnessBaseline'] = baseline
    summary['brightnessPlanned'] = owned
    preview = run('set', 'brightness', str(target), '--dry-run')
    assert preview['before'] == baseline and preview['dryRun'] and not preview['verified']
    assert run('settings') == baseline, 'Brightness preview changed monitor settings'
    try:
        if args.gui:
            gui_click('Monitor')
            gui_wait_for('gui-before-brightness', lambda tree: 'Settings read back from monitor.' in tree)
            snapshot = gui_snapshot('before-brightness-draft', screenshot=True)
            slider = next(e for e in snapshot['elements'] if e.get('role') == 'AXSlider' and e.get('label') == 'Brightness')
            result = cua.call('set_value', pid=gui_pid, window_id=gui_window,
                              element_token=slider['element_token'], value=str(target))
            with (output / 'actions.jsonl').open('a') as f:
                f.write(json.dumps({'action': ['gui-set-brightness', target], 'result': result}) + '\n')
            gui_snapshot('gui-brightness-draft', screenshot=True)
            assert run('settings') == baseline, 'Moving the slider wrote without Apply'
            gui_click('Apply Brightness')
            gui_wait_for('gui-brightness-applied', lambda tree: 'Settings read back from monitor.' in tree,
                         failed=('Refresh controls before trying again.',))
            assert run('settings') == owned
        else:
            applied = run('set', 'brightness', str(target))
            assert applied['verified'] and applied['before'] == baseline and applied['after'] == owned
        assert run('settings') == owned, 'Separate-process brightness readback differed'
        summary['brightnessApplied'] = owned
    finally:
        current = run('settings')
        if current != baseline:
            if current != owned:
                raise RuntimeError('Monitor settings changed outside the exercise; refusing to overwrite them during cleanup')
            restored = run('set', 'brightness', str(value))
            assert restored['verified'] and restored['before'] == current and restored['after'] == baseline
        final = run('settings')
        summary['brightnessFinal'] = final
        summary['brightnessRestored'] = final == baseline
        assert summary['brightnessRestored'], 'Final monitor settings differ from the baseline'


try:
    update_server = None
    update_bundle_id = 'com.danielsivan.msi-screen.menu'
    if args.update_fixture:
        update_server, update_bundle_id = prepare_update_fixture(args.update_fixture.resolve())
    if args.agent_skill_fixture:
        update_bundle_id = prepare_agent_skill_fixture(args.agent_skill_fixture.resolve())
    if args.peripherals or args.permissions or args.menu_appearance or args.update_fixture or args.login_item or args.agent_skill_fixture:
        registry_baseline = run('machine', 'list')
        summary['machines'] = registry_baseline
    else:
        baseline = read_state('status')  # Health-check the real USB controller before actions.
        summary['baseline'] = baseline
        if 'identity' in run('capabilities')['commands']:
            identity = run('identity')
            assert identity['controlSupported'] is True
            assert identity['matchedProfile'] == baseline['model'] + '/' + baseline['protocolVersion']
            assert bytes.fromhex(identity['protocolHex']).decode('ascii') == baseline['protocolVersion']
            summary['monitorIdentity'] = identity
        settings_baseline = run('settings')
        assert settings_baseline['layout'] == baseline
        assert isinstance(settings_baseline['values'], dict) and isinstance(settings_baseline['unavailable'], dict)
        summary['settingsBaseline'] = settings_baseline
        local_baseline = run('displays')
        assert isinstance(local_baseline['computerName'], str) and isinstance(local_baseline['displays'], list)
        summary['localDisplaysBaseline'] = local_baseline
        registry_baseline = run('machine', 'list')
        assert registry_baseline['schemaVersion'] == 1
        summary['machines'] = registry_baseline
        verify_machine_dry_runs(registry_baseline, baseline)
        if args.peer_host:
            summary['peerDisplays'] = peer_status(args.peer_host)
        summary['displaysBefore'] = displays('before')
        lock_path = Path.home() / 'Library/Caches/msi-screen-control/controller.lock'
        with lock_path.open('r+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            busy = run('status', success=False)
            assert 'Another msi-screen process' in busy.get('error', '')
        assert read_state('status') == baseline, 'Lock test changed monitor state'
        # A valid full-screen baseline may store identical primary/secondary inputs.
        # Use the known DP + USB-C pair for the exercise, then restore that baseline.
        left = baseline['source1'] if baseline['source1'] != baseline['source2'] else ('dp' if baseline['source2'] != 'dp' else 'usbc')
        right = baseline['source2']
        plan = run('pbp', 'on', '--left', left, '--right', right, '--dry-run')
        assert plan['dryRun'] and not plan['verified']
        assert read_state('status') == baseline, 'Dry-run changed the monitor'
        run('pbp', 'on', '--left', baseline['source1'], '--right', baseline['source1'], success=False)
        run('pbp', 'on', '--left', 'invalid', success=False)
        full_plan = run('fullscreen', baseline['source1'], '--dry-run')
        assert full_plan['dryRun'] and not full_plan['verified']
        assert read_state('status') == baseline
        assert 'fullscreen INPUT' in run('capabilities')['commands']
    if args.gui:
        cua = CuaSession()
        owner = 'msi-verification-' + uuid.uuid4().hex
        window_receipt = output / 'gui-window.json'
        launched = cua.call('launch_app', bundle_id=update_bundle_id,
                            creates_new_application_instance=True,
            additional_arguments=['--show-controls', '--verification-owner', owner,
                                                  '--verification-window-file', str(window_receipt),
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
        gui_window = next((w['window_id'] for w in windows if w.get('title') == 'MSI Screen'), None)
        if gui_window is None:
            # Floating panels are absent from Cua's layer-0 inventory. Use the
            # owned app's bootstrap receipt, then let Cua independently validate
            # the window's PID and capture its live accessibility/pixel state.
            receipt = json.loads(window_receipt.read_text())
            assert receipt['pid'] == gui_pid and receipt['owner'] == owner, 'Window receipt is not ours'
            gui_window = receipt['windowID']
            assert isinstance(gui_window, int) and gui_window > 0, 'Invalid panel window ID'
        if args.peripherals or args.permissions or args.menu_appearance or args.update_fixture or args.login_item or args.agent_skill_fixture:
            gui_wait_for('gui-health', lambda tree: 'Machines' in tree)
        else:
            gui_ready('gui-health')
            assert read_state('status') == baseline, 'Opening the app changed the monitor'
        # A peer-only exercise has its own GUI health and identity checks.
        # Keep it independent of the longer layout polling/draft exercise.
        if not (args.exercise_peer_controls or args.exercise_machine or args.exercise_machine_editor or args.idle_seconds or args.usb_route or args.exercise_kvm or args.exercise_focus or args.peripherals or args.permissions or args.exercise_arrangement or args.menu_appearance or args.update_fixture or args.login_item or args.agent_skill_fixture) or args.exercise or args.exercise_controls or args.sharing:
            gui_click('Refresh monitor')
            gui_ready('gui-refresh')
            # A background status refresh must not discard a pending layout choice
            # or apply it. Leave a different draft open past the polling interval.
            draft_split = baseline['mode'] != 'pbp'
            gui_click('Side by side' if draft_split else 'Full screen')
            gui_wait_across_poll('draft-preservation')
            draft = gui_snapshot('gui-draft-preserved', screenshot=True)
            draft_label = 'Side by side' if draft_split else 'Full screen'
            assert any(e.get('role') == 'AXRadioButton' and e.get('label') == draft_label and e.get('value') == '1'
                       for e in draft.get('elements', [])), 'Background refresh replaced the draft'
            assert read_state('status') == baseline, 'Editing a draft changed the monitor'
            gui_click('Refresh monitor')
            gui_ready('gui-draft-reset')
            gui_close_controls()
            assert not any(w['window_id'] == gui_window and w.get('is_on_screen')
                           for w in cua.call('list_windows', pid=gui_pid)['windows']), 'Controls did not close'
            # Exercise the closed-panel poll without changing hardware: a held
            # local lock makes status unreadable, then releasing it allows readback.
            with lock_path.open('r+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                gui_wait_across_poll('closed-panel-unavailable')
                gui_menu_bar('gui-poll-unavailable')
            gui_wait_across_poll('closed-panel-recovery')
            gui_menu_bar('gui-poll-recovered')
            # get_desktop_state returns screenshot metadata, not AX labels.
            # The captures need visual review; reopening proves fresh readback
            # but cannot retroactively prove that the closed-panel poll ran.
            summary['closedPanelPolling'] = {
                'verdict': 'INCONCLUSIVE',
                'reason': 'Menu-bar screenshots captured; Cua provides no menu-bar AX label assertion.',
                'evidence': ['gui-poll-unavailable-menubar.png', 'gui-poll-recovered-menubar.png'],
            }
            reopened = cua.call('launch_app', bundle_id='com.danielsivan.msi-screen.menu', urls=['msi-screen://controls'])
            assert reopened['pid'] == gui_pid, 'Controls reopened a different app instance'
            gui_ready('gui-poll-controls')
            assert read_state('status') == baseline, 'Status polling changed the monitor'
            gui_inspect_extended_controls(settings_baseline, local_baseline)
    if args.exercise:
        if args.gui:
            gui_machines('gui-layout-routing-preference', registry_baseline)
            layout_usb_preference = gui_follow_usb(False)
            gui_click('Layout')
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
        assert read_state('status') == on_state
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
            assert read_state('status') == swapped['after']
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
    if args.permissions:
        inspect_permissions()
    if args.menu_appearance:
        gui_inspect_menu_appearance()
    if args.update_fixture:
        gui_inspect_update()
    if args.login_item:
        gui_inspect_login_item()
    if args.agent_skill_fixture:
        gui_inspect_agent_skill()
    if args.exercise_arrangement:
        exercise_arrangement()
    if args.exercise_controls:
        assert read_state('status') == baseline, 'Restore the layout before exercising other controls'
        exercise_main_role()
        exercise_brightness()
    if args.exercise_peer_controls:
        exercise_peer_main_role()
    if args.exercise_machine:
        exercise_machine_routes(args.exercise_machine)
    if args.exercise_machine_editor:
        exercise_machine_editor(args.exercise_machine_editor)
    if args.exercise_focus:
        exercise_machine_focus(args.exercise_focus)
    if args.peripherals:
        inspect_peripherals(gui=args.gui, details=True, probe=args.probe_pointer,
                            controller_probe=args.probe_controller)
    if args.exercise_kvm:
        exercise_kvm_roundtrip(args.exercise_kvm)
    if args.usb_route:
        gui_inspect_usb_route()
    if args.idle_seconds:
        profile_gui_idle(args.idle_seconds)
    summary['passed'] = True
except Exception as error:
    summary['error'] = str(error)
    import traceback
    (output / 'failure-traceback.txt').write_text(traceback.format_exc())
finally:
    if update_server is not None:
        update_server.shutdown()
        update_server.server_close()
    if baseline is not None and kvm_local_safe:
        try:
            final = read_state('status')
            # Only the explicit exercise owns a layout change to clean up.
            if exercise_started and final != baseline and baseline['mode'] != 'pip':
                if final != owned_state:
                    raise RuntimeError('Monitor changed outside the verified exercise; refusing to overwrite that change during cleanup')
                if baseline['mode'] == 'pbp' or final['source1'] != baseline['source1'] or final['source2'] != baseline['source2']:
                    run('pbp', 'on', '--left', left, '--right', right)
                if baseline['mode'] == 'off':
                    run('fullscreen', baseline['source1'])
                final = read_state('status')
            summary['final'] = final
            summary['displaysAfter'] = displays('after')
            summary['restored'] = final == baseline
            if final != baseline:
                summary['passed'] = False
                summary['restoreError'] = 'Final monitor state differs from baseline'
        except Exception as error:
            summary['passed'] = False
            summary['restoreError'] = str(error)
    if baseline is not None and not kvm_local_safe:
        summary['passed'] = False
        summary['restoreError'] = 'KVM return/local controller ownership is unverified; local USB cleanup reads were skipped.'
    if layout_usb_preference is not None:
        try:
            assert gui_owned and owns_gui_process(), 'Cannot restore preference in an unowned app'
            gui_click('Machines')
            assert gui_follow_usb() is False, 'Fullscreen USB preference changed outside the layout exercise'
            gui_follow_usb(layout_usb_preference)
            summary['layoutUSBPreferenceRestored'] = True
        except Exception as error:
            summary['passed'] = False
            summary['layoutUSBPreferenceRestoreError'] = str(error)
    if cua:
        try:
            if gui_owned and gui_window is not None and owns_gui_process():
                # Quit behind an active sheet can return an AX receipt without
                # exiting. Dismiss only our recognized machine editor first.
                gui_dismiss_machine_editor('gui-quit-editor-cleanup')
                try:
                    gui_named_menu('App actions')
                    gui_click('Quit', 'AXMenuItem')
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
    if args.update_fixture and summary.get('guiProcessExited') and summary.get('updateFixture', {}).get('signedDownloadReady'):
        # Sparkle's staged automatic update installs when this owned fixture
        # quits, or --install-update drives its explicit dialog. Prove the
        # replacement on disk without touching the real installed app.
        installed = output / 'update-fixture/installed/MSI Screen.app'
        expected = (root / 'VERSION').read_text().strip()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                version = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
            except (OSError, KeyError, plistlib.InvalidFileException):
                version = None  # The installer can briefly replace the bundle.
            if version == expected:
                break
            print(json.dumps({'action': ['wait-update-install-on-quit'], 'observedVersion': version}), flush=True)
            time.sleep(1)
        else:
            summary['passed'] = False
            summary['updateInstallError'] = 'Staged update did not replace the isolated app after Quit'
        if version == expected:
            signature = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installed)], capture_output=True, text=True)
            summary['updateFixture'].update(installed=True, installedOnQuit=not args.install_update,
                                            installedViaDialog=args.install_update, signatureValid=signature.returncode == 0)
            if signature.returncode:
                summary['passed'] = False
                summary['updateInstallError'] = signature.stderr
            else:
                try:
                    release = output / 'update-fixture/release/MSI Screen.app'
                    artifacts = ['Contents/MacOS/MSIScreenMenu', 'Contents/MacOS/msi-screen',
                                 'Contents/Resources/AgentSkills/msi-screen-control/SKILL.md']
                    hashes = {}
                    for relative in artifacts:
                        hashes[relative] = hashlib.sha256((installed / relative).read_bytes()).hexdigest()
                        assert hashes[relative] == hashlib.sha256((release / relative).read_bytes()).hexdigest(), 'Installed artifact differs from the signed release: ' + relative
                    summary['updateFixture']['installedArtifactHashes'] = hashes
                    gui_relaunch_updated_fixture(update_bundle_id)
                except Exception as error:
                    summary['passed'] = False
                    summary['updateRelaunchError'] = str(error)
    if args.update_fixture:
        if update_server:
            update_server.shutdown()
            update_server.server_close()
        fixture_app = output / 'update-fixture/installed/MSI Screen.app'
        if fixture_app.exists():
            unregistered = subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                                           '-u', str(fixture_app)], capture_output=True, text=True)
            summary['updateFixtureUnregistered'] = unregistered.returncode == 0
            if unregistered.returncode:
                summary['passed'] = False
    if args.agent_skill_fixture:
        fixture_app = output / 'agent-skill-fixture/MSI Screen.app'
        if fixture_app.exists():
            unregistered = subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                                           '-u', str(fixture_app)], capture_output=True, text=True)
            summary['skillFixtureUnregistered'] = unregistered.returncode == 0
            if unregistered.returncode:
                summary['passed'] = False
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'summary': summary, 'evidence': str(output)}, indent=2), flush=True)
sys.exit(0 if summary['passed'] else 1)
