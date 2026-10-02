/*
*  CSGO Score Bar 2.0 (sprite version)
*
*  A CS:GO style bar at the top of the screen, drawn as a sprite on the HUD:
*
*      [ CT 3 ]   [ TUR 6 ]   [ TE 2 ]       blue / dark / orange
*
*  Left the CT round wins, right the T round wins, in the middle the round number (rounds
*  played + 1). The scores come from the game's own "TeamScore" event.
*
*  The bar is a single sprite per player, so there has to be one sprite for every pair of scores:
*  (sb_maxscore + 1) ^ 2 files, 256 with the default 15. The plugin writes them itself at every
*  map start (sprites/sb_<ct>_<t>.spr) and the clients download them, around 1.4 MB.
*  A sprite that is always on screen makes sprites_on_hud resend the weapon HUD messages on
*  every shot, that costs some smoothness (accepted for this plugin).
*
*  Needs: sprites_on_hud.amxx and hud_manager.amxx, loaded in this order before this plugin.
*  The bar uses the base slot of the HUD Manager: other icons (welcome banner, warnings) take
*  its place for a few seconds and the bar comes back by itself.
*
*  Cvars (server.cfg, they are read when the sprites are built at map start):
*    sb_enabled   1       the bar
*    sb_maxscore  15      highest score the bar can show (4..15), higher scores stay at the maximum
*    sb_label_ct  "CT"    text before the CT score  (letters A-Z, up to 4)
*    sb_label_t   "TE"    text before the T score
*    sb_label_rnd "TUR"   text before the round number
*/

#define VERSION "2.0"

#include <amxmodx>
#include <hud_manager>

#define BAR_W 192
#define BAR_H 24
#define BLOCK_W 64

#define SB_OFFSET_Y -212
#define SB_ABSOLUTE_MAX 15

#define PAL_WHITE 1
#define PAL_BLUE 2
#define PAL_ORANGE 3
#define PAL_DARK 4

