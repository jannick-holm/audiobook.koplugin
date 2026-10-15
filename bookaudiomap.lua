--[[--
BookAudioMap -- approximate position mapping between an audiobook and its ebook.

Pure Lua, no KOReader dependencies, so it can be unit tested on its own
(see dev/test_bookaudiomap.lua).

Given the audiobook's chapters (title + start time) and the ebook's table of
contents (title + page + depth), it pairs audio chapters with TOC entries and
builds a piecewise-linear mapping between audio time and book page:

  1. Title matching. Titles are normalised ("Chapter One", "CHAPTER 1",
     "1. The Beginning", "Kapitel 1", roman numerals) and paired with an
     order-preserving alignment (dynamic programming), so repeated titles and
     per-part chapter numbering stay in order.
  2. Order matching. Between two title anchors, if the number of unmatched
     audio chapters equals the number of unmatched TOC entries (front and
     back matter like "Copyright" or "Opening Credits" ignored), they are
     paired in order. This covers "Chapter 7" audio against titled TOCs.
  3. Inside a paired chapter, time and pages are proportional. Unpaired
     stretches are interpolated between the neighbouring anchors. With no
     usable chapters at all, the whole book is proportional.

Chapter starts land on the right page; mid-chapter positions are an estimate
(narration pace and page density vary), typically within a page or two.

@module koplugin.audiobook.bookaudiomap
--]]

local BookAudioMap = {}
BookAudioMap.__index = BookAudioMap

-- ---------------------------------------------------------------------------
-- Title normalisation
-- ---------------------------------------------------------------------------

local NUMBER_WORDS = {
    zero = 0, one = 1, two = 2, three = 3, four = 4, five = 5, six = 6,
    seven = 7, eight = 8, nine = 9, ten = 10, eleven = 11, twelve = 12,
    thirteen = 13, fourteen = 14, fifteen = 15, sixteen = 16,
    seventeen = 17, eighteen = 18, nineteen = 19,
}
local TENS_WORDS = {
    twenty = 20, thirty = 30, forty = 40, fifty = 50, sixty = 60,
    seventy = 70, eighty = 80, ninety = 90,
}
local CHAPTER_WORDS = {
    chapter = true, chap = true, ch = true, kapitel = true, kap = true,
    chapitre = true, capitulo = true, ["capítulo"] = true, kapittel = true,
    rozdzial = true, ["rozdział"] = true, track = true,
}
local PART_WORDS = {
    part = true, del = true, book = true, bog = true, volume = true,
    vol = true, act = true, partie = true, teil = true, ["część"] = true,
}
local STOP_WORDS = {
    the = true, a = true, an = true, of = true, ["and"] = true, ["in"] = true,
    to = true, og = true, i = true, en = true, et = true, de = true,
    der = true, det = true, den = true, at = true, on = true,
}
-- Substrings marking front/back matter and audio-only extras. These never
-- take part in order matching (they can still match by exact title).
local EXTRA_PATTERNS = {
    "cover", "title page", "titlepage", "half title", "copyright", "dedication",
    "contents", "epigraph", "also by", "praise for", "acknowledg",
    "about the author", "about the publisher", "newsletter", "sign up",
    "colophon", "kolofon", "indhold", "om forfatteren", "tak til",
    "credits", "intro music", "outro", "audible", "teaser", "excerpt",
    "preview", "bibliography", "index", "glossary", "map", "maps",
    "copyright page", "frontmatter", "front matter", "backmatter", "back matter",
}

local ROMAN = { i = 1, v = 5, x = 10, l = 50, c = 100, d = 500, m = 1000 }

