import { useEffect, useRef, useState, type KeyboardEvent, type PointerEvent, type ReactNode } from "react";

// The split view: two assistants side by side on a wide screen, as an
// editor splits its window. The persona cookie routes the whole host to one
// assistant, so each pane is a frame of /@<unit>/, which the proxy sends to
// that one alone; same origin, so one sign-in covers both.

/** Whether this page is a pane of the split view. */
export const PANE = window.top !== window.self;

/** What a pane asks of the window around it. */
export type PaneAsk = { split: "pick"; unit: string } | { split: "close" };

export const tell = (ask: PaneAsk) => window.parent.postMessage(ask, location.origin);

type Layout = { units: [string, string]; at: number };
const KEY = "split";

function load(): Layout | null {
  try {
    const l = JSON.parse(localStorage.getItem(KEY) ?? "null") as Layout | null;
    return l && Array.isArray(l.units) && l.units.length === 2 ? l : null;
  } catch {
    return null;
  }
}

function save(l: Layout | null) {
  if (l) localStorage.setItem(KEY, JSON.stringify(l));
  else localStorage.removeItem(KEY);
  window.dispatchEvent(new Event(KEY));
}

/** Opens the split with these two, the one shown so far on the left. */
export const openSplit = (units: [string, string]) => save({ units, at: load()?.at ?? 0.5 });

/** The split, when one is open; it lives in localStorage, so a reload or a
 * new tab on this browser opens it again. */
export function useSplit() {
  const [layout, setLayout] = useState(load);
  useEffect(() => {
    const change = () => setLayout(load());
    window.addEventListener(KEY, change);
    // Another tab opened or closed it.
    window.addEventListener("storage", change);
    return () => {
      window.removeEventListener(KEY, change);
      window.removeEventListener("storage", change);
    };
  }, []);
  return layout;
}

// Neither pane narrower than this share of the window.
const MIN = 0.2;
const clamp = (at: number) => Math.min(1 - MIN, Math.max(MIN, at));

/** Two panes and the line between them, which a drag, the arrow keys or a
 * double-click (back to even) moves. Without a second, the first fills the
 * row in the same place, so opening one beside it keeps the first's state. */
export function Panes({ start, keep, children: [a, b] }: { start: number; keep: (at: number) => void; children: [ReactNode, ReactNode] }) {
  const [at, setAt] = useState(start);
  const [dragging, setDragging] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  const settle = (to: number) => {
    setAt(to);
    keep(to);
  };
  const drag = (e: PointerEvent<HTMLDivElement>) => {
    const r = box.current!.getBoundingClientRect();
    setAt(clamp((e.clientX - r.left) / r.width));
  };
  const key = (e: KeyboardEvent<HTMLDivElement>) => {
    const step = e.key === "ArrowLeft" ? -0.05 : e.key === "ArrowRight" ? 0.05 : 0;
    if (!step) return;
    e.preventDefault();
    settle(clamp(at + step));
  };
  // A frame under the pointer would take the drag's moves for its own page.
  return (
    <div ref={box} className={`flex h-full ${dragging ? "[&_iframe]:pointer-events-none" : ""}`}>
      <div style={b ? { width: `${at * 100}%` } : undefined} className={`flex min-w-0 flex-col ${b ? "shrink-0" : "flex-1"}`}>
        {a}
      </div>
      {b && (
        <>
          <div
            role="separator"
            aria-orientation="vertical"
            aria-label="Resize the panes"
            aria-valuenow={Math.round(at * 100)}
            tabIndex={0}
            title="Drag to resize; double-click to even"
            onPointerDown={(e) => {
              e.currentTarget.setPointerCapture(e.pointerId);
              setDragging(true);
            }}
            onPointerMove={(e) => dragging && drag(e)}
            onPointerUp={() => {
              setDragging(false);
              settle(at);
            }}
            onDoubleClick={() => settle(0.5)}
            onKeyDown={key}
            className="group relative z-10 w-px shrink-0 cursor-col-resize bg-hair outline-none"
          >
            {/* A grip wider than the line it draws, as editors' sashes are. */}
            <div className={`absolute inset-y-0 -left-[3px] w-[7px] transition-colors group-hover:bg-frame group-focus-visible:bg-frame ${dragging ? "bg-frame" : ""}`} />
          </div>
          <div className="flex min-w-0 flex-1 flex-col">{b}</div>
        </>
      )}
    </div>
  );
}

export function Split({ layout }: { layout: Layout }) {
  const frames = [useRef<HTMLIFrameElement>(null), useRef<HTMLIFrameElement>(null)];
  const units = layout.units;

  useEffect(() => {
    const heard = (e: MessageEvent<PaneAsk>) => {
      if (e.origin !== location.origin || !e.data?.split) return;
      const i = frames.findIndex((f) => f.current?.contentWindow === e.source);
      if (i < 0) return;
      if (e.data.split === "close") {
        // The other one stays, as the whole window: the cookie is what the
        // root route follows.
        document.cookie = `persona=${units[1 - i]}; Path=/; Max-Age=31536000; Secure; SameSite=Lax`;
        save(null);
        location.reload();
      } else {
        const next: [string, string] = [...units];
        // Picking the other pane's assistant swaps the two.
        if (next[1 - i] === e.data.unit) next[1 - i] = next[i];
        next[i] = e.data.unit;
        save({ units: next, at: load()?.at ?? layout.at });
      }
    };
    window.addEventListener("message", heard);
    return () => window.removeEventListener("message", heard);
  });

  // Keyed by unit, so a pick loads the new one rather than keeping the old
  // page under a new address.
  const frame = (i: number) => <iframe key={units[i]} ref={frames[i]} src={`/@${units[i]}/`} title={units[i]} className="h-full w-full border-0" />;
  return (
    <Panes start={layout.at} keep={(at) => save({ units: load()?.units ?? units, at })}>
      {frame(0)}
      {frame(1)}
    </Panes>
  );
}

/** How wide the window's own content is beside a pane it opens (a
 * subagent's work), kept apart from the split's. */
export const BESIDE = {
  start: () => Number(localStorage.getItem("beside")) || 0.5,
  keep: (at: number) => localStorage.setItem("beside", String(at)),
};
