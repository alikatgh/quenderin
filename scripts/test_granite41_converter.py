#!/usr/bin/env python3
"""Run actual patched Granite converter methods without importing torch/weights."""
import argparse
import ast
import logging
from pathlib import Path
import re
from types import SimpleNamespace
from jinja2 import Environment

def main():
    p = argparse.ArgumentParser(description=__doc__); p.add_argument('--source', type=Path, required=True); a = p.parse_args()
    tree = ast.parse((a.source / 'conversion/granite.py').read_text())
    original = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'GraniteSwitchModel')
    wanted = {'__init__', '_has_decision_adapter', '_systemone_template', 'set_vocab'}
    selected = [n for n in original.body if isinstance(n, ast.FunctionDef) and n.name in wanted]
    assert {n.name for n in selected} == wanted
    class Base:
        model_arch = 'graniteswitch'
        def __init__(self, hparams, model_tensors):
            self.hparams, self.model_tensors, self.block_count = hparams, model_tensors, hparams['num_hidden_layers']
            self.gguf_writer = SimpleNamespace(add_chat_template=lambda value: setattr(self, 'templates', value))
        def set_vocab(self): pass
    cls = ast.ClassDef(name='Converter', bases=[ast.Name(id='Base', ctx=ast.Load())], keywords=[], body=selected, decorator_list=[])
    module = ast.fix_missing_locations(ast.Module(body=[cls], type_ignores=[]))
    scope = {'Base': Base, 're': re, 'logger': logging.getLogger('granite-fixture'), 'gguf': SimpleNamespace(get_tensor_name_map=lambda arch, count: (arch, count)),
             'jinja_str_or_json': lambda name: '{{ ' + name + ' if ' + name + ' is string else ' + name + ' | tojson }}'}
    exec(compile(module, 'actual-patched-granite-methods', 'exec'), scope)
    model = scope['Converter']({'num_hidden_layers': 42, 'num_adapters': 2, 'max_lora_rank': 64, 'num_attention_heads': 32,
                                'num_key_value_heads': 8, 'hidden_size': 4096, 'adapter_names': ['guardian-core', 'decision']},
                               {f'model.layers.{i}.self_attn.qkv_proj.weight': None for i in range(40)})
    assert model.block_count == 40 and model.tensor_map == ('graniteswitch', 40)
    model.set_vocab()
    template = model.templates[0]
    assert template['name'] == 'systemone'
    rendered = Environment().from_string(template['template']).render(state={'ready': True}, instructions='Choose one', type='lev',
                 options=[{'label': 'X' + str(i), 'description': 'Choice ' + str(i)} for i in range(256)])
    assert 'X255: Choice 255' in rendered and '<|decision|> DECISION' in rendered and 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' not in rendered
    try:
        scope['Converter'](model.hparams, {})
    except ValueError as e: assert 'no' in str(e) and 'tensors' in str(e)
    else: raise AssertionError('Missing weight layers must fail')
    print('Granite actual converter fixtures passed: 42 configured / 40 weight layers, decision metadata/template and 256 explicit labels; no inference')
if __name__ == '__main__': main()
