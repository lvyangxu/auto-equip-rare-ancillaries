import sys

HAS_INDEX_WITH_TIMESTAMPS = 0x40


def read_index(path):
    f = open(path, 'rb')
    magic = f.read(4)
    assert magic == b'PFH5', magic
    bitmask = int.from_bytes(f.read(4), 'little')
    packs_count = int.from_bytes(f.read(4), 'little')
    packs_index_size = int.from_bytes(f.read(4), 'little')
    files_count = int.from_bytes(f.read(4), 'little')
    files_index_size = int.from_bytes(f.read(4), 'little')
    f.read(4)  # timestamp
    idx = f.read(packs_index_size + files_index_size)
    pos = 0
    for _ in range(packs_count):
        pos = idx.index(b'\x00', pos) + 1
    entries = []
    for _ in range(files_count):
        size = int.from_bytes(idx[pos:pos + 4], 'little')
        pos += 4
        if bitmask & HAS_INDEX_WITH_TIMESTAMPS:
            pos += 4
        comp = idx[pos]
        pos += 1
        end = idx.index(b'\x00', pos)
        name = idx[pos:end].decode('utf-8', 'replace')
        pos = end + 1
        entries.append((name, size, comp))
    return entries


if __name__ == '__main__':
    path = sys.argv[1]
    needle = sys.argv[2].lower() if len(sys.argv) > 2 else ''
    entries = read_index(path)
    print('total files:', len(entries))
    for name, size, comp in entries:
        if needle in name.lower():
            print('%9d comp=%d  %s' % (size, comp, name))
