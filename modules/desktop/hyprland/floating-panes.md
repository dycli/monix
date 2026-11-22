# Floating panes

Super+Alt+A enables floating panes on the current workspace. Existing windows
start in the full frame. New windows use the most recently focused window's
frame, taking the opposite half when it is empty. Hidden and pinned windows
are excluded. Selecting hy3, scrolling or dwindle tiles the workspace again.

Frames use the monitor's logical dimensions and reserved bar space, with a
12-pixel outer margin and gutter. Panes are derived from rectangles with at
least 80% mutual overlap. No window membership list is retained.

| Keys | Floating panes | Tiling layouts |
| --- | --- | --- |
| Super+Left / Right | Left / right half | Move window left / right |
| Super+Up | Upper quarter from a left/right half; otherwise full | Move window up |
| Super+Down | Lower quarter from a left/right half; otherwise bottom half | Move window down |
| Super+Alt+Up / Down | Top / bottom half | Unused |
| Super+Tab / Shift+Tab | Next / previous pane; rotate stack if only one pane | Next / previous workspace window |
| Super+grave / Shift+grave | Next / previous window in current stack | Next / previous workspace window |
| Super+H/J/K/L | Focus left/down/up/right | Focus left/down/up/right |
| Super+Shift+H/J/K/L | Same as Super+arrows | Move left/down/up/right |

Pane order follows Calmarchy: displays top to bottom, then left to right;
within a display, left to right, then top to bottom. Cycling stays within the
current workspace. Each pane selects its most recently focused member. Stack
rotation uses stable address order so repeated forward and backward steps
remain reversible despite changes to focus history.

The half-to-quarter sequence follows Windows Snap. Super+Alt+Up/Down supplies
Windows' top/bottom-half shortcuts. Super+grave follows the Mac convention for
cycling related windows. Super+Shift+arrow bindings are removed because
Super+arrow now performs their movement action.

Reference: https://github.com/bradgessler/calmarchy (omarchy-snap,
omarchy-panel-place, omarchy-pane-cycle and omarchy-stack-cycle).
