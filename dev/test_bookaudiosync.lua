#!/usr/bin/env luajit
-- Simulated KOReader session for bookaudiosync.lua (book <-> audiobook).
-- Run from the repo root: luajit dev/test_bookaudiosync.lua

local here = (arg and arg[0] or ""):gsub("[^/]+$", "")

-- ── KOReader stubs ──────────────────────────────────────────────────────────
local shown, scheduled = {}, {}
local now = 1000000
os.time = function() return now end

package.preload["logger"] = function()
    return setmetatable({}, { __index = function() return function() end end })
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) shown[#shown + 1] = w end,
        close = function() end,
        scheduleIn = function(_, sec, fn) scheduled[#scheduled + 1] = { at = now + sec, fn = fn } end,
        unschedule = function(_, fn)
            for k = #scheduled, 1, -1 do if scheduled[k].fn == fn then table.remove(scheduled, k) end end
        end,
    }
end
package.preload["ffi/util"] = function()
    return { template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(d) return tostring(args[tonumber(d)]) end))
    end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return { size = 1, modification = 1 } end }
end
local Widget = { new = function(_, o) return o end }
package.preload["ui/widget/buttondialog"] = function() return Widget end
package.preload["ui/widget/infomessage"] = function() return Widget end
package.preload["ui/widget/textviewer"] = function() return Widget end
package.preload["ui/event"] = function()
    return { new = function(_, name, arg) return { name = name, arg = arg } end }
end

