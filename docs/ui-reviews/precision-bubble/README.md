# Precision bubble (Phase 3A)

`-demo -precision-bubble-fixture <scenario>` on an iPhone 18 Pro simulator (iOS 27). The fixture is the real `PinchZoomScrollView` with one synthetic event; the bubble sits over it, kept in place by `PrecisionAnchorTracker`.

| file | what |
|---|---|
| 01-center | 1×, start handle, bubble above |
| 02-top | 3×, start handle 30pt from the top → flips below |
| 03-bottom | 3×, end handle 30pt from the bottom → flips above |
| 04-left | card at the left edge, end handle: bubble clamped, arrow follows the handle |
| 05-right | card at the right edge, start handle |
| 06-offscreen | handle scrolled above the viewport → pinned to the top with ⌃ |
| 07-ax3 | Accessibility 3 text: steps stacked, still above |
| 08-limit | end 15 min after start: −15 off |
| 09-dark-limit | the same in dark appearance |
| 10-after-flick-scroll | real flick: the bubble flipped below with the arrow on the handle |
| 11-step-same-frame | screenshot straight after +15: the bubble already moved with the card |
| 12-mid-pinch-8x | real pinch past 8× (rubber band): the arrow stays on the handle |
