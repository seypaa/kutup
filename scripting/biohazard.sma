/*
*  Biohazard 2.00 Beta 3 - modernized / performance build
*
*  Original author: cheap_suit
*
*  Requires AMX Mod X 1.9.0 or greater (bind_pcvar_*, RegisterHamPlayer).
*
*  Main changes compared to the original:
*   - Every cvar used in a hot path is bound with bind_pcvar_*; no get_pcvar_*
*     call is made per frame / per message any more.
*   - Per-frame forwards (PreThink / PostThink / CmdStart / EmitSound) test the
*     cheap g_zombie[] flag first and only then call natives.
*   - RegisterHamPlayer replaces the CZ bot RegisterHamFromEntity workaround
*     (and its polling task).
*   - Weapon ids are resolved once at map start instead of on every equip.
*   - Corpse model lookup uses the cached model entity, not an entity search.
*   - Fixed bugs: fm_lastprimary/secondry/knife macros ignored their argument,
*     bacon_touch_pushable never stored the movetype, task_newround could loop
*     forever when the zombie ratio was larger than the player count,
*     task_initround indexed an empty player list, shadowed `static i`,
*     unchecked entity 0 when giving ammo, stale static in event_curweapon.
*/

#define VERSION	"2.00 Beta 3"

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <hamsandwich>
#include <xs>

#tryinclude "biohazard.cfg"

#if !defined _biohazardcfg_included
	#assert Biohazard configuration file required!
#elseif AMXX_VERSION_NUM < 190
	#assert AMX Mod X v1.9.0 or greater required!
#endif

#define OFFSET_DEATH 444
#define OFFSET_TEAM 114
#define OFFSET_ARMOR 112
#define OFFSET_NVG 129
#define OFFSET_CSMONEY 115
#define OFFSET_PRIMARYWEAPON 116
#define OFFSET_WEAPONTYPE 43
#define OFFSET_CLIPAMMO	51
#define EXTRAOFFSET_WEAPONS 4

#define OFFSET_AMMO_338MAGNUM 377
#define OFFSET_AMMO_762NATO 378
#define OFFSET_AMMO_556NATOBOX 379
#define OFFSET_AMMO_556NATO 380
#define OFFSET_AMMO_BUCKSHOT 381
#define OFFSET_AMMO_45ACP 382
#define OFFSET_AMMO_57MM 383
#define OFFSET_AMMO_50AE 384
#define OFFSET_AMMO_357SIG 385
#define OFFSET_AMMO_9MM 386

#define OFFSET_LASTPRIM 368
#define OFFSET_LASTSEC 369
#define OFFSET_LASTKNI 370

#define TASKID_STRIPNGIVE 698
#define TASKID_NEWROUND	641
#define TASKID_INITROUND 222
#define TASKID_STARTROUND 153
#define TASKID_BALANCETEAM 375
#define TASKID_UPDATESCR 264
#define TASKID_SPAWNDELAY 786
#define TASKID_WEAPONSMENU 564
#define TASKID_CHECKSPAWN 423

#define EQUIP_PRI (1<<0)
#define EQUIP_SEC (1<<1)
#define EQUIP_GREN (1<<2)
#define EQUIP_ALL (1<<0 | 1<<1 | 1<<2)

#define HAS_NVG (1<<0)
#define ATTRIB_BOMB (1<<1)
#define DMG_HEGRENADE (1<<24)

#define MODEL_CLASSNAME "player_model"
#define IMPULSE_FLASHLIGHT 100

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

#define fm_get_user_team(%1) get_pdata_int(%1, OFFSET_TEAM)
#define fm_get_user_deaths(%1) get_pdata_int(%1, OFFSET_DEATH)
#define fm_set_user_deaths(%1,%2) set_pdata_int(%1, OFFSET_DEATH, %2)
#define fm_get_user_money(%1) get_pdata_int(%1, OFFSET_CSMONEY)
#define fm_get_user_armortype(%1) get_pdata_int(%1, OFFSET_ARMOR)
#define fm_set_user_armortype(%1,%2) set_pdata_int(%1, OFFSET_ARMOR, %2)
#define fm_get_weapon_id(%1) get_pdata_int(%1, OFFSET_WEAPONTYPE, EXTRAOFFSET_WEAPONS)
#define fm_get_weapon_ammo(%1) get_pdata_int(%1, OFFSET_CLIPAMMO, EXTRAOFFSET_WEAPONS)
#define fm_set_weapon_ammo(%1,%2) set_pdata_int(%1, OFFSET_CLIPAMMO, %2, EXTRAOFFSET_WEAPONS)
#define fm_reset_user_primary(%1) set_pdata_int(%1, OFFSET_PRIMARYWEAPON, 0)
#define fm_lastprimary(%1) get_pdata_cbase(%1, OFFSET_LASTPRIM)
#define fm_lastsecondry(%1) get_pdata_cbase(%1, OFFSET_LASTSEC)
#define fm_lastknife(%1) get_pdata_cbase(%1, OFFSET_LASTKNI)
#define fm_get_user_model(%1,%2,%3) engfunc(EngFunc_InfoKeyValue, engfunc(EngFunc_GetInfoKeyBuffer, %1), "model", %2, %3)

#define _random(%1) random_num(0, %1 - 1)
#define AMMOWP_NULL (1<<0 | 1<<CSW_KNIFE | 1<<CSW_FLASHBANG | 1<<CSW_HEGRENADE | 1<<CSW_SMOKEGRENADE | 1<<CSW_C4)
#define is_valid_player(%1) (1 <= %1 <= MaxClients)

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
	CS_TEAM_UNASSIGNED = 0,
	CS_TEAM_T,
	CS_TEAM_CT,
	CS_TEAM_SPECTATOR
}

