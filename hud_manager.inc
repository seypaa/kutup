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
#define HM_SLOT_LAST  6

/**
 * Sets the status sprite of a slot for a player. InvalidHudSprite clears the slot.
 * The sprite handle comes from HS_PrecacheSprite() and has to be created in plugin_precache.
 *
 * @param id        Player index
 * @param slot      HM_SLOT_FIRST .. HM_SLOT_LAST
 * @param sprite    Handle from HS_PrecacheSprite()
 *
 * @return          true on success
 */
native bool:HM_SetStatus(id, slot, HudSprite:sprite)

/**
 * Clears the status sprite of a slot for a player.
 *
 * @return          true on success
 */
native bool:HM_ClearStatus(id, slot)
