#!/usr/bin/env python3
"""Builds Resources/places.tsv from GeoNames cities5000 (CC BY 4.0) for offline nearest-town lookups.
Usage: build_places.py cities5000.txt admin1CodesASCII.txt out.tsv"""
import sys

admin = {}
for line in open(sys.argv[2], encoding="utf8"):
    f = line.rstrip("\n").split("\t")
    admin[f[0]] = f[1]

rows = 0
with open(sys.argv[3], "w", encoding="utf8") as out:
    for line in open(sys.argv[1], encoding="utf8"):
        f = line.rstrip("\n").split("\t")
        name, lat, lon, cc, a1 = f[1], float(f[4]), float(f[5]), f[8], f[10]
        out.write(f"{lat:.3f}\t{lon:.3f}\t{name}\t{admin.get(cc + '.' + a1, '')}\n")
        rows += 1
print(rows)
