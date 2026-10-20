// The detail panel: whatever is selected, explained. A side panel on
// desktop, a bottom sheet on phones.
import * as d3 from "d3";
import type { Ctx } from "./ui";
import { mix, mixBar, spark } from "./ui";
import { ago, esc, num, prose, short, type Item, type Module } from "./data";
import { AREA_NAMES, areaColor, family, langColor } from "./colors";

const el = () => document.getElementById("panel")!;

export function closePanel() {
  document.body.classList.remove("panel-open");
  el().hidden = true;
  el().innerHTML = "";
}

export function openPanel(ctx: Ctx, id: string) {
  const html = id.startsWith("mod:")
    ? moduleHtml(ctx, id.slice(4))
    : id.startsWith("host:")
      ? hostHtml(ctx, id.slice(5))
      : itemHtml(ctx, id);
  if (!html) return closePanel();
  const p = el();
  p.innerHTML = `<button class="close" aria-label="Close">×</button><div class="grip"></div>${html}`;
  p.hidden = false;
  document.body.classList.add("panel-open");
  p.scrollTop = 0;
  p.querySelector(".close")!.addEventListener("click", () => ctx.select(null));
  p.querySelectorAll<HTMLElement>("[data-go]").forEach((a) =>
    a.addEventListener("click", (e) => {
      e.preventDefault();
      const [view, ...rest] = a.dataset.go!.split("|");
      ctx.go(view as never, rest.join("|") || undefined);
    }),
  );
  p.querySelectorAll<HTMLElement>("[data-pick]").forEach((a) =>
    a.addEventListener("click", (e) => {
      e.preventDefault();
      ctx.select(a.dataset.pick!);
    }),
  );
}

const crumbs = (n: d3.HierarchyNode<Item>) =>
  `<nav class="crumbs">${n
    .ancestors()
    .reverse()
    .slice(1, -1)
    .map((a) => `<a href="#" data-pick="${esc(a.data.id)}">${esc(a.data.name)}</a>`)
    .join("<span>/</span>")}</nav>`;

const stat = (label: string, value: string) => `<div class="stat"><b>${value}</b><span>${label}</span></div>`;

function itemHtml(ctx: Ctx, id: string) {
  const n = ctx.model.byId.get(id);
  if (!n) return "";
  const d = n.data;
  const m = ctx.model.moduleOf(n);
  const modLink = m
    ? `<a class="chip" href="#" data-go="wiring|mod:${esc(m.id)}"><i style="background:${areaColor(m.area)}"></i>Module <b>${esc(m.name)}</b> · ${esc(AREA_NAMES[m.area] ?? m.area)}</a>`
    : "";
  if (d.file) {
    const f = d.file;
    const fam = family(f);
    const lines = f.lines ?? 0;
    const refs = (f.refs ?? []).map(([t]) => `${d.repo}:${t}`).filter((t) => ctx.model.byId.has(t));
    const inbound = ctx.model.inbound.get(id) ?? [];
    // Paths beside this file read shorter from its own directory.
    const here = n.parent?.data.id ?? "";
    const rel = (r: string) => (r.startsWith(here + "/") ? r.slice(here.length + 1) : ctx.model.byId.get(r)!.data.path);
    const list = (ids: string[]) =>
      `<ul class="refs">${ids
        .map((r) => {
          const t = ctx.model.byId.get(r)!;
          return `<li><a href="#" data-pick="${esc(r)}"><i style="background:${t.data.file ? langColor(family(t.data.file)) : "var(--muted)"}"></i>${esc(rel(r))}</a></li>`;
        })
        .join("")}</ul>`;
    const split =
      lines && f.kind !== "data"
        ? `<div class="split"><span style="flex:${f.code ?? 0}" class="code" data-tip="Code: ${num(f.code ?? 0)} lines"></span><span style="flex:${f.comment ?? 0}" class="comment" data-tip="Comments: ${num(f.comment ?? 0)} lines"></span><span style="flex:${f.blank ?? 0}" class="blank" data-tip="Blank: ${num(f.blank ?? 0)} lines"></span></div>
           <ul class="legend"><li><i class="code"></i>code ${num(f.code ?? 0)}</li><li><i class="comment"></i>comments ${num(f.comment ?? 0)}</li><li><i class="blank"></i>blank ${num(f.blank ?? 0)}</li></ul>`
        : "";
    return `${crumbs(n)}
      <h2><i class="dot" style="background:${langColor(fam)}"></i>${esc(d.name)}</h2>
      <p class="kind">${esc(f.lang ?? "File")} · ${esc(f.kind)}${f.kind === "data" ? " (not counted in sizes)" : ""}</p>
      ${d.about ? `<p class="about">${prose(d.about)}</p>` : ""}
      ${modLink}
      <div class="stats">${stat("lines", num(lines))}${stat("commits", num(f.commits ?? 0))}${stat("last change", ago(f.changed))}</div>
      ${split}
      ${refs.length ? `<h3>Uses ${refs.length}</h3>${list(refs)}` : ""}
      ${inbound.length ? `<h3>Used by ${inbound.length}</h3>${list(inbound)}` : ""}
      <div class="actions"><a class="btn" href="#" data-go="map|${esc(id)}">Show on the map</a></div>`;
  }
  // A repository or a directory.
  const files: d3.HierarchyNode<Item>[] = [];
  n.each((c) => c.data.file && files.push(c));
  const counted = files.filter((c) => c.value);
  const recent = d3.max(files, (c) => c.data.file!.changed ?? 0);
  const repo = n.depth === 1 ? ctx.model.repos.get(d.repo) : undefined;
  const biggest = n
    .children!.filter((c) => c.value)
    .slice(0, 8)
    .map(
      (c) =>
        `<li><a href="#" data-pick="${esc(c.data.id)}"><span>${esc(c.data.name)}${c.children ? "/" : ""}</span><span class="bar"><i style="width:${(100 * (c.value ?? 0)) / (n.value || 1)}%"></i></span><b>${short(c.value ?? 0)}</b></a></li>`,
    )
    .join("");
  return `${n.depth > 1 ? crumbs(n) : `<nav class="crumbs"><span>repository</span></nav>`}
    <h2>${esc(d.name)}${n.depth > 1 ? "/" : ""}</h2>
    ${repo ? `<p class="kind">${num(repo.commits)} commits since ${new Date(repo.first * 1000).toLocaleDateString(undefined, { month: "short", year: "numeric" })} · last ${ago(repo.last)}</p>` : ""}
    ${d.about ? `<p class="about">${prose(d.about)}</p>` : ""}
    ${modLink}
    <div class="stats">${stat("lines", short(n.value ?? 0))}${stat("files", num(counted.length))}${stat("last change", ago(recent))}</div>
    ${repo ? `<h3>Commits, last 52 weeks</h3>${spark(repo.weeks, 300, 40)}<p class="note">Latest: ${esc(repo.subject)}</p>` : ""}
    ${n.value ? `<h3>Languages</h3>${mixBar(mix(n))}` : `<p class="note">Only data or assets here, nothing counted.</p>`}
    ${biggest ? `<h3>Biggest inside</h3><ul class="big">${biggest}</ul>` : ""}
    <div class="actions"><a class="btn" href="#" data-go="map|${esc(id)}">Show on the map</a></div>`;
}

