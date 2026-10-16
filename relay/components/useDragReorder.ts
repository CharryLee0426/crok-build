"use client";

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent, RefObject } from "react";
import { moveItem } from "@/lib/order";

/**
 * Drag to reorder, on pointer events (mouse, touch and pen alike; no library).
 *
 * The dragged element follows the pointer (a transform set straight on the DOM node, so a move costs no React render),
 * a line marks where it will land, and the list scrolls when the pointer nears its top or bottom edge. A handle starts
 * a drag as soon as it moves; a whole row (a link) waits for a small mouse move, or a long press on touch screens so
 * the list still scrolls under a finger. The click that ends a drag never reaches the link underneath.
 */

/** What a drag moves: the projects of the list, or the sessions of one project. */
export type DragScope = { level: "project" } | { level: "session"; projectKey: string };

export type DragSpec = {
  scope: DragScope;
  /** The dragged item: a project key or a session id. */
  id: string;
  /** The items it moves among, in list order, `id` included. */
  ids: string[];
  /** Each item's element (the one that moves). */
  element: (id: string) => HTMLElement | null;
  /** A drag handle starts at once; a row waits (see above). */
  handle: boolean;
};

export type ActiveDrag = { scope: DragScope; id: string };

const HANDLE_SLOP = 3;
const MOUSE_SLOP = 6;
const TOUCH_SLOP = 8;
const LONG_PRESS_MS = 350;
const EDGE_PX = 56;
const MAX_SCROLL_PX = 18;

type Item = { id: string; top: number; height: number };

type Gesture = {
  spec: DragSpec;
  pointerId: number;
  touch: boolean;
  startY: number;
  startX: number;
  y: number;
  phase: "pending" | "active";
  timer: number | null;
  frame: number | null;
  /** Pointer y minus the element's top when the drag began: the element keeps that offset under the pointer. */
  grab: number;
  /** The element's top on screen when the drag began, to keep it in place if the list changes shape. */
  anchor: number;
  /** Item positions in the content's coordinates (they don't change while the list scrolls). */
  items: Item[];
  from: number;
  to: number;
  el: HTMLElement | null;
};

