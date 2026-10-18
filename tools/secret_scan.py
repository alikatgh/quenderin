#!/usr/bin/env python3
"""Redacted credential-pattern check of explicitly staged publication files.

Forbidden credential files are rejected by name and are never opened. Reports
contain file names and rule names only; credentials are never echoed.
"""
import argparse
from pathlib import PurePosixPath
import re
import subprocess
import sys

RULES = {
    'private-key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    'github-token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{60,})\b'),
    'openai-token': re.compile(rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{40,}\b'),
    'huggingface-token': re.compile(rb'\bhf_[A-Za-z0-9]{30,}\b'),
    'aws-access-key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
}


def forbidden(name):
    path = PurePosixPath(name)
    return path.name.startswith(('.env', 'secrets.')) or path.suffix.lower() in ('.pem', '.key', '.p12', '.jks', '.keystore')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', action='store_true', required=True)
    parser.parse_args()
    names = subprocess.check_output(['git', 'diff', '--cached', '--name-only', '-z', '--diff-filter=ACMR']).split(b'\0')
    failures = []
    checked = 0
    for raw in filter(None, names):
        name = raw.decode('utf-8')
        if forbidden(name) or PurePosixPath(name).name.startswith('.'):
            failures.append((name, 'forbidden-publication-file'))
            continue
        data = subprocess.check_output(['git', 'show', ':' + name])
        checked += 1
        for label, pattern in RULES.items():
            if pattern.search(data): failures.append((name, label))
    for name, label in failures:
        print(f'FAIL {label}: {name}', file=sys.stderr)
    if failures:
        print('Publication stopped; credential contents were not printed.', file=sys.stderr)
        return 1
    print(f'Staged publication pattern scan passed: {checked} files. This is a pattern check, not a security audit.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
