/*
*  HUD Manager 1.0
*
*  Standalone, works on any Counter-Strike 1.6 server (no zombie mod needed).
*  Requires: AMX Mod X 1.9+ and sprites_on_hud.amxx (loaded BEFORE this plugin).
*
*  - Welcome banner on the first spawn after joining
*  - Live scoreboard: alive T against alive CT (or ZOMBI / INSAN labels for zombie mods,
*    where the zombies are on the T side)
*  - Slots for other plugins (see hud_manager.inc): sprites_on_hud shows one sprite per
*    player, this plugin takes turns between everything that is active
*
*  The sprites are written by the plugin itself at every map start, nothing has to be copied.
*
*  Cvars (set them in server.cfg, the sprites are built from them at map start):
*    hm_welcome  6.0   seconds the welcome banner stays, 0 disables it
*    hm_score    1     live scoreboard
*    hm_labels   0     0 = T / CT, 1 = ZOMBI / INSAN
*    hm_score_time 4.0 seconds the board stays after a change, 0 = always visible (heavier)
*  Player command: /hud toggles the icons for that player.
*/

#define VERSION "1.0"

#include <amxmodx>
#include <hamsandwich>
#define HM_PROVIDER
#include <hud_manager>

#define SLOT_WELCOME 0
#define SLOT_BASE 6
#define SLOT_SCORE 7
#define SLOT_COUNT 8

#define OFFSET_WELCOME_Y -90
#define OFFSET_SCORE_Y -190

#define TASKID_WELCOME 100
#define TASKID_SLOT 1000 // + id * SLOT_COUNT + slot

// Sprite canvas
#define ICON_BUFFER (216 * 48)

#define PAL_WHITE 1
#define PAL_RED 2
#define PAL_YELLOW 3
#define PAL_GREEN 4
#define PAL_ORANGE 5
#define PAL_NONE 255

// 5x7 digit font, one row per entry, bit 4 is the leftmost pixel
new const g_font[10][7] =
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

// Letters (5x7, row 0 holds the dot of the Turkish I, row 8 the cedilla)
// ids: 0 A, 1 C, 2 D, 3 E, 4 G, 5 H, 6 I, 7 L, 8 M, 9 N, 10 O, 11 S, 12 U, 13 Z, 14 S-cedilla,
//      15 dotted I, 16 B, 17 T
new const g_letters[18][9] =
{
	{ 0x00, 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11, 0x00 },
	{ 0x00, 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E, 0x00 },
	{ 0x00, 0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E, 0x00 },
	{ 0x00, 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F, 0x00 },
	{ 0x00, 0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F, 0x00 },
	{ 0x00, 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11, 0x00 },
	{ 0x00, 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E, 0x00 },
	{ 0x00, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F, 0x00 },
	{ 0x00, 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11, 0x00 },
	{ 0x00, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11, 0x00 },
	{ 0x00, 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E, 0x00 },
	{ 0x00, 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E, 0x00 },
	{ 0x00, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E, 0x00 },
	{ 0x00, 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F, 0x00 },
	{ 0x00, 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E, 0x04 },
	{ 0x04, 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E, 0x00 },
	{ 0x00, 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E, 0x00 },
	{ 0x00, 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x00 }
}

// SUNUCUMUZA / HOSGELDINIZ
new const g_welcome_line1[] = { 11, 12, 9, 12, 1, 12, 8, 12, 13, 0 }
new const g_welcome_line2[] = { 5, 10, 14, 4, 3, 7, 2, 15, 9, 15, 13 }

// Scoreboard labels
new const g_label_t[] = { 17 }
new const g_label_ct[] = { 1, 17 }
new const g_label_zombi[] = { 13, 10, 8, 16, 15 }
new const g_label_insan[] = { 15, 9, 11, 0, 9 }

new g_icon[ICON_BUFFER], g_icon_w, g_icon_h

new HudSprite:g_sprite_welcome, HudSprite:g_sprite_score[10][10]
new HudSprite:g_status[33][SLOT_COUNT], HudSprite:g_shown[33], g_rotation[33]
new bool:g_hidden[33], bool:g_welcome_pending[33]
new g_last_score = -1

new Float:cvar_welcome, cvar_score, cvar_labels, Float:cvar_score_time

/* ------------------------------------------------------------------ */
/* Precache: build and register the sprites                            */
/* ------------------------------------------------------------------ */

