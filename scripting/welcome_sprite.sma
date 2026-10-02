/*
*  Welcome Sprite 1.0
*
*  Standalone "SUNUCUMUZA HOSGELDINIZ" banner, no zombie mod and no sprites_on_hud needed.
*  Works the way the progress bar plugin does: the banner is an env_sprite entity that only its
*  owner can see (EF_OWNER_VISIBILITY, needs ReHLDS) and the animation is the sprite frame
*  number that the plugin changes with pev_frame.
*
*  The sprite is written by the plugin itself at every map start (sprites/welcome_banner.spr):
*     frames  0-11  the text is revealed from left to right with a growing underline
*     frames 12-17  a shine sweeps over the finished text (loops while the banner is up)
*  The fade in and fade out are done with the render amount, they need no extra frames.
*
*  Motion (ws_motion 1): the banner slides in from the left with an ease-out and grows from 60% to
*  full size, floats up and down gently while it is shown and drifts upwards while it fades away.
*  (mode 0 can only do the grow, its position is fixed to the model attachment.)
*
*  Attached to a weapon (ws_mode 0): the banner follows an attachment point of the weapon model the
*  player is holding. In first person the engine uses the VIEW model (v_*.mdl) for it, so the
*  point has to exist in that model, e.g. the attachment added to v_ak47.mdl with
*  tools/mdl_attachment.py. The sprite is only visible while that weapon is in hand (ws_weapon).
*  ws_attach counts from 1: QC / tool attachment 0 is ws_attach 1, attachment 2 is ws_attach 3.
*    ws_mode 0, ws_attach 3, ws_weapon ak47     (the patched v_ak47.mdl)
*
*  Cvars (server.cfg):
*    ws_time    7.0    seconds the banner stays, 0 disables it
*    ws_mode    1      1 = floats in front of the eyes (position is fully predictable)
*                      0 = attached to the player model like the progress bar plugin
*    ws_scale   0.14   sprite scale (world units per sprite pixel)
*    ws_dist    32.0   mode 1: distance in front of the eyes
*    ws_height  10.0   mode 1: how far above the crosshair
*    ws_attach  4      mode 0: attachment of the weapon model, counted from 1
*    ws_weapon  ""     mode 0: only show while this weapon is in hand (ak47, m4a1 ...), empty = always
*    ws_motion  1      slide / grow / float motion, 0 = banner stays still
*    ws_slide   40.0   mode 1: how far to the left the slide starts (world units)
*  Player command: say /welcome shows the banner again.
*/

#define VERSION "1.0"

#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>

#if !defined EF_OWNER_VISIBILITY
	#define EF_OWNER_VISIBILITY 4096
#endif

#if !defined EF_NODRAW
	#define EF_NODRAW 128
#endif

#if !defined SF_SPRITE_ONCE
	#define SF_SPRITE_ONCE 0x0002
#endif

#define BANNER_MODEL "sprites/welcome_banner.spr"
#define BANNER_CLASS "welcome_banner"

#define BANNER_W 200
#define BANNER_H 64
#define REVEAL_FRAMES 12
#define SHIMMER_FRAMES 6
#define TOTAL_FRAMES (REVEAL_FRAMES + SHIMMER_FRAMES)

#define REVEAL_TIME 1.0
#define FADE_IN_TIME 0.3
#define FADE_OUT_TIME 0.7
#define SLIDE_TIME 0.6
#define BOB_SPEED 3.0
#define BOB_RANGE 1.2
#define DRIFT_UP 8.0

#define TASKID_SHOW 200
#define TASKID_ANIM 300

#define PAL_WHITE 1
#define PAL_YELLOW 3
#define PAL_ORANGE 5
#define PAL_SHINE 7
#define PAL_NONE 255

// Letters (5x7, row 0 holds the dot of the Turkish I, row 8 the cedilla)
// ids: 0 A, 1 C, 2 D, 3 E, 4 G, 5 H, 6 I, 7 L, 8 M, 9 N, 10 O, 11 S, 12 U, 13 Z, 14 S-cedilla, 15 dotted I
new const g_letters[16][9] =
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
	{ 0x04, 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E, 0x00 }
}

// SUNUCUMUZA / HOSGELDINIZ
new const g_line1[] = { 11, 12, 9, 12, 1, 12, 8, 12, 13, 0 }
new const g_line2[] = { 5, 10, 14, 4, 3, 7, 2, 15, 9, 15, 13 }

new g_canvas[BANNER_W * BANNER_H]

new g_ent[33], Float:g_start[33], bool:g_pending[33]
new g_active, g_fwd_think, g_isz_sprite, g_filter_weapon
new bool:g_hidden[33]
new bool:g_ready, g_weapon_name[24]

new cvar_mode, cvar_attach, cvar_motion, Float:cvar_slide, Float:cvar_time, Float:cvar_scale, Float:cvar_dist, Float:cvar_height

