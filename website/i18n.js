/* Quenderin marketing site — tiny client-side i18n.
 * English is hard-coded in index.html (works with JS off / first paint, good for crawlers).
 * Other languages are flat key→string JSON in /i18n/<code>.json, swapped into [data-i18n]
 * (textContent) and [data-i18n-html] (innerHTML) nodes. Language is chosen by ?lang= →
 * saved choice → browser language → English, and remembered in localStorage.
 * Available languages are read from the <select.lang-select> options, so adding a language
 * is just: drop in the JSON + add an <option>. RTL handled via <html dir>. */
(function () {
  'use strict';
  var KEY = 'quenderin_lang';
  var RTL = { ar: 1, ur: 1, fa: 1, he: 1 };

  function selectEl() { return document.querySelector('.lang-select'); }

  function available() {
    var sel = selectEl(), set = { en: 1 };
    if (sel) { for (var i = 0; i < sel.options.length; i++) set[sel.options[i].value] = 1; }
    return set;
  }

  function pick() {
    var ok = available();
    var u = new URLSearchParams(location.search).get('lang');
    if (u && ok[u]) return u;
    try { var s = localStorage.getItem(KEY); if (s && ok[s]) return s; } catch (e) {}
    var n = (navigator.language || 'en').slice(0, 2).toLowerCase();
    return ok[n] ? n : 'en';
  }

  function apply(dict, lang) {
    var root = document.documentElement;
    root.lang = lang;
    root.dir = RTL[lang] ? 'rtl' : 'ltr';
    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      var k = el.getAttribute('data-i18n');
      if (dict[k] != null) el.textContent = dict[k];
    });
    document.querySelectorAll('[data-i18n-html]').forEach(function (el) {
      var k = el.getAttribute('data-i18n-html');
      if (dict[k] != null) el.innerHTML = dict[k];
    });
    if (dict['meta.title']) document.title = dict['meta.title'];
    var md = document.querySelector('meta[name="description"]');
    if (md && dict['meta.description']) md.setAttribute('content', dict['meta.description']);
    var sel = selectEl(); if (sel) sel.value = lang;
  }

  function load(lang) {
    return fetch('i18n/' + lang + '.json', { cache: 'no-cache' })
      .then(function (r) { if (!r.ok) throw new Error('missing ' + lang); return r.json(); })
      .then(function (d) { apply(d, lang); })
      .catch(function () { /* leave whatever is currently shown */ });
  }

  function setLang(lang) {
    try { localStorage.setItem(KEY, lang); } catch (e) {}
    load(lang);
  }

  document.addEventListener('DOMContentLoaded', function () {
    var sel = selectEl();
    var cur = pick();
    if (sel) {
      sel.value = cur;
      sel.addEventListener('change', function () { setLang(this.value); });
    }
    // English already rendered in the HTML; only fetch a dictionary when switching away.
    if (cur !== 'en') load(cur);
  });

  window.__quenderinI18n = { setLang: setLang, load: load };
})();
