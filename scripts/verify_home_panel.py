#!/usr/bin/env python3
"""Observed-cache and exact-failure summary via real binary and a failing local provider."""
import argparse
from http.server import BaseHTTPRequestHandler
import json
from pathlib import Path
import time
from urllib.parse import urlencode

from verify_admin import running_admin
from verify_keys import call, create
from verify_snapshot_restore import request


class FailedProvider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        body = b'{"error":{"code":"synthetic_unavailable"}}'
        self.send_response(503)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)


def verify(binary):
    with running_admin(binary, business_day_offset='+08:00') as f:
        key, secret = create(f.ports['admin'])
        f.secrets.append(secret)
        assert request(f.ports['data'], secret)[0] == 200
        f.provider.RequestHandlerClass = FailedProvider
        assert request(f.ports['data'], secret)[0] >= 500
        # An invalid model is rejected before admission; it is a diagnostic only.
        import http.client
        connection = http.client.HTTPConnection('127.0.0.1', f.ports['data'], timeout=5)
        connection.request('POST', '/v1/responses', body=json.dumps({'model': 'synthetic-denied', 'input': 'synthetic'}), headers={'Authorization': 'Bearer '+secret, 'Content-Type': 'application/json'})
        response = connection.getresponse()
        assert response.status >= 400
        response.read()
        connection.close()
        deadline = time.monotonic() + 5
        while True:
            status, summary = call(f.ports['admin'], 'GET', '/api/usage/keys?includeArchived=false')
            assert status == 200
            row = summary['keys'][0]
            if row['admitted'] == 2 and row['failed'] == 1 and row['inFlight'] == 0:
                break
            assert time.monotonic() < deadline
            time.sleep(0.02)
        assert row['inputTokens'] == '5' and row['cachedTokens'] == '0'
        assert row['images'] in (None, '0')
        assert row['tokens'] == '8' and row['tokenUsageIncomplete'] and row['cacheUsageIncomplete']
        status, report = call(f.ports['admin'], 'GET', '/api/usage?' + urlencode(dict(start=summary['startUnixSeconds'], end=summary['endUnixSeconds'], key=key['id'], outcome='failed')))
        assert status == 200
        assert report['totals']['admitted'] == row['failed'] == len(report['rows']) == 1
        assert report['totals']['recordedRejections'] == 0
        assert report['rows'][0]['kind'] == 'admitted' and report['rows'][0]['outcome'] == 'failed'
        assert call(f.ports['admin'], 'GET', '/api/usage?' + urlencode(dict(start=summary['startUnixSeconds'], end=summary['endUnixSeconds'], outcome='cancelled')))[0] == 400
    print('PASS: home panel observed cache survives provider 503; exact failed excludes pre-admission rejection')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    verify(str(Path(parser.parse_args().binary).resolve()))
