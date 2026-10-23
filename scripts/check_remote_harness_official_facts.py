"""Verify that native replay inputs retain their captured-runtime provenance."""
import hashlib
import json
from pathlib import Path


def verify(raw, provenance):
    if len(raw) > 262144 or len(raw) != provenance.get('factsBytes'):
        raise ValueError('Official runtime facts size differs')
    if hashlib.sha256(raw).hexdigest() != provenance.get('factsSHA256'):
        raise ValueError('Official runtime facts digest differs')
    facts = json.loads(raw)
    if (provenance.get('schema') != 1 or facts.get('schema') != 1
            or facts.get('runtime') != 'official-' + provenance.get('harnessVersion', '')
            or facts.get('source') != provenance.get('harnessSourceInspection')
            or facts.get('scriptedModelCalls') != 2 or facts.get('inertToolExecutions') != 1
            or len(facts.get('frames', [])) != provenance.get('capturedFrames')):
        raise ValueError('Official runtime facts identity differs')


def main():
    shared = Path(__file__).resolve().parents[1] / 'shared'
    provenance = json.loads((shared / 'remote-harness-official-runtime-provenance.json').read_bytes())
    verify((shared / 'remote-harness-official-runtime-facts.json').read_bytes(), provenance)
    print('OFFICIAL_RUNTIME_CAPTURE_VERIFIED: exact captured bytes and provenance')


if __name__ == '__main__':
    main()
