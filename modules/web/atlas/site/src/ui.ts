// Shared pieces: the context views get, the tooltip, small charts.
import * as d3 from "d3";
import type { Model } from "./data";
import { family, langColor, LANGS } from "./colors";
import { esc, num } from "./data";

export type ViewName = "overview" | "map" | "wiring" | "machines" | "tours";

export interface Ctx {
  model: Model;
  /** Open an item in the detail panel and record it in the address. */
  select(id: string | null): void;
  /** Switch view, optionally to a selection. */
  go(view: ViewName, id?: string): void;
}

export interface View {
  /** Light up these ids (a tour step or a search pick). */
  focus(ids: string[]): void;
  /** The panel's selection changed. */
  selected?(id: string | null): void;
  /** Colours depend on the theme. */
  repaint?(): void;
  destroy?(): void;
}

// ── Tooltip ──────────────────────────────────────────────────────────────

const tipEl = () => document.getElementById("tip")!;
export function tip(html: string, e: { clientX: number; clientY: number }) {
  const t = tipEl();
  t.innerHTML = html;
  t.hidden = false;
  const r = t.getBoundingClientRect();
  const x = Math.min(e.clientX + 14, innerWidth - r.width - 8);
  const y = e.clientY + 16 + r.height > innerHeight ? e.clientY - r.height - 12 : e.clientY + 16;
  t.style.transform = `translate(${Math.max(8, x)}px, ${Math.max(8, y)}px)`;
}
export const untip = () => (tipEl().hidden = true);

// ── Language mix ─────────────────────────────────────────────────────────

/** Lines per language family under a tree node, biggest first. */
export function mix(n: d3.HierarchyNode<import("./data").Item>) {
  const by = new Map<string, number>();
  n.each((c) => {
    const f = c.data.file;
    if (f && c.value) by.set(family(f), (by.get(family(f)) ?? 0) + c.value);
  });
  const order = [...LANGS, "Docs", "Other"];
  return [...by].sort((a, b) => order.indexOf(a[0]) - order.indexOf(b[0]));
}

/** A thin stacked bar of the mix, with a 2px gap between segments. */
export function mixBar(parts: [string, number][], { height = 10, legend = true } = {}) {
  const total = d3.sum(parts, (p) => p[1]) || 1;
  const segs = parts
    .filter((p) => p[1] / total > 0.002)
    .map(
      ([k, v]) =>
        `<span class="seg" style="flex:${v};background:${langColor(k)}" data-tip="${esc(k)}: ${num(v)} lines (${Math.round((100 * v) / total)}%)"></span>`,
    )
    .join("");
  const keys = legend
    ? `<ul class="legend">${parts
        .filter((p) => p[1] / total > 0.01)
        .map(
          ([k, v]) =>
            `<li><i style="background:${langColor(k)}"></i>${esc(k)} <b>${Math.round((100 * v) / total)}%</b></li>`,
        )
        .join("")}</ul>`
    : "";
  return `<div class="mixbar" style="height:${height}px">${segs}</div>${keys}`;
}

/** A 52-week commit sparkline as inline SVG, with a hover per week. */
export function spark(weeks: number[], w = 120, h = 26) {
  const max = d3.max(weeks) || 1;
  const bw = w / weeks.length;
  const bars = weeks
    .map((c, i) => {
      const bh = c ? Math.max(1.5, (c / max) * (h - 2)) : 0;
      const ago = weeks.length - 1 - i;
      const label = `${c} commit${c === 1 ? "" : "s"} ${ago === 0 ? "this week" : ago === 1 ? "last week" : `${ago} weeks ago`}`;
      return `<rect class="hit" x="${i * bw}" y="0" width="${bw}" height="${h}" data-tip="${label}"/>${
        bh ? `<rect class="wk" x="${i * bw + 0.5}" y="${h - bh}" width="${Math.max(1, bw - 1)}" height="${bh}" rx="0.75"/>` : ""
      }`;
    })
    .join("");
  return `<svg class="spark" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" role="img" aria-label="Commits per week over the last year"><line x1="0" x2="${w}" y1="${h - 0.5}" y2="${h - 0.5}" class="base"/>${bars}</svg>`;
}

/** "Name: value" with the value in bold. */
const label = (s: string) => {
  const i = s.indexOf(": ");
  return i < 0 ? esc(s) : `${esc(s.slice(0, i))}: <b>${esc(s.slice(i + 2))}</b>`;
};

/** Any element carrying data-tip shows it on hover. */
export function wireTips(root: HTMLElement | Document = document) {
  root.addEventListener("pointerover", (e) => {
    const t = (e.target as Element).closest?.("[data-tip]");
    if (t) tip(label(t.getAttribute("data-tip")!), e as PointerEvent);
  });
  root.addEventListener("pointermove", (e) => {
    const t = (e.target as Element).closest?.("[data-tip]");
    if (t) tip(document.getElementById("tip")!.innerHTML, e as PointerEvent);
  });
  root.addEventListener("pointerout", (e) => {
    if ((e.target as Element).closest?.("[data-tip]")) untip();
  });
}
