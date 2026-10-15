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
  document.querySelector<HTMLMetaElement>('meta[name="color-scheme"]')!.content = t;
  document.querySelector<HTMLMetaElement>('meta[name="apple-mobile-web-app-status-bar-style"]')!.content = t === "dark" ? "black" : "default";
  // Chrome takes the installed app's nav bar colour from the manifest at
  // install and ignores its dark variants, so install from the theme on
  // screen (src/site.rs manifest).
  document.querySelector<HTMLLinkElement>('link[rel="manifest"]')!.href =
    t === "dark" ? "/manifest.webmanifest?theme=dark" : "/manifest.webmanifest";
}

/** Light or dark: the phone's, unless the person picks the other one. Picking
    the phone's own theme drops the override, so the app follows the phone
    again. The installed app's nav bar keeps the theme it was installed in.
    index.html sets the first value before paint. */
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
