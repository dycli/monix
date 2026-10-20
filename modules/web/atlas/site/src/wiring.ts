// Wiring: the monix modules as a network. Each circle is a module, sized
// by lines and coloured by area; each line is a way one leans on another.
import * as d3 from "d3";
import type { Ctx, View } from "./ui";
import { tip, untip } from "./ui";
import { esc, num, short, type Link, type Module } from "./data";
import { AREA_NAMES, AREAS, areaColor } from "./colors";

interface MNode extends d3.SimulationNodeDatum {
  m: Module;
  r: number;
}
interface MLink extends d3.SimulationLinkDatum<MNode> {
  l: Link;
  source: MNode;
  target: MNode;
}

const KINDS: [string, string][] = [
  ["uses", "calls a shared helper from lib/"],
  ["configures", "sets another module's options"],
  ["reads", "reads another module's settings"],
  ["served by", "gets a web address from ship-proxy"],
  ["starts after", "one of its services waits for the other's"],
];

export function wiring(ctx: Ctx, el: HTMLElement, arg?: string): View {
  const { model } = ctx;
  const sys = model.atlas.system;
  const hosts = sys.hosts.map((h) => h.name);
  let host = arg?.startsWith("host:") ? arg.slice(5) : "";
  const hidden = new Set<string>(JSON.parse(localStorage.getItem("atlas.hiddenKinds") || '["reads"]'));

  const routes = sys.modules.flatMap((m) => m.routes.map((r) => ({ r, m })));
  el.innerHTML = `<div class="wiring">
    <div class="toolbar">
      <div class="seg-ctl" role="radiogroup" aria-label="Machine">
        <button role="radio" data-host="" aria-checked="${!host}">All machines</button>
        ${hosts.map((h) => `<button role="radio" data-host="${esc(h)}" aria-checked="${h === host}">${esc(h)}</button>`).join("")}
      </div>
      <div class="kinds">${KINDS.map(
        ([k, t]) =>
          `<label class="kind-toggle" data-tip="${esc(k)}: ${esc(t)}"><input type="checkbox" data-kind="${esc(k)}" ${hidden.has(k) ? "" : "checked"}><svg width="26" height="10"><line x1="1" x2="25" y1="5" y2="5" class="edge ${cls(k)}"/></svg>${esc(k)}</label>`,
      ).join("")}</div>
    </div>
    <div class="stage"><svg class="net" role="img" aria-label="Network of modules"></svg>
      <div class="key"><ul class="legend">${AREAS.filter((a) => sys.modules.some((m) => m.area === a))
        .map((a) => `<li><i style="background:${areaColor(a)}"></i>${esc(AREA_NAMES[a])}</li>`)
        .join("")}</ul><p class="note">Circle size: lines of code · drag to move, scroll to zoom</p></div>
    </div>
    <div class="routes-strip"><span>Web addresses</span>${routes
      .map(({ r, m }) => `<button class="route" data-mod="${esc(m.id)}" data-tip="${esc(r.subdomain)}.su.is: ${esc(m.name)}${r.port ? `, port ${r.port}` : ", static files"}">${esc(r.subdomain)}</button>`)
      .join("")}</div>
  </div>`;
  const stage = el.querySelector<HTMLElement>(".stage")!;
  const svg = d3.select(el.querySelector<SVGSVGElement>("svg.net")!);

  // Lay out once, offline: areas pulled toward their own spots on a ring so
  // the picture reads as neighbourhoods, then the links settle within.
  const rScale = d3.scaleSqrt().domain([0, d3.max(sys.modules, (m) => m.lines) || 1]).range([4, 46]);
  const nodes: MNode[] = sys.modules.map((m) => ({ m, r: rScale(m.lines) }));
  const byId = new Map(nodes.map((n) => [n.m.id, n]));
  const links: MLink[] = sys.links
    .filter((l) => byId.has(l.source) && byId.has(l.target))
    .map((l) => ({ l, source: byId.get(l.source)!, target: byId.get(l.target)! }));
  // Hubs (hosts, the foundation) link to dozens of modules; dividing by degree
  // keeps them from being dragged out of their own neighbourhood.
  const deg = new Map(nodes.map((n) => [n, 0]));
  links.forEach((l) => {
    deg.set(l.source, deg.get(l.source)! + 1);
    deg.set(l.target, deg.get(l.target)! + 1);
  });
  const present = AREAS.filter((a) => nodes.some((n) => n.m.area === a));
  const R = 330;
  const spot = new Map(
    present.map((a, i) => {
      const t = (i / present.length) * 2 * Math.PI - Math.PI / 2;
      return [a, [Math.cos(t) * R, Math.sin(t) * R]] as const;
    }),
  );
  const rand = d3.randomLcg(7);
  nodes.forEach((n) => {
    const [x, y] = spot.get(n.m.area) ?? [0, 0];
    n.x = x + (rand() - 0.5) * 60;
    n.y = y + (rand() - 0.5) * 60;
  });
  const sim = d3
    .forceSimulation(nodes)
    .randomSource(rand)
    .force("link", d3.forceLink<MNode, MLink>(links).distance((l) => 40 + l.source.r + l.target.r).strength((l) => 0.5 / Math.max(deg.get(l.source)!, deg.get(l.target)!)))
    .force("charge", d3.forceManyBody<MNode>().strength((n) => -40 - n.r * 6))
    .force("collide", d3.forceCollide<MNode>((n) => n.r + 3).iterations(2))
    .force("x", d3.forceX<MNode>((n) => spot.get(n.m.area)?.[0] ?? 0).strength(0.28))
    .force("y", d3.forceY<MNode>((n) => spot.get(n.m.area)?.[1] ?? 0).strength(0.28))
    .stop();
  for (let i = 0; i < 400; i++) sim.tick();

  const defs = svg.append("defs");
  defs
    .append("marker")
    .attr("id", "arrow")
    .attr("viewBox", "0 0 10 10")
    .attr("refX", 9)
    .attr("refY", 5)
    .attr("markerWidth", 7)
    .attr("markerHeight", 7)
    .attr("orient", "auto-start-reverse")
    .append("path")
    .attr("d", "M0,1 L9,5 L0,9 z")
    .attr("class", "arrowhead");

  const world = svg.append("g");
  const gEdges = world.append("g");
  const gNodes = world.append("g");
  const gArea = world.append("g").attr("class", "area-labels");

  const edge = gEdges
    .selectAll<SVGPathElement, MLink>("path")
    .data(links)
    .join("path")
    .attr("class", (d) => `edge ${cls(d.l.kind)}`)
    .attr("marker-end", "url(#arrow)")
    .on("pointermove", (e, d) =>
      tip(
        `<b>${esc(d.source.m.name)}</b> ${esc(d.l.kind)} <b>${esc(d.target.m.name)}</b><br><span>${esc(d.l.via.slice(0, 6).join(", "))}${d.l.via.length > 6 ? "…" : ""}</span>`,
        e,
      ),
    )
    .on("pointerleave", untip);

  const node = gNodes
    .selectAll<SVGGElement, MNode>("g")
    .data(nodes, (d) => d.m.id)
    .join("g")
    .attr("class", "mod")
    .on("pointerenter", (e, d) => {
      hover(d);
      tip(tipHtml(d), e);
    })
    .on("pointermove", (e, d) => tip(tipHtml(d), e))
    .on("pointerleave", () => {
      hover(null);
      untip();
    })
    .on("click", (e, d) => {
      e.stopPropagation();
      ctx.select(`mod:${d.m.id}`);
    });
  node
    .append("circle")
    .attr("r", (d) => d.r)
    .attr("fill", (d) => areaColor(d.m.area));
  node
    .filter((d) => d.m.routes.length > 0)
    .append("circle")
    .attr("class", "badge")
    .attr("r", 2.5)
    .attr("cx", (d) => d.r * 0.72)
    .attr("cy", (d) => -d.r * 0.72);
  node
    .append("text")
    .attr("class", (d) => (d.r > 16 ? "name big" : "name"))
    .attr("dy", (d) => (d.r > 16 ? "0.35em" : d.r + 11))
    .text((d) => d.m.name);

  // A hub like water's host module is pulled toward what it configures, so a
  // label sits over the area's core: members near its median.
  function core(a: string) {
    const ms = nodes.filter((n) => n.m.area === a);
    const mx = d3.median(ms, (n) => n.x!)!,
      my = d3.median(ms, (n) => n.y!)!;
    const near = ms.filter((n) => Math.hypot(n.x! - mx, n.y! - my) < 140);
    return near.length ? near : ms;
  }
  gArea
    .selectAll("text")
    .data(present)
    .join("text")
    .attr("x", (a) => d3.mean(core(a), (n) => n.x!)!)
    .attr("y", (a) => d3.min(core(a), (n) => n.y! - n.r)! - 14)
    .attr("fill", (a) => areaColor(a))
    .text((a) => AREA_NAMES[a]);

  const tipHtml = (d: MNode) => {
    const m = d.m;
    const deg = links.filter((l) => l.source === d || l.target === d).length;
    return `<b>${esc(m.name)}</b> <span>· ${esc(AREA_NAMES[m.area] ?? m.area)}</span><br><span>${short(m.lines)} lines · ${num(m.services.length)} services · ${deg} links${m.routes.length ? ` · ${m.routes.map((r) => r.subdomain + ".su.is").join(", ")}` : ""}</span>`;
  };

  function draw() {
    edge.attr("d", (d) => {
      const s = d.source,
        t = d.target;
      const dx = t.x! - s.x!,
        dy = t.y! - s.y!;
      const len = Math.hypot(dx, dy) || 1;
      const ux = dx / len,
        uy = dy / len;
      const x1 = s.x! + ux * s.r,
        y1 = s.y! + uy * s.r;
      const x2 = t.x! - ux * (t.r + 2),
        y2 = t.y! - uy * (t.r + 2);
      // A slight curve keeps two-way links apart.
      const cx = (x1 + x2) / 2 - uy * len * 0.12,
        cy = (y1 + y2) / 2 + ux * len * 0.12;
      return `M${x1},${y1} Q${cx},${cy} ${x2},${y2}`;
    });
    node.attr("transform", (d) => `translate(${d.x},${d.y})`);
  }
  draw();

  let picked: MNode | null = null;
  let lit = new Set<MNode>();
  function onHost(n: MNode) {
    if (!host) return true;
    if (n.m.area === "hosts") return n.m.id === `hosts/${host}`;
    const h = sys.hosts.find((x) => x.name === host);
    return n.m.hosts.length === 0 ? !!h?.modules.includes(n.m.id) || n.m.id.startsWith("lib/") : n.m.hosts.includes(host);
  }
  function state(focus: MNode | null) {
    const near = new Set<MNode>();
    if (focus) {
      near.add(focus);
      links.forEach((l) => {
        if (hidden.has(l.l.kind)) return;
        if (l.source === focus) near.add(l.target);
        if (l.target === focus) near.add(l.source);
      });
    }
    node
      .classed("off", (d) => !onHost(d))
      .classed("dim", (d) => (focus ? !near.has(d) : lit.size ? !lit.has(d) : false))
      .classed("picked", (d) => d === picked)
      .classed("lit", (d) => lit.has(d))
      .classed("named", (d) => near.has(d) || lit.has(d) || d.r > 13 || d.m.area === "hosts");
    edge
      .classed("hidden", (d) => hidden.has(d.l.kind) || !onHost(d.source) || !onHost(d.target))
      .classed("dim", (d) => (focus ? d.source !== focus && d.target !== focus : lit.size > 0 && !(lit.has(d.source) && lit.has(d.target))))
      .classed("hot", (d) => !!focus && (d.source === focus || d.target === focus));
  }
  const hover = (d: MNode | null) => state(d ?? picked);
  state(null);

  // Pan and zoom, and drag a module to untangle.
  const zoom = d3
    .zoom<SVGSVGElement, unknown>()
    .scaleExtent([0.25, 5])
    .on("zoom", (e) => world.attr("transform", e.transform.toString()));
  svg.call(zoom).on("dblclick.zoom", null);
  node.call(
    d3
      .drag<SVGGElement, MNode>()
      .on("drag", (e, d) => {
        d.x = e.x;
        d.y = e.y;
        draw();
      }),
  );
  svg.on("click", () => ctx.select(null));

  function fit(only?: MNode[], ms = 0) {
    const r = stage.getBoundingClientRect();
    svg.attr("viewBox", `0 0 ${r.width} ${r.height}`);
    const set = only?.length ? only : nodes.filter(onHost);
    const x0 = d3.min(set, (n) => n.x! - n.r)! - 30,
      x1 = d3.max(set, (n) => n.x! + n.r)! + 30;
    const y0 = d3.min(set, (n) => n.y! - n.r)! - 30,
      y1 = d3.max(set, (n) => n.y! + n.r)! + 30;
    // Keep the bottom clear of the legend box.
    const h = r.height - (stage.querySelector<HTMLElement>(".key")?.offsetHeight ?? 0) - 12;
    const k = Math.min(2.2, r.width / (x1 - x0), h / (y1 - y0));
    const t = d3.zoomIdentity
      .translate(r.width / 2, h / 2)
      .scale(k)
      .translate(-(x0 + x1) / 2, -(y0 + y1) / 2);
    (ms ? svg.transition().duration(ms) : svg).call(zoom.transform as never, t);
  }
  const ro = new ResizeObserver(() => fit());
  ro.observe(stage);

  el.querySelectorAll<HTMLButtonElement>("[data-host]").forEach((b) =>
    b.addEventListener("click", () => {
      host = b.dataset.host!;
      el.querySelectorAll("[data-host]").forEach((x) => x.setAttribute("aria-checked", String(x === b)));
      state(picked);
      fit(undefined, 600);
    }),
  );
  el.querySelectorAll<HTMLInputElement>("[data-kind]").forEach((c) =>
    c.addEventListener("change", () => {
      if (c.checked) hidden.delete(c.dataset.kind!);
      else hidden.add(c.dataset.kind!);
      localStorage.setItem("atlas.hiddenKinds", JSON.stringify([...hidden]));
      state(picked);
    }),
  );
  el.querySelectorAll<HTMLButtonElement>(".route").forEach((b) =>
    b.addEventListener("click", () => ctx.select(`mod:${b.dataset.mod}`)),
  );

  const resolve = (id: string) => byId.get(id.replace(/^(mod:|monix:)/, ""));
  if (arg && !arg.startsWith("host:")) {
    picked = resolve(arg) ?? null;
    state(picked);
  }

  return {
    focus(ids) {
      lit = new Set(ids.map(resolve).filter((n) => n) as MNode[]);
      picked = null;
      state(null);
      if (lit.size) fit([...lit].flatMap((n) => [n, ...links.filter((l) => l.source === n || l.target === n).map((l) => (l.source === n ? l.target : l.source))]), 700);
    },
    selected(id) {
      picked = id ? resolve(id) ?? null : null;
      if (picked) lit = new Set();
      state(picked);
    },
    destroy() {
      ro.disconnect();
      sim.stop();
    },
  };
}

const cls = (kind: string) => "k-" + kind.replace(/\s+/g, "-");
