import { useEffect } from "react";

// A pinch sizes the talk's text, never the page: the page zoomed leaves the
// composer and header off screen. The size is CSS `zoom` on the talk (it
// reflows, unlike a transform), kept per device.
const KEY = "talk-size";
const MIN = 0.8;
const MAX = 1.8;

const clamp = (s: number) => Math.min(MAX, Math.max(MIN, s));
const set = (s: number) => document.documentElement.style.setProperty("--talk", String(s));

export function usePinchText() {
  useEffect(() => {
    let size = clamp(Number(localStorage.getItem(KEY)) || 1);
    set(size);
    const keep = () => localStorage.setItem(KEY, String(size));
    let from: { gap: number; size: number } | undefined;
    const gap = (t: TouchList) => Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY);
    const start = (e: TouchEvent) => {
      if (e.touches.length === 2) from = { gap: gap(e.touches), size };
    };
    const move = (e: TouchEvent) => {
      if (e.touches.length < 2) return;
      e.preventDefault();
      from ??= { gap: gap(e.touches), size };
      size = clamp((from.size * gap(e.touches)) / from.gap);
      set(size);
    };
    const end = (e: TouchEvent) => {
      if (from && e.touches.length < 2) {
        from = undefined;
        keep();
      }
    };
    // Safari's own pinch, which `user-scalable=no` no longer stops.
    const gesture = (e: Event) => e.preventDefault();
    // A trackpad's pinch comes as a wheel with ctrl held.
    const wheel = (e: WheelEvent) => {
      if (!e.ctrlKey) return;
      e.preventDefault();
      size = clamp(size * Math.exp(-e.deltaY / 200));
      set(size);
      keep();
    };
    const opts = { passive: false };
    document.addEventListener("touchstart", start, opts);
    document.addEventListener("touchmove", move, opts);
    document.addEventListener("touchend", end);
    document.addEventListener("touchcancel", end);
    document.addEventListener("gesturestart", gesture, opts);
    document.addEventListener("gesturechange", gesture, opts);
    document.addEventListener("wheel", wheel, opts);
    return () => {
      document.removeEventListener("touchstart", start);
      document.removeEventListener("touchmove", move);
      document.removeEventListener("touchend", end);
      document.removeEventListener("touchcancel", end);
      document.removeEventListener("gesturestart", gesture);
      document.removeEventListener("gesturechange", gesture);
      document.removeEventListener("wheel", wheel);
    };
  }, []);
}
