-- TauntMasterMini - Modernized version
-- Author: Anonymous - 2025-2026
-- Updated for WoW Midnight Pre-Expansion Patch 12.0.0 (Build 65512) - January 2026
-- v7.1.0 - May 2026
-- A threat management addon for tanks. For Scouse.

local addonName = ...

-- Slash command identifiers
SLASH_TAUNTMASTERMINI1 = '/TauntMasterMini'
SLASH_TAUNTMASTERMINI2 = '/tm'

local DEBUG = false

local function DebugPrint(...)
    if DEBUG then
        print('|cFFFF00FFTauntMasterMini Debug:|r', ...)
    end
end

-- Globals used by XML / other files
TMMButtons = TMMButtons or {}

-- Test/config mode: number of dummy bars to show solo (0 = off).
-- Session-only by design (resets on /reload); never written to SavedVariables.
local TMM_TestCount = 0
-- Cosmetic-only palette for test bars. NOT derived from any combat API,
-- so this introduces no secret-value / taint exposure (protocol §0a).
local TMM_TEST_COLORS = {
    { 0, 0.8, 0 },      -- green
    { 1, 1, 0 },        -- yellow
    { 1, 0, 0 },        -- red
    { 0, 0.6, 1 },      -- blue
    { 1, 0.5, 0 },      -- orange
}
-- Pools for randomising test-mode bars (cosmetic only; no combat API).
local TMM_TEST_CLASSES = {
    'WARRIOR', 'PALADIN', 'HUNTER', 'ROGUE', 'PRIEST', 'DEATHKNIGHT',
    'SHAMAN', 'MAGE', 'WARLOCK', 'MONK', 'DRUID', 'DEMONHUNTER', 'EVOKER',
}
local TMM_TEST_ROLES = { 'TANK', 'HEALER', 'DAMAGER' }
-- Known interrupt abilities across all classes/specs, for filtering the
-- Interrupt Spell picker. Name-keyed (matches how spells are stored).
local TMM_INTERRUPTS = {
    ['Pummel'] = true, ['Mind Freeze'] = true, ['Skull Bash'] = true,
    ['Kick'] = true, ['Rebuke'] = true, ['Counterspell'] = true,
    ['Spell Lock'] = true, ['Wind Shear'] = true, ['Disrupt'] = true,
    ["Avenger's Shield"] = true, ['Silence'] = true, ['Solar Beam'] = true,
    ['Muzzle'] = true, ['Quell'] = true, ['Spear Hand Strike'] = true,
    ['Counter Shot'] = true,
}

-- Find the button assigned to a given unit token (e.g. "party1", "raid3")
local function TMM_FindButtonForUnit(unit)
    for _, btn in ipairs(TMMButtons) do
        if btn:IsShown() and btn:GetAttribute('unit') == unit then
            return btn
        end
    end
    return nil
end

-- Saved variable defaults
local DEFAULTS = {
    width = 75,
    height = 30,
    unitsPerColumn = 10,
    maxColumns = 4,
    minimap = { hide = false },
    leftClickSpell = '',
    rightClickSpell = '',
    skullSize = 20,
    hideWhenSolo = false,
    hideDpsInRaid = false,
    useClassColours = false,
    showNames = true,
    showSelf = true,
    pullAlertEnabled = true,
    pullAlertSound = true,
    pullAlertPartyChat = true,
    firstPullNotification = true,
    scale = 1.0,
    opacity = 1.0,
    sortMode = 'group',
    compactMode = false,
    castFlash = true,
    tauntCDIndicator = true,
    interruptSpell = '',
    showInterruptBtn = true,
    interruptSize = 20,
    showMarkerBar = true,  -- replaces the removed top skull button
    showTauntButtons = false,
    soloShowTarget = false,
}

-- Forward declarations
local TMM_CreateOrInitUI
local TMM_RebuildRoster
local TMM_SetLocked
local TMM_UpdateLockState
local TMM_ConfigureClickAction
local TMM_IsPlayer
local TMM_GetAvailableSpells  -- defined later; forward-declared so the
                              -- class kit in TMM_EnsureDefaults can
                              -- validate defaults against known spells.
function TauntMasterMini_ConfigureSpells() end


local function TMM_GetTauntSpell()
    local class = select(2, UnitClass('player'))
    local map = {
        WARRIOR = 'Taunt',
        PALADIN = 'Hand of Reckoning',
        DEATHKNIGHT = 'Dark Command',
        DRUID = 'Growl',
        MONK = 'Provoke',
        DEMONHUNTER = 'Torment',
    }
    return map[class]
end

-- Smart per-class starter kit used by TMM_EnsureDefaults (fresh character
-- AND after "Reset Defaults"). left = taunt (always), right = a useful
-- class spell, interrupt = the class interrupt. Only applied when the
-- value is empty/nil, so it never overwrites a user's saved choice on a
-- normal login — only a brand-new char or an actual Reset gets these.
-- Spell *names* only (resolved by the secure /cast macro); these are not
-- Midnight "secret values", so no §0a concern.
-- utility/interrupt are PRIORITY LISTS: TMM_EnsureDefaults picks the
-- first entry the character actually knows (validated against the
-- spellbook scan). This avoids defaulting to a talent the char may not
-- have taken (e.g. Druid "Mighty Bash"), which previously fell back to
-- the taunt and made right-click duplicate left-click.
local TMM_CLASS_KIT = {
    WARRIOR     = { taunt = 'Taunt',             utility = { 'Shield Slam', 'Revenge', 'Thunder Clap', 'Heroic Throw' },              interrupt = { 'Pummel' } },
    PALADIN     = { taunt = 'Hand of Reckoning', utility = { "Avenger's Shield", 'Judgment', 'Hammer of the Righteous', 'Blessed Hammer' }, interrupt = { 'Rebuke' } },
    DEATHKNIGHT = { taunt = 'Dark Command',      utility = { 'Death Strike', 'Heart Strike', 'Marrowrend', 'Death Grip' },             interrupt = { 'Mind Freeze' } },
    DRUID       = { taunt = 'Growl',             utility = { 'Mangle', 'Thrash', 'Swipe', 'Maul' },                                    interrupt = { 'Skull Bash' } },
    MONK        = { taunt = 'Provoke',           utility = { 'Keg Smash', 'Blackout Kick', 'Rising Sun Kick', 'Tiger Palm' },          interrupt = { 'Spear Hand Strike' } },
    DEMONHUNTER = { taunt = 'Torment',           utility = { 'Fracture', 'Shear', 'Throw Glaive', 'Immolation Aura' },                 interrupt = { 'Disrupt' } },
}

local function TMM_GetClassKit()
    return TMM_CLASS_KIT[select(2, UnitClass('player'))]
end

-- Tank-spec detection + notice. Returns true (tank), false (not tank),
-- or nil (spec not known yet — e.g. very early login; caller must NOT
-- treat nil as "not tank"). Spec/role are NOT Midnight secret values,
-- so no §0a concern; not combat-protected, safe any time.
local function TMM_IsTankSpec()
    if not GetSpecialization then return nil end
    local idx = GetSpecialization()
    if not idx then return nil end
    local role = GetSpecializationRole and GetSpecializationRole(idx)
    if not role then return nil end
    return role == 'TANK'
end

-- Tracks the last *notified* state so the chat line prints only on a
-- real transition (login into non-tank, or tank -> non-tank), never
-- every event. nil = nothing notified yet this session.
local TMM_tankNoticeState = nil

local function TMM_UpdateTankSpecNotice()
    local isTank = TMM_IsTankSpec()
    if isTank == nil then return end  -- spec unknown yet; try again later
    if isTank ~= TMM_tankNoticeState then
        if not isTank then
            print('|cFF00FFFFTauntMasterMini:|r |cFFFFFF00You are not in a '
                .. 'tanking spec — taunt/threat features are limited until '
                .. 'you switch to your tank spec.|r')
        end
        TMM_tankNoticeState = isTank
    end
    -- Options > Spells banner mirrors the live state whenever the panel
    -- exists (guarded; created later in TMM_CreateOrInitUI).
    if TMMOptionsMenu and TMMOptionsMenu._tankBanner then
        if isTank then
            TMMOptionsMenu._tankBanner:Hide()
        else
            TMMOptionsMenu._tankBanner:Show()
        end
    end
end

