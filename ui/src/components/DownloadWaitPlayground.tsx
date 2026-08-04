import { useCallback, useEffect, useRef, useState } from 'react';

const TIPS = [
  'Nothing you type will leave this device — the model runs entirely offline.',
  'One download, then airplane mode works. No account. No API keys.',
  'Bigger models think deeper; smaller ones answer faster. You can switch later.',
  'Wi‑Fi recommended: multi‑GB downloads on cellular can cost real money.',
  'When this finishes, chat is private by design — even we can’t see it.',
  'You can continue setup while this finishes in the background.',
  'Heat is the real ceiling on phones, not memory — short chats stay cool.',
  'You can cancel anytime; a partial download resumes next attempt.',
] as const;

type Token = { id: number; x: number; y: number; speed: number };

/**
 * Engagement surface while a model downloads: progress, rotating tips, token-catch mini-game.
 * Twin of native DownloadWaitPlayground (iOS/Android).
 */
export function DownloadWaitPlayground({ progress }: { progress: number }) {
  const [tipIndex, setTipIndex] = useState(0);
  const [score, setScore] = useState(0);
  const [high, setHigh] = useState(0);
  const [tokens, setTokens] = useState<Token[]>([]);
  const nextId = useRef(1);
  const spawnAccum = useRef(0);
  const scoreRef = useRef(0);
  const fieldRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const id = window.setInterval(() => setTipIndex((i) => (i + 1) % TIPS.length), 6000);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    let raf = 0;
    let last = performance.now();
    const loop = (now: number) => {
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      setTokens((prev) => {
        const next = prev
          .map((t) => ({ ...t, y: t.y + t.speed * dt }))
          .filter((t) => t.y <= 1.12);
        spawnAccum.current += dt * 1.35;
        while (spawnAccum.current >= 1) {
          spawnAccum.current -= 1;
          const h = Math.random();
          next.push({
            id: nextId.current++,
            x: 0.08 + h * 0.84,
            y: -0.06,
            speed: 0.18 + h * 0.28,
          });
        }
        return next;
      });
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, []);

  const onTap = useCallback((e: React.MouseEvent | React.PointerEvent) => {
    const el = fieldRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const nx = (e.clientX - rect.left) / rect.width;
    const ny = (e.clientY - rect.top) / rect.height;
    setTokens((prev) => {
      const r = 0.09;
      const idx = prev.findIndex((t) => {
        const dx = t.x - nx;
        const dy = t.y - ny;
        return dx * dx + dy * dy <= r * r;
      });
      if (idx < 0) return prev;
      const copy = prev.slice();
      copy.splice(idx, 1);
      scoreRef.current += 1;
      const s = scoreRef.current;
      setScore(s);
      setHigh((h) => Math.max(h, s));
      return copy;
    });
  }, []);

  const pct = Math.min(100, Math.max(0, Math.round(progress)));

  return (
    <div className="space-y-3 mb-6">
      <div className="bg-zinc-50 dark:bg-zinc-800/50 p-4 rounded-xl border border-zinc-200 dark:border-zinc-700/50">
        <div className="flex justify-between text-xs font-semibold mb-2">
          <span className="text-emerald-600 dark:text-emerald-400">Downloading AI Knowledge…</span>
          <span className="text-zinc-500 dark:text-zinc-400 tabular-nums">{pct}%</span>
        </div>
        <div
          className="w-full bg-zinc-200 dark:bg-zinc-700 rounded-full h-2 mb-2 overflow-hidden"
          role="progressbar"
          aria-label="Model download progress"
          aria-valuenow={pct}
          aria-valuemin={0}
          aria-valuemax={100}
        >
          <div
            className="bg-emerald-500 h-2 transition-colors duration-300 ease-out"
            style={{ width: `${pct}%` }}
          />
        </div>
        <p className="text-[11px] text-zinc-500 dark:text-zinc-400 text-center">
          One time — then fully offline. Play while it finishes (or continue setup below).
        </p>
      </div>

      <p className="text-xs text-zinc-500 dark:text-zinc-400 text-center leading-relaxed min-h-[2.5rem]" aria-live="polite">
        {TIPS[tipIndex]}
      </p>

      <div className="flex items-center justify-between">
        <span className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Catch the tokens</span>
        <span className="text-xs font-semibold text-emerald-600 dark:text-emerald-400 tabular-nums" aria-label={`Score ${score}`}>
          Score {score}
        </span>
      </div>

      <div
        ref={fieldRef}
        role="application"
        aria-label={`Token catch game. Tap glowing tokens. Score ${score}.`}
        className="relative h-40 rounded-xl border border-zinc-200 dark:border-zinc-700/50 bg-zinc-100/80 dark:bg-zinc-800/40 overflow-hidden cursor-pointer select-none"
        onPointerDown={onTap}
      >
        {tokens.length === 0 && score === 0 && (
          <span className="absolute inset-0 flex items-center justify-center text-xs text-zinc-500 dark:text-zinc-400 pointer-events-none">
            Tap the glowing dots
          </span>
        )}
        {tokens.map((t) => (
          <span
            key={t.id}
            className="absolute w-4 h-4 -ml-2 -mt-2 rounded-full bg-emerald-500 pointer-events-none"
            style={{ left: `${t.x * 100}%`, top: `${t.y * 100}%` }}
            aria-hidden
          />
        ))}
      </div>

      {high > 0 && (
        <p className="text-[11px] text-zinc-500 dark:text-zinc-400 text-center tabular-nums">
          Best this wait · {high}
        </p>
      )}
    </div>
  );
}
