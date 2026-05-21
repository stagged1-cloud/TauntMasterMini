# TauntMasterMini

**Version 7.2.0** | Updated for World of Warcraft: Midnight (12.0)

A lightweight threat utility for tanks that shows live threat bars, one-click spell casting, full spellbook spell selection, cooldown overlays, and smart group targeting in a compact, movable frame.

### What’s new in 7.2.0
- **Class interrupt in the Left/Right Click pickers** — your class interrupt now appears in the **Left Click Spell** and **Right Click Spell** dropdowns too, so you can bind it to a bar click; previously it was only in the Interrupt picker
- **Interrupt Spell picker greys out** when **Show Interrupt Button** is turned off, with a note explaining why — no more setting a spell for a hidden button

### Earlier — 7.1.0
- **Smart per-class starter kit** — a fresh character or “Reset Defaults” auto-fills left = class taunt, right = a useful class spell, interrupt = the class interrupt, **validated against the spells the character actually knows** (spellbook + active talents)
- **Not-in-tanking-spec notice** — a one-time chat message and an Options banner when you’re not in a tank spec
- **Removed the out-of-range indicator** — no longer achievable under Midnight (12.0) addon-disarmament (range is now an opaque/secret value addons may not read); see CHANGELOG

### Core features
- Real-time color-coded threat bars for party/raid up to 40 players
- Left/right click casts with automatic enemy/friendly targeting
- Full spellbook scan including tabs, flyouts, talents, and action bars
- Smart filter blocks profession/non-combat spells like Fishing and Mining
- Dual cooldown overlays
- Default tank taunts for all six tank specs plus any spell assignment
- Movable, lockable frame with per-character position save and minimap integration
- Slash commands: `/tm` or `/TauntMasterMini`

---

## Installation

1. Download and extract the `TauntMasterMini` folder into:
   ```
   World of Warcraft/_retail_/Interface/AddOns/
   ```
2. Restart World of Warcraft or type `/reload` in-game
3. Type `/tm` to open the options menu

---

## Slash Commands

| Command | Action |
|---|---|
| `/tm` or `/TauntMasterMini` | Open options menu |
| `/tm show` | Show the TauntMasterMini frame |
| `/tm hide` | Hide the TauntMasterMini frame |
| `/tm toggle` | Toggle frame visibility |
| `/tm lock` | Lock frame position |
| `/tm unlock` | Unlock frame position |
| `/tm spells` | Run full spell diagnostic (API checks, spellbook tabs, flyouts, talents, final list) |
| `/tm debug` | Print button macro text for each unit |
| `/tm test [N]` | Spawn N (default 5, max 40) randomised dummy bars solo for layout tuning; `/tm test 0` exits (must be out of combat) |

---

## How to Use

1. **Join a group** — The addon automatically creates a bar for each party/raid member
2. **Monitor threat** — Watch health bar colors change in real-time as threat shifts
3. **Click to cast** — Left-click a bar to cast your primary spell; right-click for your secondary spell
4. **Watch cooldowns** — The dark clock-sweep on each bar shows when your spells are ready
5. **Customize** — Type `/tm` to adjust sizes, spells, layout, and display options

---

## Configuration Options

Access via `/tm` or left-click the minimap button. The window is a fixed-size tabbed panel: **Layout / Display / Spells / Alerts**.

**Layout tab**

| Option | Description |
|---|---|
| **Button Width** | Horizontal size of each player bar (50–200 px) |
| **Button Height** | Vertical size of each player bar (20–60 px) |
| **Units Per Column** | How many bars per column before wrapping (1–20) |
| **Max Columns** | Maximum columns to display (1–8) |
| **Frame Scale (%)** | Whole-frame scale (50–150 %) |
| **Frame Opacity (%)** | Whole-frame opacity (20–100 %) |
| **Sort** | Bar order: Group order / Tanks first / By role / By name |
| **Test bars** | Spawn randomised dummy bars solo to tune layout (also `/tm test [N]`) |

**Display tab**

| Option | Description |
|---|---|
| **Show Minimap Icon** | Toggle the minimap button |
| **Show Names on Bars** | Toggle class-colored name labels |
| **Compact Mode** | Collapse bars to icon-only threat-coloured squares (no names) |
| **Flash Bar on Click** | Cast-feedback flash when you click a bar |
| **Show Spell Cooldown Indicators** | Dual cooldown icons flanking the marker row (left & right click spells) |
| **Show Interrupt Button** | Show the secure interrupt button (spell set in Spells tab) |
| **Show Raid Marker Bar** | Show all 8 raid markers below the frame (place/remove toggles) |
| **Show Target/Focus Taunt Buttons** | Show the secure Target-taunt / Focus-taunt buttons |
| **Use Class Colours on Bars** | Tint each bar with the unit's class colour |
| **Show Self** | Toggle your own button in the group list (session-only, resets on reload) |
| **Hide When Not In Party** | Hide the whole frame when you are solo |
| **Solo: show Target bar** | When ungrouped, show a single live threat/health bar for your target |
| **Hide DPS In Raid** | In raids, only show tanks and healers |
| **Lock Frame** | Lock/unlock frame position (green border when unlocked) |
| **Marker Button Size** | Size of the raid-marker buttons (12–40 px) |
| **Interrupt Button Size** | Size of the interrupt / taunt buttons (12–40 px) |

