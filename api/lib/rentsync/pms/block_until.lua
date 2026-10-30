-- Sets a shared "blocked until" time for a PMS client, keeping a later one already set
-- (research R6). KEYS[1] the key; ARGV[1] until (ms); ARGV[2] key lifetime (ms).
local current = tonumber(redis.call('GET', KEYS[1]))
local wanted = tonumber(ARGV[1])
if current == nil or current < wanted then
  redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2])
  return wanted
end
return current
