-- minerinfo: prints everything a GT machine adapter tells about one miner.
-- Usage:  minerinfo 68e3        (the first characters of the adapter address)
-- Run it once on a healthy miner and once on a miner with a power / maintenance
-- problem, and compare the output.
local component = require("component")

local prefix = ({...})[1]
if not prefix then
  print("Usage: minerinfo <address prefix>")
  print("Addresses of gt_machine components:")
  for addr in component.list("gt_machine") do print("  " .. addr) end
  return
end

local found
for addr in component.list("gt_machine") do
  if addr:sub(1, #prefix) == prefix then found = addr; break end
end
if not found then print("No gt_machine with address starting " .. prefix); return end

local proxy = component.proxy(found)
print("Machine: " .. found)
local names = {}
for name in pairs(component.methods(found)) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
  -- only getters / is.. / has.. (they take no arguments and change nothing)
  if name:match("^get") or name:match("^is") or name:match("^has") then
    local ok, a, b, c = pcall(proxy[name])
    if ok then
      if type(a) == "table" then
        print(name .. ":")
        for k, v in pairs(a) do print("   " .. tostring(k) .. " = " .. tostring(v)) end
      else
        print(name .. " = " .. tostring(a) .. (b ~= nil and (", " .. tostring(b)) or "") .. (c ~= nil and (", " .. tostring(c)) or ""))
      end
    else
      print(name .. " -> error: " .. tostring(a):sub(1, 60))
    end
  end
end
