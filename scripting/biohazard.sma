/*
*  Biohazard 2.00 Beta 3 - ReAPI build
*
*  Original author: cheap_suit
*
*  Requires: AMX Mod X 1.9+, ReHLDS, ReGameDLL_CS and the ReAPI module.
*
*  What ReAPI replaced compared to the Ham Sandwich / pdata original:
*   - Ham_TakeDamage / Killed / Spawn / TraceAttack / Touch(weapon) hooks
*     -> RegisterHookChain on CBasePlayer (no CZ bot workaround needed)
*   - HLTV event + Round_Start / Round_End log events
*     -> RG_CSGameRules_RestartRound / OnRoundFreezeEnd / RG_RoundEnd
*   - Weapon strip / give / replace / bp ammo, raw pdata offsets and last-item
*     lookups -> rg_remove_all_items, rg_give_item(GT_REPLACE), rg_*_bpammo
*   - Team, deaths, money, armor, night vision pdata -> rg_set_user_team,
*     get/set_member, rg_add_account, rg_set_user_armor
*   - Follower "player_model" entity + render hacks -> rg_set_user_model
*   - Zombie knife view model (stripngive task, CurWeapon event) -> pre hook on
*     DefaultDeploy, and AddPlayerItem is blocked so zombies cannot pick up guns
*   - Pain shock free velocity restore (PreThink pre/post) -> m_flVelocityModifier
*   - Fall damage "watertype" trick -> RG_CSGameRules_FlPlayerFallDamage
*   - Flashlight block (FM_CmdStart) -> RG_CBasePlayer_ImpulseCommands
*   - Random spawns task -> RG_CSGameRules_GetPlayerSpawnSpot
*   - Ham_CS_RoundRespawn -> rg_round_respawn
*   - Persistent stats: XP / level / infections / zombie kills saved per SteamID in nvault,
*     /rank and /top commands (needs the nvault module enabled)
*   - HUD status icons (sprites_on_hud.sma must be loaded BEFORE this plugin): infection
*     countdown, last survivor / no-respawn warnings and the mutation level. Only one
*     sprite can be shown per player, so a small manager picks by priority and rotates
*   - C4 mission: zombies plant a bomb at a random spawn point (rg_plant_bomb),
*     survivors defuse it with the stock CS defuse; bomb result ends the round
*   - ScreenFade message filter (flashbang) -> RG_PlayerBlind
*   - DeathMsg message filter -> RG_CSGameRules_SendDeathMessage
*   - "jointeam" client command -> RG_HandleMenu_ChooseTeam
*   - Fall damage -> RG_CSGameRules_FlPlayerFallDamage
*   - FM_EmitSound -> RH_SV_StartSound (falls back to FM_EmitSound without ReHLDS)
*   - Per-frame PreThink / PostThink / ImpulseCommands hooks are gone or are only
*     enabled while needed (Enable/DisableHookChain); zombie regeneration is one timer
*   - Clip / armor / maxspeed pdata access -> rg_set_user_ammo, rg_get_user_armor,
*     rg_reset_maxspeed; helper entities -> rg_create_entity
*/

#define VERSION	"2.00 Beta 3 ReAPI"

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <hamsandwich>
#include <reapi>
#include <nvault>
#include <sprites_on_hud>
#include <xs>

#tryinclude "biohazard.cfg"

#if !defined _biohazardcfg_included
	#assert Biohazard configuration file required!
#elseif AMXX_VERSION_NUM < 190
	#assert AMX Mod X v1.9.0 or greater required!
#endif

#define TASKID_NEWROUND	641
#define TASKID_INITROUND 222
#define TASKID_STARTROUND 153
#define TASKID_BALANCETEAM 375
#define TASKID_UPDATESCR 264
#define TASKID_SPAWNDELAY 786
#define TASKID_WEAPONSMENU 564
#define TASKID_CHECKSPAWN 423
#define TASKID_ZRESPAWN 912
#define TASKID_HUDCHECK 950
#define TASKID_COUNTDOWN 951

// HUD status sprites, lowest number = highest priority
#define HUD_COUNTDOWN 0
#define HUD_LASTSURV 1
#define HUD_NORESPAWN 2
#define HUD_MUTATION 3
#define HUD_STATUS_COUNT 4
#define HUD_OFFSET_Y 80

#define EQUIP_PRI (1<<0)
#define EQUIP_SEC (1<<1)
#define EQUIP_GREN (1<<2)
#define EQUIP_ALL (1<<0 | 1<<1 | 1<<2)

#define ATTRIB_BOMB (1<<1)
#define DMG_HEGRENADE (1<<24)

#define MAX_SPAWNS 128
#define MAX_CLASSES 10
#define MAX_DATA 11
#define MAX_WEAPONS 32

#define DATA_HEALTH 0
#define DATA_SPEED 1
#define DATA_GRAVITY 2
#define DATA_ATTACK 3
#define DATA_DEFENCE 4
#define DATA_HEDEFENCE 5
#define DATA_HITSPEED 6
#define DATA_HITDELAY 7
#define DATA_REGENDLY 8
#define DATA_HITREGENDLY 9
#define DATA_KNOCKBACK 10

#define _random(%1) random_num(0, %1 - 1)
#define AMMOWP_NULL (1<<0 | 1<<CSW_KNIFE | 1<<CSW_FLASHBANG | 1<<CSW_HEGRENADE | 1<<CSW_SMOKEGRENADE | 1<<CSW_C4)
#define is_valid_player(%1) (1 <= %1 <= MaxClients)
#define is_playing_team(%1) (%1 == _:TEAM_TERRORIST || %1 == _:TEAM_CT)

enum
{
	MAX_CLIP = 0,
	MAX_AMMO
}

enum
{
	MENU_PRIMARY = 1,
	MENU_SECONDARY
}

enum
{
	KBPOWER_357SIG = 0,
	KBPOWER_762NATO,
	KBPOWER_BUCKSHOT,
	KBPOWER_45ACP,
	KBPOWER_556NATO,
	KBPOWER_9MM,
	KBPOWER_57MM,
	KBPOWER_338MAGNUM,
	KBPOWER_556NATOBOX,
	KBPOWER_50AE
}

new const g_weapon_ammo[][] =
{
	{ -1, -1 },
	{ 13, 52 },
	{ -1, -1 },
	{ 10, 90 },
	{ -1, -1 },
	{ 7, 32 },
	{ -1, -1 },
	{ 30, 100 },
	{ 30, 90 },
	{ -1, -1 },
	{ 30, 120 },
	{ 20, 100 },
	{ 25, 100 },
	{ 30, 90 },
	{ 35, 90 },
	{ 25, 90 },
	{ 12, 100 },
	{ 20, 120 },
	{ 10, 30 },
	{ 30, 120 },
	{ 100, 200 },
	{ 8, 32 },
	{ 30, 90 },
	{ 30, 120 },
	{ 20, 90 },
	{ -1, -1 },
	{ 7, 35 },
	{ 30, 90 },
	{ 30, 90 },
	{ -1, -1 },
	{ 50, 100 }
}

new const g_weapon_knockback[] =
{
	-1,
	KBPOWER_357SIG,
	-1,
	KBPOWER_762NATO,
	-1,
	KBPOWER_BUCKSHOT,
	-1,
	KBPOWER_45ACP,
	KBPOWER_556NATO,
	-1,
	KBPOWER_9MM,
	KBPOWER_57MM,
	KBPOWER_45ACP,
	KBPOWER_556NATO,
	KBPOWER_556NATO,
	KBPOWER_556NATO,
	KBPOWER_45ACP,
	KBPOWER_9MM,
	KBPOWER_338MAGNUM,
	KBPOWER_9MM,
	KBPOWER_556NATOBOX,
	KBPOWER_BUCKSHOT,
	KBPOWER_556NATO,
	KBPOWER_9MM,
	KBPOWER_762NATO,
	-1,
	KBPOWER_50AE,
	KBPOWER_556NATO,
	KBPOWER_762NATO,
	-1,
	KBPOWER_57MM
}

new const g_remove_entities[][] =
{
	"func_bomb_target",
	"info_bomb_target",
	"hostage_entity",
	"monster_scientist",
	"func_hostage_rescue",
	"info_hostage_rescue",
	"info_vip_start",
	"func_vip_safetyzone",
	"func_escapezone",
	"func_buyzone"
}

new const g_dataname[][] =
{
	"HEALTH",
	"SPEED",
	"GRAVITY",
	"ATTACK",
	"DEFENCE",
	"HEDEFENCE",
	"HITSPEED",
	"HITDELAY",
	"REGENDLY",
	"HITREGENDLY",
	"KNOCKBACK"
}

new g_maxplayers, g_spawncount, g_buyzone, g_sync_hpdisplay, g_sync_msgdisplay, g_fwd_spawn,
    g_fwd_result, g_fwd_infect, g_fwd_gamestart, g_msg_flashlight, g_msg_scoreattrib,
    g_msg_deathmsg, g_msg_screenfade, g_msg_scoreinfo, Float:g_buytime, bool:g_zombies_exist,
    HookChain:g_hc_impulse, HookChain:g_hc_postthink, bool:g_c4_active, Float:g_c4_site[3],
    Float:g_c4_progress[33], g_spr_ring, g_sync_c4,
    Float:g_spawns[MAX_SPAWNS+1][9], bool:g_infecting, bool:g_gamestarted, bool:g_roundstarted,
    bool:g_roundended, bool:g_allow_item, bool:g_setting_model, g_class_name[MAX_CLASSES+1][32],
    g_classcount, g_class_desc[MAX_CLASSES+1][32], g_class_pmodel[MAX_CLASSES+1][64],
    g_class_wmodel[MAX_CLASSES+1][64], Float:g_class_data[MAX_CLASSES+1][MAX_DATA],
    g_autoteambalance, g_cvar_autoteambalance, g_primary_wid[MAX_WEAPONS],
    g_secondary_wid[MAX_WEAPONS], g_grenade_wid[MAX_WEAPONS], g_gamedesc[32], g_lights[2],
    g_skyname[32]

// Cvar values, kept in sync automatically through bind_pcvar_*
new cvar_enabled, cvar_randomspawn, cvar_autonvg, cvar_winsounds, cvar_weaponsmenu,
    cvar_killbonus, cvar_maxzombies, cvar_flashbang, cvar_buytime, cvar_respawnaszombie,
    cvar_punishsuicide, cvar_infectmoney, cvar_showtruehealth, cvar_obeyarmor,
    cvar_impactexplode, cvar_caphealthdisplay, cvar_randomclass, cvar_knockback,
    cvar_knockback_duck, cvar_killreward, cvar_painshockfree, cvar_zombie_class,
    cvar_shootobjects, cvar_ammo, Float:cvar_starttime, Float:cvar_knockback_dist,
    Float:cvar_zombiemulti, Float:cvar_zombie_hpmulti, Float:cvar_pushpwr_weapon,
    Float:cvar_pushpwr_zombie, cvar_c4mission, Float:cvar_c4_planttime, Float:cvar_c4_radius,
    cvar_zombie_respawn, Float:cvar_zombie_respawn_time, cvar_mutation_max, cvar_stats,
    cvar_xp_infect, cvar_xp_kill, cvar_xp_bomb, cvar_maxlevel, cvar_class_motd, cvar_hud,
    Float:cvar_mutation_health, Float:cvar_mutation_speed, Float:cvar_mutation_attack

new HudSprite:g_hs_countdown[11], HudSprite:g_hs_mutation[6], HudSprite:g_hs_last,
    HudSprite:g_hs_norespawn, HudSprite:g_hud_status[33][HUD_STATUS_COUNT], HudSprite:g_hud_shown[33],
    g_hud_rot[33], bool:g_hud_off[33], Float:g_infect_time, g_cd_last,
    g_class_motd_count, g_class_motd_path[96], g_vault, g_xp[33], g_level[33], g_stat_infects[33], g_stat_kills[33], g_stat_key[33][40],
    bool:g_stats_loaded[33], g_mutation[33], bool:g_zrespawn[33], bool:g_zombie[33], bool:g_disconnected[33], bool:g_showmenu[33], bool:g_menufailsafe[33],
    bool:g_preinfect[33], bool:g_welcomemsg[33], bool:g_suicide[33], Float:g_regendelay[33],
    g_mutate[33], g_victim[33], g_menuposition[33], g_player_class[33], g_player_weapons[33][2]

stock bind_int(const name[], const value[], &var)
	bind_pcvar_num(register_cvar(name, value), var)

stock bind_float(const name[], const value[], &Float:var)
	bind_pcvar_float(register_cvar(name, value), var)

