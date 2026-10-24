import sys, re, glob, collections
files = sorted(glob.glob(sys.argv[1]))
frames = late = 0; maxi = 0; marks = collections.Counter(); kinds = collections.Counter(); app = un = 0; turns = []; haptic_max = 0; first_pass = 0
for f in files:
    t = open(f).read()
    m = re.search(r'display frames n=(\d+) .*? max ([\d.]+) ms; nominal [\d.]+ ms; late \(>1.5x\) (\d+)', t)
    if not m: print('no probe in', f); continue
    frames += int(m.group(1)); late += int(m.group(3)); maxi = max(maxi, float(m.group(2)))
    for line in t.splitlines():
        lm = re.match(r'  late \+([\d.]+)s ([\d.]+) ms: busiest turn ([\d.]+) ms \(app ([\d.]+), unattributed ([\d.]+)\) \[(.*)\] marks \[(.*)\]', line)
        if lm:
            app += float(lm.group(4)); un += float(lm.group(5)); turns.append(float(lm.group(3)))
            for name in set(lm.group(7).split()): marks[name] += 1
            if not lm.group(7).strip(): marks['(none)'] += 1
            for part in lm.group(6).split(', '):
                if part and part != '—': k, v = part.rsplit(' ', 1); kinds[k] += float(v)
        hm = re.match(r'  haptics: .* max ([\d.]+) ms', line)
        if hm: haptic_max = max(haptic_max, float(hm.group(1)))
print(f"runs {len(files)}; frames {frames}; late {late} ({100*late/max(frames,1):.2f}%); worst frame {maxi:.1f} ms; busiest late turns: {sorted(turns)}")
print(f"late turns summed: app spans {app:.1f} ms, unattributed {un:.1f} ms ({100*un/max(app+un,1e-9):.0f}%)")
print("late frames by nearby mark:", dict(marks.most_common()))
print("app spans in late frames (inclusive ms):", {k: round(v,1) for k, v in kinds.most_common(8)})
print(f"haptics max {haptic_max:.1f} ms")
