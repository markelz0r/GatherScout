"""Minimal reader for QuestieDB baked TOC (Forever). Usage: python -I qdb.py <toc> <outdir>
Dumps items/objects/npcs scalar rows + selected table fields to JSON."""
import sys, re, base64, zlib, json, struct, os

def cbor_decode(b, i=0):
    ib = b[i]; i += 1
    mt, ai = ib >> 5, ib & 31
    def read_len(ai, i):
        if ai < 24: return ai, i
        if ai == 24: return b[i], i + 1
        if ai == 25: return struct.unpack('>H', b[i:i+2])[0], i + 2
        if ai == 26: return struct.unpack('>I', b[i:i+4])[0], i + 4
        if ai == 27: return struct.unpack('>Q', b[i:i+8])[0], i + 8
        if ai == 31: return None, i
        raise ValueError('bad ai %d' % ai)
    if mt == 7:
        if ai == 20: return False, i
        if ai == 21: return True, i
        if ai in (22, 23): return None, i
        if ai == 25:
            return struct.unpack('>e', b[i:i+2])[0], i + 2
        if ai == 26: return struct.unpack('>f', b[i:i+4])[0], i + 4
        if ai == 27: return struct.unpack('>d', b[i:i+8])[0], i + 8
        if ai == 31: return 'BREAK', i
        return ('simple', ai), i
    n, i = read_len(ai, i)
    if mt == 0: return n, i
    if mt == 1: return -1 - n, i
    if mt in (2, 3):
        if n is None:
            parts = []
            while b[i] != 0xff:
                p, i = cbor_decode(b, i); parts.append(p)
            i += 1
            v = b''.join(p if isinstance(p, bytes) else p.encode() for p in parts)
        else:
            v = b[i:i+n]; i += n
        if mt == 3: v = v.decode('utf-8', 'replace')
        return v, i
    if mt == 4:
        arr = []
        if n is None:
            while b[i] != 0xff:
                v, i = cbor_decode(b, i); arr.append(v)
            i += 1
        else:
            for _ in range(n):
                v, i = cbor_decode(b, i); arr.append(v)
        return arr, i
    if mt == 5:
        d = {}
        cnt = 0
        while True:
            if n is None:
                if b[i] == 0xff: i += 1; break
            elif cnt >= n: break
            k, i = cbor_decode(b, i); v, i = cbor_decode(b, i)
            if isinstance(k, list): k = tuple(k)
            d[k] = v; cnt += 1
        return d, i
    if mt == 6:
        return cbor_decode(b, i)
    raise ValueError(mt)

def dec(s):
    return cbor_decode(base64.b64decode(s))[0]

def main():
    toc, out = sys.argv[1], sys.argv[2]
    kv = {}
    rx = re.compile(r'^## (X-[^:]+): ?(.*)$')
    with open(toc, encoding='utf-8') as f:
        for line in f:
            m = rx.match(line.rstrip('\n'))
            if m: kv[m.group(1)] = m.group(2)
    def get(key):
        v = kv.get(key)
        if v is None: return None
        m = re.match(r'^~(\d+)~$', v)
        if m:
            v = ''.join(kv[key + '-' + str(p)] for p in range(1, int(m.group(1)) + 1))
        return v
    res = {}
    for ent, fields in (('Item', {2: 'npcDrops', 3: 'objectDrops'}),
                        ('Object', {4: 'spawns'}),
                        ('Npc', {7: 'spawns'})):
        raw = base64.b64decode(get('X-%s-IDS' % ent))
        for wbits in (15, -15, 31):
            try:
                ids = cbor_decode(zlib.decompress(raw, wbits))[0]; break
            except Exception:
                continue
        rows = {}
        for eid in ids:
            s = get('X-%s-%d-S' % (ent, eid))
            if s is None: continue
            row = dec(s)
            rec = {'S': {str(k): v for k, v in row.items()} if isinstance(row, dict) else row}
            for fi, fname in fields.items():
                t = get('X-%s-%d-%d' % (ent, eid, fi))
                if t is not None:
                    try:
                        val = dec(t)
                        if isinstance(val, dict):
                            val = {str(k): v for k, v in val.items()}
                        rec[fname] = val
                    except Exception as e:
                        rec[fname] = 'ERR ' + str(e)
            rows[eid] = rec
        res[ent] = rows
        print(ent, len(ids), 'ids', len(rows), 'rows')
    os.makedirs(out, exist_ok=True)
    for ent, rows in res.items():
        with open(os.path.join(out, ent.lower() + 's.json'), 'w', encoding='utf-8') as f:
            json.dump(rows, f, ensure_ascii=False, default=lambda o: o.hex() if isinstance(o, bytes) else str(o))

main()