public plugin_precache()
{
	register_plugin("Biohazard", VERSION, "cheap_suit")
	register_cvar("bh_version", VERSION, FCVAR_SPONLY|FCVAR_SERVER)
	set_cvar_string("bh_version", VERSION)

	bind_int("bh_enabled", "1", cvar_enabled)

	if(!cvar_enabled)
		return

	bind_pcvar_string(register_cvar("bh_gamedescription", "Biohazard"), g_gamedesc, charsmax(g_gamedesc))
	bind_pcvar_string(register_cvar("bh_skyname", "drkg"), g_skyname, charsmax(g_skyname))
	bind_pcvar_string(register_cvar("bh_lights", "d"), g_lights, charsmax(g_lights))
	bind_float("bh_starttime", "15.0", cvar_starttime)
	bind_int("bh_buytime", "0", cvar_buytime)
	bind_int("bh_randomspawn", "0", cvar_randomspawn)
	bind_int("bh_punishsuicide", "1", cvar_punishsuicide)
	bind_int("bh_winsounds", "1", cvar_winsounds)
	bind_int("bh_autonvg", "1", cvar_autonvg)
	bind_int("bh_respawnaszombie", "1", cvar_respawnaszombie)
	bind_int("bh_painshockfree", "1", cvar_painshockfree)
	bind_int("bh_knockback", "1", cvar_knockback)
	bind_int("bh_knockback_duck", "1", cvar_knockback_duck)
	bind_float("bh_knockback_dist", "280.0", cvar_knockback_dist)
	bind_int("bh_obeyarmor", "0", cvar_obeyarmor)
	bind_int("bh_infectionmoney", "0", cvar_infectmoney)
	bind_int("bh_caphealthdisplay", "1", cvar_caphealthdisplay)
	bind_int("bh_weaponsmenu", "1", cvar_weaponsmenu)
	bind_int("bh_ammo", "1", cvar_ammo)
	bind_int("bh_maxzombies", "31", cvar_maxzombies)
	bind_int("bh_flashbang", "1", cvar_flashbang)
	bind_int("bh_impactexplode", "1", cvar_impactexplode)
	bind_int("bh_showtruehealth", "1", cvar_showtruehealth)
	bind_float("bh_zombie_countmulti", "0.15", cvar_zombiemulti)
	bind_float("bh_zombie_hpmulti", "2.0", cvar_zombie_hpmulti)
	bind_int("bh_zombie_class", "1", cvar_zombie_class)
	bind_int("bh_randomclass", "1", cvar_randomclass)
	bind_int("bh_kill_bonus", "1", cvar_killbonus)
	bind_int("bh_kill_reward", "2", cvar_killreward)
	bind_int("bh_shootobjects", "1", cvar_shootobjects)
	bind_float("bh_pushpwr_weapon", "2.0", cvar_pushpwr_weapon)
	bind_float("bh_pushpwr_zombie", "5.0", cvar_pushpwr_zombie)
	bind_int("bh_c4mission", "1", cvar_c4mission)
	bind_int("bh_zombie_respawn", "1", cvar_zombie_respawn)
	bind_int("bh_stats", "1", cvar_stats)
	bind_int("bh_class_motd", "1", cvar_class_motd)
	bind_int("bh_hud", "1", cvar_hud)
	bind_int("bh_xp_infect", "5", cvar_xp_infect)
	bind_int("bh_xp_kill", "10", cvar_xp_kill)
	bind_int("bh_xp_bomb", "25", cvar_xp_bomb)
	bind_int("bh_maxlevel", "50", cvar_maxlevel)
	bind_int("bh_mutation_max", "3", cvar_mutation_max)
	bind_float("bh_mutation_health", "50.0", cvar_mutation_health)
	bind_float("bh_mutation_speed", "15.0", cvar_mutation_speed)
	bind_float("bh_mutation_attack", "0.1", cvar_mutation_attack)
	bind_float("bh_zombie_respawn_time", "3.0", cvar_zombie_respawn_time)
	bind_float("bh_c4_planttime", "3.0", cvar_c4_planttime)
	bind_float("bh_c4_radius", "120.0", cvar_c4_radius)

	new file[64]
	get_configsdir(file, charsmax(file))
	format(file, charsmax(file), "%s/bh_cvars.cfg", file)

	if(file_exists(file))
		server_cmd("exec %s", file)

	new mapname[32]
	get_mapname(mapname, charsmax(mapname))
	register_spawnpoints(mapname)

	register_zombieclasses("bh_zombieclass.ini")
	register_dictionary("biohazard.txt")

	precache_model(DEFAULT_PMODEL)
	precache_model(DEFAULT_WMODEL)

	new i
	for(i = 0; i < g_classcount; i++)
	{
		precache_model(g_class_pmodel[i])
		precache_model(g_class_wmodel[i])
	}

	for(i = 0; i < sizeof g_zombie_miss_sounds; i++)
		precache_sound(g_zombie_miss_sounds[i])

	for(i = 0; i < sizeof g_zombie_hit_sounds; i++)
		precache_sound(g_zombie_hit_sounds[i])

	for(i = 0; i < sizeof g_scream_sounds; i++)
		precache_sound(g_scream_sounds[i])

	for(i = 0; i < sizeof g_zombie_die_sounds; i++)
		precache_sound(g_zombie_die_sounds[i])

	for(i = 0; i < sizeof g_zombie_win_sounds; i++)
		precache_sound(g_zombie_win_sounds[i])

	for(i = 0; i < sizeof g_survivor_win_sounds; i++)
		precache_sound(g_survivor_win_sounds[i])

	g_spr_ring = precache_model("sprites/white.spr")

	hud_precache()

	g_fwd_spawn = register_forward(FM_Spawn, "fwd_spawn")

	g_buyzone = rg_create_entity("func_buyzone")
	if(g_buyzone)
	{
		dllfunc(DLLFunc_Spawn, g_buyzone)
		set_pev(g_buyzone, pev_solid, SOLID_NOT)
	}

	new ent = rg_create_entity("info_bomb_target")
	if(ent)
	{
		dllfunc(DLLFunc_Spawn, ent)
		set_pev(ent, pev_solid, SOLID_NOT)
	}

	#if FOG_ENABLE
	ent = rg_create_entity("env_fog")
	if(ent)
	{
		fm_set_kvd(ent, "density", FOG_DENSITY, "env_fog")
		fm_set_kvd(ent, "rendercolor", FOG_COLOR, "env_fog")
	}
	#endif
}

public plugin_init()
{
	if(!cvar_enabled)
		return

	g_cvar_autoteambalance = get_cvar_pointer("mp_autoteambalance")
	g_autoteambalance = get_pcvar_num(g_cvar_autoteambalance)
	set_pcvar_num(g_cvar_autoteambalance, 0)

	register_clcmd("say /class", "cmd_classmenu")
	register_clcmd("say /guns", "cmd_enablemenu")
	register_clcmd("say /help", "cmd_helpmotd")
	register_clcmd("say /rank", "cmd_rank")
	register_clcmd("say /hud", "cmd_hud")
	register_clcmd("bh_class", "cmd_setclass")
	register_clcmd("say /top", "cmd_top")
	register_clcmd("amx_infect", "cmd_infectuser", ADMIN_BAN, "<name or #userid>")

	register_menu("Equipment", 1023, "action_equip")
	register_menu("Primary", 1023, "action_prim")
	register_menu("Secondary", 1023, "action_sec")
	register_menu("Class", 1023, "action_class")

	unregister_forward(FM_Spawn, g_fwd_spawn)
	register_forward(FM_GetGameDescription, "fwd_gamedescription")
	register_forward(FM_CreateNamedEntity, "fwd_createnamedentity")
	register_forward(FM_ClientKill, "fwd_clientkill")

	// Player
	RegisterHookChain(RG_CBasePlayer_Spawn, "rg_player_spawn_post", true)
	RegisterHookChain(RG_CBasePlayer_TakeDamage, "rg_player_takedamage")
	RegisterHookChain(RG_CBasePlayer_TakeDamage, "rg_player_takedamage_post", true)
	RegisterHookChain(RG_CBasePlayer_TraceAttack, "rg_player_traceattack")
	RegisterHookChain(RG_CBasePlayer_Killed, "rg_player_killed")
	RegisterHookChain(RG_CBasePlayer_Killed, "rg_player_killed_post", true)
	RegisterHookChain(RG_CGrenade_DefuseBombEnd, "rg_defuse_end_post", true)
	RegisterHookChain(RG_HandleMenu_ChooseTeam, "rg_choose_team")
	RegisterHookChain(RG_PlayerBlind, "rg_player_blind")
	RegisterHookChain(RG_CSGameRules_FlPlayerFallDamage, "rg_fall_damage")
	RegisterHookChain(RG_CSGameRules_SendDeathMessage, "rg_send_deathmessage")

	// Needed only part of the time, switched with Enable/DisableHookChain
	g_hc_postthink = RegisterHookChain(RG_CBasePlayer_PostThink, "rg_player_postthink", true)
	g_hc_impulse = RegisterHookChain(RG_CBasePlayer_ImpulseCommands, "rg_player_impulse")
	DisableHookChain(g_hc_postthink)
	DisableHookChain(g_hc_impulse)

	// Sounds: ReHLDS hook rewrites the sample in place, FM fallback re-emits
	if(is_rehlds())
		RegisterHookChain(RH_SV_StartSound, "rh_sv_startsound")
	else
		register_forward(FM_EmitSound, "fwd_emitsound")
	RegisterHookChain(RG_CBasePlayer_AddPlayerItem, "rg_player_additem")
	RegisterHookChain(RG_CBasePlayer_GiveDefaultItems, "rg_player_givedefaultitems")
	RegisterHookChain(RG_CBasePlayer_ResetMaxSpeed, "rg_player_resetmaxspeed", true)
	RegisterHookChain(RG_CBasePlayer_SetClientUserInfoModel, "rg_player_setmodel")
	RegisterHookChain(RG_CBasePlayerWeapon_DefaultDeploy, "rg_weapon_defaultdeploy")

	// Game rules
	RegisterHookChain(RG_CSGameRules_RestartRound, "rg_round_restart_post", true)
	RegisterHookChain(RG_CSGameRules_OnRoundFreezeEnd, "rg_round_freezeend_post", true)
	RegisterHookChain(RG_RoundEnd, "rg_round_end_post", true)
	RegisterHookChain(RG_CSGameRules_GetPlayerSpawnSpot, "rg_spawnspot_post", true)

	// World entities (not covered by ReAPI)
	RegisterHam(Ham_TraceAttack, "func_pushable", "bacon_traceattack_pushable")
	RegisterHam(Ham_Use, "func_tank", "bacon_use_tank")
	RegisterHam(Ham_Use, "func_tankmortar", "bacon_use_tank")
	RegisterHam(Ham_Use, "func_tankrocket", "bacon_use_tank")
	RegisterHam(Ham_Use, "func_tanklaser", "bacon_use_tank")
	RegisterHam(Ham_Use, "func_pushable", "bacon_use_pushable")
	RegisterHam(Ham_Touch, "func_pushable", "bacon_touch_pushable")
	RegisterHam(Ham_Touch, "grenade", "bacon_touch_grenade")

	g_msg_flashlight = get_user_msgid("Flashlight")
	g_msg_scoreattrib = get_user_msgid("ScoreAttrib")
	g_msg_scoreinfo = get_user_msgid("ScoreInfo")
	g_msg_deathmsg = get_user_msgid("DeathMsg")
	g_msg_screenfade = get_user_msgid("ScreenFade")

	register_message(get_user_msgid("Health"), "msg_health")
	register_message(get_user_msgid("TextMsg"), "msg_textmsg")
	register_message(get_user_msgid("SendAudio"), "msg_sendaudio")
	register_message(get_user_msgid("StatusIcon"), "msg_statusicon")
	register_message(g_msg_scoreattrib, "msg_scoreattrib")
	register_message(get_user_msgid("TeamInfo"), "msg_teaminfo")
	register_message(get_user_msgid("WeapPickup"), "msg_weaponpickup")
	register_message(get_user_msgid("AmmoPickup"), "msg_ammopickup")

	register_event("TextMsg", "event_textmsg", "a", "2=#Game_will_restart_in")
	register_event("CurWeapon", "event_curweapon", "be", "1=1")
	register_event("ArmorType", "event_armortype", "be")

	g_fwd_infect = CreateMultiForward("event_infect", ET_IGNORE, FP_CELL, FP_CELL)
	g_fwd_gamestart = CreateMultiForward("event_gamestart", ET_IGNORE)

	g_sync_hpdisplay = CreateHudSyncObj()
	g_sync_msgdisplay = CreateHudSyncObj()
	g_sync_c4 = CreateHudSyncObj()

	g_maxplayers = get_maxplayers()

	for(new id = 0; id <= MaxClients; id++)
		hud_reset_player(id)

	set_task(3.0, "task_hud_rotate", _, _, _, "b")

	g_vault = nvault_open("biohazard_stats")
	if(g_vault == INVALID_HANDLE)
		log_amx("Could not open the nvault, stats will not be saved")

	cache_weapon_ids()

	if(g_skyname[0])
		set_cvar_string("sv_skyname", g_skyname)

	if(g_lights[0])
	{
		set_task(3.0, "task_lights", _, _, _, "b")

		set_cvar_num("sv_skycolor_r", 0)
		set_cvar_num("sv_skycolor_g", 0)
		set_cvar_num("sv_skycolor_b", 0)
	}

	set_task(0.05, "task_regen", _, _, _, "b")
	set_task(0.1, "task_c4mission", _, _, _, "b")

	if(cvar_showtruehealth)
		set_task(0.2, "task_showtruehealth", _, _, _, "b")
}

public plugin_end()
{
	if(!cvar_enabled)
		return

	set_pcvar_num(g_cvar_autoteambalance, g_autoteambalance)

	stats_save_all()

	if(g_vault != INVALID_HANDLE)
		nvault_close(g_vault)
}

public plugin_natives()
{
	register_library("biohazardf")
	register_native("preinfect_user", "native_preinfect_user", 1)
	register_native("infect_user", "native_infect_user", 1)
	register_native("cure_user", "native_cure_user", 1)
	register_native("register_class", "native_register_class", 1)
	register_native("get_class_id", "native_get_class_id", 1)
	register_native("set_class_pmodel", "native_set_class_pmodel", 1)
	register_native("set_class_wmodel", "native_set_class_wmodel", 1)
	register_native("set_class_data", "native_set_class_data", 1)
	register_native("get_class_data", "native_get_class_data", 1)
	register_native("game_started", "native_game_started", 1)
	register_native("is_user_zombie", "native_is_user_zombie", 1)
	register_native("is_user_infected", "native_is_user_infected", 1)
	register_native("get_user_class", "native_get_user_class", 1)
}

// Resolve weapon ids once, equip code never does string lookups
cache_weapon_ids()
{
	new i
	for(i = 0; i < sizeof g_primaryweapons && i < MAX_WEAPONS; i++)
		g_primary_wid[i] = get_weaponid(g_primaryweapons[i][1])

	for(i = 0; i < sizeof g_secondaryweapons && i < MAX_WEAPONS; i++)
		g_secondary_wid[i] = get_weaponid(g_secondaryweapons[i][1])

	for(i = 0; i < sizeof g_grenades && i < MAX_WEAPONS; i++)
		g_grenade_wid[i] = get_weaponid(g_grenades[i])
}

public client_connect(id)
{
	hud_reset_player(id)
	g_hud_off[id] = false
	g_showmenu[id] = true
	g_welcomemsg[id] = true
	g_zombie[id] = false
	g_preinfect[id] = false
	g_disconnected[id] = false
	g_menufailsafe[id] = false
	g_suicide[id] = false
	g_victim[id] = 0
	g_mutate[id] = -1
	g_player_class[id] = 0
	g_player_weapons[id][0] = -1
	g_player_weapons[id][1] = -1
	g_regendelay[id] = 0.0
	g_zrespawn[id] = false
	g_mutation[id] = 0
}

public client_putinserver(id)
{
	if(cvar_randomclass && g_classcount > 1)
		g_player_class[id] = _random(g_classcount)
}

