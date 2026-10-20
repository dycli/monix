// The Map: every repository as a circle, every directory inside it, every
// file inside those, each sized by its lines. Click to zoom in.
import * as d3 from "d3";
import type { Ctx, View } from "./ui";
import { tip, untip } from "./ui";
import { ago, esc, num, short, type Item } from "./data";
import { AREA_NAMES, AREAS, areaColor, family, langColor, LANGS, none, ramp } from "./colors";

type N = d3.HierarchyCircularNode<Item>;
type Mode = "language" | "age" | "activity" | "area";
const MODES: [Mode, string][] = [
  ["language", "Language"],
  ["area", "Area"],
  ["age", "Last change"],
  ["activity", "Commits"],
];

let mode: Mode = (localStorage.getItem("atlas.mapMode") as Mode) || "language";

export function map(ctx: Ctx, el: HTMLElement, arg?: string): View {
  const { model } = ctx;
  el.innerHTML = `<div class="mapview">
    <div class="toolbar">
      <nav class="trail" aria-label="Where you are"></nav>
      <div class="seg-ctl" role="radiogroup" aria-label="Colour by">${MODES.map(
        ([m, l]) => `<button role="radio" data-mode="${m}" aria-checked="${m === mode}">${l}</button>`,
      ).join("")}</div>
    </div>
    <div class="stage"><svg class="pack" role="img" aria-label="Circle map of the code"></svg><div class="key"></div><p class="hint">Click a circle to zoom in · click outside to zoom out</p></div>
  </div>`;
  const stage = el.querySelector<HTMLElement>(".stage")!;
  const svg = d3.select(el.querySelector<SVGSVGElement>("svg.pack")!);
  const trail = el.querySelector<HTMLElement>(".trail")!;
  const key = el.querySelector<HTMLElement>(".key")!;

  const S = 1000;
  const root = d3
    .pack<Item>()
    .size([S, S])
    .padding((d) => (d.depth === 0 ? 14 : d.depth === 1 ? 6 : 2.5))(model.root.copy()) as N;
  // The copy has fresh node objects; index them.
  const byId = new Map<string, N>();
  root.each((n) => byId.set(n.data.id, n));
  const nodes = root.descendants().filter((n) => n.depth > 0 && (n.value ?? 0) > 0);

  const now = Date.now() / 1000;
  const ageT = (t?: number) => (t ? Math.max(0, 1 - Math.log1p((now - t) / 86400) / Math.log1p(730)) : -1);
  const maxCommits = d3.max(nodes, (n) => n.data.file?.commits ?? 0) || 1;
  const actT = (c?: number) => (c ? Math.log1p(c) / Math.log1p(maxCommits) : -1);
  const fill = (n: N) => {
    const f = n.data.file;
    if (!f) return null;
    if (mode === "language") return langColor(family(f));
    if (mode === "area") {
      const m = n.data.repo === "monix" ? model.owner.get(n.data.path) : undefined;
      return m ? areaColor(m.area) : none();
    }
    const t = mode === "age" ? ageT(f.changed) : actT(f.commits);
    return t < 0 ? none() : ramp(t);
  };

  const gCircles = svg.append("g");
  const gArcs = svg.append("g").attr("class", "arcs");
  const gLabels = svg.append("g").attr("class", "labels");

  const circle = gCircles
    .selectAll<SVGCircleElement, N>("circle")
    .data(nodes, (d) => d.data.id)
    .join("circle")
    .attr("class", (d) => (d.children ? `dir depth${Math.min(d.depth, 3)}` : "file"))
    .on("pointermove", (e, d) => tip(tipHtml(d), e))
    .on("pointerleave", untip)
    .on("click", (e, d) => {
      e.stopPropagation();
      if (d.children) {
        if (focus !== d) zoomTo(d);
        ctx.select(d.data.id);
      } else {
        if (focus !== d.parent) zoomTo(d.parent!);
        ctx.select(d.data.id);
      }
    });
  const paint = () => circle.attr("fill", (d) => fill(d) ?? "");
  paint();

  const tipHtml = (d: N) => {
    const f = d.data.file;
    const m = model.moduleOf(d);
    const head = `<b>${esc(d.data.name)}${d.children ? "/" : ""}</b>`;
    const sub = f
      ? `${esc(f.lang ?? "")} · ${num(f.lines ?? 0)} lines · ${f.commits ? `${num(f.commits)} commits · ` : ""}changed ${ago(f.changed)}`
      : `${short(d.value ?? 0)} lines · ${d.leaves().filter((l) => l.value).length} files`;
    return `${head}<br><span>${sub}</span>${m ? `<br><span>module ${esc(m.name)} · ${esc(AREA_NAMES[m.area] ?? m.area)}</span>` : ""}`;
  };

  let focus: N = root;
  let view: [number, number, number] = [root.x, root.y, root.r * 2];
  let W = 0,
    H = 0,
    k = 1;
  let lit = new Set<N>();
  let picked: N | undefined;

  const sx = (x: number) => (x - view[0]) * k + W / 2;
  const sy = (y: number) => (y - view[1]) * k + H / 2;

  function place() {
    k = (Math.min(W, H) - 16) / view[2];
    circle.attr("cx", (d) => sx(d.x)).attr("cy", (d) => sy(d.y)).attr("r", (d) => Math.max(0, d.r * k));
    gLabels.selectAll<SVGTextElement, N>("text").attr("transform", (d) => labelAt(d));
    drawArcs();
  }
  const labelAt = (d: N) =>
    d.children && d !== focus && d.r * k > 60
      ? `translate(${sx(d.x)},${sy(d.y - d.r) + 14})`
      : `translate(${sx(d.x)},${sy(d.y)})`;

  function labels() {
    // Name the focus's children big enough to read, and inside each child
    // directory its biggest children too when there is room.
    const want: N[] = [];
    for (const c of focus.children ?? []) {
      if (!(c.value ?? 0)) continue;
      if (c.r * k > 16) want.push(c);
      if (c.children && c.r * k > 60)
        for (const g of c.children) if ((g.value ?? 0) && g.r * k > 22) want.push(g);
    }
    gLabels
      .selectAll<SVGTextElement, N>("text")
      .data(want, (d) => d.data.id)
      .join("text")
      .attr("class", (d) => (d.parent === focus ? (d.children && d.r * k > 60 ? "top" : "own") : "inner"))
      .attr("transform", (d) => labelAt(d))
      .text((d) => {
        const room = Math.floor((d.r * k * (d.parent === focus ? 1.8 : 1.6)) / 7);
        const name = d.data.name + (d.children ? "/" : "");
        return name.length > room ? name.slice(0, Math.max(3, room - 1)) + "…" : name;
      });
  }

  function zoomTo(d: N, instant = false) {
    focus = d;
    const target: [number, number, number] = [d.x, d.y, d.r * 2.05];
    drawTrail();
    gLabels.selectAll("text").remove();
    circle.classed("inside", (c) => c === d || c.ancestors().includes(d));
    if (instant || matchMedia("(prefers-reduced-motion: reduce)").matches) {
      view = target;
      place();
      labels();
      return;
    }
    const i = d3.interpolateZoom(view, target);
    svg
      .transition()
      .duration(Math.min(900, Math.max(450, i.duration * 0.9)))
      .tween("zoom", () => (t) => {
        view = i(t) as [number, number, number];
        place();
      })
      .on("end", labels);
  }

  function drawTrail() {
    const chain = focus.ancestors().reverse();
    trail.innerHTML = chain
      .map((n, i) =>
        i === chain.length - 1
          ? `<span class="here">${esc(i === 0 ? "All repositories" : n.data.name)}</span>`
          : `<a href="#" data-id="${esc(n.data.id)}">${esc(i === 0 ? "All repositories" : n.data.name)}</a>`,
      )
      .join(`<span class="sep">/</span>`);
    // On a phone the trail is one scrolling line; keep the current folder in view.
    trail.scrollLeft = trail.scrollWidth;
    trail.querySelectorAll<HTMLElement>("a").forEach((a) =>
      a.addEventListener("click", (e) => {
        e.preventDefault();
        const n = byId.get(a.dataset.id!)!;
        zoomTo(n);
        ctx.select(n.depth ? n.data.id : null);
      }),
    );
  }

  // Import arcs: from the picked file to what it uses (solid) and from
  // what uses it (dashed).
  function drawArcs() {
    const f = picked?.data.file ? picked : undefined;
    const pairs: { a: N; b: N; out: boolean }[] = [];
    if (f) {
      for (const [t] of f.data.file!.refs ?? []) {
        const b = byId.get(`${f.data.repo}:${t}`);
        if (b && b.r) pairs.push({ a: f, b, out: true });
      }
      for (const s of model.inbound.get(f.data.id) ?? []) {
        const a = byId.get(s);
        if (a && a.r) pairs.push({ a, b: f, out: false });
      }
    }
    gArcs
      .selectAll<SVGPathElement, (typeof pairs)[0]>("path")
      .data(pairs)
      .join("path")
      .attr("class", (p) => (p.out ? "out" : "in"))
      .attr("d", (p) => {
        const x1 = sx(p.a.x),
          y1 = sy(p.a.y),
          x2 = sx(p.b.x),
          y2 = sy(p.b.y);
        const dx = x2 - x1,
          dy = y2 - y1;
        const bend = 0.25;
        return `M${x1},${y1} Q${(x1 + x2) / 2 - dy * bend},${(y1 + y2) / 2 + dx * bend} ${x2},${y2}`;
      });
  }

  function highlight() {
    circle.classed("lit", (d) => lit.has(d)).classed("picked", (d) => d === picked);
    circle.classed("touched", (d) => {
      if (!picked?.data.file) return false;
      const id = d.data.id;
      return (
        (picked.data.file.refs ?? []).some(([t]) => `${picked!.data.repo}:${t}` === id) ||
        (model.inbound.get(picked.data.id) ?? []).includes(id)
      );
    });
    drawArcs();
  }

  function drawKey() {
    if (mode === "language") {
      key.innerHTML = `<ul class="legend">${[...LANGS, "Docs", "Other"]
        .map((l) => `<li><i style="background:${langColor(l)}"></i>${esc(l)}</li>`)
        .join("")}</ul>`;
    } else if (mode === "area") {
      key.innerHTML = `<ul class="legend">${AREAS.map(
        (a) => `<li><i style="background:${areaColor(a)}"></i>${esc(AREA_NAMES[a])}</li>`,
      ).join("")}<li><i style="background:${none()}"></i>Outside monix</li></ul>`;
    } else {
      const stops = d3.range(0, 1.01, 0.1).map((t) => `${ramp(t)} ${t * 100}%`);
      const [lo, hi] = mode === "age" ? ["2 years ago", "today"] : ["1 commit", `${maxCommits} commits`];
      key.innerHTML = `<div class="ramp"><span>${lo}</span><i style="background:linear-gradient(90deg,${stops.join(",")})"></i><span>${hi}</span></div><ul class="legend"><li><i style="background:${none()}"></i>no history</li></ul>`;
    }
  }

  el.querySelectorAll<HTMLButtonElement>("[data-mode]").forEach((b) =>
    b.addEventListener("click", () => {
      mode = b.dataset.mode as Mode;
      localStorage.setItem("atlas.mapMode", mode);
      el.querySelectorAll("[data-mode]").forEach((x) => x.setAttribute("aria-checked", String(x === b)));
      paint();
      drawKey();
    }),
  );
  svg.on("click", () => {
    if (focus.parent) {
      zoomTo(focus.parent);
      ctx.select(focus.depth ? focus.data.id : null);
    }
  });

  const ro = new ResizeObserver(() => {
    const r = stage.getBoundingClientRect();
    W = r.width;
    H = r.height;
    svg.attr("viewBox", `0 0 ${W} ${H}`);
    place();
    labels();
  });
  ro.observe(stage);

  const resolve = (id: string) => {
    const n = model.node(id);
    return n ? byId.get(n.data.id) : undefined;
  };
  /** Zoom so `n` is visible: to it if a directory, to its parent if a file. */
  const reveal = (n: N, instant = false) => {
    const target = n.children ? n : n.parent!;
    if (target !== focus) zoomTo(target, instant);
  };

  drawKey();
  {
    const r = stage.getBoundingClientRect();
    W = r.width;
    H = r.height;
  }
  const start = arg ? resolve(arg) : undefined;
  if (start) {
    reveal(start, true);
    picked = start;
    highlight();
  } else zoomTo(root, true);

  return {
    focus(ids) {
      const ns = ids.map(resolve).filter((n) => n) as N[];
      lit = new Set(ns);
      if (!ns.length) return highlight();
      // Zoom to the smallest directory holding them all.
      let common = ns[0].ancestors();
      for (const n of ns.slice(1)) {
        const a = new Set(n.ancestors());
        common = common.filter((c) => a.has(c));
      }
      const c = common[0];
      reveal(ns.length === 1 ? ns[0] : c);
      picked = ns.length === 1 ? ns[0] : undefined;
      highlight();
    },
    selected(id) {
      picked = id ? resolve(id) : undefined;
      if (picked && !picked.ancestors().includes(focus)) reveal(picked);
      else if (picked && picked.children && picked !== focus) reveal(picked);
      highlight();
    },
    destroy() {
      ro.disconnect();
      svg.interrupt();
    },
  };
}
