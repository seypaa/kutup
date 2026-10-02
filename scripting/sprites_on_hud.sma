#include <amxmodx>
#include <fakemeta>
#include <sprites_on_hud>

#define DEFAULT_FOV	90

#define CSW_GLOCK	2
#define FAKE_WEAPON_SLOT		0
#define FAKE_WEAPON_POSITION	19

/* Template to generate the .txt file that tells the client to display our custom sprite */
#define HUD_CONFIG "4^n\
							weapon		 640 640hud10	0	0	170	45^n\
							weapon_s	 640 640hud11	0	0	170	45^n\
							ammo		 640 640hud7	72	72	24	24^n\
							zoom		 640 %s	%d	%d	%d	%d"

enum _:WeaponData
{
	PrimaryAmmoID,
	PrimaryAmmoMaxAmount,
	SecondaryAmmoID,
	SecondaryAmmoMaxAmount,
	SlotID,
	NumberInSlot,
	Flags
}

#define MAX_WEAPON_ID CSW_P90

new WeaponListMessageData[MAX_WEAPON_ID + 1][WeaponData]
new RegUserMsgForward
new WeaponListHook
new CapturedWeapons

new Array:HandleSpritesArray

new gmsgWeaponList
new gmsgCurWeapon
new gmsgSetFOV

/* Hold the sprite that should be shown to each player and if the sprite is currently visible or not */
new HudSprite:PlayerSprite[33]
new bool:SpriteShown[33]

public plugin_precache()
{
	/*
	 * The game registers its user messages in pfnServerActivate, once per server startup, but
	 * re-sends the weapon list on every map. This forward runs earlier, so there are two cases:
	 *
	 * First map: the id does not exist yet and get_user_msgid can't be used, so wait for the game
	 * to register it. That moment is after the id exists and before the first message is sent.
	 * Later maps: the id already exists and no registration is coming, so hook immediately.
	 */ 

	gmsgWeaponList = get_user_msgid("WeaponList")
	if(gmsgWeaponList)
	{
		WeaponListHook = register_message(gmsgWeaponList, "OnWeaponList_Message")
	}
	else
	{
		RegUserMsgForward = register_forward(FM_RegUserMsg, "OnRegUserMsg_Post", 1)
	}
}

/* Fires as the game registers each of its user messages, during pfnServerActivate */
public OnRegUserMsg_Post(const MessageName[], MessageSize)
{
	if(gmsgWeaponList || !equal(MessageName, "WeaponList"))
	{
		return
	}

	/* Retrieve the weapon list message id during first server startup */
	gmsgWeaponList = get_orig_retval()
	if(gmsgWeaponList)
	{
		WeaponListHook = register_message(gmsgWeaponList, "OnWeaponList_Message")
	}
}

public OnWeaponList_Message(MsgId, MsgDest, MsgEntity)
{
	new WeaponID = get_msg_arg_int(8)
	if(WeaponID < 1 || WeaponID > MAX_WEAPON_ID)
	{
		return
	}

	/* Store the weapon data into the table */
	WeaponListMessageData[WeaponID][PrimaryAmmoID         ] = get_msg_arg_int(2)
	WeaponListMessageData[WeaponID][PrimaryAmmoMaxAmount  ] = get_msg_arg_int(3)
	WeaponListMessageData[WeaponID][SecondaryAmmoID       ] = get_msg_arg_int(4)
	WeaponListMessageData[WeaponID][SecondaryAmmoMaxAmount] = get_msg_arg_int(5)
	WeaponListMessageData[WeaponID][SlotID                ] = get_msg_arg_int(6)
	WeaponListMessageData[WeaponID][NumberInSlot          ] = get_msg_arg_int(7)
	WeaponListMessageData[WeaponID][Flags                 ] = get_msg_arg_int(9)
	CapturedWeapons++
}

public plugin_init()
{
	register_plugin("Sprites on Hud", "0.1", "HamletEagle")

	if(RegUserMsgForward)
	{
		/* Unregister the forward since we already captured the weapon list data */	
		unregister_forward(FM_RegUserMsg, RegUserMsgForward, 1)
		RegUserMsgForward = 0
	}

	if(WeaponListHook)
	{
		/* Unregister the message since we already captured the weapon list data */
		unregister_message(gmsgWeaponList, WeaponListHook)
		WeaponListHook = 0
	}

	if(!CapturedWeapons)
	{
		set_fail_state("No weapons captured from the game, cannot show sprites on HUD")
	}

	gmsgCurWeapon  = get_user_msgid("CurWeapon")
	gmsgSetFOV     = get_user_msgid("SetFOV")
	
	register_event("CurWeapon", "OnCurWeapon_Message", "b")
	register_message(gmsgSetFOV, "OnSetFOV_Message")
}

