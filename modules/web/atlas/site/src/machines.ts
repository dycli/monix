// Machines: what each computer runs. One treemap per host, modules grouped
// by area and sized by lines; a module shared by several hosts lights up
// in each when you point at it.
import * as d3 from "d3";
import type { Ctx, View } from "./ui";
import { tip, untip } from "./ui";
import { esc, num, short, type Host, type Module } from "./data";
import { AREA_NAMES, AREAS, areaColor } from "./colors";

interface T {
  name: string;
  m?: Module;
  area?: string;
  children?: T[];
}

/** "air — cloud VPS carrying…" → "cloud VPS carrying…", from the host's own comment. */
const role = (m?: Module) => {
  const s = (m?.about ?? "").replace(/^\S+\s+—\s+/, "");
  const cut = s.search(/[:.;(]/);
  return cut > 0 ? s.slice(0, cut) : s;
};

export function machines(ctx: Ctx, el: HTMLElement, arg?: string): View {
  const { model } = ctx;
  const sys = model.atlas.system;
  const totals = new Map(
    sys.hosts.map((h) => [h.name, d3.sum(h.modules, (id) => model.modules.get(id)?.lines ?? 0)]),
  );
  const order = [...sys.hosts].sort((a, b) => totals.get(b.name)! - totals.get(a.name)!);
  const max = d3.max(totals.values()) || 1;
  el.innerHTML = `<div class="machines">
    <p class="lede">Every machine is built from the same modules; each picks the ones it needs. Rectangles are modules, sized by lines and grouped by area. Point at one to find it on the other machines.</p>
    <div class="grid">${order
      .map(
        (h) => `<section class="host" data-host="${esc(h.name)}">
        <header>
          <h2><a href="#" data-pick="host:${esc(h.name)}">${esc(h.name)}</a> <small>${esc(role(model.modules.get(`hosts/${h.name}`)))}</small></h2>
          <p>${num(h.modules.length)} modules · ${num(h.services)} services · ${num(h.routes)} web addresses · ${short(totals.get(h.name)!)} lines</p>
          <div class="size"><i style="width:${(100 * totals.get(h.name)!) / max}%"></i></div>
        </header>
        <svg class="tree" role="img" aria-label="Modules on ${esc(h.name)}"></svg>
      </section>`,
      )
      .join("")}</div>
    <div class="key"><ul class="legend">${AREAS.map((a) => `<li><i style="background:${areaColor(a)}"></i>${esc(AREA_NAMES[a])}</li>`).join("")}</ul></div>
  </div>`;

  const cells: d3.Selection<SVGGElement, d3.HierarchyRectangularNode<T>, SVGGElement, unknown>[] = [];

  function draw(h: Host, svgEl: SVGSVGElement) {
    const { width, height } = svgEl.getBoundingClientRect();
    if (!width || !height) return;
    const svg = d3.select(svgEl).attr("viewBox", `0 0 ${width} ${height}`);
    svg.selectAll("*").remove();
    const mods = h.modules.map((id) => model.modules.get(id)).filter((m) => m) as Module[];
    const data: T = {
      name: h.name,
      children: AREAS.map((a) => ({
        name: a,
        area: a,
        children: mods.filter((m) => m.area === a).map((m) => ({ name: m.name, m, area: a })),
      })).filter((g) => g.children.length),
    };
    const root = d3
      .treemap<T>()
      .size([width, height])
      .paddingInner(2)
      .paddingTop((d) => (d.depth === 1 && d.x1 - d.x0 > 50 ? 16 : d.depth === 1 ? 2 : 0))
      .round(true)
      .tile(d3.treemapSquarify.ratio(1.4))(
      d3
        .hierarchy(data)
        .sum((d) => (d.m ? Math.max(d.m.lines, 8) : 0))
        .sort((a, b) => (b.value ?? 0) - (a.value ?? 0)),
    );
    svg
      .append("g")
      .selectAll("text")
      .data(root.children ?? [])
      .join("text")
      .attr("class", "group")
      .attr("x", (d) => d.x0 + 2)
      .attr("y", (d) => d.y0 + 11)
      .text((d) => (d.x1 - d.x0 > 50 ? AREA_NAMES[d.data.area!] : ""));
    const leaf = svg
      .append("g")
      .selectAll<SVGGElement, d3.HierarchyRectangularNode<T>>("g")
      .data(root.leaves())
      .join("g")
      .attr("class", "cell")
      .attr("transform", (d) => `translate(${d.x0},${d.y0})`)
      .on("pointerenter", (e, d) => {
        shared(d.data.m!.id);
        tip(tipHtml(d.data.m!), e);
      })
      .on("pointermove", (e, d) => tip(tipHtml(d.data.m!), e))
      .on("pointerleave", () => {
        shared(null);
        untip();
      })
      .on("click", (_, d) => ctx.select(`mod:${d.data.m!.id}`));
    leaf
      .append("rect")
      .attr("width", (d) => Math.max(0, d.x1 - d.x0))
      .attr("height", (d) => Math.max(0, d.y1 - d.y0))
      .attr("rx", 3)
      .attr("fill", (d) => areaColor(d.data.area));
    leaf
      .filter((d) => d.x1 - d.x0 > 38 && d.y1 - d.y0 > 16)
      .append("text")
      .attr("x", 5)
      .attr("y", 13)
      .text((d) => {
        const room = Math.floor((d.x1 - d.x0 - 8) / 6.4);
        return d.data.name.length > room ? d.data.name.slice(0, room - 1) + "…" : d.data.name;
      });
    leaf
      .filter((d) => d.x1 - d.x0 > 48 && d.y1 - d.y0 > 32)
      .append("text")
      .attr("class", "n")
      .attr("x", 5)
      .attr("y", 26)
      .text((d) => short(d.data.m!.lines));
    cells.push(leaf);
  }

  const tipHtml = (m: Module) => {
    const on = model.hostsOf(m).map((h) => h.name);
    return `<b>${esc(m.name)}</b> <span>· ${esc(AREA_NAMES[m.area] ?? m.area)}</span><br><span>${short(m.lines)} lines${m.services.length ? ` · ${m.services.length} services` : ""}</span><br><span>${on.length > 1 ? `on ${on.join(", ")}` : "only here"}</span>`;
  };
  function shared(id: string | null) {
    for (const c of cells) c.classed("match", (d) => d.data.m!.id === id).classed("dim", (d) => !!id && d.data.m!.id !== id);
  }

  function drawAll() {
    cells.length = 0;
    el.querySelectorAll<HTMLElement>("section.host").forEach((s) =>
      draw(sys.hosts.find((h) => h.name === s.dataset.host)!, s.querySelector("svg")!),
    );
  }
  const ro = new ResizeObserver(drawAll);
  ro.observe(el.querySelector(".grid")!);
  el.querySelectorAll<HTMLElement>("[data-pick]").forEach((a) =>
    a.addEventListener("click", (e) => {
      e.preventDefault();
      ctx.select(a.dataset.pick!);
    }),
  );

  const light = (names: string[]) =>
    el.querySelectorAll<HTMLElement>("section.host").forEach((s) => {
      s.classList.toggle("lit", names.includes(s.dataset.host!));
      s.classList.toggle("dim", names.length > 0 && !names.includes(s.dataset.host!));
    });
  const hostName = (id: string) => id.replace(/^host:/, "").replace(/^monix:hosts\//, "");
  if (arg?.startsWith("host:")) light([hostName(arg)]);

  return {
    focus(ids) {
      const hs = ids.map(hostName).filter((h) => sys.hosts.some((x) => x.name === h));
      light(hs.length === sys.hosts.length ? [] : hs);
    },
    selected(id) {
      light(id?.startsWith("host:") ? [hostName(id)] : []);
    },
    destroy() {
      ro.disconnect();
    },
  };
}