public plugin_precache()
{
	bind_pcvar_float(register_cvar("ws_time", "7.0"), cvar_time)
	bind_pcvar_num(register_cvar("ws_mode", "1"), cvar_mode)
	bind_pcvar_float(register_cvar("ws_scale", "0.14"), cvar_scale)
	bind_pcvar_float(register_cvar("ws_dist", "32.0"), cvar_dist)
	bind_pcvar_float(register_cvar("ws_height", "10.0"), cvar_height)
	bind_pcvar_num(register_cvar("ws_attach", "4"), cvar_attach)
	bind_pcvar_string(register_cvar("ws_weapon", ""), g_weapon_name, charsmax(g_weapon_name))
	bind_pcvar_num(register_cvar("ws_motion", "1"), cvar_motion)
	bind_pcvar_float(register_cvar("ws_slide", "40.0"), cvar_slide)

	write_banner_sprite()

	if(file_exists(BANNER_MODEL))
	{
		precache_model(BANNER_MODEL)
		g_ready = true
	}
}

public plugin_init()
{
	register_plugin("Welcome Sprite", VERSION, "Biohazard")

	register_clcmd("say /welcome", "cmd_welcome")

	RegisterHamPlayer(Ham_Spawn, "player_spawn_post", 1)
	RegisterHamPlayer(Ham_Killed, "player_killed_post", 1)

	g_isz_sprite = engfunc(EngFunc_AllocString, "env_sprite")
}

public client_putinserver(id)
{
	g_pending[id] = true
}

public client_disconnected(id)
{
	remove_task(TASKID_SHOW + id)
	banner_remove(id)
	g_pending[id] = false
}

/* ------------------------------------------------------------------ */
/* Triggers                                                            */
/* ------------------------------------------------------------------ */

public player_spawn_post(id)
{
	if(!g_pending[id] || !is_user_alive(id))
		return HAM_IGNORED

	g_pending[id] = false

	// A moment after the spawn, when the view is settled
	remove_task(TASKID_SHOW + id)
	set_task(0.5, "task_show", TASKID_SHOW + id)

	return HAM_IGNORED
}

public player_killed_post(victim)
	banner_remove(victim)

public task_show(taskid)
	banner_create(taskid - TASKID_SHOW)

public cmd_welcome(id)
{
	if(is_user_alive(id))
		banner_create(id)

	return PLUGIN_HANDLED
}

/* ------------------------------------------------------------------ */
/* Banner entity                                                       */
/* ------------------------------------------------------------------ */

banner_create(id)
{
	if(!g_ready || cvar_time <= 0.0 || !is_user_alive(id) || is_user_bot(id))
		return

	banner_remove(id)

	// Weapon the banner is tied to (mode 0), 0 means every weapon
	g_filter_weapon = 0

	if(!cvar_mode && g_weapon_name[0])
	{
		static weapon[32]
		formatex(weapon, charsmax(weapon), "weapon_%s", g_weapon_name)
		g_filter_weapon = get_weaponid(weapon)
	}

	g_hidden[id] = false

	new ent = engfunc(EngFunc_CreateNamedEntity, g_isz_sprite)
	if(pev_valid(ent) != 2)
		return

	set_pev(ent, pev_model, BANNER_MODEL)
	set_pev(ent, pev_spawnflags, SF_SPRITE_ONCE)
	set_pev(ent, pev_classname, BANNER_CLASS)
	set_pev(ent, pev_owner, id)
	set_pev(ent, pev_rendermode, kRenderTransAdd)
	set_pev(ent, pev_renderamt, 0.0)
	set_pev(ent, pev_renderfx, kRenderFxNone)
	set_pev(ent, pev_scale, cvar_scale)

	dllfunc(DLLFunc_Spawn, ent)

	// Spawn resets the movetype, so the attachment is set afterwards
	if(!cvar_mode)
	{
		set_pev(ent, pev_aiment, id)
		set_pev(ent, pev_skin, id)
		set_pev(ent, pev_body, cvar_attach)
		set_pev(ent, pev_movetype, MOVETYPE_FOLLOW)
	}

	set_pev(ent, pev_effects, pev(ent, pev_effects) | EF_OWNER_VISIBILITY)
	set_pev(ent, pev_frame, 0.0)

	g_ent[id] = ent
	g_start[id] = get_gametime()

	if(cvar_mode)
		follow_view(id, ent)

	g_active++

	if(g_active == 1)
	{
		set_task(0.07, "task_anim", TASKID_ANIM, _, _, "b")

		// Per frame position update, only registered while a banner is up
		if(cvar_mode && !g_fwd_think)
			g_fwd_think = register_forward(FM_PlayerPostThink, "fwd_postthink", 1)
	}
}

