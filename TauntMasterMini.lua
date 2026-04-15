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
    showCooldowns = true,
    showNames = true,
    skullSize = 20,
    hideWhenSolo = false,
    hideDpsInRaid = false,
    pullAlertEnabled = true,
    pullAlertPartyChat = true,
    firstPullNotification = true,
}

-- Forward declarations
local TMM_CreateOrInitUI
local TMM_RebuildRoster
local TMM_SetLocked
local TMM_UpdateLockState
local TMM_ConfigureClickAction
function TauntMasterMini_ConfigureSpells() end

-- Session-only: always show all buttons on load; user unticks to hide self
local TMM_showSelf = true

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

local function TMM_GetLeftSpell()
    return TMM_Get('leftClickSpell') or ''
end

local function TMM_GetRightSpell()
    return TMM_Get('rightClickSpell') or ''
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
    TMM_spellIconCache = {}
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
        TauntMasterMini_Header._tmmPendingShowState = show and true or false
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
    self.healicon = self.healicon or _G[self:GetName() .. '_TM_Friendly_Icon']
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
        if self._classIcon and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class] then
            self._classIcon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[class]))
            self._classIcon:Show()
        end
    else
        if self._classBg then
            self._classBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
        end
        if self._classIcon then
            self._classIcon:Hide()
        end
    end

    -- Show or hide the name label based on setting
    if self.name then
        if TMM_Get('showNames') == false then
            self.name:SetText('')
            self.name:Hide()
        else
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
        end
    end
    TauntMasterMini_UpdateThreat(self)
    TauntMasterMini_UpdateHealth(self)
    TauntMasterMini_UpdateIcons(self)
end

function TauntMasterMini_UpdateThreat(button)
    if not button.healthbar then return end
    local unit = button:GetAttribute('unit')
    if not unit or not UnitExists(unit) then
        button.healthbar:SetStatusBarColor(0, 0.8, 0)
        return
    end

    -- Custom threat colour scheme:
    --   Green  = no aggro / not in combat
    --   Yellow = losing or gaining aggro
    --   Red    = full aggro (tanking securely)

    -- UnitAffectingCombat is C-side and returns clean values.
    if not UnitAffectingCombat(unit) then
        button.healthbar:SetStatusBarColor(0, 0.8, 0)  -- Green
        return
    end

    local status = UnitThreatSituation(unit)
    if status == nil then
        -- nil is safe to compare (not tainted); means no threat data
        button.healthbar:SetStatusBarColor(0, 0.8, 0)  -- Green
        return
    end

    -- status is a tainted number; set via C-side GetThreatStatusColor,
    -- then read back clean values and remap to our scheme.
    button.healthbar:SetStatusBarColor(GetThreatStatusColor(status))
    local r, g, b = button.healthbar:GetStatusBarColor()

    -- GetThreatStatusColor returns:
    --   status 0: ~(0.69, 1.0, 0)   green   → Green (no aggro)
    --   status 1: ~(1.0, 1.0, 0.47) yellow  → Yellow (gaining)
    --   status 2: ~(1.0, 0.6, 0)    orange  → Yellow (losing)
    --   status 3: ~(1.0, 0, 0)      red     → Red (full aggro)
    if r > 0.9 and g > 0.4 and g < 0.8 then
        -- Orange (status 2) → remap to yellow
        button.healthbar:SetStatusBarColor(1, 1, 0)
    elseif r < 0.8 and g > 0.8 then
        -- Green (status 0) → our green
        button.healthbar:SetStatusBarColor(0, 0.8, 0)
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

    -- Role icon: show Tank/Healer/DPS based on assigned group role
    if button._roleIcon and ROLE_ICON_TCOORDS then
        local role = UnitGroupRolesAssigned(unit)
        if role and role ~= 'NONE' and ROLE_ICON_TCOORDS[role] then
            button._roleIcon:SetTexCoord(unpack(ROLE_ICON_TCOORDS[role]))
            button._roleIcon:Show()
        else
            button._roleIcon:Hide()
        end
    end

    if button.healicon then
        local targetUnit = unit .. 'target'
        if UnitExists(targetUnit) and UnitIsFriend(unit, targetUnit) then
            button.healicon:Show()
        else
            button.healicon:Hide()
        end
    end
