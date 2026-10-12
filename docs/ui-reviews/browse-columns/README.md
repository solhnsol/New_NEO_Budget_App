# Browse fixed grid: one decision per column while the days move, pinch settle (phase 2B-2)

Design and numbers: `docs/development/phase2b2-columns-and-causes.md`.

All on the iPhone 18 Pro simulator, `-demo -browse-temporal`; "old" is the 2B-1 rule switched back on in the same build (`-probe-legacy-columns -probe-legacy-zoom-key`).

| file | what |
|---|---|
| `old-dense-0.45.png`, `old-dense-0.55.png` | `-demo-dense`, the days held at 0.45 / 0.55 of a day (`-browse-temporal-script hold`). Old rule: past the halfway line the leaving day is drawn without the engine — its cards lose their transaction rows ("…00원") and the green card its colour bar, in one frame |
| `new-dense-0.45.png`, `new-dense-0.55.png` | new rule: the leaving day keeps the decision it has at rest; nothing changes at the halfway line |
| `old-trans-0.55.png`, `new-trans-0.55.png` | `-demo-trans` (transaction-heavy demo), 0.55 |
| `old-text-xxxl-0.6.png`, `new-text-xxxl-0.6.png` | accessibility XXXL text, 0.6 (the fixed grid's large-text limits from 1B remain) |
| `swipes-old.mp4`, `swipes-new.mp4` | the `swipes` script: slow drags across the halfway line and back, a flick, a catch mid-flight, a reversal mid-flight, twice |
| `rubber-new.mp4` | the `rubber` script: past 8× and let go (eases back to 8×), below 1× and let go, twice — no decision is made for the easing frames |

`measurements/`: `y-*` the H1/H2/H3 experiments (swipes ×5 per variant, per pass), `ba-old-*` / `ba-new-*` before/after (swipes, days, zoom, rubber ×5), `SUMMARY.txt` aggregated by `aggregate.py '<glob>' ['pass 1'|'pass 2']`.