local function romanToNumber(s)
    if not s:match("^[ivxlcdm]+$") then return nil end
    local total, prev = 0, 0
    for i = #s, 1, -1 do
        local v = ROMAN[s:sub(i, i)]
        if v < prev then total = total - v else total = total + v; prev = v end
    end
    -- Reject non-canonical forms such as "iiii" or "vx" by round-tripping.
    local function toRoman(n)
        local vals = { 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 }
        local syms = { "m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i" }
        local out = {}
        for k, v in ipairs(vals) do
            while n >= v do out[#out + 1] = syms[k]; n = n - v end
        end
        return table.concat(out)
    end
    if total <= 0 or total > 399 or toRoman(total) ~= s then return nil end
    return total
end

--- Normalise a chapter/TOC title.
-- @return table { raw = "normalised string", num = number|nil,
--                 kind = "chapter"|"part", words = set, nwords = count }
function BookAudioMap.normalize(title)
    local s = tostring(title or ""):lower()
    -- Split glued numbers ("chapter1", "01.title") and drop ASCII punctuation.
    s = s:gsub("(%a)(%d)", "%1 %2"):gsub("(%d)(%a)", "%1 %2")
    -- Typographic punctuation (dashes, curly quotes, ellipsis) is multi-byte
    -- UTF-8 and not covered by %p.
    for _, u in ipairs({ "\226\128\148", "\226\128\147", "\226\128\152", "\226\128\153",
                         "\226\128\156", "\226\128\157", "\226\128\166", "\194\183" }) do
        s = s:gsub(u, " ")
    end
    s = s:gsub("[%p]", " ")
    local tokens = {}
    for tok in s:gmatch("%S+") do tokens[#tokens + 1] = tok end

    local info = { kind = "chapter", words = {}, nwords = 0 }
    local num

    -- A number word only counts as a chapter number right after a keyword
    -- ("Chapter One") or when it is the whole title ("ONE", "Twenty-One"),
    -- so titles like "One Day" or "Thirty Days" keep their words.
    local only_number_words = #tokens > 0
    for _, tok in ipairs(tokens) do
        if not (NUMBER_WORDS[tok] or TENS_WORDS[tok]) then only_number_words = false end
    end
    local function isNumeric(tok)
        return tok ~= nil and (tok:match("^%d+$") ~= nil or NUMBER_WORDS[tok] ~= nil
            or TENS_WORDS[tok] ~= nil or romanToNumber(tok) ~= nil)
    end

    local i = 1
    while i <= #tokens do
        local tok = tokens[i]
        local prev = tokens[i - 1]
        local after_keyword = prev and (CHAPTER_WORDS[prev] or PART_WORDS[prev]) and true or false
        local number_ok = after_keyword or only_number_words or #tokens == 1
        if PART_WORDS[tok] and isNumeric(tokens[i + 1]) then
            -- "Part 2", "Book Three"; "The Book Thief" stays plain words.
            info.kind = "part"
        elseif CHAPTER_WORDS[tok] and (isNumeric(tokens[i + 1]) or #tokens == 1) then
            -- marker only
        elseif tok:match("^%d+$") then
            num = num or tonumber(tok)
        elseif TENS_WORDS[tok] and number_ok then
            local n = TENS_WORDS[tok]
            local nxt = tokens[i + 1] and NUMBER_WORDS[tokens[i + 1]]
            if nxt and nxt < 10 then n = n + nxt; i = i + 1 end
            num = num or n
        elseif NUMBER_WORDS[tok] and number_ok then
            num = num or NUMBER_WORDS[tok]
        elseif number_ok and romanToNumber(tok) then
            num = num or romanToNumber(tok)
        elseif not STOP_WORDS[tok] then
            if not info.words[tok] then
                info.words[tok] = true
                info.nwords = info.nwords + 1
            end
        end
        i = i + 1
    end
    info.num = num
    info.raw = table.concat(tokens, " ")
    return info
end

function BookAudioMap.isExtra(title)
    local raw = BookAudioMap.normalize(title).raw
    for _, pat in ipairs(EXTRA_PATTERNS) do
        if #pat <= 5 then
            -- Short words ("cover", "map", "index") only when they are the
            -- whole title, so "The Map of Time" stays a chapter.
            if raw == pat then return true end
        elseif raw:find(pat, 1, true) then
            return true
        end
    end
    return false
end

--- Similarity of two normalised titles in [-1, 1].
-- Same number and kind is a strong match; different numbers of the same
-- kind are a hard conflict.
function BookAudioMap.similarity(a, b)
    if a.raw ~= "" and a.raw == b.raw then return 1 end
    local inter, union = 0, a.nwords
    for w in pairs(b.words) do
        if a.words[w] then inter = inter + 1 else union = union + 1 end
    end
    local jacc = union > 0 and inter / union or 0
    if a.num and b.num then
        if a.kind ~= b.kind then return -1 end
        if a.num ~= b.num then return -1 end
        return 0.7 + 0.3 * jacc
    end
    if (a.num and not b.num) or (b.num and not a.num) then
        -- "Chapter 3: The Storm" vs "The Storm": rely on the words only.
        return jacc
    end
    return jacc
end

-- ---------------------------------------------------------------------------
-- Building the map
-- ---------------------------------------------------------------------------

local STRONG = 0.6          -- minimum similarity for a title match
local MAX_REL_DRIFT = 0.25  -- reject title matches this far apart (fraction of book)

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

--- Order-preserving maximum-score alignment of audio chapters and TOC entries.
local function alignByTitle(audio, toc, duration, page_count)
    local m, n = #audio, #toc
    if m == 0 or n == 0 then return {} end
    local score = {}
    for i = 1, m do
        score[i] = {}
        local ra = audio[i].start_time / duration
        for j = 1, n do
            local s = BookAudioMap.similarity(audio[i].norm, toc[j].norm)
            local rt = (toc[j].page - 1) / page_count
            if s >= STRONG and math.abs(ra - rt) <= MAX_REL_DRIFT then
                score[i][j] = s
            end
        end
    end
    -- dp[i][j] = best total using audio[1..i], toc[1..j]
    local dp, choice = {}, {}
    for i = 0, m do
        dp[i], choice[i] = {}, {}
        for j = 0, n do
            if i == 0 or j == 0 then
                dp[i][j] = 0
            else
                local best, how = dp[i - 1][j], "up"
                if dp[i][j - 1] > best then best, how = dp[i][j - 1], "left" end
                local s = score[i][j]
                if s and dp[i - 1][j - 1] + s > best then
                    best, how = dp[i - 1][j - 1] + s, "match"
                end
                dp[i][j], choice[i][j] = best, how
            end
        end
    end
    local pairs_out = {}
    local i, j = m, n
    while i > 0 and j > 0 do
        local how = choice[i][j]
        if how == "match" then
            table.insert(pairs_out, 1, { a = i, t = j, how = "title" })
            i, j = i - 1, j - 1
        elseif how == "up" then
            i = i - 1
        else
            j = j - 1
        end
    end
    return pairs_out
end

--- TOC depth used for order matching: the most common depth among title
--- matches, else the depth whose entry count best fits the audio.
local function chooseDepth(toc, title_pairs, audio_count)
    local freq, best_depth, best_freq = {}, nil, 0
    for _, p in ipairs(title_pairs) do
        local d = toc[p.t].depth
        freq[d] = (freq[d] or 0) + 1
        if freq[d] > best_freq then best_depth, best_freq = d, freq[d] end
    end
    if best_depth then return best_depth end
    local counts = {}
    for _, e in ipairs(toc) do
        if not e.extra then counts[e.depth] = (counts[e.depth] or 0) + 1 end
    end
    local best_diff
    for d, c in pairs(counts) do
        local diff = math.abs(c - audio_count)
        if not best_diff or diff < best_diff or (diff == best_diff and d < best_depth) then
            best_depth, best_diff = d, diff
        end
    end
    return best_depth or 1
end

--- Pair unmatched entries in order between title anchors when counts agree.
local function fillByOrder(audio, toc, title_pairs, depth)
    local result = {}
    local bounds = { { a = 0, t = 0 } }
    for _, p in ipairs(title_pairs) do bounds[#bounds + 1] = p end
    bounds[#bounds + 1] = { a = #audio + 1, t = #toc + 1 }
    for k = 1, #bounds - 1 do
        local lo, hi = bounds[k], bounds[k + 1]
        local ua, ut = {}, {}
        for i = lo.a + 1, hi.a - 1 do
            if not audio[i].extra then ua[#ua + 1] = i end
        end
        for j = lo.t + 1, hi.t - 1 do
            if not toc[j].extra and toc[j].depth == depth then ut[#ut + 1] = j end
        end
        if #ua > 0 and #ua == #ut then
            for q = 1, #ua do
                result[#result + 1] = { a = ua[q], t = ut[q], how = "order" }
            end
        end
        if k < #bounds - 1 then result[#result + 1] = hi end
    end
    table.sort(result, function(x, y) return x.a < y.a end)
    return result
end

--- Build a map.
-- @param audio_chapters list of { title, start_time, end_time? } (seconds)
-- @param duration total audio duration in seconds
-- @param toc list of { title, page, depth? } (KOReader ReaderToc entries)
-- @param page_count number of pages in the book
-- @return BookAudioMap
function BookAudioMap.build(audio_chapters, duration, toc, page_count)
    page_count = math.max(1, math.floor(tonumber(page_count) or 1))
    local audio = {}
    for _, ch in ipairs(audio_chapters or {}) do
        local st = tonumber(ch.start_time)
        if st then
            audio[#audio + 1] = {
                title = ch.title or "",
                start_time = st,
                end_time = tonumber(ch.end_time),
            }
        end
    end
    table.sort(audio, function(x, y) return x.start_time < y.start_time end)
    duration = tonumber(duration)
    if not duration or duration <= 0 then
        local last = audio[#audio]
        duration = last and (last.end_time or last.start_time) or 0
    end

    local entries = {}
    for _, e in ipairs(toc or {}) do
        local page = tonumber(e.page)
        if page and page >= 1 and page <= page_count then
            entries[#entries + 1] = {
                title = e.title or "",
                page = page,
                depth = tonumber(e.depth) or 1,
            }
        end
    end
    -- TOCs are in reading order already; a stable sort guards odd files.
    for k, e in ipairs(entries) do e._k = k end
    table.sort(entries, function(x, y)
        if x.page ~= y.page then return x.page < y.page end
        return x._k < y._k
    end)

    for _, a in ipairs(audio) do
        a.norm = BookAudioMap.normalize(a.title)
        a.extra = BookAudioMap.isExtra(a.title)
    end
    for _, e in ipairs(entries) do
        e.norm = BookAudioMap.normalize(e.title)
        e.extra = BookAudioMap.isExtra(e.title)
    end

    local self = setmetatable({
        duration = duration,
        page_count = page_count,
        audio_count = #audio,
        toc_count = #entries,
        title_matches = 0,
        order_matches = 0,
        method = "proportional",
        pairs = {},
    }, BookAudioMap)

    local pairs_list = {}
    if duration > 0 and #audio > 0 and #entries > 0 then
        local title_pairs = alignByTitle(audio, entries, duration, page_count)
        local depth = chooseDepth(entries, title_pairs, #audio)
        pairs_list = fillByOrder(audio, entries, title_pairs, depth)
    end

    -- Segment end points: the audio chapter runs until the next chapter
    -- starts; its text runs until the next TOC entry at the same or a
    -- shallower depth (sub-headings inside the chapter do not end it).
    local points = {}
    local function addPoint(t, p)
        points[#points + 1] = { t = t, p = p }
    end
    local paired_toc = {}
    for _, pr in ipairs(pairs_list) do paired_toc[pr.t] = true end
    for _, pr in ipairs(pairs_list) do
        local a, e = audio[pr.a], entries[pr.t]
        local t_end = (audio[pr.a + 1] and audio[pr.a + 1].start_time) or a.end_time or duration
        -- The text ends at the next entry at the same or a shallower depth,
        -- or at the next paired entry (a part ends where its first paired
        -- chapter begins).
        local p_end = page_count + 1
        for j = pr.t + 1, #entries do
            if entries[j].depth <= e.depth or paired_toc[j] then p_end = entries[j].page; break end
        end
        addPoint(a.start_time, e.page)
        addPoint(math.min(t_end, duration), p_end)
        self.pairs[#self.pairs + 1] = {
            audio_title = a.title, toc_title = e.title,
            time = a.start_time, page = e.page, how = pr.how,
        }
        if pr.how == "title" then
            self.title_matches = self.title_matches + 1
        else
            self.order_matches = self.order_matches + 1
        end
    end
    if #self.pairs > 0 then
        self.method = "chapters"
    end

    -- Book start and end, then keep only points that move forward in both
    -- time and pages so the mapping stays monotonic.
    table.insert(points, 1, { t = 0, p = 1 })
    addPoint(duration, page_count + 1)
    table.sort(points, function(x, y)
        if x.t ~= y.t then return x.t < y.t end
        return x.p < y.p
    end)
    local clean = {}
    for _, pt in ipairs(points) do
        local last = clean[#clean]
        if not last or (pt.t >= last.t and pt.p >= last.p) then
            if not (last and last.t == pt.t and last.p == pt.p) then
                clean[#clean + 1] = pt
            end
        end
    end
    self.points = clean
    self.audio = audio
    return self
end

-- ---------------------------------------------------------------------------
-- Lookups
-- ---------------------------------------------------------------------------

--- Fractional book position (1 .. page_count + 1) for an audio time.
function BookAudioMap:timeToPosition(t)
    local pts = self.points
    t = clamp(tonumber(t) or 0, 0, self.duration)
    -- Last point at or before t: at a boundary shared by several points
    -- (a chapter whose text has no audio) the later page wins, so a chapter
    -- start lands on that chapter and not on the skipped text before it.
    local k = 1
    while pts[k + 1] and pts[k + 1].t <= t do k = k + 1 end
    local a, b = pts[k], pts[k + 1]
    if not b then return a.p end
    return a.p + (t - a.t) / (b.t - a.t) * (b.p - a.p)
end

--- Page shown for an audio time.
function BookAudioMap:timeToPage(t)
    return clamp(math.floor(self:timeToPosition(t)), 1, self.page_count)
end

--- Audio time for the top of a page.
function BookAudioMap:pageToTime(page)
    local pts = self.points
    local p = clamp(tonumber(page) or 1, 1, self.page_count + 1)
    for k = 1, #pts - 1 do
        local a, b = pts[k], pts[k + 1]
        if p >= a.p and p < b.p then
            return a.t + (p - a.p) / (b.p - a.p) * (b.t - a.t)
        end
    end
    return pts[#pts].t
end

--- Audio chapter title at a time (nil when the book has no chapters).
function BookAudioMap:chapterAt(t)
    local title
    for _, a in ipairs(self.audio or {}) do
        if a.start_time <= t then title = a.title else break end
    end
    return title
end

--- One-line summary for logs and the diagnostics dialog.
function BookAudioMap:describe()
    if self.method == "proportional" then
        return string.format("proportional (no chapter pairs; %d audio chapters, %d TOC entries)",
            self.audio_count, self.toc_count)
    end
    return string.format("%d of %d audio chapters paired with the table of contents (%d by title, %d by order)",
        #self.pairs, self.audio_count, self.title_matches, self.order_matches)
end

return BookAudioMap
