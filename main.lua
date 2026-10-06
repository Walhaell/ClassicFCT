local addonName, CFCT = ...
_G[addonName] = CFCT
local IsClassic = (WOW_PROJECT_ID == WOW_PROJECT_CLASSIC)
local IsBCC = (WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC)
local IsRetail = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
-- WoW: Forever (product wow_classic_beta, interface 16xxx). It runs on the
-- retail UI engine and inherits the retail addon restrictions, which changes
-- where combat text comes from:
--   * CombatLogGetCurrentEventInfo does not exist on this client, so COMBAT_LOG
--     EVENT_UNFILTERED is unusable and every amount/flag below used to come
--     from the combat log is gone.
--   * The replacement is C_CombatText: the COMBAT_TEXT_UPDATE event plus
--     C_CombatText.GetCurrentEventInfo(), whose returns are secret values.
--     Secret values may only be handed to a C side formatter; comparing,
--     concatenating or doing arithmetic on them throws and blanks the frame.
-- So on Forever amounts are turned into plain strings as early as possible and
-- everything numeric (filters, merging, sorting) is unavailable.
-- GetBuildInfo returns its interface number as the fourth value, but on some
-- clients it returns more values than that, so the fourth one is picked up
-- into a name instead of being passed on to another function as extra
-- arguments.
local _, _, _, ForeverTOCVersion = GetBuildInfo()
local ForeverInterface = tonumber(ForeverTOCVersion) or 0
local IsForever = (ForeverInterface >= 16000 and ForeverInterface < 20000)
    and (type(C_CombatText) == "table")
    and (type(C_CombatText.GetCurrentEventInfo) == "function")
CFCT.IsForever = IsForever
CFCT.Interface = ForeverInterface
local issecretvalue = issecretvalue
CFCT.IsSecretValue = issecretvalue
local tinsert, tremove, tsort, format, strlen, strsub, gsub, floor, sin, cos, asin, acos, random, select, pairs, ipairs, unpack, bitband = table.insert, table.remove, table.sort, string.format, string.len, string.sub, string.gsub, math.floor, math.sin, math.cos, math.asin, math.acos, math.random, select, pairs, ipairs, unpack, bit.band
local InCombatLockdown = InCombatLockdown
local AbbreviateNumbers = AbbreviateNumbers
local GetTime = GetTime
local GetAddOnMetadata = GetAddOnMetadata or C_AddOns.GetAddOnMetadata

local GetSpellInfo_old = GetSpellInfo
local GetSpellInfo = (type(GetSpellInfo_old) == 'function') and function(id)
    local name, rank, icon, castTime, minRange, maxRange, spellID, originalIcon = GetSpellInfo_old(id)
    return {
        name = name,
        rank = rank,
        iconID = icon,
        originalIconID = originalIcon,
        castTime = castTime,
        minRange = minRange,
        maxRange = maxRange,
        spellID = spellID
    }
end or C_Spell.GetSpellInfo

CFCT.frame = CreateFrame("Frame", "ClassicFCT.frame", UIParent)
CFCT.Animating = {}
CFCT.fontStringCache = {}
-- CFCT.Debug = true

local now = GetTime()
local f = CFCT.frame
f:SetSize(1,1)
f:SetPoint("CENTER", 0, 0)

local anim = CFCT.Animating
local fsc = CFCT.fontStringCache

local function round(n, d)
    local p = 10^d
    return math.floor(n * p) / p
end

local damageRollingAverage = 0
function CFCT:DamageRollingAverage()
    return damageRollingAverage
end

local ROLLING_AVERAGE_LENGTH = 10
local rollingAverageTimer = 0
local damageCache = {}
local function AddToAverage(value)
    if CFCT._testMode and not InCombatLockdown() then return end
    tinsert(damageCache, {
        value = value,
        time = now
    })
end
local ROLLINGAVERAGE_UPDATE_INTERVAL = 0.5
local function CalculateRollingAverage()
    local cacheSize = #damageCache
    local damage, count = 0, 0
    for k,v in ipairs(damageCache) do
        if (cacheSize > 200) and ((now - v.time) > ROLLING_AVERAGE_LENGTH) then
            tremove(damageCache, k)
        else
            damage = damage + v.value
            count = count + 1
        end
    end
    damageRollingAverage = count > 0 and damage / count or 0
end


local function FormatThousandSeparator(v)
    local s = format("%d", floor(v))
    local pos = strlen(s) % 3
    if pos == 0 then pos = 3 end
    return strsub(s, 1, pos)..gsub(strsub(s, pos+1), "(...)", ",%1")
end


-- ----------------------------------------------------------------------
-- WoW: Forever: getting an amount out of a secret value
-- ----------------------------------------------------------------------
-- BreakUpLargeNumbers and AbbreviateNumbers are C side, so they accept a
-- secret number and hand back a plain, printable string. Everything that can
-- work with a secret number has to happen inside those calls, never in Lua.
local function IsSecret(v)
    return (issecretvalue ~= nil) and issecretvalue(v) and true or false
end

-- Checking a payload against nil is a comparison, and a comparison on a secret
-- value throws just like arithmetic does, so nil is only ever tested after
-- asking whether the value is secret.
local function IsNil(v)
    if (IsSecret(v)) then return false end
    return v == nil
end

local foreverAbbrevOptions
local function ForeverAbbreviateOptions()
    if (foreverAbbrevOptions == nil) then
        local data = C_AbbreviateConfigAPI and C_AbbreviateConfigAPI.GetAbbreviateNumberData
            and C_AbbreviateConfigAPI.GetAbbreviateNumberData()
        foreverAbbrevOptions = (data and CreateAbbreviateConfig) and CreateAbbreviateConfig(data) or false
    end
    return foreverAbbrevOptions or nil
end

-- Returns a printable string for an amount, never a secret value. Abbreviating
-- needs the locale options table on this client, so it is looked up once and
-- falls back to plain formatting when it cannot be built.
function CFCT:FormatAmount(value)
    local fctConfig = CFCT.Config
    if (fctConfig.abbreviateNumbers) then
        local opts = ForeverAbbreviateOptions()
        local ok, formatted = pcall(AbbreviateNumbers, value, opts)
        if (ok and not IsSecret(formatted) and (formatted ~= nil)) then
            return formatted
        end
    end
    local ok, formatted = pcall(BreakUpLargeNumbers, value)
    if (ok and not IsSecret(formatted) and (formatted ~= nil)) then
        return formatted
    end
    return nil
end

-- Builds "prefix<amount>" for display. When the amount cannot be turned into a
-- plain string, the FontString is handed the secret value itself through
-- SetFormattedText, which is always allowed. The caller gets either a ready
-- text or a format pattern plus the value to feed it with.
local function ForeverText(value, prefix)
    local formatted = CFCT:FormatAmount(value)
    if (formatted) then
        return prefix..formatted, nil, nil
    end
    return nil, prefix.."%s", value
end

local function InitFont(self, state)
    local fontOptions = state.fontOptions
    self:SetFont(fontOptions.fontPath, fontOptions.fontSize, fontOptions.fontStyle)
    self:SetShadowOffset(fontOptions.fontSize/14, fontOptions.fontSize/14)
    self:SetDrawLayer("OVERLAY")
    self:SetJustifyH("CENTER")
    self:SetJustifyV("MIDDLE")
    -- self:SetPoint("BOTTOM", 0, 0)
    if (state.textFmt and (state.secretValue ~= nil)) then
        -- WoW: Forever: the amount never became a plain string, so it is passed
        -- straight to the FontString, which is allowed to read secret values.
        local shown = pcall(function() self:SetFormattedText(state.textFmt, state.secretValue) end)
        if (not shown) then self:SetText("?") end
    else
        self:SetText(state.text)
    end
    self:SetTextColor(unpack(fontOptions.fontColor))
    self:SetAlpha(fontOptions.fontAlpha)
    self:SetShadowColor(0,0,0,fontOptions.fontAlpha/2)
    state.initialTime = now
    -- Measuring is a C side operation on text the FontString already holds.
    -- If a client ever refused it the text still gets shown, it just overlaps.
    local okHeight, height = pcall(self.GetStringHeight, self)
    local okWidth, width = pcall(self.GetStringWidth, self)
    state.strHeight = (okHeight and (type(height) == "number")) and height or (fontOptions.fontSize * 1.5)
    state.strWidth = (okWidth and (type(width) == "number")) and width or (fontOptions.fontSize * 4)
    state.posX = 0
    state.posY = 0
    state.direction = 0
    self.state = state
    self:Hide()
    return self