public client_disconnected(id)
{
	hud_check_later()

	stats_save(id)
	stats_clear(id)

	remove_task(TASKID_UPDATESCR + id)
	remove_task(TASKID_SPAWNDELAY + id)
	remove_task(TASKID_WEAPONSMENU + id)
	remove_task(TASKID_CHECKSPAWN + id)
	remove_task(TASKID_ZRESPAWN + id)

	g_zrespawn[id] = false
	g_disconnected[id] = true
}

public cmd_classmenu(id)
{
	if(g_classcount <= 1)
		return

	show_class_motd(id)
	display_classmenu(id, g_menuposition[id] = 0)
}

// bh_class <number>: picks the class from the MOTD list (a MOTD cannot send clicks back)
public cmd_setclass(id)
{
	if(g_classcount <= 1)
		return PLUGIN_HANDLED

	static arg[8], number
	read_argv(1, arg, charsmax(arg))
	number = str_to_num(arg)

	if(number < 1 || number > g_classcount)
	{
		client_print(id, print_console, "Usage: bh_class <1-%d>", g_classcount)
		return PLUGIN_HANDLED
	}

	set_next_class(id, number - 1)
	return PLUGIN_HANDLED
}

// The class becomes active on the next infection
set_next_class(id, class)
{
	g_mutate[id] = class
	client_print(id, print_chat, "%L", id, "MENU_CHANGECLASS", g_class_name[class])
}

/* ------------------------------------------------------------------ */
/* Class MOTD                                                          */
/* ------------------------------------------------------------------ */

// Writes the class list as an HTML page; rebuilt when the number of classes changed
build_class_motd()
{
	static datadir[64]
	get_datadir(datadir, charsmax(datadir))
	formatex(g_class_motd_path, charsmax(g_class_motd_path), "%s/bh_classes.html", datadir)

	new file = fopen(g_class_motd_path, "wt")
	if(!file)
		return

	fputs(file, "<html><head><meta charset=^"utf-8^"><style>body{background:#111;color:#ddd;font-family:Verdana;font-size:12px;margin:8px}")
	fputs(file, "h3{color:#f55}table{width:100%;border-collapse:collapse}th,td{border-bottom:1px solid #333;padding:4px;text-align:left}th{color:#f55}")
	fputs(file, "td.n{color:#fc0;font-weight:bold}p{color:#999}</style></head><body><h3>Zombie Classes</h3><table>")
	fputs(file, "<tr><th>#</th><th>Class</th><th>HP</th><th>Speed</th><th>Gravity</th><th>Attack</th><th>Description</th></tr>")

	static name[64], desc[64], row[512], i
	for(i = 0; i < g_classcount; i++)
	{
		copy(name, charsmax(name), g_class_name[i])
		copy(desc, charsmax(desc), g_class_desc[i])

		replace_all(name, charsmax(name), "<", "&lt;")
		replace_all(desc, charsmax(desc), "<", "&lt;")

		formatex(row, charsmax(row), "<tr><td class=^"n^">%d</td><td>%s</td><td>%.0f</td><td>%.0f</td><td>%.2f</td><td>x%.1f</td><td>%s</td></tr>",
			i + 1, name, g_class_data[i][DATA_HEALTH], g_class_data[i][DATA_SPEED], g_class_data[i][DATA_GRAVITY], g_class_data[i][DATA_ATTACK], desc)

		fputs(file, row)
	}

	fputs(file, "</table><p>Pick a class with the number keys of the menu, or type <b>bh_class &lt;number&gt;</b> in the console.<br>")
	fputs(file, "The chosen class is used the next time you become a zombie.</p></body></html>")
	fclose(file)

	g_class_motd_count = g_classcount
}

show_class_motd(id)
{
	if(g_class_motd_count != g_classcount || !g_class_motd_path[0])
		build_class_motd()

	if(g_class_motd_path[0] && file_exists(g_class_motd_path))
		show_motd(id, g_class_motd_path, "Zombie Classes")
}

public cmd_enablemenu(id)
{
	if(cvar_weaponsmenu)
	{
		client_print(id, print_chat, "%L", id, g_showmenu[id] ? "MENU_ALENABLED" : "MENU_REENABLED")
		g_showmenu[id] = true
	}
}

public cmd_helpmotd(id)
{
	static motd[2048]
	formatex(motd, charsmax(motd), "%L", id, "HELP_MOTD")
	replace(motd, charsmax(motd), "#Version#", VERSION)

	show_motd(id, motd, "Biohazard Help")
}

