#if defined _hud_manager_included
	#endinput
#endif
#define _hud_manager_included

#include <sprites_on_hud>

#if !defined HM_PROVIDER
	#pragma reqlib hud_manager
#endif

/**
 * HUD Manager
 *
 * sprites_on_hud can only show ONE sprite per player at a time. The HUD Manager sits on top
 * of it so that several plugins can have a status sprite at the same moment: every plugin
 * owns a slot, the manager shows the active sprites one after another (every few seconds)
 * and the welcome banner is shown alone while it is active.
 *
 * Load order in plugins.ini: sprites_on_hud, hud_manager, then the plugins that use it.
 */

/* Slots available to other plugins, share them out between your plugins */
#define HM_SLOT_FIRST 1
#define HM_SLOT_LAST  5

/* Base layer: shown whenever no other slot has a sprite (for a permanent HUD element like a score
 * bar). It never takes part in the turn taking, the other icons simply cover it while they last. */
#define HM_SLOT_BASE  6

/**
 * Sets the status sprite of a slot for a player. InvalidHudSprite clears the slot.
 * The sprite handle comes from HS_PrecacheSprite() and has to be created in plugin_precache.
 *
 * @param id        Player index
 * @param slot      HM_SLOT_FIRST .. HM_SLOT_LAST, or HM_SLOT_BASE
 * @param sprite    Handle from HS_PrecacheSprite()
 * @param duration  Seconds until the slot clears itself, 0.0 keeps it until you clear it.
 *                  Prefer short durations: while a sprite is on screen sprites_on_hud has to
 *                  resend the weapon HUD messages on every weapon update (every shot), so a
 *                  sprite that is always visible costs network traffic and client prediction.
 *
 * @return          true on success
 */
native bool:HM_SetStatus(id, slot, HudSprite:sprite, Float:duration = 0.0)

/**
 * Clears the status sprite of a slot for a player.
 *
 * @return          true on success
 */
native bool:HM_ClearStatus(id, slot)