banner_remove(id)
{
	if(!g_ent[id])
		return

	if(pev_valid(g_ent[id]))
		engfunc(EngFunc_RemoveEntity, g_ent[id])

	g_ent[id] = 0

	if(--g_active <= 0)
	{
		g_active = 0
		remove_task(TASKID_ANIM)

		if(g_fwd_think)
		{
			unregister_forward(FM_PlayerPostThink, g_fwd_think, 1)
			g_fwd_think = 0
		}
	}
}

// Hides the banner while the player holds a weapon that has no matching attachment point
banner_weapon_visibility(id, ent)
{
	new bool:hide = (get_user_weapon(id) != g_filter_weapon)

	if(hide == g_hidden[id])
		return

	g_hidden[id] = hide

	new effects = pev(ent, pev_effects)
	set_pev(ent, pev_effects, hide ? (effects | EF_NODRAW) : (effects & ~EF_NODRAW))
}

// Mode 1: keeps the sprite in front of the eyes of its owner, with the slide / float motion
follow_view(id, ent)
{
	static Float:origin[3], Float:offset[3], Float:angles[3], Float:forward_vec[3], Float:right_vec[3], Float:up_vec[3]
	static Float:elapsed, Float:progress, Float:slide, Float:lift, Float:duration

	pev(id, pev_origin, origin)
	pev(id, pev_view_ofs, offset)
	pev(id, pev_v_angle, angles)

	engfunc(EngFunc_AngleVectors, angles, forward_vec, right_vec, up_vec)

	slide = 0.0
	lift = cvar_height

	if(cvar_motion)
	{
		elapsed = get_gametime() - g_start[id]
		duration = cvar_time

		// Slide in from the left, ease-out: fast at first and settling softly
		if(elapsed < SLIDE_TIME)
		{
			progress = 1.0 - elapsed / SLIDE_TIME
			slide = -cvar_slide * progress * progress * progress
		}
		else
		{
			// Floating up and down
			lift += floatsin(elapsed * BOB_SPEED, radian) * BOB_RANGE
		}

		// Drift upwards while fading out
		if(elapsed > duration - FADE_OUT_TIME)
			lift += DRIFT_UP * (1.0 - (duration - elapsed) / FADE_OUT_TIME)
	}

	origin[0] += offset[0] + forward_vec[0] * cvar_dist + right_vec[0] * slide + up_vec[0] * lift
	origin[1] += offset[1] + forward_vec[1] * cvar_dist + right_vec[1] * slide + up_vec[1] * lift
	origin[2] += offset[2] + forward_vec[2] * cvar_dist + right_vec[2] * slide + up_vec[2] * lift

	engfunc(EngFunc_SetOrigin, ent, origin)
}

public fwd_postthink(id)
{
	if(g_ent[id])
		follow_view(id, g_ent[id])

	return FMRES_IGNORED
}

// Animation: the frame follows the time (state driven like the progress bar), alpha fades
public task_anim()
{
	static id, ent, frame, Float:elapsed, Float:amount, Float:duration, Float:progress

	duration = cvar_time

	for(id = 1; id <= MaxClients; id++)
	{
		ent = g_ent[id]

		if(!ent)
			continue

		elapsed = get_gametime() - g_start[id]

		if(elapsed >= duration || !is_user_alive(id) || pev_valid(ent) != 2)
		{
			banner_remove(id)
			continue
		}

		if(elapsed < REVEAL_TIME)
			frame = floatround(elapsed / REVEAL_TIME * float(REVEAL_FRAMES - 1), floatround_floor)
		else
			frame = REVEAL_FRAMES + (floatround(elapsed * 12.0, floatround_floor) % SHIMMER_FRAMES)

		amount = 255.0

		if(elapsed < FADE_IN_TIME)
			amount = 255.0 * elapsed / FADE_IN_TIME
		else if(elapsed > duration - FADE_OUT_TIME)
			amount = 255.0 * (duration - elapsed) / FADE_OUT_TIME

		// Weapon attachment: the point only exists on the right model, hide it for other weapons
		if(g_filter_weapon)
			banner_weapon_visibility(id, ent)

		set_pev(ent, pev_frame, float(frame))
		set_pev(ent, pev_renderamt, amount)

		// Grows from 60% to full size while it slides in
		if(cvar_motion && elapsed < SLIDE_TIME)
		{
			progress = 1.0 - elapsed / SLIDE_TIME
			set_pev(ent, pev_scale, cvar_scale * (1.0 - 0.4 * progress * progress * progress))
		}
		else if(cvar_motion && elapsed < SLIDE_TIME + 0.15)
		{
			set_pev(ent, pev_scale, cvar_scale)
		}
	}

	if(!g_active)
		remove_task(TASKID_ANIM)
}

