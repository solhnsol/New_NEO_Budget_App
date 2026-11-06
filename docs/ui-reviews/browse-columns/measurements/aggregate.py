"""agg3.py '<glob>' [section-suffix]: aggregates BrowseProbe reports; with a suffix ('pass 1', 'pass 2') only the PROBE sections whose title ends with it."""
import sys, re, glob, collections
files = sorted(glob.glob(sys.argv[1])); want = sys.argv[2] if len(sys.argv) > 2 else None
frames = late = 0; worst = 0; marks = collections.Counter(); kinds = collections.Counter(); app = un = 0; turns = []
hap = []; turnat = collections.defaultdict(lambda: [0, 0.0, 0.0, []]); runs = 0; engine = []; extra = collections.Counter()
for f in files:
    text = open(f).read()
    for m in re.finditer(r'(engine runs|asked for by a frame|partitions held while a day was read|axis transitions|frames drawing a day from two decisions|where they differed) (\d+)', text): extra[m.group(1)] += int(m.group(2))
    sections = re.split(r'^PROBE ', text, flags=re.M)[1:]
    for sec in sections:
        title = sec.splitlines()[0]
        if want and not title.endswith(want): continue
        m = re.search(r'display frames n=(\d+) .*? max ([\d.]+) ms; nominal [\d.]+ ms; late \(>1.5x\) (\d+)', sec)
        if not m: continue
        runs += 1; frames += int(m.group(1)); late += int(m.group(3)); worst = max(worst, float(m.group(2)))
        for line in sec.splitlines():
            lm = re.match(r'  late \+([\d.]+)s ([\d.]+) ms: busiest turn ([\d.]+) ms \(app ([\d.]+), unattributed ([\d.]+)\) \[(.*)\] marks \[(.*)\]', line)
            if lm:
                app += float(lm.group(4)); un += float(lm.group(5)); turns.append(float(lm.group(3)))
                ms = set(lm.group(7).split()) or {'(none)'}
                for n in ms: marks[n] += 1
                for part in lm.group(6).split(', '):
                    if part and part != '—': k, v = part.rsplit(' ', 1); kinds[k] += float(v)
            hm = re.match(r'  haptics: n=\d+ .* max ([\d.]+) ms', line)
            if hm: hap.append(float(hm.group(1)))
            tm = re.match(r'  turn at (\w+): n=(\d+) mean ([\d.]+) p50 ([\d.]+) p99 ([\d.]+) max ([\d.]+)', line)
            if tm:
                e = turnat[tm.group(1)]; n = int(tm.group(2)); e[0] += n; e[1] += n * float(tm.group(3)); e[2] = max(e[2], float(tm.group(6))); e[3].append(float(tm.group(4)))
            em = re.match(r'  engine: n=(\d+)', line)
            if em: engine.append(int(em.group(1)))
lt = sorted(turns)
print(f"sections {runs}; frames {frames}; late {late} ({100*late/max(frames,1):.2f}%); worst {worst:.1f} ms; late turn ms p50 {lt[len(lt)//2] if lt else 0:.1f} max {lt[-1] if lt else 0:.1f}; sum of late turns {sum(lt):.0f} ms")
print(f"  late turns: app {app:.1f} ms, unattributed {un:.1f} ms; marks {dict(marks.most_common())}")
print(f"  app spans in late frames: { {k: round(v,1) for k, v in kinds.most_common(6)} }; haptics max per section {hap}; engine spans per section {engine}; {dict(extra)}")
print('  turn at mark (incl. next turn): ' + '; '.join(f"{k} n={v[0]} mean {v[1]/max(v[0],1):.1f} max {v[2]:.1f}" for k, v in sorted(turnat.items()) if k in ('boundary','dragBegan','rested','selectedDayChanged','dayLanded','released','pinchEnded')))
