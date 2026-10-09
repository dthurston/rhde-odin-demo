(() => {
  const $ = (s, el = document) => el.querySelector(s);
  const ICONS = {
    c2: `<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2.2">
      <rect x="5" y="9" width="38" height="26" rx="2"/><path d="M17 41h14M24 35v6"/>
      <path d="M11 29l7-8 6 5 8-10 5 5" stroke-linejoin="round"/><circle cx="32" cy="16" r="2.4" fill="currentColor"/></svg>`,
    isr: `<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2.2">
      <circle cx="24" cy="24" r="18"/><circle cx="24" cy="24" r="10" opacity=".6"/>
      <path d="M24 24 36 11" stroke-linecap="round"/><circle cx="24" cy="24" r="2.6" fill="currentColor"/>
      <circle cx="33" cy="29" r="2" fill="currentColor"/></svg>`,
    none: `<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2.2" opacity=".5">
      <rect x="8" y="8" width="32" height="32" rx="3" stroke-dasharray="4 4"/></svg>`,
  };
  let S = null;
  const cards = {};
  const applyMode = {};
  const rateHist = [];

  // ---------- render ----------
  function depText(d) {
    if (!d) return `<span class="none">—</span>`;
    const role = d.role || "?";
    return `<span class="r-${role}">${role.toUpperCase()}</span> v${d.version || "?"}`;
  }

  function card(n, idx) {
    if (cards[n.name]) return cards[n.name];
    const el = $("#node-tpl").content.firstElementChild.cloneNode(true);
    el.dataset.idx = idx;
    $(".node-name", el).textContent = n.name;
    $(".node-ip", el).textContent = n.ip;
    applyMode[n.name] = true;
    el.querySelectorAll(".mode button").forEach(b => b.onclick = () => {
      applyMode[n.name] = b.dataset.apply === "1";
      el.querySelectorAll(".mode button").forEach(x => x.classList.toggle("on", x === b));
    });
    el.querySelectorAll(".act").forEach(b => b.onclick = () =>
      post(`/api/nodes/${n.name}/${b.dataset.act}`, { apply: b.dataset.act === "update" ? applyMode[n.name] : true }));
    $(".roles", el).innerHTML = Object.entries(S.roles).map(([k, r]) => `
      <button class="rolebtn" data-role="${k}">${ICONS[k] || ICONS.none}
        <span><b>${r.label.toUpperCase()}</b><small>${r.app}</small></span></button>`).join("");
    el.querySelectorAll(".rolebtn").forEach(b => b.onclick = () =>
      post(`/api/nodes/${n.name}/assign`, { role: b.dataset.role, apply: applyMode[n.name] }));
    $("#nodes").appendChild(el);
    return (cards[n.name] = el);
  }

  function fmtMB(b) { return b == null ? "" : (b / 1e6).toFixed(b < 1e7 ? 2 : 0) + " MB"; }

  function renderNode(n, idx) {
    const el = card(n, idx);
    const b = n.booted || {};
    const role = b.role;
    const r = S.roles[role];
    el.dataset.role = role || "";

    const phase = $(".phase", el);
    const PH = { online: ["ONLINE", "ok"], busy: ["WORKING", "busy"], rebooting: ["REBOOTING", "warn"],
      offline: ["OFFLINE", "bad"], unknown: ["CONNECTING", ""] }[n.phase] || [n.phase, ""];
    phase.textContent = PH[0]; phase.className = "pill phase " + PH[1];

    $(".role-icon", el).innerHTML = ICONS[role] || ICONS.none;
    $(".role-label", el).textContent = r ? r.label : (n.phase === "offline" ? "No contact" : "Unassigned");
    $(".role-app", el).textContent = r ? r.app : "";
    const reg = S.registry[role] || {};
    const upd = role && reg.digest && b.digest && reg.digest !== b.digest &&
      reg.digest !== (n.staged || {}).digest && reg.version;
    $(".role-ver", el).innerHTML = role
      ? `${role}:${b.version || "?"} · ${(b.digest || "").replace("sha256:", "").slice(0, 12)}` +
        (upd ? `<span class="upd">▲ v${reg.version} available</span>` : "")
      : "";

    // overlay for in-flight work
    const ov = $(".overlay", el);
    const target = n.target || (n.staged || {}).role;
    if (n.phase === "rebooting") {
      const secs = n.op_started ? Math.round(Date.now() / 1000 - n.op_started) : 0;
      const into = S.roles[target]?.label || "new image";
      ov.hidden = false;
      $(".ov-title", ov).textContent = "Rebooting";
      $(".ov-sub", ov).innerHTML = `into <b>${into}</b><br>${secs}s elapsed · atomic switch`;
      if (target) el.dataset.role = target;
    } else if (n.busy) {
      const secs = n.op_started ? Math.round(Date.now() / 1000 - n.op_started) : 0;
      ov.hidden = false;
      $(".ov-title", ov).textContent = n.busy;
      $(".ov-sub", ov).innerHTML = `<b>${fmtMB(n.op_bytes || 0)}</b> over link · ${secs}s<br>mission app still running`;
    } else {
      ov.hidden = true;
    }

    for (const k of ["booted", "staged", "rollback"]) $(`.dep[data-k="${k}"] span`, el).innerHTML = depText(n[k]);

    const idle = n.phase === "online" && !n.busy;
    el.querySelectorAll(".rolebtn").forEach(btn => {
      const cur = btn.dataset.role === role;
      btn.classList.toggle("current", cur);
      btn.disabled = !idle || (cur && !n.staged);
    });
    const rb = n.rollback;
    const actApply = $('[data-act="apply"]', el), actRb = $('[data-act="rollback"]', el), actUp = $('[data-act="update"]', el);
    actApply.disabled = !idle || !n.staged;
    actApply.classList.toggle("hot", idle && !!n.staged);
    actRb.disabled = !idle || !rb;
    actRb.textContent = rb ? `SWAP ↺ ${(rb.role || "?").toUpperCase()} v${rb.version}` : "QUICK SWAP ↺";
    actUp.disabled = !idle || !role;
    actUp.classList.toggle("hot", idle && !!upd);
    actUp.textContent = upd ? `UPDATE → v${reg.version}` : "CHECK UPDATE";
  }

  function render() {
    $("#mockchip").hidden = !S.mock;
    $("#reghost").textContent = S.registry_host;
    Object.values(S.nodes).forEach(renderNode);

    // link
    const mode = S.link.mode, lm = S.link_modes[mode];
    const seg = $("#linkseg");
    if (!seg.children.length) {
      seg.innerHTML = Object.entries(S.link_modes).map(([k, m]) => `<button data-mode="${k}">${m.label}</button>`).join("");
      seg.querySelectorAll("button").forEach(b => b.onclick = () => post("/api/link", { mode: b.dataset.mode }));
    }
    seg.querySelectorAll("button").forEach(b => b.classList.toggle("on", b.dataset.mode === mode));
    $("#linkdesc").textContent = lm.desc + (mode === "full" ? "" : " · control link unaffected");
    const chip = $("#linkchip");
    chip.textContent = lm.label;
    chip.className = "pill " + ({ full: "ok", degraded: "warn", ddil: "warn", cut: "bad" }[mode]);

    // registry
    const reg = $("#registry");
    if (!reg.children.length) {
      reg.innerHTML = Object.entries(S.roles).map(([k, r]) => `
        <div class="regrow" data-role="${k}">
          <div class="name">${r.label}<small>demo/${k}:latest</small></div>
          <div class="vers">${S.versions.map(v => `<button class="vbtn" data-v="${v}">v${v}</button>`).join("")}</div>
        </div>`).join("");
      reg.querySelectorAll(".vbtn").forEach(b => b.onclick = () =>
        post("/api/publish", { role: b.closest(".regrow").dataset.role, version: b.dataset.v }));
    }
    reg.querySelectorAll(".regrow").forEach(row => {
      const cur = (S.registry[row.dataset.role] || {}).version;
      row.querySelectorAll(".vbtn").forEach(b => b.classList.toggle("on", b.dataset.v === cur));
    });

    // feed
    const t = S.tracks, live = t.count > 0;
    $("#feedcount").textContent = t.count;
    const fs = $("#feedstate");
    fs.textContent = live ? "LIVE" : "NO SENSOR";
    fs.className = "pill " + (live ? "ok" : "bad");
    $("#feedsrc").textContent = live ? `from ${t.from} · isr v${t.version}` : "no ISR node reporting";
    $("#feedurl").textContent = `http://${S.registry_host.split(":")[0]}:8080/live/tracks`;

    // throughput
    const mbps = S.net.tx_bps / 1e6;
    $("#rate").textContent = mbps < 10 ? mbps.toFixed(2) : mbps.toFixed(0);
  }

  function spark() {
    if (!S) return;
    rateHist.push(S.net.tx_bps); if (rateHist.length > 60) rateHist.shift();
    const c = $("#spark"), x = c.getContext("2d"), dpr = devicePixelRatio || 1;
    c.width = 200 * dpr; c.height = 44 * dpr; x.scale(dpr, dpr);
    const max = Math.max(1e6, ...rateHist);
    x.beginPath();
    rateHist.forEach((v, i) => {
      const px = (i / 59) * 200, py = 42 - (v / max) * 38;
      i ? x.lineTo(px, py) : x.moveTo(px, py);
    });
    x.strokeStyle = "#3ddc84"; x.lineWidth = 1.6; x.stroke();
    x.lineTo((rateHist.length - 1) / 59 * 200, 44); x.lineTo(0, 44); x.closePath();
    x.fillStyle = "rgba(61,220,132,.12)"; x.fill();
  }

  // ---------- log ----------
  const nodeIdx = {};
  function addLog(e) {
    const li = document.createElement("li");
    const t = new Date(e.t * 1000).toISOString().slice(11, 19) + "Z";
    const tag = e.node || "command";
    if (!(tag in nodeIdx) && S && S.nodes[tag]) nodeIdx[tag] = Object.keys(S.nodes).indexOf(tag);
    const cls = tag in nodeIdx ? "n" + nodeIdx[tag] : "";
    li.innerHTML = `<time>${t}</time><span class="tag ${cls}">${tag.toUpperCase()}</span><span class="${e.level}"></span>`;
    li.lastChild.textContent = e.msg;
    const log = $("#log");
    const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 30;
    log.appendChild(li);
    while (log.children.length > 400) log.firstChild.remove();
    if (atBottom) log.scrollTop = log.scrollHeight;
  }
  $("#clearlog").onclick = () => { $("#log").innerHTML = ""; };

  // ---------- io ----------
  let toastT;
  function toast(msg) {
    const t = $("#toast"); t.textContent = msg; t.hidden = false;
    clearTimeout(toastT); toastT = setTimeout(() => (t.hidden = true), 3500);
  }
  async function post(url, body) {
    try {
      const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
      if (!r.ok) toast((await r.json()).error || r.statusText);
    } catch (e) { toast("Edge Command unreachable"); }
  }

  function connect() {
    const es = new EventSource("/api/events");
    es.addEventListener("state", ev => { S = JSON.parse(ev.data); render(); });
    es.addEventListener("log", ev => addLog(JSON.parse(ev.data)));
    es.onerror = () => { es.close(); setTimeout(connect, 2000); };
  }
  connect();

  const MON = ["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"];
  setInterval(() => {
    const d = new Date(), p = n => String(n).padStart(2, "0");
    $("#dtg").textContent = p(d.getUTCDate()) + p(d.getUTCHours()) + p(d.getUTCMinutes()) + "Z" +
      MON[d.getUTCMonth()] + String(d.getUTCFullYear()).slice(2);
    if (S) Object.values(S.nodes).forEach(n => (n.phase === "rebooting" || n.busy) && renderNode(n));
  }, 1000);
  setInterval(spark, 1000);
})();