public plugin_precache()
{
	bind_pcvar_float(register_cvar("hm_welcome", "6.0"), cvar_welcome)
	bind_pcvar_num(register_cvar("hm_score", "1"), cvar_score)
	bind_pcvar_num(register_cvar("hm_labels", "0"), cvar_labels)
	bind_pcvar_float(register_cvar("hm_score_time", "4.0"), cvar_score_time)

	generate_sprites()

	static name[32], i, j

	g_sprite_welcome = HS_PrecacheSprite("hm_welcome", 0, OFFSET_WELCOME_Y)

	for(i = 0; i < 10; i++)
	{
		for(j = 0; j < 10; j++)
		{
			formatex(name, charsmax(name), "hm_sb_%d_%d", i, j)
			g_sprite_score[i][j] = HS_PrecacheSprite(name, 0, OFFSET_SCORE_Y)
		}
	}
}

public plugin_init()
{
	register_plugin("HUD Manager", VERSION, "Biohazard")

	register_clcmd("say /hud", "cmd_hud")
	RegisterHamPlayer(Ham_Spawn, "player_spawn_post", 1)

	for(new id = 0; id <= MaxClients; id++)
		reset_player(id)

	set_task(3.0, "task_rotate", _, _, _, "b")
	set_task(0.25, "task_score", _, _, _, "b")
}

public plugin_natives()
{
	register_library("hud_manager")
	register_native("HM_SetStatus", "native_set_status")
	register_native("HM_ClearStatus", "native_clear_status")
}

public client_putinserver(id)
{
	reset_player(id)
	g_hidden[id] = false
	g_welcome_pending[id] = true
}

public client_disconnected(id)
{
	remove_task(TASKID_WELCOME + id)
	reset_player(id)
	g_welcome_pending[id] = false
}

reset_player(id)
{
	for(new slot = 0; slot < SLOT_COUNT; slot++)
		g_status[id][slot] = InvalidHudSprite

	g_shown[id] = InvalidHudSprite
	g_rotation[id] = 0
}

/* ------------------------------------------------------------------ */
/* Natives                                                             */
/* ------------------------------------------------------------------ */

public bool:native_set_status(plugin, params)
{
	new id = get_param(1), slot = get_param(2)

	if(id < 1 || id > MaxClients || slot < HM_SLOT_FIRST || slot > HM_SLOT_BASE)
		return false

	set_status(id, slot, HudSprite:get_param(3), Float:get_param_f(4))
	return true
}

public bool:native_clear_status(plugin, params)
{
	new id = get_param(1), slot = get_param(2)

	if(id < 1 || id > MaxClients || slot < HM_SLOT_FIRST || slot > HM_SLOT_BASE)
		return false

	set_status(id, slot, InvalidHudSprite)
	return true
}

/* ------------------------------------------------------------------ */
/* Manager                                                             */
/* ------------------------------------------------------------------ */

set_status(id, slot, HudSprite:sprite, Float:duration = 0.0)
{
	if(g_status[id][slot] == sprite)
		return

	// A new sprite replaces the old one and its timer
	remove_task(TASKID_SLOT + id * SLOT_COUNT + slot)

	g_status[id][slot] = sprite

	if(sprite != InvalidHudSprite && duration > 0.0)
		set_task(duration, "task_slot_expire", TASKID_SLOT + id * SLOT_COUNT + slot)

	refresh(id)
}

public task_slot_expire(taskid)
{
	taskid -= TASKID_SLOT
	set_status(taskid / SLOT_COUNT, taskid % SLOT_COUNT, InvalidHudSprite)
}

// Welcome banner alone, otherwise the active sprites in turns
refresh(id)
{
	if(!is_user_connected(id) || is_user_bot(id))
		return

	static HudSprite:list[SLOT_COUNT], HudSprite:target, count, slot
	count = 0

	if(!g_hidden[id])
	{
		for(slot = 1; slot < SLOT_COUNT; slot++)
		{
			if(slot != SLOT_BASE && g_status[id][slot] != InvalidHudSprite)
				list[count++] = g_status[id][slot]
		}
	}

	// Welcome banner alone, then the active icons in turns, the base layer when nothing else is active
	if(!g_hidden[id] && g_status[id][SLOT_WELCOME] != InvalidHudSprite)
		target = g_status[id][SLOT_WELCOME]
	else if(count)
		target = list[g_rotation[id] % count]
	else if(!g_hidden[id])
		target = g_status[id][SLOT_BASE]
	else
		target = InvalidHudSprite

	if(target == g_shown[id])
		return

	if(target == InvalidHudSprite)
		HS_ClearSprite(id)
	else
		HS_DrawSprite(id, target)

	g_shown[id] = target
}