enum
{
	CS_ARMOR_NONE = 0,
	CS_ARMOR_KEVLAR,
	CS_ARMOR_VESTHELM
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

new const g_teaminfo[][] =
{
	"UNASSIGNED",
	"TERRORIST",
	"CT",
	"SPECTATOR"
}

new g_maxplayers, g_spawncount, g_buyzone, g_sync_hpdisplay, g_sync_msgdisplay, g_fwd_spawn,
    g_fwd_result, g_fwd_infect, g_fwd_gamestart, g_msg_flashlight, g_msg_teaminfo,
    g_msg_scoreattrib, g_msg_money, g_msg_scoreinfo, g_msg_deathmsg, g_msg_screenfade,
    Float:g_buytime, Float:g_spawns[MAX_SPAWNS+1][9], Float:g_vecvel[3], bool:g_brestorevel,
    bool:g_infecting, bool:g_gamestarted, bool:g_roundstarted, bool:g_roundended,
    g_class_name[MAX_CLASSES+1][32], g_classcount, g_class_desc[MAX_CLASSES+1][32],
    g_class_pmodel[MAX_CLASSES+1][64], g_class_wmodel[MAX_CLASSES+1][64],
    Float:g_class_data[MAX_CLASSES+1][MAX_DATA], g_autoteambalance, g_cvar_autoteambalance,
    g_primary_wid[MAX_WEAPONS], g_secondary_wid[MAX_WEAPONS], g_grenade_wid[MAX_WEAPONS],
    g_gamedesc[32], g_lights[2], g_skyname[32]

// Cvar values, kept in sync automatically through bind_pcvar_*
new cvar_enabled, cvar_randomspawn, cvar_autonvg, cvar_winsounds, cvar_weaponsmenu,
    cvar_killbonus, cvar_maxzombies, cvar_flashbang, cvar_buytime, cvar_respawnaszombie,
    cvar_punishsuicide, cvar_infectmoney, cvar_showtruehealth, cvar_obeyarmor,
    cvar_impactexplode, cvar_caphealthdisplay, cvar_randomclass, cvar_knockback,
    cvar_knockback_duck, cvar_killreward, cvar_painshockfree, cvar_zombie_class,
    cvar_shootobjects, cvar_ammo,
    Float:cvar_starttime, Float:cvar_knockback_dist, Float:cvar_zombiemulti,
    Float:cvar_zombie_hpmulti, Float:cvar_pushpwr_weapon, Float:cvar_pushpwr_zombie

new bool:g_zombie[33], bool:g_falling[33], bool:g_disconnected[33], bool:g_blockmodel[33],
    bool:g_showmenu[33], bool:g_menufailsafe[33], bool:g_preinfect[33], bool:g_welcomemsg[33],
    bool:g_suicide[33], Float:g_regendelay[33], Float:g_hitdelay[33], g_mutate[33], g_victim[33],
    g_modelent[33], g_menuposition[33], g_player_class[33], g_player_weapons[33][2]

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

	g_fwd_spawn = register_forward(FM_Spawn, "fwd_spawn")

	g_buyzone = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "func_buyzone"))
	if(g_buyzone)
	{
		dllfunc(DLLFunc_Spawn, g_buyzone)
		set_pev(g_buyzone, pev_solid, SOLID_NOT)
	}

	new ent = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "info_bomb_target"))
	if(ent)
	{
		dllfunc(DLLFunc_Spawn, ent)
		set_pev(ent, pev_solid, SOLID_NOT)
	}

	#if FOG_ENABLE
	ent = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "env_fog"))
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

	register_clcmd("jointeam", "cmd_jointeam")
	register_clcmd("say /class", "cmd_classmenu")
	register_clcmd("say /guns", "cmd_enablemenu")
	register_clcmd("say /help", "cmd_helpmotd")
	register_clcmd("amx_infect", "cmd_infectuser", ADMIN_BAN, "<name or #userid>")

	register_menu("Equipment", 1023, "action_equip")
	register_menu("Primary", 1023, "action_prim")
	register_menu("Secondary", 1023, "action_sec")
	register_menu("Class", 1023, "action_class")

	unregister_forward(FM_Spawn, g_fwd_spawn)
	register_forward(FM_CmdStart, "fwd_cmdstart")
	register_forward(FM_EmitSound, "fwd_emitsound")
	register_forward(FM_GetGameDescription, "fwd_gamedescription")
	register_forward(FM_CreateNamedEntity, "fwd_createnamedentity")
	register_forward(FM_ClientKill, "fwd_clientkill")
	register_forward(FM_PlayerPreThink, "fwd_player_prethink")
	register_forward(FM_PlayerPreThink, "fwd_player_prethink_post", 1)
	register_forward(FM_PlayerPostThink, "fwd_player_postthink")
	register_forward(FM_SetClientKeyValue, "fwd_setclientkeyvalue")

	// RegisterHamPlayer also covers CZ bots automatically
	RegisterHamPlayer(Ham_TakeDamage, "bacon_takedamage_player")
	RegisterHamPlayer(Ham_Killed, "bacon_killed_player")
	RegisterHamPlayer(Ham_Spawn, "bacon_spawn_player_post", 1)
	RegisterHamPlayer(Ham_TraceAttack, "bacon_traceattack_player")
	RegisterHam(Ham_TraceAttack, "func_pushable", "bacon_traceattack_pushable")
	RegisterHam(Ham_Use, "func_tank", "bacon_use_tank")
	RegisterHam(Ham_Use, "func_tankmortar", "bacon_use_tank")
	RegisterHam(Ham_Use, "func_tankrocket", "bacon_use_tank")
	RegisterHam(Ham_Use, "func_tanklaser", "bacon_use_tank")
	RegisterHam(Ham_Use, "func_pushable", "bacon_use_pushable")
	RegisterHam(Ham_Touch, "func_pushable", "bacon_touch_pushable")
	RegisterHam(Ham_Touch, "weaponbox", "bacon_touch_weapon")
	RegisterHam(Ham_Touch, "armoury_entity", "bacon_touch_weapon")
	RegisterHam(Ham_Touch, "weapon_shield", "bacon_touch_weapon")
	RegisterHam(Ham_Touch, "grenade", "bacon_touch_grenade")

	g_msg_flashlight = get_user_msgid("Flashlight")
	g_msg_teaminfo = get_user_msgid("TeamInfo")
	g_msg_scoreattrib = get_user_msgid("ScoreAttrib")
	g_msg_scoreinfo = get_user_msgid("ScoreInfo")
	g_msg_deathmsg = get_user_msgid("DeathMsg")
	g_msg_money = get_user_msgid("Money")
	g_msg_screenfade = get_user_msgid("ScreenFade")

	register_message(get_user_msgid("Health"), "msg_health")
	register_message(get_user_msgid("TextMsg"), "msg_textmsg")
	register_message(get_user_msgid("SendAudio"), "msg_sendaudio")
	register_message(get_user_msgid("StatusIcon"), "msg_statusicon")
	register_message(g_msg_scoreattrib, "msg_scoreattrib")
	register_message(g_msg_deathmsg, "msg_deathmsg")
	register_message(g_msg_screenfade, "msg_screenfade")
	register_message(g_msg_teaminfo, "msg_teaminfo")
	register_message(get_user_msgid("ClCorpse"), "msg_clcorpse")
	register_message(get_user_msgid("WeapPickup"), "msg_weaponpickup")
	register_message(get_user_msgid("AmmoPickup"), "msg_ammopickup")

	register_event("TextMsg", "event_textmsg", "a", "2=#Game_will_restart_in")
	register_event("HLTV", "event_newround", "a", "1=0", "2=0")
	register_event("CurWeapon", "event_curweapon", "be", "1=1")
	register_event("ArmorType", "event_armortype", "be")
	register_event("Damage", "event_damage", "be")

	register_logevent("logevent_round_start", 2, "1=Round_Start")
	register_logevent("logevent_round_end", 2, "1=Round_End")

	g_fwd_infect = CreateMultiForward("event_infect", ET_IGNORE, FP_CELL, FP_CELL)
	g_fwd_gamestart = CreateMultiForward("event_gamestart", ET_IGNORE)

	g_sync_hpdisplay = CreateHudSyncObj()
	g_sync_msgdisplay = CreateHudSyncObj()

	g_maxplayers = get_maxplayers()

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

	if(cvar_showtruehealth)
		set_task(0.2, "task_showtruehealth", _, _, _, "b")
}

