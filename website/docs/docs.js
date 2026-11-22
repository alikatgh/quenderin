// Client-side enhancements for Quenderin Docs:
// copy code buttons, mobile drawer, active TOC spy, and zero-network search modal.
(function () {
  "use strict";

  // 1. Copy buttons on code blocks
  document.querySelectorAll(".docs-copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var wrap = btn.closest(".docs-codeblock");
      var code = wrap ? wrap.querySelector("pre code") : null;
      if (!code || !navigator.clipboard) return;
      var text = code.textContent || "";
      navigator.clipboard.writeText(text).then(function () {
        btn.classList.add("is-copied");
        var label = btn.querySelector("span:last-child");
        var prev = label ? label.textContent : "";
        var icon = btn.querySelector(".qi");
        if (icon) icon.className = "qi qi-check";
        if (label) label.textContent = "Copied";
        setTimeout(function () {
          btn.classList.remove("is-copied");
          if (icon) icon.className = "qi qi-copy";
          if (label) label.textContent = prev || "Copy";
        }, 1400);
      }).catch(function () {});
    });
  });

  // 2. Mobile sidebar drawer
  var sidebar = document.getElementById("docs-sidebar");
  var openBtn = document.querySelector(".docs-sidebar-toggle");
  var closeBtn = document.querySelector(".docs-sidebar-close");
  var backdrop = document.getElementById("docs-sidebar-backdrop");

  function setDrawer(open) {
    if (!sidebar) return;
    sidebar.classList.toggle("is-open", open);
    if (backdrop) backdrop.classList.toggle("is-open", open);
    if (openBtn) openBtn.setAttribute("aria-expanded", open ? "true" : "false");
    if (open && closeBtn) closeBtn.focus();
    else if (!open && openBtn && document.activeElement && sidebar.contains(document.activeElement)) {
      openBtn.focus();
    }
  }

  if (openBtn) openBtn.addEventListener("click", function () { setDrawer(!sidebar.classList.contains("is-open")); });
  if (closeBtn) closeBtn.addEventListener("click", function () { setDrawer(false); });
  if (backdrop) backdrop.addEventListener("click", function () { setDrawer(false); });

  // 3. Active "On this page" TOC highlighting
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".docs-toc .docs-toc-list a"));
  if (tocLinks.length && "IntersectionObserver" in window) {
    var linkById = Object.create(null);
    tocLinks.forEach(function (link) {
      var hash = link.getAttribute("href") || "";
      if (hash.charAt(0) === "#") linkById[hash.slice(1)] = link;
    });
    var headings = Object.keys(linkById)
      .map(function (id) { return document.getElementById(id); })
      .filter(Boolean);
    var activeId = headings[0] ? headings[0].id : "";

    function activate(id) {
      if (!id || id === activeId) return;
      activeId = id;
      tocLinks.forEach(function (link) { link.classList.remove("is-active"); });
      if (linkById[id]) linkById[id].classList.add("is-active");
    }
    if (activeId && linkById[activeId]) linkById[activeId].classList.add("is-active");

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) activate(entry.target.id);
      });
    }, { rootMargin: "-76px 0px -72% 0px", threshold: 0 });
    headings.forEach(function (h) { io.observe(h); });
  }

  // 4. Instant Documentation Search Modal (local search-index.js + JSON fallback)
  var searchBtn = document.getElementById("docs-search-trigger");
  var dialog = document.getElementById("docs-search-dialog");
  var input = document.getElementById("docs-search-input");
  var resultsEl = document.getElementById("docs-search-results");
  var closeSearchBtn = document.getElementById("docs-search-close");
  var indexData = Array.isArray(window.QUENDERIN_DOCS_INDEX) ? window.QUENDERIN_DOCS_INDEX : null;
  var selectedIdx = 0;

  function loadIndex() {
    if (indexData) return Promise.resolve(indexData);
    return fetch("search-index.json")
      .then(function (r) { return r.ok ? r.json() : []; })
      .then(function (data) {
        indexData = Array.isArray(data) ? data : [];
        return indexData;
      })
      .catch(function () { return []; });
  }

  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function scoreItem(item, terms) {
    var titleL = (item.title || "").toLowerCase();
    var catL = (item.category || "").toLowerCase();
    var summaryL = (item.summary || "").toLowerCase();
    var sourcesL = (item.sources || []).join(" ").toLowerCase();
    var headingsL = (item.headings || []).map(function (h) { return h.text.toLowerCase(); }).join(" ");
    var bodyL = (item.body || "").toLowerCase();
    var score = 0;

    for (var i = 0; i < terms.length; i++) {
      var t = terms[i];
      var hit = false;
      if (titleL.indexOf(t) !== -1) { score += titleL.indexOf(t) === 0 ? 35 : 22; hit = true; }
      if (headingsL.indexOf(t) !== -1) { score += 12; hit = true; }
      if (sourcesL.indexOf(t) !== -1) { score += 10; hit = true; }
      if (catL.indexOf(t) !== -1) { score += 6; hit = true; }
      if (summaryL.indexOf(t) !== -1) { score += 5; hit = true; }
      if (bodyL.indexOf(t) !== -1) { score += 2; hit = true; }
      if (!hit) return 0;
    }
    return score;
  }

  function findMatchedAnchor(item, terms) {
    var hs = item.headings || [];
    for (var i = 0; i < hs.length; i++) {
      var tl = hs[i].text.toLowerCase();
      for (var j = 0; j < terms.length; j++) {
        if (tl.indexOf(terms[j]) !== -1) return "#" + hs[i].id;
      }
    }
    return "";
  }

  function buildSnippet(item, terms) {
    if (!terms.length) return item.summary || "";
    var text = item.body || item.summary || "";
    var lower = text.toLowerCase();
    var pos = -1;
    for (var i = 0; i < terms.length; i++) {
      var p = lower.indexOf(terms[i]);
      if (p !== -1 && (pos === -1 || p < pos)) pos = p;
    }
    if (pos === -1) return item.summary || "";
    var start = Math.max(0, pos - 48);
    var slice = text.slice(start, start + 150).trim();
    return (start > 0 ? "…" : "") + slice + (start + 150 < text.length ? "…" : "");
  }

  function renderResults(query) {
    if (!resultsEl) return;
    function paint(items) {
      var terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
      var ranked;
      if (!terms.length) {
        ranked = items.slice(0, 12).map(function (it) { return { item: it, score: 1, hash: "" }; });
      } else {
        ranked = items
          .map(function (it) {
            return { item: it, score: scoreItem(it, terms), hash: findMatchedAnchor(it, terms) };
          })
          .filter(function (entry) { return entry.score > 0; })
          .sort(function (a, b) { return b.score - a.score; })
          .slice(0, 16);
      }
      selectedIdx = 0;
      if (!ranked.length) {
        resultsEl.innerHTML = '<div class="docs-search-empty">No matching topics or source files for “' + escapeHtml(query) + '”.</div>';
        return;
      }
      resultsEl.innerHTML = ranked.map(function (entry, idx) {
        var it = entry.item;
        var href = escapeHtml((it.href || "./") + entry.hash);
        var snippet = escapeHtml(buildSnippet(it, terms));
        var icon = escapeHtml(it.icon || "qi-file-text");
        return (
          '<a class="docs-search-hit' + (idx === 0 ? " is-selected" : "") + '" href="' + href + '">' +
            '<span class="docs-search-hit-top">' +
              '<span class="docs-search-hit-title"><span class="qi ' + icon + '" aria-hidden="true"></span><span>' + escapeHtml(it.title) + '</span></span>' +
              '<span class="docs-search-hit-cat">' + escapeHtml(it.category || "") + '</span>' +
            '</span>' +
            '<span class="docs-search-hit-snippet">' + snippet + '</span>' +
          '</a>'
        );
      }).join("");
    }
    if (indexData) paint(indexData);
    else loadIndex().then(paint);
  }

  function openSearch() {
    if (!dialog) return;
    if (sidebar && sidebar.classList.contains("is-open")) setDrawer(false);
    if (typeof dialog.showModal === "function") {
      if (!dialog.open) dialog.showModal();
    } else {
      dialog.setAttribute("open", "");
    }
    if (input) {
      input.focus();
      input.select();
    }
    renderResults(input ? input.value : "");
  }

  function closeSearch() {
    if (!dialog) return;
    if (typeof dialog.close === "function" && dialog.open) dialog.close();
    else dialog.removeAttribute("open");
  }

  if (searchBtn) searchBtn.addEventListener("click", openSearch);
  if (closeSearchBtn) closeSearchBtn.addEventListener("click", closeSearch);
  if (dialog) {
    dialog.addEventListener("click", function (ev) {
      if (ev.target === dialog) closeSearch();
    });
  }
  if (input) {
    input.addEventListener("input", function () { renderResults(input.value); });
    input.addEventListener("keydown", function (ev) {
      var hits = resultsEl ? resultsEl.querySelectorAll(".docs-search-hit") : [];
      if (!hits.length) return;
      if (ev.key === "ArrowDown") {
        ev.preventDefault();
        hits[selectedIdx].classList.remove("is-selected");
        selectedIdx = (selectedIdx + 1) % hits.length;
        hits[selectedIdx].classList.add("is-selected");
        hits[selectedIdx].scrollIntoView({ block: "nearest" });
      } else if (ev.key === "ArrowUp") {
        ev.preventDefault();
        hits[selectedIdx].classList.remove("is-selected");
        selectedIdx = (selectedIdx - 1 + hits.length) % hits.length;
        hits[selectedIdx].classList.add("is-selected");
        hits[selectedIdx].scrollIntoView({ block: "nearest" });
      } else if (ev.key === "Enter" && hits[selectedIdx]) {
        ev.preventDefault();
        window.location.href = hits[selectedIdx].getAttribute("href");
      }
    });
  }

  document.addEventListener("keydown", function (ev) {
    if (ev.key === "Escape") {
      if (sidebar && sidebar.classList.contains("is-open")) setDrawer(false);
      return;
    }
    var tag = document.activeElement ? document.activeElement.tagName : "";
    var isEditable = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || (document.activeElement && document.activeElement.isContentEditable);
    if ((ev.key === "k" || ev.key === "K") && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      openSearch();
    } else if (ev.key === "/" && !ev.metaKey && !ev.ctrlKey && !ev.altKey && !isEditable) {
      ev.preventDefault();
      openSearch();
    }
  });

  // 5. Open enclosing <details> when deep-linking to an anchor inside a folded section
  function revealHashTarget() {
    if (!window.location.hash) return;
    var id = decodeURIComponent(window.location.hash.slice(1));
    if (!id) return;
    var target = document.getElementById(id);
    if (!target) return;
    var node = target;
    while (node && node !== document.body) {
      if (node.tagName === "DETAILS") node.open = true;
      node = node.parentElement;
    }
    target.scrollIntoView({ block: "start" });
  }
  revealHashTarget();
  window.addEventListener("hashchange", revealHashTarget);
})();
