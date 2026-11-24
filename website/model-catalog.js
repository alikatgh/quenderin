// Shared-manifest recommendations + first-party, automatically refreshed discovery.
export function startingModel(catalog, ram) {
  if (!Number.isFinite(ram) || ram <= 0) return null;
  var p = catalog.recommendation;
  var band = p.ramBands.find(b => ram < b.max);
  var id = band ? band.id : p.defaultId;
  function required(m) { return m.ramGb * (m.paramsBillions <= 3 ? p.smallOverhead : p.largeOverhead); }
  // The public calculator describes ordinary builds. Experimental custom-runtime
  // models remain manual choices in a compatible app, never a RAM-only recommendation.
  function fits(m) {
    return !/bonsai|muse|jais3|minicpm-v47|lfm25|nemotron35|experimental|PTQ1_0|PQ2_0/i.test(
      [m.id, m.label, m.filename, m.quantization].join(' '))
      && required(m) <= ram * p.hardBudget;
  }
  var model = catalog.models.find(m => m.id === id);
  if (!model || !fits(model)) {
    model = catalog.models.filter(fits).sort((a, b) => b.ramGb - a.ramGb)[0];
  }
  return model ? { model: model, requiredGb: required(model) } : null;
}

export function visibleReleases(data, budget = Infinity, limit = 6) {
  return (data.models || []).filter(m => typeof m.name === 'string' && m.status === 'discovered'
    && Number.isFinite(m.downloadBytes) && m.downloadBytes > 0 && m.downloadBytes <= budget
    && /^https:\/\/huggingface\.co\/[\w.-]+\/[\w.-]+$/.test(m.sourceUrl))
    .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt)).slice(0, limit);
}

// A quantizer's account is not the model author. Only a recognized original
// namespace selects a local mark; unknown authors keep a readable text heading.
export function releaseBrand(model) {
  var authors = {
    'qwen': { family: 'qwen', name: 'Qwen' },
    'deepseek-ai': { family: 'deepseek', name: 'DeepSeek' },
    'meta-llama': { family: 'llama', name: 'Meta' },
    'google': { family: 'gemma', name: 'Google' },
    'microsoft': { family: 'phi', name: 'Microsoft' },
    'mistralai': { family: 'mistral', name: 'Mistral AI' },
    'nvidia': { family: 'nemotron', name: 'NVIDIA' },
    'liquidai': { family: 'lfm', name: 'Liquid AI' },
    'openbmb': { family: 'minicpm', name: 'OpenBMB' },
    'prism-ml': { family: 'bonsai', name: 'PrismML' },
    'ifm': { family: 'jais', name: 'Jais' }
  };
  var base = typeof model.baseModel === 'string' ? model.baseModel : '';
  var match = /^([\w.-]+)\/[\w.-]+$/.exec(base);
  var author = match ? match[1].toLowerCase() : '';
  return Object.hasOwn(authors, author) ? authors[author] : null;
}

export function parseRowRamGb(text) {
  var m = /([\d.]+)\s*GB/i.exec(String(text || ''));
  return m ? Number.parseFloat(m[1]) : Number.POSITIVE_INFINITY;
}

export function isExperimentalModelRow(modelId, roleText) {
  return /^(?:bonsai2-|muse-|beam-|nemotron|jais3-|minicpm-|lfm25-)/i.test(String(modelId || ''))
    || /experimental/i.test(String(roleText || ''));
}

export function filterCuratedRow(rowMeta, query, tier) {
  var mode = tier || 'all';
  if (mode === 'phone' && !(rowMeta.ramGb <= 4)) return false;
  if (mode === 'laptop' && !(rowMeta.ramGb <= 12)) return false;
  if (mode === 'workstation' && !(rowMeta.ramGb > 12)) return false;
  if (mode === 'stable' && rowMeta.experimental) return false;
  var terms = String(query || '').trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return true;
  var haystack = [rowMeta.id, rowMeta.name, rowMeta.role, rowMeta.download, rowMeta.ram, rowMeta.quant]
    .join(' ').toLowerCase();
  return terms.every(function (term) { return haystack.includes(term); });
}

