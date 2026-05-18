================================================================================
                TauntMasterMini - MIDNIGHT PRE-PATCH UPDATE
                              Version 7.0.0
           Updated for WoW Midnight Pre-Expansion Patch 12.0.0
================================================================================


WHAT'S NEW IN 7.0.0:
---------------------
1. TABBED OPTIONS WINDOW
   Options are now a fixed-size tabbed panel (Layout / Display / Spells /
   Alerts) that always fits on screen, replacing the old single off-screen
   list.

2. TEST / CONFIG MODE
   "/tm test [N]" (or the Layout tab) spawns N randomised dummy bars solo
   (default 5, max 40) so you can lay out the frame without a group.
   "/tm test 0" exits.  Cannot change in combat.

3. LAYOUT & DISPLAY ADDITIONS
   - Whole-frame Scale (50-150 %) and Opacity (20-100 %) sliders
   - Bar Sort: Group order / Tanks first / By role / By name
   - Compact Mode: bars collapse to threat-coloured icon-only squares
   - Solo: optional live "target" threat/health bar when ungrouped
   - Blizzard Edit Mode integration (frame movable in Edit Mode; restores
     your saved lock state on exit)

4. INTERRUPT SLOT + TARGET/FOCUS TAUNT
   Optional secure Interrupt button casts your configured interrupt on your
   target, with its own size slider and interrupt-only spell picker.
   Optional secure Target-taunt and Focus-taunt buttons.  All macros are set
   only from clean, combat-guarded code (never from a tainted click handler).

5. RAID-MARKER BAR (REPLACES THE SINGLE SKULL BUTTON)
   A row of all 8 raid markers below the frame, each a place/remove toggle
   with bright/dim feedback.  The old standalone top-centre skull button is
   gone; "Skull Marker Size" is now "Marker Button Size".

6. DUAL SPELL COOLDOWN INDICATORS
   Event-based cooldown icons for the left- and right-click spells flanking
   the marker row.  No secret-value reads (uses UNIT_SPELLCAST_SUCCEEDED +
   GetTime() + a known-duration table).

7. CAST FLASH + PULL SOUND
   Optional cast-feedback flash on bar click; optional sound cue on pull
   alert.

8. PULL-ALERT ADDON_ACTION_BLOCKED FIX
   The optional pull announce called the protected SendChatMessage from a
   tainted combat event handler, causing ADDON_ACTION_BLOCKED.  It has been
   replaced with a local on-screen raid-warning banner.  This also aligns
   with Midnight addon-disarmament (no protected combat chat from addon
   Lua).

NOTE: Interface version is unchanged (120000).  Keybindings were attempted
but reverted (Bindings.xml would not register on the test client).


WHAT WAS NEW IN 6.7.0:
-----------------------
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
   (Superseded in 7.0.0 by the full raid-marker bar.)


WHAT WAS NEW IN 6.5.0:
-----------------------
1. SKULL MARKER TOGGLE
   A small skull icon above the tank bar header to place/remove marker 8 on
   your target.  (Superseded in 7.0.0 by the full 8-marker raid-marker bar.)

2. FIRST-PULL DETECTION
   When the party is not yet in combat and a non-tank grabs aggro first,
   TauntMasterMini shows a distinct notification:

     >> 1st PULL! <<
     [PlayerName]

   After the first pull is recorded, subsequent pulls during the same combat
   revert to the standard ">> PULL! <<" alerts.  The first-pull tracker
   resets automatically when combat ends.

3. FIRST-PULL NOTIFICATION SETTING
   Added the first-pull checkbox alongside the existing pull-alert toggles.


WHAT WAS ADDED IN 6.4.0:
--------------------------
- Pull alert system: flashing red banner + local chat message
- 5-second debounce per unit prevents alert spam
  (The party/instance chat announce added here was removed in 7.0.0 — see
   the ADDON_ACTION_BLOCKED fix above.)


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
- Dual cooldown overlays
- Class-colored player names toggle
- Drag handle and per-character frame position saving
- Green square suppression (hooksecurefunc on SecureActionButtonTemplate)
- Cooldown swipe texture fix for bare Cooldown widgets
- Frame lock/unlock state restored on login


