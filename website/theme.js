// Shared appearance owner for every website route, loaded before styles paint.
(function () {
  "use strict";

  var root = document.documentElement;
  var preference = null;
  var unsavedChoice = false;
  function validPreference(value) { return value === "dark" || value === "light" ? value : null; }
  try { preference = localStorage.getItem("quenderin_theme"); } catch (e) { /* private mode */ }
  preference = validPreference(preference);

  var mq = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
  var themeToggle = null;
  var themeColors = document.querySelectorAll('meta[name="theme-color"]');
  var lightMeta = document.querySelector('meta[name="theme-color"][media="(prefers-color-scheme: light)"]');
  var darkMeta = document.querySelector('meta[name="theme-color"][media="(prefers-color-scheme: dark)"]');
  var lightChrome = lightMeta && lightMeta.getAttribute("content");
  var darkChrome = darkMeta && darkMeta.getAttribute("content");

  function apply(mode) {
    root.setAttribute("data-theme-mode", mode);
    if (themeToggle) themeToggle.setAttribute("aria-pressed", mode === "dark" ? "true" : "false");
    // Either media variant can be selected by the browser; both follow the
    // actual page appearance even when an explicit choice differs from the OS.
    var chrome = mode === "dark" ? darkChrome : lightChrome;
    if (chrome) themeColors.forEach(function (meta) { meta.setAttribute("content", chrome); });
  }

  apply(preference || (mq && mq.matches ? "dark" : "light"));

  function bindToggle() {
    themeToggle = document.querySelector(".theme-toggle");
    if (!themeToggle) return;
    themeToggle.setAttribute("aria-pressed", root.getAttribute("data-theme-mode") === "dark" ? "true" : "false");
    themeToggle.addEventListener("click", function () {
      preference = root.getAttribute("data-theme-mode") === "dark" ? "light" : "dark";
      unsavedChoice = false;
      try { localStorage.setItem("quenderin_theme", preference); } catch (e) { unsavedChoice = true; }
      apply(preference);
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", bindToggle, { once: true });
  else bindToggle();

  if (mq) {
    var onOsTheme = function (event) {
      // Re-read for cross-tab choices even if their storage event has not yet
      // arrived. A failed local save still keeps this page's explicit choice.
      if (!unsavedChoice) {
        try { preference = validPreference(localStorage.getItem("quenderin_theme")); } catch (e) { /* keep in-memory choice */ }
      }
      apply(preference || (event.matches ? "dark" : "light"));
    };
    if (mq.addEventListener) mq.addEventListener("change", onOsTheme);
    else if (mq.addListener) mq.addListener(onOsTheme);
  }

  window.addEventListener("storage", function (event) {
    if (event.key !== null && event.key !== "quenderin_theme") return;
    try { if (event.storageArea && event.storageArea !== localStorage) return; } catch (e) { return; }
    preference = validPreference(event.newValue);
    unsavedChoice = false;
    apply(preference || (mq && mq.matches ? "dark" : "light"));
  });
})();
