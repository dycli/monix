// Overview: the headline numbers, where the lines are, and what moved lately.
import * as d3 from "d3";
import type { Ctx, View } from "./ui";
import { mix, mixBar, spark } from "./ui";
import { ago, esc, num, prose, short, type Item } from "./data";
import { family, langColor, AREA_NAMES, areaColor } from "./colors";

export function overview(ctx: Ctx, el: HTMLElement): View {
  const { model } = ctx;
  const a = model.atlas;
  const files: d3.HierarchyNode<Item>[] = [];
  model.root.each((n) => n.data.file && n.value && files.push(n));
  const total = model.root.value ?? 0;
  const commits = d3.sum(a.repos, (r) => r.commits);
  const repos = model.root.children ?? [];
  const weeks = d3.range(52).map((i) => d3.sum(a.repos, (r) => r.weeks[i] ?? 0));
  const lastMonth = d3.sum(weeks.slice(-4));
  const monix = model.byId.get("monix");

  const tiles = [
    ["lines written", short(total), `${num(total)} lines of code, config and docs, blank lines and data files left out`],
    ["repositories", num(a.repos.length), "Every repository in the git mirror"],
    ["files", num(files.length), "Files that hold counted lines"],
    ["NixOS modules", num(a.system.modules.length), "Units of the monix flake, each one feature"],
    ["machines", num(a.system.hosts.length), a.system.hosts.map((h) => h.name).join(", ")],
    ["commits, last 4 weeks", num(lastMonth), `${num(commits)} commits in all`],
  ]
    .map(([l, v, t]) => `<div class="tile" data-tip="${esc(l)}: ${esc(t)}"><b>${v}</b><span>${l}</span></div>`)
    .join("");

  const maxRepo = repos[0]?.value || 1;
  const rows = repos
    .map((r) => {
      const repo = model.repos.get(r.data.repo)!;
      const parts = mix(r);
      const width = (84 * (r.value ?? 0)) / maxRepo;
      return `<tr data-pick="${esc(r.data.id)}" tabindex="0">
        <th><span class="name">${esc(r.data.name)}</span><span class="sub">${esc(firstSentence(r.data.about ?? ""))}</span></th>
        <td class="size"><div class="mixbar inline" style="width:${Math.max(width, 0.6)}%">${parts
          .map(([k, v]) => `<span class="seg" style="flex:${v};background:${langColor(k)}" data-tip="${esc(k)}: ${num(v)} lines"></span>`)
          .join("")}</div><b>${short(r.value ?? 0)}</b></td>
        <td class="spark-cell">${spark(repo.weeks)}</td>
        <td class="when">${ago(repo.last)}</td>
      </tr>`;
    })
    .join("");

  // Hotspots: files changed often, weighted by size, last half year.
  const half = Date.now() / 1000 - 182 * 86400;
  const hot = files
    .filter((f) => (f.data.file!.changed ?? 0) > half && (f.data.file!.commits ?? 0) > 2)
    .map((f) => ({ f, score: (f.data.file!.commits ?? 0) * Math.log10(10 + (f.value ?? 0)) }))
    .sort((x, y) => y.score - x.score)
    .slice(0, 12);
  const maxC = d3.max(hot, (h) => h.f.data.file!.commits ?? 0) || 1;
  const hotRows = hot
    .map(({ f }) => {
      const file = f.data.file!;
      const m = model.moduleOf(f);
      return `<li data-pick="${esc(f.data.id)}" tabindex="0">
        <i class="dot" style="background:${langColor(family(file))}"></i>
        <span class="path"><b>${esc(f.data.name)}</b><small>${esc(f.data.repo)} · ${esc(f.parent?.data.path || "/")}</small></span>
        ${m ? `<span class="area" style="--c:${areaColor(m.area)}">${esc(AREA_NAMES[m.area] ?? m.area)}</span>` : "<span></span>"}
        <span class="bar" data-tip="${esc(f.data.name)}: ${num(file.commits ?? 0)} commits, ${num(f.value ?? 0)} lines"><i style="width:${(100 * (file.commits ?? 0)) / maxC}%"></i></span>
        <b>${num(file.commits ?? 0)}</b>
      </li>`;
    })
    .join("");

  // The biggest single files: where complexity piles up.
  const big = [...files].sort((x, y) => (y.value ?? 0) - (x.value ?? 0)).slice(0, 8);
  const bigRows = big
    .map(
      (f) =>
        `<li data-pick="${esc(f.data.id)}" tabindex="0"><i class="dot" style="background:${langColor(family(f.data.file!))}"></i><span class="path"><b>${esc(f.data.name)}</b><small>${esc(f.data.repo)} · ${esc(f.parent?.data.path || "/")}</small></span><b>${num(f.value ?? 0)}</b></li>`,
    )
    .join("");

  el.innerHTML = `<div class="overview">
    <section class="intro">
      <h1>Everything you've built, in one place</h1>
      <p>${a.repos.length} repositories, measured in lines people wrote. ${
        monix ? `monix, the NixOS flake that runs every machine, is ${Math.round((100 * (monix.value ?? 0)) / total)}% of it.` : ""
      } Pick a repository, file or module anywhere to read what it is; the <a href="#map">Map</a> shows the code to scale, <a href="#wiring">Wiring</a> how the modules connect, and <a href="#tours">Tours</a> walk through how things work.</p>
    </section>
    <section class="tiles">${tiles}</section>
    <section class="card">
      <header><h2>Languages</h2><p>All repositories, by lines</p></header>
      ${mixBar(mix(model.root), { height: 14 })}
    </section>
    <section class="card wide">
      <header><h2>Repositories</h2><p>Bar length is lines, split by language. Commits per week over the last year beside it.</p></header>
      <table class="repos"><thead><tr><th>Repository</th><th>Lines</th><th>Last 52 weeks</th><th>Last change</th></tr></thead><tbody>${rows}</tbody></table>
    </section>
    <div class="pair">
      <section class="card">
        <header><h2>Hotspots</h2><p>Changed most in the last six months</p></header>
        <ol class="hot">${hotRows}</ol>
      </section>
      <section class="card">
        <header><h2>Biggest files</h2><p>Lines of code, comments and config</p></header>
        <ol class="hot big-files">${bigRows}</ol>
      </section>
    </div>
    <section class="card">
      <header><h2>All commits</h2><p>Every repository, per week, last 52 weeks</p></header>
      <div class="weeks">${spark(weeks, 640, 64)}</div>
    </section>
    <p class="foot">Scanned ${ago(a.generated)} from the git mirror on Water. ${prose("Sizes count code, comments and config; blank lines, lockfiles and data files are left out.")}</p>
  </div>`;

  el.querySelectorAll<HTMLElement>("[data-pick]").forEach((r) => {
    const pick = () => ctx.select(r.dataset.pick!);
    r.addEventListener("click", pick);
    r.addEventListener("keydown", (e) => e.key === "Enter" && pick());
  });
  return {
    focus(ids) {
      if (ids[0]) ctx.select(ids[0]);
    },
  };
}

const firstSentence = (s: string) => {
  const m = s.match(/^(.{0,110}?[.!?])(\s|$)/);
  return m ? m[1] : s.length > 110 ? s.slice(0, 108) + "…" : s;
};
