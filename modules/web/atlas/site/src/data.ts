// The shape atlas.py writes, and the indexes the views share.
import * as d3 from "d3";

export interface FileNode {
  name: string;
  path: string;
  bytes: number;
  lang?: string;
  kind: "code" | "config" | "docs" | "data" | "asset";
  lines?: number;
  code?: number;
  comment?: number;
  blank?: number;
  about?: string;
  refs?: [string, number][];
  changed?: number;
  commits?: number;
}
export interface DirNode {
  name: string;
  path: string;
  about?: string;
  children: TreeNode[];
}
export type TreeNode = FileNode | DirNode;

export interface Repo {
  name: string;
  head: string;
  subject: string;
  commits: number;
  first: number;
  last: number;
  about: string;
  tree: DirNode;
  weeks: number[];
}
export interface Service {
  name: string;
  about: string;
  timer: boolean;
  hosts: string[];
  after: string[];
}
export interface Route {
  name: string;
  subdomain: string;
  port: number | null;
  static: boolean;
  host: string;
}
export interface Module {
  id: string;
  name: string;
  area: string;
  files: string[];
  entry: string;
  about: string;
  lines: number;
  hosts: string[];
  services: Service[];
  routes: Route[];
  secrets: string[];
  options: string[];
  reads_secrets?: string[];
}
export interface Host {
  name: string;
  system: string;
  user: string;
  modules: string[];
  services: number;
  routes: number;
}
export interface Link {
  source: string;
  target: string;
  kind: string;
  via: string[];
}
export interface Step {
  title: string;
  text: string;
  view?: "overview" | "map" | "wiring" | "machines";
  focus?: string[];
}
export interface Tour {
  id: string;
  title: string;
  summary?: string;
  step: Step[];
}
export interface Atlas {
  generated: number;
  repos: Repo[];
  system: { hosts: Host[]; modules: Module[]; links: Link[] };
  tours: Tour[];
}

/** A node of the one tree over every repository: everything → repo → dirs → files. */
export interface Item {
  id: string; // "repo:path", or "repo" for a repository
  repo: string;
  name: string;
  path: string;
  file?: FileNode;
  dir?: DirNode;
  about?: string;
  children?: Item[];
}

export const isFile = (n: TreeNode): n is FileNode => !("children" in n);

/** Lines that count toward size: what people wrote and read, not data dumps. */
export const weight = (f: FileNode) =>
  f.kind === "code" || f.kind === "config" || f.kind === "docs" ? f.lines ?? 0 : 0;

export class Model {
  root: d3.HierarchyNode<Item>;
  byId = new Map<string, d3.HierarchyNode<Item>>();
  modules = new Map<string, Module>();
  /** monix file path → the module that owns it. */
  owner = new Map<string, Module>();
  /** File id → ids of files that reference it. */
  inbound = new Map<string, string[]>();
  repos = new Map<string, Repo>();

  constructor(public atlas: Atlas) {
    const item = (repo: string, n: TreeNode): Item => {
      const id = n.path ? `${repo}:${n.path}` : repo;
      if (isFile(n)) return { id, repo, name: n.name, path: n.path, file: n, about: n.about };
      return {
        id,
        repo,
        name: n.name,
        path: n.path,
        dir: n,
        about: n.about,
        children: n.children.map((c) => item(repo, c)),
      };
    };
    const top: Item = {
      id: "",
      repo: "",
      name: "Everything",
      path: "",
      children: atlas.repos.map((r) => ({ ...item(r.name, r.tree), about: r.about || r.tree.about })),
    };
    this.root = d3
      .hierarchy(top, (d) => d.children)
      .sum((d) => (d.file ? weight(d.file) : 0))
      .sort((a, b) => (b.value ?? 0) - (a.value ?? 0));
    this.root.each((n) => this.byId.set(n.data.id, n));
    for (const r of atlas.repos) this.repos.set(r.name, r);
    for (const m of atlas.system.modules) {
      this.modules.set(m.id, m);
      for (const f of m.files) this.owner.set(f, m);
    }
    this.root.each((n) => {
      for (const [t] of n.data.file?.refs ?? []) {
        const tid = `${n.data.repo}:${t}`;
        const list = this.inbound.get(tid) ?? [];
        list.push(n.data.id);
        this.inbound.set(tid, list);
      }
    });
  }

  /** The tree node for an id, accepting the tours' "monix:<module id>" too. */
  node(id: string) {
    const n = this.byId.get(id);
    if (n) return n;
    const m = this.module(id);
    return m ? this.byId.get(`monix:${m.entry}`) : undefined;
  }
  module(id: string) {
    return this.modules.get(id.replace(/^monix:/, ""));
  }
  /** The module a monix file or directory belongs to. */
  moduleOf(n: d3.HierarchyNode<Item>): Module | undefined {
    if (n.data.repo !== "monix") return;
    if (n.data.file) return this.owner.get(n.data.path);
    // A directory belongs to a module when every file with weight in it does.
    let found: Module | undefined;
    let mixed = false;
    n.each((c) => {
      if (!c.data.file || !weight(c.data.file) || mixed) return;
      const m = this.owner.get(c.data.path);
      if (!m || (found && m !== found)) mixed = true;
      found = m;
    });
    return mixed ? undefined : found;
  }
  hostsOf(m: Module) {
    return this.atlas.system.hosts.filter((h) => h.modules.includes(m.id));
  }
}

// ── Formatting ───────────────────────────────────────────────────────────

export const num = d3.format(",");
export const short = (n: number) => (n >= 10_000 ? d3.format(".3~s")(n) : num(n));
export const ago = (t?: number) => {
  if (!t) return "never";
  const s = Date.now() / 1000 - t;
  const units: [number, string][] = [
    [365 * 86400, "year"],
    [30 * 86400, "month"],
    [7 * 86400, "week"],
    [86400, "day"],
    [3600, "hour"],
    [60, "minute"],
  ];
  for (const [u, name] of units) {
    const k = Math.floor(s / u);
    if (k >= 1) return `${k} ${name}${k > 1 ? "s" : ""} ago`;
  }
  return "just now";
};
export const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
/** Markdown-ish inline code in about texts: `x` → <code>x</code>. */
export const prose = (s: string) => esc(s).replace(/`([^`]+)`/g, "<code>$1</code>");