public plugin_end()
{
	if(cvar_enabled)
		set_pcvar_num(g_cvar_autoteambalance, g_autoteambalance)
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

// Resolve weapon ids once, equipweapon() no longer does string lookups
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
	g_showmenu[id] = true
	g_welcomemsg[id] = true
	g_blockmodel[id] = true
	g_zombie[id] = false
	g_preinfect[id] = false
	g_disconnected[id] = false
	g_falling[id] = false
	g_menufailsafe[id] = false
	g_suicide[id] = false
	g_victim[id] = 0
	g_mutate[id] = -1
	g_player_class[id] = 0
	g_player_weapons[id][0] = -1
	g_player_weapons[id][1] = -1
	g_regendelay[id] = 0.0
	g_hitdelay[id] = 0.0

	remove_user_model(id)
}

public client_putinserver(id)
{
	if(cvar_randomclass && g_classcount > 1)
		g_player_class[id] = _random(g_classcount)
}

public client_disconnect(id)
{
	remove_task(TASKID_STRIPNGIVE + id)
	remove_task(TASKID_UPDATESCR + id)
	remove_task(TASKID_SPAWNDELAY + id)
	remove_task(TASKID_WEAPONSMENU + id)
	remove_task(TASKID_CHECKSPAWN + id)

	g_disconnected[id] = true
	remove_user_model(id)
}

public cmd_jointeam(id)
{
	if(g_zombie[id] && is_user_alive(id))
	{
		client_print(id, print_center, "%L", id, "CMD_TEAMCHANGE")
		return PLUGIN_HANDLED
	}
	return PLUGIN_CONTINUE
}

