#!/usr/bin/env python3
"""Compare Rust wire behavior to the archived Swift release."""

import argparse
import base64
import random
from pathlib import Path
import subprocess
import sys
import tempfile

SEED = 8093
ROOT = Path(__file__).resolve().parents[3]
MANIFEST = "rust/wire/Cargo.toml"
SWIFT_REF = "65624e4c45ee1f86560b7640abe42bec31a25f60"
SWIFT_ORACLE = ROOT / "rust/wire/tools/SwiftOracle.swift"
SWIFT_SOURCES = [
    "Sources/CodexOneAdapters/Downstream/JSONObject.swift",
    "Sources/CodexOneAdapters/Downstream/JSONOrderedWriter.swift",
    "Sources/CodexOneAdapters/Downstream/JSONOrderScanner.swift",
    "Sources/CodexOneAdapters/Downstream/JSONValue.swift",
    "Sources/CodexOneAdapters/Upstream/SSEDecoder.swift",
]
LEGACY_UTF32LE = b"\xfe\xff\0\0"


def run(command, cases, encode):
    inp = b"".join(encode(case) + b"\n" for case in cases)
    result = subprocess.run(command, input=inp, stdout=subprocess.PIPE, cwd=ROOT, check=True)
    rows = result.stdout.decode().splitlines()
    if len(rows) != len(cases):
        raise RuntimeError(f"{command[0]} returned {len(rows)} outcomes for {len(cases)} cases")
    return rows


def swift_token(token):
    if token.startswith(("invalid_", "json_", "upstream_", "incomplete_")):
        return token
    return base64.b64decode(token, validate=True).hex()


def normalized_swift(row, mode):
    if mode == "json":
        return swift_token(row)
    events, done, boundary, consumed = row.split("|")
    return "|".join((",".join(swift_token(event) for event in events.split(",")), done, boundary, consumed))


def compare(label, swift, rust, cases, mode, options=(), allow_macos_sse=False):
    expected = run([*swift, mode, *options], cases, base64.b64encode)
    observed = run([*rust, mode, *options], cases, lambda value: value.hex().encode())
    failures = []
    macos_differences = 0
    for index, (case, old, new) in enumerate(zip(cases, expected, observed)):
        old = normalized_swift(old, mode)
        if old == new:
            continue
        if allow_macos_sse and mode == "sse" and b"\r\r\n" in case:
            macos_differences += 1
            continue
        failures.append(f"case {index}: {case[:80]!r} Swift={old[:100]} Rust={new[:100]}")
    print(f"{label}: {len(cases)} inputs, {len(failures)} unexpected differences", flush=True)
    if macos_differences:
        print(f"  {macos_differences} macOS CRCRLF differences (Linux semantics selected)", flush=True)
    if failures:
        raise RuntimeError("\n".join(failures[:8]))


def decimal_cases(rng):
    numbers = [
        "0", "-0", "1.2500", "1e30", "1e-30", "-.1", "-00", "1e-0000", "01",
        "1.e+2", "-", "+1", "1e+", "--1", "0e1000", "1e128", "1.5e128", "10e-129",
        "0." + "0" * 190 + "1e62",
    ]
    digits = "00123456789"
    for _ in range(5000):
        whole = rng.choice(digits) + "".join(rng.choices(digits, k=rng.randint(0, 130)))
        if whole.startswith("0"):
            whole = "0"
        fraction = rng.choice(["", "." + "".join(rng.choices(digits, k=rng.randint(1, 150)))])
        exponent = rng.choice(["", f"e{rng.randint(-200, 200)}", f"E+{rng.randint(0, 200)}"])
        numbers.append(rng.choice(["", "-"]) + whole + fraction + exponent)
    return [number.encode() for number in numbers]


def legacy_utf32le(document):
    return LEGACY_UTF32LE + document.encode("utf-32-le")


def json_cases():
    corpus = [
        '{"z":{"b":1,"a":2},"z":{"x":3},"a":4}', '{"z":[{"b":1,"a":2}],"z":true}',
        '{"z":null,"z":{"b":2}}', r'{"a":1,"\u0061":2}', r'{"é":{"z":1,"a":2},"e\u0301":{"x":3}}',
        r'{"\"":1,"\\":2,"\/":3,"\u0000":4,"😀":5}', r'{"\uD83D\uDE00":"\u2028\u2029","x":"合成/文本"}',
        '[true,false,null,"",{},[]]', '{"a":1,}', "[1,]", "", " ", "{", "[", "01", "+1", "NaN",
        "1e9999", "1e-9999", '{"a":undefined}', '{"a":1}false', '{"a" 1}', "[1,,2]",
        r'"\uD800"', r'"\uDC00"', r'"\uD800x"', r'"\x00"', "[/*synthetic*/1]", "true false",
        '"\x01"', '{"z":{"y":1,"a":2},"合成":"😀"}', "1", "2", "0", "1.", '"\x01"',
        "[1\r\r\n,2]", r'{"model":1,"mo\u0064el":2}', '{"a":{"model":1,"model":2}}',
    ]
    ignored = [
        "+1", "--1", "-.1", "-", "1a", "1+2", "1.2.3", "1E--2", "fals", "truefalse", "null",
        '{"b":1,}', '"x"', "{}", "01e+", "1\v", r'"\uDDDD"', r'"\uZZZZ"', r'"\x00"',
    ]
    corpus.extend('{"a":1,"a":' + token + "}" for token in ignored)
    for depth in [63, 64, 65, 100, 250, 511, 512, 513]:
        nested = "[" * depth + "0" + "]" * depth
        corpus.extend([nested, r'["a\"b",' + nested + "]"])
    encodings = [
        "utf-8", "utf-8-sig", "utf-16", "utf-16-le", "utf-16-be", "utf-32", "utf-32-le", "utf-32-be",
    ]
    cases = [text.encode(encoding) for text in corpus for encoding in encodings]
    cases.extend([b'"\xff"', b'{"a":1,"a":"\xff"}'])
    cases.extend(map(legacy_utf32le, [
        "1", '{"z":{"y":1,"a":2},"model":"synthetic","a":"合成"}',
        r'{"z":1,"z":{"\uD800":1},"a":2}',
        r'{"z":0,"à":2,"a\u0300":3,"a":1,"合成":4}',
        r'{"z":[{"z":1,"a":2}],"a":{"model":1,"model":2}}',
    ]))
    return cases