**Spells tab** — Left-click spell, Right-click spell, and Interrupt spell, each picked from a filtered scan of your full spellbook (tabs, flyouts, talents, action bars). Your class interrupt is always offered in all three pickers. When **Show Interrupt Button** is off, the Interrupt Spell picker is greyed out with a note and cannot be opened.

**Alerts tab**

| Option | Description |
|---|---|
| **Alert when non-tank pulls** | Flash box + local chat message when a DPS/healer grabs aggro |
| **Show "1st Pull by ..."** | Distinct first-pull notification when someone initiates combat |
| **Announce pull on-screen** | Large on-screen raid-warning banner on pull (replaces the old combat-tainted chat announce) |
| **Play sound on pull alert** | Play a sound cue when a pull alert fires |

---

## Troubleshooting

| Problem | Solution |
|---|---|
| No bars showing | Join a party or raid — solo mode shows only your own bar |
| Spells not in dropdown | Type `/tm spells` for a diagnostic dump; try reopening the picker after a moment |
| "Invalid target" | The group member's target may be dead or doesn't exist — this is normal |
| Bars appear but clicks do nothing | Ensure you're out of combat, then `/reload` to rebuild macros |
| Green squares / outlines on buttons | Should not happen in 6.7.0+; the friendly-target indicator that caused this was removed |
| Role icons missing | Some specs have no assigned LFG role; the addon now infers from spec and falls back to DPS |
| Wrong spell after reload | Fixed in 6.3.0 — spells now refresh from SavedVariables on load |
| Pull alert not firing | You must be targeting the mob the non-tank pulled; alert is based on threat healthbar color |
| Pull alert spamming | 5-second debounce per unit is active; if still spamming, disable via Options |
| Raid marker not applying | Select a target first; each button in the marker bar toggles its marker (place/remove). The old single skull button was replaced by the full 8-marker bar in 7.0.0 |
| Interrupt / taunt button does nothing | The macro is set out of combat only; leave combat and `/reload`. Set the interrupt spell in Options → Spells |
| Pull alert not announcing in chat | By design in 7.0.0 — automated combat chat was removed (caused `ADDON_ACTION_BLOCKED`); the announce is now an on-screen raid-warning banner |

Enable Lua error reporting for detailed diagnostics:
```
/console scriptErrors 1
```

---

## Requirements

- World of Warcraft: Midnight Pre-Patch (12.0.0+)
- LibStub (included)
- LibDataBroker-1.1 (included)
- LibDBIcon-1.0 (included)

---

## Credits