public task_rotate()
{
	static id, slot, active

	for(id = 1; id <= MaxClients; id++)
	{
		if(!is_user_connected(id) || g_status[id][SLOT_WELCOME] != InvalidHudSprite)
			continue

		active = 0

		for(slot = 1; slot < SLOT_COUNT; slot++)
		{
			if(slot != SLOT_BASE && g_status[id][slot] != InvalidHudSprite)
				active++
		}

		if(active > 1)
		{
			g_rotation[id]++
			refresh(id)
		}
	}
}

public cmd_hud(id)
{
	g_hidden[id] = !g_hidden[id]
	refresh(id)

	client_print(id, print_chat, "[HUD] Icons %s.", g_hidden[id] ? "disabled" : "enabled")
	return PLUGIN_HANDLED
}

/* ------------------------------------------------------------------ */
/* Welcome banner                                                      */
/* ------------------------------------------------------------------ */

public player_spawn_post(id)
{
	if(!g_welcome_pending[id] || !is_user_alive(id) || cvar_welcome <= 0.0)
		return HAM_IGNORED

	g_welcome_pending[id] = false

	set_status(id, SLOT_WELCOME, g_sprite_welcome)

	remove_task(TASKID_WELCOME + id)
	set_task(cvar_welcome, "task_welcome_end", TASKID_WELCOME + id)

	return HAM_IGNORED
}

public task_welcome_end(taskid)
	set_status(taskid - TASKID_WELCOME, SLOT_WELCOME, InvalidHudSprite)

/* ------------------------------------------------------------------ */
/* Live scoreboard                                                     */
/* ------------------------------------------------------------------ */

// Alive T against alive CT, 0-8 exact and 9 means "9 or more".
// The board pops up for hm_score_time seconds whenever the numbers change; with 0 it stays on screen
public task_score()
{
	static id, team, t, ct, index, HudSprite:sprite

	if(!cvar_score)
	{
		if(g_last_score != -1)
		{
			g_last_score = -1

			for(id = 1; id <= MaxClients; id++)
				set_status(id, SLOT_SCORE, InvalidHudSprite)
		}
		return
	}

	t = 0
	ct = 0

	for(id = 1; id <= MaxClients; id++)
	{
		if(!is_user_alive(id))
			continue

		team = get_user_team(id)

		if(team == 1)
			t++
		else if(team == 2)
			ct++
	}

	index = min(t, 9) * 10 + min(ct, 9)
	sprite = g_sprite_score[min(t, 9)][min(ct, 9)]

	// Newcomers pick it up on the next change
	if(index != g_last_score || cvar_score_time <= 0.0)
	{
		for(id = 1; id <= MaxClients; id++)
		{
			if(is_user_connected(id))
				set_status(id, SLOT_SCORE, sprite, cvar_score_time)
		}
	}

	g_last_score = index
}

/* ------------------------------------------------------------------ */
/* Sprite generator                                                    */
/* ------------------------------------------------------------------ */

cv_clear(width, height)
{
	g_icon_w = width
	g_icon_h = height
	arrayset(g_icon, PAL_NONE, width * height)
}

cv_set(x, y, color)
{
	if(x >= 0 && x < g_icon_w && y >= 0 && y < g_icon_h)
		g_icon[y * g_icon_w + x] = color
}

cv_rect(x0, y0, x1, y1, color)
{
	for(new y = y0; y <= y1; y++)
	{
		for(new x = x0; x <= x1; x++)
			cv_set(x, y, color)
	}
}

// One digit of the 5x7 font
cv_digit(digit, x, y, scale, color)
{
	for(new row = 0; row < 7; row++)
	{
		for(new col = 0; col < 5; col++)
		{
			if(g_font[digit][row] & (1 << (4 - col)))
				cv_rect(x + col * scale, y + row * scale, x + col * scale + scale - 1, y + row * scale + scale - 1, color)
		}
	}
}

// Scoreboard value, 9 stands for "9 or more" and gets a plus sign
cv_value(value, x, color)
{
	new y = (g_icon_h - 21) / 2

	cv_digit(min(value, 9), x, y, 3, color)

	if(value >= 9)
	{
		cv_rect(x + 24, y + 3, x + 26, y + 17, color)
		cv_rect(x + 18, y + 9, x + 32, y + 11, color)
	}
}

