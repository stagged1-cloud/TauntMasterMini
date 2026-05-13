# Changelog

All notable changes to TauntMasterMini will be documented in this file.

## [6.7.0] - 2026-05-05

### Added
- **Role icons for every player** — Tank / Healer / DPS icon shown on every bar (not just tanks) using the LFG role texture sheet; falls back to DPS when role is unassigned and infers Tank/Healer from spec where possible

### Fixed
- **"Show Self" ignored when solo** — Solo branch unconditionally added the player to the unit list; now respects the toggle, so unticking Show Self while solo correctly hides your bar
- **Removed friendly-target heal icon** — The small green-outlined icon that appeared on the right of bars when a unit was targeting a friendly was confusing (looked like a stray green square); fully removed along with its texture file (`tm_friendly_icon8.tga`)
- **Role icons showing stale data after roster change** — Class and role icons are now reset before each rebuild and explicitly hidden on excess buttons when the roster shrinks (e.g. when Show Self is toggled off)
- **Taint error from boolean test on tainted flag** — Pending-rebuild flag is now compared against `nil` rather than truth-tested, avoiding a taint propagation path when the flag carried tainted state
- **`UnitIsUnit` taint** — All `UnitIsUnit` calls replaced with GUID comparison (`UnitGUID(a) == UnitGUID(b)`), which is taint-safe in protected contexts
- **Role icon texture issues** — Multiple iterations (numeric IDs → atlas → atlas+pcall → direct LFG sheet) settled on using the LFG texture sheet directly with manual `SetTexCoord`, the most reliable path across UI states

### Technical
- `TMM_IsPlayer` is forward-declared so `OnShow` handlers can reference it during early-load
- Role icons use a child `Frame` with its own `ARTWORK` texture so the icon renders independently of the bar's overlay layer

---

## [6.6.0] - 2026-04-10

### Added
- **Show Self option** — New "Show Self" checkbox in Options to hide your own button from the group list; useful for tanks who don't need a button to taunt themselves
- Session-only setting: always defaults to shown on every `/reload` for maximum reliability; untick in Options to hide for the current session

### Fixed
- **Skull marker toggle not removing skull** — Replaced non-functional `_onclick` attribute with `SecureHandlerWrapScript` preBody; the restricted-environment snippet swaps macrotext between `/targetmarker 8` (place) and `/targetmarker 0` (remove) before each click, fully taint-free
- **Spell buttons not firing when clicked** — Changed click overlay `RegisterForClicks` from `AnyDown` to `AnyUp`, which is the standard registration for `SecureActionButtonTemplate` and matches Blizzard action bar behaviour
- **Cooldown display taint errors** — Replaced `C_Spell.GetSpellCooldown` (returns "secret" values unusable from addon code) with event-based tracking via `UNIT_SPELLCAST_SUCCEEDED` + `GetTime()` and hardcoded spell durations
- **Death Coil and other dual-purpose spells missing from spell picker** — Relaxed spell filter to include non-passive spells with range even when `IsSpellHarmful`/`IsSpellHelpful` both return false