public cmd_infectuser(id, level, cid)
{
	if(!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED_MAIN

	new arg1[32]
	read_argv(1, arg1, charsmax(arg1))

	new target = cmd_target(id, arg1, (CMDTARGET_OBEY_IMMUNITY|CMDTARGET_ALLOW_SELF|CMDTARGET_ONLY_ALIVE))

	if(!target || g_zombie[target])
		return PLUGIN_HANDLED_MAIN

	if(!allow_infection())
	{
		console_print(id, "%L", id, "CMD_MAXZOMBIES")
		return PLUGIN_HANDLED_MAIN
	}

	if(!g_gamestarted)
	{
		console_print(id, "%L", id, "CMD_GAMENOTSTARTED")
		return PLUGIN_HANDLED_MAIN
	}

	new name[32]
	get_user_name(target, name, charsmax(name))

	console_print(id, "%L", id, "CMD_INFECTED", name)
	infect_user(target, 0)

	return PLUGIN_HANDLED_MAIN
}

/* ------------------------------------------------------------------ */
/* Messages                                                            */
/* ------------------------------------------------------------------ */

public msg_teaminfo(msgid, dest, id)
{
	if(!g_gamestarted)
		return PLUGIN_CONTINUE

	static team[2]
	get_msg_arg_string(2, team, 1)

	if(team[0] != 'U')
		return PLUGIN_CONTINUE

	id = get_msg_arg_int(1)
	if(!is_valid_player(id) || !g_disconnected[id] || is_user_alive(id))
		return PLUGIN_CONTINUE

	g_disconnected[id] = false
	id = randomly_pick_zombie()
	if(id)
	{
		rg_set_user_team(id, _:(g_zombie[id] ? TEAM_CT : TEAM_TERRORIST), MODEL_UNASSIGNED, false)
		set_pev(id, pev_deadflag, DEAD_RESPAWNABLE)
	}
	return PLUGIN_CONTINUE
}

public msg_scoreattrib(msgid, dest, id)
{
	if(get_msg_arg_int(2) == ATTRIB_BOMB)
		set_msg_arg_int(2, ARG_BYTE, 0)
}

public msg_statusicon(msgid, dest, id)
{
	static icon[3]
	get_msg_arg_string(2, icon, 2)

	return (icon[0] == 'c' && icon[1] == '4') ? PLUGIN_HANDLED : PLUGIN_CONTINUE
}

public msg_weaponpickup(msgid, dest, id)
	return g_zombie[id] ? PLUGIN_HANDLED : PLUGIN_CONTINUE

public msg_ammopickup(msgid, dest, id)
	return g_zombie[id] ? PLUGIN_HANDLED : PLUGIN_CONTINUE

public msg_sendaudio(msgid, dest, id)
{
	if(!cvar_winsounds)
		return PLUGIN_CONTINUE

	static audiocode[22]
	get_msg_arg_string(2, audiocode, charsmax(audiocode))

	if(equal(audiocode[7], "terwin"))
		set_msg_arg_string(2, g_zombie_win_sounds[_random(sizeof g_zombie_win_sounds)])
	else if(equal(audiocode[7], "ctwin"))
		set_msg_arg_string(2, g_survivor_win_sounds[_random(sizeof g_survivor_win_sounds)])

	return PLUGIN_CONTINUE
}

public msg_health(msgid, dest, id)
{
	if(cvar_caphealthdisplay && get_msg_arg_int(1) > 255)
		set_msg_arg_int(1, ARG_BYTE, 255)

	return PLUGIN_CONTINUE
}

public msg_textmsg(msgid, dest, id)
{
	if(get_msg_arg_int(1) != 4)
		return PLUGIN_CONTINUE

	static txtmsg[25], winmsg[32]
	get_msg_arg_string(2, txtmsg, charsmax(txtmsg))

	if(equal(txtmsg[1], "Game_bomb_drop"))
		return PLUGIN_HANDLED

	if(equal(txtmsg[1], "Terrorists_Win") || equal(txtmsg[1], "Target_Bombed"))
	{
		formatex(winmsg, charsmax(winmsg), "%L", LANG_SERVER, "WIN_TXT_ZOMBIES")
		set_msg_arg_string(2, winmsg)
	}
	else if(equal(txtmsg[1], "Target_Saved") || equal(txtmsg[1], "CTs_Win") || equal(txtmsg[1], "Bomb_Defused"))
	{
		formatex(winmsg, charsmax(winmsg), "%L", LANG_SERVER, "WIN_TXT_SURVIVORS")
		set_msg_arg_string(2, winmsg)
	}
	return PLUGIN_CONTINUE
}

/* ------------------------------------------------------------------ */
/* Round flow (ReGameDLL game rules)                                   */
/* ------------------------------------------------------------------ */

// New round (replaces the HLTV event)
public rg_round_restart_post()
{
	g_gamestarted = false

	g_zombies_exist = false
	DisableHookChain(g_hc_impulse)
	c4_reset()
	countdown_start()

	for(new id = 1; id <= g_maxplayers; id++)
	{
		hud_clear(id, HUD_LASTSURV)
		hud_clear(id, HUD_NORESPAWN)
		remove_task(TASKID_ZRESPAWN + id)
		g_zrespawn[id] = false
		g_mutation[id] = 0
	}

	if(cvar_buytime)
	{
		g_buytime = cvar_buytime + get_gametime()
		EnableHookChain(g_hc_postthink)
	}

	remove_task(TASKID_NEWROUND)
	remove_task(TASKID_INITROUND)
	remove_task(TASKID_STARTROUND)

	set_task(0.1, "task_newround", TASKID_NEWROUND)
	set_task(cvar_starttime, "task_initround", TASKID_INITROUND)
}

// Freeze time is over (replaces the Round_Start log event)
public rg_round_freezeend_post()
{
	g_roundended = false
	g_roundstarted = true

	if(!cvar_weaponsmenu)
		return

	static id, team
	for(id = 1; id <= g_maxplayers; id++)
	{
		if(!is_user_alive(id))
			continue

		team = get_member(id, m_iTeam)
		if(!is_playing_team(team))
			continue

		if(is_user_bot(id))
			bot_weapons(id)
		else if(g_showmenu[id])
		{
			add_delay(id, "display_equipmenu")

			g_menufailsafe[id] = true
			set_task(10.0, "task_weaponsmenu", TASKID_WEAPONSMENU + id)
		}
		else
			equipweapon(id, EQUIP_ALL)
	}
}

// Round finished (replaces the Round_End log event)
public rg_round_end_post(WinStatus:status, ScenarioEventEndRound:event, Float:delay)
{
	g_gamestarted = false
	g_roundstarted = false
	g_roundended = true

	remove_task(TASKID_BALANCETEAM)
	remove_task(TASKID_INITROUND)
	remove_task(TASKID_STARTROUND)

	set_task(0.1, "task_balanceteam", TASKID_BALANCETEAM)

	countdown_stop()
	hud_check_later()

	stats_save_all()
}

public event_textmsg()
{
	g_gamestarted = false
	g_roundstarted = false
	g_roundended = true

	static seconds[5]
	read_data(3, seconds, charsmax(seconds))

	remove_task(TASKID_BALANCETEAM)
	set_task(float(str_to_num(seconds)) - 0.5, "task_balanceteam", TASKID_BALANCETEAM)
}

// Random spawn points; replaces the per-player teleport loop in task_newround
public rg_spawnspot_post(const id)
{
	if(!cvar_randomspawn || g_spawncount <= 0 || !is_user_alive(id))
		return HC_CONTINUE

	static team
	team = get_member(id, m_iTeam)
	if(!is_playing_team(team))
		return HC_CONTINUE

	static spawn_index, j, Float:spawndata[3]
	spawn_index = _random(g_spawncount)

	copy_spawn_vec(spawndata, spawn_index, 0)

	if(!fm_is_hull_vacant(spawndata, HULL_HUMAN))
	{
		for(j = spawn_index + 1; j != spawn_index; j++)
		{
			if(j >= g_spawncount)
				j = 0

			copy_spawn_vec(spawndata, j, 0)

			if(fm_is_hull_vacant(spawndata, HULL_HUMAN))
			{
				spawn_index = j
				break
			}
		}
	}

	copy_spawn_vec(spawndata, spawn_index, 0)
	engfunc(EngFunc_SetOrigin, id, spawndata)

	copy_spawn_vec(spawndata, spawn_index, 3)
	set_pev(id, pev_angles, spawndata)

	copy_spawn_vec(spawndata, spawn_index, 6)
	set_pev(id, pev_v_angle, spawndata)

	set_pev(id, pev_fixangle, 1)
	return HC_CONTINUE
}

// Copies 3 consecutive floats of a spawn entry into a vector
copy_spawn_vec(Float:vec[3], index, start)
{
	vec[0] = g_spawns[index][start]
	vec[1] = g_spawns[index][start + 1]
	vec[2] = g_spawns[index][start + 2]
}

/* ------------------------------------------------------------------ */
/* Player hookchains                                                   */
/* ------------------------------------------------------------------ */

public event_curweapon(id)
{
	// Zombies hold the knife only (pickups are blocked), nothing to do for them
	if(g_zombie[id] || !is_user_alive(id))
		return PLUGIN_CONTINUE

	static weapon
	weapon = read_data(2)

	if(!cvar_ammo || (AMMOWP_NULL & (1<<weapon)))
		return PLUGIN_CONTINUE

	switch(cvar_ammo)
	{
		case 1:
		{
			static maxammo
			maxammo = g_weapon_ammo[weapon][MAX_AMMO]

			if(maxammo > 0 && rg_get_user_bpammo(id, WeaponIdType:weapon) < 1)
				rg_set_user_bpammo(id, WeaponIdType:weapon, maxammo)
		}
		case 2:
		{
			static maxclip
			maxclip = g_weapon_ammo[weapon][MAX_CLIP]

			if(maxclip > 0 && read_data(3) < 1)
				rg_set_user_ammo(id, WeaponIdType:weapon, maxclip)
		}
	}
	return PLUGIN_CONTINUE
}

public event_armortype(id)
{
	if(g_zombie[id] && is_user_alive(id) && rg_get_user_armor(id) > 0)
		rg_set_user_armor(id, 0, ARMOR_NONE)

	return PLUGIN_CONTINUE
}

// Zombie health regeneration, one timer instead of a hook on every player frame
public task_regen()
{
	if(!g_gamestarted || !g_zombies_exist)
		return

	static id, pclass, Float:health, Float:now, Float:interval
	now = get_gametime()

	for(id = 1; id <= g_maxplayers; id++)
	{
		if(!g_zombie[id] || g_regendelay[id] > now || !is_user_alive(id))
			continue

		pclass = g_player_class[id]
		pev(id, pev_health, health)

		if(health >= zombie_max_health(id))
			continue

		set_pev(id, pev_health, health + 1.0)

		// Carry the remainder so the real rate matches DATA_REGENDLY
		interval = g_class_data[pclass][DATA_REGENDLY]
		g_regendelay[id] = (now - g_regendelay[id] > interval) ? now + interval : g_regendelay[id] + interval
	}
}

// Keeps the buy zone "touched" while the buy time is running (hook is only enabled then)
public rg_player_postthink(const id)
{
	if(g_buytime <= get_gametime())
	{
		DisableHookChain(g_hc_postthink)
		return HC_CONTINUE
	}

	if(is_user_alive(id) && pev_valid(g_buyzone))
		dllfunc(DLLFunc_Touch, g_buyzone, id)

	return HC_CONTINUE
}

// Zombies cannot change team
public rg_choose_team(const id, MenuChooseTeam:slot)
{
	if(!g_zombie[id] || !is_user_alive(id))
		return HC_CONTINUE

	client_print(id, print_center, "%L", id, "CMD_TEAMCHANGE")
	return HC_SUPERCEDE
}

// Flashbangs only blind zombies (survivors and spectators are immune)
public rg_player_blind(const index, const inflictor, const attacker, const Float:fadeTime, const Float:fadeHold, const alpha, Float:color[3])
{
	if(cvar_flashbang && alpha > 199 && (!g_zombie[index] || !is_user_alive(index)))
		return HC_SUPERCEDE

	return HC_CONTINUE
}

// Zombies do not take fall damage
public rg_fall_damage(const id)
{
	if(!g_zombie[id])
		return HC_CONTINUE

	SetHookChainReturn(ATYPE_FLOAT, 0.0)
	return HC_SUPERCEDE
}

// Kill feed shows the claw icon when a zombie kills somebody
public rg_send_deathmessage(const pKiller, const pVictim, const pAssister, const pevInflictor, const killerWeaponName[], const DeathMessageFlags:iDeathMessageFlags, const KillRarity:iRarityOfKill)
{
	if(is_valid_player(pKiller) && g_zombie[pKiller])
		SetHookChainArg(5, ATYPE_STRING, g_zombie_weapname)

	return HC_CONTINUE
}

// Flashlight is disabled for zombies (hook is only enabled while zombies exist)
public rg_player_impulse(const id)
{
	if(g_zombie[id] && pev(id, pev_impulse) == 100 && is_user_alive(id))
		set_pev(id, pev_impulse, 0)

	return HC_CONTINUE
}

// Zombies cannot pick up or buy any weapon
public rg_player_additem(const id, const item)
{
	if(!g_zombie[id] || g_allow_item)
		return HC_CONTINUE

	SetHookChainReturn(ATYPE_INTEGER, 0)
	return HC_SUPERCEDE
}

// Zombies spawn with the knife only
public rg_player_givedefaultitems(const id)
{
	if(!g_zombie[id])
		return HC_CONTINUE

	give_zombie_knife(id)
	return HC_SUPERCEDE
}

public rg_player_resetmaxspeed(const id)
{
	if(g_zombie[id] && is_user_alive(id))
		set_pev(id, pev_maxspeed, g_class_data[g_player_class[id]][DATA_SPEED] + g_mutation[id] * cvar_mutation_speed)

	return HC_CONTINUE
}

// The engine must not overwrite the zombie model with the team model
public rg_player_setmodel(const id, infobuffer[], szNewModel[])
{
	if(g_zombie[id] && !g_setting_model)
		return HC_SUPERCEDE

	return HC_CONTINUE
}

// Zombie claws use the class view model
public rg_weapon_defaultdeploy(const weapon, szViewModel[], szWeaponModel[], iAnim, szAnimExt[], skiplocal)
{
	static id
	id = get_member(weapon, m_pPlayer)

	if(!is_valid_player(id) || !g_zombie[id])
		return HC_CONTINUE

	SetHookChainArg(2, ATYPE_STRING, g_class_wmodel[g_player_class[id]])
	SetHookChainArg(3, ATYPE_STRING, "")
	return HC_CONTINUE
}

public rg_player_traceattack(const victim, attacker, Float:damage, Float:direction[3], tracehandle, damagetype)
{
	if(!g_gamestarted)
		return HC_SUPERCEDE

	if(!cvar_knockback || !(damagetype & DMG_BULLET) || !g_zombie[victim] || !is_valid_player(attacker))
		return HC_CONTINUE

	static kbpower
	kbpower = g_weapon_knockback[get_user_weapon(attacker)]

	if(kbpower == -1)
		return HC_CONTINUE

	static flags
	flags = pev(victim, pev_flags)

	if(cvar_knockback_duck && (flags & FL_DUCKING) && (flags & FL_ONGROUND))
		return HC_CONTINUE

	static Float:origins[2][3]
	pev(victim, pev_origin, origins[0])
	pev(attacker, pev_origin, origins[1])

	if(get_distance_f(origins[0], origins[1]) > cvar_knockback_dist)
		return HC_CONTINUE

	static Float:velocity[3], Float:push[3], Float:zvel
	pev(victim, pev_velocity, velocity)
	zvel = velocity[2]

	xs_vec_mul_scalar(direction, damage * g_class_data[g_player_class[victim]][DATA_KNOCKBACK] * g_knockbackpower[kbpower], push)
	xs_vec_add(push, velocity, velocity)
	velocity[2] = zvel

	set_pev(victim, pev_velocity, velocity)
	return HC_CONTINUE
}

public rg_player_takedamage(const victim, inflictor, attacker, Float:damage, damagetype)
{
	if(damagetype & DMG_GENERIC || victim == attacker || !is_valid_player(attacker) || !is_user_alive(victim) || !is_user_connected(attacker))
		return HC_CONTINUE

	if(!g_gamestarted || (!g_zombie[victim] && !g_zombie[attacker]) || ((damagetype & DMG_HEGRENADE) && g_zombie[attacker]))
	{
		SetHookChainReturn(ATYPE_INTEGER, 0)
		return HC_SUPERCEDE
	}

	if(!g_zombie[attacker])
	{
		static pclass
		pclass = g_player_class[victim]

		damage *= (damagetype & DMG_HEGRENADE) ? g_class_data[pclass][DATA_HEDEFENCE] : g_class_data[pclass][DATA_DEFENCE]
		SetHookChainArg(4, ATYPE_FLOAT, damage)
	}
	else
	{
		if(get_user_weapon(attacker) != CSW_KNIFE)
		{
			SetHookChainReturn(ATYPE_INTEGER, 0)
			return HC_SUPERCEDE
		}

		damage *= g_class_data[g_player_class[attacker]][DATA_ATTACK] * (1.0 + g_mutation[attacker] * cvar_mutation_attack)

		static Float:armor
		pev(victim, pev_armorvalue, armor)

		if(cvar_obeyarmor && armor > 0.0)
		{
			armor -= damage

			if(armor < 0.0)
				armor = 0.0

			set_pev(victim, pev_armorvalue, armor)
			SetHookChainArg(4, ATYPE_FLOAT, 0.0)
		}
		else
		{
			static bool:infect
			infect = allow_infection()

			g_victim[attacker] = infect ? victim : 0

			SetHookChainArg(4, ATYPE_FLOAT, (g_infecting || infect) ? 0.0 : damage)
		}
	}
	return HC_CONTINUE
}

// Replaces the Damage event: zombie pain handling and the actual infection
public rg_player_takedamage_post(const victim, inflictor, attacker, Float:damage, damagetype)
{
	if(!g_gamestarted || !is_user_alive(victim))
		return HC_CONTINUE

	if(g_zombie[victim])
	{
		static pclass
		pclass = g_player_class[victim]

		g_regendelay[victim] = get_gametime() + g_class_data[pclass][DATA_HITREGENDLY]

		// Pain shock: ducking zombies are not slowed, others only by DATA_HITSPEED
		if(cvar_painshockfree)
			set_member(victim, m_flVelocityModifier, (pev(victim, pev_flags) & FL_DUCKING) ? 1.0 : g_class_data[pclass][DATA_HITSPEED])

		return HC_CONTINUE
	}

	if(g_infecting || !is_valid_player(attacker) || !g_zombie[attacker] || g_victim[attacker] != victim || !is_user_alive(attacker))
		return HC_CONTINUE

	g_infecting = true
	g_victim[attacker] = 0

	message_begin(MSG_ALL, g_msg_deathmsg)
	write_byte(attacker)
	write_byte(victim)
	write_byte(0)
	write_string(g_infection_name)
	message_end()

	message_begin(MSG_ALL, g_msg_scoreattrib)
	write_byte(victim)
	write_byte(0)
	message_end()

	infect_user(victim, attacker)
	mutate_zombie(attacker)

	g_stat_infects[attacker]++
	award_xp(attacker, cvar_xp_infect)

	static Float:frags
	pev(attacker, pev_frags, frags)

	set_pev(attacker, pev_frags, frags + 1.0)
	set_member(victim, m_iDeaths, get_member(victim, m_iDeaths) + 1)

	rg_add_account(attacker, cvar_infectmoney, AS_ADD)

	static params[2]
	params[0] = attacker
	params[1] = victim

	set_task(0.3, "task_updatescore", TASKID_UPDATESCR, params, 2)

	g_infecting = false
	return HC_CONTINUE
}

public rg_player_killed(const victim, killer, shouldgib)
{
	if(!g_zombie[victim] || !is_valid_player(killer) || g_zombie[killer] || !is_user_alive(killer))
		return HC_CONTINUE

	if(cvar_killbonus)
	{
		static Float:frags
		pev(killer, pev_frags, frags)
		set_pev(killer, pev_frags, frags + float(cvar_killbonus))
	}

	switch(cvar_killreward)
	{
		case 1: reward_clip(killer)
		case 2: reward_grenade(killer)
		case 3:
		{
			reward_clip(killer)
			reward_grenade(killer)
		}
	}
	return HC_CONTINUE
}

// Zombie respawn: queued when a zombie dies, cancelled once one survivor is left
public rg_player_killed_post(const victim, killer, shouldgib)
{
	hud_check_later()

	// A zombie that kills a survivor mutates, a zombie that dies loses its mutations
	if(!g_zombie[victim] && is_valid_player(killer) && g_zombie[killer])
	{
		mutate_zombie(killer)

		g_stat_infects[killer]++
		award_xp(killer, cvar_xp_infect)
	}
	else if(g_zombie[victim] && is_valid_player(killer) && !g_zombie[killer] && killer != victim)
	{
		g_stat_kills[killer]++
		award_xp(killer, cvar_xp_kill)
	}

	if(g_zombie[victim] && g_mutation[victim])
		mutation_reset(victim)

	if(!cvar_zombie_respawn || !g_zombie[victim] || !g_gamestarted || g_roundended)
		return HC_CONTINUE

	if(count_survivors() <= 1)
	{
		client_print(victim, print_center, "Last survivor left, no respawn!")
		return HC_CONTINUE
	}

	remove_task(TASKID_ZRESPAWN + victim)
	set_task(cvar_zombie_respawn_time, "task_zombie_respawn", TASKID_ZRESPAWN + victim)

	client_print(victim, print_center, "Respawning in %.0f seconds...", cvar_zombie_respawn_time)
	return HC_CONTINUE
}

public task_zombie_respawn(taskid)
{
	static id, team
	id = taskid - TASKID_ZRESPAWN

	if(!cvar_zombie_respawn || !g_gamestarted || g_roundended || !is_user_connected(id) || is_user_alive(id) || !g_zombie[id])
		return

	team = get_member(id, m_iTeam)
	if(!is_playing_team(team))
		return

	// The rule is checked again at respawn time, the survivor count may have changed
	if(count_survivors() <= 1)
	{
		client_print(id, print_center, "Last survivor left, no respawn!")
		return
	}

	g_zrespawn[id] = true
	rg_round_respawn(id)
}

// Alive humans
stock count_survivors()
{
	static id, count
	count = 0

	for(id = 1; id <= g_maxplayers; id++)
	{
		if(!g_zombie[id] && is_user_alive(id))
			count++
	}
	return count
}

/* ------------------------------------------------------------------ */
/* Persistent stats (nvault)                                           */
/* ------------------------------------------------------------------ */

// XP needed to reach a level: 100 * level^2
stock xp_for_level(level)
	return 100 * level * level

stock level_from_xp(xp)
	return min(floatround(floatsqroot(float(xp) / 100.0), floatround_floor), max(cvar_maxlevel, 0))

stats_clear(id)
{
	g_xp[id] = 0
	g_level[id] = 0
	g_stat_infects[id] = 0
	g_stat_kills[id] = 0
	g_stats_loaded[id] = false
	g_stat_key[id][0] = 0
}

public client_authorized(id, const authid[])
{
	if(!cvar_enabled || !cvar_stats || g_vault == INVALID_HANDLE || is_user_bot(id) || is_user_hltv(id))
		return

	stats_clear(id)

	// LAN / pending ids are not unique, use the name for them
	if(equal(authid, "STEAM_ID_LAN") || equal(authid, "VALVE_ID_LAN") || equal(authid, "STEAM_ID_PENDING") || equal(authid, "HLTV") || !authid[0])
	{
		static name[32]
		get_user_name(id, name, charsmax(name))
		formatex(g_stat_key[id], charsmax(g_stat_key[]), "N:%s", name)
	}
	else
		copy(g_stat_key[id], charsmax(g_stat_key[]), authid)

	static data[64], timestamp, a[12], b[12], c[12]

	if(nvault_lookup(g_vault, g_stat_key[id], data, charsmax(data), timestamp))
	{
		parse(data, a, charsmax(a), b, charsmax(b), c, charsmax(c))

		g_xp[id] = str_to_num(a)
		g_stat_infects[id] = str_to_num(b)
		g_stat_kills[id] = str_to_num(c)
	}

	g_level[id] = level_from_xp(g_xp[id])
	g_stats_loaded[id] = true
}

stats_save(id)
{
	if(!g_stats_loaded[id] || g_vault == INVALID_HANDLE)
		return

	static data[64]
	formatex(data, charsmax(data), "%d %d %d", g_xp[id], g_stat_infects[id], g_stat_kills[id])

	nvault_set(g_vault, g_stat_key[id], data)
}

stats_save_all()
{
	for(new id = 1; id <= g_maxplayers; id++)
	{
		if(g_stats_loaded[id])
			stats_save(id)
	}
}

award_xp(id, amount)
{
	if(!cvar_stats || amount <= 0 || !is_valid_player(id) || !g_stats_loaded[id])
		return

	static newlevel
	g_xp[id] += amount
	newlevel = level_from_xp(g_xp[id])

	if(newlevel <= g_level[id])
		return

	g_level[id] = newlevel

	static name[32]
	get_user_name(id, name, charsmax(name))

	set_hudmessage(255, 215, 0, -1.0, 0.35, 0, 0.0, 4.0, 0.1, 0.5)
	ShowSyncHudMsg(id, g_sync_msgdisplay, "LEVEL UP!^nYou reached level %d", newlevel)
	client_print(0, print_chat, "[Biohazard] %s reached level %d!", name, newlevel)
}

public cmd_rank(id)
{
	if(!cvar_stats || !g_stats_loaded[id])
	{
		client_print(id, print_chat, "[Biohazard] Your stats are not available yet.")
		return PLUGIN_HANDLED
	}

	static pos, total, other
	pos = 1
	total = 0

	for(other = 1; other <= g_maxplayers; other++)
	{
		if(!g_stats_loaded[other])
			continue

		total++

		if(g_xp[other] > g_xp[id])
			pos++
	}

	if(g_level[id] >= cvar_maxlevel)
		client_print(id, print_chat, "[Biohazard] Level %d (MAX), %d XP", g_level[id], g_xp[id])
	else
		client_print(id, print_chat, "[Biohazard] Level %d, %d/%d XP to level %d", g_level[id], g_xp[id], xp_for_level(g_level[id] + 1), g_level[id] + 1)

	client_print(id, print_chat, "[Biohazard] Infections: %d, Zombie kills: %d, Rank: %d/%d online", g_stat_infects[id], g_stat_kills[id], pos, total)
	return PLUGIN_HANDLED
}

// Top players currently on the server
public cmd_top(id)
{
	static order[32], count, other, i, j, tmp, name[32]
	count = 0

	for(other = 1; other <= g_maxplayers; other++)
	{
		if(g_stats_loaded[other])
			order[count++] = other
	}

	// Insertion sort by XP, highest first
	for(i = 1; i < count; i++)
	{
		tmp = order[i]

		for(j = i - 1; j >= 0 && g_xp[order[j]] < g_xp[tmp]; j--)
			order[j + 1] = order[j]

		order[j + 1] = tmp
	}

	client_print(id, print_chat, "[Biohazard] Top players online:")

	for(i = 0; i < count && i < 5; i++)
	{
		get_user_name(order[i], name, charsmax(name))
		client_print(id, print_chat, "%d. %s - Level %d (%d XP)", i + 1, name, g_level[order[i]], g_xp[order[i]])
	}
	return PLUGIN_HANDLED
}

/* ------------------------------------------------------------------ */
/* HUD status icons (sprites_on_hud)                                   */
/* ------------------------------------------------------------------ */

/* Sprite generator: the .spr files are written by the plugin itself at every map start,
 * so nothing binary has to be copied to the server (and FTP text mode cannot corrupt it). */

#define ICON_SIZE 48
#define ICON_PIXELS (ICON_SIZE * ICON_SIZE)

// Palette indexes, 255 is the transparent one
#define PAL_WHITE 1
#define PAL_RED 2
#define PAL_YELLOW 3
#define PAL_GREEN 4
#define PAL_ORANGE 5
#define PAL_NONE 255

// 5x7 digit font, one row per entry, bit 4 is the leftmost pixel
new const g_icon_font[10][7] =
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

new g_icon[ICON_PIXELS]

cv_clear()
	arrayset(g_icon, PAL_NONE, ICON_PIXELS)

cv_set(x, y, color)
{
	if(x >= 0 && x < ICON_SIZE && y >= 0 && y < ICON_SIZE)
		g_icon[y * ICON_SIZE + x] = color
}

cv_rect(x0, y0, x1, y1, color)
{
	for(new y = y0; y <= y1; y++)
	{
		for(new x = x0; x <= x1; x++)
			cv_set(x, y, color)
	}
}

cv_circle(cx, cy, r, color)
{
	for(new y = cy - r; y <= cy + r; y++)
	{
		for(new x = cx - r; x <= cx + r; x++)
		{
			if((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r)
				cv_set(x, y, color)
		}
	}
}

bool:cv_inside(const Float:pts[][2], count, Float:x, Float:y)
{
	new bool:inside = false, j = count - 1

	for(new i = 0; i < count; i++)
	{
		if((pts[i][1] > y) != (pts[j][1] > y)
		&& x < (pts[j][0] - pts[i][0]) * (y - pts[i][1]) / (pts[j][1] - pts[i][1]) + pts[i][0])
			inside = !inside

		j = i
	}
	return inside
}

cv_polygon(const Float:pts[][2], count, color)
{
	for(new y = 0; y < ICON_SIZE; y++)
	{
		for(new x = 0; x < ICON_SIZE; x++)
		{
			if(cv_inside(pts, count, float(x) + 0.5, float(y) + 0.5))
				cv_set(x, y, color)
		}
	}
}

cv_triangle(x0, y0, x1, y1, x2, y2, color)
{
	new Float:pts[3][2]

	pts[0][0] = float(x0), pts[0][1] = float(y0)
	pts[1][0] = float(x1), pts[1][1] = float(y1)
	pts[2][0] = float(x2), pts[2][1] = float(y2)

	cv_polygon(pts, 3, color)
}

cv_star(cx, cy, r, color)
{
	new Float:pts[10][2], Float:angle, Float:radius

	for(new i = 0; i < 10; i++)
	{
		angle = -1.5707963 + float(i) * 0.6283185
		radius = (i % 2 == 0) ? float(r) : float(r) * 0.45

		pts[i][0] = float(cx) + radius * floatcos(angle, radian)
		pts[i][1] = float(cy) + radius * floatsin(angle, radian)
	}
	cv_polygon(pts, 10, color)
}

// Centered number 1-10
cv_number(number, scale, color)
{
	new digits[2], count, i, row, col, x, y

	if(number >= 10)
		digits[count++] = number / 10

	digits[count++] = number % 10

	x = (ICON_SIZE - (count * 5 * scale + (count - 1) * scale)) / 2
	y = (ICON_SIZE - 7 * scale) / 2

	for(i = 0; i < count; i++)
	{
		for(row = 0; row < 7; row++)
		{
			for(col = 0; col < 5; col++)
			{
				if(g_icon_font[digits[i]][row] & (1 << (4 - col)))
					cv_rect(x + col * scale, y + row * scale, x + col * scale + scale - 1, y + row * scale + scale - 1, color)
			}
		}
		x += 6 * scale
	}
}

// Writes the canvas as a single frame, 8-bit paletted, alpha test sprite
hud_write_sprite(const name[])
{
	static path[64], palette[768], header[4], bool:ready

	formatex(path, charsmax(path), "sprites/%s.spr", name)

	new file = fopen(path, "wb")
	if(!file)
	{
		log_amx("Could not write %s, HUD icon will be missing", path)
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
	fwrite(file, _:33.936, BLOCK_INT)           // bounding radius
	fwrite(file, ICON_SIZE, BLOCK_INT)          // width
	fwrite(file, ICON_SIZE, BLOCK_INT)          // height
	fwrite(file, 1, BLOCK_INT)                  // frames
	fwrite(file, 0, BLOCK_INT)                  // beam length
	fwrite(file, 0, BLOCK_INT)                  // sync type
	fwrite(file, 256, BLOCK_SHORT)              // palette colors
	fwrite_blocks(file, palette, 768, BLOCK_BYTE)

	fwrite(file, 0, BLOCK_INT)                  // frame group
	fwrite(file, -ICON_SIZE / 2, BLOCK_INT)     // origin x
	fwrite(file, ICON_SIZE / 2, BLOCK_INT)      // origin y
	fwrite(file, ICON_SIZE, BLOCK_INT)
	fwrite(file, ICON_SIZE, BLOCK_INT)
	fwrite_blocks(file, g_icon, ICON_PIXELS, BLOCK_BYTE)

	fclose(file)
}

hud_generate_sprites()
{
	static name[32], i, j, x, color, r

	for(i = 1; i <= 10; i++)
	{
		cv_clear()
		cv_number(i, (i < 10) ? 4 : 3, (i > 3) ? PAL_YELLOW : PAL_RED)

		formatex(name, charsmax(name), "bh_cd_%d", i)
		hud_write_sprite(name)
	}

	for(i = 1; i <= 5; i++)
	{
		cv_clear()

		switch(i)
		{
			case 1, 2: color = PAL_GREEN
			case 3: color = PAL_YELLOW
			case 4: color = PAL_ORANGE
			default: color = PAL_RED
		}

		r = (i <= 3) ? 9 : 7
		x = (ICON_SIZE - (i * (2 * r + 2) - 2)) / 2 + r

		for(j = 0; j < i; j++)
		{
			cv_star(x, ICON_SIZE / 2, r, color)
			x += 2 * r + 2
		}

		formatex(name, charsmax(name), "bh_mut_%d", i)
		hud_write_sprite(name)
	}

	// Last survivor: warning triangle with an exclamation mark
	cv_clear()
	cv_triangle(24, 4, 45, 42, 3, 42, PAL_YELLOW)
	cv_triangle(24, 12, 38, 37, 10, 37, PAL_NONE)
	cv_rect(22, 18, 25, 30, PAL_YELLOW)
	cv_rect(22, 33, 25, 36, PAL_YELLOW)
	hud_write_sprite("bh_last")

	// No more respawns: skull
	cv_clear()
	cv_circle(24, 20, 14, PAL_WHITE)
	cv_rect(15, 28, 33, 40, PAL_WHITE)
	cv_circle(18, 20, 4, PAL_NONE)
	cv_circle(30, 20, 4, PAL_NONE)
	cv_triangle(24, 24, 21, 30, 27, 30, PAL_NONE)

	for(i = 0; i < 4; i++)
		cv_rect(18 + i * 4, 34, 19 + i * 4, 40, PAL_NONE)

	hud_write_sprite("bh_norespawn")
}

// Must run in plugin_precache; missing sprite files just give InvalidHudSprite
hud_precache()
{
	static name[32], i

	hud_generate_sprites()

	for(i = 1; i <= 10; i++)
	{
		formatex(name, charsmax(name), "bh_cd_%d", i)
		g_hs_countdown[i] = HS_PrecacheSprite(name, 0, HUD_OFFSET_Y)
	}

	for(i = 1; i <= 5; i++)
	{
		formatex(name, charsmax(name), "bh_mut_%d", i)
		g_hs_mutation[i] = HS_PrecacheSprite(name, 0, HUD_OFFSET_Y)
	}

	g_hs_last = HS_PrecacheSprite("bh_last", 0, HUD_OFFSET_Y)
	g_hs_norespawn = HS_PrecacheSprite("bh_norespawn", 0, HUD_OFFSET_Y)
}

hud_reset_player(id)
{
	for(new status = 0; status < HUD_STATUS_COUNT; status++)
		g_hud_status[id][status] = InvalidHudSprite

	g_hud_shown[id] = InvalidHudSprite
	g_hud_rot[id] = 0
}

stock hud_set(id, status, HudSprite:sprite)
{
	if(!is_valid_player(id) || g_hud_status[id][status] == sprite)
		return

	g_hud_status[id][status] = sprite
	hud_refresh(id)
}

stock hud_clear(id, status)
	hud_set(id, status, InvalidHudSprite)

// Shows the sprite of the active status; with several active ones the rotation index picks
hud_refresh(id)
{
	if(!is_user_connected(id))
		return

	static HudSprite:list[HUD_STATUS_COUNT], HudSprite:target, count, status
	count = 0

	if(cvar_hud && !g_hud_off[id])
	{
		for(status = 0; status < HUD_STATUS_COUNT; status++)
		{
			if(g_hud_status[id][status] != InvalidHudSprite)
				list[count++] = g_hud_status[id][status]
		}
	}

	if(!count)
	{
		if(g_hud_shown[id] != InvalidHudSprite)
		{
			HS_ClearSprite(id)
			g_hud_shown[id] = InvalidHudSprite
		}
		return
	}

	target = list[g_hud_rot[id] % count]

	if(target != g_hud_shown[id])
	{
		HS_DrawSprite(id, target)
		g_hud_shown[id] = target
	}
}

// Every few seconds players with more than one active status see the next one
public task_hud_rotate()
{
	if(!cvar_hud)
		return

	static id, status, active

	for(id = 1; id <= g_maxplayers; id++)
	{
		if(!is_user_connected(id))
			continue

		active = 0

		for(status = 0; status < HUD_STATUS_COUNT; status++)
		{
			if(g_hud_status[id][status] != InvalidHudSprite)
				active++
		}

		if(active > 1)
		{
			g_hud_rot[id]++
			hud_refresh(id)
		}
	}
}

public cmd_hud(id)
{
	g_hud_off[id] = !g_hud_off[id]
	hud_refresh(id)

	client_print(id, print_chat, "[Biohazard] HUD icons %s.", g_hud_off[id] ? "disabled" : "enabled")
	return PLUGIN_HANDLED
}

// Last 10 seconds before the first zombie appears
countdown_start()
{
	g_infect_time = get_gametime() + cvar_starttime
	g_cd_last = 0

	remove_task(TASKID_COUNTDOWN)

	if(cvar_hud)
		set_task(0.2, "task_countdown", TASKID_COUNTDOWN, _, _, "b")
}

countdown_stop()
{
	remove_task(TASKID_COUNTDOWN)
	g_cd_last = 0

	for(new id = 1; id <= g_maxplayers; id++)
		hud_clear(id, HUD_COUNTDOWN)
}

public task_countdown()
{
	static remaining, id
	remaining = floatround(g_infect_time - get_gametime(), floatround_ceil)

	if(remaining < 1)
	{
		countdown_stop()
		return
	}

	if(remaining > 10 || remaining == g_cd_last)
		return

	g_cd_last = remaining

	for(id = 1; id <= g_maxplayers; id++)
		hud_set(id, HUD_COUNTDOWN, g_hs_countdown[remaining])
}

// Last survivor gets a warning icon and so do zombies that can no longer respawn.
// Coalesced so many events in the same moment cause a single scan.
hud_check_later()
{
	if(!cvar_hud)
		return

	remove_task(TASKID_HUDCHECK)
	set_task(0.1, "task_hud_check", TASKID_HUDCHECK)
}

public task_hud_check()
{
	static id, last
	last = 0

	if(g_gamestarted && !g_roundended && count_survivors() == 1)
	{
		for(id = 1; id <= g_maxplayers; id++)
		{
			if(!g_zombie[id] && is_user_alive(id))
			{
				last = id
				break
			}
		}
	}

	for(id = 1; id <= g_maxplayers; id++)
	{
		if(!is_user_connected(id))
			continue

		if(id == last)
			hud_set(id, HUD_LASTSURV, g_hs_last)
		else
			hud_clear(id, HUD_LASTSURV)

		if(last && g_zombie[id] && cvar_zombie_respawn)
			hud_set(id, HUD_NORESPAWN, g_hs_norespawn)
		else
			hud_clear(id, HUD_NORESPAWN)
	}
}

/* ------------------------------------------------------------------ */
/* Mutation: zombies get stronger with every survivor they take down   */
/* ------------------------------------------------------------------ */

stock Float:zombie_max_health(id)
	return g_class_data[g_player_class[id]][DATA_HEALTH] + g_mutation[id] * cvar_mutation_health

mutate_zombie(id)
{
	if(!is_valid_player(id) || !g_zombie[id] || !is_user_alive(id) || g_mutation[id] >= cvar_mutation_max)
		return

	static Float:health
	g_mutation[id]++

	// Instant heal for the bonus health, then the new speed
	pev(id, pev_health, health)
	set_pev(id, pev_health, floatmin(health + cvar_mutation_health, zombie_max_health(id)))
	rg_reset_maxspeed(id)
	mutation_glow(id)
	hud_set(id, HUD_MUTATION, g_hs_mutation[min(g_mutation[id], 5)])

	set_hudmessage(80, 255, 80, -1.0, 0.3, 0, 0.0, 3.0, 0.1, 0.5)
	ShowSyncHudMsg(id, g_sync_msgdisplay, "MUTATION %d/%d^nStronger, faster, deadlier!", g_mutation[id], cvar_mutation_max)
}

mutation_reset(id)
{
	g_mutation[id] = 0
	mutation_glow(id)
	hud_clear(id, HUD_MUTATION)
}

// Glow shell gets stronger and redder with each level
mutation_glow(id)
{
	static Float:color[3], Float:fraction

	if(g_mutation[id] <= 0)
	{
		set_pev(id, pev_renderfx, kRenderFxNone)
		set_pev(id, pev_renderamt, 0.0)
		return
	}

	fraction = float(g_mutation[id]) / float(max(cvar_mutation_max, 1))

	color[0] = 60.0 + 195.0 * fraction
	color[1] = 255.0 - 215.0 * fraction
	color[2] = 40.0

	set_pev(id, pev_renderfx, kRenderFxGlowShell)
	set_pev(id, pev_rendercolor, color)
	set_pev(id, pev_renderamt, 10.0 + 20.0 * fraction)
}

reward_clip(id)
{
	static weapon, maxclip
	weapon = get_user_weapon(id)
	maxclip = g_weapon_ammo[weapon][MAX_CLIP]

	if(maxclip > 0)
		rg_set_user_ammo(id, WeaponIdType:weapon, maxclip)
}

reward_grenade(id)
{
	if(!rg_has_item_by_name(id, "weapon_hegrenade"))
		rg_give_item(id, "weapon_hegrenade")
}

public rg_player_spawn_post(const id)
{
	hud_check_later()

	if(!is_user_alive(id))
		return HC_CONTINUE

	static team
	team = get_member(id, m_iTeam)

	if(!is_playing_team(team))
		return HC_CONTINUE

	if(g_zombie[id])
	{
		if((cvar_respawnaszombie || g_zrespawn[id]) && !g_roundended)
		{
			g_zrespawn[id] = false
			set_zombie_attibutes(id)
			return HC_CONTINUE
		}
		cure_user(id)
	}

	set_task(0.3, "task_spawned", TASKID_SPAWNDELAY + id)
	set_task(5.0, "task_checkspawn", TASKID_CHECKSPAWN + id)

	return HC_CONTINUE
}

/* ------------------------------------------------------------------ */
/* Engine forwards                                                     */
/* ------------------------------------------------------------------ */

#define SOUND_IGNORE 0
#define SOUND_BLOCK 1
#define SOUND_REPLACE 2

// Shared sound logic: night vision sounds are muted, zombies use their own claw and death sounds
stock sound_filter(id, channel, const sample[], out[], len)
{
	if(channel == CHAN_ITEM && equal(sample, "items/nvg", 9))
		return SOUND_BLOCK

	if(!is_valid_player(id) || !g_zombie[id] || !is_user_connected(id))
		return SOUND_IGNORE

	static s[32]
	copy(s, charsmax(s), sample)

	if(s[8] == 'k' && s[9] == 'n' && s[10] == 'i')
	{
		if(s[14] == 's' && s[15] == 'l' && s[16] == 'a')
		{
			copy(out, len, g_zombie_miss_sounds[_random(sizeof g_zombie_miss_sounds)])
			return SOUND_REPLACE
		}

		if(s[14] == 'h' && s[15] == 'i' && s[16] == 't' || s[14] == 's' && s[15] == 't' && s[16] == 'a')
		{
			if(s[17] == 'w' && s[18] == 'a' && s[19] == 'l')
				copy(out, len, g_zombie_miss_sounds[_random(sizeof g_zombie_miss_sounds)])
			else
				copy(out, len, g_zombie_hit_sounds[_random(sizeof g_zombie_hit_sounds)])

			return SOUND_REPLACE
		}
	}
	else if(s[7] == 'd' && (s[8] == 'i' && s[9] == 'e' || s[12] == '6'))
	{
		copy(out, len, g_zombie_die_sounds[_random(sizeof g_zombie_die_sounds)])
		return SOUND_REPLACE
	}
	return SOUND_IGNORE
}

// ReHLDS: the sample is swapped before the engine sends it, nothing is re-emitted
public rh_sv_startsound(const recipients, const entity, const channel, const sample[], const volume, Float:attenuation, const fFlags, const pitch)
{
	static out[64]

	switch(sound_filter(entity, channel, sample, out, charsmax(out)))
	{
		case SOUND_BLOCK: return HC_SUPERCEDE
		case SOUND_REPLACE: SetHookChainArg(4, ATYPE_STRING, out)
	}
	return HC_CONTINUE
}

// Fallback for servers without ReHLDS
public fwd_emitsound(id, channel, sample[], Float:volume, Float:attn, flag, pitch)
{
	static out[64]

	switch(sound_filter(id, channel, sample, out, charsmax(out)))
	{
		case SOUND_BLOCK: return FMRES_SUPERCEDE
		case SOUND_REPLACE:
		{
			emit_sound(id, channel, out, volume, attn, flag, pitch)
			return FMRES_SUPERCEDE
		}
	}
	return FMRES_IGNORED
}

public fwd_spawn(ent)
{
	if(!pev_valid(ent))
		return FMRES_IGNORED

	static classname[32], i
	pev(ent, pev_classname, classname, charsmax(classname))

	for(i = 0; i < sizeof g_remove_entities; ++i)
	{
		if(equal(classname, g_remove_entities[i]))
		{
			engfunc(EngFunc_RemoveEntity, ent)
			return FMRES_SUPERCEDE
		}
	}
	return FMRES_IGNORED
}

public fwd_gamedescription()
{
	forward_return(FMV_STRING, g_gamedesc)
	return FMRES_SUPERCEDE
}

public fwd_createnamedentity(entclassname)
{
	static classname[10]
	engfunc(EngFunc_SzFromIndex, entclassname, classname, charsmax(classname))

	return (classname[7] == 'c' && classname[8] == '4') ? FMRES_SUPERCEDE : FMRES_IGNORED
}

public fwd_clientkill(id)
{
	if(cvar_punishsuicide && is_user_alive(id))
		g_suicide[id] = true
}

/* ------------------------------------------------------------------ */
/* Ham hooks for world entities                                        */
/* ------------------------------------------------------------------ */

public bacon_use_tank(ent, caller, activator, use_type, Float:value)
	return (is_valid_player(caller) && g_zombie[caller] && is_user_alive(caller)) ? HAM_SUPERCEDE : HAM_IGNORED

public bacon_use_pushable(ent, caller, activator, use_type, Float:value)
	return HAM_SUPERCEDE

public bacon_touch_grenade(ent, world)
{
	if(!cvar_impactexplode)
		return HAM_IGNORED

	static model[12]
	pev(ent, pev_model, model, charsmax(model))

	if(model[9] == 'h' && model[10] == 'e')
	{
		set_pev(ent, pev_dmgtime, 0.0)
		return HAM_HANDLED
	}
	return HAM_IGNORED
}

public bacon_touch_pushable(ent, id)
{
	static movetype
	movetype = pev(id, pev_movetype)

	if(movetype == MOVETYPE_NOCLIP || movetype == MOVETYPE_NONE)
		return HAM_IGNORED

	if(is_user_alive(id))
	{
		set_pev(id, pev_movetype, MOVETYPE_WALK)

		if(!(pev(id, pev_flags) & FL_ONGROUND))
			return HAM_SUPERCEDE
	}

	if(!cvar_shootobjects)
		return HAM_IGNORED

	static Float:velocity[2][3]
	pev(ent, pev_velocity, velocity[0])

	if(vector_length(velocity[0]) > 0.0)
	{
		pev(id, pev_velocity, velocity[1])
		velocity[1][0] += velocity[0][0]
		velocity[1][1] += velocity[0][1]

		set_pev(id, pev_velocity, velocity[1])
	}
	return HAM_SUPERCEDE
}

public bacon_traceattack_pushable(ent, attacker, Float:damage, Float:direction[3], tracehandle, damagetype)
{
	if(!cvar_shootobjects || !is_user_alive(attacker))
		return HAM_IGNORED

	static Float:velocity[3], Float:zvel
	pev(ent, pev_velocity, velocity)
	zvel = velocity[2]

	xs_vec_mul_scalar(direction, damage * (g_zombie[attacker] ? cvar_pushpwr_zombie : cvar_pushpwr_weapon), direction)
	xs_vec_add(direction, velocity, velocity)
	velocity[2] = zvel

	set_pev(ent, pev_velocity, velocity)
	return HAM_HANDLED
}

/* ------------------------------------------------------------------ */
/* Tasks                                                               */
/* ------------------------------------------------------------------ */

public task_spawned(taskid)
{
	static id
	id = taskid - TASKID_SPAWNDELAY

	if(!is_user_alive(id))
		return

	if(g_welcomemsg[id])
	{
		g_welcomemsg[id] = false

		static message[192]
		formatex(message, charsmax(message), "%L", id, "WELCOME_TXT")
		replace(message, charsmax(message), "#Version#", VERSION)

		client_print(id, print_chat, message)

		if(cvar_class_motd && g_classcount > 1)
			cmd_classmenu(id)

		if(g_stats_loaded[id])
			client_print(id, print_chat, "[Biohazard] Level %d, %d XP. Type /rank for your stats, /top for the best players.", g_level[id], g_xp[id])
	}

	if(g_suicide[id])
	{
		g_suicide[id] = false

		user_silentkill(id)
		remove_task(TASKID_CHECKSPAWN + id)

		client_print(id, print_chat, "%L", id, "SUICIDEPUNISH_TXT")
		return
	}

	if(cvar_weaponsmenu && g_roundstarted && g_showmenu[id])
	{
		if(is_user_bot(id))
			bot_weapons(id)
		else
			display_equipmenu(id)
	}

	if(!g_gamestarted)
		client_print(id, print_chat, "%L %L", id, "SCAN_RESULTS", id, g_preinfect[id] ? "SCAN_INFECTED" : "SCAN_CLEAN")
	else if(get_member(id, m_iTeam) == _:TEAM_TERRORIST)
		rg_set_user_team(id, _:TEAM_CT, MODEL_UNASSIGNED)
}

public task_checkspawn(taskid)
{
	static id, team
	id = taskid - TASKID_CHECKSPAWN

	if(g_roundended || !is_user_connected(id) || is_user_alive(id))
		return

	// Zombies are handled by the zombie respawn rules (no respawn for the last survivor)
	if(g_zombie[id])
		return

	team = get_member(id, m_iTeam)

	if(is_playing_team(team))
		rg_round_respawn(id)
}

public task_showtruehealth()
{
	set_hudmessage(_, _, _, 0.03, 0.93, _, 0.3, 0.3)

	static id, Float:health, class
	for(id = 1; id <= g_maxplayers; id++)
	{
		if(!g_zombie[id] || !is_user_alive(id) || is_user_bot(id))
			continue

		pev(id, pev_health, health)
		class = g_player_class[id]

		if(g_classcount > 1)
			ShowSyncHudMsg(id, g_sync_hpdisplay, "Health: %0.f  Class: %s (%s)  Mutation: %d/%d", health, g_class_name[class], g_class_desc[class], g_mutation[id], cvar_mutation_max)
		else
			ShowSyncHudMsg(id, g_sync_hpdisplay, "Health: %0.f  Mutation: %d/%d", health, g_mutation[id], cvar_mutation_max)
	}
}

public task_lights()
	engfunc(EngFunc_LightStyle, 0, g_lights)

public task_updatescore(params[])
{
	if(!g_gamestarted)
		return

	static attacker, victim
	attacker = params[0]
	victim = params[1]

	if(!is_user_connected(attacker))
		return

	send_scoreinfo(attacker)

	if(is_user_connected(victim))
		send_scoreinfo(victim)
}

send_scoreinfo(id)
{
	message_begin(MSG_BROADCAST, g_msg_scoreinfo)
	write_byte(id)
	write_short(get_user_frags(id))
	write_short(get_member(id, m_iDeaths))
	write_short(0)
	write_short(get_member(id, m_iTeam))
	message_end()
}

public task_weaponsmenu(taskid)
{
	static id
	id = taskid - TASKID_WEAPONSMENU

	if(g_menufailsafe[id] && !g_zombie[id] && is_user_alive(id))
		display_equipmenu(id)
}

public task_newround()
{
	static players[32], num, zombies, i, id
	get_players(players, num, "a")

	if(num < 2)
		return

	for(i = 0; i < num; i++)
		g_preinfect[players[i]] = false

	// Upper bound is the player count, otherwise the picking loop never ends
	zombies = clamp(floatround(num * cvar_zombiemulti), 1, min(31, num))

	i = 0
	while(i < zombies)
	{
		id = players[_random(num)]
		if(!g_preinfect[id])
		{
			g_preinfect[id] = true
			i++
		}
	}
}

public task_initround()
{
	countdown_stop()

	static players[32], num, i, id, zombiecount, newzombie
	get_players(players, num, "a")

	if(!num)
		return

	zombiecount = 0
	newzombie = 0

	for(i = 0; i < num; i++)
	{
		if(g_preinfect[players[i]])
		{
			newzombie = players[i]
			zombiecount++
		}
	}

	if(zombiecount > 1)
		newzombie = 0
	else if(zombiecount < 1)
		newzombie = players[_random(num)]

	for(i = 0; i < num; i++)
	{
		id = players[i]
		if(id == newzombie || g_preinfect[id])
			infect_user(id, 0)
		else
			rg_set_user_team(id, _:TEAM_CT, MODEL_UNASSIGNED)
	}

	set_hudmessage(_, _, _, _, _, 1)
	if(newzombie)
	{
		static name[32]
		get_user_name(newzombie, name, charsmax(name))

		ShowSyncHudMsg(0, g_sync_msgdisplay, "%L", LANG_PLAYER, "INFECTED_HUD", name)
		client_print(0, print_chat, "%L", LANG_PLAYER, "INFECTED_TXT", name)
	}
	else
	{
		ShowSyncHudMsg(0, g_sync_msgdisplay, "%L", LANG_PLAYER, "INFECTED_HUD2")
		client_print(0, print_chat, "%L", LANG_PLAYER, "INFECTED_TXT2")
	}

	set_task(0.51, "task_startround", TASKID_STARTROUND)
}

public task_startround()
{
	g_gamestarted = true
	ExecuteForward(g_fwd_gamestart, g_fwd_result)

	hud_check_later()

	c4_start()
}

/* ------------------------------------------------------------------ */
/* C4 mission                                                          */
/* ------------------------------------------------------------------ */

c4_reset()
{
	g_c4_active = false

	for(new id = 1; id <= g_maxplayers; id++)
	{
		if(g_c4_progress[id] > 0.0)
			rg_send_bartime(id, 0)

		g_c4_progress[id] = 0.0
	}
}

// Picks a random spawn point as the bomb site; zombies must plant the C4 there
c4_start()
{
	if(!cvar_c4mission || g_spawncount <= 0 || rg_is_bomb_planted())
		return

	copy_spawn_vec(g_c4_site, _random(g_spawncount), 0)
	g_c4_active = true

	// The bomb target scenario must be known to the game rules for the bomb to end the round
	set_member_game(m_bTargetBombed, false)
	set_member_game(m_bMapHasBombTarget, true)

	set_hudmessage(255, 60, 60, -1.0, 0.25, 1, 0.0, 6.0, 0.2, 0.2)
	ShowSyncHudMsg(0, g_sync_c4, "C4 MISSION^nZombies: plant the bomb at the marked ring (hold E)^nSurvivors: stop them and defuse it!")
	client_print(0, print_chat, "[Biohazard] C4 mission started! Zombies must plant the bomb at the red ring.")
}

public task_c4mission()
{
	if(!g_c4_active)
		return

	if(!g_gamestarted || rg_is_bomb_planted())
	{
		// Planted by us (or a round ended): stop tracking
		c4_reset()
		return
	}

	static id, bool:inzone, Float:origin[3], Float:radius, Float:planttime, Float:now
	static ticks
	radius = cvar_c4_radius
	planttime = cvar_c4_planttime

	for(id = 1; id <= g_maxplayers; id++)
	{
		inzone = false

		if(g_zombie[id] && is_user_alive(id))
		{
			pev(id, pev_origin, origin)
			inzone = (get_distance_f(origin, g_c4_site) <= radius)
		}

		if(!inzone || !(pev(id, pev_button) & IN_USE))
		{
			if(g_c4_progress[id] > 0.0)
			{
				g_c4_progress[id] = 0.0
				rg_send_bartime(id, 0)
			}
			continue
		}

		if(g_c4_progress[id] <= 0.0)
			rg_send_bartime(id, max(1, floatround(planttime)))

		g_c4_progress[id] += 0.1

		if(g_c4_progress[id] >= planttime)
		{
			c4_plant(id)
			return
		}
	}

	// Once a second: draw the site ring and hint zombies standing in it
	if(++ticks < 10)
		return

	ticks = 0
	now = float(floatround(radius))

	message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
	write_byte(TE_BEAMCYLINDER)
	engfunc(EngFunc_WriteCoord, g_c4_site[0])
	engfunc(EngFunc_WriteCoord, g_c4_site[1])
	engfunc(EngFunc_WriteCoord, g_c4_site[2])
	engfunc(EngFunc_WriteCoord, g_c4_site[0])
	engfunc(EngFunc_WriteCoord, g_c4_site[1])
	engfunc(EngFunc_WriteCoord, g_c4_site[2] + now)
	write_short(g_spr_ring)
	write_byte(0)
	write_byte(0)
	write_byte(10)
	write_byte(8)
	write_byte(0)
	write_byte(255)
	write_byte(40)
	write_byte(40)
	write_byte(200)
	write_byte(0)
	message_end()

	for(id = 1; id <= g_maxplayers; id++)
	{
		if(g_zombie[id] && g_c4_progress[id] <= 0.0 && is_user_alive(id))
		{
			pev(id, pev_origin, origin)

			if(get_distance_f(origin, g_c4_site) <= radius)
				client_print(id, print_center, "Hold E to plant the C4")
		}
	}
}

c4_plant(planter)
{
	static Float:origin[3], Float:angles[3], flags, ent

	pev(planter, pev_origin, origin)
	pev(planter, pev_angles, angles)
	flags = pev(planter, pev_flags)

	// Put the bomb on the floor under the planter
	origin[2] -= (flags & FL_DUCKING) ? 18.0 : 36.0
	angles[0] = 0.0
	angles[2] = 0.0

	ent = rg_plant_bomb(planter, origin, angles)
	c4_reset()

	if(ent <= 0)
		return

	static name[32]
	get_user_name(planter, name, charsmax(name))

	set_hudmessage(255, 60, 60, -1.0, 0.25, 1, 0.0, 6.0, 0.2, 0.2)
	ShowSyncHudMsg(0, g_sync_c4, "%s planted the C4!^nSurvivors: defuse it before it explodes!", name)
	client_print(0, print_chat, "[Biohazard] %s planted the C4! Survivors must defuse it.", name)
	award_xp(planter, cvar_xp_bomb)
}

public rg_defuse_end_post(const bomb, const player, bool:bDefused)
{
	if(!bDefused || !is_valid_player(player))
		return HC_CONTINUE

	static name[32]
	get_user_name(player, name, charsmax(name))

	client_print(0, print_chat, "[Biohazard] %s defused the C4! Survivors win.", name)
	award_xp(player, cvar_xp_bomb)
	return HC_CONTINUE
}

public task_balanceteam()
{
	static players[4][32], count[4], all[32], num
	count[_:TEAM_TERRORIST] = 0
	count[_:TEAM_CT] = 0

	get_players(all, num)

	static i, id, team
	for(i = 0; i < num; i++)
	{
		id = all[i]
		team = get_member(id, m_iTeam)

		if(is_playing_team(team))
			players[team][count[team]++] = id
	}

	if(abs(count[_:TEAM_TERRORIST] - count[_:TEAM_CT]) <= 1)
		return

	static maxplayers
	maxplayers = (count[_:TEAM_TERRORIST] + count[_:TEAM_CT]) / 2

	if(count[_:TEAM_TERRORIST] > maxplayers)
	{
		for(i = 0; i < (count[_:TEAM_TERRORIST] - maxplayers); i++)
			rg_set_user_team(players[_:TEAM_TERRORIST][i], _:TEAM_CT, MODEL_UNASSIGNED, false)
	}
	else
	{
		for(i = 0; i < (count[_:TEAM_CT] - maxplayers); i++)
			rg_set_user_team(players[_:TEAM_CT][i], _:TEAM_TERRORIST, MODEL_UNASSIGNED, false)
	}
}

bot_weapons(id)
{
	g_player_weapons[id][0] = _random(sizeof g_primaryweapons)
	g_player_weapons[id][1] = _random(sizeof g_secondaryweapons)

	equipweapon(id, EQUIP_ALL)
}

/* ------------------------------------------------------------------ */
/* Infection / cure                                                    */
/* ------------------------------------------------------------------ */

infect_user(victim, attacker)
{
	if(!is_user_alive(victim))
		return

	message_begin(MSG_ONE, g_msg_screenfade, _, victim)
	write_short(1<<10)
	write_short(1<<10)
	write_short(0)
	write_byte((g_mutate[victim] != -1) ? 255 : 100)
	write_byte(100)
	write_byte(100)
	write_byte(250)
	message_end()

	if(g_mutate[victim] != -1)
	{
		g_player_class[victim] = g_mutate[victim]
		g_mutate[victim] = -1

		set_hudmessage(_, _, _, _, _, 1)
		ShowSyncHudMsg(victim, g_sync_msgdisplay, "%L", victim, "MUTATION_HUD", g_class_name[g_player_class[victim]])
	}

	rg_set_user_team(victim, _:TEAM_TERRORIST, MODEL_UNASSIGNED)
	set_zombie_attibutes(victim)

	emit_sound(victim, CHAN_STATIC, g_scream_sounds[_random(sizeof g_scream_sounds)], VOL_NORM, ATTN_NONE, 0, PITCH_NORM)
	ExecuteForward(g_fwd_infect, g_fwd_result, victim, attacker)

	hud_check_later()
}

cure_user(id)
{
	if(!is_user_alive(id))
		return

	static bool:was_zombie
	was_zombie = g_zombie[id]

	g_zombie[id] = false
	mutation_reset(id)

	rg_reset_user_model(id, true)
	set_member(id, m_bHasNightVision, false)
	set_pev(id, pev_gravity, 1.0)

	if(was_zombie)
	{
		// Give the knife back its normal view model
		static knife
		knife = get_member(id, m_rgpPlayerItems, KNIFE_SLOT)

		if(knife > 0 && pev_valid(knife))
			ExecuteHam(Ham_Item_Deploy, knife)
	}
}

// Removes every weapon and hands out the claws
give_zombie_knife(id)
{
	rg_remove_all_items(id)

	g_allow_item = true
	rg_give_item(id, "weapon_knife")
	g_allow_item = false
}

set_zombie_attibutes(const index)
{
	if(!is_valid_player(index) || !is_user_alive(index))
		return

	g_zombie[index] = true

	if(!g_zombies_exist)
	{
		g_zombies_exist = true
		EnableHookChain(g_hc_impulse)
	}

	new iClass = g_player_class[index]
	new Float:flHealth = g_class_data[iClass][DATA_HEALTH] + g_mutation[index] * cvar_mutation_health

	if(g_preinfect[index])
		flHealth *= cvar_zombie_hpmulti

	give_zombie_knife(index)

	set_pev(index, pev_health, flHealth)
	set_pev(index, pev_gravity, g_class_data[iClass][DATA_GRAVITY])
	set_pev(index, pev_body, 0)

	rg_reset_maxspeed(index)
	rg_set_user_armor(index, 0, ARMOR_NONE)
	set_member(index, m_bHasNightVision, true)

	if(cvar_autonvg)
		engclient_cmd(index, "nightvision")

	// Player model straight from the class (models/player/<name>/<name>.mdl)
	new modelname[32]
	get_model_name(g_class_pmodel[iClass], modelname, charsmax(modelname))

	g_setting_model = true
	rg_set_user_model(index, modelname, true)
	g_setting_model = false

	new iEffects = pev(index, pev_effects)
	if(iEffects & EF_DIMLIGHT)
	{
		message_begin(MSG_ONE, g_msg_flashlight, _, index)
		write_byte(0)
		write_byte(100)
		message_end()

		set_pev(index, pev_effects, iEffects & ~EF_DIMLIGHT)
	}
}

// "models/player/slum/slum.mdl" -> "slum"
stock get_model_name(const path[], name[], len)
{
	new start, i
	for(i = 0; path[i]; i++)
	{
		if(path[i] == '/' || path[i] == 92) // 92 = backslash
			start = i + 1
	}

	copy(name, len, path[start])

	i = contain(name, ".mdl")
	if(i != -1)
		name[i] = 0
}

/* ------------------------------------------------------------------ */
/* Menus                                                               */
/* ------------------------------------------------------------------ */

public display_equipmenu(id)
{
	if(!is_valid_player(id) || !is_user_connected(id))
		return

	static menubody[192], bool:hasweap, keys
	hasweap = (g_player_weapons[id][0] != -1 && g_player_weapons[id][1] != -1)

	if(hasweap)
	{
		formatex(menubody, charsmax(menubody), "\y%L^n^n\w1. %L^n\w2. %L^n\w3. %L^n^n\w5. %L^n",
			id, "MENU_TITLE1", id, "MENU_NEWWEAPONS", id, "MENU_PREVSETUP", id, "MENU_DONTSHOW", id, "MENU_EXIT")

		keys = (MENU_KEY_1 | MENU_KEY_2 | MENU_KEY_3 | MENU_KEY_5)
	}
	else
	{
		formatex(menubody, charsmax(menubody), "\y%L^n^n\w1. %L^n\d2. %L^n\d3. %L^n^n\w5. %L^n",
			id, "MENU_TITLE1", id, "MENU_NEWWEAPONS", id, "MENU_PREVSETUP", id, "MENU_DONTSHOW", id, "MENU_EXIT")

		keys = (MENU_KEY_1 | MENU_KEY_5)
	}

	show_menu(id, keys, menubody, -1, "Equipment")
}

public action_equip(id, key)
{
	if(g_zombie[id] || !is_user_alive(id))
		return PLUGIN_HANDLED

	switch(key)
	{
		case 0: display_weaponmenu(id, MENU_PRIMARY, g_menuposition[id] = 0)
		case 1: equipweapon(id, EQUIP_ALL)
		case 2:
		{
			g_showmenu[id] = false
			equipweapon(id, EQUIP_ALL)
			client_print(id, print_chat, "%L", id, "MENU_CMDENABLE")
		}
	}

	if(key > 0)
	{
		g_menufailsafe[id] = false
		remove_task(TASKID_WEAPONSMENU + id)
	}
	return PLUGIN_HANDLED
}

display_weaponmenu(id, menuid, pos)
{
	if(pos < 0 || menuid < 0)
		return

	static start, maxitem
	start = pos * 8
	maxitem = (menuid == MENU_PRIMARY) ? sizeof g_primaryweapons : sizeof g_secondaryweapons

	if(start >= maxitem)
		start = pos = g_menuposition[id]

	static menubody[512], len, end, keys, a, b
	len = formatex(menubody, charsmax(menubody), "\y%L\w^n^n", id, menuid == MENU_PRIMARY ? "MENU_TITLE2" : "MENU_TITLE3")

	end = min(start + 8, maxitem)
	keys = MENU_KEY_0
	b = 0

	for(a = start; a < end; ++a)
	{
		keys |= (1<<b)
		len += formatex(menubody[len], charsmax(menubody) - len, "%d. %s^n", ++b, menuid == MENU_PRIMARY ? g_primaryweapons[a][0] : g_secondaryweapons[a][0])
	}

	if(end != maxitem)
	{
		formatex(menubody[len], charsmax(menubody) - len, "^n9. %L^n0. %L", id, "MENU_MORE", id, pos ? "MENU_BACK" : "MENU_EXIT")
		keys |= MENU_KEY_9
	}
	else
		formatex(menubody[len], charsmax(menubody) - len, "^n0. %L", id, pos ? "MENU_BACK" : "MENU_EXIT")

	show_menu(id, keys, menubody, -1, menuid == MENU_PRIMARY ? "Primary" : "Secondary")
}

public action_prim(id, key)
{
	if(g_zombie[id] || !is_user_alive(id))
		return PLUGIN_HANDLED

	switch(key)
	{
		case 8: display_weaponmenu(id, MENU_PRIMARY, ++g_menuposition[id])
		case 9: display_weaponmenu(id, MENU_PRIMARY, --g_menuposition[id])
		default:
		{
			g_player_weapons[id][0] = g_menuposition[id] * 8 + key
			equipweapon(id, EQUIP_PRI)

			display_weaponmenu(id, MENU_SECONDARY, g_menuposition[id] = 0)
		}
	}
	return PLUGIN_HANDLED
}

public action_sec(id, key)
{
	if(g_zombie[id] || !is_user_alive(id))
		return PLUGIN_HANDLED

	switch(key)
	{
		case 8: display_weaponmenu(id, MENU_SECONDARY, ++g_menuposition[id])
		case 9: display_weaponmenu(id, MENU_SECONDARY, --g_menuposition[id])
		default:
		{
			g_menufailsafe[id] = false
			remove_task(TASKID_WEAPONSMENU + id)

			g_player_weapons[id][1] = g_menuposition[id] * 8 + key
			equipweapon(id, EQUIP_SEC)
			equipweapon(id, EQUIP_GREN)
		}
	}
	return PLUGIN_HANDLED
}

display_classmenu(id, pos)
{
	if(pos < 0)
		return

	static start
	start = pos * 8

	if(start >= g_classcount)
		start = pos = g_menuposition[id]

	static menubody[512], len, end, keys, a, b
	len = formatex(menubody, charsmax(menubody), "\y%L\w^n^n", id, "MENU_TITLE4")

	end = min(start + 8, g_classcount)
	keys = MENU_KEY_0
	b = 0

	for(a = start; a < end; ++a)
	{
		keys |= (1<<b)
		len += formatex(menubody[len], charsmax(menubody) - len, "%d. %s^n", ++b, g_class_name[a])
	}

	if(end != g_classcount)
	{
		formatex(menubody[len], charsmax(menubody) - len, "^n9. %L^n0. %L", id, "MENU_MORE", id, pos ? "MENU_BACK" : "MENU_EXIT")
		keys |= MENU_KEY_9
	}
	else
		formatex(menubody[len], charsmax(menubody) - len, "^n0. %L", id, pos ? "MENU_BACK" : "MENU_EXIT")

	show_menu(id, keys, menubody, -1, "Class")
}

public action_class(id, key)
{
	switch(key)
	{
		case 8: display_classmenu(id, ++g_menuposition[id])
		case 9: display_classmenu(id, --g_menuposition[id])
		default:
		{
			set_next_class(id, g_menuposition[id] * 8 + key)
		}
	}
	return PLUGIN_HANDLED
}

/* ------------------------------------------------------------------ */
/* Config loading                                                      */
/* ------------------------------------------------------------------ */

register_spawnpoints(const mapname[])
{
	new configdir[32], csdmfile[64]
	get_configsdir(configdir, charsmax(configdir))
	formatex(csdmfile, charsmax(csdmfile), "%s/csdm/%s.spawns.cfg", configdir, mapname)

	new file = fopen(csdmfile, "rt")
	if(!file)
		return

	new line[64], data[10][6]
	while(!feof(file))
	{
		fgets(file, line, charsmax(line))
		if(!line[0] || str_count(line, ' ') < 2)
			continue

		parse(line, data[0], 5, data[1], 5, data[2], 5, data[3], 5, data[4], 5, data[5], 5, data[6], 5, data[7], 5, data[8], 5, data[9], 5)

		g_spawns[g_spawncount][0] = floatstr(data[0])
		g_spawns[g_spawncount][1] = floatstr(data[1])
		g_spawns[g_spawncount][2] = floatstr(data[2])
		g_spawns[g_spawncount][3] = floatstr(data[3])
		g_spawns[g_spawncount][4] = floatstr(data[4])
		g_spawns[g_spawncount][5] = floatstr(data[5])
		g_spawns[g_spawncount][6] = floatstr(data[7])
		g_spawns[g_spawncount][7] = floatstr(data[8])
		g_spawns[g_spawncount][8] = floatstr(data[9])

		if(++g_spawncount >= MAX_SPAWNS)
			break
	}
	fclose(file)
}

register_zombieclasses(const filename[])
{
	new configdir[32], configfile[64]
	get_configsdir(configdir, charsmax(configdir))
	formatex(configfile, charsmax(configfile), "%s/%s", configdir, filename)

	if(!cvar_zombie_class || !file_exists(configfile))
	{
		register_class("default")
		return
	}

	new file = fopen(configfile, "rt")
	if(!file)
	{
		register_class("default")
		return
	}

	new line[128], leftstr[32], rightstr[64], classname[32], len, i
	while(!feof(file))
	{
		fgets(file, line, charsmax(line))
		trim(line)

		if(!line[0] || line[0] == ';')
			continue

		len = strlen(line)
		if(line[0] == '[' && line[len - 1] == ']')
		{
			copy(classname, len - 2, line[1])

			if(register_class(classname) == -1)
				break

			continue
		}

		// Properties before the first [class] header have nothing to attach to
		if(g_classcount < 1)
			continue

		strtok(line, leftstr, charsmax(leftstr), rightstr, charsmax(rightstr), '=', 1)

		if(equali(leftstr, "DESC"))
			copy(g_class_desc[g_classcount - 1], 31, rightstr)
		else if(equali(leftstr, "PMODEL"))
			copy(g_class_pmodel[g_classcount - 1], 63, rightstr)
		else if(equali(leftstr, "WMODEL"))
			copy(g_class_wmodel[g_classcount - 1], 63, rightstr)
		else for(i = 0; i < MAX_DATA; i++)
		{
			if(equali(leftstr, g_dataname[i]))
			{
				g_class_data[g_classcount - 1][i] = floatstr(rightstr)
				break
			}
		}
	}
	fclose(file)
}

register_class(const classname[])
{
	if(g_classcount >= MAX_CLASSES)
		return -1

	static id
	id = g_classcount++

	copy(g_class_name[id], 31, classname)
	copy(g_class_pmodel[id], 63, DEFAULT_PMODEL)
	copy(g_class_wmodel[id], 63, DEFAULT_WMODEL)

	g_class_data[id][DATA_HEALTH] = DEFAULT_HEALTH
	g_class_data[id][DATA_SPEED] = DEFAULT_SPEED
	g_class_data[id][DATA_GRAVITY] = DEFAULT_GRAVITY
	g_class_data[id][DATA_ATTACK] = DEFAULT_ATTACK
	g_class_data[id][DATA_DEFENCE] = DEFAULT_DEFENCE
	g_class_data[id][DATA_HEDEFENCE] = DEFAULT_HEDEFENCE
	g_class_data[id][DATA_HITSPEED] = DEFAULT_HITSPEED
	g_class_data[id][DATA_HITDELAY] = DEFAULT_HITDELAY
	g_class_data[id][DATA_REGENDLY] = DEFAULT_REGENDLY
	g_class_data[id][DATA_HITREGENDLY] = DEFAULT_HITREGENDLY
	g_class_data[id][DATA_KNOCKBACK] = DEFAULT_KNOCKBACK

	return id
}

/* ------------------------------------------------------------------ */
/* Natives                                                             */
/* ------------------------------------------------------------------ */

public native_register_class(classname[], description[])
{
	param_convert(1)
	param_convert(2)

	new classid = register_class(classname)

	if(classid != -1)
		copy(g_class_desc[classid], 31, description)

	return classid
}

public native_set_class_pmodel(classid, player_model[])
{
	param_convert(2)
	copy(g_class_pmodel[classid], 63, player_model)
}

public native_set_class_wmodel(classid, weapon_model[])
{
	param_convert(2)
	copy(g_class_wmodel[classid], 63, weapon_model)
}

public native_is_user_zombie(index)
	return (is_valid_player(index) && g_zombie[index]) ? 1 : 0

public native_get_user_class(index)
	return is_valid_player(index) ? g_player_class[index] : 0

public native_is_user_infected(index)
	return (is_valid_player(index) && g_preinfect[index]) ? 1 : 0

public native_game_started()
	return g_gamestarted

public native_preinfect_user(index, bool:yesno)
{
	if(is_valid_player(index) && is_user_alive(index) && !g_gamestarted)
		g_preinfect[index] = yesno
}

public native_infect_user(victim, attacker)
{
	if(g_gamestarted && allow_infection())
		infect_user(victim, attacker)
}

public native_cure_user(index)
	cure_user(index)

public native_get_class_id(classname[])
{
	param_convert(1)

	for(new i = 0; i < g_classcount; i++)
	{
		if(equali(classname, g_class_name[i]))
			return i
	}
	return -1
}

public Float:native_get_class_data(classid, dataid)
	return g_class_data[classid][dataid]

public native_set_class_data(classid, dataid, Float:value)
	g_class_data[classid][dataid] = value

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

stock bool:fm_is_hull_vacant(const Float:origin[3], hull)
{
	static tr
	tr = 0

	engfunc(EngFunc_TraceHull, origin, origin, 0, hull, 0, tr)
	return (!get_tr2(tr, TR_StartSolid) && !get_tr2(tr, TR_AllSolid) && get_tr2(tr, TR_InOpen))
}

stock fm_set_kvd(entity, const key[], const value[], const classname[] = "")
{
	set_kvd(0, KV_ClassName, classname)
	set_kvd(0, KV_KeyName, key)
	set_kvd(0, KV_Value, value)
	set_kvd(0, KV_fHandled, 0)

	return dllfunc(DLLFunc_KeyValue, entity, 0)
}

stock str_count(const str[], searchchar)
{
	static i, count
	count = 0

	for(i = 0; str[i]; i++)
	{
		if(str[i] == searchchar)
			count++
	}
	return count
}

// Single pass over the players; stops as soon as the zombie quota is reached
stock bool:allow_infection()
{
	new iMaxZombies = clamp(cvar_maxzombies, 1, 31)
	new iZombieCount, iHumanCount

	for(new i = 1; i <= g_maxplayers; i++)
	{
		if(g_zombie[i])
		{
			if(is_user_connected(i) && ++iZombieCount >= iMaxZombies)
				return false
		}
		else if(is_user_alive(i))
			iHumanCount++
	}
	return (iHumanCount > 1)
}

stock randomly_pick_zombie()
{
	static zombies[32], humans[32], zcount, hcount, index
	zcount = 0
	hcount = 0

	for(index = 1; index <= g_maxplayers; index++)
	{
		if(!is_user_alive(index))
			continue

		if(g_zombie[index])
			zombies[zcount++] = index
		else
			humans[hcount++] = index
	}

	if(zcount && !hcount)
		return zombies[_random(zcount)]

	return (!zcount && hcount) ? humans[_random(hcount)] : 0
}

// GT_REPLACE swaps whatever sits in the weapon slot, no manual strip needed
stock equipweapon(id, weapon)
{
	if(!is_user_alive(id))
		return

	static weaponid

	if(weapon & EQUIP_PRI)
	{
		weaponid = g_primary_wid[g_player_weapons[id][0]]

		if(!rg_has_item_by_name(id, g_primaryweapons[g_player_weapons[id][0]][1]))
			rg_give_item(id, g_primaryweapons[g_player_weapons[id][0]][1], GT_REPLACE)

		rg_set_user_bpammo(id, WeaponIdType:weaponid, g_weapon_ammo[weaponid][MAX_AMMO])
	}

	if(weapon & EQUIP_SEC)
	{
		weaponid = g_secondary_wid[g_player_weapons[id][1]]

		if(!rg_has_item_by_name(id, g_secondaryweapons[g_player_weapons[id][1]][1]))
			rg_give_item(id, g_secondaryweapons[g_player_weapons[id][1]][1], GT_REPLACE)

		rg_set_user_bpammo(id, WeaponIdType:weaponid, g_weapon_ammo[weaponid][MAX_AMMO])
	}

	if(weapon & EQUIP_GREN)
	{
		static i
		for(i = 0; i < sizeof g_grenades; i++)
		{
			if(!rg_has_item_by_name(id, g_grenades[i]))
				rg_give_item(id, g_grenades[i])
		}
	}
}

// Spreads 8 players per 0.1s step so menus / equips do not all land on one frame
stock add_delay(index, const task[])
	set_task(0.1 * float(((index - 1) >> 3) + 1), task, index)
