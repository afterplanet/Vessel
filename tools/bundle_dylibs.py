#!/usr/bin/env python3
"""Copies every non-system library a program needs next to it, and rewrites the references between them."""
import os
import re
import shutil
import subprocess
import sys

SYSTEM = ("/usr/lib/", "/System/")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def references(path):
    lines = run("otool", "-L", path).splitlines()[1:]
    return [line.strip().split(" (")[0] for line in lines]


def rpaths(path):
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset", run("otool", "-l", path))


def resolve(ref, owner, origin, search):
    """A copy's relative search paths still mean where it came from, so they're read against that."""
    if ref.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
        name = ref.split("/", 1)[1]
        home = os.path.dirname(origin)
        for folder in [home, *rpaths(owner), *search]:
            folder = folder.replace("@loader_path", home).replace("@executable_path", home)
            candidate = os.path.join(folder, name)
            if os.path.exists(candidate):
                return candidate
        return None
    return ref if os.path.exists(ref) else None


def main():
    args = sys.argv[1:]
    # "--also <file>" adds a plugin the program loads itself. It sits elsewhere in the bundle but runs in
    # the program's process, so it finds the shared libraries the same way the program does.
    also = [args[i + 1] for i, a in enumerate(args) if a == "--also"]
    args = [a for i, a in enumerate(args) if a != "--also" and (i == 0 or args[i - 1] != "--also")]
    exe, libs, *search = args
    copied = {}
    missing = []
    queue = [(root, "@executable_path/../libs/", root) for root in [exe, *also]]
    for plugin in also:
        subprocess.run(["install_name_tool", "-id", "@loader_path/" + os.path.basename(plugin), plugin], check=True, capture_output=True)
    while queue:
        path, prefix, origin = queue.pop()
        changes = []
        for ref in references(path):
            if ref.startswith(SYSTEM):
                continue
            real = resolve(ref, path, origin, search + list(copied.values()))
            if real is None:
                if os.path.basename(ref) in copied:
                    changes += ["-change", ref, prefix + os.path.basename(ref)]
                else:
                    missing.append(f"{ref} (from {os.path.basename(path)})")
                continue
            name = os.path.basename(ref)
            changes += ["-change", ref, prefix + name]
            if name not in copied:
                target = os.path.join(libs, name)
                shutil.copy2(os.path.realpath(real), target)
                os.chmod(target, 0o755)
                copied[name] = target
                subprocess.run(["install_name_tool", "-id", "@loader_path/" + name, target], check=True, capture_output=True)
                queue.append((target, "@loader_path/", os.path.realpath(real)))
        for rpath in rpaths(path):
            subprocess.run(["install_name_tool", "-delete_rpath", rpath, path], check=False, capture_output=True)
        if changes:
            subprocess.run(["install_name_tool", *changes, path], check=True, capture_output=True)
    for path in [*copied.values(), *also, exe]:
        subprocess.run(["codesign", "--force", "--sign", "-", path], check=True, capture_output=True)
    print(f"bundled {len(copied)} libraries")
    if missing:
        print("MISSING:\n  " + "\n  ".join(sorted(set(missing))))
        sys.exit(1)
    # Nothing may still point outside the bundle, or it would only work on this Mac.
    leaks = [f"{os.path.basename(p)} -> {r}" for p in [exe, *also, *copied.values()] for r in references(p)
             if not r.startswith(SYSTEM) and not r.startswith(("@loader_path/", "@executable_path/"))]
    if leaks:
        print("STILL OUTSIDE:\n  " + "\n  ".join(leaks[:40]))
        sys.exit(1)


main()