local function TMM_EnsureDefaults()
    -- Account-wide DB holds minimap settings only; everything else is per-char.
    TauntMasterMiniDB = TauntMasterMiniDB or {}
    TauntMasterMiniDB.minimap = TauntMasterMiniDB.minimap or { hide = false }

    -- Per-character settings: migrate from account-wide DB (pre-6.7.0) or
    -- apply DEFAULTS for brand-new characters.
    TauntMasterMiniDBChar = TauntMasterMiniDBChar or {}

    -- Class-specific spell choices must NEVER be migrated from the shared
    -- account-wide DB. Doing so cross-contaminates classes (a Death
    -- Knight's Dark Command/Death Grip leaking onto a Demon Hunter) and
    -- survives "Reset Defaults", because Reset only nils the per-char DB
    -- while the stale account-wide copy re-injects on the next
    -- EnsureDefaults. These keys are per-character only; the class kit
    -- below is the sole source of their defaults.
    local PERCHAR_ONLY = {
        leftClickSpell = true, rightClickSpell = true, interruptSpell = true,
    }
    -- One-time scrub of legacy account-wide copies so they can never leak
    -- onto another character again. Idempotent; the current code only ever
    -- writes these per-character (TMM_Set), so nothing legitimate is lost.
    for k in pairs(PERCHAR_ONLY) do TauntMasterMiniDB[k] = nil end

    for key, value in pairs(DEFAULTS) do
        -- minimap stays account-wide. PERCHAR_ONLY class-spell keys are
        -- deliberately left ABSENT (nil) here, never forced to '': the
        -- class kit below is their only default source, applied solely
        -- when the key is nil. That makes an explicit "(None - Clear)"
        -- (which writes '') survive EnsureDefaults instead of being
        -- re-filled by the kit on the next rebuild.
        if key ~= 'minimap' and not PERCHAR_ONLY[key] then
            if TauntMasterMiniDBChar[key] == nil then
                -- Try migrating from old account-wide value first.
                if TauntMasterMiniDB[key] ~= nil then
                    if type(TauntMasterMiniDB[key]) == 'table' then
                        TauntMasterMiniDBChar[key] = CopyTable and CopyTable(TauntMasterMiniDB[key]) or {}
                    else
                        TauntMasterMiniDBChar[key] = TauntMasterMiniDB[key]
                    end
                else
                    -- No account-wide value; use default
                    if type(value) == 'table' then
                        TauntMasterMiniDBChar[key] = CopyTable and CopyTable(value) or {}
                    else
                        TauntMasterMiniDBChar[key] = value
                    end
                end
            end
        end
    end

    if TauntMasterMiniDBChar.locked == nil then
        TauntMasterMiniDBChar.locked = true
    end
    if TauntMasterMiniDBChar.hideTM == nil then
        TauntMasterMiniDBChar.hideTM = false
    end

    -- Smart class kit: left = taunt, right = useful class spell, interrupt
    -- = class interrupt. Applied ONLY when the key is nil (never set on
    -- this character / just Reset). A value of '' means the user
    -- explicitly chose "(None - Clear)" and MUST be preserved -- so the
    -- nil-vs-'' distinction is load-bearing here; do not loosen it back
    -- to `== ''` or clears will silently re-populate. A real saved spell
    -- (non-nil, non-'') is likewise never overwritten on a normal login.
    -- Only do the (relatively costly) known-spell scan when at least one
    -- slot is actually unset — the common path (everything configured)
    -- skips it entirely.
    local needFill = TauntMasterMiniDBChar.leftClickSpell == nil
                  or TauntMasterMiniDBChar.rightClickSpell == nil
                  or TauntMasterMiniDBChar.interruptSpell == nil
    if needFill then
        local kit = TMM_GetClassKit()
        -- Build the set of spells THIS character+spec actually knows,
        -- from the same source the spell dropdown uses (spellbook +
        -- ACTIVE talents). A kit default is applied only if the
        -- character truly has it — so e.g. a non-Guardian Druid does
        -- not get "Growl", and an untalented "Mighty Bash" is never
        -- written (no more "?" for a spell the char cannot cast).
        -- At cold login this list is empty; the slot simply stays nil
        -- and is filled on the SPELLS_CHANGED rebuild once spell data
        -- is available (see the SPELLS_CHANGED handler). Spec changes
        -- re-run this and self-heal the kit for the new spec.
        local known = {}
        for _, n in ipairs(TMM_GetAvailableSpells() or {}) do
            known[n] = true
        end
        -- pick: accepts a single spell name OR a priority list; returns
        -- the first entry the character actually knows, else nil.
        local function pick(cand)
            if type(cand) == 'table' then
                for _, n in ipairs(cand) do
                    if known[n] then return n end
                end
                return nil
            end
            if cand and known[cand] then return cand end
            return nil
        end
        local taunt = pick(TMM_GetTauntSpell())
        local left  = pick(kit and kit.taunt) or taunt
        -- Right-click intentionally does NOT fall back to the taunt:
        -- duplicating left-click as right-click (the "right = Growl"
        -- report) is worse than leaving it unset so the user can choose.
        local right = pick(kit and kit.utility)
        local intr  = pick(kit and kit.interrupt)
        if left  and TauntMasterMiniDBChar.leftClickSpell  == nil then
            TauntMasterMiniDBChar.leftClickSpell = left
        end
        if right and TauntMasterMiniDBChar.rightClickSpell == nil then
            TauntMasterMiniDBChar.rightClickSpell = right
        end
        if intr  and TauntMasterMiniDBChar.interruptSpell  == nil then
            TauntMasterMiniDBChar.interruptSpell = intr
        end
    end
end

-- Accessor helpers: all settings are per-character via TauntMasterMiniDBChar
local function TMM_Get(key)
    if TauntMasterMiniDBChar then return TauntMasterMiniDBChar[key] end
    return DEFAULTS[key]
end

local function TMM_Set(key, val)
    if TauntMasterMiniDBChar then TauntMasterMiniDBChar[key] = val end
end

-- Apply whole-frame scale + opacity to the header (children inherit both).
-- SetScale/SetAlpha are NOT combat-protected, so this is safe in combat and
-- needs no rebuild deferral. Clamped so the frame can never vanish entirely.
local function TMM_ApplyFrameStyle()
    local hdr = TauntMasterMini_Header
    if not hdr then return end
    local s = tonumber(TMM_Get('scale')) or 1.0
    local a = tonumber(TMM_Get('opacity')) or 1.0
    s = math.max(0.5, math.min(1.5, s))
    a = math.max(0.2, math.min(1.0, a))
    hdr:SetScale(s)
    hdr:SetAlpha(a)
end

-- Reorder the unit-token list in place per the saved sort mode.
-- RebuildRoster only runs out of combat (it early-returns under
-- InCombatLockdown), so UnitName/role here are NOT secret values. The
-- type=='string' guard is a defensive §0a backstop: a secret value can
-- never reach a < comparison even if a future code path calls this in
-- a tainted context.
local TMM_ROLE_RANK = { TANK = 1, HEALER = 2, DAMAGER = 3, NONE = 4 }
local function TMM_SortUnits(units)
    local mode = TMM_Get('sortMode') or 'group'
    if mode == 'group' or #units < 2 then return end
    local dec = {}
    for i, tok in ipairs(units) do dec[i] = { tok = tok, idx = i } end
    if mode == 'name' then
        for _, e in ipairs(dec) do
            local n = UnitName(e.tok)
            e.key = (type(n) == 'string') and n:lower() or '\255'
        end
        table.sort(dec, function(a, b)
            if a.key ~= b.key then return a.key < b.key end
            return a.idx < b.idx
        end)
    else  -- 'tank' or 'role'
        for _, e in ipairs(dec) do
            local r = UnitGroupRolesAssigned(e.tok) or 'NONE'
            if mode == 'tank' then
                e.rank = (r == 'TANK') and 1 or 2
            else
                e.rank = TMM_ROLE_RANK[r] or 4
            end
        end
        table.sort(dec, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.idx < b.idx
        end)
    end
    for i, e in ipairs(dec) do units[i] = e.tok end
end

-- Test-mode sort. Real bars sort by unit token (above), but every test
-- bar uses the 'player' token, so sorting must operate on each bar's
-- randomised test profile {class, role} instead. Same mode rules as
-- TMM_SortUnits so "Sort: Tanks first" / "By role" behave identically.
local function TMM_SortTestProfiles(profiles)
    local mode = TMM_Get('sortMode') or 'group'
    if mode == 'group' or #profiles < 2 then return end
    local dec = {}
    for i, e in ipairs(profiles) do dec[i] = { e = e, idx = i } end
    if mode == 'name' then
        for _, d in ipairs(dec) do
            d.key = (d.e.class or '\255'):lower()
        end
        table.sort(dec, function(a, b)
            if a.key ~= b.key then return a.key < b.key end
            return a.idx < b.idx
        end)
    else  -- 'tank' or 'role'
        for _, d in ipairs(dec) do
            local r = d.e.role or 'NONE'
            if mode == 'tank' then
                d.rank = (r == 'TANK') and 1 or 2
            else
                d.rank = TMM_ROLE_RANK[r] or 4
            end
        end
        table.sort(dec, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.idx < b.idx
        end)
    end
    for i, d in ipairs(dec) do profiles[i] = d.e end
end

local function TMM_GetLeftSpell()
    return TMM_Get('leftClickSpell') or ''
end

local function TMM_GetRightSpell()
    return TMM_Get('rightClickSpell') or ''
end

local function TMM_GetInterruptSpell()
    return TMM_Get('interruptSpell') or ''
end

local function TMM_MinimapSettings()
    TauntMasterMiniDB.minimap = TauntMasterMiniDB.minimap or { hide = false }
    return TauntMasterMiniDB.minimap
end

-- Spell cache: invalidated when spec/talents/spells change
local cachedSpells = nil
local cachedSpellsTime = 0

local function TMM_InvalidateSpellCache()
    cachedSpells = nil
    cachedSpellsTime = 0
end

TMM_GetAvailableSpells = function()
    -- Return cache if fresh (within 2 seconds)
    if cachedSpells and (GetTime() - cachedSpellsTime) < 2 then
        return cachedSpells
    end

    local spells, seen = {}, {}

    -- Helper: resolve spell name from a spellID using modern C_Spell API
    local function getSpellName(spellID)
        if not spellID then return nil end
        if C_Spell and C_Spell.GetSpellName then
            return C_Spell.GetSpellName(spellID)
        end
        return nil
    end

    -- Explicit blocklist: spells that slip through the harmful/helpful
    -- filter but are clearly not combat-relevant.  Checked by LOWERCASE name.
    local SPELL_BLOCKLIST = {
        ['fishing'] = true,
        ['cooking'] = true,
        ['cooking fire'] = true,
        ['survey'] = true,
        ['archaeology'] = true,
        ['skinning'] = true,
        ['mining'] = true,
        ['herb gathering'] = true,
        ['prospecting'] = true,
        ['milling'] = true,
        ['disenchant'] = true,
        ['pick lock'] = true,
        ['liftoff'] = true,
        ['mount'] = true,
        ['summon random favorite mount'] = true,
        ['fishing journal'] = true,
        ['revive battle pets'] = true,
        ['logging'] = true,
        ['overload empowered deposit'] = true,
        ['mechanism bypass'] = true,
        ['raise dead'] = true,
        ['revive pet'] = true,
        ['tame beast'] = true,
        ['beast lore'] = true,
        ['eye of the beast'] = true,
        ['eagle eye'] = true,
        ['far sight'] = true,
        ['sentry totem'] = true,
        ['water walking'] = true,
        ['path of frost'] = true,
        ['detect undead'] = true,
        ['sense undead'] = true,
    }

    -- Only include spells that can be used on other units.
    -- Must be harmful (taunts, damage) or helpful (blessings, heals) AND
    -- must have range (targets another unit, not self-only).
    local function isCombatTargetSpell(spellNameOrID)
        if not spellNameOrID then return false end
        -- Blocklist check (case-insensitive)
        if type(spellNameOrID) == 'string' and SPELL_BLOCKLIST[spellNameOrID:lower()] then
            return false
        end
        if C_Spell and C_Spell.IsSpellPassive and C_Spell.IsSpellPassive(spellNameOrID) then
            return false
        end
        local isHarmful = C_Spell and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(spellNameOrID)
        local isHelpful = C_Spell and C_Spell.IsSpellHelpful and C_Spell.IsSpellHelpful(spellNameOrID)
        -- Harmful spells (taunts, damage, debuffs) are always combat-relevant
        if isHarmful then return true end
        -- For helpful or dual-purpose spells, require range to filter out
        -- self-only buffs like Divine Steed while keeping Blessings etc.
        local hasRange = false
        if SpellHasRange and SpellHasRange(spellNameOrID) then
            hasRange = true
        elseif C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(spellNameOrID)
            if info and info.maxRange and info.maxRange > 0 then
                hasRange = true
            end
        end
        if isHelpful and hasRange then return true end
        -- Fallback: some spells (e.g. Death Coil) may not be flagged as
        -- harmful or helpful by the API but are still valid combat spells.
        -- Include them if they have range.
        if not isHarmful and not isHelpful and hasRange then return true end
        return false
    end

    local function addSpell(name)
        if not name or name == '' or seen[name] then return end
        if not isCombatTargetSpell(name) then return end
        seen[name] = true
        table.insert(spells, name)
    end

    ---------------------------------------------------------------------------
    -- METHOD 1: Scan the spellbook via SkillLine tabs (wiki-verified API)
    --   C_SpellBook.GetNumSpellBookSkillLines() -> number of tabs
    --   C_SpellBook.GetSpellBookSkillLineInfo(i) -> { itemIndexOffset, numSpellBookItems, ... }
    --   C_SpellBook.GetSpellBookItemType(slot, bank) -> itemType, actionID, spellID
    --   C_SpellBook.GetSpellBookItemInfo(slot, bank) -> SpellBookItemInfo table
    ---------------------------------------------------------------------------
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank then
        local numTabs = C_SpellBook.GetNumSpellBookSkillLines() or 0
        for tab = 1, numTabs do
            local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(tab)
            if skillLineInfo and not skillLineInfo.shouldHide and not skillLineInfo.isGuild
               and not skillLineInfo.offSpecID then
                local offset = skillLineInfo.itemIndexOffset or 0
                local numSlots = skillLineInfo.numSpellBookItems or 0
                for slot = offset + 1, offset + numSlots do
                    local itemType, actionID, spellID = C_SpellBook.GetSpellBookItemType(slot, Enum.SpellBookSpellBank.Player)
                    if itemType == Enum.SpellBookItemType.Spell then
                        -- Regular spell: check if active spec and not passive
                        local info = C_SpellBook.GetSpellBookItemInfo(slot, Enum.SpellBookSpellBank.Player)
                        if info and not info.isPassive and not info.isOffSpec then
                            local spellName = info.name
                            if not spellName and (info.spellID or actionID) then
                                spellName = getSpellName(info.spellID or actionID)
                            end
                            if spellName then
                                addSpell(spellName)
                            end
                        end
                    elseif itemType == Enum.SpellBookItemType.Flyout then
                        -- Flyouts: grouped spells (Blessings, Portals, etc.)
                        -- actionID IS the flyoutID per wiki:
                        --   "Represents a base spellID for spells, flyoutID for flyouts"
                        local flyoutID = actionID
                        if flyoutID and GetFlyoutInfo then
                            local flyoutName, flyoutDesc, numFlyoutSlots, isKnownFlyout = GetFlyoutInfo(flyoutID)
                            if numFlyoutSlots and numFlyoutSlots > 0 and GetFlyoutSlotInfo then
                                for j = 1, numFlyoutSlots do
                                    -- GetFlyoutSlotInfo returns:
                                    --   flyoutSpellID, overrideSpellID, isKnown, spellName, slotSpecID
                                    local flyoutSpellID, overrideSpellID, isKnown, slotSpellName, slotSpecID = GetFlyoutSlotInfo(flyoutID, j)
                                    if flyoutSpellID then
                                        local playerKnows = isKnown
                                        -- Fallback: check IsPlayerSpell (deprecated but still present in 12.0)
                                        if not playerKnows and IsPlayerSpell then
                                            playerKnows = IsPlayerSpell(flyoutSpellID)
                                        end
                                        if playerKnows then
                                            -- Use spellName returned directly by GetFlyoutSlotInfo
                                            local spellName = slotSpellName
                                            if not spellName or spellName == '' then
                                                spellName = getSpellName(overrideSpellID or flyoutSpellID)
                                            end
                                            if spellName then
                                                addSpell(spellName)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

    end

    ---------------------------------------------------------------------------
    -- METHOD 2: Scan active talent tree for talent-granted spells
    --   C_ClassTalents.GetActiveConfigID() -> configID
    --   C_Traits.GetConfigInfo(configID) -> { treeIDs = {...} }
    --   C_Traits.GetTreeNodes(treeID) -> nodeIDs[]
    --   C_Traits.GetNodeInfo(configID, nodeID) -> { activeEntry, activeRank, ... }
    --   C_Traits.GetEntryInfo(configID, entryID) -> { definitionID }
    --   C_Traits.GetDefinitionInfo(definitionID) -> { spellID }
    ---------------------------------------------------------------------------
    if C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits then
        local configID = C_ClassTalents.GetActiveConfigID()
        if configID then
            local configInfo = C_Traits.GetConfigInfo(configID)
            if configInfo and configInfo.treeIDs then
                for _, treeID in ipairs(configInfo.treeIDs) do
                    local nodes = C_Traits.GetTreeNodes(treeID)
                    if nodes then
                        for _, nodeID in ipairs(nodes) do
                            local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                            -- Only process nodes that have active ranks (i.e. actually selected)
                            if nodeInfo and nodeInfo.activeRank and nodeInfo.activeRank > 0
                               and nodeInfo.activeEntry and nodeInfo.activeEntry.entryID then
                                local entryInfo = C_Traits.GetEntryInfo(configID, nodeInfo.activeEntry.entryID)
                                if entryInfo and entryInfo.definitionID then
                                    local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                                    if defInfo and defInfo.spellID then
                                        -- Filter out passives
                                        local isPassive = false
                                        if C_Spell and C_Spell.IsSpellPassive then
                                            isPassive = C_Spell.IsSpellPassive(defInfo.spellID)
                                        end
                                        if not isPassive then
                                            local spellName = getSpellName(defInfo.spellID)
                                            if spellName then
                                                addSpell(spellName)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    ---------------------------------------------------------------------------
    -- METHOD 3: Scan action bars as supplementary source
    ---------------------------------------------------------------------------
    for slot = 1, 120 do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and id then
            local spellName = getSpellName(id)
            if spellName then
                addSpell(spellName)
            end
        end
    end

    ---------------------------------------------------------------------------
    -- METHOD 4: Always include the class default taunt as a fallback
    ---------------------------------------------------------------------------
    local tauntSpell = TMM_GetTauntSpell()
    if tauntSpell then
        addSpell(tauntSpell)
    end

    ---------------------------------------------------------------------------
    -- METHOD 5: Always include the class interrupt(s) as a fallback, so the
    -- Left/Right Click pickers can offer the interrupt even when it is not on
    -- an action bar yet (same rationale as the taunt fallback above). Pulled
    -- from TMM_CLASS_KIT so it is correct per class. Spell names only -- no
    -- §0a secret-value concern. addSpell() de-dupes if already known.
    ---------------------------------------------------------------------------
    local classKit = TMM_GetClassKit()
    if classKit and classKit.interrupt then
        for _, intName in ipairs(classKit.interrupt) do
            addSpell(intName)
        end
    end

    table.sort(spells)
    cachedSpells = spells
    cachedSpellsTime = GetTime()
    return spells
end

local function TMM_ShowSpellPicker(owner)
    if not owner then return end
    if InCombatLockdown and InCombatLockdown() then
        print('TauntMasterMini: Cannot change spells during combat.')
        return
    end

    -- Force fresh scan each time the picker is opened
    TMM_InvalidateSpellCache()
    local spells = TMM_GetAvailableSpells()

    if #spells == 0 then
        print('TauntMasterMini: No spells found. Spellbook may not be fully loaded yet - try again in a moment.')
        return
    end

    -- Optional per-dropdown filter (e.g. the Interrupt Spell picker only
    -- lists known interrupt abilities).
    if owner._spellFilter then
        local filtered = {}
        for _, s in ipairs(spells) do
            if owner._spellFilter(s) then filtered[#filtered + 1] = s end
        end
        spells = filtered
    end

    -- Use modern dropdown API
    MenuUtil.CreateContextMenu(UIParent, function(ownerRegion, rootDescription)
        rootDescription:SetScrollMode(GetScreenHeight() * 0.6)
        rootDescription:CreateTitle(string.format('Available Spells (%d)', #spells))

        -- Option to clear the selection
        rootDescription:CreateButton('|cFF888888(None - Clear)|r', function()
            if owner.setterFunction then
                owner.setterFunction('')
                if owner.refreshText then
                    owner:refreshText()
                end
            end
        end)

        rootDescription:CreateDivider()

        for _, spellName in ipairs(spells) do
            rootDescription:CreateButton(spellName, function()
                if owner.setterFunction then
                    owner.setterFunction(spellName)
                    if owner.refreshText then
                        owner:refreshText()
                    end
                end
            end)
        end
    end)
end

-- Minimap button
local icon
local LDB = LibStub('LibDataBroker-1.1'):NewDataObject('TauntMasterMini', {
    type = 'data source',
    text = 'TauntMasterMini',
    icon = 'Interface\\AddOns\\TauntMasterMini\\TMM',
    OnClick = function(_, button)
        if button == 'LeftButton' then
            if TMMOptionsMenu and TMMOptionsMenu:IsShown() then
                TMMOptionsMenu:Hide()
            elseif TMMOptionsMenu then
                TMMOptionsMenu:Show()
            end
        elseif button == 'RightButton' then
            SlashCmdList['TAUNTMASTERMINI']('toggle')
        end
    end,
    OnTooltipShow = function(tt)
        tt:AddLine('TauntMasterMini')
        tt:AddLine(' ')
        tt:AddLine('|cFF00FF00Left Click:|r Options', 1, 1, 1)
        tt:AddLine('|cFF00FF00Right Click:|r Toggle Frame', 1, 1, 1)
    end,
})

icon = LibStub('LibDBIcon-1.0')

local function TMMMinimapBtn_Hide()
    if icon then icon:Hide('TauntMasterMini') end
end

local function TMMMinimapBtn_Show()
    if icon then icon:Show('TauntMasterMini') end
end

local function TMM_SetHeaderShown(show)
    if not TauntMasterMini_Header then return end
    if InCombatLockdown() then
        TauntMasterMini_Header._tmmPendingShowState = show and 1 or 0
        print('TauntMasterMini: Action queued until out of combat.')
        return
    end
    if show then
        TauntMasterMini_Header:Show()
    else
        TauntMasterMini_Header:Hide()
    end
end

function TMM_SetLocked(locked)
    TMM_EnsureDefaults()
    TauntMasterMiniDBChar.locked = not not locked
    TMM_UpdateLockState()
    if TMMOptionsMenu and TMMOptionsMenu._lockCheck then
        TMMOptionsMenu._lockCheck:SetChecked(locked)
    end
    print(locked and 'TauntMasterMini: Frame locked.' or 'TauntMasterMini: Frame unlocked.')
end

local DRAG_HANDLE_HEIGHT = 18

local function TMM_SetHeaderDragEnabled(enabled)
    if not TauntMasterMini_Header then return end
    TauntMasterMini_Header:SetMovable(enabled)
    -- Note: we do NOT disable EnableMouse on the header; the drag handle does the moving
end

local function TMM_SaveHeaderPosition()
    if not TauntMasterMini_Header then return end
    local point, _, relPoint, x, y = TauntMasterMini_Header:GetPoint()
    if point then
        TauntMasterMiniDBChar.framePos = { point = point, relPoint = relPoint, x = x, y = y }
    end
end

local function TMM_RestoreHeaderPosition()
    if not TauntMasterMini_Header then return end
    local pos = TauntMasterMiniDBChar and TauntMasterMiniDBChar.framePos
    if pos and pos.point then
        TauntMasterMini_Header:ClearAllPoints()
        TauntMasterMini_Header:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    end
end

-- True only while the player is in Blizzard Edit Mode. Session-only; never
-- written to SavedVariables so the user's real lock choice is preserved.
local TMM_editModeActive = false

TMM_UpdateLockState = function()
    local locked = TauntMasterMiniDBChar and TauntMasterMiniDBChar.locked
    if TMM_editModeActive then locked = false end  -- movable while in Edit Mode
    TMM_SetHeaderDragEnabled(not locked)

    if TauntMasterMini_Header then
        -- Bright green border when UNLOCKED to indicate movable, default when locked
        if not locked then
            TauntMasterMini_Header:SetBackdropBorderColor(0, 1, 0, 1)
        elseif TauntMasterMini_Header._tmmDefaultBorderColor then
            TauntMasterMini_Header:SetBackdropBorderColor(unpack(TauntMasterMini_Header._tmmDefaultBorderColor))
        end

        -- Show/hide the drag handle
        local handle = TauntMasterMini_Header._dragHandle
        if handle then
            if locked then
                handle:Hide()
            else
                handle:Show()
            end
        end
    end

    -- Re-layout buttons to account for drag handle visibility
    if not InCombatLockdown() and TauntMasterMini_Header and TauntMasterMini_Header:IsShown() then
        TMM_RebuildRoster()
    end
end

-- Blizzard Edit Mode integration (no library). Entering Edit Mode makes the
-- frame movable like Blizzard's own frames; exiting restores the saved lock
-- state and saves the (possibly moved) position. Guarded so older clients or
-- a future API rename simply no-op instead of erroring.
if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback('EditMode.Enter', function()
        TMM_editModeActive = true
        TMM_UpdateLockState()
    end)
    EventRegistry:RegisterCallback('EditMode.Exit', function()
        TMM_editModeActive = false
        TMM_SaveHeaderPosition()
        TMM_UpdateLockState()
    end)
end

SlashCmdList['TAUNTMASTERMINI'] = function(msg)
    TMM_EnsureDefaults()
    msg = string.lower(msg or '')
    if msg == 'show' then
        TMM_SetHeaderShown(true)
    elseif msg == 'hide' then
        TMM_SetHeaderShown(false)
    elseif msg == 'toggle' then
        local show = not (TauntMasterMini_Header and TauntMasterMini_Header:IsShown())
        TMM_SetHeaderShown(show)
    elseif msg == 'lock' then
        TMM_SetLocked(true)
    elseif msg == 'unlock' then
        TMM_SetLocked(false)
    elseif msg == 'debug' then
        if TMM_DebugDump then TMM_DebugDump() end
    elseif msg == 'range' then
        print('|cFF00FFFFTauntMasterMini Range Diagnostic|r')
        print('  C_Spell.IsSpellInRange present:',
              (C_Spell and C_Spell.IsSpellInRange) and 'YES' or '|cFFFF0000NO|r')
        print('  legacy IsSpellInRange present:',
              IsSpellInRange and 'YES' or '|cFFFF0000NO|r')
        local function probe(label, spell, unit)
            if not spell or spell == '' then
                print('  ' .. label .. ': |cFFFF0000(no spell configured)|r'); return
            end
            if not UnitExists(unit) then
                print('  ' .. label .. ' [' .. spell .. ' -> ' .. unit
                      .. ']: |cFFFFFF00unit does not exist|r'); return
            end
            local raw, rawType, ok = nil, 'nil', pcall(function()
                if C_Spell and C_Spell.IsSpellInRange then
                    raw = C_Spell.IsSpellInRange(spell, unit)
                elseif IsSpellInRange then
                    raw = IsSpellInRange(spell, unit)
                end
                rawType = type(raw)
            end)
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spell)
            print(string.format(
                '  %s [%s -> %s]: result=|cFFFFFF00%s|r type=%s pcall_ok=%s spellID=%s',
                label, spell, unit, tostring(raw), rawType, tostring(ok),
                tostring(info and info.spellID or 'nil')))
        end
        local l = TMM_GetLeftSpell(); if l == '' then l = TMM_GetTauntSpell() end
        local r = TMM_GetRightSpell()
        print('--- vs your TARGET (solo bar case) ---')
        probe('left ', l, 'target')
        probe('right', r, 'target')
        print('--- vs TARGET-OF-TARGET (group bar case) ---')
        probe('left ', l, 'targettarget')
        print('--- UnitInRange (DISARMED: returns SECRET booleans here) ---')
        for _, u in ipairs({ 'player', 'party1', 'party2', 'party3', 'party4' }) do
            if UnitExists(u) then
                -- tostring() on a secret boolean can itself error, so
                -- pcall it and only report whether it was readable.
                local ok, s = pcall(function()
                    local inR = UnitInRange(u)
                    return tostring(inR)
                end)
                print(string.format('  %s (%s): %s',
                    u, UnitName(u) or '?',
                    ok and ('readable=' .. s)
                       or '|cFFFF0000SECRET / not readable by addons|r'))
            end
        end
        print('|cFF888888Range is opaque/secret under Midnight '
              .. 'addon-disarmament — the indicator is not achievable.|r')
    elseif msg == 'spells' then
        print('|cFF00FFFFTauntMasterMini Spell Diagnostic|r')
        print('--- API Checks ---')
        print('  C_SpellBook:', C_SpellBook and 'YES' or 'NO')
        print('  C_SpellBook.GetNumSpellBookSkillLines:', C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and 'YES' or '|cFFFF0000NO|r')
        print('  C_SpellBook.GetSpellBookSkillLineInfo:', C_SpellBook and C_SpellBook.GetSpellBookSkillLineInfo and 'YES' or '|cFFFF0000NO|r')
        print('  C_SpellBook.GetSpellBookItemType:', C_SpellBook and C_SpellBook.GetSpellBookItemType and 'YES' or '|cFFFF0000NO|r')
        print('  C_SpellBook.GetSpellBookItemInfo:', C_SpellBook and C_SpellBook.GetSpellBookItemInfo and 'YES' or '|cFFFF0000NO|r')
        print('  C_Spell.GetSpellName:', C_Spell and C_Spell.GetSpellName and 'YES' or '|cFFFF0000NO|r')
        print('  C_Spell.IsSpellPassive:', C_Spell and C_Spell.IsSpellPassive and 'YES' or '|cFFFF0000NO|r')
        print('  GetFlyoutInfo:', GetFlyoutInfo and 'YES' or '|cFFFF0000NO|r')
        print('  GetFlyoutSlotInfo:', GetFlyoutSlotInfo and 'YES' or '|cFFFF0000NO|r')
        print('  IsPlayerSpell:', IsPlayerSpell and 'YES (deprecated)' or 'NO')
        print('  C_ClassTalents:', C_ClassTalents and C_ClassTalents.GetActiveConfigID and 'YES' or '|cFFFF0000NO|r')
        print('  C_Traits:', C_Traits and 'YES' or '|cFFFF0000NO|r')
        print('  GetSpecialization:', GetSpecialization and tostring(GetSpecialization()) or 'NO')

        -- Show spellbook tabs
        print('--- Spellbook Tabs ---')
        if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
            local numTabs = C_SpellBook.GetNumSpellBookSkillLines() or 0
            print('  Tab count:', numTabs)
            for tab = 1, numTabs do
                local info = C_SpellBook.GetSpellBookSkillLineInfo(tab)
                if info then
                    print(string.format('  Tab %d: "%s" offset=%d count=%d specID=%s offSpecID=%s hide=%s',
                        tab, info.name or '?', info.itemIndexOffset or 0, info.numSpellBookItems or 0,
                        tostring(info.specID), tostring(info.offSpecID), tostring(info.shouldHide)))
                end
            end
        end

        -- Show flyouts found via spellbook scan
        print('--- Flyouts in Spellbook ---')
        if C_SpellBook and C_SpellBook.GetSpellBookItemType and Enum and Enum.SpellBookSpellBank then
            local flyoutCount = 0
            local i = 1
            while true do
                local itemType, actionID = C_SpellBook.GetSpellBookItemType(i, Enum.SpellBookSpellBank.Player)
                if not itemType then break end
                if itemType == Enum.SpellBookItemType.Flyout then
                    flyoutCount = flyoutCount + 1
                    local flyoutID = actionID
                    local flyoutName = '?'
                    local slotCount = 0
                    if flyoutID and GetFlyoutInfo then
                        flyoutName, _, slotCount = GetFlyoutInfo(flyoutID)
                    end
                    print(string.format('  Flyout #%d at slot %d: name="%s" flyoutID=%s slots=%d',
                        flyoutCount, i, tostring(flyoutName), tostring(flyoutID), slotCount or 0))
                    if flyoutID and slotCount and slotCount > 0 and GetFlyoutSlotInfo then
                        for j = 1, slotCount do
                            local flyoutSpellID, overrideSpellID, isKnown, slotSpellName, slotSpecID = GetFlyoutSlotInfo(flyoutID, j)
                            print(string.format('    slot %d: spellID=%s override=%s name="%s" isKnown=%s specID=%s',
                                j, tostring(flyoutSpellID), tostring(overrideSpellID),
                                tostring(slotSpellName), tostring(isKnown), tostring(slotSpecID)))
                        end
                    end
                end
                i = i + 1
            end
            if flyoutCount == 0 then
                print('  (no flyouts found)')
            end
        end

        -- Show talent-sourced spells
        print('--- Talent Spells ---')
        if C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits then
            local configID = C_ClassTalents.GetActiveConfigID()
            print('  Active configID:', tostring(configID))
            if configID then
                local configInfo = C_Traits.GetConfigInfo(configID)
                if configInfo and configInfo.treeIDs then
                    local talentSpellCount = 0
                    local shownCount = 0
                    for _, treeID in ipairs(configInfo.treeIDs) do
                        local nodes = C_Traits.GetTreeNodes(treeID)
                        if nodes then
                            for _, nodeID in ipairs(nodes) do
                                local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                                if nodeInfo and nodeInfo.activeRank and nodeInfo.activeRank > 0
                                   and nodeInfo.activeEntry and nodeInfo.activeEntry.entryID then
                                    local entryInfo = C_Traits.GetEntryInfo(configID, nodeInfo.activeEntry.entryID)
                                    if entryInfo and entryInfo.definitionID then
                                        local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                                        if defInfo and defInfo.spellID then
                                            talentSpellCount = talentSpellCount + 1
                                            if shownCount < 15 then
                                                shownCount = shownCount + 1
                                                local spellName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(defInfo.spellID) or '?'
                                                local isPassive = C_Spell and C_Spell.IsSpellPassive and C_Spell.IsSpellPassive(defInfo.spellID)
                                                print(string.format('  %d. %s (ID:%d) passive=%s rank=%d',
                                                    shownCount, tostring(spellName), defInfo.spellID,
                                                    tostring(isPassive), nodeInfo.activeRank))
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if shownCount < talentSpellCount then
                        print('  ... and ' .. (talentSpellCount - shownCount) .. ' more')
                    end
                    print('  Total talent spells: ' .. talentSpellCount)
                end
            end
        end

        -- Force a fresh scan and show final results
        print('--- Final Spell List ---')
        TMM_InvalidateSpellCache()
        local spells = TMM_GetAvailableSpells()
        print('|cFF00FF00Found ' .. #spells .. ' spells|r from spellbook + flyouts + talents + action bars:')
        for i, spell in ipairs(spells) do
            print('  ' .. i .. '. ' .. spell)
        end
        if #spells == 0 then
            print('  |cFFFF0000(none found - spellbook may not be loaded yet, try /tm spells again)|r')
        end
    elseif msg:match('^test') then
        if InCombatLockdown() then
            print('|cFF00FFFFTauntMasterMini:|r cannot change test mode in combat.')
            return
        end
        local n = tonumber(msg:match('^test%s*(%d+)'))
        if n then
            TMM_TestCount = math.max(0, math.min(40, n))
        else
            -- bare "/tm test" toggles a default of 5 dummy bars
            TMM_TestCount = (TMM_TestCount > 0) and 0 or 5
        end
        if TMM_TestCount > 0 then
            print('|cFF00FFFFTauntMasterMini:|r test mode ON (' .. TMM_TestCount ..
                  ' bars). Tune layout, then |cFFFFFF00/tm test 0|r to exit.')
        else
            print('|cFF00FFFFTauntMasterMini:|r test mode OFF.')
        end
        TMM_RebuildRoster()
    else
        if TMMOptionsMenu then TMMOptionsMenu:Show() end
    end
end

-- Button handlers ----------------------------------------------------------

function TauntMasterMini_Button_OnLoad(self)
    self:RegisterEvent('GROUP_ROSTER_UPDATE')
    self:RegisterEvent('PLAYER_ENTERING_WORLD')
    self:RegisterEvent('UNIT_THREAT_SITUATION_UPDATE')
    self:RegisterEvent('PLAYER_TARGET_CHANGED')
    self:RegisterEvent('UNIT_HEALTH')

    self.healthbar = self.healthbar or _G[self:GetName() .. '_HealthBar']
    self.name = self.name or _G[self:GetName() .. '_Name']
    self.tankicon = self.tankicon or _G[self:GetName() .. '_TM_Tank_Icon']
end

local function TMM_ApplyDefaultsForClass()
    local class = select(2, UnitClass('player'))
    local source
    if class == 'PALADIN' then source = paladinTauntM_defaults
    elseif class == 'WARRIOR' then source = warriorTauntM_defaults
    elseif class == 'DEATHKNIGHT' then source = deathknightTauntM_defaults
    elseif class == 'DRUID' then source = druidTauntM_defaults
    elseif class == 'MONK' then source = monkTauntM_defaults
    elseif class == 'DEMONHUNTER' then source = demonhunterTauntM_defaults
    else source = TauntM_defaults end
    source = source or {}
    -- Apply class defaults to per-character DB
    TauntMasterMiniDBChar = TauntMasterMiniDBChar or {}
    for k, v in pairs(source) do
        if TauntMasterMiniDBChar[k] == nil then
            TauntMasterMiniDBChar[k] = v
        end
    end
end

local function TMM_CopyDefaultsToChar()
    -- Migration is now handled entirely by TMM_EnsureDefaults.
    TMM_EnsureDefaults()
end

function TauntMasterMini_Button_OnEvent(self, event, ...)
    if event == 'PLAYER_ENTERING_WORLD' or event == 'GROUP_ROSTER_UPDATE' then
        -- Let the header's handler do the full rebuild; individual buttons
        -- just refresh their own display if they already have a unit.
        local unit = self:GetAttribute('unit')
        if unit and UnitExists(unit) then
            TauntMasterMini_Button_OnShow(self)
        end
    elseif event == 'UNIT_THREAT_SITUATION_UPDATE' or event == 'PLAYER_TARGET_CHANGED' then
        TauntMasterMini_UpdateThreat(self)
    elseif event == 'UNIT_HEALTH' then
        local unit = ...
        if unit == self:GetAttribute('unit') then
            TauntMasterMini_UpdateHealth(self)
        end
    end
end

function TauntMasterMini_Button_OnShow(self)
    local unit = self:GetAttribute('unit')
    if not unit or not UnitExists(unit) then return end

    -- Set class-colour background and class icon
    local class = select(2, UnitClass(unit))
    if class then
        local color = RAID_CLASS_COLORS[class]
        if color and self._classBg then
            self._classBg:SetColorTexture(color.r * 0.3, color.g * 0.3, color.b * 0.3, 0.85)
        end
        if not TMM_Get('compactMode') and self._classIcon and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class] then
            self._classIcon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[class]))
            self._classIcon:Show()
        end
    else
        if self._classBg then
            self._classBg:SetColorTexture(0, 0, 0, 0.85)
        end
        if self._classIcon then
            self._classIcon:Hide()
        end
    end

    -- Show or hide names on bars
    if self.name then
        if TMM_Get('showNames') and not TMM_Get('compactMode') then
            self.name:Show()
            local name = UnitName(unit)
            if name then
                self.name:SetText(name)
                self.name:SetTextColor(1, 1, 1)
            else
                C_Timer.After(0.5, function()
                    if UnitExists(unit) and self.name then
                        local retryName = UnitName(unit)
                        if retryName then
                            self.name:SetText(retryName)
                            self.name:SetTextColor(1, 1, 1)
                        end
                    end
                end)
            end
        else
            self.name:SetText('')
            self.name:Hide()
        end
    end
    TauntMasterMini_UpdateThreat(self)
    TauntMasterMini_UpdateHealth(self)
    TauntMasterMini_UpdateIcons(self)
end

-- Taint-safe UnitIsUnit: WoW's UnitIsUnit returns a "secret" boolean
-- in tainted contexts (after UnitThreatSituation). Testing it with 'if'
-- triggers an error. This wrapper uses string comparison on UnitGUID
-- which returns a clean string, not a tainted boolean.
TMM_IsPlayer = function(unit)
    if unit == 'player' then return true end
    local playerGUID = UnitGUID('player')
    local unitGUID = UnitGUID(unit)
    return playerGUID and unitGUID and (playerGUID == unitGUID)
end

-- ActionButtonUseKeyDown conflict: WoW's secure click system dispatches on
-- the press edge when that CVar is on, and on the release edge when it is
-- off. A button registered only for 'AnyUp' is dead while the CVar is on
-- (the reported "GUI buttons don't work" symptom). Rather than change the
-- global CVar (a known action-bar taint vector), register our OWN secure
-- buttons for the edge that matches the current CVar, and re-register on
-- CVAR_UPDATE. Reading the CVar (GetCVarBool) is clean and
-- RegisterForClicks is taint-safe out of combat; combat is deferred.
local TMM_secureClickButtons = {}

local function TMM_ClickEdge()
    local down = GetCVarBool and GetCVarBool('ActionButtonUseKeyDown')
    return down and 'AnyDown' or 'AnyUp'
end

local TMM_lastClickEdge
-- Use in place of button:RegisterForClicks('AnyUp') for every secure button.
local function TMM_RegisterSecureClicks(button)
    if not button then return end
    TMM_secureClickButtons[button] = true
    local edge = TMM_ClickEdge()
    TMM_lastClickEdge = edge
    button:RegisterForClicks(edge)
end

-- Re-point every tracked secure button at the current CVar's edge.
-- No-op when the edge is unchanged; returns false (defers) in combat
-- because RegisterForClicks on a secure frame is protected in lockdown.
local function TMM_RefreshSecureClicks()
    local edge = TMM_ClickEdge()
    if edge == TMM_lastClickEdge then return true end
    if InCombatLockdown() then return false end
    for b in pairs(TMM_secureClickButtons) do
        if b then b:RegisterForClicks(edge) end
    end
    TMM_lastClickEdge = edge
    return true
end

local function TMM_StopThreatFlash(button)
    if button._threatBorder then
        button._threatFlash = false
        button._threatBorder:SetBackdropBorderColor(1, 0, 0, 0)
    end
end

function TauntMasterMini_UpdateThreat(button)
    if not button.healthbar then return end

    -- Test/config mode: paint a fixed cosmetic colour from our own palette and
    -- skip the real threat path entirely. No combat API is read here.
    if TMM_TestCount > 0 and button._testIndex then
        local c = TMM_TEST_COLORS[((button._testIndex - 1) % #TMM_TEST_COLORS) + 1]
        button.healthbar:SetStatusBarColor(c[1], c[2], c[3])
        TMM_StopThreatFlash(button)
        return
    end

    local unit = button:GetAttribute('unit')
    if not unit or not UnitExists(unit) then
        button.healthbar:SetStatusBarColor(0, 0.8, 0)
        TMM_StopThreatFlash(button)
        return
    end

    -- Baseline (no-aggro) colour: the unit's class colour when class
    -- colours are enabled, otherwise green. Threat still overrides this
    -- to yellow/red below so tanks always see aggro either way.
    local baseR, baseG, baseB
    if TMM_Get('useClassColours') then
        local class = select(2, UnitClass(unit))
        local color = class and RAID_CLASS_COLORS[class]
        if color then
            baseR, baseG, baseB = color.r, color.g, color.b
        else
            baseR, baseG, baseB = 0, 0, 0
        end
    else
        baseR, baseG, baseB = 0, 0.8, 0  -- Green
    end

    -- Threat colour scheme:
    --   Baseline (green or class colour) = no aggro / not in combat
    --   Yellow = losing or gaining aggro
    --   Red    = full aggro (tanking securely)

    -- UnitAffectingCombat is C-side and returns clean values.
    if not UnitAffectingCombat(unit) then
        button.healthbar:SetStatusBarColor(baseR, baseG, baseB)
        TMM_StopThreatFlash(button)
        return
    end

    local status = UnitThreatSituation(unit)
    if status == nil then
        -- nil is safe to compare (not tainted); means no threat data
        button.healthbar:SetStatusBarColor(baseR, baseG, baseB)
        TMM_StopThreatFlash(button)
        return
    end

    -- status is a tainted number; set via C-side GetThreatStatusColor,
    -- then read back clean values and remap to our scheme.
    button.healthbar:SetStatusBarColor(GetThreatStatusColor(status))
    local r, g, b = button.healthbar:GetStatusBarColor()

    -- Remap ALL outcomes explicitly so no grey/unexpected colour leaks through.
    -- GetThreatStatusColor returns:
    --   status 0: ~(0.69, 1.0, 0)   green   → Green
    --   status 1: ~(1.0, 1.0, 0.47) yellow  → Yellow
    --   status 2: ~(1.0, 0.6, 0)    orange  → Yellow
    --   status 3: ~(1.0, 0, 0)      red     → Red
    local flashR, flashG, flashB, doFlash
    if r > 0.9 and g < 0.15 then
        -- Red (status 3) → Red — flash red border
        button.healthbar:SetStatusBarColor(1, 0, 0)
        flashR, flashG, flashB, doFlash = 1, 0, 0, true
    elseif r > 0.9 and g > 0.4 and g < 0.8 then
        -- Orange (status 2) → Yellow — flash yellow border
        button.healthbar:SetStatusBarColor(1, 1, 0)
        flashR, flashG, flashB, doFlash = 1, 1, 0, true
    elseif r > 0.9 and g > 0.8 then
        -- Yellow (status 1) → Yellow — flash yellow border
        button.healthbar:SetStatusBarColor(1, 1, 0)
        flashR, flashG, flashB, doFlash = 1, 1, 0, true
    else
        -- Green (status 0) or anything unexpected → baseline (green or class colour)
        button.healthbar:SetStatusBarColor(baseR, baseG, baseB)
        doFlash = false
    end

    if button._threatBorder then
        button._threatFlash = doFlash
        if doFlash then
            button._threatBorderR = flashR
            button._threatBorderG = flashG
            button._threatBorderB = flashB
        else
            button._threatBorder:SetBackdropBorderColor(1, 0, 0, 0)
        end
    end
end

function TauntMasterMini_UpdateHealth(button)
    local unit = button:GetAttribute('unit')
    if not unit or not UnitExists(unit) or not button.healthbar then return end
    local health = UnitHealth(unit)
    local maxHealth = UnitHealthMax(unit)
    button.healthbar:SetMinMaxValues(0, maxHealth)
    button.healthbar:SetValue(health)
end

function TauntMasterMini_UpdateIcons(button)
    local unit = button:GetAttribute('unit')
    if not unit or not UnitExists(unit) then return end

    -- Compact mode: no class/role icons. Enforced every tick because
    -- OnUpdate calls this ~10fps and would otherwise re-show the role icon.
    if TMM_Get('compactMode') then
        if button._classIcon then button._classIcon:Hide() end
        if button._roleIcon then button._roleIcon:Hide() end
        return
    end

    -- Test mode: render the randomised class/role rolled at rebuild,
    -- independent of the real (player) unit, so bars look like a mixed group.
    if TMM_TestCount > 0 and button._testIndex then
        local tc = button._testClass
        if button._classIcon and tc and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[tc] then
            button._classIcon:SetTexture('Interface\\WorldStateFrame\\Icons-Classes')
            button._classIcon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[tc]))
            button._classIcon:Show()
        end
        if button._classBg then
            local col = tc and RAID_CLASS_COLORS[tc]
            if col then
                button._classBg:SetColorTexture(col.r * 0.3, col.g * 0.3, col.b * 0.3, 0.85)
            end
        end
        if button._roleIcon and button._roleIconTex then
            local r = button._testRole
            button._roleIconTex:SetTexture('Interface\\LFGFrame\\UI-LFG-ICON-ROLES')
            if r == 'TANK' then
                button._roleIconTex:SetTexCoord(0, 0.265625, 0.265625, 0.53125)
            elseif r == 'HEALER' then
                button._roleIconTex:SetTexCoord(0.265625, 0.53125, 0, 0.265625)
            else
                button._roleIconTex:SetTexCoord(0.265625, 0.53125, 0.265625, 0.53125)
            end
            button._roleIcon:Show()
        end
        return
    end

    -- Suppress class/role chrome ONLY for the lone solo target/focus bar
    -- when it is an NPC/mob — that (and only that) is the "black squares"
    -- case from before. Group bars (party*/raid*/player tokens) keep
    -- their icons, INCLUDING NPC Follower-Dungeon companions (Crenna,
    -- Meredy, ...): they are real group members with a class and an
    -- assigned role, so the normal logic below must run for them.
    -- Scoped by unit TOKEN (solo bars use 'target'/'focus'); GUID prefix
    -- is the clean, taint-safe NPC test (cf. TMM_IsPlayer rationale).
    local isSoloUnitBar = (unit == 'target' or unit == 'focus')
    if isSoloUnitBar then
        local guid = UnitGUID(unit)
        if guid and not guid:match('^Player%-') then
            if button._classIcon then button._classIcon:Hide() end
            if button._roleIcon then button._roleIcon:Hide() end
            return
        end
    end

    -- Role icon: show Tank/Healer/DPS based on assigned group role
    if button._roleIcon and button._roleIconTex then
        local role = UnitGroupRolesAssigned(unit)
        if not role or role == 'NONE' then
            -- Fall back to spec role for the player, default DPS for others
            if TMM_IsPlayer(unit) then
                local spec = GetSpecialization()
                if spec then
                    role = GetSpecializationRole(spec) or 'DAMAGER'
                else
                    role = 'DAMAGER'
                end
            else
                role = 'DAMAGER'
            end
        end
        -- LFG role icon texture sheet — always set fresh to prevent stale icons
        button._roleIconTex:SetTexture('Interface\\LFGFrame\\UI-LFG-ICON-ROLES')
        if role == 'TANK' then
            button._roleIconTex:SetTexCoord(0, 0.265625, 0.265625, 0.53125)
        elseif role == 'HEALER' then
            button._roleIconTex:SetTexCoord(0.265625, 0.53125, 0, 0.265625)
        else
            button._roleIconTex:SetTexCoord(0.265625, 0.53125, 0.265625, 0.53125)
        end
        button._roleIcon:Show()
    end
end

-- Helper: get spell icon texture for a spell name (cached for options panel)
local TMM_spellIconCache = {}

local function TMM_GetSpellIcon(spellName)
    if not spellName or spellName == '' then return nil end
    if TMM_spellIconCache[spellName] ~= nil then
        return TMM_spellIconCache[spellName] or nil
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellName)
        if info and info.iconID then
            TMM_spellIconCache[spellName] = info.iconID
            return info.iconID
        end
    end
    -- DO NOT negative-cache a miss. On a cold login the spellbook is not
    -- yet populated, so GetSpellInfo returns nil here for a perfectly valid
    -- spell. Caching `false` made that "?" placeholder sticky for the whole
    -- session (only /reload or a manual cache wipe cleared it) because
    -- TMM_InvalidateSpellCache() does NOT wipe TMM_spellIconCache. Leaving
    -- the entry absent lets the next rebuild (now driven by SPELLS_CHANGED)
    -- re-query once spell data is available. These calls happen on
    -- rebuild/config, never in OnUpdate, so the re-query cost is negligible.
    return nil
