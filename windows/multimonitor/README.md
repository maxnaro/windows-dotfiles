# Multimonitor

A Chocolatier-themed widget pack with a photo background and a bar on each
monitor. All bar variants share local Lucide SVG icons through `icons.js` and
`resources/icons.svg`; see `resources/lucide-LICENSE` for attribution.

## Widgets

### `wallpaper`

Coniston photo filling every monitor behind application windows. Uses the local
`modules/theme/assets/coniston.jpg` image (copied into the installed pack as `resources/coniston.jpg`) and passes desktop clicks through the native
window. This does not modify Windows wallpaper policies.

### `vanilla`

Plain and simple.

### `with-glazewm`

A click-through workspace indicator for [GlazeWM](https://github.com/glzr-io/glazewm), at the top of each monitor. It slides down from the top for 1.2 seconds when that monitor’s displayed workspace changes; subsequent switches restart the timer. It reserves no screen space and stays hidden at startup. One centered dock shows battery percentage with charge/charging icons on the left when available, workspaces anchored to the monitor center between content-sized sections separated by vertical dividers, and local time and date on the right, all vertically centered in a single row. Battery status snapshots the latest valid reading once per opening and is not redrawn by clock ticks. Background readings refresh every 10 seconds without restarting the provider; temporary errors retain the last valid reading. The dock attaches flush to the screen’s top edge, with flat tops, 12px rounded lower corners, no top border, 6px vertical and 12px horizontal padding, 22px square workspace highlights, an opaque chocolate background (`#2A201A`), a warm border (`#7D6959`), a soft black shadow, cream labels, and a teal focused-workspace marker. It prefers JetBrainsMono RunCat v7 at 12px. Workspace switching uses the existing GlazeWM shortcuts; the overlay does not intercept clicks.

### `with-komorebi`

For use with [Komorebi](https://github.com/LGUG2Z/komorebi).

The GlazeWM dock also appears while either Alt key is held, with all sections visible.
It hides 1.2 seconds after release. Workspaces stay at monitor center; side sections fit their content.

For a source-tree preview without running installation, copy `modules/theme/generated/desktop.css` to `windows/multimonitor/desktop.css` and `modules/theme/assets/coniston.jpg` to `windows/multimonitor/resources/coniston.jpg`. Setup performs both copies in the installed pack.