export function useDragReorder({
  scrollerRef,
  contentRef,
  indicatorRef,
  onDrop,
}: {
  scrollerRef: RefObject<HTMLElement | null>;
  contentRef: RefObject<HTMLElement | null>;
  indicatorRef: RefObject<HTMLElement | null>;
  /** `ids` is the spec's list in its new order; called only when something moved. */
  onDrop: (scope: DragScope, ids: string[]) => void;
}) {
  const [active, setActive] = useState<ActiveDrag | null>(null);
  const gestureRef = useRef<Gesture | null>(null);
  const onDropRef = useRef(onDrop);
  /** After a project drop: keep the dropped header where it was while the sections unfold again. */
  const settleRef = useRef<{ spec: DragSpec; top: number } | null>(null);

  useEffect(() => {
    onDropRef.current = onDrop;
  }, [onDrop]);

  const controller = useMemo(() => {
    const measure = (g: Gesture) => {
      const content = contentRef.current;
      if (!content) return;
      const base = content.getBoundingClientRect().top;
      g.items = g.spec.ids.map((id) => {
        const rect = g.spec.element(id)?.getBoundingClientRect();
        return { id, top: rect ? rect.top - base : 0, height: rect ? rect.height : 0 };
      });
      g.el = g.spec.element(g.spec.id);
      g.from = g.spec.ids.indexOf(g.spec.id);
      g.to = g.from;
    };

    const placeIndicator = (g: Gesture, others: Item[]) => {
      const line = indicatorRef.current;
      if (!line) return;
      if (g.to === g.from || others.length === 0) {
        line.style.display = "none";
        return;
      }
      const prev = others[g.to - 1];
      const next = others[g.to];
      const y = prev && next ? (prev.top + prev.height + next.top) / 2 : next ? next.top - 2 : prev.top + prev.height + 2;
      line.style.display = "block";
      line.style.transform = `translateY(${Math.round(y - 1)}px)`;
    };

    const tick = () => {
      const g = gestureRef.current;
      const content = contentRef.current;
      const scroller = scrollerRef.current;
      if (!g || g.phase !== "active" || !content || !scroller || !g.el || g.from < 0) return;
      // Scroll while the pointer is near (or past) the list's top or bottom edge.
      const box = scroller.getBoundingClientRect();
      const up = box.top + EDGE_PX - g.y;
      const down = g.y - (box.bottom - EDGE_PX);
      if (up > 0) scroller.scrollTop -= Math.ceil(Math.min(1, up / EDGE_PX) * MAX_SCROLL_PX);
      else if (down > 0) scroller.scrollTop += Math.ceil(Math.min(1, down / EDGE_PX) * MAX_SCROLL_PX);

      const base = content.getBoundingClientRect().top;
      const self = g.items[g.from];
      const first = g.items[0];
      const last = g.items[g.items.length - 1];
      const top = Math.min(Math.max(g.y - base - g.grab, first.top), last.top + last.height - self.height);
      g.el.style.transform = `translateY(${top - self.top}px)`;

      const mid = top + self.height / 2;
      const others = g.items.filter((_, i) => i !== g.from);
      let to = 0;
      while (to < others.length && others[to].top + others[to].height / 2 < mid) to++;
      g.to = to;
      placeIndicator(g, others);
      g.frame = requestAnimationFrame(tick);
    };

    const activate = () => {
      const g = gestureRef.current;
      if (!g || g.phase === "active") return;
      const el = g.spec.element(g.spec.id);
      if (!el) {
        end(false);
        return;
      }
      if (g.timer !== null) window.clearTimeout(g.timer);
      g.timer = null;
      const rect = el.getBoundingClientRect();
      g.phase = "active";
      g.grab = g.startY - rect.top;
      g.anchor = rect.top;
      document.documentElement.classList.add("reordering");
      window.getSelection?.()?.removeAllRanges();
      if (g.touch) navigator.vibrate?.(8);
      // The layout effect below measures once React has rendered the drag (projects fold to their headers).
      setActive({ scope: g.spec.scope, id: g.spec.id });
    };

    const blockNextClick = () => {
      const block = (e: MouseEvent) => {
        e.preventDefault();
        e.stopPropagation();
        window.removeEventListener("click", block, true);
      };
      window.addEventListener("click", block, true);
      window.setTimeout(() => window.removeEventListener("click", block, true), 400);
    };

    const end = (commit: boolean) => {
      const g = gestureRef.current;
      if (!g) return;
      gestureRef.current = null;
      if (g.timer !== null) window.clearTimeout(g.timer);
      if (g.frame !== null) cancelAnimationFrame(g.frame);
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onCancel);
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("contextmenu", onContextMenu, true);
      window.removeEventListener("blur", onBlur);
      if (g.phase !== "active") return;
      document.documentElement.classList.remove("reordering");
      if (indicatorRef.current) indicatorRef.current.style.display = "none";
      if (g.el) {
        if (g.spec.scope.level === "project") settleRef.current = { spec: g.spec, top: g.el.getBoundingClientRect().top };
        g.el.style.transform = "";
      }
      blockNextClick();
      if (commit && g.from >= 0 && g.to !== g.from) onDropRef.current(g.spec.scope, moveItem(g.spec.ids, g.from, g.to));
      setActive(null);
    };

    function onMove(e: PointerEvent) {
      const g = gestureRef.current;
      if (!g || e.pointerId !== g.pointerId) return;
      g.y = e.clientY;
      if (g.phase === "active") {
        e.preventDefault();
        return;
      }
      const moved = Math.max(Math.abs(e.clientX - g.startX), Math.abs(e.clientY - g.startY));
      if (g.touch && !g.spec.handle) {
        // Moving before the long press ends is a scroll, not a drag.
        if (moved > TOUCH_SLOP) end(false);
        return;
      }
      if (moved > (g.spec.handle ? HANDLE_SLOP : MOUSE_SLOP)) activate();
    }
    function onUp(e: PointerEvent) {
      if (gestureRef.current && e.pointerId === gestureRef.current.pointerId) end(true);
    }
    function onCancel(e: PointerEvent) {
      if (gestureRef.current && e.pointerId === gestureRef.current.pointerId) end(false);
    }
    function onKey(e: KeyboardEvent) {
      if (e.key !== "Escape" || gestureRef.current?.phase !== "active") return;
      e.preventDefault();
      e.stopPropagation();
      end(false);
    }
    function onContextMenu(e: Event) {
      // A long press on a link would open the browser's link menu over the drag.
      if (gestureRef.current?.phase === "active") e.preventDefault();
    }
    function onBlur() {
      end(false);
    }

    /** Pass a pointerdown to start a gesture; it becomes a drag only once it moves (or, on touch rows, holds). */
    const begin = (e: ReactPointerEvent, spec: DragSpec) => {
      if (gestureRef.current) return;
      if (e.pointerType === "mouse" && e.button !== 0) return;
      if (spec.ids.length < 2 || !spec.ids.includes(spec.id)) return;
      const touch = e.pointerType !== "mouse";
      // On a handle, a mouse press shouldn't start a text selection.
      if (spec.handle && !touch) e.preventDefault();
      gestureRef.current = {
        spec,
        pointerId: e.pointerId,
        touch,
        startX: e.clientX,
        startY: e.clientY,
        y: e.clientY,
        phase: "pending",
        timer: null,
        frame: null,
        grab: 0,
        anchor: 0,
        items: [],
        from: -1,
        to: -1,
        el: null,
      };
      window.addEventListener("pointermove", onMove, { passive: false });
      window.addEventListener("pointerup", onUp);
      window.addEventListener("pointercancel", onCancel);
      window.addEventListener("keydown", onKey, true);
      window.addEventListener("contextmenu", onContextMenu, true);
      window.addEventListener("blur", onBlur);
      if (touch && !spec.handle) gestureRef.current.timer = window.setTimeout(activate, LONG_PRESS_MS);
    };

    /** Once the drag has rendered: keep the dragged item where it was, measure, and start following the pointer. */
    const started = () => {
      const g = gestureRef.current;
      if (!g || g.phase !== "active") return;
      const el = g.spec.element(g.spec.id);
      const scroller = scrollerRef.current;
      if (el && scroller) {
        const shift = el.getBoundingClientRect().top - g.anchor;
        if (Math.abs(shift) > 0.5) scroller.scrollTop += shift;
      }
      measure(g);
      g.frame = requestAnimationFrame(tick);
    };

    /** After a project drop, once the sections have unfolded: keep the dropped header where it was. */
    const settled = () => {
      const settle = settleRef.current;
      settleRef.current = null;
      const scroller = scrollerRef.current;
      const el = settle?.spec.element(settle.spec.id);
      if (!settle || !el || !scroller) return;
      const shift = el.getBoundingClientRect().top - settle.top;
      if (Math.abs(shift) > 0.5) scroller.scrollTop += shift;
    };

    const isDragging = () => gestureRef.current?.phase === "active";

    return { begin, end, started, settled, isDragging };
  }, [contentRef, indicatorRef, scrollerRef]);

  useLayoutEffect(() => {
    if (active) controller.started();
    else controller.settled();
  }, [active, controller]);

  // A finger that has started a drag must not scroll the list: block touchmove (it has to be a non-passive listener
  // registered before the touch starts, or browsers won't let it cancel the scroll).
  useEffect(() => {
    const scroller = scrollerRef.current;
    if (!scroller) return;
    const onTouchMove = (e: TouchEvent) => {
      if (controller.isDragging() && e.cancelable) e.preventDefault();
    };
    scroller.addEventListener("touchmove", onTouchMove, { passive: false });
    return () => scroller.removeEventListener("touchmove", onTouchMove);
  }, [scrollerRef, controller]);

  // Unmounting mid-drag (e.g. navigating away) leaves nothing behind.
  useEffect(() => () => controller.end(false), [controller]);

  return { active, begin: controller.begin };
}
