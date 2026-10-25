// Code highlighting, math and diagrams, loaded the first time an answer
// needs them: they are most of the page's weight, and few answers do.
import "katex/dist/katex.min.css";
import { renderAsync } from "pele/lazy";
import type { DiagramPlugin } from "streamdown";
export { code } from "@streamdown/code";
export { math } from "@streamdown/math";

// Pele draws ```mermaid blocks in place of mermaid.js: a tenth the size,
// synchronous, and themed by CSS variables (index.css) rather than
// re-rendered per theme. Streamdown's mermaid controls (fullscreen,
// download) work on its SVG as they would on mermaid's.
export const mermaid: DiagramPlugin = {
  name: "mermaid",
  type: "diagram",
  language: "mermaid",
  getMermaid: () => ({
    initialize() {},
    render: async (id, source) => ({
      // An agent writes the diagram, so it carries no links or images.
      svg: (await renderAsync(source, { idPrefix: id, responsive: true, autoDirection: true, links: false, images: false })).svg,
    }),
  }),
};
