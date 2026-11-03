#!/usr/bin/env python3
"""Optimized standalone parse+serialize comparison using the frozen test oracle; synthetic only."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Tests/CodexOneAdaptersTests/JSONOrderTests.swift').read_text()
legacy = source[source.index('private indirect enum LegacyJSONValue'):source.index('extension LegacyJSONValue')]
legacy = legacy.replace('private indirect enum', 'indirect enum')
benchmark = source[source.index('@Test func jsonOrderSyntheticMegabyteBenchmark()'):]
benchmark = benchmark.replace('@Test func jsonOrderSyntheticMegabyteBenchmark()', 'func benchmark()')
with tempfile.TemporaryDirectory(prefix='codexone-json-benchmark-') as temporary:
    root = Path(temporary)
    main = root / 'main.swift'
    main.write_text('import Foundation\nstruct GatewayProtocolError: Error { init(_ status: Int, _ code: String) {} }\n'
                    + legacy + '\n' + benchmark + '\ntry benchmark()\n')
    names = ('JSONValue', 'JSONObject', 'JSONOrderScanner', 'JSONOrderedWriter')
    sources = [ROOT / f'Sources/CodexOneAdapters/Downstream/{name}.swift' for name in names]
    subprocess.run(['swiftc', '-O', *map(str, sources), str(main), '-o', str(root / 'run')], check=True)
    subprocess.run([str(root / 'run')], check=True)
