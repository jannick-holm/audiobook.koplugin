#!/usr/bin/env luajit
-- Checks for bookaudiomap.lua (audiobook <-> ebook position mapping).
-- Run from the repo root: luajit dev/test_bookaudiomap.lua

local here = (arg and arg[0] or ""):gsub("[^/]+$", "")
local M = dofile(here .. "../bookaudiomap.lua")

local failures, checks = {}, 0
local function ok(cond, label)
    checks = checks + 1
    if not cond then failures[#failures + 1] = label end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end

-- ── normalize / similarity ──────────────────────────────────────────────────
local n = M.normalize
ok(n("Chapter 1").num == 1, "Chapter 1")
ok(n("CHAPTER ONE").num == 1, "CHAPTER ONE")
ok(n("Chapter Twenty-One").num == 21, "Chapter Twenty-One")
ok(n("Twenty-One").num == 21, "Twenty-One alone")
ok(n("XIV").num == 14, "roman alone")
ok(n("Chapter IV: The Storm").num == 4, "roman after keyword")
ok(n("1. The Beginning").num == 1, "leading digits")
ok(n("Kapitel 3").num == 3, "Danish keyword")
ok(n("Chapter 1 \226\128\148 The Boy\226\128\153s Tale").words["tale"] and not n("Chapter 1 \226\128\148 X").words["\226\128\148"], "em dash and curly apostrophe are punctuation")
ok(n("chapter12").num == 12, "glued number")
ok(n("Part Two").kind == "part" and n("Part Two").num == 2, "part kind")
ok(n("The Book Thief").kind == "chapter" and n("The Book Thief").words.book, "'book' in a title is a word")
ok(n("One Day").num == nil and n("One Day").words.day, "'One Day' is not chapter 1")
ok(n("Thirty Days").num == nil, "'Thirty Days' is not 30")
ok(n("I Am Legend").num == nil, "pronoun I is not roman 1")

local s = M.similarity
ok(s(n("Chapter 1"), n("ONE")) >= 0.7, "Chapter 1 ~ ONE")
ok(s(n("Chapter 1: The Boy Who Lived"), n("1. The Boy Who Lived")) > 0.9, "numbered titles")
ok(s(n("Chapter 2"), n("Chapter 3")) < 0, "different numbers conflict")
ok(s(n("Part 1"), n("Chapter 1")) < 0, "part vs chapter conflict")
ok(s(n("Prologue"), n("PROLOGUE")) == 1, "exact title")
ok(s(n("Chapter 3: The Storm"), n("The Storm")) >= 0.6, "title words without number")

ok(M.isExtra("Opening Credits"), "credits are extra")
ok(M.isExtra("Copyright"), "copyright is extra")
ok(M.isExtra("About the Author"), "about the author is extra")
ok(not M.isExtra("The Map of Time"), "a chapter titled with 'map' is not extra")
ok(M.isExtra("Maps"), "a Maps page is extra")
ok(not M.isExtra("Chapter 7"), "chapter is not extra")
ok(not M.isExtra("Recovery"), "'cover' inside a word is not extra")

-- ── Fixture 1: numbered audio vs number-word TOC, front/back matter ─────────
-- 10 chapters, 30 min each, plus 1 min credits at both ends.
local audio = { { title = "Opening Credits", start_time = 0 } }
for c = 1, 10 do
    audio[#audio + 1] = { title = "Chapter " .. c, start_time = 60 + (c - 1) * 1800 }
end
audio[#audio + 1] = { title = "End Credits", start_time = 60 + 10 * 1800 }
local duration = 60 + 10 * 1800 + 60
local words = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten" }
local toc = {
    { title = "Cover", page = 1, depth = 1 },
    { title = "Title Page", page = 2, depth = 1 },
    { title = "Copyright", page = 3, depth = 1 },
    { title = "Dedication", page = 4, depth = 1 },
}
for c = 1, 10 do toc[#toc + 1] = { title = words[c], page = 6 + (c - 1) * 28, depth = 1 } end
toc[#toc + 1] = { title = "Acknowledgments", page = 286, depth = 1 }
toc[#toc + 1] = { title = "About the Author", page = 290, depth = 1 }
local map = M.build(audio, duration, toc, 292)

ok(map.method == "chapters", "fixture 1 uses chapters")
ok(map.title_matches == 10, "fixture 1: 10 title matches, got " .. map.title_matches)
for c = 1, 10 do
    local t = 60 + (c - 1) * 1800
    ok(map:timeToPage(t) == 6 + (c - 1) * 28, "chapter " .. c .. " start -> its first page")
    ok(near(map:pageToTime(6 + (c - 1) * 28), t), "chapter " .. c .. " first page -> its start time")
end
-- Halfway through chapter 3 (pages 62..89, 28 pages) -> page 62 + 14 = 76.
ok(map:timeToPage(60 + 2 * 1800 + 900) == 76, "mid-chapter is proportional")
ok(near(map:pageToTime(76), 60 + 2 * 1800 + 900), "mid-chapter page -> time")
-- Back matter pages map to the end of the last chapter's audio or later.
ok(map:pageToTime(290) >= 60 + 10 * 1800, "back matter maps past the last chapter")
ok(map:timeToPage(0) == 1, "audio start -> first page")
ok(map:timeToPage(duration) == 292, "audio end -> last page")

-- Monotonic in both directions.
local prev_p, prev_t = 0, -1
for t = 0, duration, 37 do
    local p = map:timeToPage(t)
    if p < prev_p then ok(false, "timeToPage not monotonic at " .. t) break end
    prev_p = p
end
for p = 1, 292 do
    local t = map:pageToTime(p)
    if t < prev_t then ok(false, "pageToTime not monotonic at " .. p) break end
    prev_t = t
end
ok(true, "monotonic sweep")

-- ── Fixture 2: "Chapter N" audio vs titled TOC (no shared titles) ───────────
local titled = { "The Boy Who Lived", "The Vanishing Glass", "The Letters from No One",
    "The Keeper of the Keys", "Diagon Alley" }
local audio2 = { { title = "Opening Credits", start_time = 0 } }
for c = 1, 5 do audio2[#audio2 + 1] = { title = "Chapter " .. c, start_time = 30 + (c - 1) * 2000 } end
local toc2 = { { title = "Cover", page = 1, depth = 1 }, { title = "Contents", page = 2, depth = 1 } }
for c = 1, 5 do toc2[#toc2 + 1] = { title = titled[c], page = 3 + (c - 1) * 40, depth = 1 } end
local map2 = M.build(audio2, 30 + 5 * 2000, toc2, 202)
ok(map2.method == "chapters", "fixture 2 uses chapters")
ok(map2.order_matches == 5, "fixture 2: 5 order matches, got " .. map2.order_matches)
ok(map2:timeToPage(30 + 3 * 2000) == 123, "fixture 2: chapter 4 start -> page 123")

-- ── Fixture 3: parts with chapter numbering restarting per part ─────────────
local audio3 = {
    { title = "Part One", start_time = 0 },
    { title = "Chapter 1", start_time = 10 },
    { title = "Chapter 2", start_time = 1000 },
    { title = "Part Two", start_time = 2000 },
    { title = "Chapter 1", start_time = 2010 },
    { title = "Chapter 2", start_time = 3000 },
}
local toc3 = {
    { title = "Part One", page = 1, depth = 1 },
    { title = "1", page = 2, depth = 2 },
    { title = "2", page = 50, depth = 2 },
    { title = "Part Two", page = 100, depth = 1 },
    { title = "1", page = 101, depth = 2 },
    { title = "2", page = 150, depth = 2 },
}
local map3 = M.build(audio3, 4000, toc3, 200)
ok(map3.title_matches == 6, "fixture 3: all 6 matched by title, got " .. map3.title_matches)
ok(map3:timeToPage(2010) == 101, "fixture 3: part two chapter 1 -> page 101 (not page 2)")
ok(map3:timeToPage(3000) == 150, "fixture 3: part two chapter 2 -> page 150")

-- ── Fixture 4: sub-headings inside a chapter do not end the chapter ─────────
local audio4 = { { title = "Chapter 1", start_time = 0 }, { title = "Chapter 2", start_time = 1000 } }
local toc4 = {
    { title = "Chapter 1", page = 1, depth = 1 },
    { title = "A section", page = 10, depth = 2 },
    { title = "Another section", page = 20, depth = 2 },
    { title = "Chapter 2", page = 40, depth = 1 },
}
local map4 = M.build(audio4, 2000, toc4, 80)
ok(map4:timeToPage(500) == 20, "fixture 4: half of chapter 1 -> page 20 (pages 1..39)")

-- ── Fixture 5: no chapters -> proportional ──────────────────────────────────
local map5 = M.build({}, 1000, {}, 100)
ok(map5.method == "proportional", "fixture 5 proportional")
ok(map5:timeToPage(500) == 51, "fixture 5: halfway -> page 51")
ok(near(map5:pageToTime(51), 500), "fixture 5: page 51 -> halfway")

-- ── Fixture 6: duration missing, taken from last chapter end ───────────────
local map6 = M.build({ { title = "Chapter 1", start_time = 0, end_time = 600 } }, nil,
    { { title = "Chapter 1", page = 1, depth = 1 } }, 10)
ok(map6.duration == 600, "fixture 6: duration from last chapter end")

-- ── Fixture 7: a chapter missing from the audio keeps the rest aligned ──────
local audio7 = {
    { title = "Chapter 1", start_time = 0 }, { title = "Chapter 2", start_time = 1000 },
    { title = "Chapter 4", start_time = 2000 },
}
local toc7 = {
    { title = "Chapter 1", page = 1, depth = 1 }, { title = "Chapter 2", page = 20, depth = 1 },
    { title = "Chapter 3", page = 40, depth = 1 }, { title = "Chapter 4", page = 60, depth = 1 },
}
local map7 = M.build(audio7, 3000, toc7, 80)
ok(map7:timeToPage(2000) == 60, "fixture 7: chapter 4 still lands on its page")
ok(map7.title_matches == 3, "fixture 7: 3 title matches")

print(map:describe())
print(map2:describe())

if #failures == 0 then
    print(string.format("ok - %d checks passed", checks))
else
    print(string.format("FAILED %d of %d:", #failures, checks))
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
end
