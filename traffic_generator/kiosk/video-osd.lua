-- Live overlay for the video kiosk: turns the flood collision into something
-- you can read off the panel without a separate chart.
--
-- It draws, top-centre over the video:
--     * a big status word - PROTECTED (green) while the received stream is
--       healthy, DEGRADED (red) the moment bitrate collapses or frames drop.
--       This is the RECEIVER's verdict, not a claim that the video is
--       inherently prioritised: the flood (higher traffic class) breaks it by
--       default and CBS reserving the video's queue is what keeps it green.
--     * received video bitrate (Mbps) + cumulative dropped frames + the video's
--       traffic class, so the class competition is visible on the panel.
--     * a rolling sparkline of the received bitrate - the collapse is the story.
--
-- Positions are derived from the live osd size so it stays centred whichever way
-- the panel is rotated (portrait 720x1280 or landscape 1280x720).

local mp = require 'mp'
local assdraw = require 'mp.assdraw'

local ov = mp.create_osd_overlay('ass-events')

-- The video's traffic class on the wire. Best-effort by default (untagged UDP);
-- override with the VIDEO_TC env if the stream is tagged to another class.
local VIDEO_TC = os.getenv('VIDEO_TC') or 'TC0 · best-effort'

local peak = 0
local last_drop = 0
local degraded_hold = 0
local hist = {}
local HN = 64

local function mbps()
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
  hist[#hist + 1] = m
  if #hist > HN then table.remove(hist, 1) end

  local new_drops = d - last_drop
  last_drop = d
  if new_drops > 0 or (peak > 5 and m < peak * 0.75) then
    degraded_hold = 6
  elseif degraded_hold > 0 then
    degraded_hold = degraded_hold - 1
  end
  local degraded = degraded_hold > 0

  local status, colour
  if degraded then
    status, colour = 'DEGRADED', '2222DD'   -- ASS is BGR: red
  else
    status, colour = 'PROTECTED', '55AA55'   -- green
  end

  local ww = mp.get_property_number('osd-width', 1280)
  if ww == 0 then ww = 1280 end
  local cx = ww / 2

  local a = assdraw.ass_new()
  -- big status word
  a:new_event()
  a:append(string.format('{\\an8\\pos(%d,26)\\fs40\\b1\\1c&H%s&\\bord2\\3c&H000000&}%s',
                         cx, colour, status))
  -- info line: bitrate + drops + the video's traffic class
  a:new_event()
  a:append(string.format('{\\an8\\pos(%d,82)\\fs20\\b0\\1c&HFFFFFF&\\bord2\\3c&H000000&}'
                         .. 'RX %.1f Mbps    drops %d    VIDEO %s', cx, m, d, VIDEO_TC))

  -- rolling sparkline of received bitrate, scaled to its own peak
  local gw, gh, gx, gy = 260, 44, cx - 130, 112
  local pk = 1
  for _, v in ipairs(hist) do if v > pk then pk = v end end
  -- baseline box
  a:new_event()
  a:append(string.format('{\\an7\\pos(%d,%d)\\1a&HFF&\\3a&H90&\\3c&HFFFFFF&\\bord1\\p1}'
                         .. 'm 0 0 l %d 0 l %d %d l 0 %d{\\p0}', gx, gy, gw, gw, gh, gh))
  if #hist >= 2 then
    local parts = {}
    for i, v in ipairs(hist) do
      local x = (i - 1) / (HN - 1) * gw
      local y = gh - (v / pk) * gh
      parts[#parts + 1] = string.format('%s %.0f %.0f', (i == 1 and 'm' or 'l'), x, y)
    end
    a:new_event()
    a:append(string.format('{\\an7\\pos(%d,%d)\\1a&HFF&\\3c&H%s&\\bord2\\p1}%s{\\p0}',
                           gx, gy, colour, table.concat(parts, ' ')))
  end

  ov.data = a.text
  ov:update()
end

local timer = mp.add_periodic_timer(0.25, tick)

mp.register_event('shutdown', function()
  if timer then timer:kill() end
  ov:remove()
end)
