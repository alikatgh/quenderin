#!/usr/bin/env python3
"""Render marketing tables/SEO/calculator data from the canonical app manifest.

No dependency/network requests. --check fails CI if any generated output drifts.
The live discovery snapshot is separate: metadata cannot silently change app defaults.
"""
from __future__ import annotations
import hashlib
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BEGIN = '<!-- BEGIN GENERATED: website-models -->'
END = '<!-- END GENERATED: website-models -->'


def policy(text: str) -> dict:
    body = text.split('export function getRecommendedModelIdForTotalRam', 1)[1].split('\n}', 1)[0]
    bands = [{'max': float(ram), 'id': mid} for ram, mid in re.findall(
        r"if \(totalRamGb < ([\d.]+)\) return '([\w.-]+)'", body)]
    default = re.findall(r"^    return '([\w.-]+)'", body, re.M)
    if not bands or len(default) != 1:
        raise ValueError('Recommendation parser needs updating; do not ship a stale calculator')
    def number(name: str) -> float:
        return float(re.search(rf'export const {name} = ([\d.]+);', text).group(1))
    return {'ramBands': bands, 'defaultId': default[0],
            'hardBudget': number('MEMORY_BUDGET_HARD'),
            'smallOverhead': number('MODEL_OVERHEAD_MULTIPLIER_BASE'),
            'largeOverhead': number('MODEL_OVERHEAD_MULTIPLIER_LARGE')}


def family(model: dict) -> str:
    mid = model['id']
    return next((f for f in ['qwen', 'deepseek', 'gemma', 'phi', 'mistral', 'llama'] if mid.startswith(f)), 'llama')


def rows(models: list[dict]) -> str:
    result = []
    for m in sorted(models, key=lambda m: (m['id'] != 'qwen3-4b', -m['paramsBillions'], m['id'])):
        name, _, role = m['label'].partition(' (')
        role = role.rstrip(')') or 'Chat'
        # Present a use case, not an absolute quality leaderboard.
        role = {'Best Quality': 'Desktop chat', 'Best Agent, Big Download': 'Agent tasks · fast SSD',
                'Low RAM': 'Low memory', 'Light': 'Lightweight chat'}.get(role, role)
        roles = {'Everyday': 'everyday', 'Agent tasks · fast SSD': 'agent', 'Desktop chat': 'desktop',
                 'Multilingual': 'multilingual', 'Reasoning': 'reasoning', 'All-Rounder': 'allrounder',
                 'Coding': 'coding', 'Efficient': 'efficient', 'Balanced': 'balanced',
                 'Lightweight chat': 'light', 'Low memory': 'lowram'}
        role_key = roles.get(role)
        role_attr = f' data-i18n="catalog.role.{role_key}"' if role_key else ''
        if role_key:
            role = json.loads((ROOT / 'website/i18n/en.json').read_text())['catalog.role.' + role_key]
        url = m['url'].split('/resolve/', 1)[0]
        h = html.escape
        note = ' resident*' if m['id'] == 'qwen36-35b-a3b' else ''
        result.append(f'<tr data-model-id="{h(m["id"])}"><td><span class="model-fam fam-{family(m)}" aria-hidden="true"></span>'
                      f'<a href="{h(url)}" rel="noopener">{h(name)}</a></td><td{role_attr}>{h(role)}</td>'
                      f'<td>{h(m["sizeLabel"].replace(" download", ""))}</td><td>~{m["ramGb"]:g} GB{note}</td>'
                      f'<td>{h(m["quantization"])}</td></tr>')
    return '\n'.join(result)


def release_cards(data: dict) -> str:
    cards = []
    for m in data['models'][:6]:
        h = html.escape
        license_text = '' if m['license'] in ('other', 'see model card') else ' · ' + m['license']
        cards.append(f'<article class="release-model"><h3><a href="{h(m["sourceUrl"])}" rel="noopener">{h(m["name"])}</a></h3>'
                     f'<p class="release-spec">{m["downloadBytes"] / 1e9:.1f} GB · {h(m["quantization"])}</p>'
                     f'<p class="release-date">Model released {h(m["createdAt"][:10])}</p>'
                     f'<p class="release-source">{h(m["id"].split("/")[0] + license_text)}</p></article>')
    return '\n'.join(cards)


def main() -> int:
    check = '--check' in sys.argv
    raw = (ROOT / 'shared/model-catalog.json').read_bytes()
    data = json.loads(raw)
    models = data['models']
    rec = policy((ROOT / 'src/constants.ts').read_text())
    releases = json.loads((ROOT / 'website/data/model-releases.json').read_text())
    ids = {m['id'] for m in models}
    if not all(b['id'] in ids for b in rec['ramBands']) or rec['defaultId'] not in ids:
        raise ValueError('Recommendation refers to a missing model')
    output = {'version': data['version'], 'catalogSha256': hashlib.sha256(raw).hexdigest(),
              'models': models, 'recommendation': rec}
    seed = json.dumps(releases, indent=2) + '\n'
    targets = {ROOT / 'website/data/model-catalog.json': json.dumps(output, indent=2) + '\n',
               ROOT / 'apple/QuenderinKit/Sources/QuenderinKit/Resources/model-releases.json': seed,
               ROOT / 'android/app/src/main/assets/model-releases.json': seed}
    for name in ['index.html', 'models.html']:
        path = ROOT / 'website' / name
        text = path.read_text()
        start, rest = text.split(BEGIN, 1)
        _, tail = rest.split(END, 1)
        text = start + BEGIN + '\n' + rows(models) + '\n' + END + tail
        text = re.sub(r'(<div class="release-models" data-release-list>).*?(</div>)',
                      lambda m: m[1] + '\n' + release_cards(releases) + '\n' + m[2], text, flags=re.S)
        text = re.sub(r'(<p class="release-status" data-release-status aria-live="polite">).*?(</p>)',
                      lambda m: m[1] + 'Saved snapshot · ' + releases['checkedAt'][:16].replace('T', ' ') + ' UTC' + m[2], text, flags=re.S)
        schema = {'@context': 'https://schema.org', '@type': 'ItemList', 'name': 'Quenderin curated model catalog',
                  'itemListElement': [{'@type': 'ListItem', 'position': i + 1, 'name': m['label'],
                                       'url': m['url'].split('/resolve/', 1)[0]} for i, m in enumerate(models)]}
        text = re.sub(r'(<script type="application/ld\+json" id="model-catalog-schema">).*?(</script>)',
                      lambda m: m[1] + '\n' + json.dumps(schema) + '\n' + m[2], text, flags=re.S)
        targets[path] = text
    stale = []
    for path, content in targets.items():
        if not path.exists() or path.read_text() != content:
            stale.append(str(path.relative_to(ROOT)))
            if not check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
    if check and stale:
        print('Stale website catalog: ' + ', '.join(stale) + '. Run npm run gen:website-catalog.')
        return 1
    print(f'Website catalog: {len(models)} models; calculator and SEO in sync.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
