import { useEffect, useState } from "react";

export type Theme = "light" | "dark";

const system = matchMedia("(prefers-color-scheme: dark)");
const PAPER: Record<Theme, string> = { light: "#ffffff", dark: "#171719" };

function apply(t: Theme) {
  document.documentElement.dataset.theme = t;
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", PAPER[t]);
}

/** Light or dark: the system's until the person picks, then theirs for good
    on this browser. index.html sets the first value before paint. */
export function useTheme(): [Theme, () => void] {
  const [theme, setTheme] = useState(() => document.documentElement.dataset.theme as Theme);
  useEffect(() => apply(theme), [theme]);
  useEffect(() => {
    const follow = (e: MediaQueryListEvent) => {
      if (!localStorage.getItem("theme")) setTheme(e.matches ? "dark" : "light");
    };
    system.addEventListener("change", follow);
    return () => system.removeEventListener("change", follow);
  }, []);
  const toggle = () => {
    const next = theme === "dark" ? "light" : "dark";
    localStorage.setItem("theme", next);
    setTheme(next);
  };
  return [theme, toggle];
}