def sse_cases(rng):
    lines = [
        "data: 0", "data: {}", "data: [DONE]", 'data: {"b":1,', 'data: "a":"文本/合成"}',
        ": synthetic", "event: synthetic", "data:", "data", "data:\u0301", "data: \u0301",
        "data:\r", "data: {}\r", "data: \0", "data: null", "data: bad", " data: 1",
        "data: {}\r\r", "data: {} \r\r", "event: \0",
    ]
    cases = [
        b"data: \n\n", b": comment\n\n", b"data: {}\n\n", b"data: [DONE]\n\n",
        b"data: {}\r\n\n", b"data: {}\n\r\n", b'data: "\xff"\n\n',
    ]
    for _ in range(3000):
        frames = [[rng.choice(lines) for _ in range(rng.randint(1, 4))] for _ in range(rng.randint(1, 4))]
        complete = rng.choice([True, False])
        stream = bytearray()
        for frame in frames:
            for line in frame:
                stream.extend(line.encode() + rng.choice([b"\n", b"\r\n"]))
            stream.extend(rng.choice([b"\n", b"\r\n"]))
        if not complete:
            stream = stream[:rng.randint(0, len(stream))]
        cases.append(bytes(stream))
    return cases


def check_legacy_duplicate(swift, rust):
    case = legacy_utf32le(r'{"z":1,"model":"first","mo\u0064el":"ignored","a":2}')
    options = ["json", "model"]
    old, = run([*swift, *options], [case], base64.b64encode)
    new, = run([*rust, *options], [case], lambda value: value.hex().encode())
    expected = b'{"a":2,"model":"first","z":1}'
    if swift_token(old) != expected.hex() or new != "invalid_json":
        raise RuntimeError(f"legacy UTF-32LE duplicate fixture: Swift={old} Rust={new}")
    print("legacy UTF-32LE tracked duplicate: Rust returned invalid_json", flush=True)


def compile_swift(output, image):
    sources = [SWIFT_ORACLE.name]
    (output / SWIFT_ORACLE.name).write_bytes(SWIFT_ORACLE.read_bytes())
    for source in SWIFT_SOURCES:
        name = Path(source).name
        with (output / name).open("wb") as staged:
            subprocess.run(["git", "show", f"{SWIFT_REF}:{source}"],
                           cwd=ROOT, stdout=staged, check=True)
        sources.append(name)

    if image:
        docker = [
            "docker", "run", "--rm", "--network", "none", "-i",
            "--mount", f"type=bind,source={output},target=/out",
            "--workdir", "/out", image,
        ]
        subprocess.run([*docker, "swiftc", "-O", *sources, "-o", "/out/wire-swift-oracle"],
                       check=True)
        return [*docker, "/out/wire-swift-oracle"]
    program = output / "wire-swift-oracle"
    subprocess.run(["swiftc", "-O", *sources, "-o", program], cwd=output, check=True)
    return [program]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift-image", help="run Swift in this Linux Docker image")
    args = parser.parse_args()
    rng = random.Random(SEED)
    rust = ["cargo", "run", "--quiet", "--locked", "--manifest-path", MANIFEST, "--example", "wire-oracle", "--"]
    native_macos = sys.platform == "darwin" and not args.swift_image
    # On macOS, /tmp is shared with Docker Desktop. Resolve it for the bind mount.
    with tempfile.TemporaryDirectory(prefix="codexone-wire-", dir="/tmp") as temp:
        swift = compile_swift(Path(temp).resolve(), args.swift_image)
        compare("Decimal", swift, rust, decimal_cases(rng), "json")
        compare("JSON", swift, rust, json_cases(), "json", ["model", "é"])
        check_legacy_duplicate(swift, rust)
        streams = sse_cases(rng)
        for chunk in (1, 7, 4096):
            compare(f"SSE chunk={chunk}", swift, rust, streams, "sse",
                    [str(chunk), "262144", "8388608"], native_macos)
        compare("SSE limited chunk=7", swift, rust, streams, "sse", ["7", "11", "53"], native_macos)


if __name__ == "__main__":
    main()
