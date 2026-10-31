-- =====================================================================
-- Settings for meteor.lua (Meteor Ritual Controller by Sixxo)
--
-- Save this file as /home/meteor_config.lua. Updating meteor.lua never
-- touches it. Everything you leave out (or comment out with --) uses the
-- default from meteor.lua.
-- =====================================================================
local sides = require("sides")

return {
  -- ---- Transposer ----
  -- ME Interfaces with the catalysts (one entry per transposer side) and the dropper.
  SOURCE_SIDES = {sides.up},
  DROPPER_SIDE = sides.down,

  -- ---- Redstone outputs ----
  -- side: side of the Redstone I/O the signal comes out of
  -- addr: optional address prefix of a specific Redstone I/O (leave out for the default one)
  OUT = {
    dropper = {side = sides.up},      -- fires the dropper
    ritual  = {side = sides.east},    -- one-time start pulse for the ritual (Dynamism Tablet)
    miners  = {side = sides.south},   -- one-time start pulse for the GT miners
    quarry  = {side = sides.north},   -- starts the Ender Quarry
  },

  -- ---- Component addresses (first few characters are enough; list with: components) ----
  ME_ADDR = "00bd",
  MINER_ADDRS = {
    "68e3", "2db5", "7684", "6227",   -- M01-M04
    "d7b2", "64ff", "2ab2", "7885",   -- M05-M08
    "43e2", "7568", "9d1d", "72da",   -- M09-M12
    "cc18", "132b", "d16b", "5e9c",   -- M13-M16
  },

  -- ---- Meteors (max 16) ----
  -- label:    text on the button (max 17 characters)
  -- catalyst: internal name ("modid:item") or the name shown in the game
  -- quarry:   true if the Ender Quarry should clear filler blocks afterwards
  -- A label that is still "Meteor N" or "Slot N" means "not set up" (cannot be queued).
  METEORS = {
    {label = "Exquisite Diamond", catalyst = "Exquisite Diamond", quarry = false},
    {label = "Slot 2",            catalyst = "minecraft:gold_block",    quarry = true},
    {label = "Slot 3",            catalyst = "minecraft:diamond_block", quarry = true},
  },

  -- ---- Timing (seconds) ----
  QUARRY_TIME = 120,        -- how long the Ender Quarry gets to finish

  -- Other settings you may want to change (uncomment to use):
  -- FLUID_START_MIN    = 20000,    -- mB of Drilling Fluid needed to summon a meteor
  -- START_DELAY        = 5,        -- after the catalyst drop, before the miners' start pulse
  -- START_TIMEOUT      = 180,      -- how long to wait for the miners to start
  -- IDLE_CONFIRM       = 20,       -- how long ALL miners must be idle to count the meteor as mined
  -- MINER_START_GRACE  = 15,       -- idle this long after the start pulse = shown as OFF (problem)
  -- RITUAL_WARMUP      = 5,        -- seconds between the ritual pulse and the catalyst drop
  -- RITUAL_EACH_METEOR = false,    -- true: ritual pulse before every meteor
  -- QUARRY_SIGNAL      = "pulse",  -- "pulse" or "hold"
  -- CRAFT_MISSING      = true,     -- false: do not craft missing catalysts
  -- TIMEZONE_HOURS     = 1,        -- clock offset from UTC (2 in summer time)
  -- RESOLUTION         = {80, 50}, -- fixed screen resolution instead of auto fit
}
