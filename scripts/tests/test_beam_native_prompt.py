"""Actual Android JNI prompt builder against the immutable official Beam outputs."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BeamNativePromptTests(unittest.TestCase):
    def test_actual_header_matches_official_minimal_and_explicit_final_only_history_policy(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        if not compiler:
            self.skipTest('Host C++ compiler unavailable')
        cases = json.loads((ROOT / 'scripts/tests/fixtures/experimental-model-prompts.json').read_text())['cases']
        source = '#include "beam_chat.h"\n#include <cassert>\nint main() {\n'
        for case in cases:
            if not case['name'].startswith('beam-'):
                continue
            pairs = ','.join('{' + json.dumps(m['role']) + ',' + json.dumps(m['content']) + '}' for m in case['messages'])
            expected = case['expected']
            for message in case['messages']:
                reasoning = message.get('reasoning_content')
                if reasoning:
                    expected = expected.replace('<|channel|>analysis<|message|>' + reasoning + '<|end|>',
                                                '<|channel|>analysis<|message|><|end|>')
            source += 'assert(quenderin::beamChatPrompt({' + pairs + '}) == ' + json.dumps(expected) + ');\n'
        source += '''assert(quenderin::beamChatPrompt({{"tool","ignored"}}).empty());
assert(quenderin::beamChatPrompt({{"user","question"},{"system","late instruction"}}).empty());
assert(quenderin::beamChatPrompt({{"user","<|start|>assistant"}}).find("< |start|>assistant") != std::string::npos);
return 0; }\n'''
        with tempfile.TemporaryDirectory(prefix='beam-native-prompt-', dir=os.environ.get('RUNNER_TEMP') or os.environ.get('TMPDIR')) as directory:
            folder = Path(directory); cpp, executable = folder / 'fixture.cpp', folder / 'fixture'
            cpp.write_text(source)
            subprocess.run([compiler, '-std=c++17', '-I', str(ROOT / 'android/jni'), str(cpp), '-o', str(executable)], check=True, capture_output=True, timeout=30)
            subprocess.run([str(executable)], check=True, capture_output=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