end

local function ReleaseFont(self)
    self.state = nil
    self:Hide()
    tinsert(fsc, self)
end

local function CheckCollision(x1, y1, w1, h1, x2, y2, w2, h2)
    local overlapX = x1 < x2 and w1 - (x2 - x1) or w2 -( x1 - x2)
    local overlapY = y1 < y2 and h1 - (y2 - y1) or h2 - (y1 - y2)
    if (overlapX > 0 and overlapY > 0) then
        return overlapX, overlapY
    end
end

local GRID = {
    false,
    {y={o=1, p=1}},
    {x={o=1, p=1}},
    {y={o=-1, p=1}},
    {x={o=-1, p=1}},
    {x={o=1, p=2}, y={o=1, p=3}},
    {x={o=1, p=4}, y={o=-1, p=3}},
    {x={o=-1, p=2}, y={o=1, p=5}},
    {x={o=-1, p=4}, y={o=-1, p=5}},
    {y={o=1, p=2}},
    {x={o=1, p=3}},
    {y={o=-1, p=4}},
    {x={o=-1, p=5}},
    {x={o=1, p=6}, y={o=1, p=11}},
    {x={o=1, p=7}, y={o=-1, p=11}},
    {x={o=-1, p=8}, y={o=1, p=13}},
    {x={o=-1, p=9}, y={o=-1, p=13}},
    {x={o=1, p=10}, y={o=1, p=6}},
    {x={o=1, p=12}, y={o=-1, p=7}},
    {x={o=-1, p=10}, y={o=1, p=8}},
    {x={o=-1, p=12}, y={o=-1, p=9}},
    {y={o=1, p=10}},
    {x={o=1, p=11}},
    {y={o=-1, p=12}},
    {x={o=-1, p=13}},
    {x={o=1, p=18}, y={o=1, p=14}},
    {x={o=1, p=19}, y={o=-1, p=15}},
    {x={o=-1, p=20}, y={o=1, p=16}},
    {x={o=-1, p=21}, y={o=-1, p=17}},
    {x={o=1, p=22}, y={o=1, p=18}},
    {x={o=1, p=14}, y={o=1, p=23}},
    {x={o=1, p=15}, y={o=-1, p=23}},
    {x={o=1, p=24}, y={o=-1, p=19}},
    {x={o=-1, p=24}, y={o=-1, p=21}},
    {x={o=-1, p=16}, y={o=1, p=25}},
    {x={o=-1, p=17}, y={o=-1, p=25}},
    {x={o=-1, p=22}, y={o=1, p=20}},
    {y={o=1, p=22}},
    {x={o=1, p=23}},
    {y={o=-1, p=24}},
    {x={o=-1, p=25}},
    {x={o=1, p=30}, y={o=1, p=26}},
    {x={o=1, p=33}, y={o=-1, p=27}},
    {x={o=-1, p=34}, y={o=-1, p=29}},
    {x={o=-1, p=37}, y={o=1, p=28}},
    {x={o=1, p=26}, y={o=1, p=31}},
    {x={o=1, p=27}, y={o=-1, p=32}},
    {x={o=-1, p=28}, y={o=1, p=35}},
    {x={o=-1, p=29}, y={o=-1, p=36}},
    {x={o=1, p=38}, y={o=1, p=30}},
    {x={o=1, p=31}, y={o=1, p=39}},
    {x={o=1, p=32}, y={o=-1, p=39}},
    {x={o=1, p=40}, y={o=-1, p=33}},
    {x={o=-1, p=40}, y={o=-1, p=34}},
    {x={o=-1, p=35}, y={o=1, p=41}},
    {x={o=-1, p=36}, y={o=-1, p=41}},
    {x={o=-1, p=38}, y={o=1, p=37}},
    {y={o=1, p=38}},
    {x={o=1, p=39}},
    {y={o=-1, p=40}},
    {x={o=-1, p=41}},
    {x={o=1, p=50}, y={o=1, p=42}},
    {x={o=1, p=53}, y={o=-1, p=43}},
    {x={o=-1, p=57}, y={o=1, p=45}},
    {x={o=-1, p=54}, y={o=-1, p=44}},
    {x={o=1, p=42}, y={o=1, p=46}},
    {x={o=1, p=43}, y={o=-1, p=47}},
    {x={o=-1, p=45}, y={o=1, p=48}},
    {x={o=-1, p=44}, y={o=-1, p=49}},
    {x={o=1, p=46}, y={o=1, p=51}},
    {x={o=1, p=47}, y={o=-1, p=52}},
    {x={o=-1, p=48}, y={o=1, p=55}},
    {x={o=-1, p=49}, y={o=-1, p=56}},
    {x={o=1, p=58}, y={o=1, p=50}},
    {x={o=1, p=51}, y={o=1, p=59}},
    {x={o=1, p=52}, y={o=-1, p=59}},
    {x={o=1, p=60}, y={o=-1, p=53}},
    {x={o=-1, p=60}, y={o=-1, p=54}},
    {x={o=-1, p=55}, y={o=1, p=61}},
    {x={o=-1, p=56}, y={o=-1, p=61}},
    {x={o=-1, p=58}, y={o=1, p=57}},
    {y={o=1, p=58}},
    {x={o=1, p=59}},
    {y={o=-1, p=60}},
    {x={o=-1, p=61}},
    {x={o=1, p=62}, y={o=1, p=66}},
    {x={o=1, p=63}, y={o=-1, p=67}},
    {x={o=-1, p=65}, y={o=-1, p=69}},
    {x={o=-1, p=64}, y={o=1, p=68}},
    {x={o=1, p=66}, y={o=1, p=70}},
    {x={o=1, p=67}, y={o=-1, p=71}},
    {x={o=-1, p=68}, y={o=1, p=72}},
    {x={o=-1, p=69}, y={o=-1, p=73}},
    {x={o=1, p=74}, y={o=1, p=62}},
    {x={o=1, p=77}, y={o=-1, p=63}},
    {x={o=-1, p=81}, y={o=1, p=64}},
    {x={o=-1, p=78}, y={o=-1, p=65}},
    {x={o=1, p=70}, y={o=1, p=75}},
    {x={o=1, p=71}, y={o=-1, p=76}},
    {x={o=-1, p=72}, y={o=1, p=79}},
    {x={o=-1, p=73}, y={o=-1, p=80}},
    {x={o=1, p=82}, y={o=1, p=74}},
    {x={o=1, p=84}, y={o=-1, p=77}},
    {x={o=-1, p=84}, y={o=-1, p=78}},
    {x={o=-1, p=82}, y={o=1, p=81}},
    {x={o=1, p=75}, y={o=1, p=83}},
    {x={o=1, p=76}, y={o=-1, p=83}},
    {x={o=-1, p=79}, y={o=1, p=85}},
    {x={o=-1, p=80}, y={o=-1, p=85}},
    {y={o=1, p=82}},
    {x={o=1, p=83}},
    {y={o=-1, p=84}},
    {x={o=-1, p=85}},
    {x={o=1, p=86}, y={o=1, p=90}},
    {x={o=1, p=87}, y={o=-1, p=91}},
    {x={o=-1, p=89}, y={o=1, p=92}},
    {x={o=-1, p=88}, y={o=-1, p=93}},
    {x={o=1, p=94}, y={o=1, p=86}},
    {x={o=1, p=95}, y={o=-1, p=87}},
    {x={o=-1, p=96}, y={o=1, p=89}},
    {x={o=-1, p=97}, y={o=-1, p=88}},
    {x={o=1, p=102}, y={o=1, p=94}},
    {x={o=1, p=103}, y={o=-1, p=95}},
    {x={o=-1, p=105}, y={o=1, p=96}},
    {x={o=-1, p=104}, y={o=-1, p=97}},
    {x={o=1, p=90}, y={o=1, p=98}},
    {x={o=1, p=91}, y={o=-1, p=99}},
    {x={o=-1, p=92}, y={o=1, p=100}},
    {x={o=-1, p=93}, y={o=-1, p=101}},
    {x={o=1, p=110}, y={o=1, p=102}},
    {x={o=1, p=112}, y={o=-1, p=103}},
    {x={o=-1, p=110}, y={o=1, p=105}},
    {x={o=-1, p=112}, y={o=-1, p=104}},
    {x={o=1, p=98}, y={o=1, p=106}},
    {x={o=1, p=99}, y={o=-1, p=107}},
    {x={o=-1, p=100}, y={o=1, p=108}},
    {x={o=-1, p=101}, y={o=-1, p=109}},
    {x={o=1, p=106}, y={o=1, p=111}},
    {x={o=1, p=107}, y={o=-1, p=111}},
    {x={o=-1, p=108}, y={o=1, p=113}},
    {x={o=-1, p=109}, y={o=-1, p=113}},
    {x={o=1, p=118}, y={o=1, p=114}},
    {x={o=1, p=119}, y={o=-1, p=115}},
    {x={o=-1, p=120}, y={o=1, p=116}},
    {x={o=-1, p=121}, y={o=-1, p=117}},
    {x={o=1, p=122}, y={o=1, p=118}},
    {x={o=1, p=123}, y={o=-1, p=119}},
    {x={o=-1, p=124}, y={o=1, p=120}},
    {x={o=-1, p=125}, y={o=-1, p=121}},
    {x={o=1, p=114}, y={o=1, p=126}},
    {x={o=1, p=115}, y={o=-1, p=127}},
    {x={o=-1, p=116}, y={o=1, p=128}},
    {x={o=-1, p=117}, y={o=-1, p=129}},
    {x={o=1, p=126}, y={o=1, p=134}},
    {x={o=1, p=127}, y={o=-1, p=135}},
    {x={o=-1, p=128}, y={o=1, p=136}},
    {x={o=-1, p=129}, y={o=-1, p=137}},
    {x={o=1, p=130}, y={o=1, p=122}},
    {x={o=1, p=131}, y={o=-1, p=123}},
    {x={o=-1, p=132}, y={o=1, p=124}},
    {x={o=-1, p=133}, y={o=-1, p=125}},
    {x={o=1, p=134}, y={o=1, p=138}},
    {x={o=1, p=135}, y={o=-1, p=139}},
    {x={o=-1, p=136}, y={o=1, p=140}},
    {x={o=-1, p=137}, y={o=-1, p=141}},
    {x={o=1, p=142}, y={o=1, p=150}},
    {x={o=1, p=143}, y={o=-1, p=151}},
    {x={o=-1, p=144}, y={o=1, p=152}},
    {x={o=-1, p=145}, y={o=-1, p=153}},
    {x={o=1, p=146}, y={o=1, p=142}},
    {x={o=1, p=147}, y={o=-1, p=143}},
    {x={o=-1, p=148}, y={o=1, p=144}},
    {x={o=-1, p=149}, y={o=-1, p=145}},
    {x={o=1, p=150}, y={o=1, p=154}},
    {x={o=1, p=151}, y={o=-1, p=155}},
    {x={o=-1, p=152}, y={o=1, p=156}},
    {x={o=-1, p=153}, y={o=-1, p=157}},
    {x={o=1, p=158}, y={o=1, p=146}},
    {x={o=1, p=159}, y={o=-1, p=147}},
    {x={o=-1, p=160}, y={o=1, p=148}},
    {x={o=-1, p=161}, y={o=-1, p=149}},
    {x={o=1, p=154}, y={o=1, p=162}},
    {x={o=1, p=155}, y={o=-1, p=163}},
    {x={o=-1, p=156}, y={o=1, p=164}},
    {x={o=-1, p=157}, y={o=-1, p=165}},
    {x={o=1, p=170}, y={o=1, p=166}},
    {x={o=1, p=171}, y={o=-1, p=167}},
    {x={o=-1, p=172}, y={o=1, p=168}},
    {x={o=-1, p=173}, y={o=-1, p=169}},
    {x={o=1, p=178}, y={o=1, p=170}},
    {x={o=1, p=179}, y={o=-1, p=171}},
    {x={o=-1, p=180}, y={o=1, p=172}},
    {x={o=-1, p=181}, y={o=-1, p=173}},
    {x={o=1, p=166}, y={o=1, p=174}},
    {x={o=1, p=167}, y={o=-1, p=175}},
    {x={o=-1, p=168}, y={o=1, p=176}},
    {x={o=-1, p=169}, y={o=-1, p=177}},
    {x={o=1, p=174}, y={o=1, p=182}},
    {x={o=1, p=175}, y={o=-1, p=183}},
    {x={o=-1, p=176}, y={o=1, p=184}},
    {x={o=-1, p=177}, y={o=-1, p=185}},
    {x={o=1, p=186}, y={o=1, p=194}},
    {x={o=-1, p=188}, y={o=1, p=196}},
    {x={o=1, p=187}, y={o=-1, p=195}},
    {x={o=1, p=190}, y={o=1, p=186}},
    {x={o=1, p=191}, y={o=-1, p=187}},
    {x={o=-1, p=192}, y={o=1, p=188}},
    {x={o=-1, p=193}, y={o=-1, p=189}},
    {x={o=1, p=194}, y={o=1, p=198}},
    {x={o=1, p=195}, y={o=-1, p=199}},
    {x={o=-1, p=196}, y={o=1, p=200}},
    {x={o=-1, p=197}, y={o=-1, p=201}},
    {x={o=1, p=205}, y={o=1, p=202}},
    {x={o=1, p=206}, y={o=-1, p=204}},
    {x={o=-1, p=207}, y={o=1, p=203}},
    {x={o=-1, p=208}, y={o=-1, p=204}},
    {x={o=1, p=202}, y={o=1, p=209}},
    {x={o=1, p=204}, y={o=-1, p=210}},
    {x={o=-1, p=203}, y={o=1, p=211}},
    {x={o=-1, p=204}, y={o=-1, p=212}},
    {x={o=1, p=213}, y={o=1, p=217}},
    {x={o=1, p=214}, y={o=-1, p=218}},
    {x={o=-1, p=215}, y={o=1, p=219}},
    {x={o=-1, p=216}, y={o=-1, p=220}},
}


