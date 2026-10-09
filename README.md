# RHEL Device Edge: Mission Role Swap Demo

An offline, three-device demo of **RHEL image mode (`bootc`)** at the tactical edge. A touch tablet re-roles two laptops by switching their entire operating system image from a local container registry. It also shows staging, atomic apply, instant rollback and patching over a simulated disconnected, intermittent and low-bandwidth (DDIL) link.

| Role | Image | What runs |
|---|---|---|
| **C2 Workstation** | `demo/c2` | [ODINv2](https://github.com/syncpoint/ODINv2) command & control map. It shows ISR tracks live as MIL-STD-2525 symbols. |
| **ISR Sensor Node** | `demo/isr` | A simulated EO/IR and GMTI sensor console with a radar sweep and track table over offline imagery of NTC Fort Irwin. It forwards its tracks to C2. |

The tablet runs **Edge Command**, a touch dashboard. It drives the laptops over SSH with `bootc`, shapes the registry link with `tc`, publishes image versions, and relays ISR tracks into ODIN.

> Everything runs **without internet**. Internet is only needed while you build.

---

## Architecture

```
                 ┌────────────── Tablet · RHEL 10 · 10.10.10.1 ───────────────┐
                 │  registry:2        :5000  OS images for the laptops        │
                 │  mbtileserver      :8000  offline map tiles (ODIN)         │
                 │  Edge Command      :8080  dashboard · ISR→ODIN track relay │
                 │                           · ISR map tiles                  │
                 │  tc/netem on LAN NIC      DDIL link simulator              │
                 └──────────────────────┬─────────────────────────────────────┘
                                        │  unmanaged gigabit switch
                     ┌──────────────────┴──────────────────┐
              edge-a 10.10.10.11                    edge-b 10.10.10.12
              RHEL image mode                       RHEL image mode
              role: C2  ⇄  ISR                      role: ISR  ⇄  C2
```

Both role images are built `FROM` one shared base image, so a role swap only downloads the role's own layers. The OS layers are already on disk.

```
registry.redhat.io/rhel10/rhel-bootc
        └── localhost/edge-base      GNOME Kiosk autologin, SSH key, registry trust
              ├── localhost/edge-c2:1.0 / 1.1     + ODINv2 (~100 MB+ layer)
              └── localhost/edge-isr:1.0 / 1.1    + sensor web app (KBs; 1.1 = amber sweep)
```

---

## What you need

| Item | Notes |
|---|---|
| 1 × x86 tablet | Runs RHEL 10 as a normal install. It is the build host, registry and dashboard. |
| 2 × x86 laptops | These are **wiped** and reinstalled with RHEL image mode. |
| Unmanaged ethernet switch, 3 cables | Plus USB-ethernet dongles for devices without a port. Don't rely on show Wi-Fi. |
| 2–3 USB sticks, 8 GB or more | For the laptop installer ISOs. |
| Red Hat subscription | The free [Red Hat Developer](https://developers.redhat.com/register) subscription works. |
| Internet (setup only) | Needed for RHEL content, the ODIN release and the map tiles. |

---

## Setup

### 1. Tablet: install and configure (online)

1. Install **RHEL 10** with a GUI on the tablet and register it:
   ```bash
   sudo subscription-manager register --username <your-redhat-login>
   ```
2. Clone this repo:
   ```bash
   git clone https://github.com/dthurston/rhde-odin-demo.git
   cd rhde-odin-demo
   ```
3. Edit **`demo.env`**. At minimum set `LAN_IFACE` to the NIC cabled to the switch (see `nmcli device`). IPs, node names, the RHEL version and the ODIN version are also set here.
4. Run the one-time setup:
   ```bash
   sudo ./tablet/setup-tablet.sh
   ```
   This does the following:
   - Installs podman, `tc`/netem and Firefox.
   - Pins `10.10.10.1` on the LAN NIC and creates the control SSH key.
   - Starts the registry, tile server and Edge Command as services.
   - Opens the dashboard full screen when you log in.
   - Copies the project to `/opt/edge-demo`.

   The builds run from that copy. To pick up later changes, run `git pull` in your clone and re-run `setup-tablet.sh`. It's safe to re-run and keeps your SSH key. For a single changed file, copying it over with `sudo cp <file> /opt/edge-demo/<file>` is enough.

### 2. Build the images (online)

```bash
sudo podman login registry.redhat.io
cd /opt/edge-demo
sudo ./build.sh all
```

Every `build.sh` command needs `sudo`. bootc-image-builder reads root's podman storage, so the images, and the `registry.redhat.io` login, must belong to root. `all` runs these steps, and each can also be run on its own:

| Step | Command | What it does |
|---|---|---|
| fetch | `sudo ./build.sh fetch` | Downloads the ODIN AppImage and about 9k USGS imagery tiles, and pre-pulls the build images. |
| base | `sudo ./build.sh base` | Builds `edge-base`. |
| roles | `sudo ./build.sh roles` | Builds `edge-c2` and `edge-isr`, versions 1.0 and 1.1. |
| publish | `sudo ./build.sh publish c2 1.0` and `sudo ./build.sh publish isr 1.0` | Makes each image the registry's `:latest`. |

> ⚠️ **Build `edge-base` once.** Rebuilding it changes every layer digest, and the laptops then re-download the whole OS.

> ℹ️ Each image ends with `bootc container lint`. Expect **warnings** about `sysusers`, `var-tmpfiles` and `var-log`. They come from package leftovers in `/var` and from users defined in `/etc/passwd`, and they're harmless here. Only a lint **error** stops the build.

Optional dry run in a VM before touching the laptops:
```bash
sudo ./build.sh qcow2      # output/vm/qcow2/disk.qcow2 — boots straight into ODIN
```

### 3. Install the laptops

Build one unattended installer per laptop. It asks for a console password for the `admin` user.
```bash
sudo ./build.sh iso edge-a 10.10.10.11
sudo ./build.sh iso edge-b 10.10.10.12
sudo dd if=output/edge-a/bootiso/install.iso of=/dev/sdX bs=4M status=progress oflag=sync
```
Each ISO takes about 10–20 minutes and prints a full verbose log. `build.sh` passes `--progress=verbose` because bootc-image-builder's progress bar can crash with `bufio.Scanner: token too long`. The ISO is ready when the script lists `output/<name>/bootiso/install.iso`.

Boot each laptop from its USB stick (UEFI; Secure Boot can stay on). The install is hands-off and **erases the disk**. Each laptop comes up auto-logged-in as the **C2** role, tracking `10.10.10.1:5000/demo/c2:latest`.

Check from the tablet:
```bash
sudo ssh -i /root/.ssh/edge_demo root@10.10.10.11 bootc status
```
Both laptops should also show **ONLINE** at `http://10.10.10.1:8080`.

### 4. Configure ODIN (once per laptop)

ODIN's settings live in `/var/home/edgeop`, which persists across every image switch. On each laptop, while it's in the C2 role:

1. **Offline basemap:** press `Ctrl+N`, then `T`. Enter the URL `http://10.10.10.1:8000/services`, tick **ao**, and select it under Background Maps (`Ctrl+Shift+T`). Disable the default online layer.
2. **Live ISR tracks:** click **+**, choose **Create Live Data Source**, and enter the URL `http://10.10.10.1:8080/live/tracks`. Use event type `message`, enable *Track features by ID*, and tick to connect.
3. Pan to NTC Fort Irwin (35.26 N, 116.68 W). Optionally draw some friendly units, a phase line and an objective.

### 5. Set up the starting state

1. In Edge Command, assign **edge-b → ISR Sensor Node**.
2. **Pre-stage rollback:** swap each laptop through both roles once (A: C2→ISR→C2, B: ISR→C2→ISR). Each laptop then holds the other role as its rollback deployment, so **SWAP ↺** is a reboot with no download.
3. Rehearse with the tablet's internet **unplugged**. Between runs, reset the registry to v1.0 with:
   ```bash
   sudo ./build.sh reset
   ```

---

## Running the demo (~5 minutes)

**On the table:** the tablet in front with Edge Command, edge-a showing ODIN, and edge-b showing the ISR console.

| # | Do | Say / show |
|---|---|---|
| 1 | Nothing yet | "Two laptops, two mission roles. Each one's *entire OS* is a container image. The tablet is the only thing they talk to: no cloud, no internet." |
| 2 | Point at the screens | ISR contacts sweep in on edge-b, and the same tracks appear in ODIN on edge-a. The **ISR → C2 FEED** panel reads **LIVE**. |
| 3 | **DATA LINK → DDIL**. On edge-b select **STAGE ONLY**, then **C2 WORKSTATION**. | The card says *mission app still running*. Only the role layer crosses the link, and the MB counter shows it. If it's slow, switch to **FULL**: "comms restored". |
| 4 | **APPLY STAGED** | edge-b reboots into C2 in about a minute. The feed drops to **NO SENSOR**: "we just traded away our sensor." |
| 5 | **SWAP ↺ ISR** on edge-b | Nothing downloads because the previous image is still on disk. The tracks return to ODIN. |
| 6 | **DDIL** again. **REGISTRY → ISR v1.1**, then **UPDATE → v1.1** on edge-b. | A few KB over 1 Mbps. After the reboot the sweep is **amber**, visible proof the patch landed. |
| 7 | *(optional)* **CUT** during a stage | The pull fails and the laptop keeps running its old image. Nothing is ever half-applied. |
| 8 | Point at **Why image mode** | Atomic updates, rollback, the same toolchain as your apps, and bandwidth-aware delivery to the disconnected edge. |

### Dashboard controls

| Control | Runs on the laptop |
|---|---|
| Role button + **APPLY NOW** | `bootc switch --apply <registry>/demo/<role>:latest` |
| Role button + **STAGE ONLY** | `bootc switch <ref>` (downloads in the background while the current role keeps running) |
| **APPLY STAGED** | `systemctl reboot` into the staged image |
| **SWAP ↺** | `bootc rollback && systemctl reboot` (no download) |
| **CHECK UPDATE / UPDATE → vX** | `bootc upgrade [--apply]` |
| **DATA LINK** FULL / DEGRADED / DDIL / CUT | `tc` on the tablet, applied to registry traffic only (10 Mbps · 50 ms / 1 Mbps · 300 ms · 1% loss / 100% loss). SSH control stays up so you can watch the laptop's behavior. |
| **REGISTRY** v1.0 / v1.1 | `podman push` of `localhost/edge-<role>:<ver>` to `demo/<role>:latest` |

---

## Developing without hardware

Edge Command has a mock mode that simulates the laptops, the registry and the link. It uses only the Python standard library.

```bash
DEMO_MOCK=1 python3 dashboard/server.py        # http://localhost:8080
```

To preview the ISR console in a browser:

```bash
python3 -m http.server 8091 --directory isr/app   # http://localhost:8091
```

In local preview it reads tiles and posts tracks to `localhost:8080`. Running `python3 tools/fetch-tiles.py` builds `tiles/ao.mbtiles` for it.

---

## Repository layout

| Path | Purpose |
|---|---|
| `demo.env` | All IPs, names and versions, in one place |
| `build.sh` | `fetch` · `base` · `roles` · `publish` · `iso` · `qcow2` · `reset` · `all` |
| `base/` | Shared OS image: RHEL bootc, GDM autologin into GNOME Kiosk, SSH key in `/usr/ssh`, registry trust, no screen blanking |
| `c2/` | ODINv2 role: AppImage unpacked to `/usr/lib/odin`, kiosk launcher |
| `isr/` | ISR sensor role: static web app with Leaflet vendored for offline use |
| `dashboard/` | Edge Command server (`server.py`) and touch UI (`static/`) |
| `tablet/` | `setup-tablet.sh`, registry/tile Quadlets, dashboard systemd unit, kiosk autostart |
| `iso/` | Kickstart template for unattended laptop installs |
| `tools/fetch-tiles.py` | Builds the offline `.mbtiles` from USGS National Map imagery (public domain) |
| [`RUNBOOK.md`](RUNBOOK.md) | Show-day checklist, a detailed script and troubleshooting |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Laptop card stuck **OFFLINE** | Check the cable or switch. Run `ping 10.10.10.11`. On the laptop console, log in as `admin` and run `sudo bootc status`. |
| Laptop has only an IPv6 (`fe80::`) address and no 10.10.10.x | Its static IPv4 profile is missing. This happens with ISOs built before the `edge-demo.nmconnection` fix. Press `Ctrl+Alt+F3`, log in as `admin` and run: `sudo nmcli con add type ethernet con-name edge-demo ipv4.method manual ipv4.addresses 10.10.10.11/24 ipv4.gateway 10.10.10.1 ipv6.method disabled connection.autoconnect-priority 100 && sudo nmcli con up edge-demo` (use `.12` on edge-b). It lives in `/etc` and survives image switches. |
| Laptop boots to a **text login** instead of the kiosk | `systemctl get-default` says `multi-user.target`. A text-mode install sets that on ISOs built before the fix. From the tablet: `sudo ssh -i /root/.ssh/edge_demo root@<laptop-ip> 'systemctl set-default graphical.target && systemctl isolate graphical.target'` |
| Grey kiosk screen, no ODIN, and `app.asar: FILE_ERROR_ACCESS_DENIED` | The C2 image was built before the permissions fix. Run `git pull`, rebuild with `sudo ./build.sh roles`, run `sudo ./build.sh publish c2 1.0`, then press **CHECK UPDATE** on the laptop. |
| ODIN doesn't appear | The kiosk retries with `--no-sandbox` automatically. Check `journalctl --user -b` as the `edgeop` user. |
| Blank map in ODIN, or a 404 from port 8000 | Run `curl http://10.10.10.1:8000/services`. If `ao` isn't listed, the tile server started before `tiles/ao.mbtiles` existed. It only scans at startup, so run `sudo systemctl restart edge-tiles`. |
| ISR console says **NO LINK** | Run `systemctl status edge-command` on the tablet and check that port 8080 is open in firewalld. |
| DDIL buttons error | Run `modprobe sch_netem` (from `kernel-modules-extra`) and check `LAN_IFACE` in `demo.env`. |
| `bootc switch` fails with a TLS error | The registry is plain HTTP. Rebuild base if you changed `REGISTRY` in `demo.env`. |

See [RUNBOOK.md](RUNBOOK.md) for the full show-day checklist.

## Credits and licenses

- [ODINv2](https://github.com/syncpoint/ODINv2) by Syncpoint GmbH, AGPL-3.0. It is downloaded at build time from the official release and not redistributed here.
- [Leaflet](https://leafletjs.com) 1.9.4, BSD-2-Clause, vendored in `isr/app/vendor/`.
- Map imagery: [USGS The National Map](https://www.usgs.gov/programs/national-geospatial-program/national-map), public domain.
- The ISR feed is **simulated**. No real sensor data is used.
