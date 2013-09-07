#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smartdm>
#include <store>
#include <EasyJSON>

#undef REQUIRE_PLUGIN
#include <ToggleEffects>
#include <zombiereloaded>

enum Equipment
{
	String:EquipmentName[STORE_MAX_NAME_LENGTH],
	String:EquipmentModelPath[PLATFORM_MAX_PATH],
	Float:EquipmentPosition[3],
	Float:EquipmentAngles[3],
	String:EquipmentAttachment[32],
	String:EquipmentPhysicsModelPath[PLATFORM_MAX_PATH],
	EquipmentTeam[10],
	Float:EquipmentScale
}

enum EquipmentPlayerModelSettings
{
	String:EquipmentName[STORE_MAX_NAME_LENGTH],
	String:PlayerModelPath[PLATFORM_MAX_PATH],
	Float:Position[3],
	Float:Angles[3]
}

new Handle:g_hLookupAttachment = INVALID_HANDLE;

new bool:g_bZombieReloaded;
new bool:g_bToggleEffects;

new g_equipment[1024][Equipment];
new g_equipmentCount = 0;

new Handle:g_equipmentNameIndex = INVALID_HANDLE;
new Handle:g_loadoutSlotList = INVALID_HANDLE;

new g_playerModels[1024][EquipmentPlayerModelSettings];
new g_playerModelCount = 0;

new String:g_sCurrentEquipment[MAXPLAYERS+1][32][STORE_MAX_NAME_LENGTH];
new g_iEquipment[MAXPLAYERS+1][32];

new bool:g_bRestartGame = false;

new String:g_default_physics_model[PLATFORM_MAX_PATH];

new g_player_death_equipment_effect;
new String:g_player_death_dissolve_type[2]; // leave this as a string as it's used in DispatchKeyValue(cell, string, *string*)

new bool:g_bHideOwnItems = true;

/**
 * Called before plugin is loaded.
 * 
 * @param myself    The plugin handle.
 * @param late      True if the plugin was loaded after map change, false on map start.
 * @param error     Error message if load failed.
 * @param err_max   Max length of the error message.
 *
 * @return          APLRes_Success for load success, APLRes_Failure or APLRes_SilentFailure otherwise.
 */
public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	MarkNativeAsOptional("ZR_IsClientHuman"); 
	MarkNativeAsOptional("ZR_IsClientZombie"); 

	return APLRes_Success;
}

public Plugin:myinfo =
{
	name        = "[Store] Equipment",
	author      = "alongub",
	description = "Equipment component for [Store]",
	version     = STORE_VERSION,
	url         = "https://github.com/alongubkin/store"
};

/**
 * Plugin is loading.
 */
public OnPluginStart()
{
	LoadConfig();

	LoadTranslations("common.phrases");
	LoadTranslations("store.phrases");
	LoadTranslations("store.equipment.phrases");
	
	g_loadoutSlotList = CreateArray(ByteCountToCells(32));
	
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_hurt", Event_PlayerHurt); // sometimes player_death events dont fire, but the hurt does with remaining health = 0
	HookEvent("player_death", Event_PlayerDeath);
	
	new Handle:hGameConf = LoadGameConfigFile("store-equipment.gamedata");
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "LookupAttachment");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	g_hLookupAttachment = EndPrepSDKCall();	

	RegAdminCmd("store_editor", Command_OpenEditor, ADMFLAG_RCON, "Opens store-equipment editor.");
	RegAdminCmd("store_hideownitems", Command_HideOwnItems, ADMFLAG_RCON, "Toggles hiding own items for debugging.");

	//Store_RegisterItemType("equipment", OnEquip, LoadItem);
}

public OnAllPluginsLoaded()
{
	g_bZombieReloaded = LibraryExists("zombiereloaded");
	g_bToggleEffects = LibraryExists("specialfx");
}

/**
 * Load plugin config.
 */
LoadConfig() 
{
	new Handle:kv = CreateKeyValues("root");
	
	decl String:path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/store/equipment.cfg");
	
	if (!FileToKeyValues(kv, path)) 
	{
		CloseHandle(kv);
		SetFailState("Can't read config file %s", path);
	}

	g_player_death_equipment_effect = KvGetNum(kv, "player_death_equipment_effect");
	KvGetString(kv, "player_death_dissolve_type", g_player_death_dissolve_type, sizeof(g_player_death_dissolve_type), "0");
	KvGetString(kv, "default_physics_model", g_default_physics_model, sizeof(g_default_physics_model), "models/props_junk/metalbucket01a.mdl");
}

/**
 * Map is starting
 */
public OnMapStart()
{
	for (new item = 0; item < g_equipmentCount; item++)
	{
		if (strcmp(g_equipment[item][EquipmentModelPath], "") != 0 && (FileExists(g_equipment[item][EquipmentModelPath]) || FileExists(g_equipment[item][EquipmentModelPath], true)))
		{
			PrecacheModel(g_equipment[item][EquipmentModelPath]);
			Downloader_AddFileToDownloadsTable(g_equipment[item][EquipmentModelPath]);
		}
	}
}