end

-- Cooldown tracking via cast events to avoid WoW 11.x secret-value taint.
--
-- C_Spell.GetSpellCooldown returns "secret" numbers that SetCooldown will not
-- accept from tainted addon code (OnUpdate handlers). The old GetSpellCooldown
-- global was removed in WoW 11.0.
--
-- Workaround: listen for UNIT_SPELLCAST_SUCCEEDED to know when the player
-- casts a taunt, then call SetCooldown with plain GetTime() / known-duration
-- values — no secret values, no taint issues.

-- Known base cooldown durations (seconds) for common tank spells.
local TMM_KNOWN_CD = {
    ['taunt']              = 8,
    ['hand of reckoning']  = 8,
    ['dark command']       = 8,
    ['growl']              = 8,
    ['provoke']            = 8,
    ['torment']            = 8,
    ['challenging shout']  = 180,
    ['avengers shield']    = 15,
}
local TMM_DEFAULT_CD = 8.0

-- [spellName:lower()] = GetTime() when the spell was last cast
local TMM_cdStartTime = {}

local TMM_CDTracker = CreateFrame('Frame')
TMM_CDTracker:RegisterEvent('UNIT_SPELLCAST_SUCCEEDED')
TMM_CDTracker:SetScript('OnEvent', function(_, _, unit, _, spellID)
    if unit ~= 'player' then return end
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    if info and info.name then
        TMM_cdStartTime[info.name:lower()] = GetTime()
    end
end)

local function TMM_GetCDStart(spell)
    return spell and TMM_cdStartTime[spell:lower()]
end

local function TMM_GetCDDuration(spell)
    return spell and TMM_KNOWN_CD[spell:lower()] or TMM_DEFAULT_CD
end

-- Helper: get spell icon texture for a spell name (cached to avoid API calls every tick)
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