-- local gapX = 30
-- local gapY = 50
local function GridLayout(unsortedFrames)
    local fctConfig = CFCT.Config
    local frames = {}
    -- Sorting compares amounts, which are secret values on WoW: Forever.
    if (fctConfig.sortByDamage and not IsForever) then
        local missPrio = fctConfig.sortMissPrio
        local tinsert = tinsert
        local count = 0
        for k,v in ipairs(unsortedFrames) do
            if (k == 1) then
                tinsert(frames, v)
                count = count + 1
            else
                local s1 = v.state
                for i,e in ipairs(frames) do
                    local s2 = e.state
                    if (not s2.miss and not s1.miss) and (s2.amount < s1.amount) then
                        tinsert(frames, i, v)
                        count = count + 1
                        break
                    elseif (s1.miss ~= s2.miss) and ((s1.miss and missPrio) or not s1.miss) then
                        tinsert(frames, i, v)
                        count = count + 1
                        break
                    elseif (i == count) then
                        tinsert(frames, i + 1, v)
                        count = count + 1
                        break
                    end
                end
            end
        end
    else
        frames = unsortedFrames
    end
    -- if CFCT.Debug then
    --     for k,v in pairs(frames) do
    --         v:SetText(k .. v.state.text)
    --     end
    -- end
    local gapX = fctConfig.preventOverlapSpacingX
    local gapY = fctConfig.preventOverlapSpacingY
    for k, e in ipairs(frames) do
        -- frame mode
        -- local gapX, gapY = gapX * e.state.baseScale, gapY * e.state.baseScale
        local gridCell = GRID[k]
        local gridX = gridCell and (gridCell.x and frames[gridCell.x.p].state.gridX + gridCell.x.o * (gapX + frames[gridCell.x.p].state.width + 0.5*(e.state.width - frames[gridCell.x.p].state.width))) or 0
        local gridY = gridCell and (gridCell.y and frames[gridCell.y.p].state.gridY + gridCell.y.o * (gapY + (gridCell.y.o < 0 and e.state.height or frames[gridCell.y.p].state.height))) or 0
        if gridCell or k == 1 then
            if (e.state.gridIdx and (e.state.gridIdx ~= k)) then
                e.state.scrollReset = true
            end
            e.state.gridIdx = k
            -- e:SetText(format("%03d",e.state.gridIdx))
            e.state.posX = e.state.posX + gridX - (e.state.gridX or 0)
            e.state.posY = e.state.posY + gridY - (e.state.gridY or 0)
            e.state.gridX = gridX
            e.state.gridY = gridY
        else
            e.state.posX = e.state.posX + gridX - (e.state.gridX or 0)
            e.state.posY = e.state.posY + gridY - (e.state.gridY or 0)
            e.state.gridX = 9999
            e.state.gridY = 9999
        end
    end
    return frames
