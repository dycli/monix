import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./index.css";
import { App, useWide } from "./App";
import { PANE, Split, useSplit } from "./split";

// The split is for wide screens; a narrow window shows the one assistant
// the cookie routes to, and goes back to the split when it widens.
function Root() {
  const split = useSplit();
  const wide = useWide();
  return split && wide && !PANE ? <Split layout={split} /> : <App />;
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Root />
  </StrictMode>,
);
