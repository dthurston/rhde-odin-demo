#!/usr/bin/env python3
"""Edge Command -- tablet-side control plane for the RHEL image mode demo.

Drives the laptops over SSH with `bootc`, shapes the registry link with `tc`,
publishes role images to the local registry, relays ISR tracks to ODIN as an
SSE Live Data Source, and serves offline map tiles from an .mbtiles file.

Standard library only, so it runs on a fresh RHEL install with no internet.
Set DEMO_MOCK=1 to run anywhere with simulated laptops (UI development).
"""
import hashlib
import json
import os
import queue
import random
import re
import sqlite3
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MOCK = os.environ.get("DEMO_MOCK") == "1"
PORT = int(os.environ.get("PORT", "8080"))


def load_env(path):
    env = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip().strip('"')
        v = re.sub(r"\$\{(\w+)\}", lambda m: env.get(m.group(1), ""), v)
        env[k.strip()] = v
    return env


ENV = load_env(Path(os.environ.get("DEMO_ENV", ROOT / "demo.env")))
REGISTRY = ENV.get("REGISTRY", "10.10.10.1:5000")
LAN_IFACE = ENV.get("LAN_IFACE", "eth0")
SSH_KEY = ENV.get("SSH_KEY", "/root/.ssh/edge_demo")
TILES_DIR = Path(os.environ.get("TILES_DIR", ROOT / "tiles"))
NODES = [dict(zip(("name", "ip"), n.split("=", 1))) for n in ENV.get("NODES", "edge-a=10.10.10.11 edge-b=10.10.10.12").split()]
ROLES = {
    "c2": {"label": "C2 Workstation", "app": "ODINv2 command & control"},
    "isr": {"label": "ISR Sensor Node", "app": "EO/IR + GMTI sensor feed"},
}
VERSIONS = ["1.0", "1.1"]
LINK_MODES = {
    "full":     {"label": "FULL",     "desc": "1 Gbps LAN"},
    "degraded": {"label": "DEGRADED", "desc": "10 Mbps · 50 ms"},
    "ddil":     {"label": "DDIL",     "desc": "1 Mbps · 300 ms · 1% loss"},
    "cut":      {"label": "CUT",      "desc": "Data link down"},
}


def role_ref(role):
    return f"{REGISTRY}/demo/{role}:latest"


def role_of(ref):
    m = re.search(r"/demo/(\w+)[:@]", ref or "")
    return m.group(1) if m else None


# --------------------------------------------------------------------------- events
class Bus:
    def __init__(self):
        self.clients = set()
        self.lock = threading.Lock()
        self.history = []

    def subscribe(self):
        q = queue.Queue(maxsize=500)
        with self.lock:
            self.clients.add(q)
            for item in self.history[-60:]:
                q.put(item)
        return q

    def unsubscribe(self, q):
        with self.lock:
            self.clients.discard(q)

    def emit(self, kind, data):
        item = (kind, data)
        with self.lock:
            if kind == "log":
                self.history.append(item)
                del self.history[:-200]
            for q in list(self.clients):
                try:
                    q.put_nowait(item)
                except queue.Full:
                    pass


BUS = Bus()


def log(msg, node=None, level="info"):
    BUS.emit("log", {"t": time.time(), "node": node, "level": level, "msg": msg})


# --------------------------------------------------------------------------- state
LOCK = threading.RLock()
STATE = {
    "nodes": {n["name"]: {"name": n["name"], "ip": n["ip"], "phase": "unknown", "busy": None,
                          "booted": None, "staged": None, "rollback": None, "hostname": None,
                          "op_started": None, "op_bytes0": None, "last_seen": None, "target": None} for n in NODES},
    "link": {"mode": "full"},
    "registry": {r: {"version": None, "digest": None} for r in ROLES},
    "net": {"tx_bps": 0.0, "tx_total": 0},
    "tracks": {"count": 0, "from": None, "at": 0, "version": None},
}
TRACKS = {"fc": {"type": "FeatureCollection", "features": []}, "at": 0}


