-- =====================================================================
-- Meteor Ritual Controller (GTNH / OpenComputers)
--
-- Summons Blood Magic meteors by dropping catalysts onto the ritual,
-- switches the GT Ore Drilling Plants on with a one-time redstone pulse,
-- waits until all of them are idle, optionally runs an Ender Quarry to
-- clear the leftover filler blocks, then moves on to the next meteor.
--
-- Hardware: Tier 2+ screen and GPU (80x25), transposer, Redstone I/O
-- (or Redstone Card), adapters next to the miner controllers and next to
-- an ME controller / ME interface.
--
-- Flow per meteor:
--   idle -> [ritual] -> wait_start -> mining -> [quarry] -> finish -> idle
--   ("ritual" = ritual start pulse, sent before the first meteor of a run)
-- =====================================================================

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local sides     = require("sides")
local unicode   = require("unicode")

local gpu = component.gpu
local tp  = component.transposer

-- =====================================================================
-- CONFIG
-- =====================================================================

-- ---- Catalyst chest and dropper (transposer sides) ----
local CHEST_SIDE   = sides.west     -- chest with the catalysts
local DROPPER_SIDE = sides.up       -- dropper above the ritual stone

-- ---- Redstone outputs ----
-- side: side of the redstone component the signal comes out of.
-- addr: optional address prefix of a specific Redstone I/O or card.
--       Leave it out to use the computer's default redstone component.
local OUT = {
  dropper = {side = sides.up},      -- fires the dropper
  ritual  = {side = sides.east},    -- one-time start pulse for the ritual (Dynamism Tablet)
  miners  = {side = sides.south},   -- one-time start pulse for the GT miners
  quarry  = {side = sides.north},   -- starts the Ender Quarry
}

-- ---- Component addresses (the first few characters are enough) ----
-- List them with:  components
local ME_ADDR = "xxxx"              -- me_controller or me_interface

-- One entry per GT miner controller (max 16, shown as M01..M16).
-- Delete the lines of miners you do not have.
local MINER_ADDRS = {
  "xxxx", "xxxx", "xxxx", "xxxx",
  "xxxx", "xxxx", "xxxx", "xxxx",
  "xxxx", "xxxx", "xxxx", "xxxx",
  "xxxx", "xxxx", "xxxx", "xxxx",
}

-- ---- Drilling Fluid in the ME system ----
local FLUID_MATCH     = "drilling"  -- lowercase text searched in fluid name/label
local FLUID_START_MIN = 20000       -- mB needed to summon a new meteor
local FLUID_RUN_MIN   = 1000        -- mB below which idle miners are not trusted
local FLUID_BAR_MAX   = 100000      -- mB shown as a full bar

-- ---- Meteors (max 4 with this screen layout) ----
-- label:    text on the button
-- catalyst: item name of the catalyst
--           (check with tp.getStackInSlot(CHEST_SIDE, slot).name)
-- quarry:   true if the meteor has filler blocks for the Ender Quarry
local METEORS = {
  {label = "Meteor 1", catalyst = "minecraft:iron_block",    quarry = false},
  {label = "Meteor 2", catalyst = "minecraft:gold_block",    quarry = true},
  {label = "Meteor 3", catalyst = "minecraft:diamond_block", quarry = true},
}

-- ---- Timing (seconds) ----
local START_DELAY   = 5     -- after the catalyst drop, before the miners' start pulse
local START_TIMEOUT = 180   -- how long to wait for the miners to start
local IDLE_CONFIRM  = 20    -- how long ALL miners must be OFF to count the meteor as mined
local QUARRY_TIME   = 120   -- how long the Ender Quarry gets to finish
local MINERS_PULSE  = 1.0   -- length of the miners' start pulse

-- ---- Ritual start (Dynamism Tablet) ----
-- One pulse on OUT.ritual starts the ritual before the first meteor of a program run.
local RITUAL_PULSE       = 1.0    -- length of the pulse
local RITUAL_WARMUP      = 5      -- seconds to wait after the pulse before the catalyst drop
local RITUAL_EACH_METEOR = false  -- true: send the pulse before every meteor instead of once

-- ---- Screen resolution ----
-- nil: fit the screen's shape automatically (uses extra rows for spacing).
-- Or set it by hand, e.g. {80, 50}. The layout is designed for 80 columns.
local RESOLUTION = nil

