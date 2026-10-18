#!/usr/bin/env python3
"""Small real safety-code fixtures, using pinned stb headers; no model weights."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
ROOT = Path(__file__).resolve().parent.parent

def main():
    p = argparse.ArgumentParser(description=__doc__); p.add_argument('--source', type=Path, required=True); p.add_argument('--work', type=Path, required=True); a = p.parse_args()
    compiler = shutil.which('clang++') or shutil.which('g++') or shutil.which('cl')
    if not compiler: p.error('A C++17 compiler is required')
    if not (a.source / 'vendor/stb/stb_image.h').is_file(): p.error('Pinned Prism stb header is missing')
    if a.work.exists() or a.work.is_symlink(): p.error('Fixture work directory must be new')
    a.work.mkdir(parents=True)
    executable = a.work / ('vision-safety.exe' if Path(compiler).name.lower() in ('cl', 'cl.exe') else 'vision-safety')
    if Path(compiler).name.lower() in ('cl', 'cl.exe'):
        command = [compiler, '/std:c++17', '/EHsc', '/utf-8', '/DQV_STB_ALLOCATION_BUDGET=1048576', '/I' + str(ROOT/'native/vision'), '/I' + str(a.source/'vendor'), str(ROOT/'native/vision/vision_safety.cpp'), str(ROOT/'native/vision/tests/safety.cpp'), '/Fe:' + str(executable)]
    else:
        command = [compiler, '-std=c++17', '-O0', '-DQV_STB_ALLOCATION_BUDGET=1048576', '-I' + str(ROOT/'native/vision'), '-I' + str(a.source/'vendor'), str(ROOT/'native/vision/vision_safety.cpp'), str(ROOT/'native/vision/tests/safety.cpp'), '-o', str(executable)]
    subprocess.run(command, cwd=a.work, check=True, timeout=60)
    subprocess.run([str(executable.resolve())], check=True, timeout=10)
    print('Vision safety fixtures passed (real decoder, bounds, templates and reasoning filter; no inference)')
if __name__ == '__main__': main()
