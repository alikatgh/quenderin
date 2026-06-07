// Quenderin marketing site — tiny, dependency-free, first-party only.
(function () {
  "use strict";

  // Footer year
  var yearEl = document.getElementById("year");
  if (yearEl) yearEl.textContent = String(new Date().getFullYear());

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
})();
