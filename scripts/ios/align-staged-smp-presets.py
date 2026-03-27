#!/usr/bin/env python3

import pathlib
import shutil
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
LIB_DIRS = [
    ROOT / "apps/ios/Libraries/ios",
    ROOT / "apps/ios/Libraries/sim",
]

REPLACEMENTS = [
    (
        b"smp://0000000000000000000000000000000000000000006=@smp1.example.org",
        b"smp://0000000000000000000000000000000000000000015=@smp1.example.org",
    ),
    (
        b"smp://0000000000000000000000000000000000000000005=@smp2.example.org",
        b"smp://0000000000000000000000000000000000000000006=@smp2.example.org",
    ),
]


def patch_archive(path: pathlib.Path) -> int:
    data = path.read_bytes()
    original = data

    for old, new in REPLACEMENTS:
        if len(old) != len(new):
            raise ValueError(f"Length mismatch for {old!r} -> {new!r}")
        data = data.replace(old, new)

    if data == original:
        return 0

    backup = path.with_name(path.name + ".bak-smpalign")
    if not backup.exists():
        shutil.copy2(path, backup)

    path.chmod(path.stat().st_mode | 0o200)
    path.write_bytes(data)
    path.chmod(path.stat().st_mode & ~0o222)
    return 1


def main() -> int:
    patched = 0
    for lib_dir in LIB_DIRS:
        for archive in sorted(lib_dir.glob("libHS*.a")):
            patched += patch_archive(archive)
    print(f"Patched {patched} staged Haskell archives")
    return 0


if __name__ == "__main__":
    sys.exit(main())
