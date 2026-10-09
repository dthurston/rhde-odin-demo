# RHEL Device Edge demo: mission role swap over a DDIL link

A tablet runs **Edge Command**. It reassigns two laptops between mission roles by switching their whole OS image with `bootc`, pulling from a registry on the tablet. Everything runs offline.

| Role | Image | What the audience sees |
|---|---|---|
| **C2 Workstation** | `demo/c2` | ODINv2 C2 map, with live ISR tracks arriving as MIL-STD-2525 symbols |
| **ISR Sensor Node** | `demo/isr` | Sensor console: radar sweep over NTC imagery and a track table. It forwards tracks to C2. |

```
Tablet 10.10.10.1 ── dumb gigabit switch ── edge-a 10.10.10.11
  registry :5000                         └─ edge-b 10.10.10.12
  tiles    :8000 (ODIN TileJSON)
  Edge Command :8080 (dashboard, ISR→ODIN track relay, ISR map tiles)
```

---

## 0. Shopping and pre-flight (Thursday)
- A small **unmanaged ethernet switch**, 3 patch cables, and USB-ethernet dongles for any device without a port. Show-floor Wi-Fi is unreliable, so don't depend on it.
- Two USB sticks of 8 GB or more for the installer ISOs, plus one spare.
- A **Red Hat Developer subscription** (free) at developers.redhat.com, so the tablet can pull RHEL content.
- Laptop BIOS: enable UEFI boot from USB. You can leave Secure Boot on because RHEL is signed. Set the power profile to "always on".

## 1. Tablet (Thursday, needs internet)
1. Install **RHEL 10** (Workstation / Server with GUI) on the tablet as a normal install, then register it:
   `subscription-manager register --username <you>`.
2. Copy this folder to the tablet, for example on USB, to `~/rhde-odin-demo`. USB sticks drop the execute bits, so run `chmod +x build.sh tablet/setup-tablet.sh` afterward.
3. Edit `demo.env`. At minimum set **`LAN_IFACE`**, the NIC cabled to the switch (find it with `nmcli device`).
4. Run setup as root:
   ```bash
   sudo ./tablet/setup-tablet.sh
   ```
   This installs podman, tc and netem. It pins 10.10.10.1 on the LAN NIC and creates the control SSH key. It also starts the registry, tile and dashboard services and sets Firefox to open the dashboard full screen at login.
5. Log in to Red Hat's registry and build everything:
   ```bash
   sudo podman login registry.redhat.io
   cd /opt/edge-demo && sudo ./build.sh all
   ```
   `all` runs in this order: download ODIN and about 9k map tiles, build `edge-base`, build c2/isr v1.0 and v1.1, then publish v1.0 of both.
   **Build `edge-base` once and leave it alone.** Every rebuild changes its layer digests, and the laptops then re-download the whole OS.

## 2. Dry run in a VM (optional, Thursday night)
```bash
sudo ./build.sh qcow2        # output/vm/qcow2/disk.qcow2, user admin / $ADMIN_PW (default "redhat")
```
Boot it in virt-manager. It should auto-login straight into ODIN.

## 3. Install the laptops (Friday)
```bash
sudo ./build.sh iso edge-a 10.10.10.11
sudo ./build.sh iso edge-b 10.10.10.12
sudo dd if=output/edge-a/bootiso/install.iso of=/dev/sdX bs=4M status=progress oflag=sync
```
Boot each laptop from its stick. The install is unattended and **wipes the disk**. Each laptop comes up as the C2 role and already tracks `10.10.10.1:5000/demo/c2:latest`.
For console recovery, log in as `admin` with the password you entered.

Check from the tablet:
```bash
sudo ssh -i /root/.ssh/edge_demo root@10.10.10.11 bootc status
```

## 4. One-time ODIN configuration (on each laptop, while it's C2)
ODIN keeps its settings in `/var/home/operator`, and that survives every image switch, so you only do this once per laptop.
1. **Offline map:** press `Ctrl+N` then `T` and enter the URL `http://10.10.10.1:8000/services`. Tick `ao`, then select it under Background Maps (`Ctrl+Shift+T`). Turn off the default online OSM layer.
2. **Live ISR tracks:** click **+**, choose *Create Live Data Source*, enter the URL `http://10.10.10.1:8080/live/tracks`, keep the event type `message`, enable *Track features by ID*, and tick to connect.
3. Zoom to Fort Irwin / NTC (35.26 N, 116.68 W). Optionally draw a few friendly units, a phase line and an objective so the map looks like a real plan.

Then set up the demo's starting state: **edge-a = C2** and **edge-b = ISR** (on the dashboard, assign ISR to edge-b).
**Pre-stage the rollback path:** swap each laptop through both roles once (A→ISR→C2, B→C2→ISR). After that, each laptop holds the other role as its rollback deployment, so **SWAP ↺** becomes a reboot with no download.