public cmd_classmenu(id)
{
	if(g_classcount > 1)
		display_classmenu(id, g_menuposition[id] = 0)
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

public msg_teaminfo(msgid, dest, id)
{
	if(!g_gamestarted)
		return PLUGIN_CONTINUE

	static team[2]
	get_msg_arg_string(2, team, 1)

	if(team[0] != 'U')
		return PLUGIN_CONTINUE

	id = get_msg_arg_int(1)
	if(!g_disconnected[id] || is_user_alive(id))
		return PLUGIN_CONTINUE

	g_disconnected[id] = false
	id = randomly_pick_zombie()
	if(id)
	{
		fm_set_user_team(id, g_zombie[id] ? CS_TEAM_CT : CS_TEAM_T, 0)
		set_pev(id, pev_deadflag, DEAD_RESPAWNABLE)
	}
	return PLUGIN_CONTINUE
}

public msg_screenfade(msgid, dest, id)
{
	if(!cvar_flashbang)
		return PLUGIN_CONTINUE

	if((!g_zombie[id] || !is_user_alive(id))
	&& get_msg_arg_int(4) == 255 && get_msg_arg_int(5) == 255
	&& get_msg_arg_int(6) == 255 && get_msg_arg_int(7) > 199)
		return PLUGIN_HANDLED

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

public msg_deathmsg(msgid, dest, id)
{
	static killer
	killer = get_msg_arg_int(1)

	if(is_valid_player(killer) && g_zombie[killer] && is_user_connected(killer))
		set_msg_arg_string(4, g_zombie_weapname)
}

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

	if(equal(txtmsg[1], "Terrorists_Win"))
	{
		formatex(winmsg, charsmax(winmsg), "%L", LANG_SERVER, "WIN_TXT_ZOMBIES")
		set_msg_arg_string(2, winmsg)
	}
	else if(equal(txtmsg[1], "Target_Saved") || equal(txtmsg[1], "CTs_Win"))
	{
		formatex(winmsg, charsmax(winmsg), "%L", LANG_SERVER, "WIN_TXT_SURVIVORS")
		set_msg_arg_string(2, winmsg)
	}
	return PLUGIN_CONTINUE
}

public msg_clcorpse(msgid, dest, id)
{
	id = get_msg_arg_int(12)
	if(!is_valid_player(id) || !g_zombie[id])
		return PLUGIN_CONTINUE

	// Use the cached model entity instead of searching all entities
	static ent
	ent = g_modelent[id]

	if(pev_valid(ent))
	{
		static model[64]
		pev(ent, pev_model, model, charsmax(model))

		set_msg_arg_string(1, model)
	}
	return PLUGIN_CONTINUE
}

public logevent_round_start()
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

		team = fm_get_user_team(id)
		if(team != CS_TEAM_T && team != CS_TEAM_CT)
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

public logevent_round_end()
{
	g_gamestarted = false
	g_roundstarted = false
	g_roundended = true

	remove_task(TASKID_BALANCETEAM)
	remove_task(TASKID_INITROUND)
	remove_task(TASKID_STARTROUND)

	set_task(0.1, "task_balanceteam", TASKID_BALANCETEAM)
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

public event_newround()
{
	g_gamestarted = false

	if(cvar_buytime)
		g_buytime = cvar_buytime + get_gametime()

	static id
	for(id = 1; id <= g_maxplayers; id++)
		g_blockmodel[id] = true

	remove_task(TASKID_NEWROUND)
	remove_task(TASKID_INITROUND)
	remove_task(TASKID_STARTROUND)

	set_task(0.1, "task_newround", TASKID_NEWROUND)
	set_task(cvar_starttime, "task_initround", TASKID_INITROUND)
}

public event_curweapon(id)
{
	if(!is_user_alive(id))
		return PLUGIN_CONTINUE

	static weapon
	weapon = read_data(2)

	if(g_zombie[id])
	{
		if(weapon != CSW_KNIFE && !task_exists(TASKID_STRIPNGIVE + id))
			set_task(0.1, "task_stripngive", TASKID_STRIPNGIVE + id)

		return PLUGIN_CONTINUE
	}

	if(!cvar_ammo || (AMMOWP_NULL & (1<<weapon)))
		return PLUGIN_CONTINUE

	switch(cvar_ammo)
	{
		case 1:
		{
			static maxammo
			maxammo = g_weapon_ammo[weapon][MAX_AMMO]

			if(maxammo > 0 && fm_get_user_bpammo(id, weapon) < 1)
				fm_set_user_bpammo(id, weapon, maxammo)
		}
		case 2:
		{
			static maxclip
			maxclip = g_weapon_ammo[weapon][MAX_CLIP]

			if(maxclip > 0 && read_data(3) < 1)
				fill_clip(id, weapon, maxclip)
		}
	}
	return PLUGIN_CONTINUE
}

public event_armortype(id)
{
	if(g_zombie[id] && is_user_alive(id) && fm_get_user_armortype(id) != CS_ARMOR_NONE)
		fm_set_user_armortype(id, CS_ARMOR_NONE)

	return PLUGIN_CONTINUE
}

public event_damage(victim)
{
	if(!g_gamestarted || !is_user_alive(victim))
		return PLUGIN_CONTINUE

	if(g_zombie[victim])
	{
		static Float:gametime, pclass
		gametime = get_gametime()
		pclass = g_player_class[victim]

		g_regendelay[victim] = gametime + g_class_data[pclass][DATA_HITREGENDLY]
		g_hitdelay[victim] = gametime + g_class_data[pclass][DATA_HITDELAY]
	}
	else
	{
		static attacker
		attacker = get_user_attacker(victim)

		if(g_infecting || !g_zombie[attacker] || !is_user_alive(attacker))
			return PLUGIN_CONTINUE

		if(g_victim[attacker] == victim)
		{
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

			static Float:frags
			pev(attacker, pev_frags, frags)

			set_pev(attacker, pev_frags, frags + 1.0)
			fm_set_user_deaths(victim, fm_get_user_deaths(victim) + 1)

			fm_set_user_money(attacker, cvar_infectmoney)

			static params[2]
			params[0] = attacker
			params[1] = victim

			set_task(0.3, "task_updatescore", TASKID_UPDATESCR, params, 2)
		}
		g_infecting = false
	}
	return PLUGIN_CONTINUE
}

public fwd_player_prethink(id)
{
	// Cheap flag first: humans (the majority) leave immediately
	if(!g_zombie[id] || !is_user_alive(id))
		return FMRES_IGNORED

	static flags
	flags = pev(id, pev_flags)

	if(flags & FL_ONGROUND)
	{
		if(cvar_painshockfree)
		{
			pev(id, pev_velocity, g_vecvel)
			g_brestorevel = true
		}
	}
	else
	{
		static Float:fallvelocity
		pev(id, pev_flFallVelocity, fallvelocity)

		g_falling[id] = (fallvelocity >= 350.0)
	}

	if(g_gamestarted)
	{
		static pclass, Float:health
		pclass = g_player_class[id]
		pev(id, pev_health, health)

		if(health < g_class_data[pclass][DATA_HEALTH])
		{
			static Float:gametime
			gametime = get_gametime()

			if(g_regendelay[id] < gametime)
			{
				set_pev(id, pev_health, health + 1.0)
				g_regendelay[id] = gametime + g_class_data[pclass][DATA_REGENDLY]
			}
		}
	}
	return FMRES_IGNORED
}

public fwd_player_prethink_post(id)
{
	if(!g_brestorevel)
		return FMRES_IGNORED

	g_brestorevel = false

	static flag
	flag = pev(id, pev_flags)

	if(flag & FL_ONTRAIN)
		return FMRES_IGNORED

	if((flag & FL_CONVEYOR) && pev_valid(pev(id, pev_groundentity)))
	{
		static Float:vectemp[3]
		pev(id, pev_basevelocity, vectemp)

		xs_vec_add(g_vecvel, vectemp, g_vecvel)
	}

	if(!(flag & FL_DUCKING) && g_hitdelay[id] > get_gametime())
		xs_vec_mul_scalar(g_vecvel, g_class_data[g_player_class[id]][DATA_HITSPEED], g_vecvel)

	set_pev(id, pev_velocity, g_vecvel)
	return FMRES_HANDLED
}

public fwd_player_postthink(id)
{
	if(g_zombie[id] && g_falling[id] && is_user_alive(id) && (pev(id, pev_flags) & FL_ONGROUND))
	{
		set_pev(id, pev_watertype, CONTENTS_WATER)
		g_falling[id] = false
	}

	if(cvar_buytime && g_buytime > get_gametime() && is_user_alive(id) && pev_valid(g_buyzone))
		dllfunc(DLLFunc_Touch, g_buyzone, id)

	return FMRES_IGNORED
}

public fwd_emitsound(id, channel, sample[], Float:volume, Float:attn, flag, pitch)
{
	if(channel == CHAN_ITEM && sample[6] == 'n' && sample[7] == 'v' && sample[8] == 'g')
		return FMRES_SUPERCEDE

	if(!is_valid_player(id) || !g_zombie[id] || !is_user_connected(id))
		return FMRES_IGNORED

	if(sample[8] == 'k' && sample[9] == 'n' && sample[10] == 'i')
	{
		if(sample[14] == 's' && sample[15] == 'l' && sample[16] == 'a')
		{
			emit_sound(id, channel, g_zombie_miss_sounds[_random(sizeof g_zombie_miss_sounds)], volume, attn, flag, pitch)
			return FMRES_SUPERCEDE
		}
		else if(sample[14] == 'h' && sample[15] == 'i' && sample[16] == 't' || sample[14] == 's' && sample[15] == 't' && sample[16] == 'a')
		{
			if(sample[17] == 'w' && sample[18] == 'a' && sample[19] == 'l')
				emit_sound(id, channel, g_zombie_miss_sounds[_random(sizeof g_zombie_miss_sounds)], volume, attn, flag, pitch)
			else
				emit_sound(id, channel, g_zombie_hit_sounds[_random(sizeof g_zombie_hit_sounds)], volume, attn, flag, pitch)

			return FMRES_SUPERCEDE
		}
	}
	else if(sample[7] == 'd' && (sample[8] == 'i' && sample[9] == 'e' || sample[12] == '6'))
	{
		emit_sound(id, channel, g_zombie_die_sounds[_random(sizeof g_zombie_die_sounds)], volume, attn, flag, pitch)
		return FMRES_SUPERCEDE
	}
	return FMRES_IGNORED
}

public fwd_cmdstart(id, handle, seed)
{
	if(!g_zombie[id] || get_uc(handle, UC_Impulse) != IMPULSE_FLASHLIGHT || !is_user_alive(id))
		return FMRES_IGNORED

	set_uc(handle, UC_Impulse, 0)
	return FMRES_SUPERCEDE
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

public fwd_setclientkeyvalue(id, infobuffer, const key[])
{
	if(!g_blockmodel[id] || !equal(key, "model"))
		return FMRES_IGNORED

	static model[32]
	fm_get_user_model(id, model, charsmax(model))

	if(equal(model, "gordon"))
		return FMRES_IGNORED

	g_blockmodel[id] = false
	return FMRES_SUPERCEDE
}

public bacon_touch_weapon(ent, id)
	return (is_valid_player(id) && g_zombie[id] && is_user_alive(id)) ? HAM_SUPERCEDE : HAM_IGNORED

public bacon_use_tank(ent, caller, activator, use_type, Float:value)
	return (is_valid_player(caller) && g_zombie[caller] && is_user_alive(caller)) ? HAM_SUPERCEDE : HAM_IGNORED

public bacon_use_pushable(ent, caller, activator, use_type, Float:value)
	return HAM_SUPERCEDE

public bacon_traceattack_player(victim, attacker, Float:damage, Float:direction[3], tracehandle, damagetype)
{
	if(!g_gamestarted)
		return HAM_SUPERCEDE

	if(!cvar_knockback || !(damagetype & DMG_BULLET) || !g_zombie[victim] || !is_valid_player(attacker))
		return HAM_IGNORED

	static kbpower
	kbpower = g_weapon_knockback[get_user_weapon(attacker)]

	if(kbpower == -1)
		return HAM_IGNORED

	static flags
	flags = pev(victim, pev_flags)

	if(cvar_knockback_duck && (flags & FL_DUCKING) && (flags & FL_ONGROUND))
		return HAM_IGNORED

	static Float:origins[2][3]
	pev(victim, pev_origin, origins[0])
	pev(attacker, pev_origin, origins[1])

	if(get_distance_f(origins[0], origins[1]) > cvar_knockback_dist)
		return HAM_IGNORED

	static Float:velocity[3], Float:zvel
	pev(victim, pev_velocity, velocity)
	zvel = velocity[2]

	xs_vec_mul_scalar(direction, damage * g_class_data[g_player_class[victim]][DATA_KNOCKBACK] * g_knockbackpower[kbpower], direction)
	xs_vec_add(direction, velocity, velocity)
	velocity[2] = zvel

	set_pev(victim, pev_velocity, velocity)
	return HAM_HANDLED
}

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

public bacon_takedamage_player(victim, inflictor, attacker, Float:damage, damagetype)
{
	if(damagetype & DMG_GENERIC || victim == attacker || !is_valid_player(attacker) || !is_user_alive(victim) || !is_user_connected(attacker))
		return HAM_IGNORED

	if(!g_gamestarted || (!g_zombie[victim] && !g_zombie[attacker]) || ((damagetype & DMG_HEGRENADE) && g_zombie[attacker]))
		return HAM_SUPERCEDE

	if(!g_zombie[attacker])
	{
		static pclass
		pclass = g_player_class[victim]

		damage *= (damagetype & DMG_HEGRENADE) ? g_class_data[pclass][DATA_HEDEFENCE] : g_class_data[pclass][DATA_DEFENCE]
		SetHamParamFloat(4, damage)
	}
	else
	{
		if(get_user_weapon(attacker) != CSW_KNIFE)
			return HAM_SUPERCEDE

		damage *= g_class_data[g_player_class[attacker]][DATA_ATTACK]

		static Float:armor
		pev(victim, pev_armorvalue, armor)

		if(cvar_obeyarmor && armor > 0.0)
		{
			armor -= damage

			if(armor < 0.0)
				armor = 0.0

			set_pev(victim, pev_armorvalue, armor)
			SetHamParamFloat(4, 0.0)
		}
		else
		{
			static bool:infect
			infect = allow_infection()

			g_victim[attacker] = infect ? victim : 0

			SetHamParamFloat(4, (g_infecting || infect) ? 0.0 : damage)
		}
	}
	return HAM_HANDLED
}

public bacon_killed_player(victim, killer, shouldgib)
{
	if(!g_zombie[victim] || !is_valid_player(killer) || g_zombie[killer] || !is_user_alive(killer))
		return HAM_IGNORED

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
	return HAM_IGNORED
}

reward_clip(id)
{
	static weapon, maxclip
	weapon = get_user_weapon(id)
	maxclip = g_weapon_ammo[weapon][MAX_CLIP]

	if(maxclip > 0)
		fill_clip(id, weapon, maxclip)
}

reward_grenade(id)
{
	if(!user_has_weapon(id, CSW_HEGRENADE))
		bacon_give_weapon(id, "weapon_hegrenade")
}

fill_clip(id, weapon, amount)
{
	static weaponname[32], ent
	get_weaponname(weapon, weaponname, charsmax(weaponname))

	ent = fm_find_ent_by_owner(-1, weaponname, id)
	if(ent > 0)
		fm_set_weapon_ammo(ent, amount)
}

public bacon_spawn_player_post(id)
{
	if(!is_user_alive(id))
		return HAM_IGNORED

	static team
	team = fm_get_user_team(id)

	if(team != CS_TEAM_T && team != CS_TEAM_CT)
		return HAM_IGNORED

	if(g_zombie[id])
	{
		if(cvar_respawnaszombie && !g_roundended)
		{
			set_zombie_attibutes(id)
			return HAM_IGNORED
		}
		cure_user(id)
	}
	else if(pev(id, pev_rendermode) == kRenderTransTexture)
		reset_user_model(id)

	set_task(0.3, "task_spawned", TASKID_SPAWNDELAY + id)
	set_task(5.0, "task_checkspawn", TASKID_CHECKSPAWN + id)

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
	else if(fm_get_user_team(id) == CS_TEAM_T)
		fm_set_user_team(id, CS_TEAM_CT)
}

public task_checkspawn(taskid)
{
	static id, team
	id = taskid - TASKID_CHECKSPAWN

	if(g_roundended || !is_user_connected(id) || is_user_alive(id))
		return

	team = fm_get_user_team(id)

	if(team == CS_TEAM_T || team == CS_TEAM_CT)
		ExecuteHamB(Ham_CS_RoundRespawn, id)
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
			ShowSyncHudMsg(id, g_sync_hpdisplay, "Health: %0.f  Class: %s (%s)", health, g_class_name[class], g_class_desc[class])
		else
			ShowSyncHudMsg(id, g_sync_hpdisplay, "Health: %0.f", health)
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
	write_short(fm_get_user_deaths(id))
	write_short(0)
	write_short(get_user_team(id))
	message_end()
}

public task_weaponsmenu(taskid)
{
	static id
	id = taskid - TASKID_WEAPONSMENU

	if(g_menufailsafe[id] && !g_zombie[id] && is_user_alive(id))
		display_equipmenu(id)
}

public task_stripngive(taskid)
{
	static id, pclass
	id = taskid - TASKID_STRIPNGIVE

	if(!is_user_alive(id))
		return

	pclass = g_player_class[id]

	fm_strip_user_weapons(id)
	fm_reset_user_primary(id)
	bacon_give_weapon(id, "weapon_knife")

	set_pev(id, pev_weaponmodel2, "")
	set_pev(id, pev_viewmodel2, g_class_wmodel[pclass])
	set_pev(id, pev_maxspeed, g_class_data[pclass][DATA_SPEED])
}

public task_newround()
{
	static players[32], num, zombies, i, id
	get_players(players, num, "a")

	if(num > 1)
	{
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

	if(!cvar_randomspawn || g_spawncount <= 0)
		return

	static team, spawn_index, j, Float:spawndata[3]
	for(i = 0; i < num; i++)
	{
		id = players[i]

		team = fm_get_user_team(id)
		if((team != CS_TEAM_T && team != CS_TEAM_CT) || pev(id, pev_iuser1))
			continue

		spawn_index = _random(g_spawncount)

		xs_vec_copy_spawn(spawndata, spawn_index, 0)

		if(!fm_is_hull_vacant(spawndata, HULL_HUMAN))
		{
			for(j = spawn_index + 1; j != spawn_index; j++)
			{
				if(j >= g_spawncount)
					j = 0

				xs_vec_copy_spawn(spawndata, j, 0)

				if(fm_is_hull_vacant(spawndata, HULL_HUMAN))
				{
					spawn_index = j
					break
				}
			}
		}

		xs_vec_copy_spawn(spawndata, spawn_index, 0)
		engfunc(EngFunc_SetOrigin, id, spawndata)

		xs_vec_copy_spawn(spawndata, spawn_index, 3)
		set_pev(id, pev_angles, spawndata)

		xs_vec_copy_spawn(spawndata, spawn_index, 6)
		set_pev(id, pev_v_angle, spawndata)

		set_pev(id, pev_fixangle, 1)
	}
}

// Copies 3 consecutive floats of a spawn entry into a vector
stock xs_vec_copy_spawn(Float:vec[3], index, start)
{
	vec[0] = g_spawns[index][start]
	vec[1] = g_spawns[index][start + 1]
	vec[2] = g_spawns[index][start + 2]
}

public task_initround()
{
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
		{
			fm_set_user_team(id, CS_TEAM_CT, 0)
			add_delay(id, "update_team")
		}
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
}

public task_balanceteam()
{
	static players[3][32], count[3]
	get_players(players[CS_TEAM_UNASSIGNED], count[CS_TEAM_UNASSIGNED])

	count[CS_TEAM_T] = 0
	count[CS_TEAM_CT] = 0

	static i, id, team
	for(i = 0; i < count[CS_TEAM_UNASSIGNED]; i++)
	{
		id = players[CS_TEAM_UNASSIGNED][i]
		team = fm_get_user_team(id)

		if(team == CS_TEAM_T || team == CS_TEAM_CT)
			players[team][count[team]++] = id
	}

	if(abs(count[CS_TEAM_T] - count[CS_TEAM_CT]) <= 1)
		return

	static maxplayers
	maxplayers = (count[CS_TEAM_T] + count[CS_TEAM_CT]) / 2

	if(count[CS_TEAM_T] > maxplayers)
	{
		for(i = 0; i < (count[CS_TEAM_T] - maxplayers); i++)
			fm_set_user_team(players[CS_TEAM_T][i], CS_TEAM_CT, 0)
	}
	else
	{
		for(i = 0; i < (count[CS_TEAM_CT] - maxplayers); i++)
			fm_set_user_team(players[CS_TEAM_CT][i], CS_TEAM_T, 0)
	}
}

bot_weapons(id)
{
	g_player_weapons[id][0] = _random(sizeof g_primaryweapons)
	g_player_weapons[id][1] = _random(sizeof g_secondaryweapons)

	equipweapon(id, EQUIP_ALL)
}

public update_team(id)
{
	if(!is_user_connected(id))
		return

	static team
	team = fm_get_user_team(id)

	if(team == CS_TEAM_T || team == CS_TEAM_CT)
	{
		emessage_begin(MSG_ALL, g_msg_teaminfo)
		ewrite_byte(id)
		ewrite_string(g_teaminfo[team])
		emessage_end()
	}
}

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

	fm_set_user_team(victim, CS_TEAM_T)
	set_zombie_attibutes(victim)

	emit_sound(victim, CHAN_STATIC, g_scream_sounds[_random(sizeof g_scream_sounds)], VOL_NORM, ATTN_NONE, 0, PITCH_NORM)
	ExecuteForward(g_fwd_infect, g_fwd_result, victim, attacker)
}

cure_user(id)
{
	if(!is_user_alive(id))
		return

	g_zombie[id] = false
	g_falling[id] = false

	reset_user_model(id)
	fm_set_user_nvg(id, 0)
	set_pev(id, pev_gravity, 1.0)

	static viewmodel[64]
	pev(id, pev_viewmodel2, viewmodel, charsmax(viewmodel))

	if(equal(viewmodel, g_class_wmodel[g_player_class[id]]))
	{
		static weapon
		weapon = fm_lastknife(id)

		if(pev_valid(weapon))
			ExecuteHam(Ham_Item_Deploy, weapon)
	}
}

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
			g_mutate[id] = g_menuposition[id] * 8 + key
			client_print(id, print_chat, "%L", id, "MENU_CHANGECLASS", g_class_name[g_mutate[id]])
		}
	}
	return PLUGIN_HANDLED
}

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

