"""OMP-supervised lifetime for our exact background-launched app instance."""
import json
import os
import select
import signal
import subprocess
import time
import uuid
from cua_session import CuaSession

stop = False


def request_stop(*_):
    global stop
    stop = True


signal.signal(signal.SIGTERM, request_stop)
signal.signal(signal.SIGINT, request_stop)
cua = CuaSession()
token = 'msi-service-' + uuid.uuid4().hex
pid = None


def owns_process():
    if pid is None:
        return False
    args = subprocess.run(['ps', '-p', str(pid), '-o', 'args='], capture_output=True, text=True)
    return token in args.stdout.split()


try:
    result = cua.call('launch_app', bundle_id='com.danielsivan.msi-screen.menu',
                      creates_new_application_instance=True,
                      additional_arguments=['--service-owner', token, '--supervisor', str(os.getpid())])
    pid = result['pid']
    if not owns_process():
        raise RuntimeError('MSI Screen is already running; quit it before starting the managed instance')
    print(json.dumps({'event': 'app-running', 'pid': pid, 'bundle': 'com.danielsivan.msi-screen.menu'}), flush=True)
    # Watch this already-verified process in the kernel. Repeated ps subprocesses
    # waste wakeups and are unnecessary for process lifetime supervision.
    events = select.kqueue()
    try:
        event = select.kevent(pid, filter=select.KQ_FILTER_PROC,
                              flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                              fflags=select.KQ_NOTE_EXIT)
        events.control([event], 0, 0)
        heartbeat = time.monotonic()
        while not stop:
            if events.control(None, 1, 1):
                break
            if time.monotonic() - heartbeat >= 30:
                print(json.dumps({'event': 'app-alive', 'pid': pid}), flush=True)
                heartbeat = time.monotonic()
    finally:
        events.close()
finally:
    # The app observes this process's exit and quits itself once USB work is
    # idle. No other runtime needs permission to terminate a foreign process.
    cua.close()
