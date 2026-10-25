"""
build_pack.py  --  minimal PFH5 .pack writer for Total War: Warhammer III mods.

The format (little-endian), verified against vanilla packs and against a
RPFM-produced workshop mod pack:

  Header (28 bytes):
    char[4]  magic                     = "PFH5"
    uint32   bitmask                   = pack type in low bits (3 = Mod),
                                         plus optional flags in higher bits
    uint32   pack_file_count           (dependency count)
    uint32   pack_file_index_size
    uint32   file_count
    uint32   file_index_size
    uint32   timestamp                 (unix seconds)

  Then, if pack_file_count > 0, the dependency path strings (each
  NUL-terminated, backslash separated).

  Then the file index, one entry per file, sorted by path (case-insensitive):
    uint32   size                      (stored/compressed size)
    uint8    is_compressed             (0 = stored, 1 = zstd)
    char[]   path                      (backslash separated, NUL-terminated)

  Then the raw file data, concatenated in the same order as the index.

Usage:
    python build_pack.py <src_dir> <out_pack> [--type N]
"""

import os
import struct
import sys
import time

PACK_TYPE_MOD = 3


def collect_files(src_root):
    """Return [(rel_path_with_backslashes, data_bytes)] sorted by path."""
    files = []
    for dirpath, _dirnames, filenames in os.walk(src_root):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, src_root).replace("\\", "/").replace("/", "\\")
            with open(full, "rb") as f:
                data = f.read()
            files.append((rel, data))
    files.sort(key=lambda x: x[0].lower())
    return files


def build_pack(src_root, out_pack, pack_type=PACK_TYPE_MOD, dependencies=None,
               timestamp=None):
    files = collect_files(src_root)

    # ---- file index ------------------------------------------------------
    index = bytearray()
    for rel, data in files:
        index += struct.pack("<I", len(data))     # size
        index += b"\x00"                          # is_compressed = 0 (stored)
        index += rel.encode("utf-8") + b"\x00"    # path, NUL terminated

    deps = dependencies or []
    dep_bytes = bytearray()
    for d in deps:
        dep_bytes += d.encode("utf-8") + b"\x00"

    file_count = len(files)
    file_index_size = len(index)
    pack_file_count = len(deps)
    pack_file_index_size = len(dep_bytes)
    if timestamp is None:
        timestamp = int(time.time())

    # ---- header ----------------------------------------------------------
    header = bytearray()
    header += b"PFH5"
    header += struct.pack("<I", pack_type)
    header += struct.pack("<I", pack_file_count)
    header += struct.pack("<I", pack_file_index_size)
    header += struct.pack("<I", file_count)
    header += struct.pack("<I", file_index_size)
    header += struct.pack("<I", timestamp)

    os.makedirs(os.path.dirname(os.path.abspath(out_pack)) or ".", exist_ok=True)
    with open(out_pack, "wb") as f:
        f.write(header)
        f.write(dep_bytes)
        f.write(index)
        for _rel, data in files:
            f.write(data)

    print("built %s" % out_pack)
    print("  pack type      : %d" % pack_type)
    print("  dependencies   : %d" % pack_file_count)
    print("  files          : %d" % file_count)
    print("  header bytes   : %d" % len(header))
    print("  index bytes    : %d" % file_index_size)
    print("  total bytes    : %d" % os.path.getsize(out_pack))
    for rel, data in files:
        print("  %9d  %s" % (len(data), rel))
    return out_pack


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    src_root = sys.argv[1]
    out_pack = sys.argv[2]
    pack_type = PACK_TYPE_MOD
    if "--type" in sys.argv:
        pack_type = int(sys.argv[sys.argv.index("--type") + 1])

    build_pack(src_root, out_pack, pack_type=pack_type)


if __name__ == "__main__":
    main()
