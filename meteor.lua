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
-- ME Interfaces with the catalysts, one entry per transposer side that has one.
-- Add more sides when you attach more Interfaces (never the dropper's side).
local SOURCE_SIDES = {sides.up}
local DROPPER_SIDE = sides.down     -- dropper (below the transposer, holds max 1 catalyst)

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
local ME_ADDR = "00bd"              -- me_controller or me_interface

-- One entry per GT miner controller (max 16, shown as M01..M16).
-- Delete the lines of miners you do not have.
local MINER_ADDRS = {
  "68e3", "2db5", "7684", "6227",   -- M01-M04
  "d7b2", "64ff", "2ab2", "7885",   -- M05-M08
  "43e2", "7568", "9d1d", "72da",   -- M09-M12
  "cc18", "132b", "d16b", "5e9c",   -- M13-M16
}

-- ---- Drilling Fluid in the ME system ----
local FLUID_MATCH     = "Drilling Fluid"  -- searched in fluid label/name (case, spaces, _ ignored)
local FLUID_START_MIN = 20000       -- mB needed to summon a new meteor
local FLUID_RUN_MIN   = 1000        -- mB below which idle miners are not trusted
local FLUID_BAR_MAX   = 100000      -- mB shown as a full bar

-- ---- Meteors (max 16 with this screen layout) ----
-- label:    text on the button (max 17 characters)
-- catalyst: the catalyst, either the internal name ("modid:item") or the name shown
--           in the game ("Exquisite Diamond"); a text with ':' is taken as internal name
-- damage:   optional item damage / metadata (only used to find the ME crafting pattern)
--           (check with tp.getStackInSlot(sides.up, slot).name)
-- quarry:   true if the meteor has filler blocks for the Ender Quarry
local METEORS = {
  {label = "Exquisite Diamond", catalyst = "Exquisite Diamond", quarry = false},
  {label = "Meteor 2", catalyst = "minecraft:gold_block",    quarry = true},
  {label = "Meteor 3", catalyst = "minecraft:diamond_block", quarry = true},
}

-- ---- Crafting the catalysts in the ME system ----
-- The catalysts are taken by the transposer from the ME Interface above it (the
-- Interface must show them in its slots, e.g. through its configuration).
-- When the ME network does not hold the catalyst of a clicked meteor, a crafting request
-- (1 piece) is sent to the ME system. The meteor waits in the queue ("crafting") until
-- the craft is done and the item shows up in the Interface.
local CRAFT_MISSING = true      -- false: a missing catalyst is simply refused
local CRAFT_RETRY   = 10        -- seconds before a failed or canceled craft is requested again

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

-- Same, but accepts a component of any type.
local function findAnyProxy(prefix)
  if not prefix then return nil end
  for addr in component.list() do
    if addr:sub(1, #prefix) == prefix then return component.proxy(addr) end
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
local me = findProxy(ME_ADDR, {"me_controller", "me_interface"}) or findAnyProxy(ME_ADDR)

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
local fluidNote = nil         -- short reason shown when fluid is unknown
local nextFluidPoll = 0
local minersOk = false        -- every miner answered the last poll
local progress = nil          -- 0..1 progress of a timed step (nil = none)

-- Event log (newest first) and the last user action, both shown on the screen.
local events = {}
local lastAction = nil           -- {text, at} of the latest touch action

local function nowText()
  local ok, t = pcall(os.date, "%H:%M")
  if ok and t then return t end
  local m = math.floor(computer.uptime() / 60)
  return string.format("%02d:%02d", math.floor(m / 60) % 24, m % 60)
end

local function logEvent(text, color, isAction)
  table.insert(events, 1, {t = nowText(), text = text, color = color or 0xDDDDDD,
                           action = isAction, at = computer.uptime()})
  if #events > 60 then events[#events] = nil end
  if isAction then lastAction = {text = text, at = computer.uptime()} end
end

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
  progress = nil
  if message then status = message end
  logEvent(message or STATE_LABEL[newState] or newState, 0x9FD8FF)
end

local function elapsed(now)
  return now - stateSince
end

-- =====================================================================
-- READING THE WORLD
-- =====================================================================

-- lowercase, letters and digits only: "Drilling Fluid" and "liquid_drillingfluid" both contain "drillingfluid"
local function normalize(s)
  return (tostring(s):lower():gsub("[^%w]", ""))
end

-- Returns the Drilling Fluid amount in mB, or nil plus a short reason.
local function readFluid()
  if not me then return nil, "ME not found" end
  if not me.getFluidsInNetwork then return nil, "no fluid method" end
  local ok, list = pcall(me.getFluidsInNetwork)
  if not ok then
    local msg = tostring(list):gsub("^.-:%d+: ", "")
    return nil, msg:sub(1, 18)
  end
  if type(list) ~= "table" then return nil, "bad data" end
  local wanted = normalize(FLUID_MATCH)
  local total = 0
  for _, f in ipairs(list) do
    if normalize((f.label or "") .. (f.name or "")):find(wanted, 1, true) then
      total = total + (f.amount or 0)
    end
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
    fluid, fluidNote = readFluid()
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

-- Runs f(...) and returns its (ok, reason) result; a Lua error becomes false + short text.
local function safe(f, ...)
  local ok, a, b = pcall(f, ...)
  if not ok then return false, tostring(a):gsub("^.-:%d+: ", ""):sub(1, 34) end
  return a, b
end

local function findStack(side, itemName)
  local size = tp.getInventorySize(side)
  if not size then return nil end
  for slot = 1, size do
    local stack = tp.getStackInSlot(side, slot)
    if stack and (stack.name == itemName or stack.label == itemName) then return slot end
  end
  return nil
end

local function isEmpty(side)
  local size = tp.getInventorySize(side)
  if not size then return false end
  for slot = 1, size do
    if tp.getStackInSlot(side, slot) then return false end
  end
  return true
end

local function countItem(side, itemName)
  local size = tp.getInventorySize(side)
  if not size then return 0 end
  local total = 0
  for slot = 1, size do
    local stack = tp.getStackInSlot(side, slot)
    if stack and (stack.name == itemName or stack.label == itemName) then total = total + (stack.size or 1) end
  end
  return total
end

-- Total of an item over all source Interfaces.
local function countSources(itemName)
  local total = 0
  for _, side in ipairs(SOURCE_SIDES) do total = total + countItem(side, itemName) end
  return total
end

-- Moves one item with the given name between two inventories.
local function moveOne(fromSide, toSide, itemName)
  local slot = findStack(fromSide, itemName)
  if not slot then return false, "Not in interface: " .. itemName end
  local moved = tp.transferItem(fromSide, toSide, 1, slot)
  if not moved or moved == 0 then return false, "Transfer failed (target full?)" end
  return true
end

-- How many of an item the chest holds.
-- Moves one catalyst from whichever source Interface holds it into the dropper.
local function takeFromSources(itemName)
  for _, side in ipairs(SOURCE_SIDES) do
    if findStack(side, itemName) then return moveOne(side, DROPPER_SIDE, itemName) end
  end
  return false, "Not in interface: " .. itemName
end

local function hasLoc(loc)
  for _, e in ipairs(queue) do
    if e.loc == loc then return true end
  end
  return false
end

-- Queue entries: {m = meteor index, loc = "crafting" | "chest" | "dropper" | "fired"}
-- The catalysts of queued meteors wait in the chest. Only the next one is moved into the
-- dropper (max 1); when it has been fired the following one is moved in.
-- "crafting": the catalyst is being made by the ME system and has not reached the chest yet.

-- ME search filter for a meteor's catalyst (internal name or displayed name).
local function itemFilter(mt)
  local f = {}
  if mt.catalyst:find(":", 1, true) then f.name = mt.catalyst else f.label = mt.catalyst end
  if mt.damage then f.damage = mt.damage end
  return f
end

-- Sends the crafting request for a queue entry to the ME system.
local function requestCraft(entry)
  local mt = METEORS[entry.m]
  if not me or not me.getCraftables then return false, "ME can't craft" end
  local filter = itemFilter(mt)
  local list = me.getCraftables(filter)
  local craftable = list and list[1]
  if not craftable then return false, "No ME pattern: " .. mt.label end
  local job = craftable.request(1)
  if not job then return false, "ME craft rejected" end
  entry.craft = job
  return true
end

-- How many of an item the whole ME network holds (0 if it cannot be read).
local function countNetwork(mt)
  if not me or not me.getItemsInNetwork then return 0 end
  local filter = itemFilter(mt)
  local ok, list = pcall(me.getItemsInNetwork, filter)
  if not ok or type(list) ~= "table" then return 0 end
  local total = 0
  for _, it in ipairs(list) do total = total + (it.size or 1) end
  return total
end

local function waitingBefore()
  for _, e in ipairs(queue) do
    if e.loc == "chest" or e.loc == "crafting" then return true end
  end
  return false
end

local function enqueueRaw(i)
  if #queue >= 20 then return false, "Queue is full" end
  local item = METEORS[i].catalyst
  local reserved = 0            -- same catalyst already claimed by other queue entries
  for _, e in ipairs(queue) do
    if e.loc ~= "fired" and METEORS[e.m].catalyst == item then reserved = reserved + 1 end
  end
  local entry = {m = i, loc = "chest"}

  local inInterface = countSources(item)
  if inInterface > reserved then
    -- visible in the Interface right now: load the dropper if nothing waits before it
    if not waitingBefore() and not hasLoc("dropper") and isEmpty(DROPPER_SIDE) then
      local ok, err = takeFromSources(item)
      if not ok then return false, err end
      entry.loc = "dropper"
    end
  elseif countNetwork(METEORS[i]) > reserved then
    -- the ME network has it but it is not in the Interface yet: wait for it to appear
    entry.loc = "chest"
  else
    if not CRAFT_MISSING then return false, "Missing catalyst: " .. item end
    entry.loc = "crafting"
    entry.nextTry = 0          -- the craft request is sent from the main loop
  end
  queue[#queue + 1] = entry
  return true
end

local function enqueue(i)
  local ok, err = safe(enqueueRaw, i)
  if not ok then
    status = err
    logEvent(METEORS[i].label .. ": " .. tostring(err), 0xFFAA33, true)
    return
  end
  local e = queue[#queue]
  local where = (e.loc == "dropper" and "in dropper") or (e.loc == "crafting" and "crafting") or "waiting"
  logEvent("Queued: " .. METEORS[i].label .. " (" .. where .. ")", 0x55DDFF, true)
end

-- Chest -> dropper for an entry (only when the dropper is empty).
local function promoteRaw(entry)
  if entry.loc == "dropper" then return true end
  if not isEmpty(DROPPER_SIDE) then return false, "Dropper not empty" end
  local ok, err = takeFromSources(METEORS[entry.m].catalyst)
  if not ok then return false, err end
  entry.loc = "dropper"
  return true
end

-- Keeps the dropper loaded with the next queued catalyst (queue order is kept:
-- nothing is loaded while an earlier meteor still waits for its craft).
local function refillDropper()
  if hasLoc("dropper") then return end
  for _, e in ipairs(queue) do
    if e.loc == "chest" then safe(promoteRaw, e); return end
    if e.loc == "crafting" then return end
  end
end

-- Sends / follows the ME crafting jobs of the queue.
local function updateCrafts(now)
  for _, e in ipairs(queue) do
    if e.loc == "crafting" then
      if not e.craft then
        if now >= (e.nextTry or 0) then
          local ok, err = safe(requestCraft, e)
          if ok then
            e.note = nil
            logEvent("Craft requested: " .. METEORS[e.m].label, 0xFFCC66)
          else
            e.note = err
            e.nextTry = now + CRAFT_RETRY
          end
        end
      else
        local okC, canceled = pcall(e.craft.isCanceled)
        local okD, done = pcall(e.craft.isDone)
        if okC and canceled then
          e.craft = nil
          e.note = "Craft canceled, retrying"
          logEvent("Craft canceled: " .. METEORS[e.m].label, 0xFFAA33)
          e.nextTry = now + CRAFT_RETRY
        elseif okD and done then
          e.craft = nil
          logEvent("Craft done: " .. METEORS[e.m].label, 0x66FF66)
          e.loc = "chest"      -- the item should arrive in the chest; loading retries until it does
        end
      end
    end
  end
end

-- Fires the dropper with the catalyst of an entry. Returns true, or false + reason.
local function dropCatalyst(entry)
  local ok, err = safe(promoteRaw, entry)
  if not ok then return false, err end
  os.sleep(0.2)
  pulseOut("dropper", 0.3)
  os.sleep(0.3)
  entry.loc = "fired"
  return true
end

-- Puts the catalyst of a removed queue entry back into the chest.
local function returnCatalyst(entry)
  if entry.loc == "dropper" then
    safe(moveOne, DROPPER_SIDE, SOURCE_SIDES[1], METEORS[entry.m].catalyst)
  end
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
  if not queue[1] then
    setState("idle", "Queue is empty")
    return false
  end
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
  -- the catalyst must be ready before the ritual is started
  local head = queue[1]
  if head.loc == "crafting" then
    status = head.note or ("Crafting catalyst: " .. METEORS[head.m].label)
    return
  end
  if head.loc ~= "dropper" then
    local ok, err = safe(promoteRaw, head)
    if not ok then
      status = err
      retryAt = now + 5
      return
    end
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
    progress = 1 - left / RITUAL_WARMUP
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
    logEvent("Miners start signal sent", 0x9FD8FF)
  elseif elapsed(now) > START_TIMEOUT then
    -- stay in this state; START sends the signal again
    running = false
    pulsed = false
    stateSince = now
    status = "TIMEOUT - press START to retry"
    logEvent("Timeout: miners did not start", 0xFFAA33)
  end
end

local function stepMining(now)
  progress = nil
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
    progress = 1 - left / IDLE_CONFIRM
    return
  end

  -- every miner has been idle long enough: the meteor itself is mined
  if METEORS[queue[1].m].quarry then
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
    progress = 1 - left / QUARRY_TIME
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

-- Layout (80 columns, 25+ rows):
--   left  (x 1-40):  meteor buttons (2 x 8), controls (START / CLEAR QUEUE / EXIT)
--   right (x 42-79): status, GT miner tiles, Drilling Fluid, queue
--   row 1: title bar     last row: message about your last touch
-- On a taller screen the buttons get taller and the queue gets more rows.

-- Picks the screen resolution: 80 columns, rows from the screen's shape.
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
local RX, RW = 42, 38                          -- right column
local CTRL_HEADER = H - 6                      -- "CONTROLS" strip; buttons below it
local BH = math.max(2, math.floor((CTRL_HEADER - 3) / 8))   -- height of one meteor button
local QUEUE_TOP = 19
local QUEUE_ROWS = H - QUEUE_TOP               -- rows 19 .. H-1

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

-- ---------- colors ----------
local C = {
  bg = 0x000000, title = 0x12304D, header = 0x262626, headerText = 0x7FD1FF,
  text = 0xFFFFFF, dim = 0x9A9A9A, track = 0x303030, divider = 0x1E1E1E,
  good = 0x2E9E3E, bad = 0xB02A2A, warn = 0xB87400, off = 0x4A4A4A,
  accent = 0x1565C0, quarry = 0x7A4BB5, progress = 0x2196F3,
}

local STATE_BG = {
  idle = 0x4A4A4A, ritual = 0x7B3FA0, wait_start = 0xB87400,
  mining = 0x1565C0, quarry = 0x7B3FA0, finish = 0x2E9E3E,
}

-- brightness change of an 0xRRGGBB color (f < 1 darker, f > 1 lighter)
local function shade(color, f)
  local r = math.min(255, math.floor(math.floor(color / 65536) % 256 * f))
  local g = math.min(255, math.floor(math.floor(color / 256) % 256 * f))
  local b = math.min(255, math.floor(color % 256 * f))
  return r * 65536 + g * 256 + b
end

-- ---------- 3D buttons ----------
-- Raised button: lit top edge, face, dark shadow row at the bottom.
-- Pressed button: no shadow, the face moves down and gets darker.
local buttons = {}

local function addButton(b)
  buttons[#buttons + 1] = b
  return b
end

local function drawButton(b, pressed)
  local base = b.color and b.color() or 0x444444
  local label = type(b.label) == "function" and b.label() or b.label
  label = unicode.sub(label, 1, b.w)
  local faceH = b.h - 1
  local y0, color
  gpu.setBackground(C.bg)
  gpu.fill(b.x, b.y, b.w, b.h, " ")
  if pressed then
    y0, color = b.y + 1, shade(base, 0.7)
    gpu.setBackground(color)
    gpu.fill(b.x, y0, b.w, faceH, " ")
  else
    y0, color = b.y, base
    gpu.setBackground(color)
    gpu.fill(b.x, y0, b.w, faceH, " ")
    if faceH >= 2 then                            -- lit top edge
      gpu.setBackground(shade(base, 1.35))
      gpu.fill(b.x, y0, b.w, 1, " ")
    end
    gpu.setBackground(shade(base, 0.45))          -- shadow
    gpu.fill(b.x, b.y + b.h - 1, b.w, 1, " ")
  end
  local ty = y0 + math.floor((faceH - 1) / 2)
  if faceH >= 3 and not pressed then ty = y0 + math.floor(faceH / 2) end
  put(b.x + math.floor((b.w - unicode.len(label)) / 2), ty, label, C.text,
    (not pressed and faceH >= 2 and ty == y0) and shade(base, 1.35) or color)
end

assert(#METEORS <= 16, "Screen layout has room for max. 16 meteors")

-- meteor buttons: two columns of 8; purple = has an Ender Quarry step
for i, m in ipairs(METEORS) do
  local col = math.floor((i - 1) / 8)
  local row = (i - 1) % 8
  addButton({
    x = 1 + col * 21, y = 3 + row * BH, w = 19, h = BH,
    label = "+ " .. m.label,
    color = function() return m.quarry and C.quarry or C.accent end,
    action = function() enqueue(i) end,
  })
end

local startBtn = addButton({
  x = 1, y = H - 5, w = 12, h = 3,
  label = function() return running and "STOP" or "START" end,
  color = function() return running and C.bad or C.good end,
  action = function()
    running = not running
    logEvent(running and "Started" or "Stopped", running and 0x66FF66 or 0xFF7777, true)
  end,
})

addButton({
  x = 14, y = H - 5, w = 15, h = 3, label = "CLEAR QUEUE",
  color = function() return 0x9E6B00 end,
  action = function()
    -- the meteor already summoned (first in queue) is kept; the others go back to the Interface
    local keep = (queue[1] and queue[1].loc == "fired") and queue[1] or nil
    local removed = 0
    for _, e in ipairs(queue) do
      if e ~= keep then returnCatalyst(e); removed = removed + 1 end
    end
    queue = {}
    if keep then queue[1] = keep end
    logEvent("Queue cleared (" .. removed .. " removed)", 0xFFCC66, true)
  end,
})

addButton({
  x = 31, y = H - 5, w = 10, h = 3, label = "EXIT",
  color = function() return 0x666666 end,
  id = "exit",
})

-- Presses the touched button (it moves down for a moment), then runs its action.
local function handleTouch(x, y)
  for _, b in ipairs(buttons) do
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
      drawButton(b, true)
      os.sleep(0.15)
      if b.id == "exit" then return "exit" end
      if b.action then b.action() end
      drawButton(b)
      return
    end
  end
end

-- ---------- drawing helpers ----------
local drawnRunning = nil

-- Section strip with optional right-aligned text.
local function header(x, y, w, text, right, rightColor)
  put(x, y, " " .. text, C.headerText, C.header, w)
  if right then
    local s = right .. " "
    put(x + w - unicode.len(s), y, s, rightColor or C.dim, C.header)
  end
end

-- Horizontal bar; returns the number of filled columns.
local function drawBar(x, y, w, h, frac, color)
  local fill = math.max(0, math.min(w, math.floor((frac or 0) * w + 0.5)))
  gpu.setBackground(C.track)
  gpu.fill(x, y, w, h, " ")
  if fill > 0 then
    gpu.setBackground(color)
    gpu.fill(x, y, fill, h, " ")
  end
  return fill
end

local function drawStatic()
  gpu.setBackground(C.bg)
  gpu.fill(1, 1, W, H, " ")
  put(1, 1, "  METEOR RITUAL CONTROLLER", C.text, C.title, W)
  gpu.setBackground(C.divider)
  gpu.fill(41, 2, 1, H - 2, " ")
  header(1, 2, 40, "ADD METEOR TO QUEUE", "purple = quarry")
  header(1, CTRL_HEADER, 40, "CONTROLS")
  header(RX, 2, RW, "STATUS")
  for _, b in ipairs(buttons) do drawButton(b) end
  drawnRunning = running
end

local function drawTitle()
  local label, color = " STOPPED ", C.bad
  if running then label, color = " RUNNING ", C.good end
  put(W - #label, 1, label, C.text, color)
end

local function drawStatus()
  put(RX, 3, " " .. (STATE_LABEL[state] or state), C.text, STATE_BG[state] or C.off, RW)

  local bad = false
  local low = status:lower()
  for _, w in ipairs({"timeout", "unreachable", "missing", "disabled", "low ", "failed", "waiting for fluid", "not in interface", "no me pattern", "canceled", "rejected"}) do
    if low:find(w, 1, true) then bad = true end
  end
  put(RX, 4, " " .. status, bad and 0xFFAA33 or 0xFFFF88, C.bg, RW)

  local current = (queue[1] and queue[1].loc == "fired") and METEORS[queue[1].m].label or "-"
  put(RX, 5, " Meteor: ", C.dim, C.bg, 9)
  put(RX + 9, 5, current, C.text, C.bg, RW - 9)

  drawBar(RX, 6, 32, 1, progress or 0, C.progress)
  put(RX + 32, 6, progress and string.format(" %3d%%", math.floor(progress * 100)) or "    -", C.dim, C.bg, 6)
end

-- miners: 4 x 4 colored tiles
local function drawMiners()
  local activeCount = 0
  for i, m in ipairs(MINERS) do
    local r = math.floor((i - 1) / 4)
    local c = (i - 1) % 4
    local tag, color
    if m.active == nil then
      tag, color = "N/A", 0x555555
    elseif m.active then
      tag, color = "ON", C.good
      activeCount = activeCount + 1
    elseif m.disabled then
      tag, color = "DIS", C.warn
    else
      tag, color = "OFF", C.bad
    end
    local text = m.name .. " " .. tag
    local pad = math.floor((8 - #text) / 2)
    put(RX + c * 10, 9 + r, string.rep(" ", pad) .. text, C.text, color, 8)
  end
  header(RX, 8, RW, "GT MINERS", activeCount .. "/" .. #MINERS .. " operating",
    activeCount > 0 and 0x66FF66 or C.dim)
end

local function drawFluid()
  local text
  if fluid then text = fmt(fluid) .. " mB" else text = "N/A [" .. (fluidNote or "?") .. "]" end
  local enough = fluid and fluid >= FLUID_START_MIN
  header(RX, 14, RW, "DRILLING FLUID", text,
    fluid and (enough and 0x66FF66 or 0xFF7777) or 0xFFCC00)
  local color = enough and C.good or C.bad
  local fill = drawBar(RX, 15, RW, 1, fluid and (fluid / FLUID_BAR_MAX) or 0, color)
  -- tick mark = minimum needed to summon a meteor
  local mark = math.min(RW - 1, math.floor(FLUID_START_MIN / FLUID_BAR_MAX * RW))
  gpu.setForeground(C.text)
  gpu.setBackground(mark < fill and color or C.track)
  gpu.set(RX + mark, 15, "|")
  put(RX, 16, " Needs " .. fmt(FLUID_START_MIN) .. " mB to summon a meteor", C.dim, C.bg, RW)
end

local function drawQueue()
  header(RX, 18, RW, "QUEUE", #queue .. " queued")
  for r = 1, QUEUE_ROWS do
    local line, fg, bg, tag, tagColor = "", C.text, C.bg, nil, C.dim
    local e = queue[r]
    if r == QUEUE_ROWS and #queue > QUEUE_ROWS then
      line, fg = "  ... +" .. (#queue - QUEUE_ROWS + 1) .. " more", C.dim
    elseif e then
      local mt = METEORS[e.m]
      local active = e.loc == "fired"
      line = string.format("%s%2d. %s", active and "> " or "  ", r, mt.label)
      if mt.quarry then fg = 0xD0A8FF end
      if active then
        tag, tagColor, bg, fg = "ACTIVE", 0x66E0FF, 0x0B3C55, 0x66E0FF
      elseif e.loc == "dropper" then
        tag = "in dropper"
      elseif e.loc == "crafting" then
        tag, tagColor = e.note and "craft retry" or "crafting", 0xFFAA33
      else
        tag = "waiting"
      end
    elseif r == 1 then
      line, fg = "  (queue is empty)", C.dim
    end
    put(RX, QUEUE_TOP + r - 1, line, fg, bg, RW)
    if tag then put(RX + RW - #tag - 1, QUEUE_TOP + r - 1, tag, tagColor, bg) end
  end
end

-- Last event / touch action: bright for a few seconds after your touch, then dim.
local function drawMessage()
  local e = events[1]
  local text, fg, bg = " Touch a button to start", C.dim, 0x1A1A1A
  if e then
    local fresh = e.action and (computer.uptime() - e.at < 4)
    text = " " .. e.t .. "  " .. e.text
    if fresh then fg, bg = C.text, C.accent else fg = e.color end
  end
  put(1, H, text, fg, bg, W)
end

local function drawDynamic()
  drawTitle()
  drawStatus()
  drawMiners()
  drawFluid()
  drawQueue()
  drawMessage()
  -- START / STOP changes color and label, redraw only when it flips
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
    if ev then
      if handleTouch(x, y) == "exit" then return end
      drawDynamic()               -- show the result of the touch right away
    end
    pollHardware(computer.uptime())
    if running then step() end
    updateCrafts(computer.uptime())
    refillDropper()
    drawDynamic()
  end
end

local ok, err = pcall(main)
resetOutputs()
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
gpu.fill(1, 1, W, H, " ")
if not ok then print("Error: " .. tostring(err)) end
