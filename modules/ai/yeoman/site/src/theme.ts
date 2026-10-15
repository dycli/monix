import { useEffect, useState } from "react";

export type Theme = "light" | "dark";

const system = matchMedia("(prefers-color-scheme: dark)");
const PAPER: Record<Theme, string> = { light: "#e4d6bf", dark: "#1b1815" };

function apply(t: Theme) {
  document.documentElement.dataset.theme = t;
  // Both metas, media dropped: the bars follow the chosen theme, not the
  // system's, or a dark page sits over a light Android nav bar.
  for (const m of document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]')) {
    m.removeAttribute("media");
    m.content = PAPER[t];
  }
}

/** Light or dark: the phone's, unless the person picks the other one. Picking
    the phone's own theme drops the override, so the app follows the phone
    again; Android colours the installed app's nav bar by the phone's theme,
    so only an override against it leaves a mismatched bar. index.html sets
    the first value before paint. */
export function useTheme(): [Theme, () => void] {
  const [theme, setTheme] = useState(() => document.documentElement.dataset.theme as Theme);
  useEffect(() => apply(theme), [theme]);
  useEffect(() => {
    const follow = (e: MediaQueryListEvent) => {
      const mine = e.matches ? "dark" : "light";
      // The phone switched to what the person had picked: follow it from now on.
      if (localStorage.getItem("theme") === mine) localStorage.removeItem("theme");
      if (!localStorage.getItem("theme")) setTheme(mine);
    };
    system.addEventListener("change", follow);
    return () => system.removeEventListener("change", follow);
  }, []);
  const toggle = () => {
    const next = theme === "dark" ? "light" : "dark";
    if (next === (system.matches ? "dark" : "light")) localStorage.removeItem("theme");
    else localStorage.setItem("theme", next);
    setTheme(next);
  };
  return [theme, toggle];
}