/** 
 * Called when a new API library is loaded.
 */
public OnLibraryAdded(const String:name[])
{
	if (StrEqual(name, "zombiereloaded"))
	{
		g_bZombieReloaded = true;
	}
	else if (StrEqual(name, "store-inventory"))
	{
		Store_RegisterItemType("equipment", OnEquip, LoadItem);
	}
}

/** 
 * Called when an API library is removed.
 */
public OnLibraryRemoved(const String:name[])
{
	if (StrEqual(name, "zombiereloaded"))
	{
		g_bZombieReloaded = false;
	}
}

public OnClientDisconnect(client)
{
	UnequipAll(client);
}

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if (!g_bZombieReloaded || (g_bZombieReloaded && ZR_IsClientHuman(client)))
		CreateTimer(client * (1.0 / GetClientCount()), SpawnTimer, GetClientSerial(client));
	else
		UnequipAll(client);
	
	return Plugin_Continue;
}

public Action:Event_PlayerHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (GetEventInt(event, "health") <= 0)
	{
		UnequipAll(GetClientOfUserId(GetEventInt(event, "userid")), false);
	}
	return Plugin_Continue;
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	UnequipAll(GetClientOfUserId(GetEventInt(event, "userid")), false);
	return Plugin_Continue;
}

/*public OnEntityCreated(entity, const String:classname[])
{
	new String:othername[32];
	GetEdictClassname(entity, othername, sizeof(othername));
	LogMessage("OnEntityCreated: %s, %s", classname, othername);
}*/

/**
 * Called after a player has become a zombie.
 * 
 * @param client            The client that was infected.
 * @param attacker          The the infecter. (-1 if there is no infecter)
 * @param motherInfect      If the client is a mother zombie.
 * @param respawnOverride   True if the respawn cvar was overridden.
 * @param respawn           The value that respawn was overridden with.
 */
public ZR_OnClientInfected(client, attacker, bool:motherInfect, bool:respawnOverride, bool:respawn)
{
	UnequipAll(client);
}

/**
 * Called right before ZR is about to respawn a player.
 * Here you can modify any variable or stop the action entirely.
 * 
 * @param client            The client index.
 * @param condition         Respawn condition. See ZR_RespawnCondition for
 *                          details.
 *
 * @return      Plugin_Handled to block respawn.
 */
public ZR_OnClientRespawned(client, ZR_RespawnCondition:condition)
{
	UnequipAll(client);
}

public Action:SpawnTimer(Handle:timer, any:serial)
{
	new client = GetClientFromSerial(serial);
	
	if (client == 0)
		return Plugin_Continue;
	
	if (!IsClientInGame(client))
		return Plugin_Continue;

	if (IsFakeClient(client))
		return Plugin_Continue;
		
	if (g_bZombieReloaded && !ZR_IsClientHuman(client))
		return Plugin_Continue;
		
	Store_GetEquippedItemsByType(GetSteamAccountID(client), "equipment", Store_GetClientLoadout(client), OnGetPlayerEquipment, serial);
	return Plugin_Continue;
}

public Store_OnClientLoadoutChanged(client)
{
	Store_GetEquippedItemsByType(GetSteamAccountID(client), "equipment", Store_GetClientLoadout(client), OnGetPlayerEquipment, GetClientSerial(client));
}

public Store_OnReloadItems() 
{
	if (g_equipmentNameIndex != INVALID_HANDLE)
		CloseHandle(g_equipmentNameIndex);
		
	g_equipmentNameIndex = CreateTrie();
	g_equipmentCount = 0;
	g_playerModelCount = 0;
}

