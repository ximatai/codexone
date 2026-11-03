#!/usr/bin/env python3
"""Measure a local release image with synthetic HTTP fallback and upstream WS requests.

Requires Docker, cgroup v2 and a reachable host tunnel; never builds or pulls an image.
See docs/development/verification.md for interpretation and platform limits.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
from http.server import ThreadingHTTPServer
import ipaddress
import json
from pathlib import Path
import select
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import uuid

from verify_protocol import TOKEN
from verify_upstream_ws_body_limit import HEADERS, Provider, sized
from verify_json_order import wire

MIB = 1024 * 1024
CONTRACT = 'codex-subscription'
ALLOCATOR_KEYS = ('MALLOC_ARENA_MAX', 'MALLOC_MMAP_THRESHOLD_', 'MALLOC_TRIM_THRESHOLD_')


def docker(*args, check=True):
    result = subprocess.run(['docker', *args], capture_output=True, text=True, timeout=120)
    if check and result.returncode:
        # Docker errors may contain host paths/configuration; keep reports portable.
        raise RuntimeError(f'docker {args[0]} failed (exit {result.returncode})')
    return result.stdout.strip()


class Discard(Provider):
    def capture(self, body, path):
        # Do not retain large requests in the measuring process.
        with self.server.guard:
            self.server.counts[path] += 1
            return sum(self.server.counts.values())


class Tunnel(socketserver.BaseRequestHandler):
    def handle(self):
        peer = self.request
        target = None
        self.server.own(peer)
        try:
            peer.settimeout(15)
            head = bytearray()
            # No over-read: subsequent HTTP/WS bytes belong to the transparent relay.
            while not head.endswith(b'\r\n\r\n'):
                part = peer.recv(1)
                if not part:
                    return
                head.extend(part)
                if len(head) > 16384:
                    raise ValueError('Synthetic proxy header too large')
            method, url, version = bytes(head).split(b'\r\n', 1)[0].split(b' ')
            if method != b'CONNECT' or url != b'127.0.0.1:18090' or version != b'HTTP/1.1':
                raise ValueError('Unexpected synthetic proxy target')
            target = socket.create_connection(('127.0.0.1', self.server.provider_port), timeout=15)
            self.server.own(target)
            with self.server.guard:
                self.server.connects += 1
            peer.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            while not self.server.stopping.is_set():
                ready, _, _ = select.select([peer, target], [], [], 1)
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (target if source is peer else peer).sendall(data)
        except (OSError, ValueError):
            if not self.server.stopping.is_set():
                with self.server.guard:
                    self.server.errors += 1
        finally:
            for channel in (peer, target):
                if channel is not None:
                    self.server.disown(channel)
                    channel.close()


class TunnelServer(socketserver.ThreadingTCPServer):
    daemon_threads = False
    allow_reuse_address = True

    def __init__(self, address, provider_port):
        super().__init__(address, Tunnel)
        self.provider_port = provider_port
        self.guard = threading.Lock()
        self.connections = set()
        self.connects = self.errors = 0
        self.stopping = threading.Event()

    def own(self, channel):
        with self.guard:
            self.connections.add(channel)

    def disown(self, channel):
        with self.guard:
            self.connections.discard(channel)

    def close_owned(self):
        self.stopping.set()
        self.shutdown()
        with self.guard:
            channels = list(self.connections)
        for channel in channels:
            try:
                channel.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.server_close()


def post(port, body):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=600)
    began = time.monotonic()
    status, completed, code = 0, False, None
    try:
        connection.request('POST', '/v1/responses', body,
                           {'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json', **HEADERS})
        reply = connection.getresponse()
        payload = reply.read()
        status = reply.status
        completed = b'event: response.completed\n' in payload and b'data: [DONE]' in payload
        if status != 200:
            try:
                code = json.loads(payload)['error']['code']
            except (ValueError, KeyError, TypeError):
                code = 'invalid_error_envelope'
    except (OSError, http.client.HTTPException):
        code = 'connection_lost'
    finally:
        connection.close()
    return dict(status=status, completed=completed, code=code, seconds=round(time.monotonic() - began, 2))


def measure(args, image, name, network, provider, tunnel, config_dir, proxy_address):
    subnet = ipaddress.IPv4Network(args.subnet)
    listen = str(subnet.network_address + 10)
    command = ['run', '-d', '--pull', 'never', '--name', name, '--network', network, '--ip', listen,
               '--platform', 'linux/amd64', '--memory', args.memory, '--memory-swap', args.memory,
               '--tmpfs', '/var/lib/codexone:uid=10001,gid=10001,mode=0700',
               '--tmpfs', '/run/cfg:uid=10001,gid=10001,mode=0700',
               '-v', f'{config_dir}:/synthetic:ro', '-p', '127.0.0.1::18080',
               '-e', f'CODEXONE_LISTEN_ADDRESS={listen}', '-e', f'CODEXONE_ALLOWED_NETWORKS={subnet}',
               '-e', 'CODEXONE_DATA_PORT=18080', '-e', 'CODEXONE_ADMIN_PORT=18081',
               '-e', 'CODEXONE_IDENTITY_CONFIG=/run/cfg/identity.json',
               '-e', f'CODEXONE_UPSTREAM_HTTP_PROXY=http://{proxy_address}:{tunnel.server_address[1]}']
    if args.cpuset:
        command += ['--cpuset-cpus', args.cpuset]
    unset = []
    for key, value in dict(item.split('=', 1) for item in args.env).items():
        if value:
            command += ['-e', key + '=' + value]
        else:
            unset += ['-u', key]
    launch = ' '.join(['env', *unset, '/usr/local/bin/codexone'])
    docker(*command, '--entrypoint', 'sh', image, '-c',
           'cp /synthetic/identity.json /run/cfg/; chmod 600 /run/cfg/identity.json; exec ' + launch)
    port = int(docker('port', name, '18080').splitlines()[0].rsplit(':', 1)[1])
    for _ in range(120):
        if docker('exec', name, 'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
                  'http://127.0.0.1:18081/health/live', check=False) == '200':
            break
        time.sleep(1)
    else:
        raise RuntimeError('Synthetic gateway did not become live')
    began = time.monotonic()
    rows, codes = [], Counter()

    def checkpoint(step, **extra):
        fields = dict(line.split() for line in docker('exec', name, 'cat', '/sys/fs/cgroup/memory.stat').splitlines())
        row = dict(step=step, seconds=round(time.monotonic() - began, 2),
                   anon_bytes=int(fields['anon']), file_bytes=int(fields['file']),
                   current_bytes=int(docker('exec', name, 'cat', '/sys/fs/cgroup/memory.current')),
                   peak_bytes=int(docker('exec', name, 'cat', '/sys/fs/cgroup/memory.peak')), **extra)
        rows.append(row)
        print(json.dumps(row), flush=True)

    def batch(step, body, count, parallel=1, path='http'):
        before = provider.counts[path]
        with ThreadPoolExecutor(max_workers=parallel) as workers:
            for index in range(count):
                results = list(workers.map(lambda _: post(port, body), range(parallel)))
                codes.update(str(result['status']) for result in results)
                if not all(result['status'] == 200 and result['completed'] for result in results):
                    state = json.loads(docker('inspect', '--format', '{{json .State}}', name))
                    raise RuntimeError(f'{step} failed: {results}; OOMKilled={state["OOMKilled"]}')
                checkpoint(f'{step}#{index + 1}', results=results)
        assert provider.counts[path] - before == count * parallel, f'{step} used unexpected upstream transport'

    image_env = json.loads(docker('image', 'inspect', '--format', '{{json .Config.Env}}', image))
    allocator_env = {key: value for item in image_env or []
                     for key, _, value in [item.partition('=')] if key in ALLOCATOR_KEYS}
    for item in args.env:
        key, _, value = item.partition('=')
        if value:
            allocator_env[key] = value
        else:
            allocator_env.pop(key, None)
    result = dict(image_id=image, label=args.label, memory=args.memory, cpuset=args.cpuset,
                  rounds=args.rounds, idle_seconds=args.idle_seconds, final_idle_seconds=args.final_idle_seconds,
                  allocator_overrides=args.env, effective_allocator_env=allocator_env,
                  online_cpus=int(docker('exec', name, 'getconf', '_NPROCESSORS_ONLN')), platform='linux/amd64', proxy_resolution=args.proxy_resolution, rows=rows)
    try:
        checkpoint('start')
        # Early WS probe fails fast instead of allowing a misleading all-HTTP measurement.
        small = wire(sized(64 * 1024, CONTRACT, streaming=True))
        batch('ws-probe', small, 1, path='websocket')
        if args.rounds:
            big = wire(sized(30 * MIB, CONTRACT, streaming=True))
            many = wire(sized(28 * MIB, CONTRACT, streaming=True, image_count=200))
            pair = wire(sized(22 * MIB, CONTRACT, streaming=True))
            for round_number in range(1, args.rounds + 1):
                batch(f'r{round_number}-big30', big, 6)
                batch(f'r{round_number}-many28', many, 6)
                batch(f'r{round_number}-pair22', pair, 3, parallel=2)
                time.sleep(args.idle_seconds)
                checkpoint(f'r{round_number}-idle')
        batch('small64k', small, args.small_count, path='websocket')
        time.sleep(args.final_idle_seconds)
        checkpoint('final-idle')
        result['success'] = True
    except BaseException as error:
        result['success'] = False
        result['failure'] = str(error)
        raise
    finally:
        state = json.loads(docker('inspect', '--format', '{{json .State}}', name, check=False) or '{}')
        result.update(container_state={key: state.get(key) for key in ('Running', 'OOMKilled', 'ExitCode')},
                      codes=dict(codes), provider_calls=dict(provider.counts),
                      proxy_connects=tunnel.connects, proxy_errors=tunnel.errors,
                      memory_events=docker('exec', name, 'cat', '/sys/fs/cgroup/memory.events', check=False).split())
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print('PASS: all requests completed over the expected upstream transport', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True, help='Local CodexOne image reference; resolved to immutable ID')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--label', default='synthetic-memory')
    parser.add_argument('--memory', default='768m', help='Docker memory limit; swap disabled')
    parser.add_argument('--cpuset', help='Docker CPU set, e.g. 0-1')
    parser.add_argument('--env', action='append', default=[], help='Allocator override NAME=VALUE (repeatable; empty unsets the variable)')
    parser.add_argument('--rounds', type=int, default=3, help='18 large requests per round; 0 for WS diagnosis')
    parser.add_argument('--small-count', type=int, default=20)
    parser.add_argument('--idle-seconds', type=float, default=20)
    parser.add_argument('--final-idle-seconds', type=float, default=60)
    parser.add_argument('--subnet', help='Optional private test subnet; default lets Docker allocate one')
    parser.add_argument('--host-address', default='host.docker.internal', help='Host tunnel address resolved to IPv4 inside image')
    parser.add_argument('--proxy-resolution', choices=('ipv4', 'hostname'), default='ipv4',
                        help='Use resolved IPv4 for measurement; hostname preserves the original diagnostic path')
    parser.add_argument('--tunnel-bind', default='127.0.0.1', help='Host bind; Linux bridge may need a reachable private host address')
    args = parser.parse_args()
    if args.rounds < 0 or args.small_count < 1 or min(args.idle_seconds, args.final_idle_seconds) < 0:
        parser.error('Counts and idle durations must be nonnegative; small-count must be positive')
    for item in args.env:
        key, separator, value = item.partition('=')
        if key not in ALLOCATOR_KEYS or not separator or (value and not value.isdecimal()):
            parser.error('--env only accepts allocator keys with a nonnegative integer or empty value')
    if args.subnet:
        subnet = ipaddress.IPv4Network(args.subnet)
        if not subnet.is_private or subnet.num_addresses < 16:
            parser.error('--subnet must be a private IPv4 network with at least 16 addresses')
    image = docker('image', 'inspect', '--format', '{{.Id}}', args.image)
    # Hostname WS failed before CONNECT; resolved IPv4 succeeded. This is a harness workaround.
    # Preserve the hostname path on request so the gateway failure remains reproducible.
    proxy_address = args.host_address
    if args.proxy_resolution == 'ipv4':
        resolved = docker('run', '--rm', '--pull', 'never', '--platform', 'linux/amd64',
                          '--entrypoint', 'getent', image, 'ahostsv4', args.host_address)
        proxy_address = str(ipaddress.IPv4Address(resolved.split()[0]))
    provider = ThreadingHTTPServer(('127.0.0.1', 0), Discard)
    provider.daemon_threads = False
    provider.guard = threading.Condition()
    provider.counts = Counter()
    provider.mode = 'ok'
    provider.oversized_ws = 0
    tunnel = TunnelServer((args.tunnel_bind, 0), provider.server_port)
    workers = [threading.Thread(target=server.serve_forever) for server in (provider, tunnel)]
    for worker in workers:
        worker.start()
    name = 'codexone-memory-' + uuid.uuid4().hex[:12]
    network = name + '-net'
    try:
        with tempfile.TemporaryDirectory(prefix='codexone-memory-') as temporary:
            root = Path(temporary)
            config = root / 'identity.json'
            config.write_text(json.dumps(dict(principal='synthetic-large', keyID='synthetic-key',
                namespace='synthetic-large', identity='synthetic-account',
                keySHA256=hashlib.sha256(TOKEN.encode()).hexdigest(),
                models=[dict(id='synthetic-large', visionInput=True, inputMicrosPerMillion=0, outputMicrosPerMillion=0)],
                reservedMicros=1, upstreamBaseURL='http://127.0.0.1:18090/v1',
                upstreamTransport='websocket', upstreamContract=CONTRACT)))
            config.chmod(0o644)
            root.chmod(0o755)
            network_args = ['--subnet', args.subnet] if args.subnet else []
            docker('network', 'create', *network_args, network)
            args.subnet = docker('network', 'inspect', '--format', '{{(index .IPAM.Config 0).Subnet}}', network)
            measure(args, image, name, network, provider, tunnel, temporary, proxy_address)
    finally:
        docker('rm', '-f', name, check=False)
        docker('network', 'rm', network, check=False)
        tunnel.close_owned()
        provider.shutdown()
        provider.server_close()
        for worker in workers:
            worker.join(5)


if __name__ == '__main__':
    main()