end

local function AnimateLinearAbsolute(startTime, duration, minval, maxval)
    local prog = min(max((now - startTime) / duration, 0), 1)
    return (maxval - minval) * prog + minval
end

local function AnimateLinearRelative(startTime, duration, minval, maxval, curval)
    local prog = min(max((now - startTime) / duration, 0), 1)
    return ((maxval - minval) * prog + minval) - curval
end

local ANIMATIONS = {
    Pow = function(self, catConfig, animConfig)
        local duration = animConfig.duration * CFCT.Config.animDuration
        local midTime = self.state.initialTime + (duration * animConfig.inOutRatio)
        if (now < midTime) then
            self.state.powScale = AnimateLinearAbsolute(self.state.initialTime, midTime - self.state.initialTime, animConfig.initScale, animConfig.midScale)
            -- self:SetTextHeight(catConfig.fontSize * AnimateLinearAbsolute(self.state.initialTime, midTime - self.state.initialTime, animConfig.initScale, animConfig.midScale))
        else
            self.state.powScale = AnimateLinearAbsolute(midTime, duration * (1 - animConfig.inOutRatio), animConfig.midScale, animConfig.endScale)
            -- self:SetTextHeight(catConfig.fontSize * AnimateLinearAbsolute(midTime, duration * (1 - animConfig.inOutRatio), animConfig.midScale, animConfig.endScale))
        end
    end,
    FadeIn = function(self, catConfig, animConfig)
        local curAlpha = self:GetAlpha()
        local duration = animConfig.duration * CFCT.Config.animDuration
        local endTime = self.state.initialTime + duration
        if (now <= endTime) then
            local fadeInAlpha = AnimateLinearAbsolute(self.state.initialTime, duration, 0, self.state.fontOptions.fontAlpha)
            self.state.fadeAlpha = (fadeInAlpha + (self.state.fadeOutAlpha or fadeInAlpha)) * 0.5
            self.state.fadeInAlpha = fadeInAlpha
        else
            self.state.fadeInAlpha = nil
        end
    end,
    FadeOut = function(self, catConfig, animConfig)
        local curAlpha = self:GetAlpha()
        local duration = animConfig.duration
        local startTime = self.state.initialTime + CFCT.Config.animDuration - duration
        if (now >= startTime) then
            local fadeOutAlpha = AnimateLinearAbsolute(startTime, duration, self.state.fontOptions.fontAlpha, 0)
            self.state.fadeAlpha = (fadeOutAlpha + (self.state.fadeInAlpha or fadeOutAlpha)) * 0.5
            self.state.fadeOutAlpha = fadeOutAlpha
        else
            self.state.fadeOutAlpha = nil
        end
    end,
    Scroll = function(self, catConfig, animConfig)
        local duration = CFCT.Config.animDuration
        local state, dir, dist, scrollX, scrollY = self.state, animConfig.direction, animConfig.distance, 0, 0

        if dir:find("RANDOM") then
            if (state.randomX == nil) and (state.randomY == nil) then
                local a = random(1,628) / 100
                local rx, ry = cos(a), sin(a)
                state.randomX, state.randomY =  rx * dist, ry * dist
            end
            scrollX = AnimateLinearAbsolute(state.initialTime, duration, 0, state.randomX)
            scrollY = AnimateLinearAbsolute(state.initialTime, duration, 0, state.randomY)
        elseif dir:find("RIGHT") then
            scrollX = AnimateLinearAbsolute(state.initialTime, duration, 0, dist)
        elseif dir:find("LEFT") then
            scrollX = AnimateLinearAbsolute(state.initialTime, duration, 0, -dist)
        end
        if dir:find("UP") then
            scrollY = AnimateLinearAbsolute(state.initialTime, duration, 0, dist)
        elseif dir:find("DOWN") then
            scrollY = AnimateLinearAbsolute(state.initialTime, duration, 0, -dist)
        end
        if state.scrollOriginX == nil then
            state.scrollOriginX = 0
            state.scrollOriginY = 0
        elseif state.scrollReset then
            state.scrollOriginX = -scrollX
            state.scrollOriginY = -scrollY
            state.scrollReset = nil
        end
        scrollX = scrollX + state.scrollOriginX
        scrollY = scrollY + state.scrollOriginY
        -- substract old scroll pos and add new scroll pos
        state.posX = state.posX + scrollX - (state.scrollX or 0)
        state.posY = state.posY + scrollY - (state.scrollY or 0)
        -- save current scroll pos for next call
        state.scrollX = scrollX
        state.scrollY = scrollY
    end,
    -- Map


}

local UIParent = UIParent
local WorldFrame = WorldFrame
local GetNamePlateForUnit = C_NamePlate.GetNamePlateForUnit
local function UpdateFontParent(self)
    local fctConfig = CFCT.Config
    if IsForever then
        -- Combat text on this client carries no unit token and its nameplates
        -- have no namePlateUnitToken, so there is nothing to look up and
        -- nothing to inherit a scale from: everything stays on the screen.
        self:SetParent(UIParent)
        self.state.baseScale = 1
        self.state.attach = f
        return
    end
    local nameplate = UnitExists(self.state.unit) and GetNamePlateForUnit(self.state.unit) or false
    local attach
    if ((fctConfig.attachMode == "tn") or (fctConfig.attachMode == "en")) and nameplate then
        attach = nameplate
    elseif (fctConfig.attachMode == "sc") or (fctConfig.attachModeFallback == true) then
        attach = f
    else
        attach = false
    end
    local inheritNameplates = fctConfig.inheritNameplates
    if fctConfig.dontOverlapNameplates then
        self:SetParent(WorldFrame)
        self.state.baseScale = inheritNameplates and (attach and attach == nameplate) and attach:GetEffectiveScale() * UIParent:GetScale() or UIParent:GetScale()
    else
        self:SetParent(UIParent)
        self.state.baseScale = inheritNameplates and (attach and attach == nameplate) and attach:GetEffectiveScale() or 1
    end
    self.state.attach = attach
end

local function CalculateStringSize(self)
    -- frame mode
    -- self.state.height = self.state.strHeight * self.state.baseScale * self.state.powScale
    -- self.state.width = self.state.strWidth * self.state.baseScale * self.state.powScale
    self.state.height = self.state.strHeight * self.state.powScale
    self.state.width = self.state.strWidth * self.state.powScale
end

local function ValidateFont(self)
    local fctConfig = CFCT.Config
    if ((now - self.state.initialTime) > fctConfig.animDuration) then
        return false
    end
    local catConfig = fctConfig[self.state.cat]
    if not (catConfig and catConfig.enabled) then
        return false
    end
    self.state.catConfig = catConfig
    return true
end

local function UpdateFontAnimations(self)
    local catConfig = self.state.catConfig
    CalculateStringSize(self)
    for animName, animFunc in pairs(ANIMATIONS) do
        local animConfig = catConfig[animName]
        if (animConfig and (type(animConfig) == 'table')) and animConfig.enabled then
            animFunc(self, catConfig, animConfig)
        end
    end
    CalculateStringSize(self)
    -- self:SetText(format("%04d",self.state.width))
    -- print(self:GetParent():GetName(), round(self.state.strWidth,2), round(self.state.baseScale,2), round(self.state.width,2))
end