public LoadItem(const String:itemName[], const String:attrs[])
{

	PrintToServer("Loading item '%s'", itemName);

	strcopy(g_equipment[g_equipmentCount][EquipmentName], STORE_MAX_NAME_LENGTH, itemName);

	SetTrieValue(g_equipmentNameIndex, g_equipment[g_equipmentCount][EquipmentName], g_equipmentCount);

	new Handle:json = DecodeJSON(attrs);
	if (json == INVALID_HANDLE)
	{
		Store_LogError("Error parsing item '%s' attrs,\n %s", itemName, attrs);
		return;
	}

	if (!JSONGetString(json, "model", g_equipment[g_equipmentCount][EquipmentModelPath], PLATFORM_MAX_PATH))
	{
		Store_LogError("Item '%s' does not contain a model in json attributes", itemName);
		return;
	}

	if (!JSONGetString(json, "attachment", g_equipment[g_equipmentCount][EquipmentAttachment], 32))
		strcopy(g_equipment[g_equipmentCount][EquipmentAttachment], 32, "forward");

	if (!JSONGetString(json, "physicsmodel", g_equipment[g_equipmentCount][EquipmentPhysicsModelPath], PLATFORM_MAX_PATH))
		g_equipment[g_equipmentCount][EquipmentPhysicsModelPath][0] = '\0';

	new Handle:team = INVALID_HANDLE;
	if (JSONGetArray(json, "team", team) && team != INVALID_HANDLE)
		for (new i = 0; i < GetArraySize(team); i++)
			if (!JSONGetArrayInteger(team, i, g_equipment[g_equipmentCount][EquipmentTeam][i]))
				g_equipment[g_equipmentCount][EquipmentTeam][i] = 0;

	if (!JSONGetFloat(json, "scale", g_equipment[g_equipmentCount][EquipmentScale]))
		g_equipment[g_equipmentCount][EquipmentScale] = 0.0;

	new Handle:position = INVALID_HANDLE;
	if (JSONGetArray(json, "position", position) && position != INVALID_HANDLE)
		for (new i = 0; i <= 2; i++)
			if (!JSONGetArrayFloat(position, i, g_equipment[g_equipmentCount][EquipmentPosition][i]))
				g_equipment[g_equipmentCount][EquipmentPosition][i] = 0.0;

	new Handle:angles = INVALID_HANDLE;
	if (JSONGetArray(json, "angles", angles) && angles != INVALID_HANDLE)
		for (new i = 0; i <= 2; i++)
			if (!JSONGetArrayFloat(angles, i, g_equipment[g_equipmentCount][EquipmentAngles][i]))
				g_equipment[g_equipmentCount][EquipmentAngles][i] = 0.0;

	if (strcmp(g_equipment[g_equipmentCount][EquipmentModelPath], "") != 0 && 
		(FileExists(g_equipment[g_equipmentCount][EquipmentModelPath]) || FileExists(g_equipment[g_equipmentCount][EquipmentModelPath], true)))
	{
		PrecacheModel(g_equipment[g_equipmentCount][EquipmentModelPath]);
		Downloader_AddFileToDownloadsTable(g_equipment[g_equipmentCount][EquipmentModelPath]);
	}

	new Handle:playermodels = INVALID_HANDLE;
	if (JSONGetArray(json, "playermodels", playermodels) && playermodels != INVALID_HANDLE)
	{
		new size = GetArraySize(playermodels);
		for (new i = 0; i < size; i++)
		{
			new Handle:model = INVALID_HANDLE;
			if (JSONGetArrayObject(playermodels, i, model) && model != INVALID_HANDLE)
			{
				if (!JSONGetString(model, "playermodel", g_playerModels[g_playerModelCount][PlayerModelPath], PLATFORM_MAX_PATH))
				{
					Store_LogWarning("Item '%s' does not contain a playermodel path at index %d", itemName, i);
					continue;
				}
				new bool:haspositionorangle = false;

				new Handle:modelposition = INVALID_HANDLE;
				if (JSONGetArray(model, "position", modelposition) && modelposition != INVALID_HANDLE)
				{
					haspositionorangle = true;
					for (new n = 0; n <= 2; n++)
						if (!JSONGetArrayFloat(modelposition, n, g_playerModels[g_playerModelCount][Position][n]))
							g_playerModels[g_playerModelCount][Position][n] = 0.0;
				}
				new Handle:modelangle = INVALID_HANDLE;
				if (JSONGetArray(model, "angles", modelangle) && modelangle != INVALID_HANDLE)
				{
					haspositionorangle = true;
					for (new n = 0; n <= 2; n++)
						if (!JSONGetArrayFloat(modelangle, n, g_playerModels[g_playerModelCount][Angles][n]))
							g_playerModels[g_playerModelCount][Angles][n] = 0.0;
				}

				if (haspositionorangle) 
				{
					strcopy(g_playerModels[g_playerModelCount][EquipmentName], STORE_MAX_NAME_LENGTH, itemName);
					g_playerModelCount++;
				}
			}
		}
	}

	// todo: 'beautified' json causes an error invalid handle when calling DestroyJSON (fine when compacted, parser or impl error?)
	DestroyJSON(json);

	PrintToServer("Finished loading %s", itemName);

	g_equipmentCount++;
}

public OnGetPlayerEquipment(ids[], count, any:serial)
{
	new client = GetClientFromSerial(serial);
	
	if (client == 0)
		return;
		
	if (!IsClientInGame(client))
		return;
	
	if (!IsPlayerAlive(client))
		return;
		
	for (new index = 0; index < count; index++)
	{
		decl String:itemName[STORE_MAX_NAME_LENGTH];
		Store_GetItemName(ids[index], itemName, sizeof(itemName));

		decl String:displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetItemDisplayName(ids[index], displayName, sizeof(displayName));
		
		decl String:loadoutSlot[STORE_MAX_LOADOUTSLOT_LENGTH];
		Store_GetItemLoadoutSlot(ids[index], loadoutSlot, sizeof(loadoutSlot));
		
		new loadoutSlotIndex = FindStringInArray(g_loadoutSlotList, loadoutSlot);
		
		if (loadoutSlotIndex == -1)
			loadoutSlotIndex = PushArrayString(g_loadoutSlotList, loadoutSlot);
		
		Unequip(client, loadoutSlotIndex);
		
		if (!g_bZombieReloaded || (g_bZombieReloaded && ZR_IsClientHuman(client)))
			Equip(client, loadoutSlotIndex, itemName, displayName);
	}
}

