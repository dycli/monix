// Colour by job: identity (language, area) uses the validated categorical
// slots in fixed order; magnitude (age, activity) uses one blue ramp.
// Slots checked with the dataviz validator against both surfaces
// (light #fbf8f2, dark #1d1b18): CVD ΔE ≥ 8.4, normal-vision ≥ 19.
import * as d3 from "d3";
import type { FileNode } from "./data";

const LIGHT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"];
const DARK = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"];

export const dark = () => document.documentElement.dataset.theme === "dark";
const slot = (i: number) => (dark() ? DARK : LIGHT)[i];
const muted = () => (dark() ? "#5d574e" : "#c9c0b1");
const docs = () => (dark() ? "#7b7468" : "#a69c8c");

export const LANGS = ["Rust", "Nix", "Python", "C", "QML", "Shell", "TS / JS", "HTML / CSS"];
const LANG_OF: Record<string, string> = {
  Rust: "Rust",
  Nix: "Nix",
  Python: "Python",
  C: "C",
  "C++": "C",
  QML: "QML",
  Shell: "Shell",
  TypeScript: "TS / JS",
  JavaScript: "TS / JS",
  HTML: "HTML / CSS",
  CSS: "HTML / CSS",
};
/** The language family a file counts under: one of LANGS, "Docs" or "Other". */
export const family = (f: FileNode) =>
  LANG_OF[f.lang ?? ""] ?? (f.kind === "docs" ? "Docs" : "Other");
export const langColor = (fam: string) => {
  const i = LANGS.indexOf(fam);
  return i >= 0 ? slot(i) : fam === "Docs" ? docs() : muted();
};

export const AREAS = ["ai", "homelab", "desktop", "foundation", "networking", "hosts", "cli", "web"];
export const AREA_NAMES: Record<string, string> = {
  ai: "AI",
  homelab: "Homelab",
  desktop: "Desktop",
  foundation: "Foundation",
  networking: "Networking",
  hosts: "Hosts",
  cli: "Command line",
  web: "Web",
};
export const areaColor = (a?: string) => {
  const i = AREAS.indexOf(a ?? "");
  return i >= 0 ? slot(i) : muted();
};

/** One hue, light to dark (or dark to light on the dark surface), t in [0, 1]. */
export const ramp = (t: number) =>
  dark()
    ? d3.interpolateLab("#2c3644", "#8fc0ff")(t)
    : d3.interpolateLab("#e3ecf6", "#0f4a8f")(t);
export const none = () => muted();