local function UpdateFontPos(self)
    local fctConfig = CFCT.Config
    local attach = self.state.attach
    if attach then
        local isNamePlate = attach.namePlateUnitToken ~= nil
        local areaX = isNamePlate and fctConfig.areaNX or fctConfig.areaX
        local areaY = isNamePlate and fctConfig.areaNY or fctConfig.areaY
        if fctConfig.perspectiveScale then
            self:SetPoint("CENTER", attach, "CENTER", areaX + self.state.posX, areaY + self.state.posY)
        else
            -- local scaleFactor = 1 / (self.state.baseScale * self.state.powScale)
            local scaleFactor = 1 / self.state.powScale
            self:SetPoint("CENTER", attach, "CENTER", (areaX + self.state.posX) * scaleFactor, (areaY + self.state.posY) * scaleFactor)
        end
        -- self:SetFrameStrata(fctConfig.textStrata or "MEDIUM")
        self:Show()
    else
        self:Hide()
    end
end

local function ApplyFontUpdate(self)
    local alpha = self.state.baseAlpha * self.state.fadeAlpha
    local scale = self.state.baseScale * self.state.powScale
    -- local scale = self.state.powScale
    self:SetAlpha(alpha)
    self:SetShadowColor(0, 0, 0, alpha / 2)
    -- if CFCT.Config.perspectiveScale then
        self:SetScale(scale)
    -- else
        -- self.font:SetScale(scale)
    -- end
end