### Technical
- Skull toggle uses `SecureHandlerWrapScript(skullBtn, 'OnClick', wrapper, preBody)` — the preBody runs in an untainted restricted environment before the secure action fires, allowing `SetAttribute` calls even in combat
- Cooldown tracker frame listens to `UNIT_SPELLCAST_SUCCEEDED` for player casts, records `GetTime()` start times, and uses a lookup table of known spell durations (`TMM_KNOWN_CD`) with an 8-second default
- Spell filter now has three inclusion paths: harmful, helpful+hasRange, or unknown+hasRange (catches dual-purpose spells the API doesn't categorise)
- Removed premature `TMM_RebuildRoster()` call from `TMM_CreateOrInitUI()` that ran before SavedVariables were loaded; roster is now built exclusively by event handlers (`ADDON_LOADED`, `PLAYER_ENTERING_WORLD`, `GROUP_ROSTER_UPDATE`)

---

## [6.5.1] - 2026-03-16

### Fixed
- **Skull marker button broken when `ActionButtonUseKeyDown` is OFF** — Changed `RegisterForClicks('AnyDown')` to `RegisterForClicks('AnyDown', 'AnyUp')` so the button fires correctly regardless of that CVar. This CVar is commonly set to OFF by rotation addons (e.g. GSE), which silently prevented the secure action from executing.
- **Skull marker `PreClick` hook tainting `macrotext` attribute** — Removed the `HookScript('PreClick', ...)` that was calling `SetAttribute` from tainted addon Lua. Even outside combat, setting an attribute from tainted code taints the attribute value, causing the secure execution engine to silently refuse to run the macro. The toggle between `/targetmarker 8` and `/targetmarker 0` was unnecessary — `/targetmarker 8` has built-in WoW toggle behaviour (calling it on a unit that already has the skull removes it).

### Technical
- `RegisterForClicks('AnyDown', 'AnyUp')` matches how Blizzard's own action bar buttons are registered; WoW uses the `ActionButtonUseKeyDown` CVar to decide which event triggers the action — it never double-fires
- `PreClick` hook removed entirely; `macrotext` is now set once at frame creation from clean (non-tainted) code and never modified by addon Lua again

---

## [6.5.0] - 2026-03-07

### Added
- **Skull marker toggle** — A small skull icon sits above the tank bar header; click it to place or remove a skull raid marker on your current target
- **Secure macro implementation** — Skull toggle uses `SecureActionButtonTemplate` with `/targetmarker 8`, so the engine handles the protected call in a secure context; completely immune to addon taint
- **Visual toggle feedback** — Skull icon is dim/desaturated when inactive and bright/full-color after placing a skull; resets on target change
- **Tooltip** — Hover the skull icon to see "Toggle Skull Marker" with usage hint
- **First-pull notification** — When the party is not yet in combat and a non-tank pulls first, displays a distinct "1st Pull by [Name]" flash and chat message before falling back to normal pull alerts for subsequent pulls
- **First-pull setting** — New checkbox in Options → Pull Alerts: "Show '1st Pull by ...' when someone initiates combat" (enabled by default)
- **All pull alert checkboxes enabled by default** — Pull alerts, first-pull notification, and party/instance chat announce are all on by default for new installations

### Changed
- Pull alert party chat default changed from off to on for new installations
- First-pull tracker (`TMM_firstPullName`) resets automatically when combat ends (`PLAYER_REGEN_ENABLED`)
- Pull debounce table now also cleared on combat end (in addition to roster changes)

### Technical
- Skull button parented to `UIParent` and anchored to header to avoid taint propagation from threat event handling
- `PreClick` handler swaps macro between `/targetmarker 8` (place) and `/targetmarker 0` (clear) based on internal boolean state — no `GetRaidTargetIndex` or `SetRaidTarget` calls from addon Lua
- `PostClick` flips `_skullActive` boolean and updates icon; `PLAYER_TARGET_CHANGED` resets state
- Green `NormalTexture` from `SecureActionButtonTemplate` suppressed via `hooksecurefunc`

---

## [6.4.0] - 2026-03-07

### Added
- **Pull alert system** — Detects when a non-tank party/raid member gains highest threat (status 3) on your current target and fires an immediate alert
- **Flashing alert box** — A red backdrop frame pops up near the top of the screen showing `>> PULL! << [Name]`; bounces alpha between full and near-invisible (0.25 s cycle) for 3 seconds then auto-hides; draggable to reposition
- **Local chat message** — Always prints `TauntMasterMini: [Name] pulled!` to your chat frame when a pull is detected
- **Party/instance chat announce** — Optional: sends `[Name] pulled!` via `SendChatMessage` to `INSTANCE_CHAT` (dungeon), `RAID`, or `PARTY` as appropriate
- **Two new settings in Options panel** (under a "Pull Alerts" section):
  - *Alert when non-tank pulls* — enables/disables the flash box and local message (on by default)
  - *Announce pull in party/instance chat* — sends the chat message (/p or /i equivalent, off by default)
- **5-second debounce per unit** — suppresses repeat alerts for the same puller; cleared automatically on roster changes

### Changed
- Options panel height increased from 520 to 620 px to accommodate pull alert section
- Header frame now also registers `UNIT_THREAT_SITUATION_UPDATE` for pull detection (individual buttons already registered this event for threat-colour updates)

---

## [6.3.0] - 2026-03-07

### Added
- **Out-of-range indicator** — Red semi-transparent overlay on buttons when the spell target is out of range; checks `@unittarget` for hostile spells and `@unit` for helpful spells using `C_Spell.IsSpellInRange`

### Fixed
- **Left-click not working** — Rewrote hostile-spell macros to use `@<unit>target` directly instead of `/assist` which was failing silently with conditional syntax
- **Stale spell after reload** — Moved all ADDON_LOADED handling to the header frame (removed from individual buttons); dropdown text is now explicitly refreshed after SavedVariables load so it matches the saved spell, not the default
- **Double-fire on click** — Changed `RegisterForClicks('AnyDown', 'AnyUp')` to `RegisterForClicks('AnyDown')` so macros only fire once per click
- **Fishing and other non-combat spells in spell list** — Added explicit case-insensitive blocklist (Fishing, Cooking, Skinning, Mining, Herb Gathering, Prospecting, Milling, Disenchant, Liftoff, Fishing Journal, etc.) as a safety net on top of the harmful/helpful filter

### Changed
- **OnUpdate throttled** — Button updates (threat, health, cooldowns, range) now run at ~10fps instead of every frame to reduce CPU overhead

### Technical
- Hostile-spell macros now use `/cast [@party1target,exists,harm,nodead] Spell` instead of `/assist party1` + `/cast`
- Dual-target spells use `[@unit,help,nodead][@unittarget,harm,nodead]` fallback chain
- ADDON_LOADED centralized on header: ensures SavedVariables are loaded before first `TMM_RebuildRoster()`
- Spell dropdown buttons stored as `TMMOptionsMenu._leftSpellBtn` / `._rightSpellBtn` and refreshed on ADDON_LOADED

---

## [6.2.0] - 2026-03-07

### Fixed
- **Green squares on buttons** — Changed main button from `SecureActionButtonTemplate` to plain `Frame`; hooked click overlay's `SetNormalTexture` to permanently block WoW re-applying default green textures
- **Frame lock not applied on login/reload** — Added `TMM_UpdateLockState()` to header's `PLAYER_ENTERING_WORLD` handler and `TMM_RebuildRoster()` to `ADDON_LOADED` so saved lock state is correctly restored
- **Player names not showing on reload** — Added roster rebuild after `ADDON_LOADED` to apply `showNames` setting from SavedVariables; guarded individual button `PLAYER_ENTERING_WORLD` to only refresh when unit is assigned
- **Cooldown swipe not rendering** — Added `SetSwipeTexture('Interface/Cooldown/cooldown2')` to bare Cooldown widgets (required when not using `CooldownFrameTemplate`)
- **Profession spells in spell list** — Added profession/trade spell blocklist (Cooking, Fishing, Mining, Tailoring, etc.) and `isCombatSpell` filter for action bar scan; also skips off-spec spellbook tabs

### Technical
- Main unit buttons are now plain `Frame` instead of `SecureActionButtonTemplate` (only the click overlay needs secure template)
- Cooldown frames use bare `Cooldown` widget with explicit swipe texture instead of `CooldownFrameTemplate`
- Click overlay textures permanently suppressed via `hooksecurefunc` on `SetNormalTexture`

---

## [6.1.0] - 2026-03-07

### Added
- **Spell picker overhaul** — Dropdown now lists all usable spells from your spellbook (tabs, flyouts, talents, action bars) instead of action-bar-only scanning
- **Blessing / friendly spell support** — Helpful spells (e.g. Blessing of Protection) now cast correctly using `@unitToken,help,nodead` macro conditions
- **Cooldown overlays** — Each button shows a dark clock-sweep cooldown animation for both left-click and right-click spells (split left/right halves)
- **Show Player Names toggle** — New checkbox in options to show or hide class-colored names on buttons
- **Drag handle** — Green bar appears above the header when the frame is unlocked for easier repositioning
- **Frame position saving** — Header position is saved per-character and restored on login

### Fixed
- **Spell list showing junk entries** — Removed unbounded spellbook scan that was pulling non-existent spell slots; filtered guild-perks tab
- **Taunts requiring enemy targeted** — Hostile-spell macros now use `/assist unitToken` before `/cast` so taunts work without the player having the enemy targeted
- **Cooldown taint errors** — Replaced `CooldownFrame_Set()` (Lua wrapper) with `Cooldown:SetCooldown()` (C-side, AllowedWhenTainted) to avoid taint from secret spell cooldown values
- **Green boxes on buttons** — Removed `SetDrawEdge(true)` from cooldown frames that was rendering bright green edge textures
- **Frame lock default** — Frame now defaults to locked on first install

### Changed
- **Options panel** — Enlarged to 520px to accommodate new checkboxes
- **Cooldown display** — Split into two half-width overlays (left half = left-click spell, right half = right-click spell) so both spells' cooldowns are visible simultaneously

### Technical
- Wiki-verified all WoW API calls against warcraft.wiki.gg for 12.0 compatibility
- Replaced non-existent `C_SpellBook.GetNumSpellBookItems` with correct `C_SpellBook.GetNumSpellBookSkillLines()` + `GetSpellBookSkillLineInfo()`
- Added `C_Spell.IsSpellHelpful()` / `IsSpellHarmful()` detection for macro condition generation

---

## [6.0.0] - 2026-01-22

### Updated
- **Interface version to 120000** - Full compatibility with WoW Midnight Pre-Expansion Patch 12.0.0 (Build 65512)
- **All embedded libraries to latest versions** - Updated from official WoWAce repositories
  - **Ace3 Framework** - Updated to r1377 (October 28, 2025) with WoW 12.0 compatibility
    - AceAddon-3.0: Version 13
    - AceEvent-3.0: Latest with WoW 12.0 fixes
    - AceDB-3.0: Version 33 (enhanced namespace cleanup)
    - AceConsole-3.0: Version 7
    - AceConfig-3.0: Version 3
    - AceDBOptions-3.0: Version 15
  - **LibDBIcon-1.0** - Updated to version 55 (major upgrade from revision 34)
  - **LibDataBroker-1.1** - Updated to latest version
  - **LibStub** - Version 2 (current stable)
  - **CallbackHandler-1.0** - Updated to latest version

### Technical Changes
- Updated AceComm-3.0 with ChatThrottleLib for WoW 12.0
- Fixed AceConfigDialog-3.0 GameTooltip alpha value handling
- Enhanced AceDB-3.0 with proper unloaded namespace handling
- Refactored AceGUI-3.0 TreeGroup to prevent button breakage
- Fixed AceGUI-3.0 EditBox InsertLink hook for WoW 12.0 API changes

---

## [5.0.2] - 2025-10-09

### Fixed
- **Removed unwanted checkbox elements** - Fixed green squares appearing on player bars by explicitly disabling checkbox functionality

---

## [5.0.1] - 2025-10-09

### Removed
- **OOM (Out-of-Mana) alerts** - Removed mana tracking feature and all associated code
- Removed `OOMlevel` configuration option from saved variables
- Removed OOM icon display from player buttons

### Technical Changes
- Cleaned up unused OOM-related code from button creation and update functions
- Removed mana threshold checking logic

---

## [5.0.0] - 2025-10-08

### Major Rewrite
This version is a complete modernization and rewrite of the original TauntMaster2 addon by Tartarusspawn.

### Added
- **Vengeance Demon Hunter support** - Full tank spec support for Demon Hunters (Torment, Metamorphosis, Fiery Brand, Demon Spikes)
- **Modern spell picker** - Select spells directly from your action bars instead of manual spell name entry
- **Minimap button integration** - Quick access via LibDBIcon (left-click for options, right-click to toggle)
- **Smart targeting system** - Automatically targets party/raid member's hostile target for taunts
- **Modern options menu** - Completely rebuilt UI with sliders and dropdowns
- **Lock/unlock frame** - Prevent accidental movement when locked
- **Class-colored names** - Player names displayed in their class colors
- **Tank role indicators** - Visual icons show which players are assigned as tanks
- **Friendly target warnings** - Shows when allies are targeting friendlies instead of enemies
- **Flexible grid layout** - Configure columns (1-8) and rows (1-20) independently

### Changed
- **Interface version updated to 110005** - Now compatible with War Within (11.0.5+)
- **Modernized threat detection** - Uses `UnitThreatSituation` API for accurate threat tracking
- **Updated role detection** - Uses `UnitGroupRolesAssigned` for proper tank identification
- **Streamlined codebase** - Reduced from 31,000+ lines to ~400 lines of clean, maintainable code
- **Fixed all deprecated API calls** - Removed `getglobal`, old spell IDs, and outdated functions
- **Improved group/raid support** - Better detection for solo, party (5), and raid (up to 40) scenarios
- **Enhanced click-casting** - Configurable left/right click spells with smart macro generation

### Updated Tank Spells
All tank class defaults updated for War Within expansion:
- **Protection Warrior** - Taunt, Challenging Shout, Shield Wall, Last Stand
- **Protection Paladin** - Hand of Reckoning, Ardent Defender, Guardian of Ancient Kings, Divine Shield
- **Blood Death Knight** - Dark Command, Death Grip, Icebound Fortitude, Vampiric Blood
- **Guardian Druid** - Growl, Survival Instincts, Barkskin, Frenzied Regeneration
- **Brewmaster Monk** - Provoke, Fortifying Brew, Zen Meditation, Dampen Harm
- **Vengeance Demon Hunter** - Torment, Metamorphosis, Fiery Brand, Demon Spikes (NEW)

### Technical Improvements
- Removed dependency on AceAddon framework (now standalone)
- Modern Lua best practices throughout
- Proper combat lockdown handling
- Efficient event registration and handling
- Clean frame creation without XML dependencies
- Modern dropdown system using `MenuUtil.CreateContextMenu`

### Slash Commands
- `/tm` or `/TauntMasterMini` - Open options menu
- `/tm show` - Show frame
- `/tm hide` - Hide frame
- `/tm toggle` - Toggle frame visibility
- `/tm lock` - Lock frame position
- `/tm unlock` - Unlock frame position
- `/tm spells` - List available spells (debug)
- `/tm debug` - Show debug information

---

## [0.0.5] - 2015-01-30 (Original by Tartarusspawn)

Last version of the original addon before being abandoned.

### Original Features
- Basic threat detection for party/raid members
- Click-to-taunt functionality
- Customizable button layouts
- Support for Warriors, Paladins, Death Knights, Druids, and Monks
- Minimap icon

---

## Attribution

**TauntMasterMini v5.0.0+** - Modernized and rewritten by Don Thompson (Haruspex)

**Original TauntMaster2** - Created by Tartarusspawn (2015)
- Project: https://www.curseforge.com/wow/addons/taunt-master-2
