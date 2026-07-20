/* Blog posts: a Copy button on every code block. Progressive enhancement — the
   posts read fine with JS off; this just adds the convenience. */
(function () {
  'use strict';
  var blocks = document.querySelectorAll('.legal .codeblock');
  if (!blocks.length) return;

  blocks.forEach(function (cb) {
    var pre = cb.querySelector('pre');
    if (!pre) return;

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'copy-btn';
    btn.textContent = 'Copy';
    btn.setAttribute('aria-label', 'Copy code to clipboard');

    var revert;
    function copied() {
      btn.textContent = 'Copied';
      btn.classList.add('is-copied');
      clearTimeout(revert);
      revert = setTimeout(function () {
        btn.textContent = 'Copy';
        btn.classList.remove('is-copied');
      }, 1600);
    }
    function fallback(text) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); copied(); } catch (e) { /* no-op */ }
      document.body.removeChild(ta);
    }

    btn.addEventListener('click', function () {
      var text = pre.innerText;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(copied).catch(function () { fallback(text); });
      } else {
        fallback(text);
      }
    });

    cb.appendChild(btn);
  });
})();

/* Scroll-progress bar — the same thin brand line the homepage uses (main.js),
   reused here so long posts get read-progress too. */
(function () {
  if (!document.querySelector('main.legal')) return;
  var prog = document.createElement('div');
  prog.className = 'scroll-progress';
  prog.setAttribute('aria-hidden', 'true');
  document.body.appendChild(prog);
  var update = function () {
    var h = document.documentElement;
    var max = h.scrollHeight - h.clientHeight;
    prog.style.transform = 'scaleX(' + (max > 0 ? (h.scrollTop / max).toFixed(4) : 0) + ')';
  };
  update();
  window.addEventListener('scroll', update, { passive: true });
  window.addEventListener('resize', update, { passive: true });
})();

/* Reading time — words / 220 wpm, appended to the post's date line. */
(function () {
  var main = document.querySelector('main.legal');
  var meta = main && main.querySelector('.legal-updated');
  if (!main || !meta || meta.querySelector('.read-time')) return;
  var words = (main.innerText || '').trim().split(/\s+/).filter(Boolean).length;
  if (words < 60) return;
  var mins = Math.max(1, Math.round(words / 220));
  var span = document.createElement('span');
  span.className = 'read-time';
  span.textContent = ' · ' + mins + ' min read';
  meta.appendChild(span);
})();
