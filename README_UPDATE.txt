================================================================================
                TauntMasterMini - MIDNIGHT PRE-PATCH UPDATE
                              Version 6.7.0
           Updated for WoW Midnight Pre-Expansion Patch 12.0.0
================================================================================


WHAT'S NEW IN 6.7.0:
---------------------
1. ROLE ICONS ON EVERY BAR
   Tank / Healer / DPS role icons now appear on every player bar (not just
   tanks).  Uses the LFG role texture sheet with manual SetTexCoord for
   reliable rendering.  When a player has no assigned LFG role, the addon
   infers Tank/Healer from their spec where possible and falls back to DPS
   otherwise.

2. SHOW SELF FIX
   Unticking Show Self while solo now correctly hides your bar.  Previously
   the solo branch added the player unconditionally and ignored the toggle.

3. REMOVED FRIENDLY-TARGET INDICATOR
   The small green-outlined icon that appeared on the right of bars when a
   unit was targeting a friendly has been removed entirely.  It was
   confusing visually (looked like a stray UI glitch) and its texture file
   (tm_friendly_icon8.tga) has been deleted from the addon.

4. TAINT-SAFE GUID COMPARISON
   All UnitIsUnit calls replaced with UnitGUID(a) == UnitGUID(b).
   UnitIsUnit can taint in protected contexts; GUID comparison is safe.

5. ROLE-ICON RELIABILITY FIXES
   - Stale icon data after roster shrink now clears correctly
   - Class and role icons reset before each rebuild
   - Excess buttons explicitly hide their icons when Show Self toggles off
   - Settled on the LFG texture sheet directly after iterating through
     numeric IDs and atlases that had loading quirks


WHAT WAS NEW IN 6.6.0:
-----------------------
1. SHOW SELF OPTION
   New "Show Self" checkbox in the Options menu.  Untick to hide your own
   button from the group list — useful for tanks who don't need to taunt
   themselves.

2. IMPROVED SPELL PICKER
   Dual-purpose spells like Death Coil now appear in the spell list.

3. FIXED SPELL BUTTONS
   Click overlay uses RegisterForClicks('AnyUp') — standard for secure
   action buttons — fixing spells not firing when clicked.

4. FIXED COOLDOWN TRACKING
   Event-based tracking via UNIT_SPELLCAST_SUCCEEDED + GetTime() and known
   spell durations, replacing the taint-prone C_Spell.GetSpellCooldown.

5. IMPROVED SKULL MARKER TOGGLE
   SecureHandlerWrapScript for clean, taint-free state switching.


WHAT WAS NEW IN 6.5.0:
-----------------------
1. SKULL MARKER TOGGLE
   A small skull icon now sits above the tank bar header.  Click it to place
   a skull raid marker (marker 8) on your current target.  Click again to
   remove it.

   - Icon brightens when skull is placed, dims when removed or target changes
   - Uses Blizzard's SecureActionButtonTemplate with /targetmarker macro —
     completely immune to addon taint
   - Tooltip on hover: "Toggle Skull Marker"

2. FIRST-PULL DETECTION
   When the party is not yet in combat and a non-tank grabs aggro first,
   TauntMasterMini shows a distinct notification:

     >> 1st PULL! <<
     [PlayerName]

   Chat prints:  1st Pull by [Name]!
   If party chat announce is enabled, it also sends "1st Pull by [Name]!"
   to the group channel.

   After the first pull is recorded, subsequent pulls during the same combat
   revert to the standard ">> PULL! <<" alerts.  The first-pull tracker
   resets automatically when combat ends.

3. NEW SETTING: FIRST-PULL NOTIFICATION
   Options → Pull Alerts now has three checkboxes:
   - "Alert when non-tank pulls" (flash + local chat)
   - "Show '1st Pull by ...' when someone initiates combat"
   - "Announce pull in party/instance chat"
   All three are ENABLED BY DEFAULT for new installations.


WHAT WAS ADDED IN 6.4.0:
--------------------------
- Pull alert system: flashing red banner + local chat message
- Optional party/instance chat announce
- 5-second debounce per unit prevents alert spam


WHAT WAS ADDED IN 6.3.0:
--------------------------
- Out-of-range red tint indicator on bars
- Rewritten macro system using @<unit>target (no more /assist errors)
- Saved spell fix — selections persist correctly across /reload
- Click reliability — macros fire once on mouse-down only
- Hardened spell filter blocklist (Fishing, Cooking, Mining, etc.)
- OnUpdate throttled to ~10 fps for CPU performance