// A line of letters (glyph ids)
cv_letters(const ids[], count, x, y, scale, color)
{
	new i, row, col

	for(i = 0; i < count; i++)
	{
		for(row = 0; row < 9; row++)
		{
			for(col = 0; col < 5; col++)
			{
				if(g_letters[ids[i]][row] & (1 << (4 - col)))
					cv_rect(x + col * scale, y + row * scale, x + col * scale + scale - 1, y + row * scale + scale - 1, color)
			}
		}
		x += 6 * scale
	}
}

// Writes the canvas as a single frame, 8-bit paletted, alpha test sprite
write_sprite(const name[])
{
	static path[64], palette[768], header[4], bool:ready

	formatex(path, charsmax(path), "sprites/%s.spr", name)

	new file = fopen(path, "wb")
	if(!file)
	{
		log_amx("Could not write %s, the HUD sprite will be missing", path)
		return
	}

	if(!ready)
	{
		ready = true

		palette[PAL_WHITE * 3] = 255, palette[PAL_WHITE * 3 + 1] = 255, palette[PAL_WHITE * 3 + 2] = 255
		palette[PAL_RED * 3] = 255, palette[PAL_RED * 3 + 1] = 50, palette[PAL_RED * 3 + 2] = 40
		palette[PAL_YELLOW * 3] = 255, palette[PAL_YELLOW * 3 + 1] = 215, palette[PAL_YELLOW * 3 + 2] = 0
		palette[PAL_GREEN * 3] = 80, palette[PAL_GREEN * 3 + 1] = 255, palette[PAL_GREEN * 3 + 2] = 90
		palette[PAL_ORANGE * 3] = 255, palette[PAL_ORANGE * 3 + 1] = 150, palette[PAL_ORANGE * 3 + 2] = 30
	}

	header[0] = 'I', header[1] = 'D', header[2] = 'S', header[3] = 'P'
	fwrite_blocks(file, header, 4, BLOCK_BYTE)

	fwrite(file, 2, BLOCK_INT)                  // version
	fwrite(file, 2, BLOCK_INT)                  // type: vp_parallel
	fwrite(file, 3, BLOCK_INT)                  // texture format: alpha test
	fwrite(file, _:(floatsqroot(float(g_icon_w * g_icon_w + g_icon_h * g_icon_h)) / 2.0), BLOCK_INT) // bounding radius
	fwrite(file, g_icon_w, BLOCK_INT)           // width
	fwrite(file, g_icon_h, BLOCK_INT)           // height
	fwrite(file, 1, BLOCK_INT)                  // frames
	fwrite(file, 0, BLOCK_INT)                  // beam length
	fwrite(file, 0, BLOCK_INT)                  // sync type
	fwrite(file, 256, BLOCK_SHORT)              // palette colors
	fwrite_blocks(file, palette, 768, BLOCK_BYTE)

	fwrite(file, 0, BLOCK_INT)                  // frame group
	fwrite(file, -g_icon_w / 2, BLOCK_INT)      // origin x
	fwrite(file, g_icon_h / 2, BLOCK_INT)       // origin y
	fwrite(file, g_icon_w, BLOCK_INT)
	fwrite(file, g_icon_h, BLOCK_INT)
	fwrite_blocks(file, g_icon, g_icon_w * g_icon_h, BLOCK_BYTE)

	fclose(file)
}

generate_sprites()
{
	static name[32], i, j

	// Welcome banner: two lines of 2x scaled letters
	cv_clear(144, 40)
	cv_letters(g_welcome_line1, sizeof g_welcome_line1, 12, 1, 2, PAL_YELLOW)
	cv_letters(g_welcome_line2, sizeof g_welcome_line2, 6, 21, 2, PAL_WHITE)
	write_sprite("hm_welcome")

	// Scoreboard: every T / CT combination from 0 to 9+ (100 sprites)
	for(i = 0; i < 10; i++)
	{
		for(j = 0; j < 10; j++)
		{
			cv_clear(216, 24)

			if(cvar_labels)
			{
				cv_letters(g_label_zombi, sizeof g_label_zombi, 2, 3, 2, PAL_RED)
				cv_letters(g_label_insan, sizeof g_label_insan, 113, 3, 2, PAL_GREEN)
			}
			else
			{
				cv_letters(g_label_t, sizeof g_label_t, 28, 3, 2, PAL_RED)
				cv_letters(g_label_ct, sizeof g_label_ct, 128, 3, 2, PAL_GREEN)
			}

			cv_value(i, 66, PAL_WHITE)
			cv_rect(106, 2, 107, 21, PAL_ORANGE)
			cv_value(j, 177, PAL_WHITE)

			formatex(name, charsmax(name), "hm_sb_%d_%d", i, j)
			write_sprite(name)
		}
	}
}
