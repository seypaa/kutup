#if defined _sprites_on_hud_included
	#endinput
#endif
#define _sprites_on_hud_included

/**
 * A registered sprite, returned by HS_PrecacheSprite() and passed to HS_DrawSprite().
 */
enum HudSprite
{
	InvalidHudSprite = -1
}

/**
 * Registers a sprite at a screen position. Must be called from plugin_precache().
 *
 * Reads sprites/<SpriteName>.spr for its dimensions, precaches it, then writes and
 * precaches the HUD definition that positions it.
 *
 * OffsetX and OffsetY shift the image from the centre of the screen, in pixels, right
 * and down positive. They are written into the generated txt file, so register once for each 
 * position you need.
 *
 * Keep the shifted image on screen: a sprite of Size shifted by Offset needs
 * Size / 2 + Offset pixels of room from the centre.
 *
 * @param SpriteName    Sprite file name, without the sprites/ prefix or the .spr suffix
 * @param OffsetX       Horizontal shift from centre, in pixels, right positive
 * @param OffsetY       Vertical shift from centre, in pixels, down positive
 *
 * @return              A sprite handle, or InvalidHudSprite on error.
 */
native HudSprite:HS_PrecacheSprite(const SpriteName[], OffsetX = 0, OffsetY = 0)

/**
 * Shows a sprite to one player, replacing whatever sprite they were shown before.
 *
 * A player who is dead or zoomed does not see the sprite right away. It is shown on the
 * next weapon or field of view update.
 *
 * @param id            Player index
 * @param Sprite        Handle from HS_PrecacheSprite()
 *
 * @return              true if the request succeeded, false on failure
 */
native bool:HS_DrawSprite(id, HudSprite:Sprite)

/**
 * Removes the sprite from a player and restores their real weapon HUD, which brings
 * back that weapon's own crosshair or scope.
 *
 * @param id            Player index
 *
 * @return              true on success, false otherwise
 */
native bool:HS_ClearSprite(id)
