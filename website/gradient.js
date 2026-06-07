/* ──────────────────────────────────────────────────────────────────────────
   gradient.js — Quenderin animated WebGL mesh gradient
   ----------------------------------------------------------------------------
   The Stripe-style flowing mesh gradient: a full-screen quad whose colour flow
   is driven in the FRAGMENT shader by 2D simplex noise (Ashima/Gustavson, public
   domain) + domain warp. Adapted from the wallmarkets reimplementation of the
   technique documented in the Stripe UI teardown.

   Discipline kept intact:
     • rAF loop PAUSED off-screen (IntersectionObserver) and when the tab hides
     • prefers-reduced-motion → a single static frame, no loop
     • no WebGL → a static CSS linear-gradient fallback (never blank)
     • DPR capped at 2 for perf

   Usage (auto-init):
     <canvas data-quenderin-gradient
             data-colors="#7A5AF8,#635BFF,#FF6B8A,#FFD55A"
             data-darken-top></canvas>
     <script src="gradient.js" defer></script>
   ────────────────────────────────────────────────────────────────────────── */
(function (global) {
  "use strict";

  // Stripe's iconic marketing palette: violet → indigo → pink → gold.
  var DEFAULT_COLORS = ["#7A5AF8", "#635BFF", "#FF6B8A", "#FFD55A"];

  var VERT = [
    "attribute vec2 a_pos;",
    "void main(){ gl_Position = vec4(a_pos, 0.0, 1.0); }",
  ].join("\n");

  var FRAG = [
    "precision highp float;",
    "uniform float u_time;",
    "uniform vec2  u_resolution;",
    "uniform vec3  u_c0;",
    "uniform vec3  u_c1;",
    "uniform vec3  u_c2;",
    "uniform vec3  u_c3;",
    "uniform float u_darkenTop;",
    "vec3 mod289(vec3 x){return x-floor(x*(1.0/289.0))*289.0;}",
    "vec2 mod289(vec2 x){return x-floor(x*(1.0/289.0))*289.0;}",
    "vec3 permute(vec3 x){return mod289(((x*34.0)+1.0)*x);}",
    "float snoise(vec2 v){",
    "  const vec4 C=vec4(0.211324865405187,0.366025403784439,-0.577350269189626,0.024390243902439);",
    "  vec2 i=floor(v+dot(v,C.yy));",
    "  vec2 x0=v-i+dot(i,C.xx);",
    "  vec2 i1=(x0.x>x0.y)?vec2(1.0,0.0):vec2(0.0,1.0);",
    "  vec4 x12=x0.xyxy+C.xxzz; x12.xy-=i1;",
    "  i=mod289(i);",
    "  vec3 p=permute(permute(i.y+vec3(0.0,i1.y,1.0))+i.x+vec3(0.0,i1.x,1.0));",
    "  vec3 m=max(0.5-vec3(dot(x0,x0),dot(x12.xy,x12.xy),dot(x12.zw,x12.zw)),0.0);",
    "  m=m*m; m=m*m;",
    "  vec3 x=2.0*fract(p*C.www)-1.0;",
    "  vec3 h=abs(x)-0.5;",
    "  vec3 ox=floor(x+0.5);",
    "  vec3 a0=x-ox;",
    "  m*=1.79284291400159-0.85373472095314*(a0*a0+h*h);",
    "  vec3 g;",
    "  g.x=a0.x*x0.x+h.x*x0.y;",
    "  g.yz=a0.yz*x12.xz+h.yz*x12.yw;",
    "  return 130.0*dot(m,g);",
    "}",
    "void main(){",
    "  vec2 uv = gl_FragCoord.xy / u_resolution;",
    "  vec2 p = uv;",
    "  p.x *= u_resolution.x / u_resolution.y;",
    "  float t = u_time * 0.06;",
    "  vec2 q = vec2(snoise(p*1.2 + vec2(0.0, t)), snoise(p*1.2 + vec2(5.2, t*1.1)));",
    "  vec2 r = p + 0.55*q;",
    "  float n1 = snoise(r*1.5 + vec2(t*1.3, 0.0));",
    "  float n2 = snoise(r*2.0 + vec2(-t*1.1, t*0.7) + 3.0);",
    "  float n3 = snoise(r*1.1 + vec2(t*0.5, -t*0.9) + 8.0);",
    "  vec3 col = u_c0;",
    "  col = mix(col, u_c1, smoothstep(-0.35, 0.65, n1));",
    "  col = mix(col, u_c2, smoothstep(-0.20, 0.70, n2) * 0.85);",
    "  col = mix(col, u_c3, smoothstep( 0.00, 0.80, n3) * 0.70);",
    "  col *= 1.0 - u_darkenTop * (1.0 - uv.y) * 0.22;",
    "  gl_FragColor = vec4(col, 1.0);",
    "}",
  ].join("\n");

  function hexToRgb(hex) {
    hex = String(hex).trim().replace(/^#/, "");
    if (hex.length === 3) hex = hex.replace(/(.)/g, "$1$1");
    var n = parseInt(hex, 16);
    return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
  }

  function compile(gl, type, src) {
    var s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      console.error("[gradient] shader compile failed:", gl.getShaderInfoLog(s));
      gl.deleteShader(s);
      return null;
    }
    return s;
  }

  function QuenderinGradient(canvas, opts) {
    opts = opts || {};
    this.canvas = canvas;
    this.colors = (opts.colors || DEFAULT_COLORS).map(hexToRgb);
    this.speed = opts.speed != null ? opts.speed : 1;
    this.darkenTop = opts.darkenTop ? 1 : 0;
    this._raf = null;
    this._t0 = null;
    this._running = false;
    this._visible = true;

    var gl =
      canvas.getContext("webgl", { antialias: false, premultipliedAlpha: false, alpha: false }) ||
      canvas.getContext("experimental-webgl", { antialias: false });

    if (!gl) { this._fallback(); return; }
    this.gl = gl;

    var vs = compile(gl, gl.VERTEX_SHADER, VERT);
    var fs = compile(gl, gl.FRAGMENT_SHADER, FRAG);
    if (!vs || !fs) { this._fallback(); return; }

    var prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
      console.error("[gradient] link failed:", gl.getProgramInfoLog(prog));
      this._fallback();
      return;
    }
    gl.useProgram(prog);
    this.prog = prog;

    var buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    var loc = gl.getAttribLocation(prog, "a_pos");
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    this.u = {
      time: gl.getUniformLocation(prog, "u_time"),
      res: gl.getUniformLocation(prog, "u_resolution"),
      darken: gl.getUniformLocation(prog, "u_darkenTop"),
    };
    gl.uniform3fv(gl.getUniformLocation(prog, "u_c0"), this.colors[0]);
    gl.uniform3fv(gl.getUniformLocation(prog, "u_c1"), this.colors[1] || this.colors[0]);
    gl.uniform3fv(gl.getUniformLocation(prog, "u_c2"), this.colors[2] || this.colors[0]);
    gl.uniform3fv(gl.getUniformLocation(prog, "u_c3"), this.colors[3] || this.colors[0]);
    gl.uniform1f(this.u.darken, this.darkenTop);

    this._onResize = this.resize.bind(this);
    window.addEventListener("resize", this._onResize, { passive: true });
    this.resize();

    if ("IntersectionObserver" in window) {
      this._io = new IntersectionObserver(
        function (e) {
          this._visible = e[0].isIntersecting;
          this._visible ? this.play() : this.pause();
        }.bind(this),
        { threshold: 0 }
      );
      this._io.observe(canvas);
    }
    this._onVis = function () {
      document.hidden ? this.pause() : (this._visible && this.play());
    }.bind(this);
    document.addEventListener("visibilitychange", this._onVis);

    var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced) { this.render(0); } else { this.play(); }
  }

  QuenderinGradient.prototype.resize = function () {
    var gl = this.gl, c = this.canvas;
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    var w = Math.max(1, Math.floor(c.clientWidth * dpr));
    var h = Math.max(1, Math.floor(c.clientHeight * dpr));
    if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
    gl.viewport(0, 0, w, h);
    gl.uniform2f(this.u.res, w, h);
    if (!this._running) this.render(this._lastT || 0);
  };

  QuenderinGradient.prototype.render = function (tMs) {
    var gl = this.gl;
    if (!gl) return;
    this._lastT = tMs;
    gl.uniform1f(this.u.time, (tMs / 1000) * this.speed);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  };

  QuenderinGradient.prototype._loop = function (ts) {
    if (!this._running) return;
    if (this._t0 == null) this._t0 = ts;
    this.render(ts - this._t0);
    this._raf = requestAnimationFrame(this._loop.bind(this));
  };

  QuenderinGradient.prototype.play = function () {
    if (this._running || !this.gl) return;
    this._running = true;
    this._raf = requestAnimationFrame(this._loop.bind(this));
  };

  QuenderinGradient.prototype.pause = function () {
    this._running = false;
    if (this._raf) cancelAnimationFrame(this._raf);
    this._raf = null;
  };

  QuenderinGradient.prototype.destroy = function () {
    this.pause();
    window.removeEventListener("resize", this._onResize);
    document.removeEventListener("visibilitychange", this._onVis);
    if (this._io) this._io.disconnect();
  };

  QuenderinGradient.prototype._fallback = function () {
    var hexes = (this.colors || []).length
      ? this.colors.map(function (c) {
          return "rgb(" + c.map(function (v) { return Math.round(v * 255); }).join(",") + ")";
        })
      : DEFAULT_COLORS;
    this.canvas.style.background = "linear-gradient(135deg," + hexes.slice(0, 4).join(",") + ")";
  };

  function autoInit() {
    var nodes = document.querySelectorAll("canvas[data-quenderin-gradient]");
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.__qGradient) continue;
      var colorsAttr = el.getAttribute("data-colors");
      el.__qGradient = new QuenderinGradient(el, {
        colors: colorsAttr ? colorsAttr.split(",").map(function (s) { return s.trim(); }) : null,
        speed: parseFloat(el.getAttribute("data-speed")) || 1,
        darkenTop: el.hasAttribute("data-darken-top"),
      });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", autoInit);
  } else {
    autoInit();
  }

  global.QuenderinGradient = QuenderinGradient;
})(window);
