-- Calmarchy's fixed frames leave room for bars and a 12-pixel gutter.
local enabled = {}
local gap = 12
floating_panes = {}

local function windows(workspace)
  local result = {}
  for _, window in ipairs(hl.get_windows({ workspace = workspace, mapped = true })) do
    if not window.hidden and not window.pinned then table.insert(result, window) end
  end
  table.sort(result, function(a, b) return a.focus_history_id < b.focus_history_id end)
  return result
end

local function frames(monitor)
  local r, p, s = monitor.reserved, monitor.position, monitor.mode
  local x, y = p.x + r.left + gap, p.y + r.top + gap
  local w, h = s.width - r.left - r.right - 2 * gap, s.height - r.top - r.bottom - 2 * gap
  local cw, ch = math.floor((w - gap) / 2), math.floor((h - gap) / 2)
  local right, bottom = x + cw + gap, y + ch + gap
  return {
    full = {x, y, w, h}, left = {x, y, cw, h}, right = {right, y, w - cw - gap, h},
    top = {x, y, w, ch}, bottom = {x, bottom, w, h - ch - gap},
    tl = {x, y, cw, ch}, tr = {right, y, w - cw - gap, ch},
    bl = {x, bottom, cw, h - ch - gap}, br = {right, bottom, w - cw - gap, h - ch - gap},
  }
end

local function rectangle(window)
  return {window.at.x, window.at.y, window.size.x, window.size.y}
end

local function frame_name(window)
  local rect = rectangle(window)
  for name, frame in pairs(frames(window.monitor)) do
    local matches = true
    for i = 1, 4 do if math.abs(rect[i] - frame[i]) > 6 then matches = false end end
    if matches then return name end
  end
end

local function overlap(a, b)
  return math.max(0, math.min(a[1] + a[3], b[1] + b[3]) - math.max(a[1], b[1]))
    * math.max(0, math.min(a[2] + a[4], b[2] + b[4]) - math.max(a[2], b[2]))
end

local function snap(window, name)
  local f = frames(window.monitor)[name]
  hl.dispatch(hl.dsp.window.fullscreen({action = "unset", window = window}))
  hl.dispatch(hl.dsp.window.float({action = "enable", window = window}))
  hl.dispatch(hl.dsp.window.resize({x = f[3], y = f[4], relative = false, window = window}))
  hl.dispatch(hl.dsp.window.move({x = f[1], y = f[2], relative = false, window = window}))
end

local function place(window)
  local previous
  local others = windows(window.workspace)
  for _, candidate in ipairs(others) do
    if candidate ~= window and candidate.monitor == window.monitor then previous = candidate; break end
  end
  local name = previous and frame_name(previous) or "full"
  name = name or "full"
  local opposite = ({left = "right", right = "left"})[name]
  if opposite then
    local f, occupied = frames(window.monitor)[opposite], false
    for _, candidate in ipairs(others) do
      if candidate ~= window and overlap(rectangle(candidate), f) > 0.1 * f[3] * f[4] then occupied = true end
    end
    if not occupied then name = opposite end
  end
  snap(window, name)
end

function floating_panes.active()
  local workspace = hl.get_active_workspace()
  return workspace and enabled[workspace.addressable_name] == true
end

function floating_panes.enable()
  local workspace = hl.get_active_workspace()
  if not workspace then return end
  enabled[workspace.addressable_name] = true
  -- Leave scrolling's visual profile when entering a floating workspace.
  hl.config({general = {layout = "dwindle"}})
  for _, window in ipairs(windows(workspace)) do snap(window, "full") end
end

function floating_panes.tile(layout)
  local workspace = hl.get_active_workspace()
  if workspace and enabled[workspace.addressable_name] then
    enabled[workspace.addressable_name] = nil
    for _, window in ipairs(windows(workspace)) do
      hl.dispatch(hl.dsp.window.float({action = "disable", window = window}))
    end
  end
  hl.config({general = {layout = layout}})
end

function floating_panes.snap(name)
  local window = hl.get_active_window()
  if window then snap(window, name) end
end

function floating_panes.move(direction)
  local window = hl.get_active_window()
  if not window then return end
  local name = frame_name(window)
  local side = ({left = "l", right = "r"})[name]
  if direction == "l" then name = "left"
  elseif direction == "r" then name = "right"
  elseif direction == "u" then name = side and ("t" .. side) or "full"
  else name = side and ("b" .. side) or "bottom" end
  snap(window, name)
end

local function focus(window)
  hl.dispatch(hl.dsp.focus({window = window}))
  hl.dispatch(hl.dsp.window.bring_to_top())
end

function floating_panes.cycle(next, stack_only)
  local active = hl.get_active_window()
  if not active then return end
  local panes, current = {}, nil
  for _, window in ipairs(windows(active.workspace)) do
    local rect, pane = rectangle(window), nil
    for _, candidate in ipairs(panes) do
      -- Both rectangles must be substantially shared; a half is not a full pane.
      local area = overlap(rect, candidate.rect)
      if area >= 0.8 * math.max(rect[3] * rect[4], candidate.rect[3] * candidate.rect[4]) then
        pane = candidate; break
      end
    end
    if not pane then
      pane = {rect = rect, members = {}, monitor = window.monitor}
      table.insert(panes, pane)
    end
    table.insert(pane.members, window)
    if window == active then current = pane end
  end
  if not current then return end
  if stack_only or #panes == 1 then
    -- Focus history changes on every selection, so rotate by stable address.
    table.sort(current.members, function(a, b) return a.address < b.address end)
    for i, window in ipairs(current.members) do
      if window == active then focus(current.members[(i - 1 + (next and 1 or -1)) % #current.members + 1]); return end
    end
  else
    table.sort(panes, function(a, b)
      local ap, bp = a.monitor.position, b.monitor.position
      if ap.y ~= bp.y then return ap.y < bp.y end
      if ap.x ~= bp.x then return ap.x < bp.x end
      if a.rect[1] ~= b.rect[1] then return a.rect[1] < b.rect[1] end
      return a.rect[2] < b.rect[2]
    end)
    for i, pane in ipairs(panes) do
      if pane == current then focus(panes[(i - 1 + (next and 1 or -1)) % #panes + 1].members[1]); return end
    end
  end
end

hl.on("window.open", function(window)
  if window.workspace and enabled[window.workspace.addressable_name] and not window.pinned then place(window) end
end)