end

-- NOTE: there is intentionally no out-of-range indicator. Range is an
-- addon-disarmament "secret value" in Midnight (12.0): C_Spell.IsSpellInRange
-- returns nil for valid spells, and UnitInRange returns secret booleans that
-- throw when an addon branches on them. It is not achievable here. /tm range
-- remains only as a diagnostic that demonstrates this.

-- Throttle OnUpdate to ~10 fps to reduce CPU overhead
local UPDATE_THROTTLE = 0.1

function TauntMasterMini_Button_OnUpdate(self, elapsed)
    self._updateElapsed = (self._updateElapsed or 0) + elapsed
    if self._updateElapsed < UPDATE_THROTTLE then return end
    self._updateElapsed = 0

    TauntMasterMini_UpdateThreat(self)
    TauntMasterMini_UpdateHealth(self)
    TauntMasterMini_UpdateIcons(self)

    -- Pulse threat border alpha when flash is active
    if self._threatFlash and self._threatBorder then
        local t = GetTime() * 3  -- 3 Hz pulse
        local alpha = 0.5 + 0.5 * math.sin(t * math.pi * 2)
        self._threatBorder:SetBackdropBorderColor(
            self._threatBorderR or 1,
            self._threatBorderG or 0,
            self._threatBorderB or 0,
            alpha)
    end
