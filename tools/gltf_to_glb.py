#!/usr/bin/env python3
"""Packs a glTF folder (scene.gltf, scene.bin, textures) into one GLB.
Usage: gltf_to_glb.py scene.gltf out.glb [max_texture_size]
Textures over the size limit are scaled down, since these ship inside the app."""
import json, os, struct, subprocess, sys, tempfile

src, out = sys.argv[1], sys.argv[2]
base = os.path.dirname(src)
j = json.load(open(src, encoding="utf8"))
blobs, offset = [], 0
remap = {}


def add(data):
    global offset
    start = offset
    blobs.append(data)
    pad = (4 - len(data) % 4) % 4
    blobs.append(b"\0" * pad)
    offset += len(data) + pad
    return start


for i, b in enumerate(j.get("buffers", [])):
    remap[i] = add(open(os.path.join(base, b["uri"]), "rb").read())
for v in j.get("bufferViews", []):
    v["byteOffset"] = v.get("byteOffset", 0) + remap[v.get("buffer", 0)]
    v["buffer"] = 0
for im in j.get("images", []):
    if "uri" in im:
        path = os.path.join(base, im.pop("uri").replace("%20", " "))
        mime = "image/png" if path.lower().endswith("png") else "image/jpeg"
        if len(sys.argv) > 3:
            info = subprocess.check_output(["sips", "-g", "hasAlpha", path], text=True)
            keep_alpha = "hasAlpha: yes" in info and mime == "image/png"
            small = tempfile.mktemp(suffix=".png" if keep_alpha else ".jpg")
            cmd = ["sips", "-Z", sys.argv[3]] + ([] if keep_alpha else ["-s", "format", "jpeg", "-s", "formatOptions", "72"])
            subprocess.check_call(cmd + [path, "--out", small], stdout=subprocess.DEVNULL)
            path, mime = small, "image/png" if keep_alpha else "image/jpeg"
        data = open(path, "rb").read()
        im["mimeType"] = mime
        im["bufferView"] = len(j["bufferViews"])
        j["bufferViews"].append({"buffer": 0, "byteOffset": add(data), "byteLength": len(data)})
j["buffers"] = [{"byteLength": offset}]
text = json.dumps(j, separators=(",", ":")).encode()
text += b" " * ((4 - len(text) % 4) % 4)
binary = b"".join(blobs)
with open(out, "wb") as f:
    f.write(b"glTF" + struct.pack("<II", 2, 12 + 8 + len(text) + 8 + len(binary)))
    f.write(struct.pack("<I", len(text)) + b"JSON" + text)
    f.write(struct.pack("<I", len(binary)) + b"BIN\0" + binary)
