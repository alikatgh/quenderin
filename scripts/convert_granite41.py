#!/usr/bin/env python3
"""Convert an already-present, exact official Granite 4.1 8B checkpoint offline.

This command never downloads weights, dependencies or tokenizers. Obtain the
pinned source files yourself, then provide --model-dir. It validates all four
safetensors and every required metadata/tokenizer file before the converter runs.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
import prepare_prism_runtime as runtime
ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / 'shared/granite41-source.json').read_text())

def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()

def verify_source(directory: Path, manifest: dict = MANIFEST) -> dict:
    if directory.is_symlink() or not directory.is_dir(): raise ValueError('Granite source directory must be a regular local directory')
    for item in manifest['artifacts'] + manifest['metadata']:
        name = item['filename']
        if '/' in name or '\\' in name or name.startswith('.'): raise ValueError('Unsafe source manifest filename')
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size != item['bytes'] or sha(path) != item['sha256']:
            raise ValueError('Official pinned Granite file is missing or modified: ' + name)
    config = json.loads((directory / 'config.json').read_text())
    index = json.loads((directory / 'model.safetensors.index.json').read_text())
    ids = {int(m.group(1)) for name in index['weight_map'] if (m := re.match(r'(?:model\.)?layers\.(\d+)\.', name))}
    weights = {x['filename'] for x in manifest['artifacts']}
    if (config.get('architectures') != [manifest['architecture']] or config.get('num_hidden_layers') != manifest['configuredLayers']
            or config.get('hidden_size') != manifest['embeddingSize'] or ids != set(range(manifest['weightLayers']))
            or set(index['weight_map'].values()) != weights):
        raise ValueError('Granite architecture, weight-layer count or shard map differs')
    return {'repository': manifest['repository'], 'revision': manifest['revision'], 'weightLayers': len(ids)}

def convert(source: Path, model: Path, output: Path, outtype: str) -> dict:
    provenance = runtime.verify(source)
    if provenance.get('graniteConverterPatchId') != 'granite41-official-converter-v1': raise ValueError('Exact Granite 4.1 converter patch is required')
    output = output.absolute()
    if output.exists() or output.is_symlink() or Path(str(output) + '.quenderin.json').exists(): raise ValueError('Output and provenance paths must be new; existing files are preserved')
    if output.suffix.lower() != '.gguf' or not output.parent.is_dir(): raise ValueError('Use a .gguf output in an existing directory')
    proof = verify_source(model)
    # Bound this explicit conversion to one worker and one hour. No retries,
    # dependency installs, remote custom code or model downloads are performed.
    if shutil.disk_usage(output.parent).free < 2 * MANIFEST['downloadBytes'] + 1024**3:
        raise ValueError('Conversion needs headroom for a fresh output and intermediates; existing files are preserved')
    staging = Path(tempfile.mkdtemp(prefix='.quenderin-granite41-', dir=output.parent))
    staged = staging / 'granite-switch-4.1-8b.gguf'
    environment = os.environ.copy()
    environment.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_DATASETS_OFFLINE='1', OMP_NUM_THREADS='2', MKL_NUM_THREADS='2')
    try:
        subprocess.run([sys.executable, str(source / 'convert_hf_to_gguf.py'), str(model.resolve()), '--outfile', str(staged), '--outtype', outtype],
                       env=environment, check=True, timeout=3600)
        if staged.is_symlink() or not staged.is_file() or staged.stat().st_size < 1024: raise ValueError('Converter did not produce a valid new output')
        with staged.open('rb') as f:
            if f.read(4) != b'GGUF': raise ValueError('Converter output is not GGUF')
        result = {'version': 1, 'source': proof, 'runtime': provenance, 'outtype': outtype,
                  'bytes': staged.stat().st_size, 'sha256': sha(staged), 'inferenceVerified': False}
        os.link(staged, output)  # Exclusive: a concurrent existing output is preserved.
        with Path(str(output) + '.quenderin.json').open('x') as f: json.dump(result, f, indent=2); f.write('\n')
        staged.unlink()  # Only this command's own staging alias; final output stays.
        staging.rmdir()
        return result
    except BaseException:
        # Retain an incomplete result for diagnosis; never delete an external or
        # already-published output in recovery. The explicit path identifies it.
        print('Conversion staging retained at ' + str(staging), file=sys.stderr)
        raise

def main():
    p = argparse.ArgumentParser(description=__doc__); p.add_argument('--runtime-source', type=Path, required=True); p.add_argument('--model-dir', type=Path, required=True); p.add_argument('--output', type=Path); p.add_argument('--outtype', choices=['f16', 'bf16', 'q8_0'], default='q8_0'); p.add_argument('--verify-only', action='store_true'); a = p.parse_args()
    try:
        if a.verify_only:
            runtime.verify(a.runtime_source); result = verify_source(a.model_dir)
        else:
            if not a.output: p.error('--output is required for conversion')
            result = convert(a.runtime_source, a.model_dir, a.output, a.outtype)
        print(json.dumps(result))
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as e: p.exit(1, f'Granite conversion rejected: {e}\n')
if __name__ == '__main__': main()