WHAT WAS ADDED IN 6.1–6.2:
----------------------------
- Full spellbook spell picker (tabs, flyouts, talents, action bars)
- Blessing / friendly spell casting (@unit,help,nodead macros)
- Dual cooldown overlays (left half = left-click spell, right half = right-click)
- Class-colored player names toggle
- Drag handle and per-character frame position saving
- Green square suppression (hooksecurefunc on SecureActionButtonTemplate)
- Cooldown swipe texture fix for bare Cooldown widgets
- Frame lock/unlock state restored on login


FULL FEATURE LIST:
------------------
- Compact party/raid bars with real-time threat coloring
- One-click casting: left-click and right-click configurable spells
- Full spellbook spell picker with combat-relevance filtering
- Dual cooldown sweep overlays (left/right halves)
- Out-of-range red tint indicator
- Show Self toggle: hide your own bar from the group list (session-only)
- Skull marker toggle: place/remove skull on target with one click
- Pull alerts: flashing box + local message + optional party/instance chat
- First-pull detection: distinct "1st Pull by ..." notification
- Class-colored player names
- Role icons (Tank / Healer / DPS) on every bar
- Threat colors: green (none), yellow (high), orange (insecure), red (tanking)
- Adjustable button width (50-200), height (20-60), columns (1-8), rows (1-20)
- Movable frame with drag handle and lock/unlock
- Per-character frame position saving
- Minimap button (left-click = options, right-click = toggle frame)
- Smart macro generation for hostile, helpful, and dual-target spells


TANK SPECS SUPPORTED:
---------------------
✓ Protection Warrior      (Taunt)
✓ Protection Paladin      (Hand of Reckoning)
✓ Blood Death Knight      (Dark Command)
✓ Guardian Druid          (Growl)
✓ Brewmaster Monk         (Provoke)
✓ Vengeance Demon Hunter  (Torment)


SLASH COMMANDS:
---------------
/tm              Open options menu
/tm show         Show TauntMasterMini frame
/tm hide         Hide TauntMasterMini frame
/tm toggle       Toggle frame visibility
/tm lock         Lock frame position
/tm unlock       Unlock frame position
/tm spells       Full spell diagnostic dump
/tm debug        Print button macros for each unit


TESTING AFTER UPDATE:
---------------------
1. Type /reload in-game

2. Look for: "TauntMasterMini v6.7.0" in green text in chat

3. Type /tm — verify options open; check the "Pull Alerts" section at the
   bottom of the panel (three checkboxes, all ticked by default)

4. Look for the small skull icon above the tank bar header:
   - Target an enemy
   - Click the skull icon — a skull marker should appear over the mob
   - The skull icon should brighten
   - Click again — skull removed, icon dims
   - Switch targets — icon resets to dim

5. Join a party:
   - Bars should appear with class-colored names
   - Left-click a bar → should taunt their target (or cast your configured spell)
   - Right-click → should cast secondary spell
   - Bars of out-of-range targets should show red tint
   - Cooldown sweeps should appear after casting

6. Test pull alerts:
   - Have a DPS group member attack before you establish aggro
   - First pull: should see ">> 1st PULL! << [Name]" flash
   - Subsequent pulls: should see ">> PULL! << [Name]" flash
   - Combat ends → first-pull tracker resets for next encounter

7. /tm spells — verify no Fishing, Cooking, or other junk in the list


TROUBLESHOOTING:
----------------
No bars?
  → Must be in a party or raid.  Solo shows only your bar.

Dropdown empty?
  → Type /tm spells for diagnostic.  Reopen picker after a moment.

Wrong spell fires?
  → Fixed in 6.3.0.  If it persists, close options, /reload, reopen.

Skull marker not working?
  → Must have a target selected.  Uses /targetmarker securely.

Pull alert not firing?
  → Alert is based on threat healthbar color — the non-tank must have
    aggro (orange or red bar) to trigger detection.

Pull alert spamming?
  → 5-second debounce is active.  If still an issue, untick
    "Alert when non-tank pulls" in /tm options.

Enable Lua errors:
  /console scriptErrors 1

Reset all saved settings:
  Exit WoW completely.  Delete:
    WTF/Account/<You>/SavedVariables/TauntMasterMini.lua
    WTF/Account/<You>/<Realm>/<Char>/SavedVariables/TauntMasterMini.lua
  Restart WoW.

================================================================================
