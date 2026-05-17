-- TauntMasterMini - Modernized version
-- Author: Don Thompson (Haruspex) - 2025-2026
-- Updated for WoW Midnight Pre-Expansion Patch 12.0.0 (Build 65512) - January 2026
-- v6.7.0 - April 2026
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
    showMarkerBar = false,
}

-- Forward declarations
local TMM_CreateOrInitUI
local TMM_RebuildRoster
local TMM_SetLocked
local TMM_UpdateLockState
local TMM_ConfigureClickAction
local TMM_IsPlayer
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

local function TMM_EnsureDefaults()
    -- Account-wide DB holds minimap settings only; everything else is per-char.
    TauntMasterMiniDB = TauntMasterMiniDB or {}
    TauntMasterMiniDB.minimap = TauntMasterMiniDB.minimap or { hide = false }

    -- Per-character settings: migrate from account-wide DB (pre-6.7.0) or
    -- apply DEFAULTS for brand-new characters.
    TauntMasterMiniDBChar = TauntMasterMiniDBChar or {}

    for key, value in pairs(DEFAULTS) do
        if key ~= 'minimap' then  -- minimap stays account-wide
            if TauntMasterMiniDBChar[key] == nil then
                -- Try migrating from old account-wide value first
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

    local defaultTaunt = TMM_GetTauntSpell()
    if defaultTaunt then
        if not TauntMasterMiniDBChar.leftClickSpell or TauntMasterMiniDBChar.leftClickSpell == '' then
            TauntMasterMiniDBChar.leftClickSpell = defaultTaunt
        end
        if not TauntMasterMiniDBChar.rightClickSpell or TauntMasterMiniDBChar.rightClickSpell == '' then
            TauntMasterMiniDBChar.rightClickSpell = defaultTaunt
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

local function TMM_GetAvailableSpells()
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

TMM_UpdateLockState = function()
    local locked = TauntMasterMiniDBChar and TauntMasterMiniDBChar.locked
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

    -- Class colour mode: bar colour is always the unit's class colour
    if TMM_Get('useClassColours') then
        local class = select(2, UnitClass(unit))
        local color = class and RAID_CLASS_COLORS[class]
        if color then
            button.healthbar:SetStatusBarColor(color.r, color.g, color.b)
        else
            button.healthbar:SetStatusBarColor(0, 0, 0)
        end
        TMM_StopThreatFlash(button)
        return
    end

    -- Threat colour scheme:
    --   Green  = no aggro / not in combat
    --   Yellow = losing or gaining aggro
    --   Red    = full aggro (tanking securely)

    -- UnitAffectingCombat is C-side and returns clean values.
    if not UnitAffectingCombat(unit) then
        button.healthbar:SetStatusBarColor(0, 0.8, 0)  -- Green
        TMM_StopThreatFlash(button)
        return
    end

    local status = UnitThreatSituation(unit)
    if status == nil then
        -- nil is safe to compare (not tainted); means no threat data
        button.healthbar:SetStatusBarColor(0, 0.8, 0)  -- Green
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
        -- Green (status 0) or anything unexpected → Green
        button.healthbar:SetStatusBarColor(0, 0.8, 0)
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
    TMM_spellIconCache[spellName] = false
    return nil
end

-- Out-of-range check.
-- For hostile spells we check range to <unit>target; for helpful spells
-- we check range to <unit> itself.  Uses C_Spell.IsSpellInRange (12.0+)
-- which returns true/false, or the legacy IsSpellInRange (0/1/nil).
local function TauntMasterMini_UpdateRange(button)
    local unit = button:GetAttribute('unit')
    if not unit or not UnitExists(unit) then
        if button._oorOverlay then button._oorOverlay:Hide() end
        return
    end

    -- Determine primary spell and the unit to range-check against
    local spell = TMM_GetLeftSpell()
    if not spell or spell == '' then spell = TMM_GetTauntSpell() end
    if not spell then
        if button._oorOverlay then button._oorOverlay:Hide() end
        return
    end

    local isHelpful = C_Spell and C_Spell.IsSpellHelpful and C_Spell.IsSpellHelpful(spell)
    local isHarmful = C_Spell and C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(spell)

    local checkUnit
    if isHelpful and not isHarmful then
        -- Friendly spell: range check to the group member
        checkUnit = unit
    else
        -- Hostile or dual spell: range check to group member's target
        checkUnit = unit .. 'target'
    end

    if not UnitExists(checkUnit) then
        -- No valid target to check range against — hide overlay
        if button._oorOverlay then button._oorOverlay:Hide() end
        return
    end

    -- Try modern C_Spell.IsSpellInRange first (returns bool), then legacy
    local inRange
    if C_Spell and C_Spell.IsSpellInRange then
        inRange = C_Spell.IsSpellInRange(spell, checkUnit)
    elseif IsSpellInRange then
        local r = IsSpellInRange(spell, checkUnit)
        if r ~= nil then inRange = (r == 1) end
    end

    if button._oorOverlay then
        if inRange == false then
            button._oorOverlay:Show()
        else
            -- true or nil (no range data) — hide
            button._oorOverlay:Hide()
        end
    end
