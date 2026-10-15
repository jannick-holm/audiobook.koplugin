#!/usr/bin/env luajit
-- Checks for the ffmpeg chapter fallback in m4bparser.lua.
-- Run from the repo root: luajit dev/test_ffmpeg_chapters.lua
--
-- The bundled ffmpeg is built with --disable-ffprobe, so on e-readers M4B
-- chapters come from the stderr dump of `ffmpeg -i <file>`. The fixture
-- below is that dump for an M4B with three chapters (ffmpeg 7.1).

local here = (arg and arg[0] or ""):gsub("[^/]+$", "")

package.preload["logger"] = function()
    return setmetatable({}, { __index = function() return function() end end })
end
package.preload["device"] = function()
    return { isAndroid = function() return false end }
end

local MetadataParser = dofile(here .. "../m4bparser.lua")
local parser = MetadataParser:new{}

local failures, checks = {}, 0
local function ok(cond, label)
    checks = checks + 1
    if not cond then failures[#failures + 1] = label end
end

local dump = [[
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'Test Book.m4b':
  Metadata:
    major_brand     : M4A 
    title           : Test Book
    encoder         : Lavf61.7.100
  Duration: 10:02:03.50, start: 0.000000, bitrate: 34 kb/s
  Chapters:
    Chapter #0:0: start 0.000000, end 4.000000
      Metadata:
        title           : Opening Credits
    Chapter #0:1: start 4.000000, end 9.500000
      Metadata:
        title           : Chapter 1: The "Beginning", part one
    Chapter #0:2: start 9.500000, end 36123.500000
  Stream #0:0[0x1](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, mono, fltp, 32 kb/s (default)
      Metadata:
        handler_name    : SoundHandler
        title           : Stream title must not leak
At least one output file must be specified
]]

local chapters, duration = parser:_parseFfmpegInfo(dump)
ok(#chapters == 3, "three chapters parsed")
ok(duration == 36123.5, "duration parsed from Duration line")
ok(chapters[1].title == "Opening Credits", "first title")
ok(chapters[1].start_time == 0 and chapters[1].end_time == 4, "first chapter times")
ok(chapters[2].title == 'Chapter 1: The "Beginning", part one', "title with colon and quotes kept verbatim")
ok(chapters[3].title == "Chapter 3", "untitled chapter gets a default and stream title does not leak")
ok(chapters[3].end_time == 36123.5, "last chapter end")
ok(chapters[1].id == 0 and chapters[3].id == 2, "ids are zero-based and sequential")

local none, none_dur = parser:_parseFfmpegInfo([[
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'nochap.m4b':
  Duration: 00:00:07.00, start: 0.000000, bitrate: 34 kb/s
  Stream #0:0[0x1](und): Audio: aac (LC)
]])
ok(#none == 0, "file without chapters yields no chapters")
ok(none_dur == 7, "duration still reported without chapters")

ok(parser:_shellQuote("It's $x `y`.m4b") == [['It'\''s $x `y`.m4b']], "shell quoting is safe for quotes and $")

-- Optional end-to-end check with a real ffmpeg on PATH and an M4B fixture.
local fixture = os.getenv("M4B_FIXTURE")
if fixture then
    local real = MetadataParser:new{ plugin_dir = os.getenv("PLUGIN_DIR") }
    local ch, dur = real:parse(fixture)
    ok(ch and #ch > 0, "real ffmpeg finds chapters in " .. fixture)
    ok(type(dur) == "number" and dur > 0, "real ffmpeg reports a duration")
end

if #failures == 0 then
    print(string.format("ok - %d checks passed", checks))
else
    print(string.format("FAILED %d of %d:", #failures, checks))
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
end
