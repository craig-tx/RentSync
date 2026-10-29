-- Per-client token bucket, updated atomically (research R8).
-- KEYS[1]  bucket hash {tokens, ts_ms}
-- ARGV[1]  capacity (requests per window)
-- ARGV[2]  window_ms (60000 for "per minute")
-- ARGV[3]  optional now_ms; when absent, Redis TIME is the single clock for every web instance
-- Returns {allowed (0|1), retry_after_ms, remaining}
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local window_ms = tonumber(ARGV[2])
local now
if ARGV[3] ~= nil and ARGV[3] ~= '' then
  now = tonumber(ARGV[3])
else
  local t = redis.call('TIME')
  now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end

local state = redis.call('HMGET', key, 'tokens', 'ts_ms')
local tokens = tonumber(state[1])
local ts = tonumber(state[2])
if tokens == nil or ts == nil then
  tokens = capacity
  ts = now
end

-- Refill continuously; elapsed * capacity / window keeps whole-token refills exact.
local elapsed = math.max(0, now - ts)
tokens = math.min(capacity, tokens + (elapsed * capacity) / window_ms)

local allowed = 0
local retry_after_ms = 0
if tokens >= 1 then
  tokens = tokens - 1
  allowed = 1
else
  retry_after_ms = math.ceil(((1 - tokens) * window_ms) / capacity)
end

redis.call('HSET', key, 'tokens', tostring(tokens), 'ts_ms', tostring(now))
-- An idle client's bucket is full again after one window; let the key lapse then.
redis.call('PEXPIRE', key, window_ms + 1000)
return { allowed, retry_after_ms, math.floor(tokens) }