public plugin_natives()
{
	HandleSpritesArray = ArrayCreate(256)
	for(new i = 0; i < sizeof(PlayerSprite); i++)
	{
		PlayerSprite[i] = InvalidHudSprite
	}
	
	register_native("HS_PrecacheSprite", "NativeHS_PrecacheSprite") // HudSprite:HS_PrecacheSprite(const SpriteName[], OffsetX = 0, OffsetY = 0)
	register_native("HS_DrawSprite", "NativeHS_DrawSprite")         // bool:HS_DrawSprite(id, HudSprite:Sprite)
	register_native("HS_ClearSprite", "NativeHS_ClearSprite")       // bool:HS_ClearSprite(id)
}

public plugin_end()
{ 
	ArrayDestroy(HandleSpritesArray)
}

public HudSprite:NativeHS_PrecacheSprite(const PluginIndex, const ParamsCount)
{
	new SpriteName[128], SpritePath[256]

	get_string(1, SpriteName, charsmax(SpriteName))
	new OffsetX = get_param(2)
	new OffsetY = get_param(3)

	formatex(SpritePath, charsmax(SpritePath), "sprites/%s.spr", SpriteName)

	new Width, Height
	if(!GetSpriteData(SpritePath, Width, Height))
	{
		return InvalidHudSprite
	}

	engfunc(EngFunc_PrecacheModel, SpritePath)

    /* Compute the location where the sprite needs to be drawn so it ends up at the position requested by the caller */
	new RectWidth  = Width  - 2 * OffsetX
	new RectHeight = Height - 2 * OffsetY
	new Left = RectOrigin(OffsetX, RectWidth)
	new Top  = RectOrigin(OffsetY, RectHeight)

	return RegisterHudSprite(SpriteName, Left, Top, RectWidth, RectHeight)
}

HudSprite:RegisterHudSprite(const SpriteName[], Left, Top, RectWidth, RectHeight)
{
	new DefinitionName[256], FileName[256], FileContent[512]
	formatex(FileContent, charsmax(FileContent), HUD_CONFIG, SpriteName, Left, Top, RectWidth, RectHeight)

	/* Generate a unique definition name for the text file corresponding to the sprite. The text file decides the position at which the sprite is drawn.*/
	formatex(DefinitionName, charsmax(DefinitionName), "soh_%s_%d_%d_%d_%d", SpriteName, Left, Top, RectWidth, RectHeight)
	formatex(FileName, charsmax(FileName), "sprites/%s.txt", DefinitionName)
	
	new FilePointer = fopen(FileName, "wt")
	if(!FilePointer)
	{
		return InvalidHudSprite
	}

	fputs(FilePointer, FileContent)
	fclose(FilePointer)

	/* Download the file on the client */
	precache_generic(FileName)

	new HudSprite:Handle = HudSprite:ArraySize(HandleSpritesArray)
	ArrayPushArray(HandleSpritesArray, DefinitionName)
	return Handle
}

public bool:NativeHS_DrawSprite(const PluginIndex, const ParamsCount)
{
	new id = get_param(1)
	if(!is_user_connected(id))
	{
		return false
	}

	new SpriteIndex = get_param(2)
	if(SpriteIndex < 0 || SpriteIndex >= ArraySize(HandleSpritesArray))
	{
		return false
	}

	PlayerSprite[id] = HudSprite:SpriteIndex

	/* A dead or zoomed player cannot see the sprite yet */
	if(CanShowSprite(id))
	{
		DrawSprite(id)
	}

	return true
}

public bool:NativeHS_ClearSprite(const PluginIndex, const ParamsCount)
{
	new id = get_param(1)
	if(!is_user_connected(id))
	{
		return false
	}

	if(PlayerSprite[id] != InvalidHudSprite)
	{
		PlayerSprite[id] = InvalidHudSprite
		HideSprite(id)
	}

	return true
}


public OnCurWeapon_Message(id)
{
	/* The game has just re-sent the real weapon, which replaces our fake one */
	if(PlayerSprite[id] == InvalidHudSprite)
	{
		return
	}

	if(CanShowSprite(id))
	{
		DrawSprite(id)
	}
	else
	{
		SpriteShown[id] = false
	}
}

public client_putinserver(id)
{
	ClearPlayerState(id)
}

public client_disconnect(id)
{
	ClearPlayerState(id)
}

public OnSetFOV_Message(MsgId, MsgDest, MsgEntity)
{
	new id = MsgEntity
	if(!is_user_alive(id) || PlayerSprite[id] == InvalidHudSprite)
	{
		return PLUGIN_CONTINUE
	}

	new Fov = get_msg_arg_int(1)
	if(Fov == 0 || Fov == DEFAULT_FOV)
	{
		/* Not zoomed, draw the sprite */ 
		if(!SpriteShown[id])
		{
			DrawSprite(id)
		}
	}
	else if(SpriteShown[id])
	{
		/* Zoomed, hide the sprite and allow the scope to take priority */
		HideSprite(id)
	}

	return PLUGIN_CONTINUE
}