function start() {
  var root = document.querySelector('[data-model-releases]');
  var saved;
  var dict = {};
  function t(key, fallback) { return dict[key] || fallback; }
  var last;
  function initCatalogExplorer() {
    var explorers = document.querySelectorAll('[data-catalog-explorer]');
    if (!explorers.length) return;
    explorers.forEach(function (explorer) {
      var search = explorer.querySelector('[data-catalog-search]');
      var clearBtn = explorer.querySelector('[data-catalog-clear]');
      var chips = Array.prototype.slice.call(explorer.querySelectorAll('[data-catalog-tier]'));
      var countEl = explorer.querySelector('[data-catalog-count]');
      var emptyEl = explorer.querySelector('[data-catalog-empty]');
      var resetBtn = explorer.querySelector('[data-catalog-reset]');
      var table = explorer.querySelector('.model-spec-table');
      if (!table) return;
      var rows = Array.prototype.slice.call(table.querySelectorAll('tbody tr'));
      var activeTier = 'all';

      function readMeta(tr) {
        var cells = tr.children;
        var id = tr.getAttribute('data-model-id') || '';
        var name = cells[0] ? cells[0].textContent.trim() : '';
        var role = cells[1] ? cells[1].textContent.trim() : '';
        var download = cells[2] ? cells[2].textContent.trim() : '';
        var ram = cells[3] ? cells[3].textContent.trim() : '';
        var quant = cells[4] ? cells[4].textContent.trim() : '';
        return {
          id: id,
          name: name,
          role: role,
          download: download,
          ram: ram,
          quant: quant,
          ramGb: parseRowRamGb(ram),
          experimental: isExperimentalModelRow(id, role)
        };
      }

      function applyFilter() {
        var q = search ? search.value : '';
        var shown = 0;
        rows.forEach(function (tr) {
          var matched = filterCuratedRow(readMeta(tr), q, activeTier);
          tr.hidden = !matched;
          if (matched) shown += 1;
        });
        if (clearBtn) clearBtn.hidden = q.trim().length === 0;
        if (countEl) {
          var tpl = t('catalog.filter.count', 'Showing {shown} of {total} models');
          countEl.textContent = tpl.replace('{shown}', String(shown)).replace('{total}', String(rows.length));
        }
        if (emptyEl) emptyEl.hidden = shown > 0;
      }

      if (search) {
        search.addEventListener('input', applyFilter);
        search.addEventListener('keydown', function (e) {
          if (e.key === 'Escape' && search.value) {
            search.value = '';
            applyFilter();
          }
        });
      }
      if (clearBtn && search) {
        clearBtn.addEventListener('click', function () {
          search.value = '';
          search.focus();
          applyFilter();
        });
      }
      chips.forEach(function (chip) {
        chip.addEventListener('click', function () {
          activeTier = chip.getAttribute('data-catalog-tier') || 'all';
          chips.forEach(function (btn) {
            var active = btn === chip;
            btn.classList.toggle('is-active', active);
            btn.setAttribute('aria-pressed', active ? 'true' : 'false');
          });
          applyFilter();
        });
      });
      if (resetBtn) {
        resetBtn.addEventListener('click', function () {
          if (search) search.value = '';
          activeTier = 'all';
          chips.forEach(function (btn) {
            var isAll = btn.getAttribute('data-catalog-tier') === 'all';
            btn.classList.toggle('is-active', isAll);
            btn.setAttribute('aria-pressed', isAll ? 'true' : 'false');
          });
          applyFilter();
          if (search) search.focus();
        });
      }
      document.addEventListener('quenderin:language', function (e) {
        if (e && e.detail) dict = e.detail;
        applyFilter();
      });
      applyFilter();
    });
  }
  function render(data) {
    last = data;
    if (!root) return;
    var select = root.querySelector('[data-release-budget]');
    var budget = select ? Number(select.value) : Infinity;
    var list = root.querySelector('[data-release-list]');
    list.replaceChildren();
    var limit = Number(root.dataset.limit) || 6;
    var entries = visibleReleases(data, budget, limit);
    var more = root.querySelector('[data-release-more]');
    if (more) more.hidden = visibleReleases(data, budget, 100).length <= limit;
    entries.forEach(function (m) {
      var article = document.createElement('article');
      article.className = 'release-model';
      var h = document.createElement('h3');
      var brand = releaseBrand(m);
      if (brand) {
        var mark = document.createElement('span');
        mark.className = 'model-fam fam-' + brand.family;
        mark.setAttribute('aria-hidden', 'true');
        h.appendChild(mark);
      }
      var a = document.createElement('a');
      a.href = m.sourceUrl;
      a.rel = 'noopener';
      a.textContent = m.name;
      h.appendChild(a);
      var details = document.createElement('p');
      details.className = 'release-spec';
      details.textContent = (m.downloadBytes / 1e9).toFixed(1) + ' GB · ' + m.quantization;
      var date = document.createElement('p');
      date.className = 'release-date';
      date.textContent = t('catalog.published', 'Model released') + ' ' + new Date(m.createdAt).toLocaleDateString(document.documentElement.lang);
      var source = document.createElement('p');
      source.className = 'release-source';
      source.textContent = (brand ? brand.name + ' · ' : '') + 'GGUF: ' + m.sourceUrl.split('/')[3]
        + (m.license !== 'other' && m.license !== 'see model card' ? ' · ' + m.license : '');
      article.append(h, details, date, source);
      list.appendChild(article);
    });
    if (!entries.length) {
      var empty = document.createElement('p');
      empty.textContent = t('catalog.empty', 'No recent release in this download range. Try a larger range or choose a curated model below.');
      list.appendChild(empty);
    }
    var date = new Date(data.checkedAt);
    var current = data.freshness === 'live' && Date.now() - date.getTime() < 7200000;
    var status = root.querySelector('[data-release-status]');
    status.textContent = (current ? t('catalog.checked', 'Checked') : t('catalog.saved', 'Saved snapshot')) + ' · '
      + (Number.isFinite(date.getTime()) ? date.toLocaleString(document.documentElement.lang) : '—')
      + (data.partial ? ' · ' + t('catalog.partial', 'Some sources unavailable') : '');
  }
  if (root) {
    var select = root.querySelector('[data-release-budget]');
    if (select) select.addEventListener('change', function () { if (last) render(last); });
    var more = root.querySelector('[data-release-more]');
    if (more) more.addEventListener('click', function () { root.dataset.limit = '20'; if (last) render(last); });
    // Static/offline previews retain the dated snapshot. Live production makes only
    // a same-origin request; the Worker supplies cached public upstream metadata.
    fetch('data/model-releases.json', { cache: 'no-cache' }).then(r => {
      if (!r.ok) throw new Error(); return r.json();
    }).then(data => { saved = data; if (!last) render({ ...data, freshness: 'saved' }); }).catch(function () {});
    fetch('/api/model-releases', { cache: 'no-cache', signal: AbortSignal.timeout(16000) }).then(r => {
      if (!r.ok) throw new Error(); return r.json();
    }).then(data => render(data)).catch(function () { if (saved) render({ ...saved, freshness: 'saved' }); });
    document.addEventListener('quenderin:language', function (e) { dict = e.detail; if (last) render(last); });
  }
  var ram = document.getElementById('fit-ram');
  if (ram) fetch('data/model-catalog.json', { cache: 'no-cache' }).then(r => {
    if (!r.ok) throw new Error(); return r.json();
  }).then(function (catalog) {
    function renderFit() {
      var gb = Number(ram.value);
      var pick = startingModel(catalog, gb);
      document.getElementById('fit-ram-out').textContent = gb + ' GB';
      if (!pick) return;
      document.getElementById('fit-model').textContent = pick.model.label.replace(/ \(.*\)$/, '');
      document.getElementById('fit-dl').textContent = pick.model.sizeLabel.replace(' download', '');
      document.getElementById('fit-quant').textContent = pick.model.quantization;
      document.getElementById('fit-foot-gb').textContent = '~' + pick.requiredGb.toFixed(1);
      document.getElementById('fit-foot-dev').textContent = gb;
      var bar = document.getElementById('fit-bar-fill');
      bar.style.width = Math.min(100, pick.requiredGb / gb * 100) + '%';
      bar.classList.toggle('tight', pick.requiredGb / gb > 0.65);
    }
    ram.addEventListener('input', renderFit);
    renderFit();
  }).catch(function () {});
  initCatalogExplorer();
}
if (typeof document !== 'undefined') start();