public Store_ItemUseAction:OnEquip(client, itemId, bool:equipped)
{
	if (!IsClientInGame(client))
	{
		return Store_DoNothing;
	}
	
	if (!IsPlayerAlive(client))
	{
		//PrintToChat(client, "%s%t", STORE_PREFIX, "Must be alive to equip");
		return equipped ? Store_UnequipItem : Store_EquipItem;
	}
	
	if (g_bZombieReloaded && !ZR_IsClientHuman(client))
	{
		PrintToChat(client, "%s%t", STORE_PREFIX, "Must be human to equip");	
		return Store_DoNothing;
	}
	
	decl String:name[STORE_MAX_NAME_LENGTH];
	Store_GetItemName(itemId, name, sizeof(name));
	
	decl String:loadoutSlot[STORE_MAX_LOADOUTSLOT_LENGTH];
	Store_GetItemLoadoutSlot(itemId, loadoutSlot, sizeof(loadoutSlot));
	
	new loadoutSlotIndex = FindStringInArray(g_loadoutSlotList, loadoutSlot);
	
	if (loadoutSlotIndex == -1)
		loadoutSlotIndex = PushArrayString(g_loadoutSlotList, loadoutSlot);
		
	if (equipped)
	{
		if (!Unequip(client, loadoutSlotIndex))
			return Store_DoNothing;
	
		decl String:displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetItemDisplayName(itemId, displayName, sizeof(displayName));
		
		PrintToChat(client, "%s%t", STORE_PREFIX, "Unequipped item", displayName);
		return Store_UnequipItem;
	}
	else
	{
		decl String:displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetItemDisplayName(itemId, displayName, sizeof(displayName));

		if (!Equip(client, loadoutSlotIndex, name, displayName))
			return Store_DoNothing;
		
		PrintToChat(client, "%s%t", STORE_PREFIX, "Equipped item", displayName);
		return Store_EquipItem;
	}
}

SetEntityVectors(source, ent, equipment)
{
	new Float:or[3];
	new Float:ang[3];
	new Float:fForward[3];
	new Float:fRight[3];
	new Float:fUp[3];
	
	GetEntPropVector(source, Prop_Send, "m_vecOrigin", or);

	decl String:clsname[255];
	if (GetEntityNetClass(source, clsname, sizeof(clsname)))
	{
		if (FindSendPropOffs(clsname, "m_angRotation") >= 0)
		{
			GetEntPropVector(source, Prop_Send, "m_angRotation", ang);
			//LogMessage("ang %i %i %i", ang[0], ang[1], ang[2]);
		}
	}

	decl String:m_ModelName[PLATFORM_MAX_PATH];
	GetEntPropString(source, Prop_Data, "m_ModelName", m_ModelName, sizeof(m_ModelName));
	
	new playerModel = -1;
	for (new j = 0; j < g_playerModelCount; j++)
	{	
		if (StrEqual(g_equipment[equipment][EquipmentName], g_playerModels[j][EquipmentName]) && StrEqual(m_ModelName, g_playerModels[j][PlayerModelPath], false))
		{
			playerModel = j;
			break;
		}
	}

	if (playerModel == -1)
	{
		ang[0] += g_equipment[equipment][EquipmentAngles][0];
		ang[1] += g_equipment[equipment][EquipmentAngles][1];
		ang[2] += g_equipment[equipment][EquipmentAngles][2];
	}
	else
	{
		ang[0] += g_playerModels[playerModel][Angles][0];
		ang[1] += g_playerModels[playerModel][Angles][1];
		ang[2] += g_playerModels[playerModel][Angles][2];
	}

	new Float:fOffset[3];

	if (playerModel == -1)
	{
		fOffset[0] = g_equipment[equipment][EquipmentPosition][0];
		fOffset[1] = g_equipment[equipment][EquipmentPosition][1];
		fOffset[2] = g_equipment[equipment][EquipmentPosition][2];
	}
	else
	{
		fOffset[0] = g_playerModels[playerModel][Position][0];
		fOffset[1] = g_playerModels[playerModel][Position][1];
		fOffset[2] = g_playerModels[playerModel][Position][2];
	}

	GetAngleVectors(ang, fForward, fRight, fUp);

	or[0] += fRight[0]*fOffset[0]+fForward[0]*fOffset[1]+fUp[0]*fOffset[2];
	or[1] += fRight[1]*fOffset[0]+fForward[1]*fOffset[1]+fUp[1]*fOffset[2];
	or[2] += fRight[2]*fOffset[0]+fForward[2]*fOffset[1]+fUp[2]*fOffset[2];

	TeleportEntity(ent, or, ang, NULL_VECTOR); 
}

