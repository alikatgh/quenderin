// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/modelTable/ScrollThumb.tsx at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import React, { useEffect, useLayoutEffect, useRef } from "react";

/** Matches the app's scrollbar in App.css. */
const INSET = 3;
const MIN_HEIGHT = 32;
/** How long it stays visible after scrolling stops. */
const LINGER_MS = 800;

/**
 * Overlay scrollbar so rows run full width on every platform. Render after the
 * list inside a `relative group/scroll` box; the list hides its native one.
 * Solid, not translucent: over a picked row or divider a translucent thumb
 * blends into a third grey.
 */
export const ScrollThumb: React.FC<{
  listRef: React.RefObject<HTMLElement>;
}> = ({ listRef }) => {
  const thumbRef = useRef<HTMLDivElement>(null);
  const drag = useRef<{ y: number; top: number } | null>(null);
  const linger = useRef(0);

  /** Size and position the thumb from the list's scroll metrics. */
  const place = useRef(() => {});
  place.current = () => {
    const list = listRef.current;
    const thumb = thumbRef.current;
    if (!list || !thumb) return;
    const { scrollTop, scrollHeight, clientHeight } = list;
    const max = scrollHeight - clientHeight;
    thumb.hidden = max <= 1;
    if (thumb.hidden) return;
    const track = clientHeight - INSET * 2;
    const height = Math.max(MIN_HEIGHT, (track * clientHeight) / scrollHeight);
    // Clamp during overscroll bounce.
    const at = Math.min(1, Math.max(0, scrollTop / max));
    thumb.style.height = `${height}px`;
    thumb.style.transform = `translateY(${INSET + at * (track - height)}px)`;
  };

  const show = () => {
    const thumb = thumbRef.current;
    if (!thumb) return;
    thumb.dataset.active = "";
    clearTimeout(linger.current);
    linger.current = window.setTimeout(() => {
      if (!drag.current) delete thumb.dataset.active;
    }, LINGER_MS);
  };

  // Every render: search and filters change the content height.
  useLayoutEffect(() => place.current());
  useEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const onScroll = () => {
      place.current();
      show();
    };
    list.addEventListener("scroll", onScroll, { passive: true });
    const resized = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(() => place.current());
    resized?.observe(list);
    return () => {
      list.removeEventListener("scroll", onScroll);
      resized?.disconnect();
      clearTimeout(linger.current);
    };
  }, [listRef]);

  const release = () => {
    drag.current = null;
    thumbRef.current?.removeAttribute("data-dragging");
    show();
  };

  return (
    <div
      aria-hidden="true"
      className="pointer-events-none absolute inset-y-0 end-0 w-[14px]"
    >
      <div
        ref={thumbRef}
        onPointerDown={(e) => {
          const list = listRef.current;
          if (!list) return;
          e.preventDefault();
          e.currentTarget.setPointerCapture(e.pointerId);
          drag.current = { y: e.clientY, top: list.scrollTop };
          e.currentTarget.dataset.dragging = "";
          show();
        }}
        onPointerMove={(e) => {
          const list = listRef.current;
          const from = drag.current;
          if (!list || !from) return;
          // The thumb's travel stands for the list's.
          const travel =
            list.clientHeight - INSET * 2 - e.currentTarget.offsetHeight;
          const max = list.scrollHeight - list.clientHeight;
          if (travel > 0)
            list.scrollTop = from.top + ((e.clientY - from.y) * max) / travel;
        }}
        onPointerUp={release}
        onLostPointerCapture={release}
        className="pointer-events-auto touch-none absolute top-0 start-[3px] end-[4px] rounded-full bg-zinc-400 dark:bg-zinc-600 opacity-0 transition-[opacity,background-color] duration-300 motion-reduce:transition-none hover:bg-zinc-500 dark:bg-zinc-400 group-hover/scroll:opacity-100 data-active:opacity-100 data-dragging:bg-zinc-500 dark:bg-zinc-400"
      />
    </div>
  );
};