## 5. Rehearse (Saturday and Sunday)
- Do three full runs with **the tablet's internet unplugged**.
- **Record a backup video** of one clean run on a phone and keep it on the tablet.
- Between runs, use `sudo ./build.sh reset`, which puts both roles back to v1.0 in the registry. Then use SWAP ↺ to return to the starting state.

---

## The demo (about 5 minutes)

**Setup on the table:** tablet in front running Edge Command, edge-a showing ODIN, edge-b showing the ISR console.

1. **Hook (30 s).** "Two laptops, two mission roles. Each laptop's entire operating system is a container image. This tablet is the only thing they talk to: a registry, a map server and a control app. There's no cloud, no internet and no USB sticks."
2. **Sensor to shooter (45 s).** Point at the tracks sweeping in on the ISR node. On edge-a, ODIN shows the same contacts as live 2525 symbols, relayed through the tablet. The tablet's *ISR → C2 FEED* panel shows LIVE.
3. **Re-role on a degraded link (90 s).** Set **DATA LINK to DDIL** (1 Mbps, 300 ms, 1% loss). On edge-b, choose **STAGE ONLY**, then **C2 WORKSTATION**.
   - The card says *mission app still running*, and the ISR console keeps working while the image downloads in the background.
   - Point out that only the role layer crosses the link because the OS layers are already on disk. Watch the MB counter.
   - *If it's slow* (the ODIN layer is about 100 MB or more), switch to FULL and say: "Comms restored, it finishes on its own."
4. **Atomic apply (60 s).** Press **APPLY STAGED**. edge-b reboots and comes back as a second C2 workstation, about a minute later. Meanwhile the ISR feed drops to **NO SENSOR**. "That's the trade-off: we just lost our sensor."
5. **Instant rollback (45 s).** On edge-b press **SWAP ↺ ISR**. Nothing downloads because the previous image is still on disk, and it boots straight back. The tracks reappear in ODIN.
6. **Patch over DDIL (60 s).** Set DATA LINK to DDIL. Under REGISTRY, publish **ISR Sensor Node v1.1**. On edge-b press **UPDATE → v1.1** with APPLY NOW. Only a few KB cross the 1 Mbps link. After the reboot the sweep is **amber**, a visible proof that the patch landed.
7. **Cut the link mid-update (optional, 30 s).** Set **CUT** during a stage. The pull fails, and the laptop is still running its old image, untouched. "Nothing is ever half-applied." Restore the link and retry.
8. **Close.** Point at the *Why image mode* panel: atomic updates, rollback, the same container toolchain as your apps, and bandwidth-aware delivery to the disconnected edge.

---

## Recovery and troubleshooting
| Symptom | Fix |
|---|---|
| Laptop card stuck **OFFLINE** | Check the cable or switch. `ping 10.10.10.11`. On the laptop console, log in as `admin` and run `sudo bootc status`. |
| ODIN window doesn't appear | The kiosk retries with `--no-sandbox` automatically. On the laptop, run `journalctl --user -b` as operator. Make sure `/usr/lib/odin/odin-launch` exists. |
| Map is blank in ODIN | Run `curl http://10.10.10.1:8000/services` on the tablet. Is `tiles/ao.mbtiles` present? Re-add the tile service in ODIN. |
| ISR console says NO LINK | Run `systemctl status edge-command` on the tablet and check that firewall port 8080 is open. |
| DDIL buttons error | Run `lsmod | grep netem`. If it's missing: `dnf install kernel-modules-extra && modprobe sch_netem`. Also check that `LAN_IFACE` in demo.env is correct. |
| `bootc switch` fails with a TLS error | The registry is HTTP. The base image ships `/etc/containers/registries.conf.d/50-edge-demo.conf`. Rebuild base if you changed `REGISTRY`. |
| Everything is broken 10 minutes before showtime | Play the backup video. Then fix edge-b by running `bootc rollback && reboot` from its console. |

## What's where
| Path | Purpose |
|---|---|
| `demo.env` | All IPs, names and versions |
| `base/` | Shared OS image: RHEL bootc, GDM autologin, GNOME Kiosk, SSH key, registry trust |
| `c2/` | ODINv2 role (AppImage unpacked into `/usr/lib/odin`) |
| `isr/` | ISR sensor console role (static web app, Leaflet vendored for offline use) |
| `dashboard/` | Edge Command server and UI (Python stdlib only). `DEMO_MOCK=1 python3 dashboard/server.py` runs it without hardware. |
| `tablet/` | Tablet setup script, registry/tile quadlets, dashboard unit |
| `iso/` | Kickstart template for unattended laptop installs |
| `tools/fetch-tiles.py` | Builds the offline `.mbtiles` from USGS National Map imagery (public domain) |