-- ── Fake book: 10 chapters x 28 pages, 10 audio chapters x 30 min ──────────
local plugin_path = here .. "../"
local words = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten" }
local toc = { { title = "Cover", page = 1, depth = 1 }, { title = "Copyright", page = 2, depth = 1 } }
for c = 1, 10 do toc[#toc + 1] = { title = words[c], page = 3 + (c - 1) * 28, depth = 1 } end
local audio_chapters = {}
for c = 1, 10 do audio_chapters[c] = { title = "Chapter " .. c, start_time = (c - 1) * 1800 } end

local current_page = 1
local page_count = 283
local goto_calls = {}
local plugin
local ui = {
    toc = { toc = toc, fillToc = function() end },
    document = {
        file_path = "/mnt/onboard/Books/Dune.epub",
        getPageCount = function() return page_count end,
    },
    getCurrentPage = function() return current_page end,
    handleEvent = function(_, ev)
        if ev.name == "GotoPage" then
            goto_calls[#goto_calls + 1] = ev.arg
            current_page = ev.arg
            plugin:_pairOnPageUpdate(current_page)
        end
    end,
}

local engine = { current_path = nil, pos = 0 }
function engine:getPosition() return self.pos end
local STATE = { STOPPED = "stopped", PLAYING = "playing", PAUSED = "paused", LOADING = "loading" }
local media_sync = { STATE = STATE, state = STATE.STOPPED, media_engine = engine }

local settings = {}
local played = {}
plugin = {
    ui = ui,
    media_sync = media_sync,
    media_engine = { probeDuration = function() return 10 * 1800 end },
    getSetting = function(_, k, d) if settings[k] == nil then return d end return settings[k] end,
    setSetting = function(_, k, v) settings[k] = v end,
    _formatAudioTime = function(_, s) return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60)) end,
    _saved = nil,
    _getSavedPosition = function(self) return self._saved, now - 100 end,
    _clearPosition = function(self) self._saved = nil end,
    _findMatchingAudiobook = function() return "/mnt/onboard/Books/Dune.m4b" end,
    _doPlayAudioFile = function(_, path, _, start)
        played[#played + 1] = { path = path, start = start }
        engine.current_path = path
        engine.pos = start
        media_sync.state = STATE.PLAYING
    end,
}

-- The chapter probe would run ffmpeg; feed the fixture instead.
local BookAudioSync = dofile(here .. "../bookaudiosync.lua")
local installed = BookAudioSync.install(plugin, { plugin_path = plugin_path })
plugin._pairAudioMeta = function() return audio_chapters, 10 * 1800 end

local failures, checks = {}, 0
local function ok(cond, label)
    checks = checks + 1
    if not cond then failures[#failures + 1] = label end
end
local function advance(seconds)
    local target = now + seconds
    while true do
        table.sort(scheduled, function(a, b) return a.at < b.at end)
        local nxt = scheduled[1]
        if not nxt or nxt.at > target then break end
        table.remove(scheduled, 1)
        now = nxt.at
        nxt.fn()
    end
    now = target
end
local function buttonTexts(dialog)
    local out = {}
    for _, row in ipairs(dialog.buttons) do
        for _, b in ipairs(row) do out[#out + 1] = b.text end
    end
    return table.concat(out, " | ")
end
local function press(dialog, prefix)
    for _, row in ipairs(dialog.buttons) do
        for _, b in ipairs(row) do
            if b.text:sub(1, #prefix) == prefix then b.callback(); return true end
        end
    end
    error("no button " .. prefix .. " in " .. buttonTexts(dialog))
end

ok(installed == true, "module installs")
ok(plugin:_pairMode() == "live", "default mode is live")

-- ── 1. Book -> audio: reading at the start of chapter 4 (page 87) ──────────
current_page = 87
ok(plugin:_pairStart(ui.document.file_path, "/mnt/onboard/Books/Dune.m4b") == true, "start dialog shown")
local dlg = shown[#shown]
ok(dlg.title:find("Your page 87 of 283", 1, true) ~= nil, "dialog shows the page: " .. dlg.title)
ok(dlg.title:find("Chapter 4", 1, true) ~= nil, "dialog names the matching chapter")
ok(buttonTexts(dlg):find("Play from my page (90:00)", 1, true) ~= nil, "offers 90:00: " .. buttonTexts(dlg))
press(dlg, "Play from my page")
ok(played[1].start == 3 * 1800, "audio starts at chapter 4 (5400 s), got " .. tostring(played[1].start))

-- ── 2. Audio -> book (live): 14 minutes into chapter 4 -> page 87 + 13 ─────
engine.pos = 3 * 1800 + 900  -- halfway through chapter 4
advance(5)
ok(current_page == 87 + 14, "live follow turns to the matching page, got " .. current_page)
local turns = #goto_calls

-- A manual page turn holds off the automatic turns.
now = now + 20
current_page = 50
plugin:_pairOnPageUpdate(50)
engine.pos = 3 * 1800 + 1700
advance(30)
ok(current_page == 50, "manual turn is respected during the hold")
advance(90)
ok(current_page == plugin._pair.map:timeToPage(engine.pos), "following resumes after the hold")

-- ── 3. Pause mode: no turns while playing, one turn on pause ───────────────
settings.book_audio_follow = "pause"
engine.pos = 5 * 1800   -- chapter 6 start = page 143
advance(10)
ok(current_page ~= 143, "pause mode does not turn pages while playing")
media_sync.state = STATE.PAUSED
advance(5)
ok(current_page == 143, "pause mode turns to the page on pause, got " .. current_page)
local before = #goto_calls
advance(20)
ok(#goto_calls == before, "only one turn per pause")

-- ── 4. Stop ends pairing with a final sync to the last position ────────────
media_sync.state = STATE.PLAYING
engine.pos = 6 * 1800    -- chapter 7 = page 171
advance(5)
media_sync.state = STATE.STOPPED
advance(5)
ok(current_page == 171, "stop syncs the last position, got " .. current_page)
ok(plugin._pair.active == false, "stop ends the pairing")
ok(plugin._pair_loop == nil, "loop is unscheduled")

-- ── 5. Same place: saved audio matches the page -> single Play ─────────────
settings.book_audio_follow = "live"
plugin._saved = 6 * 1800 + 30
shown = {}
plugin:_pairStart(ui.document.file_path, "/mnt/onboard/Books/Dune.m4b")
dlg = shown[#shown]
ok(dlg.title:find("same place", 1, true) ~= nil, "same place detected")
ok(buttonTexts(dlg):find("Resume audio", 1, true) == nil, "no separate resume when same place")
press(dlg, "Play")
ok(played[#played].start == 6 * 1800 + 30, "same place plays from the saved audio position")

-- ── 6. Different place: both choices, resume picks the saved audio ─────────
media_sync.state = STATE.STOPPED
advance(5)
current_page = 3
plugin._saved = 2 * 1800
shown = {}
plugin:_pairStart(ui.document.file_path, "/mnt/onboard/Books/Dune.m4b")
dlg = shown[#shown]
ok(buttonTexts(dlg):find("Resume audio (60:00)", 1, true) ~= nil, "offers resume: " .. buttonTexts(dlg))
press(dlg, "Resume audio")
ok(played[#played].start == 2 * 1800, "resume uses the saved audio position")
advance(5)
ok(current_page == 59, "live follow moves the book to the audio (chapter 3 = page 59), got " .. current_page)

-- ── 7. Reflow (font change) rebuilds the map and is not a manual turn ──────
page_count = 400
for _, e in ipairs(toc) do e.page = math.floor((e.page - 1) * 400 / 283) + 1 end
plugin:_pairOnPageUpdate(80)
ok(plugin._pair.manual_at == nil or now - plugin._pair.manual_at > 90, "reflow is not a manual turn")
engine.pos = 4 * 1800
advance(5)
ok(plugin._pair.pages == 400, "map rebuilt for the new page count")
ok(current_page == toc[2 + 5].page, "follows chapter 5 in the new layout, got " .. current_page)

-- ── 8. Suspend syncs before sleeping ───────────────────────────────────────
engine.pos = 7 * 1800
plugin:_pairBeforeSuspend()
ok(current_page == toc[2 + 8].page, "suspend turns to the audio page")

-- ── 9. Another file playing ends the pairing ───────────────────────────────
engine.current_path = "/mnt/onboard/Music/song.mp3"
advance(5)
ok(plugin._pair.active == false, "a different audio file ends pairing")

-- ── 10. Menu ────────────────────────────────────────────────────────────────
local items = plugin:_pairMenuItems()
ok(#items == 4, "menu has 3 modes + diagnostics")
items[3].callback()
ok(plugin:_pairMode() == "off", "menu sets off")
shown = {}
plugin:_pairShowDiagnostics()
ok(shown[#shown] and shown[#shown].text:find("by title", 1, true) ~= nil, "diagnostics show the matching")

if #failures == 0 then
    print(string.format("ok - %d checks passed", checks))
else
    print(string.format("FAILED %d of %d:", #failures, checks))
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
end
