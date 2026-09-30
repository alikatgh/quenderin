// Shared-manifest recommendations + first-party, automatically refreshed discovery.
export function startingModel(catalog, ram) {
  if (!Number.isFinite(ram) || ram <= 0) return null;
  var p = catalog.recommendation;
  var band = p.ramBands.find(b => ram < b.max);
  var id = band ? band.id : p.defaultId;
  function required(m) { return m.ramGb * (m.paramsBillions <= 3 ? p.smallOverhead : p.largeOverhead); }
  function fits(m) { return required(m) <= ram * p.hardBudget; }
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

function start() {
  var root = document.querySelector('[data-model-releases]');
  var saved;
  var dict = {};
  function t(key, fallback) { return dict[key] || fallback; }
  var last;
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
      source.textContent = m.id.split('/')[0] + (m.license !== 'other' && m.license !== 'see model card' ? ' · ' + m.license : '');
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
}
if (typeof document !== 'undefined') start();