def deployment(entry):
    """Normalise one deployment out of `bootc status --format=json`."""
    if not entry:
        return None
    img = entry.get("image") or {}
    ref = (img.get("image") or {}).get("image")
    return {"ref": ref, "role": role_of(ref), "version": img.get("version"),
            "digest": img.get("imageDigest"), "timestamp": img.get("timestamp")}


# --------------------------------------------------------------------------- backends
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07")


class RealBackend:
    def _ssh(self, ip, tty=False):
        args = ["ssh", "-i", SSH_KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
                "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR", "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=3"]
        if tty:
            args.append("-tt")
        return args + [f"root@{ip}"]

    def status(self, node):
        try:
            out = subprocess.run(self._ssh(node["ip"]) + ["hostname; bootc status --format=json"],
                                 capture_output=True, text=True, timeout=8)
        except subprocess.TimeoutExpired:
            return None
        if out.returncode != 0:
            return None
        host, _, js = out.stdout.partition("\n")
        st = (json.loads(js).get("status") or {})
        return {"hostname": host.strip(), "booted": deployment(st.get("booted")),
                "staged": deployment(st.get("staged")), "rollback": deployment(st.get("rollback"))}

    def run(self, node, command, on_line):
        p = subprocess.Popen(self._ssh(node["ip"], tty=True) + [command],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        buf, last_progress = b"", 0.0
        while True:
            chunk = p.stdout.read1(4096) if hasattr(p.stdout, "read1") else p.stdout.read(1)
            if not chunk:
                break
            buf += chunk
            parts = re.split(rb"[\r\n]", buf)
            buf = parts.pop()
            for raw in parts:
                line = ANSI.sub("", raw.decode(errors="replace")).strip()
                if not line:
                    continue
                # progress bars redraw constantly; keep the log readable
                if re.search(r"\d+(\.\d+)?\s*[KMG]i?B|\d+%|\[[#=>\- ]+\]", line):
                    if time.time() - last_progress < 0.5:
                        continue
                    last_progress = time.time()
                on_line(line)
        return p.wait()

    def shell(self, command):
        return subprocess.run(command, shell=True, capture_output=True, text=True)

    def tx_bytes(self):
        try:
            return int(Path(f"/sys/class/net/{LAN_IFACE}/statistics/tx_bytes").read_text())
        except OSError:
            return 0

    def registry_info(self, role):
        base = f"http://{REGISTRY}/v2/demo/{role}"
        accept = ", ".join(["application/vnd.oci.image.manifest.v1+json",
                            "application/vnd.docker.distribution.manifest.v2+json"])
        try:
            req = urllib.request.Request(f"{base}/manifests/latest", headers={"Accept": accept})
            with urllib.request.urlopen(req, timeout=3) as r:
                digest = r.headers.get("Docker-Content-Digest")
                manifest = json.load(r)
            with urllib.request.urlopen(f"{base}/blobs/{manifest['config']['digest']}", timeout=3) as r:
                labels = (json.load(r).get("config") or {}).get("Labels") or {}
            return {"version": labels.get("org.opencontainers.image.version"), "digest": digest}
        except Exception:
            return {"version": None, "digest": None}


class MockBackend:
    """Simulated laptops so the UI can be built and rehearsed without hardware."""
    SIZES = {"c2": 182e6, "isr": 0.4e6}  # role-layer delta; base layers already cached

    def __init__(self):
        self.reg = {"c2": "1.0", "isr": "1.0"}
        self.tx = 0
        self.hosts = {}
        for i, n in enumerate(NODES):
            role = "c2" if i % 2 == 0 else "isr"
            self.hosts[n["name"]] = {"booted": self._dep(role, "1.0"), "staged": None, "rollback": None,
                                     "down_until": 0}

    def _dep(self, role, ver):
        return {"ref": role_ref(role), "role": role, "version": ver,
                "digest": "sha256:" + hashlib.sha256(f"{role}{ver}".encode()).hexdigest(), "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ")}

    def status(self, node):
        h = self.hosts[node["name"]]
        if time.time() < h["down_until"]:
            return None
        return {"hostname": node["name"], **{k: h[k] for k in ("booted", "staged", "rollback")}}

    def _rate(self):
        return {"full": 60e6, "degraded": 1.2e6, "ddil": 0.11e6, "cut": 0}[STATE["link"]["mode"]] * 3

    def _pull(self, role, on_line):
        size, done = self.SIZES[role], 0.0
        on_line(f"layers already present: 64; layers needed: {2 if role == 'c2' else 1} ({size / 1e6:.1f} MB)")
        while done < size:
            rate = self._rate()
            if rate == 0:
                time.sleep(3)
                on_line("error: fetching layer: connection reset by peer")
                return False
            time.sleep(0.5)
            step = min(size - done, rate * 0.5)
            done += step
            self.tx += int(step * 1.04)  # + protocol overhead
            on_line(f"Fetching ostree chunk {done / 1e6:.1f} MB / {size / 1e6:.1f} MB")
        on_line("Pruned images: 0 (layers: 0, objsize: 0 bytes)")
        return True

    def _reboot(self, h):
        h["rollback"], h["booted"], h["staged"] = h["booted"], h["staged"] or h["booted"], None
        h["down_until"] = time.time() + 20

    def run(self, node, command, on_line):
        h = self.hosts[node["name"]]
        apply = "--apply" in command
        time.sleep(0.6)
        if command.startswith("bootc switch"):
            role = role_of(command.split()[-1])
            on_line(f"Queued for next boot: {command.split()[-1]}")
            if not self._pull(role, on_line):
                return 1
            h["staged"] = self._dep(role, self.reg[role])
            on_line("Staging deployment... done")
        elif command.startswith("bootc upgrade"):
            role = h["booted"]["role"]
            if h["booted"]["version"] == self.reg[role]:
                on_line("No changes in: " + role_ref(role))
                return 0
            on_line(f"Update available for {role_ref(role)}")
            if not self._pull("isr", on_line):  # point updates are small deltas
                return 1
            h["staged"] = self._dep(role, self.reg[role])
            on_line("Staging deployment... done")
        elif command.startswith("bootc rollback"):
            if not h["rollback"]:
                on_line("error: No rollback available")
                return 1
            h["staged"] = h["rollback"]
            on_line("Next boot: rollback deployment")
        elif "reboot" in command:
            apply = True
        if apply:
            on_line("Rebooting system...")
            self._reboot(h)
            return 255
        return 0

    def shell(self, command):
        m = re.search(r"edge-(\w+):([\d.]+) ", command)
        if m:
            self.reg[m.group(1)] = m.group(2)
        time.sleep(1.5)
        return subprocess.CompletedProcess(command, 0, "Writing manifest to image destination\n", "")

    def tx_bytes(self):
        return self.tx

    def registry_info(self, role):
        return {"version": self.reg[role],
                "digest": "sha256:" + hashlib.sha256(f"{role}{self.reg[role]}".encode()).hexdigest()}