FULL FEATURE LIST (7.0.0):
--------------------------
- Compact party/raid bars with real-time threat coloring
- One-click casting: left-click and right-click configurable spells
- Full spellbook spell picker with combat-relevance filtering
- Dual event-based spell cooldown indicators
- Out-of-range red tint indicator
- Tabbed options (Layout / Display / Spells / Alerts)
- Frame Scale & Opacity sliders
- Bar Sort (group / tanks-first / role / name) and Compact icon-only mode
- Test/config mode (/tm test [N]) for solo layout tuning
- Show Self toggle (session-only); Solo target bar; Hide-when-solo;
  Hide DPS in raid
- Raid-marker bar: all 8 markers below the frame, place/remove toggles
- Interrupt slot and Target/Focus taunt secure buttons (size sliders)
- Pull alerts: flashing box + local message + optional on-screen
  raid-warning banner + optional sound cue
- First-pull detection: distinct "1st Pull by ..." notification
- Class-colored player names; class & role icons (Tank/Healer/DPS) on every bar
- Threat colors: green (none), yellow (high), orange (insecure), red (tanking)
- Adjustable button width (50-200), height (20-60), columns (1-8), rows (1-20)
- Movable frame with drag handle, lock/unlock, Blizzard Edit Mode integration
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
/tm test [N]     Spawn N dummy bars solo (default 5, max 40); /tm test 0
                 exits (out of combat only)


TESTING AFTER UPDATE:
---------------------
1. Type /reload in-game

2. Look for: "TauntMasterMini v7.0.0" in green text in chat

3. Type /tm — verify the tabbed options window opens (Layout / Display /
   Spells / Alerts) and fits on screen.  Check the Alerts tab toggles.

4. Layout tab → use the Test bars control (or /tm test 5) solo:
   - Dummy bars appear with randomised class/role
   - Tune width/height/columns/scale/opacity/sort, then /tm test 0

5. Display tab → enable the Raid Marker Bar:
   - Target an enemy
   - Click a marker button — the marker should appear over the mob and the
     button should brighten; click again to remove (button dims)
   - Optionally enable the Interrupt and Target/Focus taunt buttons

6. Join a party:
   - Bars appear with class-colored names and role icons
   - Left-click a bar → casts your primary spell on their target
   - Right-click → secondary spell
   - Out-of-range targets show a red tint
   - Cooldown indicators update after you cast

7. Test pull alerts:
   - Have a DPS group member attack before you establish aggro
   - First pull: ">> 1st PULL! << [Name]" flash
   - Subsequent pulls: ">> PULL! << [Name]" flash
   - With "Announce pull on-screen" on, a large raid-warning banner shows
   - Combat ends → first-pull tracker resets

8. /tm spells — verify no Fishing, Cooking, or other junk in the list

9. (Paranoid) /console taintLog 2, reproduce, then check Logs/taint.log —
   expect no new TauntMasterMini taint entries.


TROUBLESHOOTING:
----------------
No bars?
  → Must be in a party or raid.  Solo shows only your bar (or the Solo
    target bar if enabled).

Dropdown empty?
  → Type /tm spells for diagnostic.  Reopen picker after a moment.

Wrong spell fires?
  → Fixed in 6.3.0.  If it persists, close options, /reload, reopen.

Raid marker not applying?
  → Must have a target selected.  Each marker button toggles its marker
    via /targetmarker securely.

Interrupt / taunt button does nothing?
  → Macro is set out of combat only.  Leave combat and /reload.  Set the
    interrupt spell in Options → Spells.

Pull alert not announcing in chat?
  → By design in 7.0.0 — automated combat chat was removed (it triggered
    ADDON_ACTION_BLOCKED).  Enable "Announce pull on-screen" for the
    raid-warning banner instead.

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