stock fm_strip_user_weapons(index)
{
	static stripent
	if(!pev_valid(stripent))
	{
		stripent = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "player_weaponstrip"))
		dllfunc(DLLFunc_Spawn, stripent)
		set_pev(stripent, pev_solid, SOLID_NOT)
	}
	dllfunc(DLLFunc_Use, stripent, index)

	return 1
}

stock fm_set_entity_visibility(index, visible = 1)
{
	static effects
	effects = pev(index, pev_effects)

	set_pev(index, pev_effects, visible ? (effects & ~EF_NODRAW) : (effects | EF_NODRAW))
}

stock fm_find_ent_by_owner(index, const classname[], owner)
{
	static ent
	ent = index

	while((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", classname)) && pev(ent, pev_owner) != owner) {}

	return ent
}

stock bacon_give_weapon(index, const weapon[])
{
	if(!equal(weapon, "weapon_", 7))
		return 0

	static ent
	ent = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, weapon))

	if(!pev_valid(ent))
		return 0

	set_pev(ent, pev_spawnflags, SF_NORESPAWN)
	dllfunc(DLLFunc_Spawn, ent)

	if(!ExecuteHamB(Ham_AddPlayerItem, index, ent))
	{
		if(pev_valid(ent))
			set_pev(ent, pev_flags, pev(ent, pev_flags) | FL_KILLME)

		return 0
	}
	ExecuteHamB(Ham_Item_AttachToPlayer, ent, index)

	return 1
}

