// ⌘K: find any repository, directory, file, module or machine by name.
import type { Ctx } from "./ui";
import { esc, short } from "./data";
import { areaColor, family, langColor, AREA_NAMES } from "./colors";

interface Hit {
  id: string;
  view: "map" | "wiring" | "machines";
  label: string;
  sub: string;
  color: string;
  kind: string;
  hay: string;
  weight: number;
}

export function searchDialog(ctx: Ctx) {
  const dlg = document.getElementById("search") as HTMLDialogElement;
  const { model } = ctx;
  const hits: Hit[] = [];
  model.root.each((n) => {
    if (!n.depth) return;
    const f = n.data.file;
    hits.push({
      id: n.data.id,
      view: "map",
      label: n.data.name + (n.children ? "/" : ""),
      sub: n.depth === 1 ? "repository" : `${n.data.repo} · ${n.parent?.data.path || "/"}`,
      color: f ? langColor(family(f)) : "var(--ink-3)",
      kind: n.depth === 1 ? "repo" : f ? "file" : "dir",
      hay: `${n.data.repo}/${n.data.path}`.toLowerCase(),
      weight: n.value ?? 0,
    });
  });
  for (const m of model.atlas.system.modules)
    hits.push({
      id: `mod:${m.id}`,
      view: "wiring",
      label: m.name,
      sub: `module · ${AREA_NAMES[m.area] ?? m.area}`,
      color: areaColor(m.area),
      kind: "module",
      hay: `${m.name} ${m.id} ${m.services.map((s) => s.name).join(" ")} ${m.routes.map((r) => r.subdomain + ".su.is").join(" ")}`.toLowerCase(),
      weight: m.lines * 4,
    });
  for (const h of model.atlas.system.hosts)
    hits.push({ id: `host:${h.name}`, view: "machines", label: h.name, sub: "machine", color: "var(--ink)", kind: "machine", hay: h.name, weight: 1e9 });

  dlg.innerHTML = `<form method="dialog" class="search">
    <input type="search" placeholder="Find a repo, file, module, service or web address" autocomplete="off" spellcheck="false" aria-label="Search">
    <ul role="listbox"></ul>
    <p class="hint"><kbd>↑</kbd><kbd>↓</kbd> to move · <kbd>Enter</kbd> to open · <kbd>Esc</kbd> to close</p>
  </form>`;
  const input = dlg.querySelector("input")!;
  const list = dlg.querySelector("ul")!;
  let shown: Hit[] = [];
  let at = 0;

  const score = (h: Hit, q: string) => {
    const name = h.label.toLowerCase();
    if (name === q || name === q + "/") return 4;
    if (name.startsWith(q)) return 3;
    if (name.includes(q)) return 2;
    if (h.hay.includes(q)) return 1;
    // Every word somewhere in the path.
    return q.split(/\s+/).every((w) => h.hay.includes(w)) ? 0.5 : 0;
  };
  function render() {
    const q = input.value.trim().toLowerCase();
    shown = q
      ? hits
          .map((h) => [h, score(h, q)] as const)
          .filter(([, s]) => s > 0)
          .sort((a, b) => b[1] - a[1] || b[0].weight - a[0].weight)
          .slice(0, 40)
          .map(([h]) => h)
      : hits.filter((h) => h.kind === "machine" || h.kind === "repo").sort((a, b) => b.weight - a.weight).slice(0, 12);
    at = Math.min(at, Math.max(0, shown.length - 1));
    list.innerHTML = shown
      .map(
        (h, i) =>
          `<li role="option" aria-selected="${i === at}" data-i="${i}"><i style="background:${h.color}"></i><span><b>${esc(h.label)}</b><small>${esc(h.sub)}</small></span><em>${h.kind}${h.kind === "file" || h.kind === "dir" || h.kind === "repo" ? ` · ${short(h.weight)}` : ""}</em></li>`,
      )
      .join("");
    list.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: "nearest" });
  }
  const open = (h?: Hit) => {
    if (!h) return;
    dlg.close();
    ctx.go(h.view, h.id);
  };
  input.addEventListener("input", () => {
    at = 0;
    render();
  });
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") at = Math.min(shown.length - 1, at + 1);
    else if (e.key === "ArrowUp") at = Math.max(0, at - 1);
    else if (e.key === "Enter") {
      e.preventDefault();
      return open(shown[at]);
    } else return;
    e.preventDefault();
    render();
  });
  list.addEventListener("click", (e) => {
    const li = (e.target as Element).closest<HTMLElement>("li");
    if (li) open(shown[+li.dataset.i!]);
  });
  dlg.addEventListener("click", (e) => e.target === dlg && dlg.close());

  return () => {
    input.value = "";
    at = 0;
    render();
    dlg.showModal();
    input.focus();
  };
}
