--[[--
BookAudioSync -- keep an ebook and its same-named audiobook at the same place.

When an EPUB is open and an audiobook with the same base name sits next to it
(Dune.epub + Dune.m4b), "Play aligned/enriched audiobook" plays it as an
unaligned audiobook. This module pairs the two using bookaudiomap.lua:

  * Book -> audio: starting playback offers "Play from my page", the audio
    time that matches the page you are on, next to the usual resume point.
  * Audio -> book: while it plays (setting "live") or when it is paused or
    stopped (setting "pause"), the book turns to the page that matches the
    audio. KOReader then saves that page as reading progress, so sync
    plugins (KOReader sync, BookOrbit, ...) carry it to other devices.

Turning pages yourself holds off the automatic page turns for a while, so
looking something up while listening is not interrupted.

Installed onto the plugin instance by main.lua:_initSubmodules().

@module koplugin.audiobook.bookaudiosync
--]]

local logger = require("logger")

local TICK_SECONDS = 5           -- how often playback is checked
local MANUAL_HOLD_SECONDS = 90   -- no auto page turns after a manual turn
local LOADING_TIMEOUT = 120      -- give up waiting for playback to start
local SAME_PLACE_PAGES = 1       -- saved audio within this many pages = same place
local STARTUP_GRACE_SECONDS = 10 -- page events while playback starts are layout, not the user

local BookAudioSync = {}