function moduleHtml(ctx: Ctx, mid: string) {
  const m = ctx.model.modules.get(mid);
  if (!m) return "";
  const links = ctx.model.atlas.system.links;
  const out = links.filter((l) => l.source === m.id);
  const inn = links.filter((l) => l.target === m.id);
  const linkList = (ls: typeof links, other: "source" | "target") =>
    `<ul class="refs">${ls
      .map((l) => {
        const o = ctx.model.modules.get(l[other])!;
        return `<li><a href="#" data-pick="mod:${esc(o.id)}"><i style="background:${areaColor(o.area)}"></i><em>${esc(l.kind)}</em> ${esc(o.name)}</a><small>${esc(l.via.slice(0, 4).join(", "))}${l.via.length > 4 ? ` +${l.via.length - 4}` : ""}</small></li>`;
      })
      .join("")}</ul>`;
  const services = m.services
    .map(
      (s) =>
        `<li><b>${esc(s.name)}</b>${s.timer ? ` <span class="tag">timer</span>` : ""}${s.about ? `<span>${prose(s.about)}</span>` : ""}</li>`,
    )
    .join("");
  const routes = m.routes
    .map(
      (r) =>
        `<li><a class="route" href="https://${esc(r.subdomain)}.su.is" target="_blank" rel="noopener">${esc(r.subdomain)}.su.is</a> <span>${r.static ? "static files" : `→ port ${r.port}`}</span></li>`,
    )
    .join("");
  const hosts = ctx.model.hostsOf(m);
  const fileIds = m.files.map((f) => `monix:${f}`).filter((f) => ctx.model.byId.has(f));
  const fileRows = fileIds
    .map((f) => ctx.model.byId.get(f)!)
    .sort((a, b) => (b.value ?? 0) - (a.value ?? 0));
  const shown = fileRows.slice(0, 12);
  return `<nav class="crumbs"><span>module</span><span>/</span><span>${esc(m.id)}</span></nav>
    <h2><i class="dot" style="background:${areaColor(m.area)}"></i>${esc(m.name)}</h2>
    <p class="kind">${esc(AREA_NAMES[m.area] ?? m.area)} · ${m.files.length} file${m.files.length === 1 ? "" : "s"}</p>
    ${m.about ? `<p class="about">${prose(m.about)}</p>` : ""}
    <div class="stats">${stat("lines", short(m.lines))}${stat("services", num(m.services.length))}${stat("machines", num(hosts.length))}</div>
    ${hosts.length ? `<h3>Runs on</h3><p class="chips">${hosts.map((h) => `<a class="chip" href="#" data-go="machines|host:${esc(h.name)}">${esc(h.name)}</a>`).join("")}</p>` : ""}
    ${routes ? `<h3>Web addresses</h3><ul class="routes">${routes}</ul>` : ""}
    ${services ? `<h3>Services</h3><ul class="services">${services}</ul>` : ""}
    ${out.length ? `<h3>Depends on</h3>${linkList(out, "target")}` : ""}
    ${inn.length ? `<h3>Depended on by</h3>${linkList(inn, "source")}` : ""}
    ${m.secrets.length ? `<h3>Secrets</h3><p class="chips">${m.secrets.map((s) => `<span class="chip">${esc(s)}</span>`).join("")}</p>` : ""}
    ${shown.length ? `<h3>Files</h3><ul class="big">${shown.map((c) => `<li><a href="#" data-pick="${esc(c.data.id)}"><span>${esc(c.data.path.replace(/^modules\//, ""))}</span><span class="bar"><i style="width:${(100 * (c.value ?? 0)) / (fileRows[0].value || 1)}%;background:${c.data.file ? langColor(family(c.data.file)) : ""}"></i></span><b>${short(c.value ?? 0)}</b></a></li>`).join("")}</ul>${fileRows.length > shown.length ? `<p class="note">and ${fileRows.length - shown.length} more</p>` : ""}` : ""}
    <div class="actions"><a class="btn" href="#" data-go="wiring|mod:${esc(m.id)}">Show the wiring</a><a class="btn" href="#" data-go="map|${esc(dirOf(ctx, m))}">Show on the map</a></div>`;
}

