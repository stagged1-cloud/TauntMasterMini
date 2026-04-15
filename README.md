# TauntMasterMini

**Version 6.6.0** | Updated for World of Warcraft: Midnight Pre-Patch (12.0.0)

A lightweight threat utility for tanks that shows live threat bars, one-click spell casting, full spellbook spell selection, cooldown overlays, out-of-range warnings, and smart group targeting in a compact, movable frame.

### What’s new in 6.6.0
- Added **Show Self** option to hide your own button from the group list
- Improved skull marker toggle and secure click handling
- Fixed spell button reliability and dual-purpose spell picker entries

### Core features
- Real-time color-coded threat bars for party/raid up to 40 players
- Left/right click casts with automatic enemy/friendly targeting
- Full spellbook scan including tabs, flyouts, talents, and action bars
- Smart filter blocks profession/non-combat spells like Fishing and Mining
- Dual cooldown overlays and red out-of-range tint
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

---

## How to Use

1. **Join a group** — The addon automatically creates a bar for each party/raid member
2. **Monitor threat** — Watch health bar colors change in real-time as threat shifts
3. **Click to cast** — Left-click a bar to cast your primary spell; right-click for your secondary spell
4. **Check range** — A red tint on a bar means the target is out of range
5. **Watch cooldowns** — The dark clock-sweep on each bar shows when your spells are ready
6. **Customize** — Type `/tm` to adjust sizes, spells, layout, and display options

---

## Configuration Options

Access via `/tm` or left-click the minimap button:

| Option | Description |
|---|---|
| **Button Width** | Horizontal size of each player bar (50–200 px) |
| **Button Height** | Vertical size of each player bar (20–60 px) |
| **Units Per Column** | How many bars per column before wrapping (1–20) |
| **Max Columns** | Maximum columns to display (1–8) |
| **Left Click Spell** | Spell cast on left-click (picked from your spellbook) |
| **Right Click Spell** | Spell cast on right-click (picked from your spellbook) |
| **Show Minimap Icon** | Toggle the minimap button |
| **Show Cooldowns** | Toggle cooldown sweep overlays on bars |
| **Show Player Names** | Toggle class-colored name labels |
| **Show Self** | Toggle your own button in the group list (session-only, resets on reload) |
| **Lock Frame** | Lock/unlock frame position (green border when unlocked) |
| **Alert when non-tank pulls** | Flash box + local chat message when a DPS/healer grabs aggro |
| **Show "1st Pull by ..."** | Distinct first-pull notification when someone initiates combat |
| **Announce pull in party/instance chat** | Broadcasts the pull message to party, instance, or raid chat |

---

## Troubleshooting

| Problem | Solution |
|---|---|
| No bars showing | Join a party or raid — solo mode shows only your own bar |
| Spells not in dropdown | Type `/tm spells` for a diagnostic dump; try reopening the picker after a moment |
| "Invalid target" | The group member's target may be dead or doesn't exist — this is normal |
| Bars appear but clicks do nothing | Ensure you're out of combat, then `/reload` to rebuild macros |
| Green squares on buttons | Should not happen in 6.5.0; if seen, `/reload` once more |
| Wrong spell after reload | Fixed in 6.3.0 — spells now refresh from SavedVariables on load |
| Pull alert not firing | You must be targeting the mob the non-tank pulled; alert is based on threat healthbar color |
| Pull alert spamming | 5-second debounce per unit is active; if still spamming, disable via Options |
| Skull marker not working | Must have a target selected; if using GSE or any addon that sets `ActionButtonUseKeyDown` OFF, update to 6.5.1+ which handles both CVar states |

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

Modernized and rewritten by **Don Thompson (Haruspex)**

*For Scouse.*

---

## Changelog

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

This addon is a complete rewrite based on the original TauntMaster2 by Tartarusspawn. All new code © 2025–2026 Don Thompson.