function BookAudioSync.install(plugin, env)
    local _ = env._ or function(s) return s end
    local plugin_path = env.plugin_path
    local UIManager = require("ui/uimanager")
    local T = require("ffi/util").template

    local ok_map, BookAudioMap = pcall(dofile, plugin_path .. "bookaudiomap.lua")
    if not ok_map or not BookAudioMap then
        logger.warn("Audiobook: bookaudiomap.lua failed to load:", BookAudioMap)
        return false
    end

    local function fmt(seconds)
        if plugin._formatAudioTime then return plugin:_formatAudioTime(seconds) end
        return tostring(math.floor(seconds or 0))
    end

    -- ── Settings ─────────────────────────────────────────────────────────

    function plugin:_pairMode()
        local mode = self:getSetting("book_audio_follow", "live")
        if mode ~= "live" and mode ~= "pause" and mode ~= "off" then mode = "live" end
        return mode
    end

    -- ── Building the map ─────────────────────────────────────────────────

    --- Chapters and duration of an audio file, cached per path + size + mtime
    --- so the ffmpeg probe runs once per file.
    function plugin:_pairAudioMeta(audio_path)
        local lfs = require("libs/libkoreader-lfs")
        local attr = lfs.attributes(audio_path) or {}
        local key = audio_path .. "|" .. tostring(attr.size) .. "|" .. tostring(attr.modification)
        self._pair_meta_cache = self._pair_meta_cache or {}
        local cached = self._pair_meta_cache[key]
        if cached then return cached.chapters, cached.duration end

        local chapters, duration = {}, nil
        local ok_mp, MetadataParser = pcall(dofile, plugin_path .. "m4bparser.lua")
        if ok_mp and MetadataParser then
            local ok_parse, ch, dur = pcall(function()
                return MetadataParser:new{ plugin_dir = plugin_path }:parse(audio_path)
            end)
            if ok_parse then
                chapters = ch or {}
                if type(dur) == "number" then duration = dur end
            end
        end
        if not duration and self.media_engine then
            pcall(function() duration = self.media_engine:probeDuration(audio_path) end)
        end
        self._pair_meta_cache[key] = { chapters = chapters, duration = duration }
        return chapters, duration
    end

    function plugin:_pairTocEntries()
        local toc = {}
        local reader_toc = self.ui and self.ui.toc
        if reader_toc then
            pcall(function() reader_toc:fillToc() end)
            for _, e in ipairs(reader_toc.toc or {}) do
                toc[#toc + 1] = { title = e.title, page = e.page, depth = e.depth }
            end
        end
        return toc
    end

    --- Map for doc + audio, rebuilt when the page count changes (font size,
    --- margins, rotation all reflow the book).
    function plugin:_pairMapFor(doc_path, audio_path)
        if not (self.ui and self.ui.document) then return nil end
        local pages = self.ui.document:getPageCount()
        local pair = self._pair
        if pair and pair.doc_path == doc_path and pair.audio_path == audio_path
                and pair.map and pair.pages == pages then
            return pair.map
        end
        local chapters, duration = self:_pairAudioMeta(audio_path)
        local map = BookAudioMap.build(chapters, duration, self:_pairTocEntries(), pages)
        if not pair or pair.doc_path ~= doc_path or pair.audio_path ~= audio_path then
            pair = { doc_path = doc_path, audio_path = audio_path }
            self._pair = pair
        end
        pair.map, pair.pages = map, pages
        logger.warn("Audiobook: book/audio map:", map:describe(), "pages=", pages,
            "duration=", map.duration)
        return map
    end

    function plugin:_pairCurrentPage()
        local ok, page = pcall(function() return self.ui:getCurrentPage() end)
        return ok and page or nil
    end

    -- ── Book -> audio: the start dialog ─────────────────────────────────

    --- Replaces the "Found matching audiobook. Play it?" box.
    function plugin:_pairStart(doc_path, audio_path)
        local ok, map = pcall(self._pairMapFor, self, doc_path, audio_path)
        if not ok or not map or map.duration <= 0 then
            logger.warn("Audiobook: book/audio pairing unavailable:", map)
            return false
        end
        local page = self:_pairCurrentPage() or 1
        local book_time = page > 1 and map:pageToTime(page) or 0
        local saved_pos = self:_getSavedPosition(audio_path)
        if saved_pos and saved_pos <= 30 then saved_pos = nil end

        local name = audio_path:match("([^/]+)$") or audio_path
        local lines = { T(_("Audiobook: %1"), name), "" }
        local function where(t)
            local ch = map:chapterAt(t)
            return ch and T("%1 (%2)", fmt(t), ch) or fmt(t)
        end

        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        local function start(pos, clear)
            UIManager:close(dialog)
            if clear then self:_clearPosition(audio_path) end
            self:_pairBegin(doc_path, audio_path, pos)
        end
        local buttons = {}
        local same_place = saved_pos
            and math.abs(map:timeToPage(saved_pos) - page) <= SAME_PLACE_PAGES

        if same_place then
            table.insert(lines, T(_("The book and the audio are at the same place: %1"), where(saved_pos)))
            table.insert(buttons, {{ text = _("Play"), callback = function() start(saved_pos) end }})
        else
            table.insert(lines, T(_("Your page %1 of %2 ≈ %3"), page, map.page_count, where(book_time)))
            table.insert(buttons, {{
                text = T(_("Play from my page (%1)"), fmt(book_time)),
                callback = function() start(book_time) end,
            }})
            if saved_pos then
                table.insert(lines, T(_("Last listened: %1"), where(saved_pos)))
                table.insert(buttons, {{
                    text = T(_("Resume audio (%1)"), fmt(saved_pos)),
                    callback = function() start(saved_pos) end,
                }})
            end
        end
        if map.method == "proportional" then
            table.insert(lines, "")
            table.insert(lines, _("No chapter match, so the position is estimated from the book's length."))
        end
        table.insert(buttons, {
            { text = _("From start"), callback = function() start(0, true) end },
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
        })
        dialog = ButtonDialog:new{
            title = table.concat(lines, "\n"),
            title_align = "left",
            buttons = buttons,
        }
        UIManager:show(dialog)
        return true
    end

    function plugin:_pairBegin(doc_path, audio_path, start_pos)
        self:_pairMapFor(doc_path, audio_path)
        local pair = self._pair
        pair.active = true
        pair.started = false
        pair.engine_path = nil
        pair.manual_at = nil
        pair.last_pos = start_pos
        pair.paused_synced = false
        pair.begun_at = os.time()
        self:_doPlayAudioFile(audio_path, nil, start_pos or 0)
        self:_pairStartLoop()
    end

    -- ── Audio -> book ────────────────────────────────────────────────────

    function plugin:_pairStartLoop()
        if self._pair_loop then UIManager:unschedule(self._pair_loop) end
        self._pair_loop = function()
            local ok, err = pcall(self._pairTick, self)
            if not ok then
                logger.warn("Audiobook: book/audio sync tick failed:", err)
                self:_pairEnd()
            end
        end
        UIManager:scheduleIn(TICK_SECONDS, self._pair_loop)
    end

    function plugin:_pairEnd()
        if self._pair_loop then
            UIManager:unschedule(self._pair_loop)
            self._pair_loop = nil
        end
        if self._pair then self._pair.active = false end
    end

    function plugin:_pairPosition()
        local pos
        pcall(function() pos = self.media_sync.media_engine:getPosition() end)
        if type(pos) == "number" and pos >= 0 then return pos end
        return nil
    end

    function plugin:_pairTick()
        local pair = self._pair
        local ms = self.media_sync
        if not (pair and pair.active and ms and self.ui and self.ui.document) then
            return self:_pairEnd()
        end
        local doc_path = self.ui.document.file_path or self.ui.document.file
        if doc_path ~= pair.doc_path then return self:_pairEnd() end

        local engine = ms.media_engine
        local cur = engine and engine.current_path
        local state = ms.state
        local mode = self:_pairMode()

        if state == ms.STATE.PLAYING or state == ms.STATE.PAUSED then
            -- Remember which file the engine plays (it may be a transcode);
            -- a different file means the user started something else.
            if not pair.engine_path then pair.engine_path = cur end
            if cur and pair.engine_path and cur ~= pair.engine_path then
                return self:_pairEnd()
            end
            pair.started = true
        end

        if state == ms.STATE.PLAYING then
            local pos = self:_pairPosition()
            if pos then pair.last_pos = pos end
            pair.paused_synced = false
            if mode == "live" and pos then self:_pairFollow(pos) end
        elseif state == ms.STATE.PAUSED then
            if not pair.paused_synced and mode ~= "off" then
                self:_pairFollow(self:_pairPosition() or pair.last_pos)
                pair.paused_synced = true
            end
        elseif state == ms.STATE.STOPPED then
            if pair.started then
                if mode ~= "off" and not pair.paused_synced and pair.last_pos then
                    self:_pairFollow(pair.last_pos)
                end
                return self:_pairEnd()
            end
            if os.time() - (pair.begun_at or 0) > LOADING_TIMEOUT then
                return self:_pairEnd()
            end
        end
        UIManager:scheduleIn(TICK_SECONDS, self._pair_loop)
    end

    --- Turn the book to the page matching an audio time.
    -- @param force ignore the manual-turn hold (used for explicit actions)
    function plugin:_pairFollow(pos, force)
        local pair = self._pair
        if not (pair and pos and self.ui and self.ui.document) then return end
        if not force and pair.manual_at and os.time() - pair.manual_at < MANUAL_HOLD_SECONDS then
            return
        end
        local map = self:_pairMapFor(pair.doc_path, pair.audio_path)
        if not map then return end
        local page = map:timeToPage(pos)
        local cur = self:_pairCurrentPage()
        if not cur or page == cur then return end
        pair.expect_page = page
        pair.expect_until = os.time() + 3
        local Event = require("ui/event")
        self.ui:handleEvent(Event:new("GotoPage", page))
        logger.dbg("Audiobook: book follows audio", fmt(pos), "-> page", page)
    end

    --- Called from main.lua onPageUpdate: page turns we did not cause are
    --- the user's, and pause the automatic page turns for a while.
    function plugin:_pairOnPageUpdate(cur_page)
        local pair = self._pair
        if not (pair and pair.active) then return end
        if pair.expect_page and os.time() <= (pair.expect_until or 0) then
            if cur_page == pair.expect_page then pair.expect_page = nil end
            return
        end
        -- Starting playback reserves space for the mini player, which
        -- reflows the book; that is not the user turning pages.
        if os.time() - (pair.begun_at or 0) < STARTUP_GRACE_SECONDS then return end
        local pages
        pcall(function() pages = self.ui.document:getPageCount() end)
        if pages and pair.pages and pages ~= pair.pages then return end
        pair.manual_at = os.time()
    end

    --- Called from main.lua onSuspend, before playback is paused, so the
    --- page saved when the device sleeps matches the audio.
    function plugin:_pairBeforeSuspend()
        local pair = self._pair
        if not (pair and pair.active) or self:_pairMode() == "off" then return end
        local pos = self:_pairPosition() or pair.last_pos
        if pos then self:_pairFollow(pos) end
    end

    -- ── Menu ─────────────────────────────────────────────────────────────

    function plugin:_pairShowDiagnostics()
        local InfoMessage = require("ui/widget/infomessage")
        local doc_path = self.ui and self.ui.document and (self.ui.document.file_path or self.ui.document.file)
        local audio_path = doc_path and self:_findMatchingAudiobook(doc_path)
        if not audio_path then
            UIManager:show(InfoMessage:new{
                text = _("No audiobook with the same name next to this book."),
                timeout = 4,
            })
            return
        end
        local map = self:_pairMapFor(doc_path, audio_path)
        if not map then return end
        local lines = {
            T(_("Audiobook: %1"), audio_path:match("([^/]+)$") or audio_path),
            T(_("Length: %1, book: %2 pages"), fmt(map.duration), map.page_count),
            "",
            map:describe(),
            "",
        }
        for k, p in ipairs(map.pairs) do
            if k > 40 then
                table.insert(lines, T(_("… and %1 more"), #map.pairs - 40))
                break
            end
            table.insert(lines, T("%1  %2  →  p. %3  %4", fmt(p.time), p.audio_title, p.page,
                p.toc_title ~= p.audio_title and ("(" .. p.toc_title .. ")") or ""))
        end
        local page = self:_pairCurrentPage()
        if page then
            table.insert(lines, "")
            table.insert(lines, T(_("This page (%1) ≈ %2"), page, fmt(map:pageToTime(page))))
        end
        local TextViewer = require("ui/widget/textviewer")
        UIManager:show(TextViewer:new{
            title = _("Book ↔ audiobook matching"),
            text = table.concat(lines, "\n"),
        })
    end

    function plugin:_pairMenuItems()
        local function modeItem(mode, text, help)
            return {
                text = text,
                radio = true,
                checked_func = function() return self:_pairMode() == mode end,
                callback = function() self:setSetting("book_audio_follow", mode) end,
                help_text = help,
            }
        end
        return {
            modeItem("live", _("Follow the audio while it plays"),
                _("The book turns to the page that matches the audio while it plays. Turning a page yourself pauses this for a minute and a half.")),
            modeItem("pause", _("Only when paused or stopped"),
                _("The book jumps to the page that matches the audio when you pause or stop.")),
            modeItem("off", _("Off"),
                _("Book and audiobook are not linked; playback asks to resume the audio as before.")),
            {
                text = _("Show chapter matching"),
                separator = true,
                enabled_func = function() return (self.ui and self.ui.document) and true or false end,
                callback = function() self:_pairShowDiagnostics() end,
            },
        }
    end

    return true
end

return BookAudioSync