/** The deepest directory holding all of a module's files. */
export function dirOf(ctx: Ctx, m: Module) {
  const nodes = m.files.map((f) => ctx.model.byId.get(`monix:${f}`)).filter((n) => n) as d3.HierarchyNode<Item>[];
  if (nodes.length === 1) return nodes[0].data.id;
  let common = nodes[0]?.ancestors() ?? [];
  for (const n of nodes.slice(1)) {
    const a = new Set(n.ancestors());
    common = common.filter((c) => a.has(c));
  }
  return common[0]?.data.id ?? "monix";
}

function hostHtml(ctx: Ctx, name: string) {
  const h = ctx.model.atlas.system.hosts.find((x) => x.name === name);
  if (!h) return "";
  const mods = h.modules.map((id) => ctx.model.modules.get(id)).filter((m) => m) as Module[];
  const by = d3.rollups(
    mods,
    (v) => d3.sum(v, (m) => m.lines),
    (m) => m.area,
  ).sort((a, b) => b[1] - a[1]);
  const total = d3.sum(by, (b) => b[1]) || 1;
  const self = ctx.model.modules.get(`hosts/${name}`);
  return `<nav class="crumbs"><span>machine</span></nav>
    <h2>${esc(h.name)}</h2>
    <p class="kind">${esc(h.system)} · user ${esc(h.user)}</p>
    ${self?.about ? `<p class="about">${prose(self.about)}</p>` : ""}
    <div class="stats">${stat("modules", num(mods.length))}${stat("services", num(h.services))}${stat("web addresses", num(h.routes))}</div>
    <h3>What it carries, by area</h3>
    <div class="mixbar" style="height:10px">${by.map(([a, v]) => `<span class="seg" style="flex:${v};background:${areaColor(a)}" data-tip="${esc(AREA_NAMES[a] ?? a)}: ${num(v)} lines"></span>`).join("")}</div>
    <ul class="legend">${by.map(([a, v]) => `<li><i style="background:${areaColor(a)}"></i>${esc(AREA_NAMES[a] ?? a)} <b>${Math.round((100 * v) / total)}%</b></li>`).join("")}</ul>
    <h3>Biggest modules</h3>
    <ul class="big">${mods
      .sort((a, b) => b.lines - a.lines)
      .slice(0, 10)
      .map(
        (m) =>
          `<li><a href="#" data-pick="mod:${esc(m.id)}"><span>${esc(m.name)}</span><span class="bar"><i style="width:${(100 * m.lines) / (mods[0].lines || 1)}%;background:${areaColor(m.area)}"></i></span><b>${short(m.lines)}</b></a></li>`,
      )
      .join("")}</ul>
    <div class="actions"><a class="btn" href="#" data-go="wiring|host:${esc(h.name)}">Its wiring</a></div>`;
}

