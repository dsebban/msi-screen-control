"""Small stdio MCP client for the installed Cua Driver; background actions only."""
import json
import selectors
import subprocess
import time


class CuaSession:
    def __init__(self):
        self.process = subprocess.Popen(['cua-driver', 'mcp'], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        bufsize=0)
        self.sequence = 0
        self.buffer = b''
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                                   'clientInfo': {'name': 'msi-screen-verifier', 'version': '1'}})
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})

    def send(self, message):
        self.process.stdin.write((json.dumps(message) + '\n').encode())
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        identifier = self.sequence
        self.send({'jsonrpc': '2.0', 'id': identifier, 'method': method, 'params': params})
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if b'\n' not in self.buffer:
                if not self.selector.select(max(0, deadline - time.monotonic())):
                    break
                chunk = self.process.stdout.read(65536)
                if not chunk:
                    raise RuntimeError('Cua Driver MCP connection closed')
                self.buffer += chunk
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                message = json.loads(line)
                if message.get('id') == identifier:
                    if 'error' in message:
                        raise RuntimeError(message['error'])
                    return message['result']
        raise TimeoutError(f'Cua Driver timed out: {method}')

    def call(self, name, **arguments):
        result = self.request('tools/call', {'name': name, 'arguments': arguments})
        if result.get('isError'):
            raise RuntimeError(result)
        data = result.get('structuredContent')
        if data is not None:
            if data.get('status') == 'refused':
                raise RuntimeError(data)
            return data
        return result

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=3)
        self.selector.close()
