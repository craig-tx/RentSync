-- Blocks a PMS client for every instance, keeping a later block already set (research R6).
-- KEYS[1]  the key; its value is the end of the block, in ms
-- ARGV[1]  block length (ms)
-- ARGV[2]  optional now_ms; when absent, Redis TIME is the single clock for every instance
-- Returns the end of the block in force (ms)
local now
if ARGV[2] ~= nil and ARGV[2] ~= '' then
  now = tonumber(ARGV[2])
else
  local t = redis.call('TIME')
  now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end

local wanted = now + tonumber(ARGV[1])
local current = tonumber(redis.call('GET', KEYS[1]))
if current == nil or current < wanted then
  -- The key outlives the block by a minute; the value, not the expiry, is what counts.
  redis.call('SET', KEYS[1], tostring(wanted), 'PX', tonumber(ARGV[1]) + 60000)
  return wanted
end
return current