// 5x7 digits, one row per entry, bit 4 is the leftmost pixel
new const g_digits[10][7] =
{
	{ 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E },
	{ 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E },
	{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F },
	{ 0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E },
	{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 },
	{ 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E },
	{ 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E },
	{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
	{ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E },
	{ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C }
}

// 5x7 letters A-Z
new const g_letters[26][7] =
{
	{ 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
	{ 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E },
	{ 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E },
	{ 0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E },
	{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F },
	{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10 },
	{ 0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F },
	{ 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
	{ 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E },
	{ 0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C },
	{ 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 },
	{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F },
	{ 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11 },
	{ 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 },
	{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
	{ 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 },
	{ 0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D },
	{ 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11 },
	{ 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E },
	{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
	{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
	{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04 },
	{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11 },
	{ 0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11 },
	{ 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04 },
	{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F }
}

new g_canvas[BAR_W * BAR_H]

new HudSprite:g_sprite[SB_ABSOLUTE_MAX + 1][SB_ABSOLUTE_MAX + 1]
new g_score_ct, g_score_t, g_max_score, g_last_index = -1
new bool:g_ready

new cvar_enabled, cvar_maxscore
new cvar_label_ct[8], cvar_label_t[8], cvar_label_round[8]

/* ------------------------------------------------------------------ */
/* Precache: build and register the sprites                            */
/* ------------------------------------------------------------------ */

public plugin_precache()
{
	bind_pcvar_num(register_cvar("sb_enabled", "1"), cvar_enabled)
	bind_pcvar_num(register_cvar("sb_maxscore", "15"), cvar_maxscore)
	bind_pcvar_string(register_cvar("sb_label_ct", "CT"), cvar_label_ct, charsmax(cvar_label_ct))
	bind_pcvar_string(register_cvar("sb_label_t", "TE"), cvar_label_t, charsmax(cvar_label_t))
	bind_pcvar_string(register_cvar("sb_label_rnd", "TUR"), cvar_label_round, charsmax(cvar_label_round))

	if(!cvar_enabled)
		return

	g_max_score = clamp(cvar_maxscore, 4, SB_ABSOLUTE_MAX)

	static name[32], ct, t

	for(ct = 0; ct <= g_max_score; ct++)
	{
		for(t = 0; t <= g_max_score; t++)
		{
			render_bar(ct, t)

			formatex(name, charsmax(name), "sb_%d_%d", ct, t)
			write_sprite(name)

			g_sprite[ct][t] = HS_PrecacheSprite(name, 0, SB_OFFSET_Y)
		}
	}

	g_ready = true
}

public plugin_init()
{
	register_plugin("CSGO Score Bar", VERSION, "Biohazard")

	register_event("TeamScore", "event_teamscore", "a")
	register_event("TextMsg", "event_restart", "a", "2=#Game_Commencing", "2=#Game_will_restart_in")
}

public client_putinserver(id)
{
	// Slightly later, when the player is fully in the game
	set_task(2.0, "task_show", id)
}

public client_disconnected(id)
	remove_task(id)

public task_show(id)
	draw_bar(id)

/* ------------------------------------------------------------------ */
/* Scores                                                              */
/* ------------------------------------------------------------------ */

// "TeamScore" is sent by the game whenever a team's round wins change
public event_teamscore()
{
	static team[2]
	read_data(1, team, charsmax(team))

	if(team[0] == 'C')
		g_score_ct = read_data(2)
	else if(team[0] == 'T')
		g_score_t = read_data(2)

	draw_all()
}

public event_restart()
{
	g_score_ct = 0
	g_score_t = 0
	draw_all()
}

draw_all()
{
	if(!g_ready)
		return

	static index
	index = min(g_score_ct, g_max_score) * 100 + min(g_score_t, g_max_score)

	// Nothing to resend when the shown numbers did not change
	if(index == g_last_index)
		return

	g_last_index = index

	for(new id = 1; id <= MaxClients; id++)
		draw_bar(id)
}

draw_bar(id)
{
	if(!g_ready || !is_user_connected(id))
		return

	HM_SetStatus(id, HM_SLOT_BASE, g_sprite[min(g_score_ct, g_max_score)][min(g_score_t, g_max_score)])
}

/* ------------------------------------------------------------------ */
/* Sprite generator                                                    */
/* ------------------------------------------------------------------ */

cv_set(x, y, color)
{
	if(x >= 0 && x < BAR_W && y >= 0 && y < BAR_H)
		g_canvas[y * BAR_W + x] = color
}

cv_rect(x0, y0, x1, y1, color)
{
	for(new y = y0; y <= y1; y++)
	{
		for(new x = x0; x <= x1; x++)
			cv_set(x, y, color)
	}
}

// One 5x7 glyph, rows[] has 7 entries
cv_glyph(const rows[], x, y, scale, color)
{
	for(new row = 0; row < 7; row++)
	{
		for(new col = 0; col < 5; col++)
		{
			if(rows[row] & (1 << (4 - col)))
				cv_rect(x + col * scale, y + row * scale, x + col * scale + scale - 1, y + row * scale + scale - 1, color)
		}
	}
}

// Width of a text in pixels
text_width(const text[], scale)
{
	new count
	while(text[count])
		count++

	return count ? count * 6 * scale - scale : 0
}

// Letters A-Z (any case), everything else is an empty space
cv_text(const text[], x, y, scale, color)
{
	new c

	for(new i = 0; text[i]; i++)
	{
		c = text[i]

		if(c >= 'a' && c <= 'z')
			c -= 32

		if(c >= 'A' && c <= 'Z')
			cv_glyph(g_letters[c - 'A'], x, y, scale, color)

		x += 6 * scale
	}
}

// A one or two digit number
cv_number(number, x, y, scale, color)
{
	if(number >= 10)
	{
		cv_glyph(g_digits[(number / 10) % 10], x, y, scale, color)
		x += 6 * scale
	}

	cv_glyph(g_digits[number % 10], x, y, scale, color)
}

number_width(number, scale)
	return (number >= 10) ? 11 * scale : 5 * scale

// A block: label and number side by side, centered in the block
cv_block(const label[], number, block, color)
{
	new left = block * BLOCK_W
	new label_w = text_width(label, 1)
	new total = label_w + 5 + number_width(number, 2)
	new x = left + (BLOCK_W - total) / 2

	cv_rect(left, 0, left + BLOCK_W - 1, BAR_H - 1, color)
	cv_text(label, x, (BAR_H - 7) / 2, 1, PAL_WHITE)
	cv_number(number, x + label_w + 5, (BAR_H - 14) / 2, 2, PAL_WHITE)
}

render_bar(ct, t)
{
	arrayset(g_canvas, PAL_DARK, BAR_W * BAR_H)

	cv_block(cvar_label_ct, ct, 0, PAL_BLUE)
	cv_block(cvar_label_round, min(ct + t + 1, 99), 1, PAL_DARK)
	cv_block(cvar_label_t, t, 2, PAL_ORANGE)

	// Thin light line on the top edge of the middle block, like the CS:GO round box
	cv_rect(BLOCK_W, 0, BLOCK_W * 2 - 1, 0, PAL_WHITE)
}

// Single frame, 8-bit paletted, alpha test sprite
write_sprite(const name[])
{
	static path[64], palette[768], header[4], bool:ready

	formatex(path, charsmax(path), "sprites/%s.spr", name)

	new file = fopen(path, "wb")
	if(!file)
	{
		log_amx("Could not write %s, the score bar will be missing", path)
		return
	}

	if(!ready)
	{
		ready = true

		palette[PAL_WHITE * 3] = 255, palette[PAL_WHITE * 3 + 1] = 255, palette[PAL_WHITE * 3 + 2] = 255
		palette[PAL_BLUE * 3] = 70, palette[PAL_BLUE * 3 + 1] = 120, palette[PAL_BLUE * 3 + 2] = 230
		palette[PAL_ORANGE * 3] = 235, palette[PAL_ORANGE * 3 + 1] = 140, palette[PAL_ORANGE * 3 + 2] = 30
		palette[PAL_DARK * 3] = 45, palette[PAL_DARK * 3 + 1] = 48, palette[PAL_DARK * 3 + 2] = 58
	}

	header[0] = 'I', header[1] = 'D', header[2] = 'S', header[3] = 'P'
	fwrite_blocks(file, header, 4, BLOCK_BYTE)

	fwrite(file, 2, BLOCK_INT)                  // version
	fwrite(file, 2, BLOCK_INT)                  // type: vp_parallel
	fwrite(file, 3, BLOCK_INT)                  // texture format: alpha test
	fwrite(file, _:(floatsqroot(float(BAR_W * BAR_W + BAR_H * BAR_H)) / 2.0), BLOCK_INT) // bounding radius
	fwrite(file, BAR_W, BLOCK_INT)              // width
	fwrite(file, BAR_H, BLOCK_INT)              // height
	fwrite(file, 1, BLOCK_INT)                  // frames
	fwrite(file, 0, BLOCK_INT)                  // beam length
	fwrite(file, 0, BLOCK_INT)                  // sync type
	fwrite(file, 256, BLOCK_SHORT)              // palette colors
	fwrite_blocks(file, palette, 768, BLOCK_BYTE)

	fwrite(file, 0, BLOCK_INT)                  // frame group
	fwrite(file, -BAR_W / 2, BLOCK_INT)         // origin x
	fwrite(file, BAR_H / 2, BLOCK_INT)          // origin y
	fwrite(file, BAR_W, BLOCK_INT)
	fwrite(file, BAR_H, BLOCK_INT)
	fwrite_blocks(file, g_canvas, BAR_W * BAR_H, BLOCK_BYTE)

	fclose(file)
}
