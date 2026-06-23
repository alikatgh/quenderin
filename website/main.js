// Quenderin marketing site — tiny, dependency-free, first-party only.
(function () {
  "use strict";

  // Footer year
  var yearEl = document.getElementById("year");
  if (yearEl) yearEl.textContent = String(new Date().getFullYear());

  // Dark / light theme toggle (initial mode is set by the inline head script)
  var themeToggle = document.querySelector(".theme-toggle");
  if (themeToggle) {
    var root = document.documentElement;
    var sync = function () {
      themeToggle.setAttribute("aria-pressed", root.getAttribute("data-theme-mode") === "dark" ? "true" : "false");
    };
    sync();
    themeToggle.addEventListener("click", function () {
      var next = root.getAttribute("data-theme-mode") === "dark" ? "light" : "dark";
      root.setAttribute("data-theme-mode", next);
      try { localStorage.setItem("quenderin_theme", next); } catch (e) { /* private mode */ }
      sync();
    });
    // Follow the OS theme live — but only until the user makes an explicit choice
    if (window.matchMedia) {
      var mq = window.matchMedia("(prefers-color-scheme: dark)");
      var onOsTheme = function (e) {
        try { if (localStorage.getItem("quenderin_theme")) return; } catch (err) { /* private mode */ }
        root.setAttribute("data-theme-mode", e.matches ? "dark" : "light");
        sync();
      };
      if (mq.addEventListener) mq.addEventListener("change", onOsTheme);
      else if (mq.addListener) mq.addListener(onOsTheme);
    }
  }

  // Mobile nav toggle
  var toggle = document.querySelector(".nav-toggle");
  var menu = document.getElementById("nav-menu");
  if (toggle && menu) {
    toggle.addEventListener("click", function () {
      var open = menu.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
    menu.querySelectorAll("a").forEach(function (link) {
      link.addEventListener("click", function () {
        menu.classList.remove("open");
        toggle.setAttribute("aria-expanded", "false");
      });
    });
  }

  // Reveal on scroll (opacity only — never geometry)
  var reveals = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && reveals.length) {
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("in");
            io.unobserve(entry.target);
          }
        });
      },
      { rootMargin: "0px 0px -10% 0px", threshold: 0.05 }
    );
    reveals.forEach(function (el) { io.observe(el); });
  } else {
    reveals.forEach(function (el) { el.classList.add("in"); });
  }

  // 3D tilt on the hero product window (Stripe pattern: small cap, expo reset)
  var tiltWrap = document.querySelector(".hero-visual");
  var tiltEl = document.querySelector(".hero-visual .device");
  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var finePointer = window.matchMedia && window.matchMedia("(pointer: fine)").matches;
  if (tiltWrap && tiltEl && !reduceMotion && finePointer) {
    var CAP = 6; // degrees
    tiltWrap.addEventListener("mousemove", function (e) {
      var r = tiltWrap.getBoundingClientRect();
      var px = (e.clientX - r.left) / r.width - 0.5;
      var py = (e.clientY - r.top) / r.height - 0.5;
      tiltEl.style.transition = "transform 0.08s linear";
      tiltEl.style.transform = "rotateY(" + (px * CAP).toFixed(2) + "deg) rotateX(" + (-py * CAP).toFixed(2) + "deg)";
    });
    tiltWrap.addEventListener("mouseleave", function () {
      tiltEl.style.transition = "transform 0.6s cubic-bezier(0.16, 1, 0.3, 1)";
      tiltEl.style.transform = "rotateY(0deg) rotateX(0deg)";
    });
  }

  // Scroll-aware header: a touch more presence once you leave the hero
  var header = document.querySelector(".site-header");
  if (header) {
    var onScroll = function () { header.classList.toggle("scrolled", window.scrollY > 8); };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
  }

  // Scroll-spy: highlight the nav link for the section currently in view
  var spyLinks = Array.prototype.slice.call(document.querySelectorAll('.nav-menu a[href^="#"]'));
  var spySections = spyLinks
    .map(function (a) { return document.getElementById(a.getAttribute("href").slice(1)); })
    .filter(Boolean);
  if ("IntersectionObserver" in window && spySections.length) {
    var spy = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          var id = entry.target.id;
          spyLinks.forEach(function (a) {
            a.classList.toggle("is-active", a.getAttribute("href") === "#" + id);
          });
        });
      },
      { rootMargin: "-45% 0px -50% 0px", threshold: 0 }
    );
    spySections.forEach(function (s) { spy.observe(s); });
  }

  // Model-fit calculator — RAM -> recommended model (mirrors the on-device recommender bands)
  var fitRam = document.getElementById("fit-ram");
  if (fitRam) {
    var FIT_BANDS = [
      { max: 2, model: "Llama 3.2 1B", dl: "0.4 GB", ram: 1.2 },
      { max: 4, model: "Llama 3.2 1B", dl: "0.8 GB", ram: 1.5 },
      { max: 10, model: "Qwen3 4B", dl: "2.4 GB", ram: 4 },
      { max: 1e9, model: "Qwen3 14B", dl: "9.0 GB", ram: 11 }
    ];
    var fitOut = document.getElementById("fit-ram-out");
    var fitModel = document.getElementById("fit-model");
    var fitDl = document.getElementById("fit-dl");
    var fitBar = document.getElementById("fit-bar-fill");
    var fitFootGb = document.getElementById("fit-foot-gb");
    var fitFootDev = document.getElementById("fit-foot-dev");
    var renderFit = function () {
      var gb = parseInt(fitRam.value, 10);
      if (fitOut) fitOut.textContent = gb + " GB";
      var b = FIT_BANDS.filter(function (x) { return gb < x.max; })[0] || FIT_BANDS[FIT_BANDS.length - 1];
      if (fitModel) fitModel.textContent = b.model;
      if (fitDl) fitDl.textContent = b.dl;
      if (fitBar) {
        fitBar.style.width = Math.min(100, Math.round((b.ram / gb) * 100)) + "%";
        fitBar.classList.toggle("tight", b.ram / gb > 0.85);
      }
      if (fitFootGb) fitFootGb.textContent = "~" + b.ram;
      if (fitFootDev) fitFootDev.textContent = gb;
    };
    fitRam.addEventListener("input", renderFit);
    renderFit();
  }

  // Service worker — make the site itself work offline (fitting for an offline-first product)
  if ("serviceWorker" in navigator) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("sw.js").catch(function () {});
    });
  }

  // Back-to-top — injected so it lives on every page without per-page markup
  var toTop = document.createElement("button");
  toTop.className = "to-top";
  toTop.type = "button";
  toTop.setAttribute("aria-label", "Back to top");
  toTop.innerHTML = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 19V5M5 12l7-7 7 7"/></svg>';
  document.body.appendChild(toTop);
  toTop.addEventListener("click", function () { window.scrollTo({ top: 0, behavior: "smooth" }); });
  var toggleToTop = function () { toTop.classList.toggle("show", window.scrollY > 600); };
  toggleToTop();
  window.addEventListener("scroll", toggleToTop, { passive: true });

  // Copy-to-clipboard buttons (brief ✓ feedback, language-agnostic)
  document.querySelectorAll(".copy-btn[data-copy-target]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var t = document.getElementById(btn.getAttribute("data-copy-target"));
      if (!t || !navigator.clipboard) return;
      navigator.clipboard.writeText(t.textContent.trim()).then(function () {
        btn.classList.add("copied");
        setTimeout(function () { btn.classList.remove("copied"); }, 1600);
      }).catch(function () {});
    });
  });

  // Scroll-progress bar (injected) — a thin brand line tracking read progress
  var prog = document.createElement("div");
  prog.className = "scroll-progress";
  prog.setAttribute("aria-hidden", "true");
  document.body.appendChild(prog);
  var updateProg = function () {
    var h = document.documentElement;
    var max = h.scrollHeight - h.clientHeight;
    prog.style.transform = "scaleX(" + (max > 0 ? (h.scrollTop / max).toFixed(4) : 0) + ")";
  };
  updateProg();
  window.addEventListener("scroll", updateProg, { passive: true });
  window.addEventListener("resize", updateProg, { passive: true });

})();
