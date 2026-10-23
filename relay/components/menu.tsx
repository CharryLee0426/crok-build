"use client";

/**
 * Popovers and menus: the row menus (a ⋯ button or a right click: the phones' long press), the computer switcher, the
 * thinking-level menu. Drawn in a portal with fixed positioning, kept inside the window, closed by a click elsewhere,
 * Escape, scrolling or resizing. Keyboard: arrows move between items, Enter picks.
 */
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type {
  KeyboardEvent as ReactKeyboardEvent,
  MouseEvent as ReactMouseEvent,
  PointerEvent as ReactPointerEvent,
  ReactNode,
  RefObject,
} from "react";
import { createPortal } from "react-dom";
import { CheckIcon } from "./icons";

/** Where a popover opens; `el` is what it belongs to (scrolling a box that holds it closes the popover). */
export type Anchor = { kind: "rect"; rect: DOMRect; el?: Element } | { kind: "point"; x: number; y: number; el?: Element };
export type Placement = "bottom-start" | "bottom-end" | "top-start" | "top-end";

const MARGIN = 8;

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

export function Popover({
  anchor,
  placement = "bottom-end",
  onClose,
  ignore,
  label,
  role = "menu",
  className = "",
  children,
}: {
  anchor: Anchor;
  placement?: Placement;
  onClose: () => void;
  /** The trigger: a press on it toggles instead of counting as "elsewhere". */
  ignore?: RefObject<HTMLElement | null>;
  label?: string;
  role?: "menu" | "dialog" | "listbox";
  className?: string;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);
  const closeRef = useRef(onClose);
  useEffect(() => {
    closeRef.current = onClose;
  }, [onClose]);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    let left: number;
    let top: number;
    if (anchor.kind === "point") {
      left = anchor.x + w > vw - MARGIN ? anchor.x - w : anchor.x;
      top = anchor.y + h > vh - MARGIN ? anchor.y - h : anchor.y;
    } else {
      const r = anchor.rect;
      const below = r.bottom + 6;
      const above = r.top - 6 - h;
      top = placement.startsWith("top")
        ? above >= MARGIN
          ? above
          : below
        : below + h <= vh - MARGIN
          ? below
          : above;
      left = placement.endsWith("start") ? r.left : r.right - w;
    }
    setPos({ left: clamp(left, MARGIN, vw - w - MARGIN), top: clamp(top, MARGIN, vh - h - MARGIN) });
  }, [anchor, placement]);

  const anchorEl = anchor.el;
  useEffect(() => {
    const inside = (target: EventTarget | null) =>
      target instanceof Node && (ref.current?.contains(target) || ignore?.current?.contains(target));
    const onDown = (e: PointerEvent) => {
      if (!inside(e.target)) closeRef.current();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopPropagation();
      closeRef.current();
    };
    const onScroll = (e: Event) => {
      if (e.target instanceof Node && ref.current?.contains(e.target)) return;
      // Only a scroll that moves the anchor (a transcript growing beside the composer's menu does not).
      if (anchorEl && e.target instanceof Node && e.target !== document && !e.target.contains(anchorEl)) return;
      closeRef.current();
    };
    const onResize = () => closeRef.current();
    document.addEventListener("pointerdown", onDown, true);
    document.addEventListener("keydown", onKey, true);
    document.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", onResize);
    return () => {
      document.removeEventListener("pointerdown", onDown, true);
      document.removeEventListener("keydown", onKey, true);
      document.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", onResize);
    };
  }, [ignore, anchorEl]);

  if (typeof document === "undefined") return null;
  return createPortal(
    <div
      ref={ref}
      role={role}
      aria-label={label}
      style={{ position: "fixed", left: pos?.left ?? 0, top: pos?.top ?? 0, visibility: pos ? "visible" : "hidden" }}
      className={`z-50 max-h-[calc(100dvh-16px)] overflow-y-auto overscroll-contain rounded-2xl border border-line bg-surface py-1.5 text-fg shadow-card scroll-quiet ${className}`}
    >
      {children}
    </div>,
    document.body,
  );
}

export type MenuItem = {
  label: string;
  icon?: ReactNode;
  /** Shown before the label instead of a small icon (an avatar). */
  leading?: ReactNode;
  /** A second line under the label. */
  detail?: ReactNode;
  tone?: "danger" | "accent";
  /** Shown but not selectable. */
  disabled?: boolean;
  /** A checkmark at the end (the current choice). */
  checked?: boolean;
  /** A line above this item. */
  separated?: boolean;
  onSelect: () => void;
};

