#!/usr/bin/env python3
"""Real fixture sockets prove replay and cancellation timeout cannot become false PASS."""
import http.client
import json
import time
from verify_desktop_boundaries import synthetic_provider, assert_provider_healthy, frame, read_frame, MODEL
from verify_websocket import dial


def retired(provider):
    deadline = time.monotonic() + 2
    while True:
        with provider.guard: active = provider.active
        if not active: return
        assert time.monotonic() < deadline
        time.sleep(.01)


def must_reject(provider):
    try: assert_provider_healthy(provider)
    except AssertionError: return
    raise AssertionError('Owner accepted a failed provider fixture')


def verify():
    with synthetic_provider(65536, .15) as provider:
        for index in range(2):
            client = http.client.HTTPConnection('127.0.0.1', provider.server_port, timeout=2)
            try:
                client.request('POST', '/v1/responses', json.dumps({'model': MODEL, 'input': 'same-invocation'}), {'Content-Type': 'application/json'})
                try:
                    response = client.getresponse(); assert index == 0 and response.status == 200; response.read()
                except http.client.RemoteDisconnected: assert index == 1
            finally: client.close()
        retired(provider)
        assert provider.calls == 1 and provider.replays == 1 and provider.failures > 0
        must_reject(provider)
    with synthetic_provider(65536, .15) as provider:
        with dial(provider.server_port) as peer:
            frame(peer, {'type': 'response.create', 'model': MODEL, 'input': 'native-cancel-timeout'}, masked=True)
            assert json.loads(read_frame(peer)[1])['type'] == 'response.created'
            assert not provider.cancelled.wait(.4), 'Timeout impersonated peer close'
        retired(provider)
        assert 'cancel_timeout' in provider.failure_kinds
        must_reject(provider)
    with synthetic_provider(65536, .5) as provider:
        with dial(provider.server_port) as peer:
            frame(peer, {'type': 'response.create', 'model': MODEL, 'input': 'native-cancel-close'}, masked=True)
            assert json.loads(read_frame(peer)[1])['type'] == 'response.created'
        assert provider.cancelled.wait(1)
        retired(provider); assert_provider_healthy(provider)
    print('PASS: fixture owner rejects real duplicate invocation and open-socket timeout; actual peer close succeeds')


if __name__ == '__main__': verify()