RectOrigin(Offset, Nominal)
{
	if(Offset <= 0)
	{
		/* Start at 0, the far edge extends to the size of the sprite */
		return 0
	}
	if(Nominal > 0)
	{
		/* Start below 0 so the far edge lands on 0 */
		return -Nominal
	}

	return -1
}

ClearPlayerState(id)
{
	PlayerSprite[id] = InvalidHudSprite
	SpriteShown[id] = false
}

/* A sprite can only be shown to an alive player who is not zoomed in. */
bool:CanShowSprite(id)
{
	if(!is_user_alive(id))
	{
		return false
	}

	new Float:Fov
	pev(id, pev_fov, Fov)

	new Degrees = floatround(Fov)
	return (Degrees == 0 || Degrees == DEFAULT_FOV)
}

/* Remove the sprite from the client hud */
HideSprite(id)
{
	SpriteShown[id] = false

	new Clip
	new Weapon = get_user_weapon(id, Clip)
	if(Weapon <= 0)
	{
		/* Nothing to restore */
		SendCurWeaponMessage(id, 0, 0, 0)
		return
	}

	/* Restore the real weapon */
	new WeaponName[32]
	get_weaponname(Weapon, WeaponName, charsmax(WeaponName))
	SendWeaponListMessage(id, WeaponName, Weapon, true)
	SendCurWeaponMessage(id, 1, Weapon, Clip)
}

/* Draw a sprite on the client hud */
DrawSprite(id)
{
	/* Any FOV below the default makes the client pick the zoomed crosshair entry,
	 * which is the one we are using in the generated .txt files. */
	SendSetFOVMessage(id, DEFAULT_FOV - 1)
	
	new Clip
	new Weapon = get_user_weapon(id, Clip)

	/* Obtain the name of the txt file for the sprite that needs to be drawn */
	new DefinitionName[256]
	ArrayGetString(HandleSpritesArray, _:PlayerSprite[id], DefinitionName, charsmax(DefinitionName))

	SendWeaponListMessage(id, DefinitionName, Weapon)
	SendCurWeaponMessage(id, 1, CSW_GLOCK, Clip)

	/* Reset the FOV to default */
	SendSetFOVMessage(id, DEFAULT_FOV)

	SpriteShown[id] = true
}

GetSpriteData(const SpritePath[], &Width, &Height)
{
	new FilePointer = fopen(SpritePath, "rb")
	if(!FilePointer)
	{
		return 0
	}

	const WidthPosition = 20
	fseek(FilePointer, WidthPosition, SEEK_SET)
	fread(FilePointer, Width, BLOCK_INT)
	fread(FilePointer, Height, BLOCK_INT)
	fclose(FilePointer)

	return 1
}

SendWeaponListMessage(id, const WeaponName[], WeaponID, bool:Reset = false)
{
	message_begin(MSG_ONE, gmsgWeaponList, .player = id)
	{
		write_string(WeaponName)
		write_byte(WeaponListMessageData[WeaponID][PrimaryAmmoID         ])
		write_byte(WeaponListMessageData[WeaponID][PrimaryAmmoMaxAmount  ])
		write_byte(WeaponListMessageData[WeaponID][SecondaryAmmoID       ])
		write_byte(WeaponListMessageData[WeaponID][SecondaryAmmoMaxAmount])
		if(!Reset)
		{
			/* While the sprite is displayed, send fake data */
			write_byte(FAKE_WEAPON_SLOT)
			write_byte(FAKE_WEAPON_POSITION)
			write_byte(CSW_GLOCK)
		}
		else 
		{
			/* Send the proper data for this weapon if no sprite is displayed */
			write_byte(WeaponListMessageData[WeaponID][SlotID])
			write_byte(WeaponListMessageData[WeaponID][NumberInSlot])
			write_byte(WeaponID)
		}
		
		write_byte(WeaponListMessageData[WeaponID][Flags])
	}
	message_end()
}


SendCurWeaponMessage(id, State, WeaponID, ClipAmmo)
{		
	message_begin(MSG_ONE, gmsgCurWeapon, .player = id)
	{
		write_byte(State)
		write_byte(WeaponID)
		write_byte(ClipAmmo)
	}
	message_end()
}

SendSetFOVMessage(id, Degrees)
{
	message_begin(MSG_ONE, gmsgSetFOV, .player = id)
	{
		write_byte(Degrees)
	}
	message_end()
}