stock bacon_strip_weapon(index, const weapon[])
{
	if(!equal(weapon, "weapon_", 7))
		return 0

	static weaponid, weaponent
	weaponid = get_weaponid(weapon)

	if(!weaponid)
		return 0

	weaponent = fm_find_ent_by_owner(-1, weapon, index)

	if(!weaponent)
		return 0

	if(get_user_weapon(index) == weaponid)
		ExecuteHamB(Ham_Weapon_RetireWeapon, weaponent)

	if(!ExecuteHamB(Ham_RemovePlayerItem, index, weaponent))
		return 0

	ExecuteHamB(Ham_Item_Kill, weaponent)
	set_pev(index, pev_weapons, pev(index, pev_weapons) & ~(1<<weaponid))

	return 1
}

stock fm_set_user_team(index, team, update = 1)
{
	set_pdata_int(index, OFFSET_TEAM, team)
	if(update)
	{
		emessage_begin(MSG_ALL, g_msg_teaminfo)
		ewrite_byte(index)
		ewrite_string(g_teaminfo[team])
		emessage_end()
	}
	return 1
}

// Backpack ammo offset of a weapon, 0 if it has none
stock fm_get_bpammo_offset(weapon)
{
	switch(weapon)
	{
		case CSW_AWP: return OFFSET_AMMO_338MAGNUM
		case CSW_SCOUT, CSW_AK47, CSW_G3SG1: return OFFSET_AMMO_762NATO
		case CSW_M249: return OFFSET_AMMO_556NATOBOX
		case CSW_FAMAS, CSW_M4A1, CSW_AUG, CSW_SG550, CSW_GALI, CSW_SG552: return OFFSET_AMMO_556NATO
		case CSW_M3, CSW_XM1014: return OFFSET_AMMO_BUCKSHOT
		case CSW_USP, CSW_UMP45, CSW_MAC10: return OFFSET_AMMO_45ACP
		case CSW_FIVESEVEN, CSW_P90: return OFFSET_AMMO_57MM
		case CSW_DEAGLE: return OFFSET_AMMO_50AE
		case CSW_P228: return OFFSET_AMMO_357SIG
		case CSW_GLOCK18, CSW_TMP, CSW_ELITE, CSW_MP5NAVY: return OFFSET_AMMO_9MM
	}
	return 0
}

