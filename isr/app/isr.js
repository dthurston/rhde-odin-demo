// ISR Sensor Node: simulated wide-area GMTI sensor. Tracks are generated
// locally, painted when the sweep passes them, and forwarded once a second
// to the tablet hub, which re-serves them to ODIN as a Live Data Source.
(() => {
  const CFG = Object.assign({ version: "dev", accent: "#ee0000", hub: "", tiles: "" }, window.ISR_CONFIG || {});
  document.documentElement.style.setProperty("--accent", CFG.accent);
  document.getElementById("imgver").textContent = "isr:" + CFG.version;
  const logEl = document.getElementById("log");

  // AO: National Training Center, Fort Irwin CA
  const SENSOR = { lat: 35.262, lon: -116.684 };
  const RANGE_M = 15000;
  const SWEEP_PERIOD_MS = 10000; // 6 rpm
  const T0 = Date.now();

  const map = L.map("map", { zoomControl: false, attributionControl: false, minZoom: 6, maxZoom: 15 })
    .setView([SENSOR.lat, SENSOR.lon], 11);
  const fitCoverage = () => map.fitBounds(L.latLng(SENSOR.lat, SENSOR.lon).toBounds(RANGE_M * 2.15), { animate: false });
  fitCoverage();
  if (CFG.tiles) L.tileLayer(CFG.tiles, { maxZoom: 15, maxNativeZoom: 15 }).addTo(map);

  map.on("mousemove", e => {
    document.getElementById("coords").textContent =
      e.latlng.lat.toFixed(5) + "  " + e.latlng.lng.toFixed(5);
  });

  // ---- geometry helpers -------------------------------------------------
  const R_EARTH = 6371000;
  const rad = d => d * Math.PI / 180, deg = r => r * 180 / Math.PI;
  function move(lat, lon, bearingDeg, meters) {
    const d = meters / R_EARTH, b = rad(bearingDeg), p1 = rad(lat), l1 = rad(lon);
    const p2 = Math.asin(Math.sin(p1) * Math.cos(d) + Math.cos(p1) * Math.sin(d) * Math.cos(b));
    const l2 = l1 + Math.atan2(Math.sin(b) * Math.sin(d) * Math.cos(p1), Math.cos(d) - Math.sin(p1) * Math.sin(p2));
    return { lat: deg(p2), lon: deg(l2) };
  }
  function bearingTo(lat, lon) {
    const p1 = rad(SENSOR.lat), p2 = rad(lat), dl = rad(lon - SENSOR.lon);
    return (deg(Math.atan2(Math.sin(dl) * Math.cos(p2),
      Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl))) + 360) % 360;
  }
  function distTo(lat, lon) {
    const dp = rad(lat - SENSOR.lat), dl = rad(lon - SENSOR.lon);
    const a = Math.sin(dp / 2) ** 2 + Math.cos(rad(SENSOR.lat)) * Math.cos(rad(lat)) * Math.sin(dl / 2) ** 2;
    return 2 * R_EARTH * Math.asin(Math.sqrt(a));
  }

  // ---- simulated contacts -----------------------------------------------
  const TYPES = [
    { type: "ARMOR PLT",  affil: "H", sidc: "SHGPUCA--------", kmh: [18, 32] },
    { type: "MECH INF",   affil: "H", sidc: "SHGPUCIZ-------", kmh: [20, 35] },
    { type: "RECON VEH",  affil: "H", sidc: "SHGPUCR--------", kmh: [30, 55] },
    { type: "UAS",        affil: "H", sidc: "SHAPMFQ--------", kmh: [80, 120] },
    { type: "WHEELED",    affil: "U", sidc: "SUGPU----------", kmh: [25, 50] },
    { type: "ROTARY",     affil: "U", sidc: "SUAPMH---------", kmh: [110, 160] },
    { type: "CAV TROOP",  affil: "F", sidc: "SFGPUCR--------", kmh: [20, 40] },
  ];
  const COLORS = { H: "#ff3b3b", U: "#ffd23f", F: "#4fb3ff" };
  const AFFIL = { H: "HOSTILE", U: "UNKNOWN", F: "FRIEND" };
  let nextId = 1041;
  const tracks = [];

  function glyph(affil) {
    const c = COLORS[affil];
    if (affil === "H") return `<svg width="18" height="18" viewBox="-9 -9 18 18"><path d="M0-8 8 0 0 8-8 0Z" fill="${c}33" stroke="${c}" stroke-width="1.8"/></svg>`;
    if (affil === "U") return `<svg width="18" height="18" viewBox="-9 -9 18 18"><rect x="-7" y="-7" width="14" height="14" rx="6" fill="${c}33" stroke="${c}" stroke-width="1.8"/></svg>`;
    return `<svg width="20" height="14" viewBox="-10 -7 20 14"><rect x="-9" y="-6" width="18" height="12" fill="${c}33" stroke="${c}" stroke-width="1.8"/></svg>`;
  }

  // weighted toward hostiles so the picture is always interesting
  const MIX = [0, 1, 2, 3, 0, 1, 4, 5, 6];
  function spawn(initial) {
    const t = TYPES[initial ? MIX[tracks.length % MIX.length] : MIX[Math.floor(Math.random() * MIX.length)]];
    // hostiles enter from the east/north-east edge, others anywhere
    const brg = t.affil === "H" ? 20 + Math.random() * 110 : Math.random() * 360;
    const dist = initial ? 3000 + Math.random() * 10000 : RANGE_M * 0.95;
    const p = move(SENSOR.lat, SENSOR.lon, brg, dist);
    const tr = {
      id: "TK-" + (nextId++), ...t, lat: p.lat, lon: p.lon,
      hdg: (brg + 180 + (Math.random() * 80 - 40) + 360) % 360,
      speed: (t.kmh[0] + Math.random() * (t.kmh[1] - t.kmh[0])) / 3.6,
      seen: 0, trail: [],
    };
    tr.marker = L.marker([tr.lat, tr.lon], {
      icon: L.divIcon({ className: "trk", iconSize: [18, 18], iconAnchor: [9, 9],
        html: glyph(tr.affil) + `<div class="lbl">${tr.id}<small>${tr.type}</small></div>` }),
      interactive: false,
    }).addTo(map);
    tr.line = L.polyline([], { color: COLORS[tr.affil], weight: 1.5, opacity: .45, dashArray: "2 4" }).addTo(map);
    tracks.push(tr);
    log(`NEW CONTACT ${tr.id} ${AFFIL[tr.affil]} ${tr.type}`, tr.affil === "H");
    return tr;
  }
  for (let i = 0; i < 7; i++) spawn(true);

  function step(dt) {
    for (let i = tracks.length - 1; i >= 0; i--) {
      const tr = tracks[i];
      tr.hdg = (tr.hdg + (Math.random() - .5) * 6 * dt + 360) % 360;
      const p = move(tr.lat, tr.lon, tr.hdg, tr.speed * dt * 6); // 6x time compression keeps it lively
      tr.lat = p.lat; tr.lon = p.lon;
      if (distTo(tr.lat, tr.lon) > RANGE_M) {
        log(`LOST ${tr.id} — LEFT COVERAGE`);
        map.removeLayer(tr.marker); map.removeLayer(tr.line);
        tracks.splice(i, 1);
      }
    }
    while (tracks.length < 7) spawn(false);
  }

  // ---- sweep -------------------------------------------------------------
  const cv = document.getElementById("sweep"), ctx = cv.getContext("2d");
  function resize() {
    const r = cv.parentElement.getBoundingClientRect();
    cv.width = r.width * devicePixelRatio; cv.height = r.height * devicePixelRatio;
    cv.style.width = r.width + "px"; cv.style.height = r.height + "px";
  }
  window.addEventListener("resize", () => { resize(); map.invalidateSize(); fitCoverage(); }); resize();

  function hexA(hex, a) {
    const n = parseInt(hex.slice(1), 16);
    return `rgba(${n >> 16 & 255},${n >> 8 & 255},${n & 255},${a})`;
  }

  function drawSweep(now) {
    const dpr = devicePixelRatio;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, cv.width, cv.height);
    const c = map.latLngToContainerPoint([SENSOR.lat, SENSOR.lon]);
    const edge = move(SENSOR.lat, SENSOR.lon, 90, RANGE_M);
    const rPx = map.latLngToContainerPoint([edge.lat, edge.lon]).x - c.x;

    // range rings + spokes
    ctx.strokeStyle = "rgba(160,190,175,.22)"; ctx.lineWidth = 1;
    ctx.font = "11px 'Red Hat Mono', monospace"; ctx.fillStyle = "rgba(160,190,175,.55)";
    for (let k = 1; k <= 3; k++) {
      ctx.beginPath(); ctx.arc(c.x, c.y, rPx * k / 3, 0, Math.PI * 2); ctx.stroke();
      ctx.fillText((5 * k) + " KM", c.x + 4, c.y - rPx * k / 3 - 4);
    }
    for (let a = 0; a < 360; a += 30) {
      ctx.beginPath(); ctx.moveTo(c.x, c.y);
      ctx.lineTo(c.x + rPx * Math.sin(rad(a)), c.y - rPx * Math.cos(rad(a))); ctx.stroke();
    }

    // sweep wedge (bearing 0 = north, clockwise)
    const ang = ((now - T0) % SWEEP_PERIOD_MS) / SWEEP_PERIOD_MS * 360;
    const a1 = rad(ang - 90);
    const steps = 30;
    for (let s = 0; s < steps; s++) {
      const from = a1 - rad(40) * (s + 1) / steps, to = a1 - rad(40) * s / steps;
      ctx.beginPath(); ctx.moveTo(c.x, c.y); ctx.arc(c.x, c.y, rPx, from, to); ctx.closePath();
      ctx.fillStyle = hexA(CFG.accent, .22 * (1 - s / steps)); ctx.fill();
    }
    ctx.strokeStyle = hexA(CFG.accent, .9); ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(c.x, c.y); ctx.lineTo(c.x + rPx * Math.cos(a1), c.y + rPx * Math.sin(a1)); ctx.stroke();

    // sensor
    ctx.fillStyle = CFG.accent; ctx.beginPath(); ctx.arc(c.x, c.y, 5, 0, Math.PI * 2); ctx.fill();

    // paint tracks the beam just crossed
    for (const tr of tracks) {
      const b = bearingTo(tr.lat, tr.lon);
      const diff = (ang - b + 360) % 360;
      if (diff < 8) {
        if (!tr.seen) log(`DETECT ${tr.id} BRG ${String(Math.round(b)).padStart(3, "0")}`, tr.affil === "H");
        tr.seen = now;
        tr.marker.setLatLng([tr.lat, tr.lon]);
        tr.trail.push([tr.lat, tr.lon]); if (tr.trail.length > 12) tr.trail.shift();
        tr.line.setLatLngs(tr.trail);
      }
      const age = tr.seen ? (now - tr.seen) / SWEEP_PERIOD_MS : 9;
      const el = tr.marker.getElement();
      if (el) el.style.opacity = tr.seen ? Math.max(.35, 1 - age * .55) : 0;
    }
  }

  // ---- side panel --------------------------------------------------------
  const tbody = document.querySelector("#tracks tbody");
  function renderTable() {
    const now = Date.now();
    tbody.innerHTML = tracks.filter(t => t.seen).map(t => `
      <tr class="${now - t.seen > SWEEP_PERIOD_MS * 1.5 ? "stale" : ""}">
        <td class="glyph">${glyph(t.affil)}</td><td>${t.id}</td><td>${t.type}</td>
        <td>${Math.round(t.speed * 3.6)}</td><td>${String(Math.round(t.hdg)).padStart(3, "0")}</td>
      </tr>`).join("");
    document.getElementById("trackcount").textContent = tracks.filter(t => t.seen).length;
  }

  function log(msg, hostile) {
    const li = document.createElement("li");
    if (hostile) li.className = "hostile";
    li.innerHTML = `<time>${new Date().toISOString().slice(11, 19)}Z</time>${msg}`;
    logEl.prepend(li);
    while (logEl.children.length > 8) logEl.lastChild.remove();
  }

  const MON = ["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"];
  function dtg(d) {
    const p = n => String(n).padStart(2, "0");
    return p(d.getUTCDate()) + p(d.getUTCHours()) + p(d.getUTCMinutes()) + "Z" +
      MON[d.getUTCMonth()] + String(d.getUTCFullYear()).slice(2);
  }

  // ---- forward to C2 hub ------------------------------------------------
  let forwarded = 0;
  const linkEl = document.getElementById("linkstate");
  async function forward() {
    if (!CFG.hub) return;
    const fc = { type: "FeatureCollection", features: tracks.filter(t => t.seen).map(t => ({
      type: "Feature", id: t.id,
      geometry: { type: "Point", coordinates: [+t.lon.toFixed(6), +t.lat.toFixed(6)] },
      properties: { sidc: t.sidc, name: t.id, t: t.id, type: t.type, speed: Math.round(t.speed * 3.6), heading: Math.round(t.hdg) },
    })), source: { role: "isr", version: CFG.version } };
    try {
      const r = await fetch(CFG.hub + "/api/tracks", { method: "POST", body: JSON.stringify(fc),
        headers: { "Content-Type": "text/plain" }, signal: AbortSignal.timeout(2500) });
      if (!r.ok) throw new Error(r.status);
      forwarded += fc.features.length;
      linkEl.className = "pill ok"; linkEl.textContent = "FORWARDING";
    } catch {
      linkEl.className = "pill bad"; linkEl.textContent = "NO LINK";
    }
    document.getElementById("fwdcount").textContent = forwarded;
  }

  // ---- loops -------------------------------------------------------------
  let last = performance.now();
  function frame(t) {
    const dt = Math.min(.25, (t - last) / 1000); last = t;
    step(dt);
    drawSweep(Date.now());
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  setInterval(() => {
    renderTable();
    document.getElementById("dtg").textContent = dtg(new Date());
    const s = Math.floor((Date.now() - T0) / 1000), p = n => String(n).padStart(2, "0");
    document.getElementById("uptime").textContent = p(Math.floor(s / 3600)) + ":" + p(Math.floor(s / 60) % 60) + ":" + p(s % 60);
  }, 500);
  setInterval(forward, 1000);
  log("SENSOR ONLINE — IMAGE isr:" + CFG.version);
})();
