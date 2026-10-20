// Tours: short guided walks. The tour list is its own page; a running tour
// drives the other views and shows a bar with the step's text.
import type { Ctx, View } from "./ui";
import { esc, prose, type Tour } from "./data";

export function tourList(ctx: Ctx, el: HTMLElement, start: (t: Tour, i: number) => void): View {
  const tours = ctx.model.atlas.tours;
  el.innerHTML = `<div class="tours">
    <section class="intro"><h1>Tours</h1><p>Short walks through how things actually work. Each step moves the map or the wiring and lights up the parts it is talking about.</p></section>
    <div class="tour-grid">${tours
      .map(
        (t, i) => `<button class="tour-card" data-i="${i}">
          <span class="n">${t.step.length} steps</span>
          <h2>${esc(t.title)}</h2>
          <p>${prose(t.summary ?? "")}</p>
          <ol>${t.step.map((s) => `<li>${esc(s.title)}</li>`).join("")}</ol>
          <span class="go">Start →</span>
        </button>`,
      )
      .join("")}${tours.length ? "" : `<p class="note">No tours in this scan.</p>`}</div>
  </div>`;
  el.querySelectorAll<HTMLElement>(".tour-card").forEach((b) =>
    b.addEventListener("click", () => start(tours[+b.dataset.i!], 0)),
  );
  return { focus() {} };
}

/** The bar at the bottom while a tour runs. */
export function tourBar(t: Tour, i: number, go: (i: number) => void, stop: () => void) {
  const bar = document.getElementById("tourbar")!;
  const s = t.step[i];
  bar.innerHTML = `<div class="inner">
    <div class="head"><span class="which">${esc(t.title)} · ${i + 1} of ${t.step.length}</span><button class="x" aria-label="End tour">×</button></div>
    <h3>${esc(s.title)}</h3>
    <p>${prose(s.text.trim())}</p>
    <div class="nav">
      <div class="dots">${t.step.map((_, k) => `<button class="${k === i ? "on" : ""}" data-k="${k}" aria-label="Step ${k + 1}"></button>`).join("")}</div>
      <button class="btn ghost" data-k="${i - 1}" ${i === 0 ? "disabled" : ""}>Back</button>
      <button class="btn" data-k="${i + 1}">${i === t.step.length - 1 ? "Finish" : "Next"}</button>
    </div>
  </div>`;
  bar.hidden = false;
  bar.querySelector(".x")!.addEventListener("click", stop);
  bar.querySelectorAll<HTMLButtonElement>("[data-k]").forEach((b) =>
    b.addEventListener("click", () => {
      const k = +b.dataset.k!;
      if (k >= t.step.length) stop();
      else go(k);
    }),
  );
}
export const hideTourBar = () => {
  const bar = document.getElementById("tourbar")!;
  bar.hidden = true;
  bar.innerHTML = "";
};
