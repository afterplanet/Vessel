#!/usr/bin/env python3
"""Expands <use> references in SVG flags, which AppKit's SVG renderer silently drops."""
import copy, glob, sys
import xml.etree.ElementTree as ET

SVG = "http://www.w3.org/2000/svg"
XLINK = "http://www.w3.org/1999/xlink"
ET.register_namespace("", SVG)
ET.register_namespace("xlink", XLINK)

def flatten(path):
    tree = ET.parse(path)
    root = tree.getroot()
    ids = {e.get("id"): e for e in root.iter() if e.get("id")}
    changed = False
    for _ in range(12):  # references can nest
        parents = {c: p for p in root.iter() for c in p}
        uses = [e for e in root.iter() if e.tag == f"{{{SVG}}}use"]
        if not uses:
            break
        for u in uses:
            ref = (u.get(f"{{{XLINK}}}href") or u.get("href") or "").lstrip("#")
            target = ids.get(ref)
            parent = parents[u]
            at = list(parent).index(u)
            parent.remove(u)
            changed = True
            if target is None:
                continue
            g = ET.Element(f"{{{SVG}}}g")
            for k, v in u.attrib.items():
                if k not in (f"{{{XLINK}}}href", "href", "x", "y", "width", "height"):
                    g.set(k, v)
            x, y = u.get("x", "0"), u.get("y", "0")
            if x != "0" or y != "0":
                g.set("transform", f"{g.get('transform', '')} translate({x} {y})".strip())
            clone = copy.deepcopy(target)
            for e in clone.iter():
                e.attrib.pop("id", None)
            g.append(clone)
            parent.insert(at, g)
    if changed:
        tree.write(path, encoding="unicode", xml_declaration=False)
    return changed

n = sum(flatten(p) for p in glob.glob(sys.argv[1] + "/*.svg"))
print(f"flattened {n} flags")