/** Menu items as buttons; the first enabled one takes the focus, arrows move it. */
export function MenuList({ items, onDone, autoFocus = true }: { items: MenuItem[]; onDone: () => void; autoFocus?: boolean }) {
  const listRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!autoFocus) return;
    const first = listRef.current?.querySelector<HTMLButtonElement>("button:not(:disabled)");
    first?.focus({ preventScroll: true });
  }, [autoFocus]);
  const onKeyDown = (e: ReactKeyboardEvent<HTMLDivElement>) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp" && e.key !== "Home" && e.key !== "End") return;
    e.preventDefault();
    const buttons = [...(listRef.current?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)") ?? [])];
    if (!buttons.length) return;
    const at = buttons.indexOf(document.activeElement as HTMLButtonElement);
    const next =
      e.key === "Home"
        ? 0
        : e.key === "End"
          ? buttons.length - 1
          : (at + (e.key === "ArrowDown" ? 1 : -1) + buttons.length) % buttons.length;
    buttons[next].focus();
  };
  return (
    <div ref={listRef} onKeyDown={onKeyDown} className="min-w-52">
      {items.map((item, index) => (
        <div key={`${index}:${item.label}`}>
          {item.separated && index > 0 ? <div className="my-1.5 border-t border-line" /> : null}
          <button
            type="button"
            role={item.checked !== undefined ? "menuitemradio" : "menuitem"}
            aria-checked={item.checked}
            disabled={item.disabled}
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              onDone();
              item.onSelect();
            }}
            className={`flex w-full items-center gap-3 px-3.5 py-2 text-left text-[14px] outline-none hover:bg-hover focus-visible:bg-hover disabled:cursor-default disabled:opacity-45 disabled:hover:bg-transparent ${
              item.tone === "danger" ? "text-danger" : item.tone === "accent" ? "text-accent-text" : "text-fg"
            }`}
          >
            {item.leading ?? (item.icon ? <span className={item.tone ? "" : "text-muted"}>{item.icon}</span> : null)}
            <span className="min-w-0 flex-1">
              <span className="block truncate">{item.label}</span>
              {item.detail ? <span className="block truncate text-[12.5px] text-muted">{item.detail}</span> : null}
            </span>
            {item.checked ? <CheckIcon size={17} className="shrink-0 text-accent-text" /> : null}
          </button>
        </div>
      ))}
    </div>
  );
}

const LONG_PRESS_MS = 450;
const LONG_PRESS_SLOP = 8;

/**
 * A menu's open state: from a button (anchored to it), a right click or the context-menu key (at the pointer, or the
 * element), or a long press on a touch screen (the phones' gesture; iOS Safari fires no `contextmenu` for it).
 */
export function useMenu() {
  const [anchor, setAnchor] = useState<Anchor | null>(null);
  const press = useRef<{ timer: number; x: number; y: number; pointerId: number } | null>(null);
  const close = useCallback(() => setAnchor(null), []);
  const fromElement = useCallback(
    (el: Element) => setAnchor({ kind: "rect", rect: el.getBoundingClientRect(), el }),
    [],
  );
  const atPointer = useCallback((e: ReactMouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    // The keyboard's context-menu key has no pointer position: open at the row.
    if (e.clientX === 0 && e.clientY === 0) setAnchor({ kind: "rect", rect: e.currentTarget.getBoundingClientRect(), el: e.currentTarget });
    else setAnchor({ kind: "point", x: e.clientX, y: e.clientY, el: e.currentTarget });
  }, []);

  const cancelPress = useCallback(() => {
    if (press.current) window.clearTimeout(press.current.timer);
    press.current = null;
  }, []);
  /** Pointer handlers for a row: a touch held still opens the menu, and the click that follows is dropped. */
  const longPress = {
    onPointerDown: (e: ReactPointerEvent<HTMLElement>) => {
      if (e.pointerType === "mouse") return;
      cancelPress();
      const target = e.currentTarget;
      const { clientX: x, clientY: y, pointerId } = e;
      press.current = {
        x,
        y,
        pointerId,
        timer: window.setTimeout(() => {
          press.current = null;
          navigator.vibrate?.(8);
          setAnchor({ kind: "point", x, y, el: target });
          const block = (event: MouseEvent) => {
            event.preventDefault();
            event.stopPropagation();
          };
          window.addEventListener("click", block, { capture: true, once: true });
          window.setTimeout(() => window.removeEventListener("click", block, { capture: true }), 600);
        }, LONG_PRESS_MS),
      };
    },
    onPointerMove: (e: ReactPointerEvent<HTMLElement>) => {
      const p = press.current;
      if (p && e.pointerId === p.pointerId && Math.hypot(e.clientX - p.x, e.clientY - p.y) > LONG_PRESS_SLOP) cancelPress();
    },
    onPointerUp: cancelPress,
    onPointerCancel: cancelPress,
  };
  useEffect(() => cancelPress, [cancelPress]);

  return { anchor, open: anchor !== null, close, fromElement, atPointer, longPress };
}

export type MenuState = ReturnType<typeof useMenu>;

/** A `useMenu` state's popover with its items. */
export function MenuPopover({
  menu,
  items,
  label,
  placement,
  ignore,
}: {
  menu: MenuState;
  items: MenuItem[];
  label?: string;
  placement?: Placement;
  ignore?: RefObject<HTMLElement | null>;
}) {
  if (!menu.anchor || !items.length) return null;
  return (
    <Popover anchor={menu.anchor} onClose={menu.close} label={label} placement={placement} ignore={ignore}>
      <MenuList items={items} onDone={menu.close} />
    </Popover>
  );
}
