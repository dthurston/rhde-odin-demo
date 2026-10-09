#!/usr/bin/env python3
"""Build an offline raster .mbtiles for the demo AO from USGS National Map imagery
(public domain). Run once while you still have internet; stdlib only.

  python3 tools/fetch-tiles.py                       # default: NTC Fort Irwin AO
  python3 tools/fetch-tiles.py --bbox -117.0,35.1,-116.3,35.5 --maxzoom 15

Two passes: a wide regional context at low zoom, then the AO in detail.
"""
import argparse
import math
import sqlite3
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SOURCES = {
    "imagery": "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}",
    "imagerytopo": "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}",
    "topo": "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
}


def tile_range(bbox, z):
    w, s, e, n = bbox

    def xy(lon, lat):
        lat = max(min(lat, 85.0511), -85.0511)
        x = int((lon + 180) / 360 * (1 << z))
        y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * (1 << z))
        return x, y

    x0, y0 = xy(w, n)
    x1, y1 = xy(e, s)
    return [(z, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bbox", default="-117.2,34.95,-116.15,35.6", help="AO w,s,e,n (default NTC Fort Irwin)")
    ap.add_argument("--context-bbox", default="-121,32.5,-112,37.5", help="regional context w,s,e,n")
    ap.add_argument("--context-maxzoom", type=int, default=10)
    ap.add_argument("--minzoom", type=int, default=4)
    ap.add_argument("--maxzoom", type=int, default=15)
    ap.add_argument("--source", choices=SOURCES, default="imagerytopo")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "tiles" / "ao.mbtiles"))
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()

    bbox = [float(v) for v in a.bbox.split(",")]
    ctx = [float(v) for v in a.context_bbox.split(",")]
    jobs = []
    for z in range(a.minzoom, a.maxzoom + 1):
        jobs += tile_range(ctx if z <= a.context_maxzoom else bbox, z)
    print(f"{len(jobs)} tiles -> {a.out}", flush=True)

    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(a.out)
    db.executescript("""
        create table if not exists metadata (name text primary key, value text);
        create table if not exists tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob);
        create unique index if not exists tile_index on tiles (zoom_level, tile_column, tile_row);
    """)
    have = set(db.execute("select zoom_level, tile_column, (1 << zoom_level) - 1 - tile_row from tiles"))
    todo = [j for j in jobs if j not in have]
    print(f"{len(have)} cached, {len(todo)} to fetch", flush=True)

    url = SOURCES[a.source]

    def fetch(job):
        z, x, y = job
        for attempt in range(4):
            try:
                req = urllib.request.Request(url.format(z=z, x=x, y=y),
                                             headers={"User-Agent": "rhde-odin-demo offline tile cache"})
                with urllib.request.urlopen(req, timeout=20) as r:
                    return job, r.read()
            except Exception as e:
                if getattr(e, "code", None) == 404:
                    return job, None
                time.sleep(1 + attempt * 2)
        return job, None

    done = failed = 0
    with ThreadPoolExecutor(a.workers) as pool:
        for (z, x, y), data in pool.map(fetch, todo):
            if data:
                db.execute("insert or replace into tiles values (?,?,?,?)", (z, x, (1 << z) - 1 - y, data))
            else:
                failed += 1
            done += 1
            if done % 100 == 0:
                db.commit()
                print(f"  {done}/{len(todo)}", flush=True)
    db.commit()

    fmt = "jpg"
    sample = db.execute("select tile_data from tiles limit 1").fetchone()
    if sample and sample[0][:4] == b"\x89PNG":
        fmt = "png"
    cx, cy = (bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2
    meta = {"name": Path(a.out).stem, "format": fmt, "type": "baselayer", "version": "1",
            "description": f"USGS National Map {a.source} (public domain) — offline demo AO",
            "attribution": "USGS The National Map", "minzoom": str(a.minzoom), "maxzoom": str(a.maxzoom),
            "bounds": ",".join(map(str, ctx)), "center": f"{cx},{cy},12"}
    db.executemany("insert or replace into metadata values (?,?)", meta.items())
    db.commit()
    size = Path(a.out).stat().st_size / 1e6
    print(f"done: {done - failed} tiles stored, {failed} missing, {size:.0f} MB", flush=True)
    return 0 if failed < len(todo) * 0.05 else 1


if __name__ == "__main__":
    sys.exit(main())