BACKEND = MockBackend() if MOCK else RealBackend()


# --------------------------------------------------------------------------- workers
def poll_node(name):
    while True:
        node = STATE["nodes"][name]
        st = BACKEND.status(node)
        with LOCK:
            if st:
                if node["phase"] == "rebooting" and time.time() - (node["op_started"] or 0) < 8:
                    pass  # still on its way down
                else:
                    if node["phase"] == "rebooting":
                        secs = time.time() - node["op_started"]
                        b = st["booted"] or {}
                        log(f"back online as {ROLES.get(b.get('role'), {}).get('label', '?')} "
                            f"v{b.get('version')} after {secs:.0f}s", name, "ok")
                        node["op_started"] = None
                    node.update(st, last_seen=time.time())
                    node["phase"] = "busy" if node["busy"] else "online"
            elif node["phase"] == "rebooting" and time.time() - (node["op_started"] or 0) > 300:
                log("did not come back after 5 min — check the console", name, "error")
                node["phase"], node["op_started"] = "offline", None
            elif node["phase"] != "rebooting":
                if node["phase"] != "offline":
                    log("unreachable", name, "warn")
                node["phase"] = "offline"
        time.sleep(3)


def poll_net():
    last, lt = BACKEND.tx_bytes(), time.time()
    tick = 0
    while True:
        time.sleep(1)
        now, cur = time.time(), BACKEND.tx_bytes()
        with LOCK:
            STATE["net"]["tx_bps"] = max(0, (cur - last) * 8 / (now - lt))
            STATE["net"]["tx_total"] = cur
            fresh = time.time() - TRACKS["at"] < 5
            STATE["tracks"]["count"] = len(TRACKS["fc"]["features"]) if fresh else 0
        last, lt = cur, now
        if tick % 5 == 0:
            for role in ROLES:
                info = BACKEND.registry_info(role)
                with LOCK:
                    STATE["registry"][role] = info
        tick += 1
        BUS.emit("state", snapshot())