GetEquipmentIndexFromName(const String:name[])
{
	new equipment = -1;
	if (!GetTrieValue(g_equipmentNameIndex, name, equipment))
	{
		return -1;
	}
	return equipment;
}

bool:Equip(client, loadoutSlot, const String:name[], const String:displayName[]="")
{
	Unequip(client, loadoutSlot);

	new equipment = GetEquipmentIndexFromName(name);
	if (equipment < 0)
	{
		PrintToChat(client, "%s%t", STORE_PREFIX, "No item attributes");
		return false;
	}
	
	if (!LookupAttachment(client, g_equipment[equipment][EquipmentAttachment])) 
	{
		PrintToChat(client, "%s%t", STORE_PREFIX, "Player model unsupported");
		return false;
	}

	if (g_equipment[equipment][EquipmentTeam] > 1) // assume 0 is unassigned, 1 is spec
	{
		if (GetClientTeam(client) != g_equipment[equipment][EquipmentTeam])
		{
			PrintToChat(client, "%s%t", STORE_PREFIX, "Equipment wrong team", strlen(displayName) == 0 ? name : displayName);
			return false;
		}
	}

	new ent = CreateEntityByName("prop_dynamic_override");
	DispatchKeyValue(ent, "model", g_equipment[equipment][EquipmentModelPath]);
	// DispatchKeyValue(ent, "spawnflags", "256"); // don't output on +use flag
	DispatchKeyValue(ent, "solid", "0");
	//SetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity", client); // not needed ?
	if (g_equipment[equipment][EquipmentScale] > 0)
	{
		SetEntPropFloat(ent, Prop_Data, "m_flModelScale", g_equipment[equipment][EquipmentScale]);
	}
	
	DispatchSpawn(ent);

	ActivateEntity(ent);
	AcceptEntityInput(ent, "TurnOn");
	AcceptEntityInput(ent, "Enable");

	SetEntityVectors(client, ent, equipment);
	
	SetVariantString("!activator");
	AcceptEntityInput(ent, "SetParent", client, ent);
	
	SetVariantString(g_equipment[equipment][EquipmentAttachment]);
	AcceptEntityInput(ent, "SetParentAttachmentMaintainOffset");

	strcopy(g_sCurrentEquipment[client][loadoutSlot], STORE_MAX_NAME_LENGTH, name);
	g_iEquipment[client][loadoutSlot] = ent;
	
	SDKHook(ent, SDKHook_SetTransmit, ShouldHide);
	
	return true;
}

