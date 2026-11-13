// The homepage's client. The clock, search, monitor and server-stats
// widgets are ports of Glance's page.js and templates (AGPL-3.0) to
// client-side rendering against this server's /api/home, /api/board and
// /api/usage. Glance gives each page its own address; here the three tabs
// are one document, switched by the URL's hash.

import { setupPopovers } from "./popover.js";

const STATUS_EVERY = 30_000;
const BOARD_EVERY = 300_000;
// The server keeps a usage report five minutes; asking sooner gets the same.
const USAGE_EVERY = 300_000;

const $ = (id) => document.getElementById(id);

// Builds markup with every interpolated value escaped, except fragments
// wrapped in raw().
const esc = (v) =>
  String(v ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
class Raw {
  constructor(s) { this.s = s; }
}
const raw = (s) => new Raw(s);
function html(parts, ...values) {
  return parts.reduce(
    (out, p, i) => out + p + (i < values.length ? (values[i] instanceof Raw ? values[i].s : esc(values[i])) : ""),
    "",
  );
}

// --- Clock (Glance setupClocks, local time, 12h) ---

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

function tick() {
  const now = new Date();
  const h = now.getHours();
  const m = now.getMinutes();
  $("time").textContent = `${h % 12 || 12}:${m < 10 ? "0" + m : m} ${h < 12 ? "AM" : "PM"}`;
  $("date").textContent = `${now.getDate()} ${MONTHS[now.getMonth()]}`;
  $("weekday").textContent = WEEKDAYS[now.getDay()];
  $("year").textContent = now.getFullYear();
  setTimeout(tick, (60 - now.getSeconds()) * 1000);
}

// --- Search (Glance setupSearchBoxes) ---
// Bangs as Glance has them, plus the services by name: "son" + Enter opens
// Sonarr.

const ENGINE = "https://search.brave.com/search?q=!QUERY!";
const BANGS = [
  { shortcut: "!yt", title: "YouTube", url: "https://www.youtube.com/results?search_query=!QUERY!" },
  { shortcut: "!gh", title: "GitHub", url: "https://github.com/search?q=!QUERY!&type=repositories" },
  { shortcut: "!nix", title: "NixOS packages", url: "https://search.nixos.org/packages?channel=unstable&query=!QUERY!" },
  { shortcut: "!w", title: "Wikipedia", url: "https://en.wikipedia.org/w/index.php?search=!QUERY!" },
  { shortcut: "!m", title: "Maps", url: "https://www.google.com/maps/search/!QUERY!" },
];
let services = [];

function setupSearch() {
  const input = document.querySelector(".search-input");
  const bangElement = document.querySelector(".search-bang");
  const kbd = document.querySelector(".search kbd");
  const bangs = Object.fromEntries(BANGS.map((b) => [b.shortcut, b]));
  let current = null;
  let lastQuery = "";

  // A service whose name starts with what was typed, if only one does.
  const service = (text) => {
    const t = text.toLowerCase();
    if (t.length < 2) return null;
    const hits = services.filter((s) => s.name.toLowerCase().startsWith(t));
    return hits.length === 1 ? hits[0] : null;
  };

  const show = (title) => (bangElement.textContent = title ?? "");

  input.addEventListener("input", () => {
    const value = input.value.trim();
    const words = value.split(" ");
    if (value in bangs) current = bangs[value];
    else if (words.length >= 2 && words[0] in bangs) current = bangs[words[0]];
    else current = null;
    const s = current ? null : service(value);
    show(current ? current.title : s ? `→ ${s.name}` : null);
  });

  input.addEventListener("keydown", (event) => {
    if (event.key === "Escape") return input.blur();
    if (event.key === "ArrowUp" && lastQuery) return void (input.value = lastQuery);
    if (event.key !== "Enter") return;
    const text = input.value.trim();
    const s = current ? null : service(text);
    let url;
    if (s) url = s.url;
    else {
      const query = current ? text.slice(current.shortcut.length + 1) : text;
      if (!query && !current) return;
      url = (current ? current.url : ENGINE).replace("!QUERY!", encodeURIComponent(query));
      lastQuery = query;
    }
    if (event.ctrlKey || event.metaKey) window.open(url, "_blank");
    else location.href = url;
    input.value = "";
    current = null;
    show(null);
  });

  document.addEventListener("keydown", (event) => {
    if (["INPUT", "TEXTAREA"].includes(document.activeElement.tagName)) return;
    if (event.code !== "KeyS") return;
    input.focus();
    event.preventDefault();
  });
  kbd.addEventListener("mousedown", () => requestAnimationFrame(() => input.focus()));
}

// --- Services (Glance monitor widget) ---

const OK_ICON = `<svg fill="var(--color-positive)" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm3.857-9.809a.75.75 0 0 0-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 1 0-1.06 1.061l2.5 2.5a.75.75 0 0 0 1.137-.089l4-5.5Z" clip-rule="evenodd" /></svg>`;
const BAD_ICON = `<svg fill="var(--color-negative)" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495ZM10 5a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 10 5Zm0 9a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z" clip-rule="evenodd" /></svg>`;

// Icons from the dashboard-icons set, as Glance's `di:` prefix loads them.
const iconURL = (name) => `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/${name}.svg`;

function renderServices(box, list) {
  const items = list.map((s) => {
    const st = s.state ?? {};
    const status = st.up
      ? html`<li title="${st.code}">${s.about}</li><li>${st.ms}ms</li>`
      : html`<li class="color-negative" title="${st.error ?? st.code ?? ""}">${st.error ? "Down" : "Error " + st.code}</li>`;
    return html`<li class="monitor-site flex items-center gap-15">
      ${raw(
        s.icon
          ? html`<img class="monitor-site-icon" src="${iconURL(s.icon)}" alt="" loading="lazy">`
          : html`<div class="monitor-site-icon monogram" aria-hidden="true">${s.name[0]}</div>`,
      )}
      <div class="grow min-width-0">
        ${raw(s.url ? html`<a class="size-h3 color-highlight text-truncate block" href="${s.url}" rel="noreferrer">${s.name}</a>` : html`<div class="size-h3 color-highlight text-truncate">${s.name}</div>`)}
        <ul class="list-horizontal-text">${raw(status)}</ul>
      </div>
      <div class="monitor-site-status-icon">${raw(st.up ? OK_ICON : BAD_ICON)}</div>
    </li>`;
  });
  box.querySelector(".widget-content").innerHTML =
    `<ul class="dynamic-columns list-gap-20 list-with-separator">${items.join("")}</ul>`;
  showImages(box);
}

// Glance's setupLazyImages: its CSS hides a lazy image until it is marked
// loaded, and an image already in the cache shows without the fade.
function showImages(root) {
  for (const img of root.querySelectorAll('img[loading="lazy"]')) {
    if (img.complete && img.naturalWidth) img.classList.add("cached");
    else img.addEventListener("load", () => img.classList.add("loaded"), { once: true });
  }
}

// --- Server (Glance server-stats widget) ---

function size(mb) {
  if (mb >= 1024 * 1024) return [(mb / 1024 / 1024).toFixed(1), "TB"];
  if (mb >= 1024) return [(mb / 1024).toFixed(1), "GB"];
  return [mb, "MB"];
}
const pct = (used, total) => (total ? Math.round((used / total) * 100) : 0);
const notice = (p) => (p >= 85 ? " progress-value-notice" : "");
const pair = (label, used, total) => {
  const [u, uu] = size(used);
  const [t, tu] = size(total);
  return html`<div class="flex margin-top-3"><div class="size-h5">${label}</div><div class="value-separator"></div>
    <div class="color-highlight text-very-compact">${u} <span class="color-base size-h5">${uu} /</span> ${t} <span class="color-base size-h5">${tu}</span></div></div>`;
};
function uptime(secs) {
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  return d ? `${d}d ${h}h` : `${h}h ${Math.floor((secs % 3600) / 60)}m`;
}

const SERVER_ICON = `<svg class="server-icon" stroke="var(--color-positive)" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5"><path stroke-linecap="round" stroke-linejoin="round" d="M21.75 17.25v-.228a4.5 4.5 0 0 0-.12-1.03l-2.268-9.64a3.375 3.375 0 0 0-3.285-2.602H7.923a3.375 3.375 0 0 0-3.285 2.602l-2.268 9.64a4.5 4.5 0 0 0-.12 1.03v.228m19.5 0a3 3 0 0 1-3 3H5.25a3 3 0 0 1-3-3m19.5 0a3 3 0 0 0-3-3H5.25a3 3 0 0 0-3 3m16.5 0h.008v.008h-.008v-.008Zm-3 0h.008v.008h-.008v-.008Z" /></svg>`;

function renderServer(box, s) {
  if (!s) return void (box.hidden = true);
  box.hidden = false;
  const mem = pct(s.mem_used, s.mem_total);
  const swap = pct(s.swap_used, s.swap_total);
  const disks = s.disks.map((d) => ({ ...d, p: pct(d.used, d.total) }));
  const hot = s.temp != null && s.temp >= 80;
  box.querySelector(".widget-content").innerHTML = html`<div class="server">
    <div class="server-info">
      <div class="server-details">
        <div class="server-name color-highlight size-h3">${s.host}</div>
        <div>${uptime(s.uptime)} uptime</div>
      </div>
      <div class="shrink-0">${raw(SERVER_ICON)}</div>
    </div>
    <div class="server-stats">
      <div class="flex-1">
        <div class="flex items-end size-h5"><div>CPU</div>${raw(hot ? '<span class="color-negative" style="margin-left:.4em">●</span>' : "")}
          <div class="color-highlight margin-left-auto text-very-compact">${s.load1} <span class="color-base">%</span></div></div>
        <div data-popover-type="html">
          <div data-popover-html>
            <div class="flex"><div class="size-h5">1M AVG</div><div class="value-separator"></div><div class="color-highlight text-very-compact">${s.load1} <span class="color-base size-h5">%</span></div></div>
            <div class="flex margin-top-3"><div class="size-h5">15M AVG</div><div class="value-separator"></div><div class="color-highlight text-very-compact">${s.load15} <span class="color-base size-h5">%</span></div></div>
            ${raw(s.temp != null ? html`<div class="flex margin-top-3"><div class="size-h5">TEMP C</div><div class="value-separator"></div><div class="color-highlight text-very-compact">${s.temp} <span class="color-base size-h5">°</span></div></div>` : "")}
          </div>
          <div class="progress-bar progress-bar-combined">
            <div class="progress-value${notice(s.load1)}" style="--percent: ${s.load1}"></div>
            <div class="progress-value${notice(s.load15)}" style="--percent: ${s.load15}"></div>
          </div>
        </div>
      </div>
      <div class="flex-1">
        <div class="flex justify-between items-end size-h5"><div>RAM</div>
          <div class="color-highlight text-very-compact">${mem} <span class="color-base">%</span></div></div>
        <div data-popover-type="html">
          <div data-popover-html>${raw(pair("RAM", s.mem_used, s.mem_total))}${raw(s.swap_total ? pair("SWAP", s.swap_used, s.swap_total) : "")}</div>
          <div class="progress-bar progress-bar-combined">
            <div class="progress-value${notice(mem)}" style="--percent: ${mem}"></div>
            ${raw(s.swap_total ? html`<div class="progress-value${notice(swap)}" style="--percent: ${swap}"></div>` : "")}
          </div>
        </div>
      </div>
      <div class="flex-1">
        <div class="flex justify-between items-end size-h5"><div>DISK</div>
          <div class="color-highlight text-very-compact">${disks[0]?.p ?? "n/a"} <span class="color-base">%</span></div></div>
        <div data-popover-type="html">
          <div data-popover-html>${raw(disks.map((d) => pair(d.name.toUpperCase(), d.used, d.total)).join(""))}</div>
          <div class="progress-bar progress-bar-combined">
            ${raw(disks.slice(0, 2).map((d) => html`<div class="progress-value${notice(d.p)}" style="--percent: ${d.p}"></div>`).join(""))}
          </div>
        </div>
      </div>
    </div>
  </div>`;
  setupPopovers();
}

// Every disk with its own bar, for Monitoring.
function renderDisks(s) {
  const box = $("disks");
  if (!s?.disks.length) return void (box.hidden = true);
  box.hidden = false;
  box.querySelector(".widget-content").innerHTML = `<ul class="list list-gap-14">${s.disks
    .map((d) => {
      const p = pct(d.used, d.total);
      return html`<li>${raw(pair(d.name.toUpperCase(), d.used, d.total))}
        <div class="progress-bar margin-top-5"><div class="progress-value${notice(p)}" style="--percent: ${p}"></div></div></li>`;
    })
    .join("")}</ul>`;
}

// --- Subscriptions (the usage service's report, as Glance-style bars) ---

const ACCOUNTS = { claude: "Claude", codex: "ChatGPT / Codex", go: "OpenCode Go" };

function renderUsage(u) {
  const content = $("usage").querySelector(".widget-content");
  if (!u) {
    content.innerHTML = `<p class="color-subdue">The usage service didn't answer.</p>`;
    return;
  }
  const accounts = new Map();
  const account = (name) => {
    if (!accounts.has(name)) accounts.set(name, []);
    return accounts.get(name);
  };
  for (const w of u.windows) {
    const shares = w.shares.filter(([, p]) => p > 0).map(([who, p]) => `${who} ${p}%`);
    account(w.account).push(html`<li>
      <div class="flex justify-between items-end size-h5"><div class="uppercase">${w.window}</div>
        <div class="color-highlight text-very-compact">${w.pct} <span class="color-base">%</span></div></div>
      <div class="progress-bar margin-top-5"><div class="progress-value${notice(w.pct)}" style="--percent: ${w.pct}"></div></div>
      <ul class="list-horizontal-text size-h6 margin-top-5">
        <li>resets ${w.resets}</li>
        ${raw(shares.length ? html`<li>${shares.join(" · ")}</li>` : "")}
        ${raw(w.cost ? html`<li>${w.cost} at API prices</li>` : "")}
      </ul></li>`);
  }
  for (const [name, kind] of u.unknown) {
    account(name).push(html`<li class="color-negative" title="${kind}">Couldn't read its use (${kind})</li>`);
  }
  content.innerHTML = [...accounts]
    .map(([name, rows]) => html`<div class="usage-account"><div class="size-h3 color-highlight">${ACCOUNTS[name] ?? name}</div>
      <ul class="list list-gap-14 margin-top-10">${raw(rows.join(""))}</ul></div>`)
    .join("");
}

// --- Weather (after Glance's widget, by day: the forecast has no hours) ---

const WEATHER = {
  0: "Clear Sky", 1: "Mainly Clear", 2: "Partly Cloudy", 3: "Overcast", 45: "Fog", 48: "Rime Fog",
  51: "Drizzle", 53: "Drizzle", 55: "Drizzle", 56: "Drizzle", 57: "Drizzle", 61: "Rain",
  63: "Moderate Rain", 65: "Heavy Rain", 66: "Freezing Rain", 67: "Freezing Rain", 71: "Snow",
  73: "Moderate Snow", 75: "Heavy Snow", 77: "Snow Grains", 80: "Rain", 81: "Moderate Rain",
  82: "Heavy Rain", 85: "Snow", 86: "Snow", 95: "Thunderstorm", 96: "Thunderstorm", 99: "Thunderstorm",
};
const DAY = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function renderWeather(w) {
  const box = $("weather");
  if (!w) return void (box.hidden = true);
  box.hidden = false;
  const highs = w.days.map((d) => d.high);
  const lo = Math.min(...highs);
  const span = Math.max(...highs) - lo || 1;
  const columns = w.days.map((d, i) => {
    const day = DAY[new Date(d.date + "T12:00").getDay()];
    return html`<div class="weather-column${i === 0 ? " weather-column-current" : ""}" title="${WEATHER[d.code] ?? ""}, low ${Math.round(d.low)}°${d.rain ? `, ${d.rain}% rain` : ""}">
      ${raw((d.rain ?? 0) >= 40 ? '<div class="weather-column-rain"></div>' : "")}
      <div class="weather-column-value">${Math.round(d.high)}</div>
      <div class="weather-bar" style="--weather-bar-height: ${((d.high - lo) / span).toFixed(2)}"></div>
      <div class="weather-column-time">${i === 0 ? "Today" : day}</div>
    </div>`;
  });
  box.querySelector(".widget-content").innerHTML = html`<div class="widget-small-content-bounds">
    <div class="size-h2 color-highlight text-center">${WEATHER[w.now.code] ?? ""}, ${Math.round(w.now.temp)}°F</div>
    <div class="size-h4 text-center">Feels like ${Math.round(w.now.feels)}°F</div>
    <div class="weather-columns weather-days flex margin-top-15 justify-center">${raw(columns.join(""))}</div>
  </div>`;
}

// --- Air (the AirGradient, in Glance's key/value style) ---

function renderAir(box, a, every) {
  if (!a) return void (box.hidden = true);
  box.hidden = false;
  const row = (label, value, unit, bad) => html`<li class="flex items-center">
    <div class="size-h5">${label}</div><div class="value-separator"></div>
    <div class="${bad ? "color-negative" : "color-highlight"} text-very-compact">${value} <span class="color-base size-h5">${unit}</span></div></li>`;
  const rows = [
    row("CO₂", Math.round(a.co2), "ppm", a.co2 >= 1000),
    row("TEMP", Math.round(a.temp), "°F", false),
    row("HUMIDITY", Math.round(a.humidity), "%", a.humidity >= 65),
    row("PM2.5", Math.round(a.pm25), "µg/m³", a.pm25 >= 35),
  ];
  if (every) {
    rows.push(
      row("PM1", Math.round(a.pm1), "µg/m³", false),
      row("PM10", Math.round(a.pm10), "µg/m³", a.pm10 >= 150),
      // AirGradient's indices: 100 is the room's usual, higher is worse.
      row("VOC", Math.round(a.voc), "index", a.voc >= 250),
      row("NOx", Math.round(a.nox), "index", a.nox >= 20),
    );
  }
  box.querySelector(".widget-content").innerHTML = `<ul class="list list-gap-10">${rows.join("")}</ul>`;
}

// --- Weather tab: now, by the hour (Glance's columns), and the week ---

const COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
const hour = (iso) => new Date(iso).getHours();
const hourLabel = (h) => `${h % 12 || 12}${h < 12 ? "am" : "pm"}`;
const clockOf = (iso) => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

function renderNow(w) {
  const n = w.now;
  const today = w.days[0];
  const row = (label, value, unit) => html`<li class="flex items-center">
    <div class="size-h5">${label}</div><div class="value-separator"></div>
    <div class="color-highlight text-very-compact">${value} <span class="color-base size-h5">${unit}</span></div></li>`;
  $("now").querySelector(".widget-content").innerHTML = html`
    <div class="size-h2 color-highlight">${WEATHER[n.code] ?? ""}, ${Math.round(n.temp)}°F</div>
    <div class="size-h4">Feels like ${Math.round(n.feels)}°F</div>
    <ul class="list list-gap-10 margin-top-15">${raw([
      row("WIND", `${COMPASS[Math.round(n.from / 45) % 8]} ${Math.round(n.wind)}`, "mph"),
      row("GUSTS", Math.round(n.gust), "mph"),
      row("HUMIDITY", Math.round(n.humidity), "%"),
      row("DEW POINT", Math.round(n.dew), "°F"),
      row("UV", Math.round(today.uv), "max"),
      row("SUNRISE", clockOf(today.sunrise), ""),
      row("SUNSET", clockOf(today.sunset), ""),
    ].join(""))}</ul>`;
}

function renderHours(w) {
  const hours = w.hours.slice(0, 24);
  const temps = hours.map((h) => h.temp);
  const lo = Math.min(...temps);
  const span = Math.max(...temps) - lo || 1;
  const columns = hours.map((h, i) => {
    const light = !h.day ? "" : !hours[i - 1]?.day ? " weather-column-daylight-sunrise" : !hours[i + 1]?.day ? " weather-column-daylight-sunset" : "";
    return html`<div class="weather-column${i === 0 ? " weather-column-current" : ""}" title="${WEATHER[h.code] ?? ""}${h.rain ? `, ${h.rain}% rain` : ""}">
      ${raw(h.rain >= 40 ? '<div class="weather-column-rain"></div>' : "")}
      ${raw(h.day ? `<div class="weather-column-daylight${light}"></div>` : "")}
      <div class="weather-column-value">${Math.round(h.temp)}</div>
      <div class="weather-bar" style="--weather-bar-height: ${((h.temp - lo) / span).toFixed(2)}"></div>
      <div class="weather-column-time">${i === 0 ? "Now" : hourLabel(hour(h.time))}</div>
    </div>`;
  });
  $("hours").querySelector(".widget-content").innerHTML =
    `<div class="weather-columns flex hide-scrollbars">${columns.join("")}</div>`;
}

function renderDays(w) {
  const lo = Math.min(...w.days.map((d) => d.low));
  const span = Math.max(...w.days.map((d) => d.high)) - lo || 1;
  const rows = w.days.map((d, i) => {
    const day = i === 0 ? "Today" : DAY[new Date(d.date + "T12:00").getDay()];
    return html`<li class="day-row flex items-center gap-15">
      <div class="day-name color-highlight">${day}</div>
      <div class="grow min-width-0 text-truncate">${WEATHER[d.code] ?? ""}</div>
      <div class="day-rain size-h6 color-subdue text-right">${d.rain ? `${d.rain}%` : ""}</div>
      <div class="day-temp text-right color-subdue">${Math.round(d.low)}°</div>
      <div class="day-range"><div style="left: ${((d.low - lo) / span) * 100}%; right: ${100 - ((d.high - lo) / span) * 100}%"></div></div>
      <div class="day-temp color-highlight">${Math.round(d.high)}°</div>
    </li>`;
  });
  $("days").querySelector(".widget-content").innerHTML =
    `<ul class="list list-gap-14 list-with-separator">${rows.join("")}</ul>`;
}

// --- Calendar (the frame's events, as a Glance list) ---

// An all-day event's start is a date; a timed one's "2026-10-21 16:00".
function parseEvent(e) {
  const allDay = e.start.length === 10;
  const when = new Date(allDay ? e.start + "T00:00" : e.start.replace(" ", "T"));
  const time = allDay ? "All day" : when.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  return { ...e, when, time };
}

const dayLabel = (d) => {
  const key = d.toDateString();
  if (key === new Date().toDateString()) return "Today";
  if (key === new Date(Date.now() + 86400000).toDateString()) return "Tomorrow";
  return `${WEEKDAYS[d.getDay()]} ${d.getDate()} ${MONTHS[d.getMonth()].slice(0, 3)}`;
};

const eventItem = (e) => html`<li class="flex gap-15"><div class="event-time color-subdue shrink-0">${e.time}</div>
  <div class="min-width-0"><div class="color-highlight text-truncate">${e.summary}</div>${raw(e.location ? html`<div class="size-h6 text-truncate">${e.location}</div>` : "")}</div></li>`;

function renderEvents(events) {
  const box = $("events");
  if (!events) return void (box.hidden = true);
  box.hidden = false;
  if (!events.length) {
    box.querySelector(".widget-content").innerHTML = `<p class="color-subdue">Nothing in the next week.</p>`;
    return;
  }
  const groups = new Map();
  for (const e of events.map(parseEvent)) {
    const key = e.when.toDateString();
    if (!groups.has(key)) groups.set(key, { label: dayLabel(e.when), items: [] });
    groups.get(key).items.push(eventItem(e));
  }
  box.querySelector(".widget-content").innerHTML = [...groups.values()]
    .map((g) => `<div class="event-day"><div class="size-h5 uppercase color-subdue">${esc(g.label)}</div><ul class="list list-gap-10 margin-top-5">${g.items.join("")}</ul></div>`)
    .join("");
}

// The Calendar tab's week: a column a day from today, every day shown.
function renderWeek(events) {
  const list = (events ?? []).map(parseEvent);
  const start = new Date();
  start.setHours(0, 0, 0, 0);
  const days = Array.from({ length: 7 }, (_, i) => new Date(start.getFullYear(), start.getMonth(), start.getDate() + i));
  $("week").querySelector(".widget-content").innerHTML = `<div class="week-grid">${days
    .map((d) => {
      const mine = list.filter((e) => e.when.toDateString() === d.toDateString());
      return html`<div class="week-day${d.getTime() === start.getTime() ? " week-today" : ""}">
        <div class="size-h5 uppercase color-subdue">${dayLabel(d)}</div>
        ${raw(mine.length
          ? html`<ul class="list list-gap-10 margin-top-5">${raw(mine.map((e) => html`<li><div class="size-h6 color-subdue">${e.time}</div>
              <div class="color-highlight">${e.summary}</div>${raw(e.location ? html`<div class="size-h6">${e.location}</div>` : "")}</li>`).join(""))}</ul>`
          : '<div class="size-h6 color-subdue margin-top-5">Nothing</div>')}
      </div>`;
    })
    .join("")}</div>`;
}

// Glance's calendar widget: this month, Monday first, today marked, and a
// dot on the days the week's events fall.
function renderMonth(events) {
  const now = new Date();
  const busy = new Set((events ?? []).map((e) => parseEvent(e).when.toDateString()));
  $("month-name").textContent = `${MONTHS[now.getMonth()]} ${now.getFullYear()}`;
  const first = new Date(now.getFullYear(), now.getMonth(), 1);
  const lead = (first.getDay() + 6) % 7;
  const cells = Array.from({ length: 42 }, (_, i) => new Date(now.getFullYear(), now.getMonth(), 1 - lead + i));
  const weeks = cells[35].getMonth() === now.getMonth() ? cells : cells.slice(0, 35);
  $("month").querySelector(".widget-content").innerHTML = `<div class="calendar-dates">${["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    .map((d) => `<div class="calendar-date color-subdue size-h6">${d}</div>`)
    .join("")}${weeks
    .map((d) => {
      const cls = [
        "calendar-date",
        d.toDateString() === now.toDateString() ? "calendar-current-date" : "",
        d.getMonth() !== now.getMonth() ? "calendar-spillover-date" : "",
        busy.has(d.toDateString()) ? "calendar-busy-date" : "",
      ].filter(Boolean).join(" ");
      return `<div class="${cls}">${d.getDate()}</div>`;
    })
    .join("")}</div>`;
}

// --- Polling ---

async function getJSON(url) {
  const r = await fetch(url, { cache: "no-store" });
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return r.json();
}

async function status() {
  try {
    const s = await getJSON("/api/home");
    services = s.services.filter((x) => x.url);
    renderServices($("services"), services);
    renderServices($("agents"), s.services.filter((x) => x.agent));
    renderServices($("monitor"), s.services);
    renderServer($("server"), s.server);
    renderServer($("server2"), s.server);
    renderDisks(s.server);
  } catch (e) {
    console.warn(e);
  }
  setTimeout(status, STATUS_EVERY);
}

async function board() {
  try {
    const b = await getJSON("/api/board");
    renderWeather(b.weather);
    renderAir($("air"), b.air, false);
    renderAir($("air2"), b.air, true);
    renderEvents(b.events);
    renderWeek(b.events);
    renderMonth(b.events);
    if (b.weather) {
      renderNow(b.weather);
      renderHours(b.weather);
      renderDays(b.weather);
    }
  } catch (e) {
    console.warn(e);
  }
  setTimeout(board, BOARD_EVERY);
}

let usageTimer = null;
async function usage() {
  clearTimeout(usageTimer);
  try {
    renderUsage(await getJSON("/api/usage"));
  } catch (e) {
    console.warn(e);
  }
  usageTimer = setTimeout(usage, USAGE_EVERY);
}

// --- Tabs ---
// Each tab is a page of columns. On a phone, as in Glance, a pill per
// column picks the one shown, starting on the widest.

function showTab() {
  const tab = location.hash.slice(1) || "home";
  const page = document.querySelector(`.page-columns[data-tab="${tab}"]`) ?? document.querySelector(".page-columns");
  const name = page.dataset.tab;
  for (const p of document.querySelectorAll(".page-columns")) p.hidden = p !== page;
  for (const a of document.querySelectorAll(".nav-item")) {
    const current = a.dataset.tab === name;
    a.classList.toggle("nav-item-current", current);
    if (current) a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  }
  const columns = [...page.children];
  const primary = Math.max(0, columns.findIndex((c) => c.classList.contains("page-column-full")));
  // A lone column gets no pills, but is still the one chosen, so the
  // phone's CSS shows it.
  $("pills").innerHTML = columns.length < 2
    ? `<input type="radio" class="mobile-navigation-input" name="column" value="0" checked hidden>`
    : columns
        .map((_, i) => `<label class="mobile-navigation-label"><input type="radio" class="mobile-navigation-input" name="column" value="${i}" autocomplete="off"${i === primary ? " checked" : ""}><div class="mobile-navigation-pill"></div></label>`)
        .join("");
  document.querySelector(".mobile-navigation-page-links-input").checked = false;
  document.title = name === "home" ? "Home" : `${name[0].toUpperCase()}${name.slice(1)} · Home`;
  if (name === "agents" && usageTimer === null) usage();
}

window.addEventListener("hashchange", showTab);
showTab();
tick();
setupSearch();
status();
board();
