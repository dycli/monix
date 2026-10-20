// The glossary behind the ? button: what each view shows and the words used.
import type { Atlas } from "./data";

export const help = (a: Atlas) => `<div class="help">
  <button class="close" aria-label="Close">×</button>
  <h2>How to read the atlas</h2>
  <p class="lede">The atlas reads every repository in the git mirror on Water once an hour and draws it. Nothing here is written by hand except the tours.</p>
  <div class="cols">
    <section>
      <h3>The views</h3>
      <dl>
        <dt>Overview</dt><dd>Headline numbers, every repository as a bar split by language, and the files that change most.</dd>
        <dt>Map</dt><dd>Circles inside circles: a repository holds its folders, a folder holds its files. Area is lines of code, so a circle twice the size holds twice the code. Click to zoom in, click outside to zoom out. Pick a file to see what it uses (solid arcs) and what uses it (dashed).</dd>
        <dt>Wiring</dt><dd>The ${a.system.modules.length} modules of monix and how they lean on each other. Modules of one area sit together. Hover one to see only its links.</dd>
        <dt>Machines</dt><dd>What each of the ${a.system.hosts.length} computers runs, one block per module.</dd>
        <dt>Tours</dt><dd>Guided walks through how a message, a deploy, a web request and the memory work.</dd>
      </dl>
    </section>
    <section>
      <h3>Words</h3>
      <dl>
        <dt>Repository</dt><dd>One project under git, with its own history.</dd>
        <dt>monix</dt><dd>The repository that defines every machine: a Nix <em>flake</em>, a set of files that says exactly what software runs where.</dd>
        <dt>Module</dt><dd>One feature of monix, like the photo frame or the deploy tool, usually a <code>.mod.nix</code> file plus any program it builds.</dd>
        <dt>Area</dt><dd>The group a module belongs to, from the folder it lives in: AI, homelab, desktop and so on.</dd>
        <dt>Machine (host)</dt><dd>A computer monix builds: water, earth, fire, air.</dd>
        <dt>Service</dt><dd>A program the machine keeps running (a systemd unit), or a job a timer starts.</dd>
        <dt>Web address</dt><dd>A <code>name.su.is</code> route that ship-proxy points at a service.</dd>
        <dt>Lines</dt><dd>Code, comments and config. Blank lines, lockfiles and data files are not counted.</dd>
      </dl>
    </section>
    <section>
      <h3>Links on the Wiring view</h3>
      <dl>
        <dt>uses</dt><dd>Calls a helper from <code>lib/</code>.</dd>
        <dt>configures</dt><dd>Sets an option another module defines.</dd>
        <dt>reads</dt><dd>Reads another module's settings (hidden by default; there are many).</dd>
        <dt>served by</dt><dd>Gets a web address from ship-proxy.</dd>
        <dt>starts after</dt><dd>One of its services waits for one of the other's.</dd>
      </dl>
      <h3>Keys</h3>
      <dl class="keys">
        <dt><kbd>⌘K</kbd> or <kbd>/</kbd></dt><dd>Search</dd>
        <dt><kbd>Esc</kbd></dt><dd>Close the panel or end a tour</dd>
        <dt><kbd>←</kbd> <kbd>→</kbd></dt><dd>Step through a tour</dd>
        <dt><kbd>?</kbd></dt><dd>This help</dd>
      </dl>
    </section>
  </div>
</div>`;