bool:Unequip(client, loadoutSlot, bool:destroy=true)
{
	new oldequip = g_iEquipment[client][loadoutSlot];
	g_iEquipment[client][loadoutSlot] = 0;

	if (oldequip != 0 && IsValidEdict(oldequip))
	{
		SDKUnhook(oldequip, SDKHook_SetTransmit, ShouldHide);

		if(destroy)
		{
			AcceptEntityInput(oldequip, "Kill");
			return true;
		}

		switch(g_player_death_equipment_effect)
		{
			case 1: // stay on ragdoll
			{
				new ragdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
				if (ragdoll > 0 && IsValidEdict(ragdoll))
				{
					AcceptEntityInput(oldequip, "ClearParent");
					
					new equipment = GetEquipmentIndexFromName(g_sCurrentEquipment[client][loadoutSlot]);
					if (equipment < 0)
					{
						AcceptEntityInput(oldequip, "Kill");
						return true;
					}

					SetEntityVectors(ragdoll, oldequip, equipment);
	
					SetVariantString("!activator");
					AcceptEntityInput(oldequip, "SetParent", ragdoll, oldequip);
					
					SetVariantString(g_equipment[equipment][EquipmentAttachment]);
					AcceptEntityInput(oldequip, "SetParentAttachmentMaintainOffset");

					//LogMessage("OK %i %i", equipment, oldequip);
				}
			}
			case 2: // physics
			{
				AcceptEntityInput(oldequip, "ClearParent");

				new Float:velocity[3];
				new ragdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
				if (ragdoll > 0 && IsValidEdict(ragdoll))
				{
					GetEntPropVector(ragdoll, Prop_Send, "m_vecRagdollVelocity", velocity);
				}

				velocity[0] *= 1.2;
				velocity[1] *= 1.2;
				velocity[2] *= 1.2;
				
				new equipment = GetEquipmentIndexFromName(g_sCurrentEquipment[client][loadoutSlot]);
				if (equipment < 0)
				{
					AcceptEntityInput(oldequip, "Kill");
					return true;
				}
				new ent = CreateEntityByName("prop_physics_multiplayer");
				if (ent < 0 || !IsValidEdict(ent))
				{
					AcceptEntityInput(oldequip, "Kill");
					return true;
				}
				if (strlen(g_equipment[equipment][EquipmentPhysicsModelPath]) > 0)
				{
					DispatchKeyValue(ent, "model", g_equipment[equipment][EquipmentPhysicsModelPath]);
				}
				else 
				{
					DispatchKeyValue(ent, "model", g_default_physics_model);
				}
				DispatchKeyValue(ent, "spawnflags", "6");
				DispatchKeyValue(ent, "physicsmode", "2");
				DispatchKeyValue(ent, "rendermode", "10"); // invisible
				DispatchKeyValue(ent, "renderamt", "0");
				DispatchSpawn(ent);
				ActivateEntity(ent);

				new Float:origin[3];
				new Float:len;
				for (new i = 0; i < 3; i++)
				{
					new Float:n = g_equipment[equipment][EquipmentPosition][i];
					if (n < 0) n *= -1;
					len += n;
				}
				if (len > 20.0)
				{
					GetClientEyePosition(client, origin);
				}
				else
				{
					GetEntPropVector(oldequip, Prop_Send, "m_vecOrigin", origin);
				}

				TeleportEntity(ent, origin, NULL_VECTOR, velocity);

				SetVariantString("!activator");
				AcceptEntityInput(oldequip, "SetParent", ent, oldequip);

				SetEntPropVector(ent, Prop_Data, "m_vecVelocity", velocity); // is this necessary ?

				// kill the physics entity (and equipment as it is attached) in 10 seconds
				new String:addoutput[64];
				Format(addoutput, sizeof(addoutput), "OnUser1 !self:kill::%f:1", 10.0);
				SetVariantString(addoutput);
				AcceptEntityInput(ent, "AddOutput");
				AcceptEntityInput(ent, "FireUser1");
			}
			case 3: // dissolver
			{
				AcceptEntityInput(oldequip, "ClearParent");
				new dissolver = CreateEntityByName("env_entity_dissolver");
				if (dissolver < 0 || !IsValidEdict(dissolver))
				{
					AcceptEntityInput(oldequip, "Kill");
					return true;
				}
				DispatchKeyValue(dissolver, "dissolvetype", g_player_death_dissolve_type);
				DispatchKeyValue(dissolver, "magnitude", "1");
				DispatchKeyValue(dissolver, "target", "!activator");

				AcceptEntityInput(dissolver, "Dissolve", oldequip);
				AcceptEntityInput(dissolver, "Kill");
			}
			default: // 0/anything else = kill
			{
				AcceptEntityInput(oldequip, "Kill");
			}
		}
	}
	return true;
}

UnequipAll(client, bool:destroy=true)
{
	for (new index = 0, size = GetArraySize(g_loadoutSlotList); index < size; index++)
		Unequip(client, index, destroy);
}

public Action:ShouldHide(ent, client)
{
	// if not hiding any own items, just show them all
	if (!g_bHideOwnItems)
		return Plugin_Continue;

	// hide all items for the client if they have the toggle special fx cookie set
	if (g_bToggleEffects)
		if (!ShowClientEffects(client))
			return Plugin_Handled;
	
	// hide items on ourself to stop obstructions to first person view
	for (new index = 0, size = GetArraySize(g_loadoutSlotList); index < size; index++)
	{
		if (ent == g_iEquipment[client][index])
			return Plugin_Handled;
	}
	
	// hide items on our observer target if in first person mode
	if (IsClientInGame(client) && GetEntProp(client, Prop_Send, "m_iObserverMode") == 4 && GetEntPropEnt(client, Prop_Send, "m_hObserverTarget") >= 0)
	{
		for (new index = 0, size = GetArraySize(g_loadoutSlotList); index < size; index++)
		{
			if (ent == g_iEquipment[GetEntPropEnt(client, Prop_Send, "m_hObserverTarget")][index])
				return Plugin_Handled;
		}
	}
	
	return Plugin_Continue;
}

stock bool:LookupAttachment(client, String:point[])
{
	if (g_hLookupAttachment == INVALID_HANDLE)
		return false;

	if (client <= 0 || !IsClientInGame(client)) 
		return false;
	
	return SDKCall(g_hLookupAttachment, client, point);
}

public Action:Command_HideOwnItems(client, args)
{
	g_bHideOwnItems = !g_bHideOwnItems;
	ReplyToCommand(client, "%sHiding own items: %i", STORE_PREFIX, g_bHideOwnItems);
	return Plugin_Handled;
}

