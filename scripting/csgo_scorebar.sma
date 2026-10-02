/*
*  CSGO Score Bar 1.0
*
*  A CS:GO style score bar at the top of the screen, live for everybody:
*
*        CT: 3          TUR 7/30          TE: 2
*                        1:42
*
*  Left the CT round wins (blue), right the T round wins (orange), in the middle the round number
*  (current round = rounds played + 1) and the round timer. Works with any mod, no other plugin
*  and no module is needed (AMX Mod X 1.9+).
*
*  It is built from HUD messages instead of sprites on purpose: a bar that is always on screen
*  would need a sprite on every player at all times, and sprites_on_hud has to resend the weapon
*  HUD messages on every shot while a sprite is shown. HUD messages cost nothing like that.
*
*  Cvars:
*    sb_enabled   1       the bar
*    sb_timer     1       round timer under the round number
*    sb_label_ct  "CT"    text before the CT score
*    sb_label_t   "TE"    text before the T score
*    sb_round     "TUR"   text before the round number
*    sb_gap       0.10    distance of the scores from the center (fraction of the screen width)
*    sb_y         0.02    height (fraction of the screen height, 0.0 is the top edge)
*/

#define VERSION "1.0"

#include <amxmodx>

enum
{
	TIMER_WAITING = 0,
	TIMER_RUNNING,
	TIMER_ENDED
}

new g_sync_ct, g_sync_middle, g_sync_t
new g_score_ct, g_score_t, g_timer_state
new Float:g_round_end
new g_pcvar_roundtime, g_pcvar_maxrounds

new cvar_enabled, cvar_timer, Float:cvar_gap, Float:cvar_y
new cvar_label_ct[8], cvar_label_t[8], cvar_label_round[8]

public plugin_init()
{
	register_plugin("CSGO Score Bar", VERSION, "Biohazard")

	bind_pcvar_num(register_cvar("sb_enabled", "1"), cvar_enabled)
	bind_pcvar_num(register_cvar("sb_timer", "1"), cvar_timer)
	bind_pcvar_float(register_cvar("sb_gap", "0.10"), cvar_gap)
	bind_pcvar_float(register_cvar("sb_y", "0.02"), cvar_y)
	bind_pcvar_string(register_cvar("sb_label_ct", "CT"), cvar_label_ct, charsmax(cvar_label_ct))
	bind_pcvar_string(register_cvar("sb_label_t", "TE"), cvar_label_t, charsmax(cvar_label_t))
	bind_pcvar_string(register_cvar("sb_round", "TUR"), cvar_label_round, charsmax(cvar_label_round))

	g_pcvar_roundtime = get_cvar_pointer("mp_roundtime")
	g_pcvar_maxrounds = get_cvar_pointer("mp_maxrounds")

	register_event("TeamScore", "event_teamscore", "a")
	register_event("HLTV", "event_newround", "a", "1=0", "2=0")
	register_event("TextMsg", "event_restart", "a", "2=#Game_Commencing", "2=#Game_will_restart_in")

	register_logevent("event_roundstart", 2, "1=Round_Start")
	register_logevent("event_roundend", 2, "1=Round_End")

	g_sync_ct = CreateHudSyncObj()
	g_sync_middle = CreateHudSyncObj()
	g_sync_t = CreateHudSyncObj()

	set_task(1.0, "task_update", _, _, _, "b")
}

/* ------------------------------------------------------------------ */
/* Game events                                                         */
/* ------------------------------------------------------------------ */

// Scores come from the game itself: "TeamScore" is sent whenever a team wins a round
public event_teamscore()
{
	static team[2]
	read_data(1, team, charsmax(team))

	if(team[0] == 'C')
		g_score_ct = read_data(2)
	else if(team[0] == 'T')
		g_score_t = read_data(2)

	update_bar()
}

// New round, the timer shows the full time until the freeze time is over
public event_newround()
{
	g_timer_state = TIMER_WAITING
	update_bar()
}

public event_roundstart()
{
	g_timer_state = TIMER_RUNNING
	g_round_end = get_gametime() + (g_pcvar_roundtime ? get_pcvar_float(g_pcvar_roundtime) : 2.0) * 60.0
	update_bar()
}

public event_roundend()
{
	g_timer_state = TIMER_ENDED
	update_bar()
}

// Game restart: scores start from zero
public event_restart()
{
	g_score_ct = 0
	g_score_t = 0
	g_timer_state = TIMER_WAITING
	update_bar()
}

/* ------------------------------------------------------------------ */
/* The bar                                                             */
/* ------------------------------------------------------------------ */

public task_update()
	update_bar()

update_bar()
{
	if(!cvar_enabled || !get_playersnum())
		return

	static maxrounds, round, seconds, timer[16], max_text[12], Float:left_x, Float:right_x

	// Current round = rounds already played + 1
	round = g_score_ct + g_score_t + 1
	maxrounds = g_pcvar_maxrounds ? get_pcvar_num(g_pcvar_maxrounds) : 0

	max_text[0] = 0
	if(maxrounds > 0)
		formatex(max_text, charsmax(max_text), "/%d", maxrounds)

	timer[0] = 0
	if(cvar_timer)
	{
		switch(g_timer_state)
		{
			case TIMER_RUNNING:
				seconds = max(0, floatround(g_round_end - get_gametime(), floatround_ceil))
			case TIMER_ENDED:
				seconds = 0
			default:
				seconds = floatround((g_pcvar_roundtime ? get_pcvar_float(g_pcvar_roundtime) : 2.0) * 60.0)
		}

		formatex(timer, charsmax(timer), "^n%d:%02d", seconds / 60, seconds % 60)
	}

	// Left text starts before the center, the right text starts after it
	left_x = 0.5 - cvar_gap - 0.06
	right_x = 0.5 + cvar_gap

	// CT: blue
	set_hudmessage(90, 160, 255, left_x, cvar_y, 0, 0.0, 1.2, 0.0, 0.0, -1)
	ShowSyncHudMsg(0, g_sync_ct, "%s: %d", cvar_label_ct, g_score_ct)

	// Round number and timer: white
	set_hudmessage(255, 255, 255, -1.0, cvar_y, 0, 0.0, 1.2, 0.0, 0.0, -1)
	ShowSyncHudMsg(0, g_sync_middle, "%s %d%s%s", cvar_label_round, round, max_text, timer)

	// T: orange
	set_hudmessage(255, 170, 60, right_x, cvar_y, 0, 0.0, 1.2, 0.0, 0.0, -1)
	ShowSyncHudMsg(0, g_sync_t, "%s: %d", cvar_label_t, g_score_t)
}
