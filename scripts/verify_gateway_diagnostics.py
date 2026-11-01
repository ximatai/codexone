#!/usr/bin/env python3
"""Exercise failure diagnostics with synthetic children, including a live pipe without EOF."""
from contextlib import redirect_stderr
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from verify_protocol import GATEWAY_OUTPUT_LIMIT, TOKEN, dump_gateway_failure, start, stop


class GatewayDiagnosticsTests(unittest.TestCase):
    def test_exited_child_keeps_startup_stdout_stderr_and_poll(self):
        process = subprocess.Popen([sys.executable, '-c',
            "import os; os.write(1,b'synthetic stdout\\n'); os.write(2,b'synthetic stderr\\n'); raise SystemExit(7)"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            process.wait(timeout=5)
            process.gateway_startup_output = b'LISTENING synthetic startup\n'
            captured = io.StringIO()
            with redirect_stderr(captured):
                dump_gateway_failure(process)
            diagnostic = captured.getvalue()
            for marker in ('process.poll()=7', 'synthetic startup', 'synthetic stdout', 'synthetic stderr'):
                self.assertIn(marker, diagnostic)
        finally:
            stop(process)

    def test_live_child_does_not_wait_for_eof_and_redacts_bounded_tail(self):
        process = subprocess.Popen([sys.executable, '-c',
            "import os; os.write(1,b'ready'); os.read(0,1)"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            self.assertEqual(os.read(process.stdout.fileno(), 5), b'ready')
            process.gateway_redactions = (TOKEN, '/synthetic/private')
            captured = io.StringIO()
            with redirect_stderr(captured):
                dump_gateway_failure(process, output=b'x' * (2 * GATEWAY_OUTPUT_LIMIT)
                    + f'{TOKEN} /synthetic/private'.encode())
            diagnostic = captured.getvalue()
            self.assertIsNone(process.poll())
            self.assertIn('process.poll()=None', diagnostic)
            self.assertLess(len(diagnostic), GATEWAY_OUTPUT_LIMIT + 256)
            self.assertNotIn(TOKEN, diagnostic)
            self.assertNotIn('/synthetic/private', diagnostic)
            self.assertIn('[redacted]', diagnostic)
        finally:
            stop(process)
            process.stdin.close()

    def test_start_failure_dumps_before_cleanup_and_redacts_fixture_directory(self):
        with tempfile.TemporaryDirectory(prefix='codexone-diagnostics-') as temporary:
            root = Path(temporary)
            binary = root / 'gateway'
            binary.write_text(f'#!{sys.executable}\nimport os\n'
                'os.write(1,b"synthetic startup stdout\\n")\n'
                'os.write(2,(os.environ["CODEXONE_DATA_DIRECTORY"]+"\\n").encode())\n'
                'raise SystemExit(9)\n')
            binary.chmod(0o700)
            captured = io.StringIO()
            with redirect_stderr(captured), self.assertRaises(AssertionError):
                start(str(binary), root / 'identity.json', root)
            diagnostic = captured.getvalue()
            self.assertIn('process.poll()=9', diagnostic)
            self.assertIn('synthetic startup stdout', diagnostic)
            self.assertIn('[redacted]/state', diagnostic)
            self.assertNotIn(temporary, diagnostic)


if __name__ == '__main__':
    unittest.main()