end

-- Roster / button creation -------------------------------------------------

local function TMM_CreateUnitButton(index)
    local parent = TauntMasterMini_Header or UIParent
    local name = string.format('TauntMasterMini_Button_%d', index)
    local btn = CreateFrame('Frame', name, parent)
    btn:SetSize(TMM_Get('width') or 75, TMM_Get('height') or 30)
    btn:EnableMouse(false)

    local hb = CreateFrame('StatusBar', name .. '_HealthBar', btn)
    hb:SetAllPoints(btn)
    hb:SetStatusBarTexture('Interface/TargetingFrame/UI-StatusBar')
    hb:SetMinMaxValues(0, 1)
    hb:SetValue(1)
    hb:SetFrameLevel(btn:GetFrameLevel() - 1)
    hb:EnableMouse(false)
    btn.healthbar = hb

    -- Class-colour background on the health bar itself so it shows
    -- behind the fill as the "empty" portion and is not occluded.
    local classBg = hb:CreateTexture(name .. '_ClassBG', 'BACKGROUND')
    classBg:SetAllPoints(hb)
    classBg:SetColorTexture(0, 0, 0, 0.85)
    btn._classBg = classBg

    -- Class icon to the left of the bar, sized to match bar height
    local classIcon = btn:CreateTexture(name .. '_ClassIcon', 'OVERLAY')
    local iconSize = (TMM_Get('height') or 30)
    classIcon:SetSize(iconSize, iconSize)
    classIcon:SetPoint('RIGHT', btn, 'LEFT', -2, 0)
    classIcon:SetTexture('Interface\\WorldStateFrame\\Icons-Classes')
    classIcon:Hide()
    btn._classIcon = classIcon

    local label = btn:CreateFontString(name .. '_Name', 'OVERLAY')
    label:SetFont('Fonts\\FRIZQT__.TTF', 11, 'OUTLINE')
    label:SetShadowOffset(1, -1)
    label:SetShadowColor(0, 0, 0, 1)
    label:SetAllPoints(btn)
    label:SetJustifyH('CENTER')
    label:SetJustifyV('MIDDLE')
    label:SetText('-')
    btn.name = label

    -- Role icon to the right of the bar, sized to match bar height
    -- Use a child Frame with its own texture so it renders independently
    local roleFrame = CreateFrame('Frame', name .. '_RoleFrame', btn)
    local roleSize = (TMM_Get('height') or 30)
    roleFrame:SetSize(roleSize, roleSize)
    roleFrame:SetPoint('LEFT', btn, 'RIGHT', 2, 0)
    roleFrame:SetFrameLevel(btn:GetFrameLevel() + 2)
    local roleIcon = roleFrame:CreateTexture(nil, 'ARTWORK')
    roleIcon:SetAllPoints(roleFrame)
    roleFrame:Hide()
    btn.tankicon = roleFrame    -- keep backward-compat field name
    btn._roleIcon = roleFrame
    btn._roleIconTex = roleIcon

    -- Flashing threat border: pulses when unit has high threat (yellow/red)
    local border = CreateFrame('Frame', name .. '_ThreatBorder', btn, BackdropTemplateMixin and 'BackdropTemplate')
    border:SetPoint('TOPLEFT', btn, 'TOPLEFT', -2, 2)
    border:SetPoint('BOTTOMRIGHT', btn, 'BOTTOMRIGHT', 2, -2)
    border:SetBackdrop({
        edgeFile = 'Interface/Tooltips/UI-Tooltip-Border',
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    border:SetBackdropBorderColor(1, 0, 0, 0)
    border:SetFrameLevel(btn:GetFrameLevel() + 3)
    border:EnableMouse(false)
    btn._threatBorder = border
    btn._threatFlash = false


    -- Cast-feedback flash: a brief white pulse on click so you can see the
    -- click registered. Driven purely by an Alpha animation — no SetAttribute
    -- and no secure mutation, so the PostClick trigger stays taint-free.
    local castFlash = btn:CreateTexture(name .. '_CastFlash', 'ARTWORK', nil, 3)
    castFlash:SetAllPoints(btn)
    castFlash:SetColorTexture(1, 1, 1, 1)
    castFlash:SetAlpha(0)
    local cfAnim = castFlash:CreateAnimationGroup()
    local cfA = cfAnim:CreateAnimation('Alpha')
    cfA:SetFromAlpha(0.55)
    cfA:SetToAlpha(0)
    cfA:SetDuration(0.35)
    cfAnim:SetScript('OnFinished', function() castFlash:SetAlpha(0) end)
    btn._castFlash = castFlash
    btn._castFlashAnim = cfAnim

    btn:SetScript('OnEvent', TauntMasterMini_Button_OnEvent)
    btn:SetScript('OnShow', TauntMasterMini_Button_OnShow)
    btn:SetScript('OnUpdate', TauntMasterMini_Button_OnUpdate)

    TauntMasterMini_Button_OnLoad(btn)

    local click = CreateFrame('Button', name .. '_Click', btn, 'SecureActionButtonTemplate')
    click:SetAllPoints(btn)
    TMM_RegisterSecureClicks(click)
    click:SetFrameLevel(btn:GetFrameLevel() + 10)

    -- SecureActionButtonTemplate creates visual textures (NormalTexture,
    -- CheckedTexture, etc.) that show as unwanted green squares.
    -- Nuke every texture child and permanently prevent new ones from showing.
    local function nukeAllTextures(frame)
        if frame.GetNormalTexture and frame:GetNormalTexture() then
            frame:GetNormalTexture():SetTexture(nil)
            frame:GetNormalTexture():SetAlpha(0)
            frame:GetNormalTexture():Hide()
            frame:GetNormalTexture():SetSize(0, 0)
        end
        if frame.GetPushedTexture and frame:GetPushedTexture() then
            frame:GetPushedTexture():SetAlpha(0)
            frame:GetPushedTexture():Hide()
        end
        if frame.GetCheckedTexture and frame:GetCheckedTexture() then
            frame:GetCheckedTexture():SetAlpha(0)
            frame:GetCheckedTexture():Hide()
        end
        for _, region in pairs({frame:GetRegions()}) do
            if region:IsObjectType('Texture') and region ~= frame.__tmmHighlight then
                region:SetTexture(nil)
                region:SetAlpha(0)
                region:Hide()
                region:SetSize(0, 0)
                region:ClearAllPoints()
            end
        end
    end
    nukeAllTextures(click)
    -- Hook to catch WoW re-applying textures on attribute changes
    hooksecurefunc(click, 'SetNormalTexture', function(self)
        local nt = self:GetNormalTexture()
        if nt then nt:SetTexture(nil); nt:SetAlpha(0); nt:Hide(); nt:SetSize(0, 0) end
    end)
    -- Set our own highlight (tag it so nukeAllTextures skips it)
    click:SetHighlightTexture('Interface/Buttons/UI-Common-MouseHilight', 'ADD')
    local hl = click:GetHighlightTexture()
    if hl then click.__tmmHighlight = hl end
    -- Run nuke again after highlight is set in case it disturbed regions
    nukeAllTextures(click)
    click:SetScript('OnMouseDown', function()
        if btn.healthbar then btn.healthbar:SetAlpha(0.65) end
    end)
    click:SetScript('OnMouseUp', function()
        if btn.healthbar then btn.healthbar:SetAlpha(1) end
    end)
    click:SetScript('OnLeave', function()
        if btn.healthbar then btn.healthbar:SetAlpha(1) end
    end)
    btn._clickOverlay = click

    return btn
end

-- Trigger the click-feedback flash. Only animates a texture's alpha — safe
-- to call from PostClick (no secure attribute writes, cf. skull PostClick).
local function TMM_PlayCastFlash(btn)
    if not btn or not btn._castFlash or not btn._castFlashAnim then return end
    if not TMM_Get('castFlash') then return end
    btn._castFlashAnim:Stop()
    btn._castFlash:SetAlpha(0.55)
    btn._castFlashAnim:Play()
end

TMM_ConfigureClickAction = function(btn, unit)
    local click = btn._clickOverlay
    if not click then return end

    local function clean(entry)
        if not entry then return nil end
        entry = entry:match('^%s*(.-)%s*$')
        if not entry or entry == '' then return nil end
        return entry
    end

    local function buildMacro(unitToken, override)
        local spell = clean(override)
        if not spell then
            spell = TMM_GetTauntSpell()
        end
        if not spell then return '' end

        -- Detect whether the spell targets friendly or hostile units
        local isHelpful = C_Spell and C_Spell.IsSpellHelpful and C_Spell.IsSpellHelpful(spell)
        local isHarmful = C_Spell and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(spell)

        if isHelpful and not isHarmful then
            -- Pure friendly-target spell (Blessings, heals, Lay on Hands, etc.)
            -- Cast directly on the group member whose bar was clicked
            if unitToken == 'player' then
                return string.format('/cast [@player,nodead] %s', spell)
            else
                return string.format('/cast [@%s,help,nodead] %s', unitToken, spell)
            end
        elseif isHelpful and isHarmful then
            -- Dual-target spell: try friendly first, hostile fallback via their target
            if unitToken == 'player' then
                return string.format('/cast [@player,nodead] %s', spell)
            else
                return string.format('/cast [@%s,help,nodead][@%starget,harm,nodead] %s',
                    unitToken, unitToken, spell)
            end
        else
            -- Hostile-target spell (taunts, damage) or unknown.
            -- Cast directly on the unit's target using @<unit>target — no /assist
            -- needed. This avoids target-switching and "Invalid target" errors.
            if unitToken == 'player' then
                return string.format(
                    '/cast [@target,exists,harm,nodead][@targettarget,exists,harm,nodead] %s',
                    spell)
            else
                return string.format(
                    '/cast [@%starget,exists,harm,nodead] %s',
                    unitToken, spell)
            end
        end
    end

    click:SetAttribute('pressAndHoldAction', false)

    local leftMacro = buildMacro(unit, TMM_GetLeftSpell())
    local rightMacro = buildMacro(unit, TMM_GetRightSpell())

    click:SetAttribute('type', 'macro')
    click:SetAttribute('type1', 'macro')
    click:SetAttribute('type2', 'macro')
    click:SetAttribute('macrotext', leftMacro)
    click:SetAttribute('macrotext1', leftMacro)
    click:SetAttribute('macrotext2', rightMacro)

    if DEBUG then
        click:SetScript('PreClick', function(_, which)
            local friendlyTarget = unit == 'player' and 'target' or unit .. 'target'
            local targetName = UnitExists(friendlyTarget) and UnitName(friendlyTarget) or '<none>'
            local currentTarget = UnitExists('target') and UnitName('target') or '<none>'
            print(string.format('TMM PreClick %s bar=%s target=%s playerTarget=%s', which, unit, targetName, currentTarget))
        end)
        click:SetScript('PostClick', function(_, which)
            print(string.format('TMM PostClick %s executed', which))
            TMM_PlayCastFlash(btn)
        end)
    else
        click:SetScript('PreClick', nil)
        click:SetScript('PostClick', function()
            TMM_PlayCastFlash(btn)
        end)
    end
end

TMM_RebuildRoster = function()
    TMM_EnsureDefaults()
    TMM_ApplyFrameStyle()  -- combat-safe; run before the lockdown early-return
    if InCombatLockdown() then return end
    local parent = TauntMasterMini_Header or UIParent

    -- Hide when not in party/raid if option is enabled (test mode overrides it)
    if TMM_TestCount == 0 and TMM_Get('hideWhenSolo') and not IsInGroup() then
        parent:Hide()
        return
    elseif not TauntMasterMiniDBChar.hideTM then
        parent:Show()
    end

    local units = {}
    local testProfiles  -- test mode only: per-bar {class, role}, sorted
    local num = GetNumGroupMembers()
    local hideSelf = not TMM_Get('showSelf')
    local filterDps = TMM_Get('hideDpsInRaid') and IsInRaid()
    if TMM_TestCount > 0 then
        -- Test/config mode: N dummy bars, all bound to 'player' so every
        -- secure macro and WoW API call stays valid and taint-free. The
        -- random class/role is rolled HERE (once per rebuild) into a
        -- profile list so the sort can reorder it — assigning it per
        -- button index after sorting (the old approach) made "Sort:
        -- Tanks first" a no-op on test bars.
        testProfiles = {}
        for k = 1, TMM_TestCount do
            table.insert(units, 'player')
            testProfiles[k] = {
                class = TMM_TEST_CLASSES[math.random(#TMM_TEST_CLASSES)],
                role  = TMM_TEST_ROLES[math.random(#TMM_TEST_ROLES)],
            }
        end
        TMM_SortTestProfiles(testProfiles)
    elseif IsInRaid() and num > 0 then
        for i = 1, num do
            local raidUnit = 'raid' .. i
            if not (hideSelf and TMM_IsPlayer(raidUnit)) then
                if filterDps then
                    local role = UnitGroupRolesAssigned(raidUnit)
                    if role == 'TANK' or role == 'HEALER' then
                        table.insert(units, raidUnit)
                    end
                else
                    table.insert(units, raidUnit)
                end
            end
        end
    elseif IsInGroup() and num > 0 then
        if not hideSelf then table.insert(units, 'player') end
        for i = 1, num - 1 do table.insert(units, 'party' .. i) end
    else
        if not hideSelf then table.insert(units, 'player') end
        -- Solo/world mode: also show a live "target" bar (threat/health of
        -- whatever you're targeting — world elites, rares, etc.).
        if TMM_Get('soloShowTarget') then table.insert(units, 'target') end
    end

    if TMM_TestCount == 0 then
        TMM_SortUnits(units)  -- test bars are sorted via testProfiles above
    end

    local perCol = TMM_Get('unitsPerColumn') or 10
    local maxCols = TMM_Get('maxColumns') or 4
    local bw = TMM_Get('width') or 75
    local bh = TMM_Get('height') or 30

    -- Compact (icon-only) mode: each unit is a bh x bh threat-coloured
    -- square, no class/role icon columns and no name.
    local compact = TMM_Get('compactMode')
    local ebw = compact and bh or bw                       -- effective bar width
    local leftPad = compact and 0 or (bh + 2)              -- class-icon gutter (full only)
    local cellW = compact and bh or (bh + 2 + bw + 2 + bh) -- classIcon+gap+bar+gap+roleIcon

    local needed = math.min(#units, perCol * maxCols)

    for i = 1, needed do
        if not TMMButtons[i] then
            TMMButtons[i] = TMM_CreateUnitButton(i)
        end
        TMMButtons[i]:SetSize(ebw, bh)
        if TMMButtons[i]._classIcon then
            TMMButtons[i]._classIcon:SetSize(bh, bh)
            TMMButtons[i]._classIcon:Hide()
        end
        if TMMButtons[i]._roleIcon then
            TMMButtons[i]._roleIcon:SetSize(bh, bh)
            TMMButtons[i]._roleIcon:Hide()
        end
    end

    for i = needed + 1, #TMMButtons do
        if TMMButtons[i] then
            TMMButtons[i]._testIndex = nil
            TMMButtons[i]._testClass = nil
            TMMButtons[i]._testRole = nil
            TMMButtons[i]:Hide()
            if TMMButtons[i]._classIcon then TMMButtons[i]._classIcon:Hide() end
            if TMMButtons[i]._roleIcon then TMMButtons[i]._roleIcon:Hide() end
        end
    end

    local colY = {}  -- running Y offset per column
    local topOffset = 5
    if parent._dragHandle and parent._dragHandle:IsShown() then
        topOffset = topOffset + DRAG_HANDLE_HEIGHT
    end
    local totalH = 0

    for i = 1, needed do
        local btn = TMMButtons[i]
        local unit = units[i]
        btn:ClearAllPoints()
        local col = math.floor((i - 1) / perCol)
        if not colY[col] then colY[col] = 0 end
        local yOff = colY[col]
        btn:SetPoint('TOPLEFT', parent, 'TOPLEFT', 5 + leftPad + col * (cellW + 6), -topOffset - yOff)
        colY[col] = yOff + bh + 4
        if colY[col] > totalH then totalH = colY[col] end
        btn:SetAttribute('unit', unit)
        btn._testIndex = (TMM_TestCount > 0) and i or nil
        if TMM_TestCount > 0 then
            -- Pull the SORTED profile for this slot (rolled once per
            -- rebuild above), so bar order reflects the chosen sort.
            local p = testProfiles and testProfiles[i]
            btn._testClass = p and p.class
            btn._testRole = p and p.role
        else
            btn._testClass = nil
            btn._testRole = nil
        end
        TMM_ConfigureClickAction(btn, unit)
        btn:Show()
        TauntMasterMini_Button_OnShow(btn)
        -- Test mode: label bars Test 1..N (OnShow set the real player name)
        if TMM_TestCount > 0 and btn.name and not compact then
            btn.name:Show()
            btn.name:SetText('Test ' .. i)
            btn.name:SetTextColor(1, 1, 1)
        end
    end

    local cols = math.min(maxCols, math.max(1, math.ceil(needed / perCol)))
    local handleExtra = (parent._dragHandle and parent._dragHandle:IsShown()) and DRAG_HANDLE_HEIGHT or 0
    parent:SetSize(10 + cols * (cellW + 6), 10 + totalH + handleExtra)

    -- Refresh the interrupt button's macrotext/icon from clean, out-of-combat
    -- code (RebuildRoster already early-returned if InCombatLockdown).
    if TauntMasterMini_Header and TauntMasterMini_Header._configureInterrupt then
        TauntMasterMini_Header._configureInterrupt()
    end
    if TauntMasterMini_Header and TauntMasterMini_Header._configureTaunts then
        TauntMasterMini_Header._configureTaunts()
    end
    if TauntMasterMini_Header and TauntMasterMini_Header._layoutTopRow then
        TauntMasterMini_Header._layoutTopRow()
    end
end

TMM_DebugDump = function()
    TMM_EnsureDefaults()
    print('TMM Debug: taunt spell=', TMM_GetTauntSpell() or '<none>')
    print('TMM Debug: frame ' .. ((TauntMasterMiniDBChar and TauntMasterMiniDBChar.locked) and 'locked' or 'unlocked'))
    for i, btn in ipairs(TMMButtons) do
        local unit = btn:GetAttribute('unit') or '<nil>'
        local shown = btn:IsShown() and 'shown' or 'hidden'
        local macro = btn._clickOverlay and btn._clickOverlay:GetAttribute('macrotext') or '<none>'
        print(string.format('  Button %d unit=%s %s macro=%s', i, unit, shown, macro))
    end
end

-- Raid-marker system --------------------------------------------------------
-- The standalone top-centre skull button was removed; raid markers now live
-- in the bottom marker bar (markers 1-8, skull = 8). Each marker is a
-- SecureActionButtonTemplate with a static "/targetmarker N" macro — the
-- engine executes it in a secure context (bypassing addon taint) and the
-- macro self-toggles (clicking N again removes N). A taint-safe, visual-only
-- PostClick flips a per-button boolean for the bright/dim "active" look;
-- PLAYER_TARGET_CHANGED dims them all (state set up in the marker block).

-- Pull Alert ---------------------------------------------------------------

local pullAlertCooldown = {}
local TMMPullFlash  -- forward reference; created on first use
local TMM_firstPullName = nil   -- tracks who made the first pull this combat

local function TMM_CreatePullFlashFrame()
    local f = CreateFrame('Frame', 'TMMPullFlash', UIParent, BackdropTemplateMixin and 'BackdropTemplate')
    f:SetSize(240, 55)
    f:SetPoint('TOP', UIParent, 'TOP', 0, -160)
    f:SetBackdrop({
        bgFile   = 'Interface/Tooltips/UI-Tooltip-Background',
        edgeFile = 'Interface/Tooltips/UI-Tooltip-Border',
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.75, 0.05, 0.05, 0.93)
    f:SetBackdropBorderColor(1, 0.25, 0.1, 1)
    f:SetFrameStrata('HIGH')
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag('LeftButton')
    f:SetScript('OnDragStart', f.StartMoving)
    f:SetScript('OnDragStop', f.StopMovingOrSizing)

    local text = f:CreateFontString(nil, 'OVERLAY', 'GameFontNormalLarge')
    text:SetAllPoints(f)
    text:SetJustifyH('CENTER')
    text:SetJustifyV('MIDDLE')
    text:SetTextColor(1, 0.9, 0.1, 1)
    f._text = text

    -- Flash animation: bounce alpha between full and near-invisible
    local ag = f:CreateAnimationGroup()
    ag:SetLooping('BOUNCE')
    local anim = ag:CreateAnimation('Alpha')
    anim:SetFromAlpha(1.0)
    anim:SetToAlpha(0.15)
    anim:SetDuration(0.25)
    f._ag = ag

    f:Hide()
    return f
end

local function TMM_ShowPullFlash(name, customMsg)
    if not TMMPullFlash then
        TMMPullFlash = TMM_CreatePullFlashFrame()
    end
    local msg = customMsg or ('|cFFFF4444>> PULL! <<|r\n|cFFFFFFFF' .. name .. '|r')
    TMMPullFlash._text:SetText(msg)
    TMMPullFlash:Show()
    TMMPullFlash._ag:Stop()
    TMMPullFlash._ag:Play()
    -- Optional audio cue. Single chokepoint for both first-pull and normal
    -- alerts. Master sound channel so it is audible even with SFX low.
    if TMM_Get('pullAlertSound') ~= false then
        PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, 'Master')
    end
    C_Timer.After(3, function()
        if TMMPullFlash and TMMPullFlash:IsShown() then
            TMMPullFlash._ag:Stop()
            TMMPullFlash:Hide()
        end
    end)
end

local function TMM_GetChatChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return 'INSTANCE_CHAT'
    elseif IsInRaid() then
        return 'RAID'
    elseif IsInGroup() then
        return 'PARTY'
    end
    return nil
end

-- Local, NON-protected on-screen "raid warning" banner. Replaces the old
-- automated SendChatMessage, which is a PROTECTED call when fired from a
-- tainted combat event handler (ADDON_ACTION_BLOCKED) and is exactly the
-- automated-combat-comms pattern Midnight's addon disarmament forbids.
local function TMM_RaidWarn(msg)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, msg,
            (ChatTypeInfo and ChatTypeInfo['RAID_WARNING']) or { r = 1, g = 0.3, b = 0.1 })
    else
        print('|cFFFF4400TauntMasterMini:|r ' .. msg)
    end
end

local function TMM_HandlePullEvent(unit)
    if not TMM_Get('pullAlertEnabled') then return end
    if not unit or not UnitExists(unit) then return end
    if unit == 'player' then return end                 -- ignore ourselves
    if not IsInGroup() then return end                  -- must be grouped
    local role = UnitGroupRolesAssigned(unit)
    if role == 'TANK' then return end                   -- ignore other tanks

    -- Check threat vs the unit's own target first (works even if player isn't targeting the mob),
    -- then fall back to the player's current target.
    local mobToken = unit .. 'target'
    if not UnitExists(mobToken) or UnitIsFriend('player', mobToken) then
        mobToken = 'target'
    end
    if not UnitExists(mobToken) then return end

    -- Threat APIs return tainted ("secret") values in combat that Lua
    -- cannot compare.  Instead, read the healthbar color that was already
    -- set by TauntMasterMini_UpdateThreat (which pipes tainted values
    -- through C-side SetStatusBarColor).  GetStatusBarColor returns clean
    -- untainted floats.  Orange (1,0.6,0) = status 2, Red (1,0,0) = status 3.
    -- Both indicate the unit is tanking / has pulled.
    local btn = TMM_FindButtonForUnit(unit)
    if not btn or not btn.healthbar then return end
    local r, g, b = btn.healthbar:GetStatusBarColor()
    -- "Tanking" colors have high red and low green (orange r=1 g≈0.6, red r=1 g=0)
    -- Yellow is r=1 g=1 b≈0.47, green is r=0 g=1 b=0.  So r>0.9 and g<0.7 = pulling.
    if not (r > 0.9 and g < 0.7) then return end

    -- Debounce: suppress repeat alerts for the same unit for 5 s
    local now = GetTime()
    if pullAlertCooldown[unit] and (now - pullAlertCooldown[unit]) < 5 then return end
    pullAlertCooldown[unit] = now

    local name = UnitName(unit) or unit

    -- First-pull detection: if no one has pulled yet this combat session,
    -- this person is the first non-tank to initiate / gain aggro.
    if TMM_firstPullName == nil then
        TMM_firstPullName = name
        if TMM_Get('firstPullNotification') then
            local flashMsg = '|cFFFF8800>> 1st PULL! <<|r\n|cFFFFFFFF' .. name .. '|r'
            TMM_ShowPullFlash(name, flashMsg)
            print(string.format('|cFFFF8800TauntMasterMini:|r 1st Pull by |cFFFFFFFF%s|r!', name))
            if TMM_Get('pullAlertPartyChat') then
                TMM_RaidWarn('1st Pull by ' .. name .. '!')
            end
            return
        end
    end

    -- Normal pull-aggro alert (subsequent pulls, or first-pull notification disabled)
    TMM_ShowPullFlash(name)
    print(string.format('|cFFFF4400TauntMasterMini:|r |cFFFFFFFF%s|r pulled aggro!', name))

    if TMM_Get('pullAlertPartyChat') then
        TMM_RaidWarn(name .. ' pulled aggro!')
    end
end

-- Options UI creation ------------------------------------------------------

TMM_CreateOrInitUI = function()
    TMM_EnsureDefaults()

    if not TMMOptionsMenu then
        local f = CreateFrame('Frame', 'TMMOptionsMenu', UIParent, BackdropTemplateMixin and 'BackdropTemplate')
        f:SetSize(460, 660)  -- wide enough for the longest checkbox labels
        f:SetPoint('CENTER')
        f:SetBackdrop({
            bgFile = 'Interface/Tooltips/UI-Tooltip-Background',
            edgeFile = 'Interface/Tooltips/UI-Tooltip-Border',
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        f:SetBackdropColor(0, 0, 0, 0.8)
        f:SetFrameStrata('DIALOG')
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag('LeftButton')
        f:SetScript('OnDragStart', f.StartMoving)
        f:SetScript('OnDragStop', f.StopMovingOrSizing)

        local title = f:CreateFontString(nil, 'OVERLAY', 'GameFontNormalLarge')
        title:SetPoint('TOP', 0, -12)
        title:SetText('TauntMasterMini Options')


        -- Track all checkboxes and sliders so we can refresh them after
        -- SavedVariables are loaded (ADDON_LOADED fires after UI creation).
        f._tmmChecks = {}
        f._tmmSliders = {}
        f._pages = {}
        f._tabs = {}

        -- Tab system: fixed-size window, one page visible at a time, so the
        -- panel always fits on screen (replaces the old scroll-less tall list).
        local PAGE_X, PAGE_Y = 10, -66
        local PAGE_W, PAGE_H = 440, 540

        local curPage  -- helpers below add controls to whichever page is current

        local function SetPage(p)
            for _, pg in ipairs(f._pages) do pg:Hide() end
            for _, tb in ipairs(f._tabs) do
                if tb._page == p then tb:LockHighlight() else tb:UnlockHighlight() end
            end
            p:Show()
            -- Keep the not-tank banner in sync whenever the panel/tab opens.
            TMM_UpdateTankSpecNotice()
        end

        local function NewPage(tabLabel)
            local pg = CreateFrame('Frame', nil, f)
            pg:SetPoint('TOPLEFT', PAGE_X, PAGE_Y)
            pg:SetSize(PAGE_W, PAGE_H)
            pg._y = -6
            pg:Hide()
            table.insert(f._pages, pg)
            local idx = #f._pages
            local tab = CreateFrame('Button', nil, f, 'UIPanelButtonTemplate')
            tab:SetSize(86, 22)
            tab:SetPoint('TOPLEFT', 10 + (idx - 1) * 88, -40)
            tab:SetText(tabLabel)
            tab._page = pg
            tab:SetScript('OnClick', function() SetPage(pg) end)
            table.insert(f._tabs, tab)
            return pg
        end

        local pageLayout  = NewPage('Layout')
        local pageDisplay = NewPage('Display')
        local pageSpells  = NewPage('Spells')
        local pageAlerts  = NewPage('Alerts')

        local function AddCheck(label, get, set)
            local cb = CreateFrame('CheckButton', nil, curPage, 'UICheckButtonTemplate')
            cb.text:SetText(label)
            cb:SetPoint('TOPLEFT', 12, curPage._y)
            cb:SetChecked(get())
            cb._tmmGetter = get
            table.insert(f._tmmChecks, cb)
            cb:SetScript('OnClick', function(self)
                if InCombatLockdown() then
                    print('TauntMasterMini: Cannot change this during combat.')
                    self:SetChecked(get())
                    return
                end
                set(self:GetChecked())
            end)
            curPage._y = curPage._y - 28
            return cb
        end

        local function AddSlider(label, minV, maxV, step, get, set)
            local s = CreateFrame('Slider', nil, curPage, 'OptionsSliderTemplate')
            s:SetPoint('TOPLEFT', 16, curPage._y)
            s:SetMinMaxValues(minV, maxV)
            s:SetValueStep(step)
            s:SetObeyStepOnDrag(true)
            s:SetValue(get())
            s._tmmGetter = get
            table.insert(f._tmmSliders, s)
            s.Text:SetText(label)
            s.Low:SetText(tostring(minV))
            s.High:SetText(tostring(maxV))
            s:SetScript('OnValueChanged', function(self, value)
                if InCombatLockdown() then return end
                set(math.floor(value + 0.5))
            end)
            curPage._y = curPage._y - 48
            return s
        end

        local SORT_ORDER = { 'group', 'tank', 'role', 'name' }
        local SORT_LABEL = {
            group = 'Group order', tank = 'Tanks first',
            role = 'By role', name = 'By name',
        }
        local function AddCycle(label, get, set)
            local b = CreateFrame('Button', nil, curPage, 'UIPanelButtonTemplate')
            b:SetPoint('TOPLEFT', 16, curPage._y)
            b:SetSize(320, 24)
            local function upd()
                local v = get()
                b:SetText(label .. ': ' .. (SORT_LABEL[v] or tostring(v)))
            end
            upd()
            -- Page is hidden until shown; refresh on show so it always
            -- reflects the loaded SavedVariables value.
            b:SetScript('OnShow', upd)
            b:SetScript('OnClick', function()
                if InCombatLockdown() then
                    print('TauntMasterMini: Cannot change this during combat.')
                    return
                end
                local cur, idx = get(), 1
                for i, v in ipairs(SORT_ORDER) do
                    if v == cur then idx = i break end
                end
                set(SORT_ORDER[(idx % #SORT_ORDER) + 1])
                upd()
            end)
            curPage._y = curPage._y - 30
            return b
        end

        local function AddSpellDropdown(label, get, set)
            local lbl = curPage:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
            lbl:SetPoint('TOPLEFT', 16, curPage._y)
            lbl:SetText(label)
            curPage._y = curPage._y - 20

            -- Spell icon to the left of the button
            local iconFrame = CreateFrame('Frame', nil, curPage)
            iconFrame:SetSize(24, 24)
            iconFrame:SetPoint('TOPLEFT', 16, curPage._y)
            local iconTex = iconFrame:CreateTexture(nil, 'ARTWORK')
            iconTex:SetAllPoints()
            iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- trim default icon border

            local button = CreateFrame('Button', nil, curPage, 'UIPanelButtonTemplate')
            button:SetPoint('LEFT', iconFrame, 'RIGHT', 4, 0)
            button:SetSize(200, 24)
            button.getterFunction = get
            button._spellIcon = iconTex
            button._spellLabel = lbl
            button.setterFunction = function(value)
                set(value)
                button:refreshText()
            end
            function button:refreshText()
                local value = get()
                if not value or value == '' then
                    self:SetText('Select Spell')
                    self._spellIcon:SetTexture('Interface/Icons/INV_Misc_QuestionMark')
                else
                    self:SetText(value)
                    local icon = TMM_GetSpellIcon(value)
                    self._spellIcon:SetTexture(icon or 'Interface/Icons/INV_Misc_QuestionMark')
                end
            end
            button:refreshText()
            button:SetScript('OnClick', function(self)
                if InCombatLockdown and InCombatLockdown() then
                    print('TauntMasterMini: Cannot change spells during combat.')
                    return
                end
                TMM_ShowSpellPicker(self)
            end)
            curPage._y = curPage._y - 34
            return button
        end


        TMMOptionsMenu = f
        curPage = pageLayout

        AddSlider('Button Width', 50, 200, 1, function()
            return TMM_Get('width') or 75
        end, function(v)
            TMM_Set('width', v)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = 1
            else
                TMM_RebuildRoster()
            end
        end)

        AddSlider('Button Height', 20, 60, 1, function()
            return TMM_Get('height') or 30
        end, function(v)
            TMM_Set('height', v)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = 1
            else
                TMM_RebuildRoster()
            end
        end)

        AddSlider('Units Per Column', 1, 20, 1, function()
            return TMM_Get('unitsPerColumn') or 10
        end, function(v)
            TMM_Set('unitsPerColumn', v)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = 1
            else
                TMM_RebuildRoster()
            end
        end)

        AddSlider('Max Columns', 1, 8, 1, function()
            return TMM_Get('maxColumns') or 4
        end, function(v)
            TMM_Set('maxColumns', v)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = 1
            else
                TMM_RebuildRoster()
            end
        end)

        AddSlider('Frame Scale (%)', 50, 150, 5, function()
            return math.floor((tonumber(TMM_Get('scale')) or 1.0) * 100 + 0.5)
        end, function(v)
            TMM_Set('scale', v / 100)
            TMM_ApplyFrameStyle()
        end)

        AddSlider('Frame Opacity (%)', 20, 100, 5, function()
            return math.floor((tonumber(TMM_Get('opacity')) or 1.0) * 100 + 0.5)
        end, function(v)
            TMM_Set('opacity', v / 100)
            TMM_ApplyFrameStyle()
        end)

        AddCycle('Sort', function()
            return TMM_Get('sortMode') or 'group'
        end, function(v)
            TMM_Set('sortMode', v)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = 1
            else
                TMM_RebuildRoster()
            end
        end)

        -- Test mode toggle (same TMM_TestCount the /tm test command drives)
        local TEST_STEPS = { 0, 5, 10, 20 }
        local testBtn = CreateFrame('Button', nil, curPage, 'UIPanelButtonTemplate')
        testBtn:SetPoint('TOPLEFT', 16, curPage._y)
        testBtn:SetSize(320, 24)
        local function testUpd()
            testBtn:SetText('Test Bars: ' ..
                (TMM_TestCount > 0 and tostring(TMM_TestCount) or 'Off'))
        end
        testUpd()
        testBtn:SetScript('OnShow', testUpd)
        testBtn:SetScript('OnClick', function()
            if InCombatLockdown() then
                print('|cFF00FFFFTauntMasterMini:|r cannot change test mode in combat.')
                return
            end
            local idx = 1
            for i, v in ipairs(TEST_STEPS) do
                if v == TMM_TestCount then idx = i break end
            end
            TMM_TestCount = TEST_STEPS[(idx % #TEST_STEPS) + 1]
            testUpd()
            TMM_RebuildRoster()
        end)
        curPage._y = curPage._y - 30

        curPage = pageSpells
        -- Not-in-tank-spec warning banner. Shown/hidden by
        -- TMM_UpdateTankSpecNotice (login / spec change / panel open).
        -- Space is reserved at the top of the Spells page so the
        -- dropdowns sit at a consistent position whether or not it shows.
        local tankBanner = curPage:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
        tankBanner:SetPoint('TOPLEFT', 12, curPage._y)
        tankBanner:SetPoint('TOPRIGHT', -12, curPage._y)
        tankBanner:SetJustifyH('CENTER')
        tankBanner:SetText('|cFFFFD200Not in a tanking spec — taunt is '
            .. 'unavailable until you switch to your tank spec.|r')
        tankBanner:Hide()
        f._tankBanner = tankBanner
        curPage._y = curPage._y - 38

        f._leftSpellBtn = AddSpellDropdown('Left Click Spell', function()
            return TMM_GetLeftSpell()
        end, function(val)
            TauntMasterMiniDBChar.leftClickSpell = val
            wipe(TMM_spellIconCache)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = 1
            else
                TMM_RebuildRoster()
            end
        end)

        f._rightSpellBtn = AddSpellDropdown('Right Click Spell', function()
            return TMM_GetRightSpell()
        end, function(val)
            TauntMasterMiniDBChar.rightClickSpell = val
            wipe(TMM_spellIconCache)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = 1
            else
                TMM_RebuildRoster()
            end
        end)

        f._interruptSpellBtn = AddSpellDropdown('Interrupt Spell', function()
            return TMM_GetInterruptSpell()
        end, function(val)
            TauntMasterMiniDBChar.interruptSpell = val
            wipe(TMM_spellIconCache)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = 1
            else
                TMM_RebuildRoster()
            end
        end)
        f._interruptSpellBtn._spellFilter = function(n)
            return TMM_INTERRUPTS[n] == true
        end

        -- Explanatory note shown under the Interrupt Spell picker when the
        -- interrupt button itself is turned off (Display tab). Pure UI state
        -- -- no secure frame, no taint, no combat-data concern.
        local intDisabledMsg = curPage:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
        intDisabledMsg:SetPoint('TOPLEFT', 16, curPage._y)
        intDisabledMsg:SetPoint('TOPRIGHT', -12, curPage._y)
        intDisabledMsg:SetJustifyH('LEFT')
        intDisabledMsg:SetText('|cFFFF4040Disabled —|r |cFFFFD200turn on "Show '
            .. 'Interrupt Button" on the Display tab to set an interrupt spell.|r')
        intDisabledMsg:Hide()
        f._interruptDisabledMsg = intDisabledMsg
        curPage._y = curPage._y - 26

        -- Greys out the Interrupt Spell picker (button + icon + label) and
        -- shows the note above when the interrupt button is disabled. A
        -- disabled UIPanelButton does not fire OnClick, so the picker cannot
        -- be opened while greyed. Driven by the "Show Interrupt Button"
        -- checkbox, Reset Defaults, and the ADDON_LOADED panel refresh.
        function f:_updateInterruptSpellEnabled()
            local enabled = (TMM_Get('showInterruptBtn') ~= false)
            local btn = self._interruptSpellBtn
            if btn then
                if enabled then
                    btn:Enable()
                    if btn._spellIcon  then btn._spellIcon:SetDesaturated(false) end
                    if btn._spellLabel then btn._spellLabel:SetTextColor(1, 0.82, 0) end
                else
                    btn:Disable()
                    if btn._spellIcon  then btn._spellIcon:SetDesaturated(true) end
                    if btn._spellLabel then btn._spellLabel:SetTextColor(0.5, 0.5, 0.5) end
                end
            end
            if self._interruptDisabledMsg then
                if enabled then
                    self._interruptDisabledMsg:Hide()
                else
                    self._interruptDisabledMsg:Show()
                end
            end
        end
        f:_updateInterruptSpellEnabled()

        curPage = pageDisplay
        AddCheck('Show Minimap Icon', function()
            return not (TMM_MinimapSettings().hide)
        end, function(val)
            TMM_MinimapSettings().hide = not val
            if val then TMMMinimapBtn_Show() else TMMMinimapBtn_Hide() end
        end)

        AddCheck('Show Names on Bars', function()
            return TMM_Get('showNames')
        end, function(val)
            TMM_Set('showNames', val)
            for _, btn in ipairs(TMMButtons) do
                if btn:IsShown() then
                    TauntMasterMini_Button_OnShow(btn)
                end
            end
        end)

        AddCheck('Compact Mode  (icon-only squares, no names)', function()
            return TMM_Get('compactMode') or false
        end, function(val)
            TMM_Set('compactMode', val)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = 1
            else
                TMM_RebuildRoster()
            end
        end)

        AddCheck('Flash Bar on Click  (cast feedback)', function()
            return TMM_Get('castFlash') ~= false
        end, function(val)
            TMM_Set('castFlash', val)
        end)

        AddCheck('Show Spell Cooldown Indicators  (left & right of skull)', function()
            return TMM_Get('tauntCDIndicator') ~= false
        end, function(val)
            TMM_Set('tauntCDIndicator', val)
            if TauntMasterMini_Header and TauntMasterMini_Header._updateTauntCDVisible then
                TauntMasterMini_Header._updateTauntCDVisible()
            end
        end)

        AddCheck('Show Interrupt Button  (set spell in Spells tab)', function()
            return TMM_Get('showInterruptBtn') ~= false
        end, function(val)
            TMM_Set('showInterruptBtn', val)
            if TauntMasterMini_Header and TauntMasterMini_Header._updateInterruptVisible then
                TauntMasterMini_Header._updateInterruptVisible()
            end
            -- Grey/un-grey the Interrupt Spell picker on the Spells tab.
            if f._updateInterruptSpellEnabled then
                f:_updateInterruptSpellEnabled()
            end
        end)

        AddCheck('Show Raid Marker Bar  (8 markers below the frame)', function()
            return TMM_Get('showMarkerBar') == true
        end, function(val)
            TMM_Set('showMarkerBar', val and true or false)
            if TauntMasterMini_Header and TauntMasterMini_Header._updateMarkerBar then
                TauntMasterMini_Header._updateMarkerBar()
            end
        end)

        AddCheck('Show Target/Focus Taunt Buttons', function()
            return TMM_Get('showTauntButtons') == true
        end, function(val)
            TMM_Set('showTauntButtons', val and true or false)
            if TauntMasterMini_Header and TauntMasterMini_Header._updateTauntBtns then
                TauntMasterMini_Header._updateTauntBtns()
            end
        end)

        AddCheck('Use Class Colours on Bars', function()
            return TMM_Get('useClassColours')
        end, function(val)
            TMM_Set('useClassColours', val)
            for _, btn in ipairs(TMMButtons) do
                if btn:IsShown() then
                    TauntMasterMini_UpdateThreat(btn)
                end
            end
        end)

        AddCheck('Show Self', function()
            return TMM_Get('showSelf')
        end, function(val)
            TMM_Set('showSelf', val)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = 1
            else
                TMM_RebuildRoster()
            end
        end)

        AddCheck('Hide When Not In Party', function()
            return TMM_Get('hideWhenSolo') or false
        end, function(val)
            TMM_Set('hideWhenSolo', val)
            if not InCombatLockdown() then
                TMM_RebuildRoster()
            end
        end)

        AddCheck('Solo: show Target bar  (threat on your target)', function()
            return TMM_Get('soloShowTarget') == true
        end, function(val)
            TMM_Set('soloShowTarget', val and true or false)
            if not InCombatLockdown() then
                TMM_RebuildRoster()
            end
        end)

        AddCheck('Hide DPS In Raid  (show tanks & healers only)', function()
            return TMM_Get('hideDpsInRaid') or false
        end, function(val)
            TMM_Set('hideDpsInRaid', val)
            if not InCombatLockdown() then
                TMM_RebuildRoster()
            end
        end)

        TMMOptionsMenu._lockCheck = AddCheck('Lock Frame', function()
            return TauntMasterMiniDBChar and TauntMasterMiniDBChar.locked or false
        end, function(val)
            TMM_SetLocked(val)
        end)

        curPage._y = curPage._y - 6
        AddSlider('Marker Button Size', 12, 40, 1, function()
            return TMM_Get('skullSize') or 20
        end, function(v)
            TMM_Set('skullSize', v)
            local h = TauntMasterMini_Header
            if h and h._markerBtns then
                for _, mb in ipairs(h._markerBtns) do mb:SetSize(v, v) end
            end
        end)

        AddSlider('Interrupt Button Size', 12, 40, 1, function()
            return TMM_Get('interruptSize') or 20
        end, function(v)
            TMM_Set('interruptSize', v)
            if TauntMasterMini_Header and TauntMasterMini_Header._interruptBtn then
                TauntMasterMini_Header._interruptBtn:SetSize(v, v)
            end
        end)

        -- Pull Alert section
        curPage = pageAlerts
        local pullHeader = pageAlerts:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
        pullHeader:SetPoint('TOPLEFT', 16, curPage._y)
        pullHeader:SetText('|cFFFF9900Pull Alerts|r')
        curPage._y = curPage._y - 24

        AddCheck('Alert when non-tank pulls  (flash + local chat)', function()
            return TMM_Get('pullAlertEnabled') ~= false
        end, function(val)
            TMM_Set('pullAlertEnabled', val)
        end)

        AddCheck('Show "1st Pull by ..." when someone initiates combat', function()
            return TMM_Get('firstPullNotification') ~= false
        end, function(val)
            TMM_Set('firstPullNotification', val)
        end)

        AddCheck('Announce pull on-screen  (big raid-warning banner)', function()
            return TMM_Get('pullAlertPartyChat') ~= false
        end, function(val)
            TMM_Set('pullAlertPartyChat', val)
        end)

        AddCheck('Play sound on pull alert', function()
            return TMM_Get('pullAlertSound') ~= false
        end, function(val)
            TMM_Set('pullAlertSound', val)
        end)

        -- Show the Layout tab by default
        SetPage(pageLayout)

        -- Reset Defaults button
        local resetBtn = CreateFrame('Button', nil, f, 'UIPanelButtonTemplate')
        resetBtn:SetSize(130, 22)
        resetBtn:SetPoint('BOTTOM', 0, 38)
        resetBtn:SetText('Reset Defaults')
        resetBtn:SetScript('OnClick', function()
            if resetBtn._confirmPending then
                -- Second click: actually reset
                resetBtn._confirmPending = nil
                TauntMasterMiniDBChar = nil
                TMM_EnsureDefaults()
                TMM_ApplyDefaultsForClass()
                TMM_CopyDefaultsToChar()
                wipe(TMM_spellIconCache)
                -- Reset position
                if TauntMasterMini_Header then
                    TauntMasterMini_Header:ClearAllPoints()
                    TauntMasterMini_Header:SetPoint('CENTER', UIParent, 'CENTER', 0, 0)
                    TMM_SaveHeaderPosition()
                end
                TMM_UpdateLockState()
                -- Refresh option panel controls
                if TMMOptionsMenu then
                    if TMMOptionsMenu._leftSpellBtn and TMMOptionsMenu._leftSpellBtn.refreshText then
                        TMMOptionsMenu._leftSpellBtn:refreshText()
                    end
                    if TMMOptionsMenu._rightSpellBtn and TMMOptionsMenu._rightSpellBtn.refreshText then
                        TMMOptionsMenu._rightSpellBtn:refreshText()
                    end
                    if TMMOptionsMenu._interruptSpellBtn and TMMOptionsMenu._interruptSpellBtn.refreshText then
                        TMMOptionsMenu._interruptSpellBtn:refreshText()
                    end
                    for _, cb in ipairs(TMMOptionsMenu._tmmChecks or {}) do
                        if cb._tmmGetter then cb:SetChecked(cb._tmmGetter()) end
                    end
                    for _, s in ipairs(TMMOptionsMenu._tmmSliders or {}) do
                        if s._tmmGetter then s:SetValue(s._tmmGetter()) end
                    end
                    if TMMOptionsMenu._updateInterruptSpellEnabled then
                        TMMOptionsMenu:_updateInterruptSpellEnabled()
                    end
                end
                if not InCombatLockdown() then
                    TMM_RebuildRoster()
                end
                resetBtn:SetText('Reset Defaults')
                print('|cFFFF0000TauntMasterMini:|r All settings for this character have been reset to defaults.')
            else
                -- First click: show warning, wait for confirm
                resetBtn._confirmPending = true
                resetBtn:SetText('|cFFFF0000Confirm Reset?|r')
                C_Timer.After(5, function()
                    if resetBtn._confirmPending then
                        resetBtn._confirmPending = nil
                        resetBtn:SetText('Reset Defaults')
                    end
                end)
            end
        end)

        local close = CreateFrame('Button', nil, f, 'UIPanelButtonTemplate')
        close:SetSize(80, 22)
        close:SetPoint('BOTTOM', 0, 12)
        close:SetText('Close')
        close:SetScript('OnClick', function() f:Hide() end)

        f:Hide()
    end

    if not TauntMasterMini_Header then
        local header = CreateFrame('Frame', 'TauntMasterMini_Header', UIParent, BackdropTemplateMixin and 'BackdropTemplate')
        header:SetSize(85, 36)
        header:SetPoint('CENTER', UIParent, 'CENTER', -360, 120)
        header:SetBackdrop({
            bgFile = 'Interface/Tooltips/UI-Tooltip-Background',
            edgeFile = 'Interface/Tooltips/UI-Tooltip-Border',
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        header:SetBackdropColor(0, 0, 0, 0.9)

        local r, g, b, a = header:GetBackdropBorderColor()
        header._tmmDefaultBorderColor = { r, g, b, a }
        header:SetMovable(true)
        header:EnableMouse(true)

        -- Create a drag handle bar at the top for moving the frame
        local handle = CreateFrame('Frame', 'TauntMasterMini_DragHandle', header)
        handle:SetHeight(DRAG_HANDLE_HEIGHT)
        handle:SetPoint('TOPLEFT', header, 'TOPLEFT', 3, -3)
        handle:SetPoint('TOPRIGHT', header, 'TOPRIGHT', -3, -3)
        handle:EnableMouse(true)
        handle:RegisterForDrag('LeftButton')
        handle:SetScript('OnDragStart', function() header:StartMoving() end)
        handle:SetScript('OnDragStop', function()
            header:StopMovingOrSizing()
            TMM_SaveHeaderPosition()
        end)

        -- Background texture for the drag handle
        local handleBg = handle:CreateTexture(nil, 'BACKGROUND')
        handleBg:SetAllPoints()
        handleBg:SetColorTexture(0.2, 0.8, 0.2, 0.6)

        -- Grip lines texture (visual affordance)
        local gripText = handle:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
        gripText:SetPoint('CENTER')
        gripText:SetText('= Drag to Move =')
        gripText:SetTextColor(1, 1, 1, 0.8)

        handle:SetFrameLevel(header:GetFrameLevel() + 20)
        handle:Hide()  -- hidden by default (locked state)
        header._dragHandle = handle

        -- Shared size for the top control icons (CDs) and the marker bar.
        local skullSz = TMM_Get('skullSize') or 20

        -- Spell cooldown indicators (one per click spell), flanking the
        -- skull: left-click spell to the LEFT of the skull, right-click
        -- spell to the RIGHT. EVENT-BASED ONLY — never calls the secret
        -- C_Spell.GetSpellCooldown. We watch the player's own
        -- UNIT_SPELLCAST_SUCCEEDED, record GetTime(), and feed our own
        -- numbers to a Cooldown widget (C-side, taint-allowed). Durations
        -- come from a small known-CD table; 8s is the baseline for the
        -- six tank taunts and a sane default for anything unknown.
        local TMM_SPELL_CD = {
            ['Taunt'] = 8, ['Hand of Reckoning'] = 8, ['Dark Command'] = 8,
            ['Growl'] = 8, ['Provoke'] = 8, ['Torment'] = 8,
        }
        local TMM_DEFAULT_CD = 8

        local function TMM_MakeCDIndicator(idName, getter)
            local fr = CreateFrame('Frame', idName, header)
            fr:SetSize(skullSz, skullSz)
            fr:SetFrameLevel(header:GetFrameLevel() + 25)
            local ic = fr:CreateTexture(nil, 'ARTWORK')
            ic:SetAllPoints()
            ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local sw = CreateFrame('Cooldown', idName .. 'Swipe', fr, 'CooldownFrameTemplate')
            sw:SetAllPoints()
            sw:SetDrawEdge(false)
            fr._getter, fr._iconTex, fr._swipe, fr._readyAt = getter, ic, sw, 0
            -- Throttled: keep the icon in sync with the configured spell and
            -- brighten/dim by readiness. Only GetTime()/our own numbers.
            fr:SetScript('OnUpdate', function(self, elapsed)
                self._t = (self._t or 0) + elapsed
                if self._t < 0.2 then return end
                self._t = 0
                local sp = self._getter()
                self._iconTex:SetTexture((sp and sp ~= '' and TMM_GetSpellIcon(sp))
                    or 'Interface/Icons/INV_Misc_QuestionMark')
                if GetTime() >= (self._readyAt or 0) then
                    self._iconTex:SetDesaturated(false)
                    self._iconTex:SetVertexColor(1, 1, 1, 1)
                else
                    self._iconTex:SetDesaturated(true)
                    self._iconTex:SetVertexColor(0.6, 0.6, 0.6, 1)
                end
            end)
            return fr
        end

        -- Positions for leftCD/rightCD (and intBtn/taunt buttons) are set by
        -- header._layoutTopRow(), which reflows only the enabled icons with
        -- no gaps, centred above the bars.
        local leftCD = TMM_MakeCDIndicator('TMMLeftCD', TMM_GetLeftSpell)
        local rightCD = TMM_MakeCDIndicator('TMMRightCD', TMM_GetRightSpell)
        header._leftCD, header._rightCD = leftCD, rightCD

        local function TMM_UpdateTauntCDVisible()
            local show = TMM_Get('tauntCDIndicator') ~= false
            if show then leftCD:Show(); rightCD:Show()
            else leftCD:Hide(); rightCD:Hide() end
            if header._layoutTopRow then header._layoutTopRow() end
        end
        header._updateTauntCDVisible = TMM_UpdateTauntCDVisible
        TMM_UpdateTauntCDVisible()

        local cdTracker = CreateFrame('Frame')
        cdTracker:RegisterUnitEvent('UNIT_SPELLCAST_SUCCEEDED', 'player')
        cdTracker:SetScript('OnEvent', function(_, _, _, _, spellID)
            local castName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
            if not castName then return end
            local now = GetTime()
            if castName == TMM_GetLeftSpell() then
                local d = TMM_SPELL_CD[castName] or TMM_DEFAULT_CD
                leftCD._readyAt = now + d
                leftCD._swipe:SetCooldown(now, d)
            end
            if castName == TMM_GetRightSpell() then
                local d = TMM_SPELL_CD[castName] or TMM_DEFAULT_CD
                rightCD._readyAt = now + d
                rightCD._swipe:SetCooldown(now, d)
            end
        end)
        header._cdTracker = cdTracker

        -- Interrupt slot: a secure one-button cast of the configured
        -- interrupt on your current target. macrotext is set ONLY from
        -- clean, combat-guarded code (header._configureInterrupt, driven by
        -- ADDON_LOADED / TMM_RebuildRoster) — never from a tainted PreClick
        -- (the 6.5.1 lesson). [Paranoid]
        local TMM_INT_CD = {
            ['Pummel'] = 15, ['Mind Freeze'] = 15, ['Skull Bash'] = 15,
            ['Kick'] = 15, ['Rebuke'] = 15, ['Counterspell'] = 24,
            ['Spell Lock'] = 24, ['Wind Shear'] = 12, ['Disrupt'] = 15,
            ['Avenger\'s Shield'] = 15, ['Silence'] = 45, ['Solar Beam'] = 60,
        }
        local intBtn = CreateFrame('Button', 'TMMInterruptBtn', UIParent,
            'SecureActionButtonTemplate')
        intBtn:SetSize(TMM_Get('interruptSize') or 20, TMM_Get('interruptSize') or 20)
        intBtn:SetFrameStrata(header:GetFrameStrata())
        intBtn:SetFrameLevel(header:GetFrameLevel() + 6)
        intBtn:SetAttribute('type', 'macro')
        intBtn:SetAttribute('macrotext', '')
        TMM_RegisterSecureClicks(intBtn)
        hooksecurefunc(intBtn, 'SetNormalTexture', function(self)
            local n = self:GetNormalTexture(); if n then n:SetAlpha(0) end
        end)
        do local n = intBtn:GetNormalTexture(); if n then n:SetAlpha(0) end end
        local intIcon = intBtn:CreateTexture(nil, 'ARTWORK')
        intIcon:SetAllPoints()
        intIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local intHl = intBtn:CreateTexture(nil, 'HIGHLIGHT')
        intHl:SetAllPoints()
        intHl:SetColorTexture(1, 1, 1, 0.2)
        local intSwipe = CreateFrame('Cooldown', 'TMMInterruptSwipe', intBtn,
            'CooldownFrameTemplate')
        intSwipe:SetAllPoints()
        intSwipe:SetDrawEdge(false)
        intBtn._readyAt = 0

        local function TMM_UpdateInterruptVisible()
            local on = (TMM_Get('showInterruptBtn') ~= false)
                and (TMM_GetInterruptSpell() ~= '')
            if on and header:IsShown() then intBtn:Show() else intBtn:Hide() end
            if header._layoutTopRow then header._layoutTopRow() end
        end
        header._updateInterruptVisible = TMM_UpdateInterruptVisible

        hooksecurefunc(header, 'Show', function() TMM_UpdateInterruptVisible() end)
        hooksecurefunc(header, 'Hide', function() intBtn:Hide() end)

        -- Set macrotext + icon from the configured spell. Never SetAttribute
        -- in combat (deferred; RebuildRoster re-runs this once combat ends).
        header._configureInterrupt = function()
            local sp = TMM_GetInterruptSpell()
            intIcon:SetTexture((sp ~= '' and TMM_GetSpellIcon(sp))
                or 'Interface/Icons/INV_Misc_QuestionMark')
            if InCombatLockdown() then return end
            if sp ~= '' then
                intBtn:SetAttribute('macrotext', '/cast [@target,harm,nodead] ' .. sp)
            else
                intBtn:SetAttribute('macrotext', '')
            end
            TMM_UpdateInterruptVisible()
        end
        header._configureInterrupt()

        intBtn:SetScript('OnUpdate', function(self, e)
            self._t = (self._t or 0) + e
            if self._t < 0.2 then return end
            self._t = 0
            if GetTime() >= (self._readyAt or 0) then
                intIcon:SetDesaturated(false); intIcon:SetVertexColor(1, 1, 1, 1)
            else
                intIcon:SetDesaturated(true); intIcon:SetVertexColor(0.6, 0.6, 0.6, 1)
            end
        end)

        intBtn:SetScript('OnEnter', function(self)
            GameTooltip:SetOwner(self, 'ANCHOR_TOP')
            GameTooltip:SetText('Interrupt', 1, 1, 1)
            local sp = TMM_GetInterruptSpell()
            GameTooltip:AddLine(sp ~= '' and ('Casts ' .. sp .. ' on your target.')
                or 'Set an interrupt spell in Options > Spells.', 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        intBtn:SetScript('OnLeave', GameTooltip_Hide)

        local intTracker = CreateFrame('Frame')
        intTracker:RegisterUnitEvent('UNIT_SPELLCAST_SUCCEEDED', 'player')
        intTracker:SetScript('OnEvent', function(_, _, _, _, spellID)
            local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
            local cur = TMM_GetInterruptSpell()
            if nm and cur ~= '' and nm == cur then
                local now = GetTime()
                local d = TMM_INT_CD[nm] or 15
                intBtn._readyAt = now + d
                intSwipe:SetCooldown(now, d)
            end
        end)
        header._interruptBtn = intBtn
        header._intTracker = intTracker

        -- Target-taunt / Focus-taunt secure buttons. Same static secure
        -- pattern as the interrupt: macrotext set ONLY from clean,
        -- combat-guarded code (header._configureTaunts via ADDON_LOADED /
        -- TMM_RebuildRoster) — never a tainted PreClick. [Paranoid]
        local function TMM_MakeTauntBtn(nm, label)
            local b = CreateFrame('Button', nm, UIParent, 'SecureActionButtonTemplate')
            b:SetSize(TMM_Get('interruptSize') or 20, TMM_Get('interruptSize') or 20)
            b:SetFrameStrata(header:GetFrameStrata())
            b:SetFrameLevel(header:GetFrameLevel() + 6)
            b:SetAttribute('type', 'macro')
            b:SetAttribute('macrotext', '')
            TMM_RegisterSecureClicks(b)
            hooksecurefunc(b, 'SetNormalTexture', function(self)
                local t = self:GetNormalTexture(); if t then t:SetAlpha(0) end
            end)
            do local t = b:GetNormalTexture(); if t then t:SetAlpha(0) end end
            local ic = b:CreateTexture(nil, 'ARTWORK')
            ic:SetAllPoints(); ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local hl = b:CreateTexture(nil, 'HIGHLIGHT')
            hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.2)
            b._iconTex = ic
            b:SetScript('OnEnter', function(self)
                GameTooltip:SetOwner(self, 'ANCHOR_TOP')
                GameTooltip:SetText(label .. ' Taunt', 1, 1, 1)
                local ts = TMM_GetTauntSpell()
                GameTooltip:AddLine(ts and ('Casts ' .. ts .. ' on your ' ..
                    string.lower(label) .. '.') or 'No taunt for this class.',
                    0.8, 0.8, 0.8, true)
                GameTooltip:Show()
            end)
            b:SetScript('OnLeave', GameTooltip_Hide)
            return b
        end
        local tgtTauntBtn = TMM_MakeTauntBtn('TMMTargetTaunt', 'Target')
        local focusTauntBtn = TMM_MakeTauntBtn('TMMFocusTaunt', 'Focus')

        local function TMM_UpdateTauntBtns()
            local on = (TMM_Get('showTauntButtons') == true)
                and (TMM_GetTauntSpell() ~= nil) and header:IsShown()
            if on then tgtTauntBtn:Show(); focusTauntBtn:Show()
            else tgtTauntBtn:Hide(); focusTauntBtn:Hide() end
            if header._layoutTopRow then header._layoutTopRow() end
        end
        header._updateTauntBtns = TMM_UpdateTauntBtns
        hooksecurefunc(header, 'Show', function() TMM_UpdateTauntBtns() end)
        hooksecurefunc(header, 'Hide', function()
            tgtTauntBtn:Hide(); focusTauntBtn:Hide()
        end)

        header._configureTaunts = function()
            local ts = TMM_GetTauntSpell()
            local icon = ts and TMM_GetSpellIcon(ts)
            tgtTauntBtn._iconTex:SetTexture(icon or 'Interface/Icons/INV_Misc_QuestionMark')
            focusTauntBtn._iconTex:SetTexture(icon or 'Interface/Icons/INV_Misc_QuestionMark')
            if InCombatLockdown() then return end
            if ts then
                tgtTauntBtn:SetAttribute('macrotext', '/cast [@target,harm,nodead] ' .. ts)
                focusTauntBtn:SetAttribute('macrotext', '/cast [@focus,harm,nodead] ' .. ts)
            else
                tgtTauntBtn:SetAttribute('macrotext', '')
                focusTauntBtn:SetAttribute('macrotext', '')
            end
            TMM_UpdateTauntBtns()
        end
        header._configureTaunts()
        header._tgtTauntBtn = tgtTauntBtn
        header._focusTauntBtn = focusTauntBtn

        -- Auto-align the top control row: only the currently-shown icons, in
        -- fixed order, packed with no gaps and centred just above the bars.
        -- Called by every visibility updater so the row reflows when icons
        -- are enabled/disabled. SetPoint is not protected — safe any time.
        header._layoutTopRow = function()
            -- intBtn/taunt buttons are secure; moving them in combat is
            -- protected. Skip in combat — re-run on PLAYER_REGEN_ENABLED.
            if InCombatLockdown() then return end
            local order = { leftCD, rightCD, intBtn, tgtTauntBtn, focusTauntBtn }
            local shown, total = {}, 0
            local gap = 4
            for _, b in ipairs(order) do
                if b and b:IsShown() then
                    shown[#shown + 1] = b
                    total = total + b:GetWidth()
                end
            end
            if #shown > 1 then total = total + gap * (#shown - 1) end
            local x = -total / 2
            for _, b in ipairs(shown) do
                b:ClearAllPoints()
                b:SetPoint('BOTTOMLEFT', header, 'TOP', x, 2)
                x = x + b:GetWidth() + gap
            end
        end
        header._layoutTopRow()

        -- Multi-marker bar: 8 secure buttons. EXACT proven skull mechanism,
        -- per marker: a SecureHandlerWrapScript preBody (runs untainted, so
        -- SetAttribute is legal even in combat) alternates the macrotext
        -- between "/targetmarker N" (place) and "/targetmarker 0" (clear, the
        -- same removal the old skull used). PostClick is tainted but only
        -- READS an attribute + updates visuals. Parented to UIParent like
        -- the old skull to avoid threat-handler taint propagation. [Paranoid]
        local MARKER_SZ = TMM_Get('skullSize') or 20
        local markerBtns = {}
        local markerWrapper = CreateFrame('Frame', nil, UIParent,
            'SecureHandlerBaseTemplate')
        local function TMM_SetMarkerBright(mb, bright)
            if bright then
                mb._icon:SetDesaturated(false); mb._icon:SetVertexColor(1, 1, 1, 1)
            else
                mb._icon:SetDesaturated(true); mb._icon:SetVertexColor(0.55, 0.55, 0.55, 0.7)
            end
        end
        for n = 1, 8 do
            -- SecureHandlerBaseTemplate is mixed in so the button gains
            -- SetFrameRef/GetFrameRef (plain SecureActionButtonTemplate does
            -- NOT provide them) — required for the sibling-clear refs below.
            -- Do not drop it. [Paranoid]
            local mb = CreateFrame('Button', 'TMMMarker' .. n, UIParent,
                'SecureActionButtonTemplate, SecureHandlerBaseTemplate')
            mb:SetSize(MARKER_SZ, MARKER_SZ)
            if n == 1 then
                mb:SetPoint('TOPLEFT', header, 'BOTTOMLEFT', 0, -2)
            else
                mb:SetPoint('LEFT', markerBtns[n - 1], 'RIGHT', 2, 0)
            end
            mb:SetFrameStrata(header:GetFrameStrata())
            mb:SetFrameLevel(header:GetFrameLevel() + 6)
            mb:SetAttribute('type', 'macro')
            -- Per-button place/clear macrotexts + state (set from clean load
            -- code; the wrapper swaps 'macrotext' between them on each click).
            mb:SetAttribute('mk-on', '/targetmarker ' .. n)
            mb:SetAttribute('mk-off', '/targetmarker 0')
            mb:SetAttribute('macrotext', '/targetmarker ' .. n)
            mb:SetAttribute('mk-state', 'off')
            TMM_RegisterSecureClicks(mb)
            -- A unit can only carry ONE raid marker, so the bar is a radio
            -- group: turning a marker ON must also turn every OTHER marker
            -- OFF (state + macrotext) so the GUI matches reality. This sibling
            -- reset is done HERE, inside the untainted restricted environment
            -- (legal even in combat) — never from tainted Lua. Sibling
            -- handles come from frame refs set once at load. [Paranoid]
            SecureHandlerWrapScript(mb, 'OnClick', markerWrapper, [[
                local st = self:GetAttribute('mk-state') or 'off'
                if st == 'off' then
                    for i = 1, 8 do
                        local sib = self:GetFrameRef('mk' .. i)
                        if sib and sib ~= self then
                            sib:SetAttribute('mk-state', 'off')
                            sib:SetAttribute('macrotext', sib:GetAttribute('mk-on'))
                        end
                    end
                    self:SetAttribute('macrotext', self:GetAttribute('mk-on'))
                    self:SetAttribute('mk-state', 'on')
                else
                    self:SetAttribute('macrotext', self:GetAttribute('mk-off'))
                    self:SetAttribute('mk-state', 'off')
                end
            ]])
            hooksecurefunc(mb, 'SetNormalTexture', function(self)
                local nt = self:GetNormalTexture(); if nt then nt:SetAlpha(0) end
            end)
            do local nt = mb:GetNormalTexture(); if nt then nt:SetAlpha(0) end end
            local ic = mb:CreateTexture(nil, 'ARTWORK')
            ic:SetAllPoints()
            ic:SetTexture('Interface/TargetingFrame/UI-RaidTargetingIcon_' .. n)
            local hl = mb:CreateTexture(nil, 'HIGHLIGHT')
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.25)
            mb._icon = ic
            TMM_SetMarkerBright(mb, false)  -- start dim/inactive
            -- PostClick is tainted but only READS secure state attributes and
            -- updates visuals (no SetAttribute / secure mutation). Resync the
            -- WHOLE bar so the sibling-clear above is reflected: only the
            -- active marker stays bright, every other one dims.
            mb:HookScript('PostClick', function()
                for _, sib in ipairs(markerBtns) do
                    TMM_SetMarkerBright(sib, sib:GetAttribute('mk-state') == 'on')
                end
            end)
            markerBtns[n] = mb
        end
        header._markerBtns = markerBtns

        -- Give every marker a secure frame ref to all 8 buttons so the
        -- OnClick restricted snippet can clear its siblings via
        -- self:GetFrameRef. SetFrameRef exists only because the buttons mix
        -- in SecureHandlerBaseTemplate (see CreateFrame above). Set once at
        -- load from clean code (out of combat) — refs are setup, not a
        -- per-click secure mutation. [Paranoid]
        for a = 1, 8 do
            for i = 1, 8 do
                markerBtns[a]:SetFrameRef('mk' .. i, markerBtns[i])
            end
        end

        -- On target change, dim every marker icon (visual only — we do NOT
        -- SetAttribute 'mk-state' from tainted Lua; same minor state desync
        -- the old skull accepted).
        local markerReset = CreateFrame('Frame')
        markerReset:RegisterEvent('PLAYER_TARGET_CHANGED')
        markerReset:SetScript('OnEvent', function()
            for _, mb in ipairs(markerBtns) do
                TMM_SetMarkerBright(mb, false)
            end
        end)
        header._markerReset = markerReset

        local function TMM_UpdateMarkerBar()
            local on = (TMM_Get('showMarkerBar') == true) and header:IsShown()
            for _, mb in ipairs(markerBtns) do
                if on then mb:Show() else mb:Hide() end
            end
        end
        header._updateMarkerBar = TMM_UpdateMarkerBar
        hooksecurefunc(header, 'Show', function() TMM_UpdateMarkerBar() end)
        hooksecurefunc(header, 'Hide', function()
            for _, mb in ipairs(markerBtns) do mb:Hide() end
        end)
        TMM_UpdateMarkerBar()

        header:SetScript('OnEvent', function(self, event, ...)
            if event == 'ADDON_LOADED' and ... == addonName then
                -- SavedVariables are now restored — this is the FIRST safe
                -- point to read TauntMasterMiniDB/DBChar reliably.
                TMM_EnsureDefaults()
                TMM_ApplyDefaultsForClass()
                TMM_CopyDefaultsToChar()
                TMM_UpdateLockState()
                TMM_ApplyFrameStyle()
                if self._updateTauntCDVisible then self._updateTauntCDVisible() end
                if self._updateInterruptVisible then self._updateInterruptVisible() end
                if self._updateMarkerBar then self._updateMarkerBar() end
                if self._updateTauntBtns then self._updateTauntBtns() end

                -- Restore saved position
                TMM_RestoreHeaderPosition()

                -- Apply saved frame size
                local savedW = TMM_Get('width')
                local savedH = TMM_Get('height')
                if savedW and savedH then
                    for _, btn in ipairs(TMMButtons) do
                        btn:SetWidth(savedW)
                        btn:SetHeight(savedH)
                    end
                end

                -- Apply saved marker button size
                local savedSkull = TMM_Get('skullSize')
                if self._markerBtns and savedSkull then
                    for _, mb in ipairs(self._markerBtns) do
                        mb:SetSize(savedSkull, savedSkull)
                    end
                end

                -- Apply saved interrupt button size
                local savedInt = TMM_Get('interruptSize')
                if self._interruptBtn and savedInt then
                    self._interruptBtn:SetSize(savedInt, savedInt)
                end

                -- Show/hide header based on saved preference
                if TauntMasterMiniDBChar.hideTM then
                    self:Hide()
                else
                    self:Show()
                end

                -- Refresh option panel controls to match loaded SavedVariables
                if TMMOptionsMenu then
                    if TMMOptionsMenu._leftSpellBtn and TMMOptionsMenu._leftSpellBtn.refreshText then
                        TMMOptionsMenu._leftSpellBtn:refreshText()
                    end
                    if TMMOptionsMenu._rightSpellBtn and TMMOptionsMenu._rightSpellBtn.refreshText then
                        TMMOptionsMenu._rightSpellBtn:refreshText()
                    end
                    if TMMOptionsMenu._interruptSpellBtn and TMMOptionsMenu._interruptSpellBtn.refreshText then
                        TMMOptionsMenu._interruptSpellBtn:refreshText()
                    end
                    for _, cb in ipairs(TMMOptionsMenu._tmmChecks or {}) do
                        if cb._tmmGetter then cb:SetChecked(cb._tmmGetter()) end
                    end
                    for _, s in ipairs(TMMOptionsMenu._tmmSliders or {}) do
                        if s._tmmGetter then s:SetValue(s._tmmGetter()) end
                    end
                    if TMMOptionsMenu._updateInterruptSpellEnabled then
                        TMMOptionsMenu:_updateInterruptSpellEnabled()
                    end
                end

                -- Full rebuild with correct saved spell values
                if not InCombatLockdown() then
                    TMM_RebuildRoster()
                else
                    self._tmmPendingRebuild = 1
                end
            elseif event == 'PLAYER_REGEN_ENABLED' then
                -- Combat ended — reset first-pull tracker for the next encounter
                TMM_firstPullName = nil
                for k in pairs(pullAlertCooldown) do pullAlertCooldown[k] = nil end
                if self._tmmPendingRebuild == 1 then
                    self._tmmPendingRebuild = nil
                    TMM_RebuildRoster()
                end
                if self._tmmPendingShowState ~= nil then
                    local show = (self._tmmPendingShowState == 1)
                    self._tmmPendingShowState = nil
                    TMM_SetHeaderShown(show)
                end
                if self._tmmPendingClicks == 1 then
                    self._tmmPendingClicks = nil
                    TMM_RefreshSecureClicks()
                end
                -- Reflow the top row now that moving secure frames is allowed.
                if self._layoutTopRow then self._layoutTopRow() end
            elseif event == 'PLAYER_SPECIALIZATION_CHANGED' or event == 'TRAIT_CONFIG_UPDATED' or event == 'SPELLS_CHANGED' then
                -- Invalidate spell cache so dropdowns show current spec/talent spells
                TMM_InvalidateSpellCache()
                DebugPrint('Spell cache invalidated due to', event)
                -- Re-evaluate tank-spec notice for the new spec/talents.
                TMM_UpdateTankSpecNotice()
                -- COLD-LOGIN FIX: on a fresh login the spellbook is NOT
                -- populated when ADDON_LOADED fires, so _configureTaunts()
                -- set every secure macrotext to '' and every icon to the
                -- "?" placeholder (taunt/interrupt/cooldowns do nothing,
                -- dropdowns empty). SPELLS_CHANGED is the first point spell
                -- data is actually available, so reconfigure the secure
                -- buttons now. Combat-guarded: SetAttribute on secure
                -- frames is illegal in combat, so defer to
                -- PLAYER_REGEN_ENABLED exactly like the PEW path below.
                if InCombatLockdown() then
                    self._tmmPendingRebuild = 1
                else
                    TMM_RebuildRoster()
                end
                -- The Options > Spells panel icons are a SEPARATE path from
                -- the bar's _configureTaunts: they are set by each spell
                -- button's refreshText(), which only ran at the cold
                -- ADDON_LOADED pass (spells not loaded -> "?"). Refresh them
                -- now that spell data is available. refreshText only sets
                -- text/icon textures (not secure) so it needs no combat
                -- guard. Same trio refreshed on ADDON_LOADED / Reset.
                if TMMOptionsMenu then
                    if TMMOptionsMenu._leftSpellBtn and TMMOptionsMenu._leftSpellBtn.refreshText then
                        TMMOptionsMenu._leftSpellBtn:refreshText()
                    end
                    if TMMOptionsMenu._rightSpellBtn and TMMOptionsMenu._rightSpellBtn.refreshText then
                        TMMOptionsMenu._rightSpellBtn:refreshText()
                    end
                    if TMMOptionsMenu._interruptSpellBtn and TMMOptionsMenu._interruptSpellBtn.refreshText then
                        TMMOptionsMenu._interruptSpellBtn:refreshText()
                    end
                end
            elseif event == 'PLAYER_ENTERING_WORLD' or event == 'GROUP_ROSTER_UPDATE' then
                TMM_InvalidateSpellCache()
                -- One-time login notice if not in a tank spec.
                TMM_UpdateTankSpecNotice()
                -- Clear pull debounce table on roster changes
                for k in pairs(pullAlertCooldown) do pullAlertCooldown[k] = nil end
                if InCombatLockdown() then
                    self._tmmPendingRebuild = 1
                else
                    TMM_RebuildRoster()
                end
                -- Re-apply lock state after SavedVariables are restored
                TMM_UpdateLockState()
                -- Sync secure-click edge to ActionButtonUseKeyDown now that
                -- the CVar is stable and all secure buttons exist.
                if not TMM_RefreshSecureClicks() then
                    self._tmmPendingClicks = 1
                end
            elseif event == 'UNIT_THREAT_SITUATION_UPDATE' then
                TMM_HandlePullEvent(...)
            elseif event == 'PLAYER_TARGET_CHANGED' then
                -- Solo/world mode: rebuild so the target bar's name/icons
                -- track the new target (threat/health track live regardless).
                if TMM_Get('soloShowTarget') and not IsInGroup()
                   and not InCombatLockdown() then
                    TMM_RebuildRoster()
                end
            elseif event == 'CVAR_UPDATE' then
                -- ActionButtonUseKeyDown (or any CVar) changed: re-point our
                -- secure buttons at the matching click edge. Idempotent and
                -- cheap; deferred to PLAYER_REGEN_ENABLED if it lands in combat.
                if not TMM_RefreshSecureClicks() then
                    self._tmmPendingClicks = 1
                end
            end
        end)
        header:RegisterEvent('ADDON_LOADED')
        header:RegisterEvent('PLAYER_TARGET_CHANGED')
        header:RegisterEvent('PLAYER_ENTERING_WORLD')
        header:RegisterEvent('GROUP_ROSTER_UPDATE')
        header:RegisterEvent('PLAYER_REGEN_ENABLED')
        header:RegisterEvent('PLAYER_SPECIALIZATION_CHANGED')
        header:RegisterEvent('TRAIT_CONFIG_UPDATED')
        header:RegisterEvent('SPELLS_CHANGED')
        header:RegisterEvent('UNIT_THREAT_SITUATION_UPDATE')
        header:RegisterEvent('CVAR_UPDATE')

        TMM_UpdateLockState()
    end

    if icon and LDB then
        icon:Register('TauntMasterMini', LDB, TMM_MinimapSettings())
        if TMM_MinimapSettings().hide then
            icon:Hide('TauntMasterMini')
        end
    end

    -- Do NOT call TMM_RebuildRoster() here — SavedVariables are not loaded yet.
    -- ADDON_LOADED, PLAYER_ENTERING_WORLD, and GROUP_ROSTER_UPDATE will each
    -- trigger a rebuild once the data is ready.
end

-- Initialization -----------------------------------------------------------

TMM_CreateOrInitUI()
DebugPrint('TauntMasterMini.lua file loaded')
print('|cFF00FF00TauntMasterMini v7.1.0|r. Type |cFFFFFF00/tm|r for options.')