end

-- Throttle OnUpdate to ~10 fps to reduce CPU overhead
local OOR_THROTTLE = 0.1

function TauntMasterMini_Button_OnUpdate(self, elapsed)
    self._updateElapsed = (self._updateElapsed or 0) + elapsed
    if self._updateElapsed < OOR_THROTTLE then return end
    self._updateElapsed = 0

    TauntMasterMini_UpdateThreat(self)
    TauntMasterMini_UpdateHealth(self)
    TauntMasterMini_UpdateIcons(self)
    TauntMasterMini_UpdateRange(self)

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

    -- Out-of-range overlay: semi-transparent red tint shown when the
    -- spell target is out of range.  Sits above the health bar but below
    -- the name text and click overlay.
    local oorOverlay = btn:CreateTexture(name .. '_OOR', 'ARTWORK', nil, 2)
    oorOverlay:SetAllPoints(btn)
    oorOverlay:SetColorTexture(1, 0.1, 0.1, 0.4)
    oorOverlay:Hide()
    btn._oorOverlay = oorOverlay

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
    click:RegisterForClicks('AnyUp')
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
    local num = GetNumGroupMembers()
    local hideSelf = not TMM_Get('showSelf')
    local filterDps = TMM_Get('hideDpsInRaid') and IsInRaid()
    if TMM_TestCount > 0 then
        -- Test/config mode: N dummy bars, all bound to 'player' so every
        -- secure macro and WoW API call stays valid and taint-free.
        for _ = 1, TMM_TestCount do table.insert(units, 'player') end
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
    end

    TMM_SortUnits(units)

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
            -- Randomise class/role per bar so the test layout looks like a
            -- real mixed group instead of all-tank. Rolled once per rebuild
            -- and stored, so the ~10fps icon refresh stays stable.
            btn._testClass = TMM_TEST_CLASSES[math.random(#TMM_TEST_CLASSES)]
            btn._testRole = TMM_TEST_ROLES[math.random(#TMM_TEST_ROLES)]
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

-- Skull-marker system -------------------------------------------------------
-- Once an addon touches UnitThreatSituation, its ENTIRE Lua environment is
-- tainted.  Every WoW API return value becomes a "secret" value that cannot
-- be compared — not just threat APIs but UnitGUID, GetRaidTargetIndex, etc.
--
-- Solution:
-- 1) SecureActionButtonTemplate with macro "/targetmarker 8" — the engine
--    executes this in a secure context, bypassing addon taint entirely.
-- 2) A simple boolean toggle for the icon brightness — NO API return values
--    are ever compared.  PostClick flips the bool.  Target-switch dims it.

local _skullActive = false      -- true = skull is currently placed
local _skullIconTex = nil       -- set after header creation

local function TMM_SetSkullIconBright(bright)
    local tex = _skullIconTex
    if not tex then return end
    if bright then
        tex:SetDesaturated(false)
        tex:SetVertexColor(1, 1, 1, 1)
    else
        tex:SetDesaturated(true)
        tex:SetVertexColor(0.5, 0.5, 0.5, 0.6)
    end
end

-- When the player switches target, dim the icon and show the place button so
-- the next click always places skull on the new target.
-- Show/Hide are not combat-protected, so this is safe from tainted event code.
-- On target change just dim the icon. The _onclick handler on the skull button
-- reads GetRaidTargetIndex fresh each click so no state reset is needed.
local TMMSkullEvents = CreateFrame('Frame')
TMMSkullEvents:RegisterEvent('PLAYER_TARGET_CHANGED')
TMMSkullEvents:SetScript('OnEvent', function()
    _skullActive = false
    TMM_SetSkullIconBright(false)
end)

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
        f:SetSize(380, 620)
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
        local PAGE_W, PAGE_H = 360, 500

        local curPage  -- helpers below add controls to whichever page is current

        local function SetPage(p)
            for _, pg in ipairs(f._pages) do pg:Hide() end
            for _, tb in ipairs(f._tabs) do
                if tb._page == p then tb:LockHighlight() else tb:UnlockHighlight() end
            end
            p:Show()
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
        end)

        AddCheck('Show Raid Marker Bar  (8 markers below the frame)', function()
            return TMM_Get('showMarkerBar') == true
        end, function(val)
            TMM_Set('showMarkerBar', val and true or false)
            if TauntMasterMini_Header and TauntMasterMini_Header._updateMarkerBar then
                TauntMasterMini_Header._updateMarkerBar()
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
        AddSlider('Skull Marker Size', 12, 40, 1, function()
            return TMM_Get('skullSize') or 20
        end, function(v)
            TMM_Set('skullSize', v)
            if TauntMasterMini_Header and TauntMasterMini_Header._skullBtn then
                TauntMasterMini_Header._skullBtn:SetSize(v, v)
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

        local skullBtn = CreateFrame('Button', 'TMMSkullToggle', UIParent,
            'SecureActionButtonTemplate')
        local skullSz = TMM_Get('skullSize') or 20
        skullBtn:SetSize(skullSz, skullSz)
        skullBtn:SetPoint('BOTTOM', header, 'TOP', 0, 2)
        skullBtn:SetFrameStrata(header:GetFrameStrata())
        skullBtn:SetFrameLevel(header:GetFrameLevel() + 5)
        skullBtn:SetAttribute('type', 'macro')
        skullBtn:SetAttribute('macrotext', '/targetmarker 8')
        skullBtn:SetAttribute('skull-state', 'off')
        skullBtn:RegisterForClicks('AnyUp')

        -- Use SecureHandlerWrapScript to swap macrotext BEFORE the action fires.
        -- The preBody runs in an untainted restricted environment so SetAttribute
        -- is allowed even in combat — no ADDON_ACTION_BLOCKED errors.
        local skullWrapper = CreateFrame('Frame', nil, UIParent,
            'SecureHandlerBaseTemplate')
        SecureHandlerWrapScript(skullBtn, 'OnClick', skullWrapper, [[
            local state = self:GetAttribute('skull-state') or 'off'
            if state == 'off' then
                self:SetAttribute('macrotext', '/targetmarker 8')
                self:SetAttribute('skull-state', 'on')
            else
                self:SetAttribute('macrotext', '/targetmarker 0')
                self:SetAttribute('skull-state', 'off')
            end
        ]])

        hooksecurefunc(skullBtn, 'SetNormalTexture', function(self)
            local nt = self:GetNormalTexture()
            if nt then nt:SetAlpha(0) end
        end)
        local nt = skullBtn:GetNormalTexture()
        if nt then nt:SetAlpha(0) end

        local skullIcon = skullBtn:CreateTexture(nil, 'ARTWORK')
        skullIcon:SetAllPoints()
        skullIcon:SetTexture('Interface/TargetingFrame/UI-RaidTargetingIcon_8')
        skullIcon:SetDesaturated(true)
        skullIcon:SetVertexColor(0.5, 0.5, 0.5, 0.6)
        _skullIconTex = skullIcon

        local skullHl = skullBtn:CreateTexture(nil, 'HIGHLIGHT')
        skullHl:SetAllPoints()
        skullHl:SetTexture('Interface/TargetingFrame/UI-RaidTargetingIcon_8')
        skullHl:SetAlpha(0.3)

        -- PostClick is tainted but only reads an attribute and updates visuals.
        skullBtn:HookScript('PostClick', function()
            _skullActive = (skullBtn:GetAttribute('skull-state') == 'on')
            TMM_SetSkullIconBright(_skullActive)
        end)

        skullBtn:SetScript('OnEnter', function(self)
            GameTooltip:SetOwner(self, 'ANCHOR_TOP')
            GameTooltip:SetText('Toggle Skull Marker', 1, 1, 1)
            GameTooltip:AddLine('Click to place/remove skull on current target.', 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        skullBtn:SetScript('OnLeave', GameTooltip_Hide)

        hooksecurefunc(header, 'Show', function() skullBtn:Show() end)
        hooksecurefunc(header, 'Hide', function() skullBtn:Hide() end)

        header._skullBtn = skullBtn

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

        local leftCD = TMM_MakeCDIndicator('TMMLeftCD', TMM_GetLeftSpell)
        leftCD:SetPoint('RIGHT', skullBtn, 'LEFT', -4, 0)
        local rightCD = TMM_MakeCDIndicator('TMMRightCD', TMM_GetRightSpell)
        rightCD:SetPoint('LEFT', skullBtn, 'RIGHT', 4, 0)
        header._leftCD, header._rightCD = leftCD, rightCD

        local function TMM_UpdateTauntCDVisible()
            local show = TMM_Get('tauntCDIndicator') ~= false
            if show then leftCD:Show(); rightCD:Show()
            else leftCD:Hide(); rightCD:Hide() end
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
        intBtn:SetPoint('LEFT', rightCD, 'RIGHT', 4, 0)
        intBtn:SetFrameStrata(header:GetFrameStrata())
        intBtn:SetFrameLevel(header:GetFrameLevel() + 6)
        intBtn:SetAttribute('type', 'macro')
        intBtn:SetAttribute('macrotext', '')
        intBtn:RegisterForClicks('AnyUp')
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

        -- Multi-marker bar: 8 secure buttons (/targetmarker N). Static
        -- macrotext set once from clean code; /targetmarker N self-toggles
        -- so NO wrapper/PreClick is needed (the safest secure pattern).
        -- Parented to UIParent like the skull to avoid threat-handler taint
        -- propagation. Opt-in; default off. [Paranoid]
        local MARKER_SZ = 18
        local markerBtns = {}
        for n = 1, 8 do
            local mb = CreateFrame('Button', 'TMMMarker' .. n, UIParent,
                'SecureActionButtonTemplate')
            mb:SetSize(MARKER_SZ, MARKER_SZ)
            if n == 1 then
                mb:SetPoint('TOPLEFT', header, 'BOTTOMLEFT', 0, -2)
            else
                mb:SetPoint('LEFT', markerBtns[n - 1], 'RIGHT', 2, 0)
            end
            mb:SetFrameStrata(header:GetFrameStrata())
            mb:SetFrameLevel(header:GetFrameLevel() + 6)
            mb:SetAttribute('type', 'macro')
            mb:SetAttribute('macrotext', '/targetmarker ' .. n)
            mb:RegisterForClicks('AnyUp')
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
            markerBtns[n] = mb
        end
        header._markerBtns = markerBtns

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

                -- Apply saved skull marker size
                local savedSkull = TMM_Get('skullSize')
                if self._skullBtn and savedSkull then
                    self._skullBtn:SetSize(savedSkull, savedSkull)
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
            elseif event == 'PLAYER_SPECIALIZATION_CHANGED' or event == 'TRAIT_CONFIG_UPDATED' or event == 'SPELLS_CHANGED' then
                -- Invalidate spell cache so dropdowns show current spec/talent spells
                TMM_InvalidateSpellCache()
                DebugPrint('Spell cache invalidated due to', event)
            elseif event == 'PLAYER_ENTERING_WORLD' or event == 'GROUP_ROSTER_UPDATE' then
                TMM_InvalidateSpellCache()
                -- Clear pull debounce table on roster changes
                for k in pairs(pullAlertCooldown) do pullAlertCooldown[k] = nil end
                if InCombatLockdown() then
                    self._tmmPendingRebuild = 1
                else
                    TMM_RebuildRoster()
                end
                -- Re-apply lock state after SavedVariables are restored
                TMM_UpdateLockState()
            elseif event == 'UNIT_THREAT_SITUATION_UPDATE' then
                TMM_HandlePullEvent(...)
            end
        end)
        header:RegisterEvent('ADDON_LOADED')
        header:RegisterEvent('PLAYER_ENTERING_WORLD')
        header:RegisterEvent('GROUP_ROSTER_UPDATE')
        header:RegisterEvent('PLAYER_REGEN_ENABLED')
        header:RegisterEvent('PLAYER_SPECIALIZATION_CHANGED')
        header:RegisterEvent('TRAIT_CONFIG_UPDATED')
        header:RegisterEvent('SPELLS_CHANGED')
        header:RegisterEvent('UNIT_THREAT_SITUATION_UPDATE')

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
print('|cFF00FF00TauntMasterMini v6.7.0|r by |cFFFFFFFF(Haruspex)|r.. Type |cFFFFFF00/tm|r for options.')