def snapshot():
    with LOCK:
        s = json.loads(json.dumps(STATE))
    for n in s["nodes"].values():
        if n["op_bytes0"] is not None:
            n["op_bytes"] = s["net"]["tx_total"] - n["op_bytes0"]
    s["roles"], s["versions"], s["link_modes"], s["mock"] = ROLES, VERSIONS, LINK_MODES, MOCK
    s["registry_host"] = REGISTRY
    return s


def node_action(name, action, role=None, apply=True):
    node = STATE["nodes"].get(name)
    if not node:
        return 404, {"error": "no such node"}
    with LOCK:
        if node["busy"]:
            return 409, {"error": f"{name} is busy ({node['busy']})"}
        if node["phase"] in ("offline", "rebooting") and action != "status":
            return 409, {"error": f"{name} is {node['phase']}"}
        booted, staged = node["booted"] or {}, node["staged"]
        if action == "assign":
            if role not in ROLES:
                return 400, {"error": "unknown role"}
            if booted.get("role") == role and not staged:
                return 409, {"error": f"{name} is already {ROLES[role]['label']}"}
            cmd, what = f"bootc switch {'--apply ' if apply else ''}{role_ref(role)}", \
                f"{'assign' if apply else 'stage'} role {ROLES[role]['label']}"
        elif action == "apply":
            if not staged:
                return 409, {"error": "nothing staged"}
            cmd, what = "systemctl reboot", "apply staged image (reboot)"
        elif action == "rollback":
            if not node["rollback"]:
                return 409, {"error": "no rollback deployment"}
            cmd, what = "bootc rollback && systemctl reboot", "rollback (instant, no download)"
        elif action == "update":
            cmd, what = f"bootc upgrade {'--apply' if apply else ''}".strip(), \
                "pull + apply update" if apply else "stage update"
        else:
            return 400, {"error": "unknown action"}
        node["target"] = {"assign": role, "rollback": (node["rollback"] or {}).get("role"),
                          "apply": (staged or {}).get("role")}.get(action, booted.get("role"))
        node["busy"], node["phase"] = what, "busy"
        node["op_started"], node["op_bytes0"] = time.time(), BACKEND.tx_bytes()

    def work():
        log(f"▶ {what}", name)
        log(f"$ {cmd}", name, "cmd")
        seen = []

        def on_line(line):
            seen.append(line)
            log(line, name, "out")

        rc = BACKEND.run(node, cmd, on_line)
        no_change = any(re.search(r"no (changes|update)", l, re.I) for l in seen)
        with LOCK:
            moved = BACKEND.tx_bytes() - node["op_bytes0"]
            node["busy"], node["op_bytes0"] = None, None
            # ssh exits 255 when the box reboots under it
            rebooting = rc == 255 or (rc == 0 and (action in ("apply", "rollback")
                                                   or (apply and action == "assign")
                                                   or (apply and action == "update" and not no_change)))
            if rebooting:
                node["phase"], node["op_started"] = "rebooting", time.time()
                log(f"rebooting into new image · {moved / 1e6:.1f} MB over link", name, "ok")
            elif rc == 0:
                node["phase"], node["op_started"] = "online", None
                log(f"✔ done · {moved / 1e6:.1f} MB over link · running mission untouched", name, "ok")
            else:
                node["phase"], node["op_started"] = "online", None
                log(f"✖ failed (rc={rc}) · running image untouched, nothing half-applied", name, "error")
        BUS.emit("state", snapshot())

    threading.Thread(target=work, daemon=True).start()
    return 202, {"ok": True}


