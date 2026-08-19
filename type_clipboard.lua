local M = {}

local START_DELAY = 1.5
local BASE_DELAY = 0.055
local JITTER_MIN = 0.6
local JITTER_MAX = 1.6
local SENTENCE_PAUSE_MIN, SENTENCE_PAUSE_MAX = 0.25, 0.60
local CLAUSE_PAUSE_MIN, CLAUSE_PAUSE_MAX = 0.08, 0.20
local LINE_PAUSE_MIN, LINE_PAUSE_MAX = 0.20, 0.50
local SPACE_FACTOR = 0.8

local timer = nil
local running = false

local function randRange(lo, hi)
  return lo + math.random() * (hi - lo)
end

local function delayAfter(char)
  local delay = BASE_DELAY * randRange(JITTER_MIN, JITTER_MAX)
  if char == "\n" then
    return delay + randRange(LINE_PAUSE_MIN, LINE_PAUSE_MAX)
  elseif char:match("[%.%!%?]") then
    return delay + randRange(SENTENCE_PAUSE_MIN, SENTENCE_PAUSE_MAX)
  elseif char:match("[,;:]") then
    return delay + randRange(CLAUSE_PAUSE_MIN, CLAUSE_PAUSE_MAX)
  elseif char == " " then
    return delay * SPACE_FACTOR
  end
  return delay
end

local function splitCharacters(text)
  local chars = {}
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chars[#chars + 1] = char
  end
  return chars
end

local function finish(message)
  running = false
  timer = nil
  hs.alert.show(message, 1)
end

local function typeFrom(chars, index)
  if not running then
    return
  end

  if index > #chars then
    finish("Typing done")
    return
  end

  local char = chars[index]
  if char == "\n" then
    hs.eventtap.keyStroke({}, "return", 0)
  elseif char ~= "\r" then
    hs.eventtap.keyStrokes(char)
  end

  timer = hs.timer.doAfter(delayAfter(char), function()
    typeFrom(chars, index + 1)
  end)
end

function M.start()
  if running then
    hs.alert.show("Already typing — ⌘⌥⌃. to stop")
    return
  end

  local text = hs.pasteboard.getContents()
  if not text or text == "" then
    hs.alert.show("Clipboard is empty")
    return
  end

  local chars = splitCharacters(text)
  running = true
  hs.alert.show(("Typing %d characters in %.1fs — focus the target field"):format(#chars, START_DELAY), START_DELAY)

  timer = hs.timer.doAfter(START_DELAY, function()
    typeFrom(chars, 1)
  end)
end

function M.stop()
  if not running then
    hs.alert.show("Not typing")
    return
  end
  if timer then
    timer:stop()
  end
  finish("Typing stopped")
end

return M
