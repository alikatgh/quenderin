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

  // Waitlist form: until a real endpoint is wired in (the action still carries the
  // "your-form-id" placeholder), don't POST to a dead URL — degrade honestly instead of
  // 404-ing or pretending the email was saved.
  var waitlistForm = document.querySelector(".waitlist-form");
  if (waitlistForm && (waitlistForm.getAttribute("action") || "").indexOf("your-form-id") !== -1) {
    waitlistForm.addEventListener("submit", function (event) {
      event.preventDefault();
      var note = document.createElement("p");
      note.className = "form-consent";
      note.textContent =
        "The waitlist isn’t live yet — watch the repo on GitHub to hear the moment the apps land.";
      waitlistForm.replaceWith(note);
    });
  }
})();