def set_link(mode):
    if mode not in LINK_MODES:
        return 400, {"error": "unknown mode"}
    dev = LAN_IFACE
    # Only registry traffic (src port 5000) is shaped: the control link (SSH)
    # stays up so the dashboard can show what the laptop does on a bad link.
    netem = {"degraded": "delay 50ms rate 10mbit", "ddil": "delay 300ms rate 1mbit loss 1%",
             "cut": "loss 100%"}.get(mode)
    cmds = [f"tc qdisc del dev {dev} root 2>/dev/null || true"]
    if netem:
        cmds += [f"tc qdisc add dev {dev} root handle 1: prio bands 3 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1",
                 f"tc qdisc add dev {dev} parent 1:3 handle 30: netem {netem}",
                 f"tc filter add dev {dev} parent 1:0 protocol ip u32 match ip sport 5000 0xffff flowid 1:3"]
    if not MOCK:
        for c in cmds:
            r = BACKEND.shell(c)
            if r.returncode != 0:
                log(f"tc failed: {r.stderr.strip()}", None, "error")
                return 500, {"error": r.stderr}
    with LOCK:
        STATE["link"]["mode"] = mode
    log(f"data link → {LINK_MODES[mode]['label']} ({LINK_MODES[mode]['desc']})", None,
        "warn" if mode != "full" else "ok")
    BUS.emit("state", snapshot())
    return 200, {"ok": True}


PUBLISHING = set()


def publish(role, version):
    if role not in ROLES or version not in VERSIONS:
        return 400, {"error": "bad role/version"}
    if role in PUBLISHING:
        return 409, {"error": "publish in progress"}
    PUBLISHING.add(role)

    def work():
        log(f"▶ publish {role}:{version} → {role_ref(role)}", "registry")
        cmd = (f"podman tag localhost/edge-{role}:{version} {role_ref(role)} && "
               f"podman push --tls-verify=false {role_ref(role)}")
        log(f"$ {cmd}", "registry", "cmd")
        r = BACKEND.shell(cmd)
        PUBLISHING.discard(role)
        if r.returncode == 0:
            with LOCK:
                STATE["registry"][role] = BACKEND.registry_info(role)
            log(f"✔ {role}:{version} is now :latest — nodes in this role can update", "registry", "ok")
        else:
            log(f"✖ publish failed: {(r.stderr or r.stdout).strip()[-300:]}", "registry", "error")
        BUS.emit("state", snapshot())

    threading.Thread(target=work, daemon=True).start()
    return 202, {"ok": True}


# --------------------------------------------------------------------------- tiles
_TILE_DBS = {}


def tile(name, z, x, y):
    path = TILES_DIR / f"{name}.mbtiles"
    if not re.fullmatch(r"[\w-]+", name) or not path.exists():
        return None, None
    db = _TILE_DBS.get(name)
    if db is None:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, check_same_thread=False)
        fmt = (db.execute("select value from metadata where name='format'").fetchone() or ["png"])[0]
        _TILE_DBS[name] = db = (db, threading.Lock(), "image/jpeg" if fmt in ("jpg", "jpeg") else "image/png")
    conn, lk, ctype = db
    with lk:
        row = conn.execute("select tile_data from tiles where zoom_level=? and tile_column=? and tile_row=?",
                           (z, x, (1 << z) - 1 - y)).fetchone()
    return (row[0], ctype) if row else (None, None)