public Action:Command_OpenEditor(client, args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "%sUsage: store_editor <name>", STORE_PREFIX);
		return Plugin_Handled;
	}

	decl String:target[65];
	decl String:target_name[MAX_TARGET_LENGTH];
	decl target_list[MAXPLAYERS];
	decl target_count;
	decl bool:tn_is_ml;
    
	GetCmdArg(1, target, sizeof(target));
     
	if ((target_count = ProcessTargetString(
			target,
			0,
			target_list,
			MAXPLAYERS,
			0,
			target_name,
			sizeof(target_name),
			tn_is_ml)) <= 0)
	{
		ReplyToTargetError(client, target_count);
		return Plugin_Handled;
	}

	for (new i = 0; i < target_count; i++)
	{
		if (IsClientInGame(target_list[i]) && !IsFakeClient(target_list[i]))
		{
			OpenEditor(client, target_list[0]);
			break;
		}
	}

	return Plugin_Handled;
}

OpenEditor(client, target)
{
	new Handle:menu = CreateMenu(Editor_LoadoutSlotSelectHandle);
	SetMenuTitle(menu, "Select loadout slot:");

	for (new index = 0, size = GetArraySize(g_loadoutSlotList); index < size; index++)
	{
		decl String:loadoutSlot[32];
		GetArrayString(g_loadoutSlotList, index, loadoutSlot, sizeof(loadoutSlot));

		decl String:value[32];
		Format(value, sizeof(value), "%d,%d", target, index);

		AddMenuItem(menu, value, loadoutSlot);
	}

	DisplayMenu(menu, client, 0);
}

public Editor_LoadoutSlotSelectHandle(Handle:menu, MenuAction:action, client, slot)
{
	if (action == MenuAction_Select)
	{
		new String:value[48];
		if (GetMenuItem(menu, slot, value, sizeof(value)))
		{
			new String:values[2][16];
			ExplodeString(value, ",", values, sizeof(values), sizeof(values[]));

			Editor_OpenLoadoutSlotMenu(client, StringToInt(values[0]), StringToInt(values[1]));
		}
	}
	else if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
}

Editor_OpenLoadoutSlotMenu(client, target, loadoutSlot, Float:amount = 0.5)
{
	new Handle:menu = CreateMenu(Editor_ActionSelectHandle);
	SetMenuTitle(menu, "Select action:");

	for (new bool:add = true; add >= false; add--)
	{
		for (new axis = 'x'; axis <= 'z'; axis++)
		{
			Editor_AddMenuItem(menu, target, "position", loadoutSlot, axis, add, amount);
			Editor_AddMenuItem(menu, target, "angles", loadoutSlot, axis, add, amount);
		}
	}

	Editor_AddMenuItem(menu, target, "save", loadoutSlot);
	DisplayMenu(menu, client, 0);
}

Editor_AddMenuItem(Handle:menu, target, const String:actionType[], loadoutSlot, axis = 0, bool:add = false, Float:amount = 0.0)
{
	decl String:value[128];
	Format(value, sizeof(value), "%s,%d,%d,%c,%b", actionType, target, loadoutSlot, axis, add);

	decl String:text[32];

	if (StrEqual(actionType, "position"))
	{
		Format(text, sizeof(text), "%c ", CharToUpper(axis));

		if (add)
			Format(text, sizeof(text), "%s+", text);
		else
			Format(text, sizeof(text), "%s-", text);

		Format(text, sizeof(text), "Position %s %.1f", text, amount);
	}
	else if (StrEqual(actionType, "angles"))
	{
		Format(text, sizeof(text), "%c ", CharToUpper(axis));

		if (add)
			Format(text, sizeof(text), "%s+", text);
		else
			Format(text, sizeof(text), "%s-", text);

		Format(text, sizeof(text), "Angles %s %.1f", text, amount);
	}
	else
	{
		Format(text, sizeof(text), "Save");
	}

	AddMenuItem(menu, value, text);
}

