#!/usr/bin/env python3
"""Convert an offline provider catalog into a private model profile snapshot."""
import argparse
import json
import os
import re
import time


def convert(source, models, source_label, revision, client_versions):
    def label(value):
        return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9._-]{1,64}', value)
    if not label(source_label) or not label(revision) or not 1 <= len(client_versions) <= 8 or len(set(client_versions)) != len(client_versions) or not all(map(label, client_versions)):
        raise ValueError('Invalid labels')
    if not 1 <= len(models) <= 32 or len(set(models)) != len(models):
        raise ValueError('Invalid model selection')
    entries = source['models']
    if not isinstance(entries, list):
        raise ValueError('Invalid catalog')
    indexed = {}
    for entry in entries:
        slug = entry['slug']
        if not isinstance(slug, str) or not slug or slug in indexed:
            raise ValueError('Invalid or duplicate model')
        indexed[slug] = entry
    result = []
    for model in models:
        entry = indexed[model]
        guidance = entry.get('base_instructions')
        if not isinstance(guidance, str) or not guidance.strip() or len(json.dumps(entry, ensure_ascii=False, allow_nan=False, separators=(',', ':')).replace('/', r'\/').encode()) > 262144 or len(model.encode()) > 128:
            raise ValueError('Invalid profile')
        result.append(dict(id=model, upstream=entry))
    return dict(version=1, source=source_label, revision=revision,
                capturedAtUnixSeconds=int(time.time()), clientVersions=client_versions, models=result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--model', action='append', required=True)
    parser.add_argument('--source-label', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--client-version', action='append', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    try:
        with open(args.source, encoding='utf-8') as source:
            result = convert(json.load(source), args.model, args.source_label, args.revision, args.client_version)
        data = (json.dumps(result, ensure_ascii=False, allow_nan=False, indent=2) + '\n').encode()
        if len(data) > 4194304:
            raise ValueError('Snapshot too large')
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(data)
    except (OSError, ValueError, KeyError, TypeError):
        parser.exit(1, 'Import failed\n')
    print(f'Imported {len(result["models"])} models')


if __name__ == '__main__':
    main()