Based on **TauntMaster2** by **Tartarusspawn** ([CurseForge](https://www.curseforge.com/wow/addons/taunt-master-2))

Modernized and rewritten

*For Scouse.*

---

## Changelog

### Version 7.2.0
- Class interrupt now also available in the Left Click and Right Click spell pickers (previously interrupt-only)
- Interrupt Spell picker greys out with an explanatory note when "Show Interrupt Button" is disabled

### Version 7.1.0
- Smart per-class starter kit (taunt / useful spell / interrupt), validated against the character’s known spells (spellbook + active talents)
- Not-in-tanking-spec notice (one-time chat message + Options banner)
- Fixed: cold-login spells/icons inert until `/reload`; sticky “?” icons; Options spell icons not refreshing; “Reset Defaults” cross-class contamination; “(None - Clear)” not sticking; right-click duplicating the taunt; solo-target NPC class/role squares; test-mode bar sorting; options window too narrow
- Removed the out-of-range indicator — not achievable under Midnight (12.0) addon-disarmament (range is now an opaque/secret value); `/tm range` kept as a diagnostic

### Version 7.0.0
- Tabbed options window (Layout / Display / Spells / Alerts) — fixed-size, always fits on screen
- Test/config mode (`/tm test [N]` or the Layout tab) to lay out the frame solo
- Whole-frame Scale & Opacity sliders; bar Sort (group / tanks-first / role / name); Compact icon-only mode
- Dual spell cooldown indicators, configurable Interrupt slot, and Target/Focus taunt secure buttons
- Raid-marker bar (all 8 markers, place/remove toggles) replaces the old single skull button
- Cast-feedback flash, pull-alert sound cue, Blizzard Edit Mode integration, and a Solo/world target bar
- Fixed pull-alert `ADDON_ACTION_BLOCKED`: combat chat announce replaced with a local on-screen raid-warning banner (also aligns with Midnight addon-disarmament)

### Version 6.7.0
- Added Tank/Healer/DPS role icons on every bar (not just tanks); falls back to DPS when role is unassigned and infers from spec
- Fixed Show Self being ignored when solo (your bar still appeared even with the toggle off)
- Removed the small green-outlined friendly-target indicator that appeared on bars whose unit was targeting a friendly — confusing visual, full removal including its texture file
- Replaced all `UnitIsUnit` calls with GUID comparison for taint-safety in protected contexts
- Multiple role-icon reliability fixes: stale icon data after roster shrink, atlas/texture loading paths, explicit hide on excess buttons

### Version 6.6.0
- Added "Show Self" option to hide your own button from the group list — useful for tanks who don't need to taunt themselves
- Session-only setting: always resets to shown on each /reload for reliability; untick in Options to hide
- Improved skull marker toggle using SecureHandlerWrapScript for clean state switching without taint
- Improved spell list filtering: dual-purpose spells like Death Coil now appear in the spell picker
- Fixed cooldown tracking to use event-based system (UNIT_SPELLCAST_SUCCEEDED) instead of taint-prone C_Spell.GetSpellCooldown secret values
- Fixed spell buttons not firing by switching click registration to AnyUp (standard for secure action buttons)

### Version 6.5.1
- Fixed skull marker button not working when `ActionButtonUseKeyDown` CVar is OFF (e.g. when GSE is managing rotations)
- Fixed taint issue: removed PreClick hook that was tainting the macrotext attribute, silently blocking secure execution
- Skull button now registers for both AnyDown and AnyUp, matching Blizzard action bar behaviour

### Version 6.5.0
- Added skull marker toggle button above the tank bar header — click to place/remove skull on current target
- Added first-pull detection: distinct "1st Pull by [Name]" flash when someone initiates combat before falling back to normal pull alerts
- Added first-pull notification checkbox in Options (enabled by default)
- All pull alert checkboxes now enabled by default for new installations
- Skull button uses SecureActionButtonTemplate for taint-immune operation

### Version 6.4.0
- Added pull alert system: flashing red banner + local chat message when a non-tank grabs aggro
- Added optional party/instance chat announcement of pulls (/p or /i equivalent)
- New "Pull Alerts" section in Options panel with two toggles
- 5-second debounce per unit prevents alert spam; cleared on roster changes

### Version 6.3.0
- Added out-of-range indicator (red tint overlay when spell target is beyond range)
- Rewrote hostile macros to use `@unittarget` directly — eliminates `/assist` and "Invalid target" errors
- Centralized ADDON_LOADED on header frame — spell dropdowns now refresh from SavedVariables on load
- Fixed double-fire on click (RegisterForClicks changed to AnyDown only)
- Hardened spell filter with explicit blocklist for Fishing, Cooking, Mining, Skinning, and other non-combat spells
- Throttled OnUpdate to ~10 fps for better CPU performance

### Version 6.2.0
- Filtered profession/trade spells from spell picker
- Fixed green squares on buttons (SecureActionButtonTemplate texture suppression)
- Fixed frame lock state not applying on login/reload
- Fixed player names not showing on reload
- Fixed cooldown swipe not rendering (explicit swipe texture for bare Cooldown widgets)

### Version 6.1.0
- Overhauled spell picker to scan full spellbook (tabs, flyouts, talents, action bars)
- Added blessing / friendly spell casting support
- Added dual cooldown overlays (left-click and right-click spells)
- Added show/hide player names option
- Added drag handle and frame position saving
- Fixed cooldown taint errors with native Cooldown:SetCooldown() widget API
- Wiki-verified all WoW API calls for 12.0 compatibility

### Version 6.0.0
- Interface version updated to 120000 for Midnight Pre-Patch 12.0.0
- All embedded libraries updated to latest versions (Ace3, LibDBIcon, LibDataBroker, LibStub)

### Version 5.0.0
- Complete rewrite and modernization for War Within (11.0.5+)
- Added Vengeance Demon Hunter support
- Modernized threat detection using UnitThreatSituation API
- Streamlined codebase from 31,000+ to clean maintainable Lua
- Added spell picker, minimap button, flexible grid layout

---

## License

This addon is a complete rewrite based on the original TauntMaster2 by Tartarusspawn. All new code © 2025–2026.
