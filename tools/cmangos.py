"""Read loot tables from a CMaNGOS classic-db full dump (ClassicDB_*.sql.gz, GPL-3.0) and turn them into
per-creature drop chances.

Loot rules (MaNGOS loot system):
  * ChanceOrQuestChance < 0      -> quest-only drop, ignored
  * groupid == 0                 -> independent roll with the given chance
  * groupid  > 0                 -> at most one item of the group drops: explicit chances first, entries with
                                    chance 0 share whatever is left of 100% equally
  * mincountOrRef < 0            -> reference to reference_loot_template[-mincountOrRef], processed `maxcount`
                                    times, each time with the entry's chance
Result: probability (in %) that one kill / one skinning yields at least one of the item.
"""
import gzip
import re
from collections import defaultdict

LOOT_TABLES = ('creature_loot_template', 'reference_loot_template', 'skinning_loot_template')


def _values(line, start):
    """Parse `(..),(..);` SQL tuples starting at index `start`."""
    rows, row, i, n = [], None, start, len(line)
    tok = []
    in_str = False
    while i < n:
        c = line[i]
        if in_str:
            if c == '\\':
                tok.append(line[i + 1]); i += 2; continue
            if c == "'":
                if i + 1 < n and line[i + 1] == "'":
                    tok.append("'"); i += 2; continue
                in_str = False
                i += 1
                continue
            tok.append(c)
            i += 1
            continue
        if c == "'":
            in_str = True
            tok = [] if not tok else tok
            row_is_str = True
        elif c == '(':
            row, tok = [], []
        elif c == ',' or c == ')':
            if row is not None:
                v = ''.join(tok).strip()
                row.append(_conv(v))
                tok = []
                if c == ')':
                    rows.append(row)
                    row = None
        elif c == ';':
            break
        else:
            if row is not None:
                tok.append(c)
        i += 1
    return rows


def _conv(v):
    if v == 'NULL':
        return None
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return v


class Loot:
    def __init__(self, path):
        cols, rows = {}, {t: [] for t in LOOT_TABLES + ('creature_template', 'item_template')}
        cur = None
        with gzip.open(path, 'rt', encoding='utf-8', errors='replace') as f:
            for line in f:
                m = re.match(r'CREATE TABLE `(\w+)`', line)
                if m:
                    cur = m.group(1) if m.group(1) in rows else None
                    if cur:
                        cols[cur] = []
                    continue
                if cur:
                    m = re.match(r'\s*`(\w+)`', line)
                    if m:
                        cols[cur].append(m.group(1))
                        continue
                    if line.startswith(')'):
                        cur = None
                if line.startswith('INSERT INTO `'):
                    t = line[13:line.index('`', 13)]
                    if t in rows:
                        rows[t].extend(_values(line, line.index('VALUES') + 6))
        ct = cols['creature_template']
        ie, il, isk, it = ct.index('Entry'), ct.index('LootId'), ct.index('SkinningLootId'), ct.index('CreatureType')
        self.creature = {r[ie]: (r[il], r[isk], r[it]) for r in rows['creature_template']}
        # items: {entry: (quality, bonding)}; bonding 1 = bind on pickup, 4 = quest item
        itc = cols['item_template']
        ii, iq, ib = itc.index('entry'), itc.index('Quality'), itc.index('bonding')
        self.items = {r[ii]: (r[iq], r[ib]) for r in rows['item_template']}
        self.tables = {}
        for t in LOOT_TABLES:
            by = defaultdict(list)
            for r in rows[t]:
                # entry, item, chance, groupid, mincountOrRef, maxcount
                by[r[0]].append((r[1], float(r[2]), r[3], r[4], r[5]))
            self.tables[t] = by
        self._memo = {}

    def probs(self, table, entry, depth=0):
        """{itemID: probability 0..1 of at least one} for one roll of a loot template."""
        key = (table, entry)
        if key in self._memo:
            return self._memo[key]
        out = {}
        if depth > 6 or not entry:
            return out

        def add(item, p):
            if p <= 0:
                return
            q = out.get(item, 0.0)
            out[item] = 1 - (1 - q) * (1 - min(1.0, p))

        def apply(row, p_entry):
            item, chance, group, mref, maxc = row
            if mref < 0:
                sub = self.probs('reference_loot_template', -mref, depth + 1)
                times = max(1, maxc or 1)
                for it, pp in sub.items():
                    add(it, 1 - (1 - p_entry * pp) ** times)
            else:
                add(item, p_entry)

        groups = defaultdict(list)
        for row in self.tables[table].get(entry, ()):
            if row[1] < 0:          # quest-only chance
                continue
            if row[2]:
                groups[row[2]].append(row)
            else:
                apply(row, row[1] / 100.0)
        for g in groups.values():
            explicit = sum(r[1] for r in g if r[1] > 0)
            equal = [r for r in g if r[1] == 0]
            share = max(0.0, 100.0 - explicit) / len(equal) if equal else 0.0
            for r in g:
                apply(r, (r[1] if r[1] > 0 else share) / 100.0)
        self._memo[key] = out
        return out

    def creature_probs(self, npc):
        """(loot {item: %}, skinning {item: %}, creatureType) for a creature entry."""
        c = self.creature.get(npc)
        if not c:
            return {}, {}, None
        loot = self.probs('creature_loot_template', c[0]) if c[0] else {}
        skin = self.probs('skinning_loot_template', c[1]) if c[1] else {}
        return ({i: p * 100 for i, p in loot.items()}, {i: p * 100 for i, p in skin.items()}, c[2])