# --------------------------------------------------------------------------- http
STATIC = HERE / "static"
CTYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css",
          ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store" if ctype.startswith(("application", "text/html")) else "max-age=3600")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def _sse_start(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/state":
            return self._send(200, snapshot())
        if path == "/api/events":
            return self._events()
        if path == "/live/tracks":
            return self._tracks_stream()
        if path.startswith("/nominatim/"):
            return self._send(200, [])
        m = re.fullmatch(r"/tiles/([\w-]+)/(\d+)/(\d+)/(\d+)(?:\.\w+)?", path)
        if m:
            data, ctype = tile(m.group(1), *map(int, m.groups()[1:]))
            return self._send(200, data, ctype) if data else self._send(404, b"", "text/plain")
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        f = (STATIC / rel).resolve()
        if STATIC in f.parents and f.is_file():
            return self._send(200, f.read_bytes(), CTYPES.get(f.suffix, "application/octet-stream"))
        self._send(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        body = self._body()
        m = re.fullmatch(r"/api/nodes/([\w-]+)/(\w+)", path)
        if m:
            return self._send(*node_action(m.group(1), m.group(2), body.get("role"), body.get("apply", True)))
        if path == "/api/link":
            return self._send(*set_link(body.get("mode")))
        if path == "/api/publish":
            return self._send(*publish(body.get("role"), body.get("version")))
        if path == "/api/tracks":
            feats = body.get("features") if isinstance(body.get("features"), list) else []
            src = body.get("source") or {}
            with LOCK:
                TRACKS["fc"] = {"type": "FeatureCollection", "features": feats}
                TRACKS["at"] = time.time()
                who = next((n["name"] for n in NODES if n["ip"] == self.client_address[0]), self.client_address[0])
                STATE["tracks"].update(count=len(feats), at=TRACKS["at"], version=src.get("version"))
                if STATE["tracks"]["from"] != who:
                    log(f"ISR feed now arriving from {who}", "isr-feed", "ok")
                STATE["tracks"]["from"] = who
            return self._send(200, {"ok": True})
        self._send(404, {"error": "not found"})

    def _events(self):
        self._sse_start()
        q = BUS.subscribe()
        try:
            self.wfile.write(f"event: state\ndata: {json.dumps(snapshot())}\n\n".encode())
            self.wfile.flush()
            while True:
                try:
                    kind, data = q.get(timeout=15)
                    self.wfile.write(f"event: {kind}\ndata: {json.dumps(data)}\n\n".encode())
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            BUS.unsubscribe(q)

    def _tracks_stream(self):
        """SSE Live Data Source for ODIN: GeoJSON FeatureCollection once a second."""
        self._sse_start()
        try:
            while True:
                with LOCK:
                    fresh = time.time() - TRACKS["at"] < 5
                    fc = TRACKS["fc"] if fresh else {"type": "FeatureCollection", "features": []}
                self.wfile.write(f"data: {json.dumps(fc)}\n\n".encode())
                self.wfile.flush()
                time.sleep(1)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def main():
    for n in NODES:
        threading.Thread(target=poll_node, args=(n["name"],), daemon=True).start()
    threading.Thread(target=poll_net, daemon=True).start()
    if MOCK:
        threading.Thread(target=_mock_isr_feed, daemon=True).start()
    log(f"Edge Command up · registry {REGISTRY} · {'MOCK MODE' if MOCK else 'live'}", None, "ok")
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    print(f"Edge Command listening on :{PORT} (mock={MOCK})", flush=True)
    srv.serve_forever()


def _mock_isr_feed():
    """In mock mode, pretend whichever node is ISR is posting tracks."""
    while True:
        time.sleep(1)
        with LOCK:
            isr = next((n for n in STATE["nodes"].values()
                        if n["phase"] in ("online", "busy") and (n["booted"] or {}).get("role") == "isr"), None)
            if isr:
                TRACKS["fc"] = {"type": "FeatureCollection", "features": [{}] * random.randint(5, 7)}
                TRACKS["at"] = time.time()
                STATE["tracks"].update(**{"from": isr["name"], "version": isr["booted"]["version"]})


if __name__ == "__main__":
    main()
