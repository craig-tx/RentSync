-- How long a PMS client's shared block still has to run, by the same clock that set it.
-- KEYS[1]  the key written by block_until.lua
-- ARGV[1]  optional now_ms; when absent, Redis TIME
-- Returns the remaining ms, 0 when not blocked
local current = tonumber(redis.call('GET', KEYS[1]))
if current == nil then
  return 0
end

local now
if ARGV[1] ~= nil and ARGV[1] ~= '' then
  now = tonumber(ARGV[1])
else
  local t = redis.call('TIME')
  now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end
return math.max(0, current - now)
