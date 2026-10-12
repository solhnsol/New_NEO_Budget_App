import sys, re, collections
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
frames, binaries, threads, backtraces, times = {}, {}, {}, {}, {}
def binary_of(f):
    b = f.find('binary')
    if b is None: return None
    if b.get('id'): binaries[b.get('id')] = b.get('name')
    return binaries.get(b.get('id') or b.get('ref'))
def frame(f):
    if f.get('ref'): return frames[f.get('ref')]
    v = (f.get('name'), binary_of(f)); frames[f.get('id')] = v; return v
samples = []
for row in root.iter('row'):
    t = row.find('sample-time'); th = row.find('thread'); bt = row.find('tagged-backtrace')
    if t is None or th is None or bt is None: continue
    if t.get('id'): times[t.get('id')] = int(t.text)
    tv = times[t.get('ref')] if t.get('ref') else times[t.get('id')]
    if th.get('id'): threads[th.get('id')] = th.get('fmt')
    tname = threads.get(th.get('id') or th.get('ref'), '')
    if bt.get('ref'): stack = backtraces[bt.get('ref')]
    else:
        stack = [frame(f) for f in bt.findall('frame')]; backtraces[bt.get('id')] = stack
    samples.append((tv/1e6, tname, stack))
main = [s for s in samples if s[1].startswith('Main Thread')]
print('samples', len(samples), 'main', len(main))
# busy stretches on the main thread (1 ms sampling)
stretches, cur = [], []
for s in main:
    if cur and s[0] - cur[-1][0] > 1.6: stretches.append(cur); cur = []
    cur.append(s)
if cur: stretches.append(cur)
long = [st for st in stretches if st[-1][0]-st[0][0] >= 12]
print('stretches', len(stretches), '>=12ms', len(long))
APP = ('OnAllApp.debug.dylib', 'OnAllApp')
def cls(stack):
    libs = [b for _, b in stack if b]
    top = libs[0] if libs else '?'
    return top, set(libs)
total_top = collections.Counter(); total_incl = collections.Counter(); syms = collections.Counter()
for st in long:
    top = collections.Counter(); incl = collections.Counter(); sy = collections.Counter()
    for _, _, stack in st:
        t, libs = cls(stack); top[t] += 1
        for l in libs: incl[l] += 1
        # the first app frame, or the deepest named framework frame under a run-loop callout
        app = next((n for n, b in stack if b in APP), None)
        sy[app or next((n for n, b in stack if b and not n.startswith('0x')), '?')] += 1
    total_top.update(top); total_incl.update(incl); syms.update(sy)
    print(f"\n-- stretch at {st[0][0]:.0f} ms, {st[-1][0]-st[0][0]:.0f} ms, {len(st)} samples")
    print('   top lib:', ', '.join(f'{k} {v}' for k, v in top.most_common(6)))
    print('   in stack:', ', '.join(f'{k} {v}' for k, v in incl.most_common(10)))
    print('   first app frame / top named:', '; '.join(f'{k[:90]} {v}' for k, v in sy.most_common(6)))
print('\n== all long stretches: top lib', total_top.most_common(10))
print('== in stack', total_incl.most_common(14))
print('== first app frame / top named', [(k[:100], v) for k, v in syms.most_common(15)])

print('\n== samples with no app frame but $main, in long stretches (except the report): which SwiftUI work')
mid = collections.Counter(); leafsym = collections.Counter(); path = collections.Counter()
for st in long:
    if st[0][0] > 12000: continue
    for _, _, stack in st:
        appf = [n for n, b in stack if b in APP]
        if appf and appf[0] != 'static OnAllApp.$main()':
            # where in the app
            path['app: ' + appf[0][:80]] += 1; continue
        named = [(n, b) for n, b in stack if b in ('SwiftUI', 'SwiftUICore', 'UIKitCore', 'QuartzCore', 'UpdateCycle') and not n.startswith('0x')]
        leafsym[(named[0][1] + ' ' + named[0][0][:110]) if named else '?'] += 1
        # a recognisable phase: look for known markers from the root side
        names = ' | '.join(n for n, b in stack)
        for key in ['ViewGraph.updateOutputs', 'runTransaction', 'layoutSubviews', 'DisplayList', 'render', 'sizeThatFits', 'updateGraph', 'commit', 'CA::Transaction', 'Text', 'Layout', '_UIHostingView', 'beginTransaction', 'flushTransactions', 'GestureGraph', 'TimelineView', 'ForEach']:
            if key in names: mid[key] += 1
print('phase keys (samples whose stack has them):', mid.most_common(20))
print('leaf-most named framework frame:')
for k, v in leafsym.most_common(25): print('  ', v, k)
print('app frames (not $main):', path.most_common(12))
