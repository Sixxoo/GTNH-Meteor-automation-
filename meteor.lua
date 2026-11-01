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
--   ("ritual" = ritual start pulse, sent RITUAL_DELAY seconds after the first catalyst drop)
-- =====================================================================

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local sides     = require("sides")
local unicode   = require("unicode")

local gpu = component.gpu
local tp  = component.transposer

-- ---------------------------------------------------------------------
-- Your own settings live in a separate file, so updating this program never
-- overwrites them. Put meteor_config.lua next to the program (e.g. /home/meteor_config.lua).
-- It must return a table with the settings below, for example:
--     local sides = require("sides")
--     return {QUARRY_TIME = 90, METEORS = {...}}
-- Anything not set there uses the defaults in this file.
-- ---------------------------------------------------------------------
local USER = {}
local CONFIG_NOTE = "No meteor_config.lua found - using built-in defaults"
do
  local paths = {"/home/meteor_config.lua"}
  local okShell, shell = pcall(require, "shell")
  if okShell and shell and shell.resolve then
    local okR, p = pcall(shell.resolve, "meteor_config.lua")
    if okR and p then paths[#paths + 1] = p end
  end
  local fs = require("filesystem")
  for _, path in ipairs(paths) do
    if fs.exists(path) then
      local ok, result = pcall(dofile, path)
      if not ok then error("Error in " .. path .. ": " .. tostring(result), 0) end
      if type(result) ~= "table" then error(path .. " must end with: return { ... }", 0) end
      USER = result
      CONFIG_NOTE = "Settings loaded from " .. path
      break
    end
  end
end

local function cfg(name, default)
  local v = USER[name]
  if v == nil then return default end
  return v
end

-- =====================================================================
-- CONFIG
-- =====================================================================

-- ---- Catalyst chest and dropper (transposer sides) ----
-- ME Interfaces with the catalysts, one entry per transposer side that has one.
-- Add more sides when you attach more Interfaces (never the dropper's side).
local SOURCE_SIDES = cfg("SOURCE_SIDES", {sides.up})
local DROPPER_SIDE = cfg("DROPPER_SIDE", sides.down)     -- dropper (below the transposer, holds max 1 catalyst)

-- ---- Redstone outputs ----
-- side: side of the redstone component the signal comes out of.
-- addr: optional address prefix of a specific Redstone I/O or card.
--       Leave it out to use the computer's default redstone component.
local OUT = cfg("OUT", {
  dropper = {addr = "c6352", side = sides.east},   -- fires the dropper (Redstone I/O c6352, dropper to the east)
  ritual  = {addr = "b8a3b", side = sides.south},   -- one-time start pulse for the ritual (Dynamism Tablet, Redstone I/O b8a3b)
  miners  = {addr = "e676d", side = sides.north},   -- one-time start pulse for the GT miners (Redstone I/O e676d)
  quarry  = {side = sides.north},   -- starts the Ender Quarry
})

-- ---- Component addresses (the first few characters are enough) ----
-- List them with:  components
local ME_ADDR = cfg("ME_ADDR", "00bd")              -- me_controller or me_interface

-- One entry per GT miner controller (max 16, shown as M01..M16).
-- Delete the lines of miners you do not have.
local MINER_ADDRS = cfg("MINER_ADDRS", {
  "68e3", "2db5", "7684", "6227",   -- M01-M04
  "d7b2", "64ff", "2ab2", "7885",   -- M05-M08
  "43e2", "7568", "9d1d", "72da",   -- M09-M12
  "cc18", "132b", "d16b", "5e9c",   -- M13-M16
})

-- ---- Drilling Fluid in the ME system ----
local FLUID_MATCH = cfg("FLUID_MATCH", "Drilling Fluid")  -- searched in fluid label/name (case, spaces, _ ignored)
local FLUID_START_MIN = cfg("FLUID_START_MIN", 20000)       -- mB needed to summon a new meteor
local FLUID_RUN_MIN = cfg("FLUID_RUN_MIN", 1000)        -- mB below which idle miners are not trusted
local FLUID_BAR_MAX = cfg("FLUID_BAR_MAX", 100000000)     -- mB shown as a full bar

-- ---- Meteors (max 12 with this screen layout) ----
-- label:    text on the button (max 17 characters)
-- catalyst: the catalyst, either the internal name ("modid:item") or the name shown
--           in the game ("Exquisite Diamond"); a text with ':' is taken as internal name
-- damage:   optional item damage / metadata (only used to find the ME crafting pattern)
--           (check with tp.getStackInSlot(sides.up, slot).name)
-- short:    optional shorter catalyst text for the screen (max 24 characters)
-- tier, lp: shown on the button (machine tier and Life Point cost, information only)
-- quarry:   true if the meteor has filler blocks for the Ender Quarry
-- A meteor whose label is still "Meteor N" or "Slot N" counts as not set up and cannot be queued.
local METEORS = cfg("METEORS", {
  {label = "Graphite",             catalyst = "Exquisite Diamond",               tier = "N/A", lp = 420000,    quarry = true},
  {label = "Overworld",            catalyst = "Field Generator (LV)",            tier = "LV",  lp = 600000,    quarry = false},
  {label = "Nether",               catalyst = "Advanced Replicator",             tier = "MV",  lp = 1200000,   quarry = false},
  {label = "End",                  catalyst = "Advanced Circuit Assembler II", short = "Adv. Circuit Assem. II", tier = "HV",  lp = 3250000,   quarry = true},
  {label = "BartWorks",            catalyst = "Elite Packager",                  tier = "LuV", lp = 10000000,  quarry = false},
  {label = "Platinum",             catalyst = "Advanced Scanner IV",             tier = "IV",  lp = 12500000,  quarry = false},
  {label = "Naquadah",             catalyst = "Crystal Mainframe",               tier = "ZPM", lp = 25000000,  quarry = false},
  {label = "Samarium",             catalyst = "Elite Circuit Assembler II", short = "Elite Circuit Assem. II", tier = "ZPM", lp = 80000000,  quarry = false},
  {label = "Gems",                 catalyst = "Bloody Ichorium Fusion Crafting", short = "Bloody Ichorium Fus. Cr.", tier = "ZPM", lp = 90000000,  quarry = false},
  {label = "Samarium+Neutron.",    catalyst = "Elite Mass Fabricator II",        tier = "ZPM", lp = 100000000, quarry = false},
  {label = "Indium",               catalyst = "Wetware Supercomputer",           tier = "UV",  lp = 50000000,  quarry = false},
  {label = "SpNt+FluxElectrum",    catalyst = "Ultimate Botanical Architect", short = "Ult. Botanical Architect", tier = "UV",  lp = 125000000, quarry = false},
})

-- ---- Crafting the catalysts in the ME system ----
-- The catalysts are taken by the transposer from the ME Interface above it (the
-- Interface must show them in its slots, e.g. through its configuration).
-- When the ME network does not hold the catalyst of a clicked meteor, a crafting request
-- (1 piece) is sent to the ME system. The meteor waits in the queue ("crafting") until
-- the craft is done and the item shows up in the Interface.
local CRAFT_MISSING = cfg("CRAFT_MISSING", true)      -- false: a missing catalyst is simply refused
local CRAFT_RETRY = cfg("CRAFT_RETRY", 10)        -- seconds before a failed or canceled craft is requested again

-- ---- Timing (seconds) ----
local START_DELAY = cfg("START_DELAY", 5)     -- after the catalyst drop, before the miners' start pulse
local START_TIMEOUT = cfg("START_TIMEOUT", 180)   -- how long to wait for the miners to start
local IDLE_CONFIRM = cfg("IDLE_CONFIRM", 3)    -- how long ALL miners must be OFF to count the meteor as mined
local QUARRY_TIME = cfg("QUARRY_TIME", 120)   -- how long the Ender Quarry gets to finish
local MINERS_PULSE = cfg("MINERS_PULSE", 1.0)   -- length of the miners' start pulse
local MINER_START_GRACE = cfg("MINER_START_GRACE", 15)  -- a miner still idle this long after the start pulse is shown as OFF (problem)

-- ---- Ritual start (Dynamism Tablet) ----
-- One pulse on OUT.ritual starts the ritual, RITUAL_DELAY seconds after the catalyst was dropped
-- (first meteor of a program run).
local RITUAL_PULSE = cfg("RITUAL_PULSE", 1.0)    -- length of the pulse
local RITUAL_DELAY = cfg("RITUAL_DELAY", 1)      -- seconds after the catalyst drop before the ritual start pulse
local RITUAL_EACH_METEOR = cfg("RITUAL_EACH_METEOR", false)  -- true: send the pulse before every meteor instead of once

-- ---- Screen resolution ----
-- nil: fit the screen's shape automatically (uses extra rows for spacing).
-- Or set it by hand, e.g. {80, 50}. The layout is designed for 80 columns.
local RESOLUTION = cfg("RESOLUTION", nil)

-- ---- Ender Quarry signal ----
-- "pulse": one short pulse starts it, then we just wait QUARRY_TIME
-- "hold":  signal stays on for QUARRY_TIME, then goes off
local QUARRY_SIGNAL = cfg("QUARRY_SIGNAL", "pulse")
local QUARRY_PULSE = cfg("QUARRY_PULSE", 1.0)   -- length of the pulse in "pulse" mode

-- ---- Miners switched off by your own shutdown method ----
-- true: miners disabled via machine controller cover / soft mallet count as OFF.
-- false: such miners block the meteor from being counted as mined.
local IGNORE_DISABLED = cfg("IGNORE_DISABLED", true)

-- ---- Clock shown on the screen (real-world time) ----
-- Fixed offset from UTC in hours: 1 = UTC+1 (use 2 for summer time).
local TIMEZONE_HOURS = cfg("TIMEZONE_HOURS", 1)

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
local pulseAt = nil           -- uptime of that pulse
local finishedAt = nil        -- uptime when the last meteor was fully mined
local curHasQuarry = nil      -- does the meteor being processed have a filler step
local ritualStarted = false   -- ritual start pulse already sent (once per program run)
local ritualPending = false   -- catalyst dropped, ritual start pulse still to be sent
local idleSince = nil         -- uptime since when all miners have been OFF
local fluid = nil             -- Drilling Fluid in ME (mB), nil = unknown
local fluidNote = nil         -- short reason shown when fluid is unknown
local nextFluidPoll = 0
local minersOk = false        -- every miner answered the last poll
local progress = nil          -- 0..1 progress of a timed step (nil = none)

-- Event log (newest first) and the last user action, both shown on the screen.
local events = {}
local lastAction = nil           -- {text, at} of the latest touch action

-- Real-world time: the modification time of a freshly written file is the real clock of the
-- server (the in-game os.time() is not). Read once, then advanced with the uptime.
local clockBase = nil           -- {real = epoch seconds, up = uptime}

local function realEpoch()
  local ok, t = pcall(function()
    local fs = require("filesystem")
    local path = "/tmp/.meteor_clock"
    local f = io.open(path, "w")
    if f then f:write("x"); f:close() end
    return math.floor(fs.lastModified(path) / 1000)
  end)
  if ok and type(t) == "number" and t > 0 then return t end
  return nil
end

-- Seconds since midnight of the shown time zone, or nil when the real time is unknown.
local function clockSeconds()
  local up = computer.uptime()
  if not clockBase or up - clockBase.up > 600 then
    local t = realEpoch()
    if t then clockBase = {real = t, up = up} end
  end
  if not clockBase then return nil end
  return (clockBase.real + math.floor(up - clockBase.up) + TIMEZONE_HOURS * 3600) % 86400
end

local function clockText()
  local t = clockSeconds()
  if not t then return "--:--:--" end
  return string.format("%02d:%02d:%02d", math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
end

local function nowText()
  return clockText():sub(1, 5)
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
      if m.active then m.worked = true end        -- ran during this meteor
      -- switched off by soft mallet / redstone (skipped if the method is missing)
      local ok2, allowed = pcall(m.proxy.isWorkAllowed)
      if ok2 and allowed == false and not IGNORE_DISABLED then m.disabled = true end
    end
    if m.active == nil then minersOk = false end

    -- a miner that never started after the start pulse has a problem (power, maintenance, ...)
    if m.active then
      m.failed = false
    elseif m.active == false and not m.worked and pulsed and pulseAt
        and (state == "wait_start" or state == "mining")
        and now - pulseAt > MINER_START_GRACE then
      if not m.failed then logEvent(m.name .. " did not start (power / maintenance?)", 0xFF7777) end
      m.failed = true
    end
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
  pulseAt = nil
  finishedAt = nil
  ritualPending = RITUAL_EACH_METEOR or not ritualStarted
  curHasQuarry = METEORS[queue[1].m].quarry and true or false
  for _, m in ipairs(MINERS) do m.worked = false; m.failed = false end
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
  summon(now)
end

local function stepWaitStart(now)
  if ritualPending then
    -- the ritual starts RITUAL_DELAY seconds after the catalyst drop
    local left = RITUAL_DELAY - elapsed(now)
    if left > 0 then
      status = "Ritual starts in " .. math.ceil(left) .. " s"
      return
    end
    pulseOut("ritual", RITUAL_PULSE)
    ritualStarted = true
    ritualPending = false
    status = "Ritual start signal sent"
    logEvent("Ritual start signal sent", 0x9FD8FF)
    return
  end
  if anyActive() then
    idleSince = nil
    setState("mining", "Mining in progress")
  elseif not pulsed and elapsed(now) >= START_DELAY then
    -- sent only while no miner runs, so a toggle (T flip-flop) cannot switch them off
    pulseOut("miners", MINERS_PULSE)
    pulsed = true
    pulseAt = computer.uptime()
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
  finishedAt = computer.uptime()
  setState("idle", "Meteor fully mined")
end

local STEPS = {
  idle       = stepIdle,
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
--   row 1-2   title bar
--   left      the meteor list (12 rows)
--   right     cards: STATE, GT MINERS, DRILLING FLUID, QUEUE and below it START / CLEAR QUEUE / EXIT
--   last row  message about your last touch
-- On a taller screen the meteor buttons get taller and the queue card longer.

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
local RX, RW = 42, 38                          -- right column (cards)
local CTRL_Y = H - 3                           -- controls: rows H-3 .. H-1 (same bottom as the queue card)
local PER = math.max(1, math.floor((H - 5) / 12))   -- screen rows per meteor in the list card (12 meteors, rows 4 .. H-2)
local STATE_Y, MINERS_Y, FLUID_Y = 3, 8, 14     -- card tops (state 3-7, miners 8-13, fluid 14-16)
local QUEUE_Y = 17                             -- queue card: rows 17 .. CTRL_Y-1; the controls sit below it
local QUEUE_ROWS = CTRL_Y - QUEUE_Y - 2         -- content rows of the queue card (rows QUEUE_Y+1 .. CTRL_Y-2)

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

-- Line-drawing characters (built at runtime so this file stays plain ASCII).
local CH = {
  tl = unicode.char(0x250C), tr = unicode.char(0x2510),
  bl = unicode.char(0x2514), br = unicode.char(0x2518),
  h  = unicode.char(0x2500), v  = unicode.char(0x2502),
  hh = unicode.char(0x2501), vv = unicode.char(0x2503),
  dot = unicode.char(0x25CF), ring = unicode.char(0x25CB), check = unicode.char(0x2713),
}

-- ---------- colors (neon on near-black) ----------
local C = {
  bg = 0x03050A, card = 0x090C14, face = 0x0B0F18,
  neon = 0x00B4FF, red = 0xFF2A3D, green = 0x2BE05A, amber = 0xFFB020, yellow = 0xFFE14D,
  text = 0xFFFFFF, dim = 0x6B7A8F, track = 0x1E2C40, line = 0x14507A,
}

local STATE_BIG = {
  idle = "IDLE", ritual = "RITUAL", wait_start = "STARTING",
  mining = "MINING", quarry = "QUARRY", finish = "FINISH",
}

local STATE_COLOR = {
  idle = 0xB0BCCB, ritual = 0xFF2A3D, wait_start = 0xFFB020,
  mining = 0x00B4FF, quarry = 0xFF2A3D, finish = 0x2BE05A,
}

local function spaced(text)
  return (text:gsub(".", "%0 "):sub(1, -2))
end

-- ---------- buttons ----------
local buttons = {}

local function addButton(b)
  buttons[#buttons + 1] = b
  return b
end

-- Colors of the machine tiers in the meteor list
local TIER_COLOR = {
  ["LV"] = 0xDCE6F2, ["MV"] = 0xFF8A1F, ["HV"] = 0xFFE14D,
  ["IV"] = 0x00B4FF, ["LuV"] = 0xFF3DDC, ["ZPM"] = 0x2EF0F0, ["UV"] = 0x2BE05A,
}

-- Meteor buttons: dark face with a neon stripe. Control buttons: neon outline.
-- The touched button lights up (filled neon) for a moment.
local function drawButton(b, pressed)
  local base = b.color and b.color() or C.neon
  local label = type(b.label) == "function" and b.label() or b.label
  if b.outline then
    local bg = pressed and base or C.card
    gpu.setBackground(bg)
    gpu.fill(b.x, b.y, b.w, b.h, " ")
    if not pressed then
      local hl = string.rep(CH.h, b.w - 2)
      put(b.x, b.y, CH.tl .. hl .. CH.tr, base, C.card)
      put(b.x, b.y + b.h - 1, CH.bl .. hl .. CH.br, base, C.card)
      for r = b.y + 1, b.y + b.h - 2 do
        put(b.x, r, CH.v, base, C.card)
        put(b.x + b.w - 1, r, CH.v, base, C.card)
      end
    end
    put(b.x + math.floor((b.w - unicode.len(label)) / 2), b.y + math.floor(b.h / 2), label,
      pressed and C.bg or base, bg)
    return
  end
  local faceH = b.faceH or math.max(1, b.h - 1)   -- the last row stays empty: gap to the next button
  local bg, fg = b.empty and 0x06080D or (b.alt and 0x101826 or C.face), b.empty and C.dim or C.text
  local stripe = b.stripe()
  if pressed then bg, fg = stripe, C.bg end
  gpu.setBackground(b.gapBg or C.bg)
  gpu.fill(b.x, b.y, b.w, b.h, " ")
  gpu.setBackground(bg)
  gpu.fill(b.x, b.y, b.w, faceH, " ")
  if not b.noStripe then
    gpu.setBackground(stripe)
    gpu.fill(b.x, b.y, 1, faceH, " ")
  end
  -- text area: right of the stripe. A long name wraps to a second line when the cell is
  -- tall enough, otherwise it is shortened with a dot.
  local tw = b.w - 2
  if b.info then
    -- meteor row: name, tier, LP cost, FILL mark; the catalyst on the second row when there is room
    local inf = b.info
    local nm = inf.name
    if unicode.len(nm) > 24 then nm = unicode.sub(nm, 1, 23) .. "." end
    local cTier = pressed and C.bg or (TIER_COLOR[inf.tier] or C.dim)
    local cDim = pressed and C.bg or C.dim
    local cLP = pressed and C.bg or C.red
    local cLight = pressed and C.bg or (inf.filler and C.green or C.red)
    -- columns (b.x+1 = first text column): name / catalyst 24 wide, tier +25, LP cost +30, filler light +36
    local y0 = b.y
    put(b.x + 1, y0, nm, fg, bg, 24)
    put(b.x + 25, y0, inf.tier or "", cTier, bg, 3)
    put(b.x + 30, y0, inf.lp or "", cLP, bg, 5)
    put(b.x + 36, y0, CH.dot, cLight, bg)
    if faceH >= 2 then
      local cat = inf.catalyst
      if unicode.len(cat) > 24 then cat = unicode.sub(cat, 1, 23) .. "." end
      put(b.x + 1, y0 + 1, cat, cDim, bg, 24)
      put(b.x + 25, y0 + 1, string.rep(" ", 13), fg, bg)
    end
    return
  end
  local line1, line2 = label, nil
  if unicode.len(label) > tw then
    if faceH >= 2 then
      local cut = tw
      while cut > 1 and unicode.sub(label, cut + 1, cut + 1) ~= " " do cut = cut - 1 end
      if cut <= 1 then cut = tw end
      line1 = unicode.sub(label, 1, cut)
      line2 = unicode.sub(label, cut + 1):gsub("^ +", "")
      if unicode.len(line2) > tw then line2 = unicode.sub(line2, 1, tw - 1) .. "." end
    else
      line1 = unicode.sub(label, 1, tw - 1) .. "."
    end
  end
  if line2 then
    local y0 = b.y + math.floor((faceH - 2) / 2)
    put(b.x + 2, y0, line1, fg, bg, tw)
    put(b.x + 2, y0 + 1, line2, fg, bg, tw)
  else
    put(b.x + 2, b.y + math.floor((faceH - 1) / 2), line1, fg, bg, tw)
  end
end

assert(#METEORS <= 12, "Screen layout has room for max. 12 meteors")

-- LP cost as a short text: 420k, 1.2M, 125M
local function fmtLP(n)
  if not n then return "" end
  local t
  if n >= 1000000 then
    t = string.format("%.2f", n / 1000000):gsub("0+$", ""):gsub("%.$", "") .. "M"
  else
    t = string.format("%d", math.floor(n / 1000 + 0.5)) .. "k"
  end
  return t
end

-- Meteor list: one entry per row group, the whole left part of the screen. Set-up meteors (catalyst
-- given and renamed from the default "Meteor N" / "Slot N") are buttons (the others stay dim and cannot be queued.
for i = 1, #METEORS do
  local m = METEORS[i]
  local lbl = tostring(m.label)
  local ready = m.catalyst and m.catalyst ~= "" and not lbl:match("^Meteor %d+$") and not lbl:match("^[Ss]lot %d+$")
  addButton({
    x = 2, y = 4 + (i - 1) * PER, w = 38, h = PER, faceH = (PER >= 3) and (PER - 1) or PER, gapBg = C.card, noStripe = true,
    empty = not ready, alt = (i % 2 == 0),
    label = lbl,
    info = ready and {
      name = lbl, catalyst = tostring(m.short or m.catalyst), tier = m.tier,
      lp = fmtLP(m.lp), filler = m.quarry,
    } or nil,
    stripe = function()
      if not ready then return C.track end
      return C.neon
    end,
    action = function()
      if ready then
        enqueue(i)
      else
        logEvent(lbl .. " is not set up (METEORS)", C.amber, true)
      end
    end,
  })
end

local startBtn = addButton({
  x = RX, y = CTRL_Y, w = 12, h = 3, outline = true,
  label = function() return running and "STOP" or "START" end,
  color = function() return running and C.red or C.green end,
  action = function()
    running = not running
    logEvent(running and "Started" or "Stopped", running and 0x66FF99 or 0xFF7777, true)
  end,
})

addButton({
  x = RX + 13, y = CTRL_Y, w = 15, h = 3, outline = true, label = "CLEAR QUEUE",
  color = function() return C.amber end,
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
  x = RX + 29, y = CTRL_Y, w = 9, h = 3, outline = true, label = "EXIT",
  color = function() return C.red end,
  id = "exit",
})

-- Lights up the touched button for a moment, then runs its action.
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

-- Thin neon bar: heavy line = filled part, light line = rest. Returns the filled length.
local function drawThin(x, y, w, frac, color, bg)
  local fill = math.max(0, math.min(w, math.floor((frac or 0) * w + 0.5)))
  put(x, y, string.rep(CH.hh, fill), color, bg or C.card)
  if fill < w then put(x + fill, y, string.rep(CH.h, w - fill), C.track, bg or C.card) end
  return fill
end

-- Top edge of a card with its title (left) and a value (right).
local function cardTop(x, y, w, title, right, rightColor)
  put(x, y, CH.tl .. string.rep(CH.h, w - 2) .. CH.tr, C.neon, C.card)
  put(x, y, CH.tl, C.red, C.card)
  put(x + 2, y, " " .. title .. " ", C.text, C.card)
  if right then
    local t = " " .. right .. " "
    put(x + w - 2 - unicode.len(t), y, t, rightColor or C.dim, C.card)
  end
end

local function cardFrame(x, y, w, h, title)
  gpu.setBackground(C.card)
  gpu.fill(x, y, w, h, " ")
  cardTop(x, y, w, title)
  put(x, y + h - 1, CH.bl .. string.rep(CH.h, w - 2) .. CH.br, C.neon, C.card)
  put(x + w - 1, y + h - 1, CH.br, C.red, C.card)
  for r = y + 1, y + h - 2 do
    put(x, r, CH.v, C.neon, C.card)
    put(x + w - 1, r, CH.v, C.neon, C.card)
  end
end

local function drawStatic()
  gpu.setBackground(C.bg)
  gpu.fill(1, 1, W, H, " ")
  -- title bar
  local titleX = math.floor((W - 22) / 2) + 1        -- "METEOR RITUAL by Sixxo" is 22 wide
  put(titleX, 1, "METEOR RITUAL", C.text, C.bg)
  put(titleX + 14, 1, "by Sixxo", C.neon, C.bg)
  put(1, 2, string.rep(CH.h, W), C.line, C.bg)
  put(1, 2, string.rep(CH.hh, 12), C.red, C.bg)
  -- left caption
  -- meteor list card: the column titles sit in its top border, above their columns
  cardFrame(1, 3, 40, H - 3, "")
  put(2, 3, " METEOR ", C.text, C.card)
  put(26, 3, " TIER ", C.text, C.card)
  put(31, 3, " LP ", C.text, C.card)
  put(35, 3, " FILL", C.text, C.card)
  -- cards
  cardFrame(RX, STATE_Y, RW, 5, "STATE")
  cardFrame(RX, MINERS_Y, RW, 6, "GT MINERS")
  cardFrame(RX, FLUID_Y, RW, 3, "DRILLING FLUID")
  cardFrame(RX, QUEUE_Y, RW, CTRL_Y - QUEUE_Y, "QUEUE")
  for _, b in ipairs(buttons) do drawButton(b) end
  drawnRunning = running
end

local function drawTitle()
  put(2, 1, clockText(), 0xB0BCCB, C.bg, 8)
  local label, color = "[ STOPPED ]", C.red
  if running then label, color = "[ RUNNING ]", C.green end
  put(W - #label - 1, 1, label, color, C.bg)
end

-- Phase of the current meteor: 0 none, 1 summoning, 2 GT miners, 3 filler blocks (Ender Quarry),
-- 4 finishing, 5 meteor mined (kept until the next meteor starts).
local function currentPhase()
  if state == "wait_start" and ritualPending then return 1 end
  if state == "wait_start" or state == "mining" then return 2 end
  if state == "quarry" then return 3 end
  if state == "finish" then return 4 end
  if finishedAt and computer.uptime() - finishedAt < 8 then return 5 end
  if running and queue[1] and queue[1].loc ~= "fired" then return 1 end
  return finishedAt and 5 or 0          -- stays on "Meteor mined" until the next meteor starts
end

local PHASE_NAMES = {"Summoning meteor", "Mining - GT Miners", "Mining filler blocks", "Meteor mined"}

local PHASE_COLOR = {C.neon, C.yellow, 0xB07CFF, C.green}

-- Shows only the phase that is running now (phase 5 = the meteor is mined).
local function drawStatus()
  local phase = currentPhase()
  if phase == 5 then phase = 4 end
  put(RX + 2, STATE_Y + 1, "PHASE " .. phase .. "/4  ", C.dim, C.card, 10)
  if phase == 0 then
    put(RX + 12, STATE_Y + 1, "Ready to summon Meteor", C.text, C.card, RW - 14)
  else
    put(RX + 12, STATE_Y + 1, PHASE_NAMES[phase], PHASE_COLOR[phase], C.card, RW - 14)
  end

  local bad = false
  local low = status:lower()
  for _, w in ipairs({"timeout", "unreachable", "missing", "disabled", "low ", "failed", "waiting for fluid", "not in interface", "no me pattern", "canceled", "rejected"}) do
    if low:find(w, 1, true) then bad = true end
  end
  if phase == 0 and (status == "Ready" or status == "Queue is empty") then
    put(RX + 2, STATE_Y + 2, "", C.text, C.card, RW - 4)
  else
    put(RX + 2, STATE_Y + 2, status, bad and C.amber or C.text, C.card, RW - 4)
  end

  drawThin(RX + 2, STATE_Y + 3, 29, progress or 0, C.neon)
  put(RX + 32, STATE_Y + 3, progress and string.format(" %3d%%", math.floor(progress * 100)) or "    -", C.dim, C.card, 5)
end

-- miners: 4 x 4 neon status lights, numbered down each column (M01-M04, M05-M08, ...)
local function drawMiners()
  local nOn, nOk, nOff = 0, 0, 0
  for i, m in ipairs(MINERS) do
    local c = math.floor((i - 1) / 4)       -- column by column: M01-M04 go down the first column
    local r = (i - 1) % 4
    -- yellow ON  = mining now
    -- green  OK  = finished and ready for the next meteor
    -- red    OFF = problem: did not start (power failure, maintenance, ...) or disabled
    -- grey   N/A = miner does not answer
    local tag, color
    if m.active == nil then
      tag, color = "N/A", C.dim
    elseif m.active then
      tag, color = "ON", C.yellow
      nOn = nOn + 1
    elseif m.failed or m.disabled then
      tag, color = "OFF", C.red
      nOff = nOff + 1
    else
      tag, color = "OK", C.green
      nOk = nOk + 1
    end
    local x, y = RX + 2 + c * 9, MINERS_Y + 1 + r
    put(x, y, m.name, C.text, C.card, 3)
    put(x + 4, y, tag, color, C.card, 3)
  end
  -- counters in the card title: ON always yellow, OK always green, OFF always red
  cardTop(RX, MINERS_Y, RW, "GT MINERS")
  local sOn, sOk, sOff = nOn .. " ON", nOk .. " OK", nOff .. " OFF"
  local total = #sOn + #sOk + #sOff + 4          -- 2 spaces between the counters
  local x0 = RX + RW - 3 - total
  put(x0 - 1, MINERS_Y, string.rep(" ", total + 2), C.text, C.card)
  put(x0, MINERS_Y, sOn, C.yellow, C.card)
  put(x0 + #sOn + 2, MINERS_Y, sOk, C.green, C.card)
  put(x0 + #sOn + #sOk + 4, MINERS_Y, sOff, C.red, C.card)
end

local function drawFluid()
  local enough = fluid and fluid >= FLUID_START_MIN
  local right
  if fluid then right = fmt(fluid) .. " mB" else right = "N/A [" .. (fluidNote or "?") .. "]" end
  cardTop(RX, FLUID_Y, RW, "DRILLING FLUID", right,
    fluid and (enough and C.green or C.red) or C.amber)
  local barW = RW - 4
  local color = enough and C.neon or C.red
  drawThin(RX + 2, FLUID_Y + 1, barW, fluid and (fluid / FLUID_BAR_MAX) or 0, color)
  -- red tick = current amount on the 0 .. FLUID_BAR_MAX scale
  local frac = fluid and math.max(0, math.min(1, fluid / FLUID_BAR_MAX)) or 0
  local mark = math.min(barW - 1, math.floor(frac * barW))
  put(RX + 2 + mark, FLUID_Y + 1, CH.vv, C.red, C.card)
end

local function drawQueue()
  cardTop(RX, QUEUE_Y, RW, "QUEUE", #queue .. " QUEUED", C.dim)
  for r = 1, QUEUE_ROWS do
    local line, fg, tag, tagColor = "", C.text, nil, C.dim
    local e = queue[r]
    if r == QUEUE_ROWS and #queue > QUEUE_ROWS then
      line, fg = "  ... +" .. (#queue - QUEUE_ROWS + 1) .. " more", C.dim
    elseif e then
      local mt = METEORS[e.m]
      local active = e.loc == "fired"
      line = string.format("%s%2d  %s", active and ">" or " ", r, mt.label)
      if mt.quarry then fg = 0xFF7A86 end
      if active then
        tag, tagColor, fg = "ACTIVE", C.neon, C.neon
      elseif e.loc == "dropper" then
        tag = "in dropper"
      elseif e.loc == "crafting" then
        tag, tagColor = e.note and "craft retry" or "crafting", C.amber
      else
        tag = "waiting"
      end
    end
    local y = QUEUE_Y + r
    put(RX + 2, y, line, fg, C.card, RW - 4)
    if tag then put(RX + RW - 2 - #tag - 1, y, tag, tagColor, C.card) end
  end
end

-- Last event / touch action: bright for a few seconds after your touch, then dim.
local function drawMessage()
  local e = events[1]
  local text, fg, bg = " touch a button to start", C.dim, C.bg
  if e then
    local fresh = e.action and (computer.uptime() - e.at < 4)
    text = " " .. e.t .. "  " .. e.text
    if fresh then fg, bg = C.bg, C.neon else fg = C.dim end
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
  logEvent(CONFIG_NOTE, 0x7FD1FF)
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