local function TauntMasterMini_UpdateCooldowns(button)
    if not TMM_Get('showCooldowns') then
        if button._cdFrameLeft  then button._cdFrameLeft:SetCooldown(0, 0)  end
        if button._cdFrameRight then button._cdFrameRight:SetCooldown(0, 0) end
        if button._cdIconLeft  then button._cdIconLeft:Hide()  end
        if button._cdIconRight then button._cdIconRight:Hide() end
        return
    end

    local now = GetTime()

    local leftSpell = TMM_GetLeftSpell()
    if not leftSpell or leftSpell == '' then leftSpell = TMM_GetTauntSpell() end

    -- Update left spell icon texture
    if button._cdIconLeft then
        local icon = TMM_GetSpellIcon(leftSpell)
        if icon then
            button._cdIconLeft._iconTex:SetTexture(icon)
            button._cdIconLeft:Show()
        else
            button._cdIconLeft:Hide()
        end
    end

    if button._cdFrameLeft then
        local start = TMM_GetCDStart(leftSpell)
        if start then
            local dur = TMM_GetCDDuration(leftSpell)
            if now - start < dur then
                button._cdFrameLeft:SetCooldown(start, dur)
            else
                TMM_cdStartTime[leftSpell:lower()] = nil
                button._cdFrameLeft:SetCooldown(0, 0)
            end
        else
            button._cdFrameLeft:SetCooldown(0, 0)
        end
    end

    local rightSpell = TMM_GetRightSpell()
    if not rightSpell or rightSpell == '' then rightSpell = TMM_GetTauntSpell() end

    -- Update right spell icon texture
    if button._cdIconRight then
        local icon = TMM_GetSpellIcon(rightSpell)
        if icon then
            button._cdIconRight._iconTex:SetTexture(icon)
            button._cdIconRight:Show()
        else
            button._cdIconRight:Hide()
        end
    end

    if button._cdFrameRight then
        local start = TMM_GetCDStart(rightSpell)
        if start then
            local dur = TMM_GetCDDuration(rightSpell)
            if now - start < dur then
                button._cdFrameRight:SetCooldown(start, dur)
            else
                TMM_cdStartTime[rightSpell:lower()] = nil
                button._cdFrameRight:SetCooldown(0, 0)
            end
        else
            button._cdFrameRight:SetCooldown(0, 0)
        end
    end
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
    TauntMasterMini_UpdateCooldowns(self)
    TauntMasterMini_UpdateRange(self)
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
    classBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
    btn._classBg = classBg

    -- Class icon on the left edge of the bar
    local classIcon = btn:CreateTexture(name .. '_ClassIcon', 'OVERLAY')
    classIcon:SetSize(16, 16)
    classIcon:SetPoint('LEFT', btn, 'LEFT', 2, 0)
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

    -- Role icon: shows Tank, Healer, or DPS icon based on assigned role
    local roleIcon = btn:CreateTexture(name .. '_TM_Role_Icon', 'OVERLAY')
    roleIcon:SetSize(16, 16)
    roleIcon:SetPoint('LEFT', btn, 'LEFT', 20, 0)
    roleIcon:SetTexture('Interface\\LFGFrame\\UI-LFG-ICON-ROLES')
    if ROLE_ICON_TCOORDS and ROLE_ICON_TCOORDS.TANK then
        roleIcon:SetTexCoord(unpack(ROLE_ICON_TCOORDS.TANK))
    end
    roleIcon:Hide()
    btn.tankicon = roleIcon    -- keep backward-compat field name
    btn._roleIcon = roleIcon

    local friendlyIcon = btn:CreateTexture(name .. '_TM_Friendly_Icon', 'OVERLAY')
    friendlyIcon:SetSize(24, 24)
    friendlyIcon:SetPoint('RIGHT', btn, 'RIGHT', 2, 0)
    friendlyIcon:SetTexture('Interface/AddOns/TauntMasterMini/tm_friendly_icon8')
    friendlyIcon:Hide()
    btn.healicon = friendlyIcon

    -- Out-of-range overlay: semi-transparent red tint shown when the
    -- spell target is out of range.  Sits above the health bar but below
    -- the name text and click overlay.
    local oorOverlay = btn:CreateTexture(name .. '_OOR', 'ARTWORK', nil, 2)
    oorOverlay:SetAllPoints(btn)
    oorOverlay:SetColorTexture(1, 0.1, 0.1, 0.4)
    oorOverlay:Hide()
    btn._oorOverlay = oorOverlay

    -- Spell cooldown icons BELOW the bar.
    -- Two square icons: left-click spell (left) and right-click spell (right).
    -- Each has a spell icon texture with a cooldown sweep overlay.
    local CD_ICON_SIZE = 18

    local function SetupCooldownFrame(cd)
        cd:SetDrawEdge(false)
        cd:SetDrawBling(false)
        cd:SetDrawSwipe(true)
        cd:SetSwipeTexture('Interface/Cooldown/cooldown2')
        cd:SetSwipeColor(0, 0, 0, 0.6)
        cd:SetHideCountdownNumbers(true)
        cd:SetReverse(false)
    end

    -- Left-click spell icon + cooldown
    local cdIconLeft = CreateFrame('Frame', name .. '_CDIconLeft', btn)
    cdIconLeft:SetSize(CD_ICON_SIZE, CD_ICON_SIZE)
    cdIconLeft:SetPoint('TOPLEFT', btn, 'BOTTOMLEFT', 2, -1)
    local cdIconLeftTex = cdIconLeft:CreateTexture(nil, 'ARTWORK')
    cdIconLeftTex:SetAllPoints()
    cdIconLeftTex:SetTexture('Interface/Icons/INV_Misc_QuestionMark')
    cdIconLeft._iconTex = cdIconLeftTex
    btn._cdIconLeft = cdIconLeft

    local cdFrameLeft = CreateFrame('Cooldown', name .. '_CDLeft', cdIconLeft)
    cdFrameLeft:SetAllPoints(cdIconLeft)
    cdFrameLeft:SetFrameLevel(cdIconLeft:GetFrameLevel() + 1)
    SetupCooldownFrame(cdFrameLeft)
    btn._cdFrameLeft = cdFrameLeft

    -- Right-click spell icon + cooldown
    local cdIconRight = CreateFrame('Frame', name .. '_CDIconRight', btn)
    cdIconRight:SetSize(CD_ICON_SIZE, CD_ICON_SIZE)
    cdIconRight:SetPoint('LEFT', cdIconLeft, 'RIGHT', 2, 0)
    local cdIconRightTex = cdIconRight:CreateTexture(nil, 'ARTWORK')
    cdIconRightTex:SetAllPoints()
    cdIconRightTex:SetTexture('Interface/Icons/INV_Misc_QuestionMark')
    cdIconRight._iconTex = cdIconRightTex
    btn._cdIconRight = cdIconRight

    local cdFrameRight = CreateFrame('Cooldown', name .. '_CDRight', cdIconRight)
    cdFrameRight:SetAllPoints(cdIconRight)
    cdFrameRight:SetFrameLevel(cdIconRight:GetFrameLevel() + 1)
    SetupCooldownFrame(cdFrameRight)
    btn._cdFrameRight = cdFrameRight

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
        end)
    else
        click:SetScript('PreClick', nil)
        click:SetScript('PostClick', nil)
    end