/* ------------------------------------------------------------------ */
/* Sprite generator                                                    */
/* ------------------------------------------------------------------ */

cv_set(x, y, color)
{
	if(x >= 0 && x < BANNER_W && y >= 0 && y < BANNER_H)
		g_canvas[y * BANNER_W + x] = color
}

cv_rect(x0, y0, x1, y1, color)
{
	for(new y = y0; y <= y1; y++)
	{
		for(new x = x0; x <= x1; x++)
			cv_set(x, y, color)
	}
}

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

// One animation frame on the canvas
render_frame(frame)
{
	new x, y, reveal, center, distance

	arrayset(g_canvas, PAL_NONE, BANNER_W * BANNER_H)

	cv_letters(g_line1, sizeof g_line1, 11, 2, 3, PAL_YELLOW)
	cv_letters(g_line2, sizeof g_line2, 2, 33, 3, PAL_WHITE)

	if(frame < REVEAL_FRAMES)
	{
		// Wipe from the left, the underline grows with it
		reveal = (frame + 1) * BANNER_W / REVEAL_FRAMES

		for(y = 0; y < BANNER_H; y++)
		{
			for(x = reveal; x < BANNER_W; x++)
				g_canvas[y * BANNER_W + x] = PAL_NONE
		}

		cv_rect(0, BANNER_H - 3, reveal - 1, BANNER_H - 2, PAL_ORANGE)
		return
	}

	cv_rect(0, BANNER_H - 3, BANNER_W - 1, BANNER_H - 2, PAL_ORANGE)

	// A diagonal band of light moves over the text
	center = -10 + (frame - REVEAL_FRAMES) * ((BANNER_W + 2 * BANNER_H + 20) / (SHIMMER_FRAMES - 1))

	for(y = 0; y < BANNER_H - 4; y++)
	{
		for(x = 0; x < BANNER_W; x++)
		{
			if(g_canvas[y * BANNER_W + x] == PAL_NONE)
				continue

			distance = (x + y * 2) - center

			if(distance > -10 && distance < 10)
				g_canvas[y * BANNER_W + x] = PAL_SHINE
		}
	}
}

// Writes all frames into one sprite file: 8-bit paletted, alpha test, frame i = frame number
write_banner_sprite()
{
	static palette[768], header[4]

	new file = fopen(BANNER_MODEL, "wb")
	if(!file)
	{
		log_amx("Could not write %s, the welcome banner is disabled", BANNER_MODEL)
		return
	}

	palette[PAL_WHITE * 3] = 255, palette[PAL_WHITE * 3 + 1] = 255, palette[PAL_WHITE * 3 + 2] = 255
	palette[PAL_YELLOW * 3] = 255, palette[PAL_YELLOW * 3 + 1] = 215, palette[PAL_YELLOW * 3 + 2] = 0
	palette[PAL_ORANGE * 3] = 255, palette[PAL_ORANGE * 3 + 1] = 150, palette[PAL_ORANGE * 3 + 2] = 30
	palette[PAL_SHINE * 3] = 255, palette[PAL_SHINE * 3 + 1] = 255, palette[PAL_SHINE * 3 + 2] = 190

	header[0] = 'I', header[1] = 'D', header[2] = 'S', header[3] = 'P'
	fwrite_blocks(file, header, 4, BLOCK_BYTE)

	fwrite(file, 2, BLOCK_INT)                  // version
	fwrite(file, 2, BLOCK_INT)                  // type: vp_parallel (always faces the viewer)
	fwrite(file, 3, BLOCK_INT)                  // texture format: alpha test
	fwrite(file, _:(floatsqroot(float(BANNER_W * BANNER_W + BANNER_H * BANNER_H)) / 2.0), BLOCK_INT) // bounding radius
	fwrite(file, BANNER_W, BLOCK_INT)           // width
	fwrite(file, BANNER_H, BLOCK_INT)           // height
	fwrite(file, TOTAL_FRAMES, BLOCK_INT)       // frames
	fwrite(file, 0, BLOCK_INT)                  // beam length
	fwrite(file, 0, BLOCK_INT)                  // sync type
	fwrite(file, 256, BLOCK_SHORT)              // palette colors
	fwrite_blocks(file, palette, 768, BLOCK_BYTE)

	for(new frame = 0; frame < TOTAL_FRAMES; frame++)
	{
		render_frame(frame)

		fwrite(file, 0, BLOCK_INT)              // frame group
		fwrite(file, -BANNER_W / 2, BLOCK_INT)  // origin x
		fwrite(file, BANNER_H / 2, BLOCK_INT)   // origin y
		fwrite(file, BANNER_W, BLOCK_INT)
		fwrite(file, BANNER_H, BLOCK_INT)
		fwrite_blocks(file, g_canvas, BANNER_W * BANNER_H, BLOCK_BYTE)
	}

	fclose(file)
}