public Editor_ActionSelectHandle(Handle:menu, MenuAction:action, client, slot)
{
	if (action == MenuAction_Select)
	{
		new String:value[128];
		if (GetMenuItem(menu, slot, value, sizeof(value)))
		{
			new String:values[5][32];
			ExplodeString(value, ",", values, sizeof(values), sizeof(values[]));
			
			//PrintToChatAll(values[0]); // debug msg :-)

			new target = StringToInt(values[1]);
			new loadoutSlot = StringToInt(values[2]);

			decl String:modelPath[PLATFORM_MAX_PATH];
			GetClientModel(target, modelPath, sizeof(modelPath));

			new axis = values[3][0];
			new bool:add = bool:StringToInt(values[4]);

			new equipment = GetEquipmentIndexFromName(g_sCurrentEquipment[target][loadoutSlot]);
			if (equipment < 0)
			{
				PrintToChat(client, "%s%t", STORE_PREFIX, "No item attributes");
				return;
			}

			new playerModel = -1;
			for (new j = 0; j < g_playerModelCount; j++)
			{	
				if (!StrEqual(g_sCurrentEquipment[target][loadoutSlot], g_playerModels[j][EquipmentName]))
					continue;

				if (!StrEqual(modelPath, g_playerModels[j][PlayerModelPath], false))
					continue;

				playerModel = j;
				break;
			}

			if (playerModel == -1)
			{
				strcopy(g_playerModels[g_playerModelCount][PlayerModelPath], PLATFORM_MAX_PATH, modelPath);
				strcopy(g_playerModels[g_playerModelCount][EquipmentName], STORE_MAX_NAME_LENGTH, g_sCurrentEquipment[target][loadoutSlot]);

				for (new i = 0; i < 3; i++)
				{
					g_playerModels[g_playerModelCount][Position][i] = g_equipment[equipment][EquipmentPosition][i];
					g_playerModels[g_playerModelCount][Angles][i] = g_equipment[equipment][EquipmentAngles][i];
				}

				playerModel = g_playerModelCount;
				g_playerModelCount++;
			}

			if (StrEqual(values[0], "save"))
			{
				Editor_SavePlayerModelAttributes(client, equipment);
			}
			else if(StrEqual(values[0], "angles"))
			{
				if (axis == 'x')
				{
					if (add)
						g_playerModels[playerModel][Angles][0] += 0.5;
					else
						g_playerModels[playerModel][Angles][0] -= 0.5;
				}
				else if (axis == 'y')
				{
					if (add)
						g_playerModels[playerModel][Angles][1] += 0.5;
					else
						g_playerModels[playerModel][Angles][1] -= 0.5;
				} 
				else if (axis == 'z')
				{
					if (add)
						g_playerModels[playerModel][Angles][2] += 0.5;
					else
						g_playerModels[playerModel][Angles][2] -= 0.5;
				}

				Equip(target, loadoutSlot, g_sCurrentEquipment[target][loadoutSlot]);
				Editor_OpenLoadoutSlotMenu(client, target, loadoutSlot);				
			}
			else
			{
				if (axis == 'x')
				{
					if (add)
						g_playerModels[playerModel][Position][0] += 0.5;
					else
						g_playerModels[playerModel][Position][0] -= 0.5;
				}
				else if (axis == 'y')
				{
					if (add)
						g_playerModels[playerModel][Position][1] += 0.5;
					else
						g_playerModels[playerModel][Position][1] -= 0.5;
				} 
				else if (axis == 'z')
				{
					if (add)
						g_playerModels[playerModel][Position][2] += 0.5;
					else
						g_playerModels[playerModel][Position][2] -= 0.5;
				}

				Equip(target, loadoutSlot, g_sCurrentEquipment[target][loadoutSlot]);
				Editor_OpenLoadoutSlotMenu(client, target, loadoutSlot);				
			}
		}
	}
	else if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
}

// todo: untested with native json parsing
Editor_SavePlayerModelAttributes(client, equipment)
{	
	new Handle:json = CreateJSON();
	JSONSetString(json, "model", g_equipment[equipment][EquipmentModelPath]);
	Editor_AppendJSONVector(json, "position", g_equipment[equipment][EquipmentPosition]);
	Editor_AppendJSONVector(json, "angles", g_equipment[equipment][EquipmentAngles]);
	JSONSetString(json, "attachment", g_equipment[equipment][EquipmentAttachment]);

	if (g_playerModelCount > 0) 
	{
		new Handle:playerModels = CreateArray(1);
		new count;
		for (new j = 0; j < g_playerModelCount; j++)
		{	
			if (!StrEqual(g_equipment[equipment][EquipmentName], g_playerModels[j][EquipmentName]))
				continue;

			new Handle:model = CreateJSON();
			JSONSetString(model, "playermodel", g_playerModels[j][PlayerModelPath]);
			Editor_AppendJSONVector(model, "position", g_playerModels[j][Position]);
			Editor_AppendJSONVector(model, "angles", g_playerModels[j][Angles]);

			SetArrayCell(playerModels, count++, model);
		}

		JSONSetArray(json, "playermodels", playerModels);
	}

	new String:sJSON[10 * 1024];
	EncodeJSON(json, sJSON, sizeof(sJSON));	

	CloseHandle(json);

	Store_WriteItemAttributes(g_equipment[equipment][EquipmentName], sJSON, Editor_OnSave, client);
}

public Editor_OnSave(bool:success, any:client)
{
	PrintToChat(client, "%sSave successful.", STORE_PREFIX);
	g_bRestartGame = true;
	Store_ReloadItemCache();
}

public Store_OnReloadItemsPost()
{
	if (g_bRestartGame)
	{
		ServerCommand("mp_restartgame 1");
		g_bRestartGame = false;
	}
}

Editor_AppendJSONVector(Handle:json, const String:key[], Float:vector[])
{
	new Handle:array = CreateArray(1, 3);

	for (new i = 0; i < 3; i++)
		SetArrayCell(array, i, vector[i]);

	JSONSetArray(json, key, array);		
}