stock fm_get_user_bpammo(index, weapon)
{
	static offset
	offset = fm_get_bpammo_offset(weapon)

	return offset ? get_pdata_int(index, offset) : 0
}

stock fm_set_user_bpammo(index, weapon, amount)
{
	static offset
	offset = fm_get_bpammo_offset(weapon)

	if(offset)
		set_pdata_int(index, offset, amount)

	return 1
}

stock fm_set_user_nvg(index, onoff = 1)
{
	static nvg
	nvg = get_pdata_int(index, OFFSET_NVG)

	set_pdata_int(index, OFFSET_NVG, onoff ? (nvg | HAS_NVG) : (nvg & ~HAS_NVG))
	return 1
}

stock fm_set_user_money(index, addmoney, update = 1)
{
	static money
	money = fm_get_user_money(index) + addmoney

	set_pdata_int(index, OFFSET_CSMONEY, money)

	if(update)
	{
		message_begin(MSG_ONE, g_msg_money, _, index)
		write_long(clamp(money, 0, 16000))
		write_byte(1)
		message_end()
	}
	return 1
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

stock reset_user_model(index)
{
	set_pev(index, pev_rendermode, kRenderNormal)
	set_pev(index, pev_renderamt, 0.0)

	if(pev_valid(g_modelent[index]))
		fm_set_entity_visibility(g_modelent[index], 0)
}

// Removes the follower model entity that belongs to a player slot
stock remove_user_model(index)
{
	static ent
	ent = g_modelent[index]

	if(ent && pev_valid(ent))
		engfunc(EngFunc_RemoveEntity, ent)

	g_modelent[index] = 0
}

stock set_zombie_attibutes(const index)
{
	if(!is_valid_player(index) || !is_user_alive(index))
		return

	g_zombie[index] = true

	if(!task_exists(TASKID_STRIPNGIVE + index))
		set_task(0.1, "task_stripngive", TASKID_STRIPNGIVE + index)

	new iClass = g_player_class[index]
	new Float:flHealth = g_class_data[iClass][DATA_HEALTH]

	if(g_preinfect[index])
		flHealth *= cvar_zombie_hpmulti

	set_pev(index, pev_health, flHealth)
	set_pev(index, pev_gravity, g_class_data[iClass][DATA_GRAVITY])
	set_pev(index, pev_body, 0)
	set_pev(index, pev_armorvalue, 0.0)
	set_pev(index, pev_renderamt, 0.0)
	set_pev(index, pev_rendermode, kRenderTransTexture)

	fm_set_user_armortype(index, CS_ARMOR_NONE)
	fm_set_user_nvg(index)

	if(cvar_autonvg)
		engclient_cmd(index, "nightvision")

	new ent = g_modelent[index]
	if(!pev_valid(ent))
	{
		// Cache the string index, AllocString on every infection wastes the string pool
		static iszInfoTarget
		if(!iszInfoTarget)
			iszInfoTarget = engfunc(EngFunc_AllocString, "info_target")

		ent = engfunc(EngFunc_CreateNamedEntity, iszInfoTarget)
		if(pev_valid(ent))
		{
			engfunc(EngFunc_SetModel, ent, g_class_pmodel[iClass])
			set_pev(ent, pev_classname, MODEL_CLASSNAME)
			set_pev(ent, pev_movetype, MOVETYPE_FOLLOW)
			set_pev(ent, pev_aiment, index)
			set_pev(ent, pev_owner, index)

			g_modelent[index] = ent
		}
	}
	else
	{
		engfunc(EngFunc_SetModel, ent, g_class_pmodel[iClass])
		fm_set_entity_visibility(ent, 1)
	}

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

stock equipweapon(id, weapon)
{
	if(!is_user_alive(id))
		return

	static weaponid, current, weaponent, weapname[32]

	if(weapon & EQUIP_PRI)
	{
		weaponid = g_primary_wid[g_player_weapons[id][0]]
		weaponent = fm_lastprimary(id)
		current = -1

		if(pev_valid(weaponent))
		{
			current = fm_get_weapon_id(weaponent)
			if(current != weaponid)
			{
				get_weaponname(current, weapname, charsmax(weapname))
				bacon_strip_weapon(id, weapname)
			}
		}

		if(current != weaponid)
			bacon_give_weapon(id, g_primaryweapons[g_player_weapons[id][0]][1])

		fm_set_user_bpammo(id, weaponid, g_weapon_ammo[weaponid][MAX_AMMO])
	}

	if(weapon & EQUIP_SEC)
	{
		weaponid = g_secondary_wid[g_player_weapons[id][1]]
		weaponent = fm_lastsecondry(id)
		current = -1

		if(pev_valid(weaponent))
		{
			current = fm_get_weapon_id(weaponent)
			if(current != weaponid)
			{
				get_weaponname(current, weapname, charsmax(weapname))
				bacon_strip_weapon(id, weapname)
			}
		}

		if(current != weaponid)
			bacon_give_weapon(id, g_secondaryweapons[g_player_weapons[id][1]][1])

		fm_set_user_bpammo(id, weaponid, g_weapon_ammo[weaponid][MAX_AMMO])
	}

	if(weapon & EQUIP_GREN)
	{
		static i
		for(i = 0; i < sizeof g_grenades; i++)
		{
			if(!user_has_weapon(id, g_grenade_wid[i]))
				bacon_give_weapon(id, g_grenades[i])
		}
	}
}

// Spreads 8 players per 0.1s step so menus / equips do not all land on one frame
stock add_delay(index, const task[])
	set_task(0.1 * float(((index - 1) >> 3) + 1), task, index)