end

TMM_RebuildRoster = function()
    TMM_EnsureDefaults()
    if InCombatLockdown() then return end
    local parent = TauntMasterMini_Header or UIParent

    -- Hide when not in party/raid if option is enabled
    if TMM_Get('hideWhenSolo') and not IsInGroup() then
        parent:Hide()
        return
    elseif not TauntMasterMiniDBChar.hideTM then
        parent:Show()
    end

    local units = {}
    local num = GetNumGroupMembers()
    local hideSelf = not TMM_showSelf
    local filterDps = TMM_Get('hideDpsInRaid') and IsInRaid()
    if IsInRaid() and num > 0 then
        for i = 1, num do
            local raidUnit = 'raid' .. i
            if not (hideSelf and UnitIsUnit(raidUnit, 'player')) then
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
        table.insert(units, 'player')
    end

    local perCol = TMM_Get('unitsPerColumn') or 10
    local maxCols = TMM_Get('maxColumns') or 4
    local bw = TMM_Get('width') or 75
    local bh = TMM_Get('height') or 30

    local needed = math.min(#units, perCol * maxCols)

    for i = 1, needed do
        if not TMMButtons[i] then
            TMMButtons[i] = TMM_CreateUnitButton(i)
        end
        TMMButtons[i]:SetSize(bw, bh)
    end

    for i = needed + 1, #TMMButtons do
        if TMMButtons[i] then TMMButtons[i]:Hide() end
    end

    for i = 1, needed do
        local btn = TMMButtons[i]
        local unit = units[i]
        btn:ClearAllPoints()
        local col = math.floor((i - 1) / perCol)
        local row = (i - 1) % perCol
        -- Offset downward when drag handle is visible (unlocked)
        local topOffset = 5
        if parent._dragHandle and parent._dragHandle:IsShown() then
            topOffset = topOffset + DRAG_HANDLE_HEIGHT
        end
        -- Extra vertical space for cooldown icons below each bar (18px icon + 3px gap)
        local cdExtra = (TMM_Get('showCooldowns')) and 21 or 0
        btn:SetPoint('TOPLEFT', parent, 'TOPLEFT', 5 + col * (bw + 8), -topOffset - row * (bh + 4 + cdExtra))
        btn:SetAttribute('unit', unit)
        TMM_ConfigureClickAction(btn, unit)
        btn:Show()
        TauntMasterMini_Button_OnShow(btn)
    end

    local cols = math.min(maxCols, math.max(1, math.ceil(needed / perCol)))
    local rows = math.min(perCol, needed)
    local handleExtra = (parent._dragHandle and parent._dragHandle:IsShown()) and DRAG_HANDLE_HEIGHT or 0
    local cdExtra = (TMM_Get('showCooldowns')) and 21 or 0
    parent:SetSize(10 + cols * bw + (cols - 1) * 8, 10 + rows * (bh + cdExtra) + (rows - 1) * 4 + handleExtra)
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

local function TMM_HandlePullEvent(unit)
    if not TMM_Get('pullAlertEnabled') then return end
    if not unit or not UnitExists(unit) then return end
    if UnitIsUnit(unit, 'player') then return end       -- ignore ourselves
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
                local channel = TMM_GetChatChannel()
                if channel then
                    SendChatMessage('1st Pull by ' .. name .. '!', channel)
                end
            end
            return
        end
    end

    -- Normal pull-aggro alert (subsequent pulls, or first-pull notification disabled)
    TMM_ShowPullFlash(name)
    print(string.format('|cFFFF4400TauntMasterMini:|r |cFFFFFFFF%s|r pulled aggro!', name))

    if TMM_Get('pullAlertPartyChat') then
        local channel = TMM_GetChatChannel()
        if channel then
            SendChatMessage(name .. ' pulled aggro!', channel)
        end
    end
end

-- Options UI creation ------------------------------------------------------

TMM_CreateOrInitUI = function()
    TMM_EnsureDefaults()

    if not TMMOptionsMenu then
        local f = CreateFrame('Frame', 'TMMOptionsMenu', UIParent, BackdropTemplateMixin and 'BackdropTemplate')
        f:SetSize(360, 800)
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

        local y = -50
        local function AddCheck(label, get, set)
            local cb = CreateFrame('CheckButton', nil, f, 'UICheckButtonTemplate')
            cb.text:SetText(label)
            cb:SetPoint('TOPLEFT', 16, y)
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
            y = y - 28
            return cb
        end

        local function AddSlider(label, minV, maxV, step, get, set)
            local s = CreateFrame('Slider', nil, f, 'OptionsSliderTemplate')
            s:SetPoint('TOPLEFT', 16, y)
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
            y = y - 48
            return s
        end

        local function AddSpellDropdown(label, get, set)
            local title = f:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
            title:SetPoint('TOPLEFT', 16, y)
            title:SetText(label)
            y = y - 20

            local button = CreateFrame('Button', nil, f, 'UIPanelButtonTemplate')
            button:SetPoint('TOPLEFT', 16, y)
            button:SetSize(200, 24)
            button.getterFunction = get
            button.setterFunction = function(value)
                set(value)
                button:refreshText()
            end
            function button:refreshText()
                local value = get()
                if not value or value == '' then
                    self:SetText('Select Spell')
                else
                    self:SetText(value)
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
            y = y - 34
            return button
        end


        TMMOptionsMenu = f

        AddSlider('Button Width', 50, 200, 1, function()
            return TMM_Get('width') or 75
        end, function(v)
            TMM_Set('width', v)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = true
            else
                TMM_RebuildRoster()
            end
        end)

        AddSlider('Button Height', 20, 60, 1, function()
            return TMM_Get('height') or 30
        end, function(v)
            TMM_Set('height', v)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = true
            else
                TMM_RebuildRoster()
            end
        end)

        AddSlider('Units Per Column', 1, 20, 1, function()
            return TMM_Get('unitsPerColumn') or 10
        end, function(v)
            TMM_Set('unitsPerColumn', v)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = true
            else
                TMM_RebuildRoster()
            end
        end)

        AddSlider('Max Columns', 1, 8, 1, function()
            return TMM_Get('maxColumns') or 4
        end, function(v)
            TMM_Set('maxColumns', v)
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = true
            else
                TMM_RebuildRoster()
            end
        end)

        f._leftSpellBtn = AddSpellDropdown('Left Click Spell', function()
            return TMM_GetLeftSpell()
        end, function(val)
            TauntMasterMiniDBChar.leftClickSpell = val
            TMM_spellIconCache = {}
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = true
            else
                TMM_RebuildRoster()
            end
        end)

        f._rightSpellBtn = AddSpellDropdown('Right Click Spell', function()
            return TMM_GetRightSpell()
        end, function(val)
            TauntMasterMiniDBChar.rightClickSpell = val
            TMM_spellIconCache = {}
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = true
            else
                TMM_RebuildRoster()
            end
        end)

        y = y - 12
        AddCheck('Show Minimap Icon', function()
            return not (TMM_MinimapSettings().hide)
        end, function(val)
            TMM_MinimapSettings().hide = not val
            if val then TMMMinimapBtn_Show() else TMMMinimapBtn_Hide() end
        end)

        AddCheck('Show Cooldowns', function()
            return TMM_Get('showCooldowns')
        end, function(val)
            TMM_Set('showCooldowns', val)
        end)

        AddCheck('Show Player Names', function()
            return TMM_Get('showNames') ~= false
        end, function(val)
            TMM_Set('showNames', val)
            -- Refresh all buttons immediately
            for _, btn in ipairs(TMMButtons) do
                if btn:IsShown() then
                    TauntMasterMini_Button_OnShow(btn)
                end
            end
        end)

        AddCheck('Show Self', function()
            return TMM_showSelf
        end, function(val)
            TMM_showSelf = val
            if InCombatLockdown() then
                TauntMasterMini_Header._tmmPendingRebuild = true
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

        y = y - 6
        AddSlider('Skull Marker Size', 12, 40, 1, function()
            return TMM_Get('skullSize') or 20
        end, function(v)
            TMM_Set('skullSize', v)
            if TauntMasterMini_Header and TauntMasterMini_Header._skullBtn then
                TauntMasterMini_Header._skullBtn:SetSize(v, v)
            end
        end)

        -- Pull Alert section
        y = y - 14
        local pullHeader = f:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
        pullHeader:SetPoint('TOPLEFT', 16, y)
        pullHeader:SetText('|cFFFF9900Pull Alerts|r')
        y = y - 22

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

        AddCheck('Announce pull in party/instance chat  (/p or /i)', function()
            return TMM_Get('pullAlertPartyChat') ~= false
        end, function(val)
            TMM_Set('pullAlertPartyChat', val)
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

        -- Restore saved position
        TMM_RestoreHeaderPosition()

        header:SetScript('OnEvent', function(self, event, ...)
            if event == 'ADDON_LOADED' and ... == addonName then
                -- SavedVariables are now restored — this is the FIRST safe
                -- point to read TauntMasterMiniDB/DBChar reliably.
                TMM_EnsureDefaults()
                TMM_ApplyDefaultsForClass()
                TMM_CopyDefaultsToChar()
                TMM_UpdateLockState()

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
                    self._tmmPendingRebuild = true
                end
            elseif event == 'PLAYER_REGEN_ENABLED' then
                -- Combat ended — reset first-pull tracker for the next encounter
                TMM_firstPullName = nil
                for k in pairs(pullAlertCooldown) do pullAlertCooldown[k] = nil end
                if self._tmmPendingRebuild then
                    self._tmmPendingRebuild = false
                    TMM_RebuildRoster()
                end
                if self._tmmPendingShowState ~= nil then
                    local show = self._tmmPendingShowState
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
                    self._tmmPendingRebuild = true
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