-- ---- Ender Quarry signal ----
-- "pulse": one short pulse starts it, then we just wait QUARRY_TIME
-- "hold":  signal stays on for QUARRY_TIME, then goes off
local QUARRY_SIGNAL = "pulse"
local QUARRY_PULSE  = 1.0   -- length of the pulse in "pulse" mode

-- ---- Miners switched off by your own shutdown method ----
-- true: miners disabled via machine controller cover / soft mallet count as OFF.
-- false: such miners block the meteor from being counted as mined.
local IGNORE_DISABLED = true

-- =====================================================================
-- HARDWARE ACCESS
-- =====================================================================

local function findProxy(prefix, types)
  if not prefix then return nil end
  for _, t in ipairs(types) do
    for addr in component.list(t) do
      if addr:sub(1, #prefix) == prefix then return component.proxy(addr) end
    end
  end
  return nil
end

-- GT miners
local MINERS = {}
for i, addr in ipairs(MINER_ADDRS) do
  if i > 16 then break end
  MINERS[i] = {name = string.format("M%02d", i), addr = addr}
  MINERS[i].proxy = findProxy(addr, {"gt_machine"})
end

-- ME system
local me = findProxy(ME_ADDR, {"me_controller", "me_interface"})

-- Redstone outputs
for name, o in pairs(OUT) do
  if o.addr then
    o.proxy = findProxy(o.addr, {"redstone"})
  else
    o.proxy = component.redstone
  end
  assert(o.proxy, "Redstone output '" .. name .. "' not found (check addr)")
end

local function setOut(name, level)
  OUT[name].proxy.setOutput(OUT[name].side, level)
end

local function pulseOut(name, seconds)
  setOut(name, 15)
  os.sleep(seconds)
  setOut(name, 0)
end

local function resetOutputs()
  for name in pairs(OUT) do setOut(name, 0) end
end

-- =====================================================================
-- STATE
-- =====================================================================

local queue = {}              -- indexes into METEORS, in summoning order
local running = false         -- START / STOP switch
local state = "idle"          -- idle | ritual | wait_start | mining | quarry | finish
local stateSince = 0          -- uptime when the current state began
local status = "Ready"        -- one-line message shown on screen
local retryAt = 0             -- idle: do not retry the catalyst drop before this time
local pulsed = false          -- miners' start pulse already sent for this meteor
local ritualStarted = false   -- ritual start pulse already sent (once per program run)
local idleSince = nil         -- uptime since when all miners have been OFF
local fluid = nil             -- Drilling Fluid in ME (mB), nil = unknown
local nextFluidPoll = 0
local minersOk = false        -- every miner answered the last poll

local STATE_LABEL = {
  idle       = "Waiting for next meteor",
  ritual     = "Starting ritual",
  wait_start = "Waiting for miners to start",
  mining     = "Mining meteor",
  quarry     = "Ender Quarry is clearing filler",
  finish     = "Finishing",
}

local function setState(newState, message)
  state = newState
  stateSince = computer.uptime()
  if message then status = message end
end

local function elapsed(now)
  return now - stateSince
end

-- =====================================================================
-- READING THE WORLD
-- =====================================================================

local function readFluid()
  if not me then return nil end
  local ok, list = pcall(me.getFluidsInNetwork)
  if not ok or type(list) ~= "table" then return nil end
  local total = 0
  for _, f in ipairs(list) do
    local text = ((f.label or "") .. " " .. (f.name or "")):lower()
    if text:find(FLUID_MATCH, 1, true) then total = total + (f.amount or 0) end
  end
  return total
end

local function pollHardware(now)
  minersOk = true
  for _, m in ipairs(MINERS) do
    m.active = nil
    m.disabled = false
    if m.proxy then
      local ok, active = pcall(m.proxy.isMachineActive)
      if ok then m.active = active and true or false end
      -- switched off by soft mallet / redstone (skipped if the method is missing)
      local ok2, allowed = pcall(m.proxy.isWorkAllowed)
      if ok2 and allowed == false and not IGNORE_DISABLED then m.disabled = true end
    end
    if m.active == nil then minersOk = false end
  end
  if now >= nextFluidPoll then
    fluid = readFluid()
    nextFluidPoll = now + 5
  end
end

local function anyActive()
  for _, m in ipairs(MINERS) do
    if m.active then return true end
  end
  return false
end

local function anyDisabled()
  for _, m in ipairs(MINERS) do
    if m.disabled then return true end
  end
  return false
end

-- =====================================================================
-- ACTIONS
-- =====================================================================

local function findCatalyst(itemName)
  local size = tp.getInventorySize(CHEST_SIDE)
  if not size then return nil end
  for slot = 1, size do
    local stack = tp.getStackInSlot(CHEST_SIDE, slot)
    if stack and stack.name == itemName then return slot end
  end
  return nil
end

-- Moves one catalyst into the dropper and fires it. Returns true, or false + reason.
local function dropCatalyst(meteorIdx)
  local item = METEORS[meteorIdx].catalyst
  local slot = findCatalyst(item)
  if not slot then return false, "Missing catalyst: " .. item end
  local moved = tp.transferItem(CHEST_SIDE, DROPPER_SIDE, 1, slot)
  if not moved or moved == 0 then return false, "Dropper full / transfer failed" end
  os.sleep(0.2)
  pulseOut("dropper", 0.3)
  return true
end

local function startQuarry()
  if QUARRY_SIGNAL == "hold" then
    setOut("quarry", 15)
  else
    pulseOut("quarry", QUARRY_PULSE)
  end
end

local function stopQuarry()
  if QUARRY_SIGNAL == "hold" then setOut("quarry", 0) end
end

-- =====================================================================
-- STATE MACHINE (one function per state)
-- =====================================================================

-- Drops the catalyst of the first queued meteor. Returns true when it worked.
local function summon(now)
  local ok, err = dropCatalyst(queue[1])
  if not ok then
    status = err
    retryAt = now + 5
    return false
  end
  pulsed = false
  setState("wait_start", "Meteor summoned, starting miners soon")
  return true
end

local function stepIdle(now)
  if #queue == 0 then status = "Queue is empty"; return end
  if now < retryAt then return end
  if fluid and fluid < FLUID_START_MIN then
    status = "Waiting for fluid (min " .. string.format("%d", FLUID_START_MIN) .. " mB)"
    return
  end
  if RITUAL_EACH_METEOR or not ritualStarted then
    pulseOut("ritual", RITUAL_PULSE)
    ritualStarted = true
    setState("ritual", "Ritual start signal sent")
  else
    summon(now)
  end
end

-- Gives the ritual a moment to start, then drops the catalyst.
-- A missing catalyst is retried here, so the ritual pulse is not sent again.
local function stepRitual(now)
  local left = RITUAL_WARMUP - elapsed(now)
  if left > 0 then
    status = "Ritual starting (" .. math.ceil(left) .. " s)"
    return
  end
  if now < retryAt then return end
  summon(now)
end

local function stepWaitStart(now)
  if anyActive() then
    idleSince = nil
    setState("mining", "Mining in progress")
  elseif not pulsed and elapsed(now) >= START_DELAY then
    -- sent only while no miner runs, so a toggle (T flip-flop) cannot switch them off
    pulseOut("miners", MINERS_PULSE)
    pulsed = true
    status = "Start signal sent, waiting for miners"
  elseif elapsed(now) > START_TIMEOUT then
    -- stay in this state; START sends the signal again
    running = false
    pulsed = false
    stateSince = now
    status = "TIMEOUT - press START to retry"
  end
end

local function stepMining(now)
  if not minersOk then
    idleSince = nil
    status = "Miner unreachable (address/adapter)"
    return
  end
  if anyActive() then
    idleSince = nil
    status = "Mining in progress"
    return
  end
  if anyDisabled() then
    idleSince = nil
    status = "Miner disabled (mallet/redstone)"
    return
  end
  if fluid and fluid < FLUID_RUN_MIN then
    idleSince = nil
    status = "Miners idle - low Drilling Fluid"
    return
  end

  idleSince = idleSince or now
  local left = IDLE_CONFIRM - (now - idleSince)
  if left > 0 then
    status = "Miners OFF, verifying (" .. math.ceil(left) .. " s)"
    return
  end

  -- every miner has been idle long enough: the meteor itself is mined
  if METEORS[queue[1]].quarry then
    startQuarry()
    setState("quarry", "Ender Quarry started")
  else
    setState("finish")
  end
end

local function stepQuarry(now)
  local left = QUARRY_TIME - elapsed(now)
  if left > 0 then
    status = "Ender Quarry running (" .. math.ceil(left) .. " s)"
    return
  end
  stopQuarry()
  setState("finish")
end

local function stepFinish()
  table.remove(queue, 1)
  idleSince = nil
  setState("idle", "Meteor fully mined")
end

local STEPS = {
  idle       = stepIdle,
  ritual     = stepRitual,
  wait_start = stepWaitStart,
  mining     = stepMining,
  quarry     = stepQuarry,
  finish     = stepFinish,
}

local function step()
  STEPS[state](computer.uptime())
end

-- =====================================================================
-- USER INTERFACE
-- =====================================================================

local PANEL_X = 40            -- left panel: x 2..37, right panel: x 40..79

-- The layout is designed for 80x25. On a taller screen the extra rows are used
-- for spacing: every layout row n is placed at screen row Y(n).
local function fitResolution()
  local maxW, maxH = gpu.maxResolution()
  if RESOLUTION then
    return math.min(RESOLUTION[1], maxW), math.min(RESOLUTION[2], maxH)
  end
  local w, h = math.min(80, maxW), 25
  local ok, a, b = pcall(function()
    return component.proxy(gpu.getScreen()).getAspectRatio()
  end)
  if ok and a and b and a > 0 then
    -- a character cell is twice as tall as wide, so w/h = 2*a/b fills the screen
    local ideal = math.floor(w * b / (2 * a) + 0.5)
    h = math.max(25, math.min(ideal, maxH))
  end
  return w, h
end

local W, H = fitResolution()
local VS = math.max(1, math.floor(H / 25))     -- vertical scale of the layout

local function Y(n)
  return (n - 1) * VS + 1
end

local function put(x, y, text, fg, bg, width)
  text = tostring(text)
  if width then
    local len = unicode.len(text)
    if len < width then text = text .. string.rep(" ", width - len)
    elseif len > width then text = unicode.sub(text, 1, width) end
  end
  gpu.setForeground(fg or 0xFFFFFF)
  gpu.setBackground(bg or 0x000000)
  gpu.set(x, y, text)
end

local function fmt(n)
  local s = tostring(math.floor(n))
  local r = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (r:gsub("^ ", ""))
end

-- ---------- buttons ----------
local buttons = {}

local function addButton(b)
  buttons[#buttons + 1] = b
  return b
end

local function drawButton(b)
  gpu.setBackground(b.color and b.color() or 0x444444)
  gpu.setForeground(0xFFFFFF)
  gpu.fill(b.x, b.y, b.w, b.h, " ")
  local len = unicode.len(b.label)
  gpu.set(b.x + math.floor((b.w - len) / 2), b.y + math.floor(b.h / 2), b.label)
end

local function queueAdd(meteorIdx)
  if #queue < 20 then queue[#queue + 1] = meteorIdx end
end

assert(#METEORS <= 4, "Screen layout has room for max. 4 meteors")

for i, m in ipairs(METEORS) do
  addButton({
    x = 2, y = Y(4 + (i - 1) * 3), w = 34, h = 3 * VS,
    label = "+ " .. m.label .. (m.quarry and " [quarry]" or ""),
    color = function() return 0x0066CC end,
    action = function() queueAdd(i) end,
  })
end

local startBtn = addButton({
  x = PANEL_X, y = Y(20), w = 18, h = 2 * VS, label = "START / STOP",
  color = function() return running and 0x00AA00 or 0xAA0000 end,
  action = function() running = not running end,
})

addButton({
  x = PANEL_X + 20, y = Y(20), w = 18, h = 2 * VS, label = "CLEAR QUEUE",
  color = function() return 0x886600 end,
  action = function()
    -- the meteor currently being processed (first in queue) is kept
    local keep = (state ~= "idle") and queue[1] or nil
    queue = {}
    if keep then queue[1] = keep end
  end,
})

addButton({
  x = PANEL_X, y = Y(23), w = 18, h = 2 * VS, label = "EXIT",
  color = function() return 0x777777 end,
  id = "exit",
})

-- Returns "exit" when the EXIT button was pressed.
local function handleTouch(x, y)
  for _, b in ipairs(buttons) do
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
      if b.id == "exit" then return "exit" end
      if b.action then b.action() end
    end
  end
end

-- ---------- drawing ----------
local drawnRunning = nil

local function drawStatic()
  gpu.setBackground(0x000000)
  gpu.fill(1, 1, W, H, " ")
  put(2, 1, "METEOR RITUAL CONTROLLER", 0x00FFFF)
  put(2, Y(3), "ADD METEOR TO QUEUE", 0xAAAAAA)
  put(2, Y(17), "QUEUE (summoning order)", 0xAAAAAA)
  for _, b in ipairs(buttons) do drawButton(b) end
  drawnRunning = running
end

-- miners: two columns of 8 (M01-M08 left, M09-M16 right)
local function drawMiners()
  local activeCount = 0
  for i, m in ipairs(MINERS) do
    local col = math.floor((i - 1) / 8)
    local row = (i - 1) % 8
    local x, y = PANEL_X + col * 20, Y(4 + row)
    local label, color
    if m.active == nil then
      label, color = "N/A", 0x888888
    elseif m.active then
      label, color = "Operating", 0x00FF00
      activeCount = activeCount + 1
    elseif m.disabled then
      label, color = "DISABLED", 0xFFAA00
    else
      label, color = "OFF", 0xFF4444
    end
    put(x, y, m.name, 0xFFFFFF, 0x000000, 4)
    put(x + 4, y, label, color, 0x000000, 15)
  end
  put(PANEL_X, Y(3), "GT MINERS (" .. activeCount .. "/" .. #MINERS .. " operating)", 0xAAAAAA, 0x000000, 40)
end

local function drawFluid()
  local text = fluid and (fmt(fluid) .. " mB") or "N/A"
  put(PANEL_X, Y(13), "Drilling Fluid: " .. text, 0xFFFF00, 0x000000, 40)
  local barW = 36
  local fill = 0
  if fluid then fill = math.min(barW, math.floor(fluid / FLUID_BAR_MAX * barW)) end
  gpu.setBackground(0x333333)
  gpu.fill(PANEL_X, Y(14), barW, VS, " ")
  if fill > 0 then
    gpu.setBackground((fluid >= FLUID_START_MIN) and 0x00AA00 or 0xCC0000)
    gpu.fill(PANEL_X, Y(14), fill, VS, " ")
  end
end

local function drawStatus()
  put(PANEL_X, Y(16), "State: " .. (STATE_LABEL[state] or state), 0xFFFFFF, 0x000000, 40)
  put(PANEL_X, Y(17), status, 0xFFFF00, 0x000000, 40)
  local current = (state ~= "idle" and queue[1]) and METEORS[queue[1]].label or "-"
  put(PANEL_X, Y(18), "Current meteor: " .. current, 0xFFFFFF, 0x000000, 40)
end

local function drawQueue()
  for r = 1, 7 do
    local line, color = "", 0xFFFFFF
    if r == 7 and #queue > 7 then
      line = "... +" .. (#queue - 6) .. " more"
    elseif queue[r] then
      line = r .. ". " .. METEORS[queue[r]].label
      if r == 1 and state ~= "idle" then
        line = "> " .. line .. " (active)"
        color = 0x00FFFF
      end
    end
    put(2, Y(17 + r), line, color, 0x000000, 36)
  end
end

local function drawDynamic()
  drawMiners()
  drawFluid()
  drawStatus()
  drawQueue()
  -- START / STOP changes color, redraw only when it flips
  if drawnRunning ~= running then
    drawButton(startBtn)
    drawnRunning = running
  end
end

-- =====================================================================
-- MAIN LOOP
-- =====================================================================

local function main()
  resetOutputs()
  gpu.setResolution(W, H)
  drawStatic()
  while true do
    local ev, _, x, y = event.pull(1, "touch")
    if ev and handleTouch(x, y) == "exit" then return end
    pollHardware(computer.uptime())
    if running then step() end
    drawDynamic()
  end
end

local ok, err = pcall(main)
resetOutputs()
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
gpu.fill(1, 1, W, H, " ")
if not ok then print("Error: " .. tostring(err)) end