local function GrabFontString()
    if (#fsc > 0) then return tremove(fsc) end
    local frame = f:CreateFontString()

    frame.Init = InitFont
    frame.UpdateParent = UpdateFontParent
    frame.UpdateAnimation = UpdateFontAnimations
    frame.UpdatePosition = UpdateFontPos
    frame.Validate = ValidateFont
    frame.Release = ReleaseFont
    frame.ApplyUpdate = ApplyFontUpdate

    return frame
end

local iconCache = {}
local function SpellIconText(spell) -- spellid or spellname
    local fctConfig = CFCT.Config
    local tx = iconCache[spell] or GetSpellInfo(spell).iconID
    if tx then
        iconCache[spell] = tx
        local aspectRatio = fctConfig.spellIconAspectRatio
        local zoom = fctConfig.spellIconZoom
        local offsetX, offsetY = fctConfig.spellIconOffsetX, fctConfig.spellIconOffsetY
        local height, width = 12 / aspectRatio, 12
        local txSize = zoom * 100
        local txMinX = (zoom - 1) * 100 / 2
        local txMaxX = (zoom + 1) * 100 / 2
        local txMinY = (zoom - (1 / aspectRatio)) * 100 / 2
        local txMaxY = (zoom + (1 / aspectRatio)) * 100 / 2
        return format("|T%s:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d|t",
            tx, height, width, offsetX, offsetY, txSize, txSize, txMinX, txMaxX, txMinY, txMaxY)
    end
    return false
end


local function GetDamageTypeColor(school)
    return CFCT.Config.colorTable[school]
end
local function GetDotTypeColor(school)
    return CFCT.Config.colorTableDot[school]
end


local function DispatchText(guid, event, text, amount, spellid, spellicon, periodic, crit, miss, pet, school, count, textFmt, secretValue)
    local cat = (pet and "pet" or "")..event..(periodic and "tick" or "")..(crit and "crit" or miss and "miss" or "")
    local fctConfig = CFCT.Config
    local catConfig = fctConfig[cat]
    -- TODO put fctConfig and catConfig into state

    count = count or 1
    if (IsForever) then
        -- Every feature in the block below needs to compare or add up amounts,
        -- and amounts are secret values on WoW: Forever: no rolling average, no
        -- thresholds, no abbreviating here. The amount arrives either as a
        -- ready made string or as a format pattern plus the secret value.
        if (not text) and (not textFmt) then
            text = CFCT:FormatAmount(amount) or ""
        end
    else
        text = text or tostring(amount)
        if (not miss) then
            if (not crit) then
                AddToAverage(amount / count)
            end
            if (fctConfig.filterAbsoluteEnabled and (fctConfig.filterAbsoluteThreshold > amount))
    or (fctConfig.filterRelativeEnabled and ((fctConfig.filterRelativeThreshold * 0.01 * CFCT:UnitHealthMax('player')) > amount))
    or (fctConfig.filterAverageEnabled and ((fctConfig.filterAverageThreshold * 0.01 * CFCT:DamageRollingAverage()) > amount)) then
                return false
            end

            if (fctConfig.abbreviateNumbers) then
                text = AbbreviateNumbers(amount)
            elseif (fctConfig.kiloSeparator) then
                text = FormatThousandSeparator(amount)
            end
        end
    end

    if (count > 1) and fctConfig.mergeEventsCounter then
        text = text.." x"..tostring(count)
    end

    if (not textFmt) and (spellicon and catConfig.showIcons) then text = spellicon..text end

    local fontColor, fontAlpha
    local typeColor = periodic and fctConfig.colorTableDotEnabled and GetDotTypeColor(school) or GetDamageTypeColor(school)
    if (catConfig.colorByType == true) and typeColor then
        local r, g, b, a = CFCT.Color2RGBA((strlen(typeColor) == 6) and "FF"..typeColor or typeColor)
        local a = min(a, select(4, CFCT.Color2RGBA(catConfig.fontColor)))
        fontColor = {r, g, b, a}
        fontAlpha = a
    else
        local r, g, b, a = CFCT.Color2RGBA(catConfig.fontColor)
        fontColor = {r, g, b, a}
        fontAlpha = a
    end

    tinsert(anim, 1, GrabFontString():Init({
        cat = cat,
        guid = guid,
        icon = spellicon,
        text = text,
        textFmt = textFmt,
        secretValue = secretValue,
        amount = amount,
        miss = miss,
        baseAlpha = 1,
        baseScale = 1,
        fadeAlpha = 1,
        powScale = 1,
        fontOptions = {
            fontPath = catConfig.fontPath,
            fontSize = catConfig.fontSize,
            fontStyle = catConfig.fontStyle,
            fontColor = fontColor,
            fontAlpha = fontAlpha
        },
    }))
end

local spellIdCache = {}
CFCT.spellIdCache = spellIdCache
local eventCache = {}
CFCT.eventCache = eventCache
local function CacheEvent(guid, event, amount, text, spellid, spellicon, periodic, crit, miss, pet, school)
    if (spellid and not spellIdCache[spellid]) then
        spellIdCache[spellid] = true
        if CFCT.ConfigPanel:IsVisible() then
            CFCT.ConfigPanel:refresh()
        end
    end

    local fctConfig = CFCT.Config
    if fctConfig.filterSpellBlacklist[spellid] == true
    or (fctConfig.filterMissesEnabled and miss) then
        return
    end

    local mergeConfig = {
        {fctConfig.mergeEventsByGuid, guid},
        {fctConfig.mergeEventsBySpellID, spellid},
        {fctConfig.mergeEventsBySpellIcon, spellicon},
        {fctConfig.mergeEventsBySchool, school}
    }
    local id = tostring(pet)
    for _, e in ipairs(mergeConfig) do
        if e[1] == true then id = id .. tostring(e[2]) end
    end
    -- print(id)
    local mergeTime = fctConfig.mergeEventsIntervalOverrides[spellid] or fctConfig.mergeEventsInterval
    local now = GetTime()
    local record = eventCache[id] or {
        events = {},
        expiry = nil
    }
    tinsert(record.events, {
        time = now,
        guid = guid,
        event = event,
        amount = amount,
        text = text,
        spellid = spellid,
        spellicon = spellicon,
        periodic = periodic,
        crit = crit,
        miss = miss,
        pet = pet,
        school = school,
        count = 1
    })
    if fctConfig.mergeEventsIntervalMode == "first" then
        record.expiry = record.expiry or (now + mergeTime)
    elseif fctConfig.mergeEventsIntervalMode == "last" then
        record.expiry = now + mergeTime
    end
    eventCache[id] = record
end

local function ProcessCachedEvents()
    local mergingEnabled = CFCT.Config.mergeEvents
    local separateMisses = CFCT.Config.mergeEventsMisses

    for id,record in pairs(eventCache) do
        if mergingEnabled then
            if (now > record.expiry) then
                local merge
                for _,e in ipairs(record.events) do
                    if e.miss and separateMisses then
                        DispatchText(e.guid, e.event, e.text, e.amount, e.spellid, e.spellicon, e.periodic, e.crit, e.miss, e.pet, e.school)
                    elseif not merge then
                        merge = e
                    else
                        merge.amount = merge.amount + e.amount
                        merge.text = merge.text or e.text
                        merge.count = merge.count + 1
                        merge.miss = merge.miss == false and false or e.miss
                        merge.crit = merge.crit or e.crit
                        merge.periodic = merge.periodic and e.periodic
                    end
                end
                if merge then
                    local text = (merge.amount ~= 0) and merge.amount or merge.text
                    DispatchText(merge.guid, merge.event, text, merge.amount, merge.spellid, merge.spellicon, merge.periodic, merge.crit, merge.miss, merge.pet, merge.school, merge.count)
                end
                eventCache[id] = nil
            end
        else
            for _,e in ipairs(record.events) do
                local text = (e.amount ~= 0) and e.amount or e.text
                DispatchText(e.guid, e.event, e.text, e.amount, e.spellid, e.spellicon, e.periodic, e.crit, e.miss, e.pet, e.school)
            end
            eventCache[id] = nil
        end
    end
end


-- CFCT.TestFrames = {}
CFCT._testMode = false
local testModeTimer = 0
function CFCT:Test(n)
    local cats = {
        "auto",
        "spell",
        "heal"
    }
    if (IsForever) then
        -- No nameplates to spread over and UnitGUID is a secret value here, so
        -- the preview uses made up amounts instead of live units. They are
        -- plain numbers, which is also the only way to exercise the number
        -- formatting code path from the options panel.
        for i = 1, n do
            local school = random(1,128)
            local crit = (random(1,3) == 1)
            local miss = not crit and (random(1,2) == 1)
            local event = cats[random(1,#cats)]
            local amount = crit and 2674 or 1337
            local amountText = CFCT:FormatAmount(amount) or tostring(amount)
            local text = miss and ForeverMissText("MISS") or ((event == "heal" and "+" or "-")..amountText)
            DispatchText(nil, event, text, nil, nil, "", false, crit, miss, false, school)
        end
        return
    end
    local nameplates = C_NamePlate.GetNamePlates()
    local numplates = #nameplates
    local it = (numplates > 0) and (n*numplates) or n
    for i = 1, it do
        local spellinfo
        repeat
            spellinfo = GetSpellInfo(random(1,32767))
        until (spellinfo and spellinfo.iconID)

        local school = random(1,128)
        local pet = (random(1,3) == 1)
        local crit = (random(1,3) == 1)
        local miss = not crit and (random(1,2) == 1)
        local event = cats[random(1,#cats)]
        local text = miss and "Miss" or nil
        local periodic = (random(1,3) == 1) and event == "spell"
        local amount = crit and 2674 or miss and 0 or 1337
        if crit and miss then
            print(amount, crit, miss)
        end
        local guid = (numplates > 0) and UnitGUID(nameplates[random(1,numplates)].UnitFrame.unit) or UnitGUID("target")
        local spellicon = spellid and SpellIconText(spellid) or ""
        DispatchText(guid, event, text, amount, spellid, spellicon, periodic, crit, miss, pet, school)
    end
end



local CVAR_CHECK_INTERVAL = 5
local cvarTimer = 0
local foreverBlizzHidden = false
local function checkCvars()
    if (IsForever) then
        -- The old floatingCombatTextCombatDamage/CombatHealing cvars are gone
        -- on this client. Blizzard's CombatText frame stops drawing while it
        -- is hidden (its OnEvent bails early), so that is what gets hidden
        -- instead, and it is put back as soon as the option is turned off.
        local blizzFrame = _G.CombatText
        if (blizzFrame) then
            local wantHidden = CFCT.hideBlizz and true or false
            if (wantHidden and not foreverBlizzHidden) then
                foreverBlizzHidden = true
                blizzFrame:Hide()
            elseif (not wantHidden and foreverBlizzHidden) then
                foreverBlizzHidden = false
                blizzFrame:Show()
            end
        end
        return
    end
    if (GetCVarDefault("floatingCombatTextCombatDamage")) then
        local varHideDamage = CFCT.hideBlizz and "0" or "1"
        local cvarHideDamage = GetCVar("floatingCombatTextCombatDamage")
        if not (cvarHideDamage == varHideDamage) then
            if CFCT.forceCVars then
                SetCVar("floatingCombatTextCombatDamage", varHideDamage)
            else
                CFCT.hideBlizz = (cvarHideDamage == "0")
            end
        end
    end
    if (GetCVarDefault("floatingCombatTextCombatHealing")) then
        local varHideHealing = CFCT.hideBlizzHeals and "0" or "1"
        local cvarHideHealing = GetCVar("floatingCombatTextCombatHealing")
        if not (cvarHideHealing == varHideHealing) then
            if CFCT.forceCVars then
                SetCVar("floatingCombatTextCombatHealing", varHideHealing)
            else
                CFCT.hideBlizzHeals = (cvarHideHealing == "0")
            end
        end
    end
end
-- Lets the options panel apply a "Hide Blizzard Text" change right away.
CFCT.ApplyBlizzardTextVisibility = checkCvars



-- ----------------------------------------------------------------------
-- WoW: Forever: C_CombatText
-- ----------------------------------------------------------------------
-- This client does not hand addons a usable combat log, so the only sanctioned
-- source of combat text is the COMBAT_TEXT_UPDATE event. The payload is read
-- with C_CombatText.GetCurrentEventInfo(), which returns up to three values
-- whose meaning depends on the message type (same shape Blizzard's own
-- CombatText.lua uses):
--   damage types    data = amount, arg3 = blocked/absorbed part
--   heal types      data = healer name, arg3 = amount, arg4 = absorbed part
--   miss types      nothing to format, just a label
-- What is *not* reported, and what the categories below therefore give up:
--   spell ids and icons, damage schools, pets and damage over time. A crit is
--   reported as DAMAGE_CRIT whether it came from a swing or from a spell, so it
--   is shown with the auto attack crit style.
local FOREVER_MISS_TYPE = {
    MISS = true, DODGE = true, PARRY = true, EVADE = true, IMMUNE = true,
    DEFLECT = true, REFLECT = true, MISFIRE = true
}
local FOREVER_MISS_LABEL = {
    MISS = "MISS", DODGE = "DODGE", PARRY = "PARRY", EVADE = "EVADE",
    IMMUNE = "IMMUNE", DEFLECT = "DEFLECT", REFLECT = "REFLECT", MISFIRE = "MISFIRE"
}
local FOREVER_REDUCTION_TYPE = {
    BLOCK = "BLOCK", SPELL_BLOCK = "BLOCK",
    ABSORB = "ABSORB", SPELL_ABSORB = "ABSORB",
    RESIST = "RESIST", SPELL_RESIST = "RESIST"
}
-- Message types that carry a damage amount, and which ClassicFCT category each
-- one belongs to. There is no separate type for a damage over time tick, so
-- those arrive as a normal spell hit.
local FOREVER_DAMAGE_TYPE = {
    DAMAGE = "auto", DAMAGE_CRIT = "auto", DAMAGE_SHIELD = "spell",
    SPELL_DAMAGE = "spell", SPLIT_DAMAGE = "spell"
}
local FOREVER_HEAL_TYPE = {
    HEAL = "heal", HEAL_CRIT = "heal", HEAL_ABSORB = "heal", HEAL_CRIT_ABSORB = "heal",
    PERIODIC_HEAL = "healtick", PERIODIC_HEAL_CRIT = "healtick", PERIODIC_HEAL_ABSORB = "healtick"
}

local function ForeverMissText(messageType)
    return _G["COMBAT_TEXT_"..messageType] or FOREVER_MISS_LABEL[messageType] or messageType
end

local function ForeverReductionText(reductionType)
    return _G["COMBAT_TEXT_"..reductionType] or reductionType
end

local foreverUnit = "player"
local function ForeverSetActiveUnit()
    if (type(C_CombatText.SetActiveUnit) == "function") then
        C_CombatText.SetActiveUnit(foreverUnit)
    end
end

local function ForeverDispatch(event, text, textFmt, secretValue, periodic, crit, miss, count)
    if (CFCT.enabled == false) then return end
    local fctConfig = CFCT.Config
    if (miss and fctConfig.filterMissesEnabled) then return end
    -- Merging needs to add amounts together and needs a spell id to group by,
    -- neither of which exists here, so events go straight to the animator.
    DispatchText(nil, event, text, nil, nil, "", periodic, crit, miss, false, nil, count, textFmt, secretValue)
end

function f:COMBAT_TEXT_UPDATE(messageType)
    if (CFCT.enabled == false) then return end
    if (not messageType) then return end
    local data, arg3, arg4 = C_CombatText.GetCurrentEventInfo()
    local isSpell = (strsub(messageType, 1, 6) == "SPELL_")
    local typeName = isSpell and strsub(messageType, 7) or messageType

    if (FOREVER_MISS_TYPE[typeName]) then
        ForeverDispatch(isSpell and "spell" or "auto", ForeverMissText(typeName), nil, nil, false, false, true)
    elseif (FOREVER_DAMAGE_TYPE[messageType]) then
        if (IsNil(data)) then return end
        local crit = (messageType == "DAMAGE_CRIT")
        local text, textFmt, secretValue = ForeverText(data, "-")
        ForeverDispatch(FOREVER_DAMAGE_TYPE[messageType], text, textFmt, secretValue, false, crit, false)
    elseif (FOREVER_HEAL_TYPE[messageType]) then
        if (IsNil(arg3)) then return end
        local event = FOREVER_HEAL_TYPE[messageType]
        local crit = (strfind(messageType, "_CRIT") ~= nil)
        local text, textFmt, secretValue = ForeverText(arg3, "+")
        if (text and not IsNil(arg4)) then
            local absorbed = CFCT:FormatAmount(arg4)
            text = text.." ("..(absorbed or "?").." "..ForeverReductionText("ABSORB")..")"
        end
        ForeverDispatch(event, text, textFmt, secretValue, event == "healtick", crit, false)
    elseif (FOREVER_REDUCTION_TYPE[messageType]) then
        local event = isSpell and "spell" or "auto"
        if (not IsNil(arg3)) and (not IsNil(data)) then
            -- Partial block/absorb/resist: the hit itself, with what was soaked.
            local text, textFmt, secretValue = ForeverText(data, "-")
            local partial = CFCT:FormatAmount(arg3)
            local trailer = partial and (ForeverReductionText(FOREVER_REDUCTION_TYPE[messageType])..": "..partial) or nil
            if (text and trailer) then
                text = text.." ("..trailer..")"
            elseif (textFmt) then
                textFmt = textFmt.." ("..(trailer or "?")..")"
            else
                return
            end
            ForeverDispatch(event, text, textFmt, secretValue, false, false, false)
        else
            -- Fully blocked/absorbed/resisted: only the label is worth showing.
            ForeverDispatch(event, ForeverReductionText(FOREVER_REDUCTION_TYPE[messageType]), nil, nil, false, false, true)
        end
    end
end

function f:UNIT_ENTERED_VEHICLE(unit, showVehicle)
    if (unit == "player") then
        foreverUnit = showVehicle and "vehicle" or "player"
        ForeverSetActiveUnit()
    end
end
function f:UNIT_EXITING_VEHICLE(unit)
    if (unit == "player") then
        foreverUnit = "player"
        ForeverSetActiveUnit()
    end
end

local events
if (IsForever) then
    events = {
        COMBAT_TEXT_UPDATE = true,
        UNIT_ENTERED_VEHICLE = true,
        UNIT_EXITING_VEHICLE = true,
        ADDON_LOADED = true,
        PLAYER_LOGOUT = true,
        PLAYER_ENTERING_WORLD = true
    }
else
    events = {
        COMBAT_LOG_EVENT_UNFILTERED = true,
        UNIT_MAXHEALTH = true,
        ADDON_LOADED = true,
        PLAYER_LOGOUT = true,
        PLAYER_ENTERING_WORLD = true,
        NAME_PLATE_UNIT_ADDED = true,
        NAME_PLATE_UNIT_REMOVED = true
    }
end
for e,_ in pairs(events) do f:RegisterEvent(e) end
f:SetScript("OnEvent", function(self, event, ...) if (self[event]) then self[event](self, ...) end end)

local function SortByUnit(allFrames)
    local fctConfig = CFCT.Config
    if (IsForever) then
        -- One single area: combat text here has no unit to group by.
        for k, frame in ipairs(allFrames) do
            frame.state.unit = "player"
        end
        return {player = allFrames}
    end
    local animAreas = {target={}}
    for k, frame in ipairs(allFrames) do
        local state = frame.state
        if (fctConfig.attachMode == "en") then
            state.unit = CFCT:GetNamePlateUnitByGUID(state.guid) or ""
        else
            state.unit = "target"
        end
        animAreas[state.unit] = animAreas[state.unit] or {}
        tinsert(animAreas[state.unit], frame)
    end
    return animAreas
end

local function PrepareAnimatingFonts()
    local c = #anim
    local i = 1
    while (i <= c) do
        local frame = anim[i]
        if (frame:Validate() == false) then
            frame:Release()
            tremove(anim, i)
            c = c - 1
        else
            i = i + 1
        end
    end
end

local function UpdateAnimatingFonts()
    local animAreas = SortByUnit(anim)
    for k, animArea in pairs(animAreas) do
        for k, frame in ipairs(animArea) do
            frame:UpdateParent(animArea)
            frame:UpdateAnimation()
        end
        if CFCT.Config.preventOverlap then
            GridLayout(animArea)
        end
        for _, e in pairs(animArea) do
            e:UpdatePosition()
            e:ApplyUpdate()
        end
        if (now > cvarTimer) then
            checkCvars()
            cvarTimer = now + CVAR_CHECK_INTERVAL
        end
    end
end

f:SetScript("OnUpdate", function(self, elapsed)
    now = GetTime()
    if CFCT._testMode and (now > testModeTimer) and not InCombatLockdown() then
        CFCT:Test(2)
        testModeTimer = now + CFCT.Config.animDuration / 2
    end
    if (now > rollingAverageTimer) then
        CalculateRollingAverage()
        rollingAverageTimer = now + ROLLINGAVERAGE_UPDATE_INTERVAL
    end
    ProcessCachedEvents()
    PrepareAnimatingFonts()
    UpdateAnimatingFonts()
end)
f:Show()

function f:ADDON_LOADED(name)
    if (name == addonName) then
        CFCT.Config:OnLoad()
        if (IsForever) then
            ForeverSetActiveUnit()
        end
        local version = GetAddOnMetadata(addonName, "Version")
        if (version ~= CFCT.lastVersion) then
            C_Timer.After(5,function()
                CFCT:Log(GetAddOnMetadata(addonName, "Version")..[[

Recent changes:
    0.87u   Aug 16, 2024
        - Fixed miss filter, ColorPicker and Config panels for The War Within]])
            end)
        end
        CFCT.lastVersion = version
    end
end

function f:PLAYER_LOGOUT()
    CFCT.Config:OnSave()
end

local playerGUID
function f:PLAYER_ENTERING_WORLD()
    if (IsForever) then
        -- UnitGUID is a secret value here and combat text carries no unit, so
        -- there is nothing to look up; just make sure the watched unit is set.
        ForeverSetActiveUnit()
        return
    end
    playerGUID = UnitGUID("player")
end

local nameplates = {}
function f:NAME_PLATE_UNIT_ADDED(unit)
    if (IsForever) then return end
    local guid = UnitGUID(unit)
    nameplates[unit] = guid
    nameplates[guid] = unit 
end
function f:NAME_PLATE_UNIT_REMOVED(unit)
    local guid = nameplates[unit]
    nameplates[unit] = nil
    nameplates[guid] = nil
end
function CFCT:GetNamePlateUnitByGUID(guid)
    return nameplates[guid]
end

local unitHealthMax = {}
function f:UNIT_MAXHEALTH(unit)
    if (unit == 'player') then
        unitHealthMax[unit] = UnitHealthMax(unit)
    end
end
function CFCT:UnitHealthMax(unit)
    return unitHealthMax[unit] or UnitHealthMax(unit)
end








local CLEU_SWING_EVENT = {
    SWING_DAMAGE = true,
    SWING_HEAL = true,
    SWING_LEECH = true,
    SWING_MISSED = true
}
local CLEU_SPELL_EVENT = {
    DAMAGE_SHIELD = true,
    DAMAGE_SPLIT = true,
    RANGE_DAMAGE = true,
    SPELL_DAMAGE = true,
    SPELL_BUILDING_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true,
    RANGE_MISSED = true,
    SPELL_MISSED = true,
    SPELL_PERIODIC_MISSED = true,
    SPELL_BUILDING_MISSED = true
}
local CLEU_MISS_EVENT = {
    SWING_MISSED = true,
    RANGE_MISSED = true,
    SPELL_MISSED = true,
    SPELL_PERIODIC_MISSED = true,
    SPELL_BUILDING_MISSED = true,
}
local CLEU_DAMAGE_EVENT = {
    SWING_DAMAGE = true,
    DAMAGE_SHIELD = true,
    DAMAGE_SPLIT = true,
    RANGE_DAMAGE = true,
    SPELL_DAMAGE = true,
    SPELL_BUILDING_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true
}
local CLEU_HEALING_EVENT = {
    SWING_HEAL = true,
    RANGE_HEAL = true,
    SPELL_HEAL = true,
    SPELL_BUILDING_HEAL = true,
    SPELL_PERIODIC_HEAL = true,
}


-- local MISS_EVENT_STRINGS = {
--     ["ABSORB"] = "Absorbed",
--     ["BLOCK"] = "Blocked",
--     ["DEFLECT"] = "Deflected",
--     ["DODGE"] = "Dodged",
--     ["EVADE"] = "Evaded",
--     ["IMMUNE"] = "Immune",
--     ["MISS"] = "Missed",
--     ["PARRY"] = "Parried",
--     ["REFLECT"] = "Reflected",
--     ["RESIST"] = "Resisted",
-- }

function f:COMBAT_LOG_EVENT_UNFILTERED()
    if CFCT.enabled == false then return end
    local timestamp, cleuEvent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, arg12, arg13, arg14, arg15, arg16, arg17, arg18, arg19, arg20, arg21, arg22, arg23, arg24, arg25 = CombatLogGetCurrentEventInfo()
    local playerEvent, petEvent = (playerGUID == sourceGUID), false
    if not playerEvent then petEvent = (bitband(sourceFlags, COMBATLOG_OBJECT_TYPE_GUARDIAN) > 0 or bitband(sourceFlags, COMBATLOG_OBJECT_TYPE_PET) > 0) and (bitband(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0) end
    if not (playerEvent or petEvent) then return end
    if (destGUID == playerGUID) then return end
    -- local unit = nameplates[destGUID]
    local guid = destGUID
    if CLEU_DAMAGE_EVENT[cleuEvent] then
        if CLEU_SWING_EVENT[cleuEvent] then
            local amount,overkill,school,resist,block,absorb,crit,glancing,crushing,offhand = arg12,arg13,arg14,arg15,arg16,arg17,arg18,arg19,arg20,arg21
            self:DamageEvent(guid, nil, amount, nil, crit, petEvent, school)
        else --its a SPELL event
            local periodic = cleuEvent:find("SPELL_PERIODIC", 1, true)
            local spellid,spellname,school1,amount,overkill,school2,resist,block,absorb,crit,glancing,crushing,offhand = arg12,arg13,arg14,arg15,arg16,arg17,arg18,arg19,arg20,arg21,arg22,arg23,arg24
            if (spellid == 0 and IsClassic) then spellid = spellname end
            self:DamageEvent(guid, spellid, amount, periodic, crit, petEvent, school1)
        end
    elseif CLEU_MISS_EVENT[cleuEvent] then
        if CLEU_SWING_EVENT[cleuEvent] then
            local misstype,_,amount = arg12,arg13,arg14
            self:MissEvent(guid, nil, amount, nil, misstype, petEvent, SCHOOL_MASK_PHYSICAL)
        else --its a SPELL event
            local periodic = cleuEvent:find("SPELL_PERIODIC", 1, true)
            local spellid,spellname,school1,misstype,_,amount = arg12,arg13,arg14,arg15,arg16,arg17
            if (spellid == 0 and IsClassic) then spellid = spellname end
            self:MissEvent(guid, spellid, amount, periodic, misstype, petEvent, school1)
        end
    elseif CLEU_HEALING_EVENT[cleuEvent] then
        if CLEU_SWING_EVENT[cleuEvent] then
            local amount,overheal,absorb,crit = arg12,arg13,arg14,arg15
            self:HealingEvent(guid, nil, amount, nil, crit, petEvent, nil)
        else --its a SPELL event
            local periodic = cleuEvent:find("SPELL_PERIODIC", 1, true)
            local spellid,spellname,school1,amount,overheal,absorb,crit = arg12,arg13,arg14,arg15,arg16,arg17,arg18
            if (spellid == 0 and IsClassic) then spellid = spellname end
            self:HealingEvent(guid, spellid, amount, periodic, crit, petEvent, school1)
        end
    end
end




function f:DamageEvent(guid, spellid, amount, periodic, crit, pet, school, dot)
    spellid = spellid or 6603 -- 6603 = Auto Attack
    local event = ((spellid == 75) or (spellid == 6603)) and "auto" or "spell" -- 75 = autoshot
    local spellicon = spellid and SpellIconText(spellid) or ""
    CacheEvent(guid, event, amount, nil, spellid, spellicon, periodic, crit, false, pet, school)
end
function f:MissEvent(guid, spellid, amount, periodic, misstype, pet, school)
    spellid = spellid or 6603 -- 6603 = Auto Attack
    local event = ((spellid == 75) or (spellid == 6603)) and "auto" or "spell" -- 75 = autoshot
    local spellicon = spellid and SpellIconText(spellid) or ""
    CacheEvent(guid, event, 0, strlower(misstype):gsub("^%l", strupper), spellid or 6603, spellicon, periodic, false, true, pet, school)
end
function f:HealingEvent(guid, spellid, amount, periodic, crit, pet, school)
    local event = "heal"
    local spellicon = spellid and SpellIconText(spellid) or ""
    CacheEvent(guid, event, amount, nil, spellid, spellicon, periodic, crit, false, pet, school)
end


-- ----------------------------------------------------------------------
-- Slash commands
-- ----------------------------------------------------------------------
SLASH_CLASSICFCT1 = "/classicfct"
SLASH_CLASSICFCT2 = "/cfct"

local function ReportCapabilities()
    -- Every value this client returns, not just the ones that are documented:
    -- it hands out more than four, and which one is the interface number is
    -- exactly what has to be confirmed on a client nobody can test for.
    local build = { GetBuildInfo() }
    local reported = {}
    for i = 1, #build do
        reported[i] = tostring(build[i])
    end
    local lines = {
        "ClassicFCT - client capabilities",
        "  GetBuildInfo   : "..table.concat(reported, " | "),
        "  interface      : "..tostring(ForeverInterface),
        "  flavor mode    : "..(IsForever and "WoW: Forever (C_CombatText)" or "combat log (COMBAT_LOG_EVENT_UNFILTERED)"),
        "  C_CombatText   : "..tostring(type(C_CombatText)),
        "  issecretvalue  : "..tostring(type(issecretvalue)),
        "  CLEU reader    : "..tostring(type(CombatLogGetCurrentEventInfo)),
        "  watched unit   : "..tostring(foreverUnit),
    }
    if (IsForever) then
        -- This event is only sent while the client's own floating combat text
        -- is enabled, so that setting has to stay on for anything to show up.
        local ok, enabled = pcall(function() return C_CVar.GetCVarBool("enableFloatingCombatText") end)
        if (ok) then
            table.insert(lines, "  blizz fct cvar  : "..(enabled and "on (required)" or "OFF - nothing will show"))
        end
        -- Lets a player confirm how this build behaves on their client without
        -- having to read any code: if the last line says plain, amounts can be
        -- turned into strings and everything is displayed by this addon; if it
        -- says secret, amounts are handed to the FontString instead.
        local sample = CFCT:FormatAmount(1234567)
        if (sample) then
            table.insert(lines, "  sample amount  : "..tostring(sample).." (plain string)")
        else
            table.insert(lines, "  sample amount  : could not be formatted (secret), using SetFormattedText")
        end
    end
    return table.concat(lines, "\n")
end

SlashCmdList["CLASSICFCT"] = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.*)$")
    cmd = strlower(cmd or "")
    if (cmd == "diag" or cmd == "") then
        CFCT:Log(ReportCapabilities())
    elseif (cmd == "reload") then
        CFCT:Log("Reloading ClassicFCT...")
        C_Timer.After(1, function() ReloadUI() end)
    else
        CFCT:Log("Commands: /cfct diag, /cfct reload")
    end
end
























