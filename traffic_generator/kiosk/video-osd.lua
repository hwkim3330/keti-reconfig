-- Live overlay for the video kiosk: turns the flood collision into something
-- you can read off the panel without a separate chart.
--
-- It draws, top-centre over the video:
--     * received video bitrate (Mbps), sampled from mpv's demuxer
--     * cumulative dropped / error frames since start
--     * a big status word - PROTECTED (green) while the stream is healthy,
--       DEGRADED (red) the moment bitrate collapses or frames start dropping.
--
-- The status is deliberately derived from what the *receiver* sees, so the
-- story reads the same whether the switch is a dumb one (flood on -> DEGRADED)
-- or a 9692 with CBS (flood on but video class reserved -> stays PROTECTED).

local mp = require 'mp'
local assdraw = require 'mp.assdraw'

local ov = mp.create_osd_overlay('ass-events')

-- Rolling baseline of the healthy bitrate so "collapse" is relative, not a
-- hard-coded Mbps that breaks when the demo video changes.
local peak = 0
local last_drop = 0
local degraded_hold = 0   -- keep DEGRADED latched briefly so it doesn't flicker

local function mbps()
  -- video-bitrate is the decoded elementary-stream rate mpv is currently
  -- seeing; when packets are lost it sags, which is exactly our signal.
  local b = mp.get_property_number('video-bitrate', 0) or 0
  return b / 1e6
end

local function drops()
  local a = mp.get_property_number('frame-drop-count', 0) or 0
  local b = mp.get_property_number('decoder-frame-drop-count', 0) or 0
  return a + b
end

local function tick()
  local m = mbps()
  local d = drops()
  if m > peak then peak = m end

  -- Degraded if frames dropped since last sample, or bitrate fell well under
  -- the healthy peak (a real collision shears off a big chunk).
  local new_drops = d - last_drop
  last_drop = d
  if new_drops > 0 or (peak > 5 and m < peak * 0.75) then
    degraded_hold = 6            -- ~1.5 s at 4 Hz
  elseif degraded_hold > 0 then
    degraded_hold = degraded_hold - 1
  end
  local degraded = degraded_hold > 0

  local status, colour
  if degraded then
    status, colour = 'DEGRADED', '2222DD'   -- ASS is BGR: this is red
  else
    status, colour = 'PROTECTED', '55AA55'   -- green
  end

  local a = assdraw.ass_new()
  -- top-centred block
  a:new_event()
  a:append(string.format('{\\an8\\pos(360,40)\\fs34\\b1\\1c&H%s&\\bord2\\3c&H000000&}%s',
                         colour, status))
  a:new_event()
  a:append(string.format('{\\an8\\pos(360,90)\\fs22\\b0\\1c&HFFFFFF&\\bord2\\3c&H000000&}'
                         .. 'RX %.0f Mbps    drops %d', m, d))
  ov.data = a.text
  ov:update()
end

local timer = mp.add_periodic_timer(0.25, tick)

mp.register_event('shutdown', function()
  if timer then timer:kill() end
  ov:remove()
end)
