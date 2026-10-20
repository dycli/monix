// Atlas: a visual map of everything in the git mirror. One JSON file from
// atlas.py, five views, and a panel that explains whatever you pick.
import "./style.css";
import { Model, type Atlas, type Tour } from "./data";
import type { Ctx, View, ViewName } from "./ui";
import { untip, wireTips } from "./ui";
import { closePanel, openPanel } from "./panel";
import { overview } from "./overview";
import { map } from "./map";
import { wiring } from "./wiring";
import { machines } from "./machines";
import { hideTourBar, tourBar, tourList } from "./tours";
import { searchDialog } from "./search";
import { help } from "./help";

const app = document.getElementById("app")!;
const VIEWS: ViewName[] = ["overview", "map", "wiring", "machines", "tours"];

// Theme: follow the system until chosen, then remember the choice.
const saved = localStorage.getItem("atlas.theme");
const systemDark = matchMedia("(prefers-color-scheme: dark)");
const applyTheme = (t: string) => (document.documentElement.dataset.theme = t);
applyTheme(saved ?? (systemDark.matches ? "dark" : "light"));

async function boot() {
  let atlas: Atlas;
  try {
    const r = await fetch("data/atlas.json", { cache: "no-cache" });
    if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
    atlas = await r.json();
  } catch (e) {
    app.innerHTML = `<div class="loading">Couldn't read the scan: ${String(e)}</div>`;
    return;
  }
  const model = new Model(atlas);

  let name: ViewName | null = null;
  let view: View | null = null;
  let selection: string | null = null;
  let tour: { t: Tour; i: number } | null = null;

  const ctx: Ctx = {
    model,
    select(id) {
      selection = id;
      if (id) openPanel(ctx, id);
      else closePanel();
      view?.selected?.(id);
      if (!tour && name) history.replaceState(null, "", `#${name}${id ? "/" + id : ""}`);
    },
    go(v, id) {
      const h = `#${v}${id ? "/" + id : ""}`;
      if (location.hash === h) route();
      else location.hash = h;
    },
  };

  function mount(v: ViewName, arg?: string) {
    view?.destroy?.();
    untip();
    name = v;
    document.body.dataset.view = v;
    document.querySelectorAll<HTMLElement>(".tabs a").forEach((a) => a.setAttribute("aria-current", String(a.dataset.view === v)));
    app.innerHTML = "";
    const el = document.createElement("div");
    el.className = "view";
    app.append(el);
    view =
      v === "overview"
        ? overview(ctx, el)
        : v === "map"
          ? map(ctx, el, arg)
          : v === "wiring"
            ? wiring(ctx, el, arg)
            : v === "machines"
              ? machines(ctx, el, arg)
              : tourList(ctx, el, (t, i) => (location.hash = `#tours/${t.id}/${i + 1}`));
  }

  function route() {
    const raw = decodeURIComponent(location.hash.slice(1));
    const slash = raw.indexOf("/");
    const v = (slash < 0 ? raw : raw.slice(0, slash)) as ViewName;
    const arg = slash < 0 ? undefined : raw.slice(slash + 1);
    if (v === "tours" && arg) {
      const [tid, k] = arg.split("/");
      const t = atlas.tours.find((x) => x.id === tid);
      const i = Math.max(0, Math.min((t?.step.length ?? 1) - 1, (+k || 1) - 1));
      if (t) return runStep(t, i);
    }
    tour = null;
    hideTourBar();
    document.body.classList.remove("touring");
    const target = VIEWS.includes(v) ? v : "overview";
    // A machine filter on Wiring is part of the drawing, not a selection.
    const filter = target === "wiring" && arg?.startsWith("host:");
    if (target !== name || filter) mount(target, arg);
    if (arg && !filter) {
      selection = arg;
      openPanel(ctx, arg);
      view?.selected?.(arg);
    } else if (selection) ctx.select(null);
  }

  function runStep(t: Tour, i: number) {
    tour = { t, i };
    const s = t.step[i];
    const v = s.view ?? "wiring";
    document.body.classList.add("touring");
    closePanel();
    selection = null;
    if (v !== name) mount(v);
    document.querySelectorAll<HTMLElement>(".tabs a").forEach((a) => a.setAttribute("aria-current", String(a.dataset.view === "tours")));
    tourBar(t, i, (k) => (location.hash = `#tours/${t.id}/${k + 1}`), () => (location.hash = "#tours"));
    // Let the view lay out before it zooms.
    requestAnimationFrame(() => view?.focus(s.focus ?? []));
  }

  const openSearch = searchDialog(ctx);
  document.getElementById("search-open")!.addEventListener("click", openSearch);
  const helpDlg = document.getElementById("help") as HTMLDialogElement;
  helpDlg.innerHTML = help(atlas);
  helpDlg.addEventListener("click", (e) => (e.target === helpDlg || (e.target as Element).closest(".close")) && helpDlg.close());
  document.getElementById("help-open")!.addEventListener("click", () => helpDlg.showModal());
  document.getElementById("theme")!.addEventListener("click", () => {
    const t = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    localStorage.setItem("atlas.theme", t);
    applyTheme(t);
    rerender();
  });
  systemDark.addEventListener("change", (e) => {
    if (localStorage.getItem("atlas.theme")) return;
    applyTheme(e.matches ? "dark" : "light");
    rerender();
  });
  // Colours are computed per theme, so the view is drawn again.
  function rerender() {
    const keep = selection;
    if (tour) {
      name = null;
      return runStep(tour.t, tour.i);
    }
    mount(name ?? "overview", keep ?? undefined);
    if (keep) ctx.select(keep);
  }
  addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
      e.preventDefault();
      openSearch();
    } else if (e.key === "/" && !(e.target as Element).closest("input, textarea")) {
      e.preventDefault();
      openSearch();
    } else if (e.key === "?" && !(e.target as Element).closest("input, textarea") && !document.querySelector("dialog[open]")) {
      helpDlg.showModal();
    } else if (e.key === "Escape" && !document.querySelector("dialog[open]")) {
      if (tour) location.hash = "#tours";
      else if (selection) ctx.select(null);
    } else if (tour && (e.key === "ArrowRight" || e.key === "ArrowLeft") && !document.querySelector("dialog[open]")) {
      const k = tour.i + (e.key === "ArrowRight" ? 1 : -1);
      if (k >= 0 && k < tour.t.step.length) location.hash = `#tours/${tour.t.id}/${k + 1}`;
    }
  });
  wireTips();
  addEventListener("hashchange", route);
  if (!location.hash) history.replaceState(null, "", "#overview");
  route();
}

boot();
