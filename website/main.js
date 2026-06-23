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
      { max: 2, model: "Llama 3.2 1B", dl: "0.4 GB" },
      { max: 4, model: "Llama 3.2 1B", dl: "0.8 GB" },
      { max: 10, model: "Qwen3 4B", dl: "2.4 GB" },
      { max: 1e9, model: "Qwen3 14B", dl: "9.0 GB" }
    ];
    var fitOut = document.getElementById("fit-ram-out");
    var fitModel = document.getElementById("fit-model");
    var fitDl = document.getElementById("fit-dl");
    var renderFit = function () {
      var gb = parseInt(fitRam.value, 10);
      if (fitOut) fitOut.textContent = gb + " GB";
      var b = FIT_BANDS.filter(function (x) { return gb < x.max; })[0] || FIT_BANDS[FIT_BANDS.length - 1];
      if (fitModel) fitModel.textContent = b.model;
      if (fitDl) fitDl.textContent = b.dl;
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

})();
