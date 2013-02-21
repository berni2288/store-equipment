#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smartdm>
#include <store>
#include <smjansson>

#undef REQUIRE_PLUGIN
#include <ToggleEffects>
#include <zombiereloaded>

enum Equipment
{
	String:EquipmentName[STORE_MAX_NAME_LENGTH],
	String:EquipmentModelPath[PLATFORM_MAX_PATH], 
	Float:EquipmentPosition[3],
	Float:EquipmentAngles[3],
	String:EquipmentFlag[2],
	String:EquipmentAttachment[32]
}

enum EquipmentPlayerModelSettings
{
	String:EquipmentName[STORE_MAX_NAME_LENGTH],
	String:PlayerModelPath[PLATFORM_MAX_PATH],
	Float:Position[3],
	Float:Angles[3]
}

new Handle:g_hLookupAttachment = INVALID_HANDLE;

new bool:g_zombieReloaded;
new bool:g_toggleEffects;

new g_equipment[1024][Equipment];
new g_equipmentCount = 0;

new Handle:g_equipmentNameIndex = INVALID_HANDLE;
new Handle:g_loadoutSlotList = INVALID_HANDLE;

new g_playerModels[1024][EquipmentPlayerModelSettings];
new g_playerModelCount = 0;

new String:g_currentHats[MAXPLAYERS+1][STORE_MAX_NAME_LENGTH];
new g_iEquipment[MAXPLAYERS+1][32];

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
	version     = "1.1-alpha",
	url         = "https://github.com/alongubkin/store"
};

/**
 * Plugin is loading.
 */
public OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("store.phrases");
	
	g_loadoutSlotList = CreateArray(ByteCountToCells(32));
	
	g_zombieReloaded = LibraryExists("zombiereloaded");
	g_toggleEffects = LibraryExists("ToggleEffects");
	
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_death", Event_PlayerDeath);
	
	new Handle:hGameConf = LoadGameConfigFile("store-equipment.gamedata");
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "LookupAttachment");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	g_hLookupAttachment = EndPrepSDKCall();	

	RegAdminCmd("sm_editor", Command_OpenEditor, ADMFLAG_ROOT, "Opens equipment editor.");

	Store_RegisterItemType("equipment", OnEquip, LoadItem);
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
		g_zombieReloaded = true;
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
		g_zombieReloaded = false;
	}
}

public OnClientDisconnect(client)
{
	UnequipAll(client);
}

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if (!g_zombieReloaded || (g_zombieReloaded && ZR_IsClientHuman(client)))
		CreateTimer(1.0, SpawnTimer, GetClientSerial(client));
	else
		UnequipAll(client);
	
	return Plugin_Continue;
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	UnequipAll(GetClientOfUserId(GetEventInt(event, "userid")));
	return Plugin_Continue;
}

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
	
	if (g_zombieReloaded && !ZR_IsClientHuman(client))
		return Plugin_Continue;
		
	Store_GetEquippedItemsByType(Store_GetClientAccountID(client), "equipment", Store_GetClientLoadout(client), OnGetPlayerEquipment, serial);
	return Plugin_Continue;
}

public Store_OnClientLoadoutChanged(client)
{
	Store_GetEquippedItemsByType(Store_GetClientAccountID(client), "equipment", Store_GetClientLoadout(client), OnGetPlayerEquipment, GetClientSerial(client));
}

public Store_OnReloadItems() 
{
	if (g_equipmentNameIndex != INVALID_HANDLE)
		CloseHandle(g_equipmentNameIndex);
		
	g_equipmentNameIndex = CreateTrie();
	g_equipmentCount = 0;
}

public LoadItem(const String:itemName[], const String:attrs[])
{
	strcopy(g_equipment[g_equipmentCount][EquipmentName], STORE_MAX_NAME_LENGTH, itemName);

	SetTrieValue(g_equipmentNameIndex, g_equipment[g_equipmentCount][EquipmentName], g_equipmentCount);

	new Handle:json = json_load(attrs);
	json_object_get_string(json, "model", g_equipment[g_equipmentCount][EquipmentModelPath], PLATFORM_MAX_PATH);
	json_object_get_string(json, "attachment", g_equipment[g_equipmentCount][EquipmentAttachment], 32);

	new Handle:position = json_object_get(json, "position");

	for (new i = 0; i <= 2; i++)
		g_equipment[g_equipmentCount][EquipmentPosition][i] = json_array_get_float(position, i);

	CloseHandle(position);

	new Handle:angles = json_object_get(json, "angles");

	for (new i = 0; i <= 2; i++)
		g_equipment[g_equipmentCount][EquipmentAngles][i] = json_array_get_float(angles, i);

	CloseHandle(angles);

	if (strcmp(g_equipment[g_equipmentCount][EquipmentModelPath], "") != 0 && (FileExists(g_equipment[g_equipmentCount][EquipmentModelPath]) || FileExists(g_equipment[g_equipmentCount][EquipmentModelPath], true)))
	{
		PrecacheModel(g_equipment[g_equipmentCount][EquipmentModelPath]);
		Downloader_AddFileToDownloadsTable(g_equipment[g_equipmentCount][EquipmentModelPath]);
	}

	new Handle:playerModels = json_object_get(json, "playermodels");

	if (playerModels != INVALID_HANDLE && json_typeof(playerModels) == JSON_ARRAY)
	{
		for (new index = 0, size = json_array_size(playerModels); index < size; index++)
		{
			new Handle:playerModel = json_array_get(playerModels, index);

			if (playerModel == INVALID_HANDLE)
				continue;

			if (json_typeof(playerModel) != JSON_OBJECT)
			{
				CloseHandle(playerModel);
				continue;
			}

			json_object_get_string(playerModel, "playermodel", g_playerModels[g_playerModelCount][PlayerModelPath], PLATFORM_MAX_PATH);

			new Handle:playerModelPosition = json_object_get(playerModel, "position");

			for (new i = 0; i <= 2; i++)
				g_playerModels[g_playerModelCount][Position][i] = json_array_get_float(playerModelPosition, i);

			CloseHandle(playerModelPosition);

			new Handle:playerModelAngles = json_object_get(playerModel, "angles");

			for (new i = 0; i <= 2; i++)
				g_playerModels[g_playerModelCount][Angles][i] = json_array_get_float(playerModelAngles, i);

			strcopy(g_playerModels[g_playerModelCount][EquipmentName], STORE_MAX_NAME_LENGTH, itemName);

			CloseHandle(playerModelAngles);
			CloseHandle(playerModel);

			g_playerModelCount++;
		}

		CloseHandle(playerModels);
	}

	CloseHandle(json);

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
		
		decl String:loadoutSlot[STORE_MAX_LOADOUTSLOT_LENGTH];
		Store_GetItemLoadoutSlot(ids[index], loadoutSlot, sizeof(loadoutSlot));
		
		new loadoutSlotIndex = FindStringInArray(g_loadoutSlotList, loadoutSlot);
		
		if (loadoutSlotIndex == -1)
			loadoutSlotIndex = PushArrayString(g_loadoutSlotList, loadoutSlot);
		
		Unequip(client, loadoutSlotIndex);
		
		if (!g_zombieReloaded || (g_zombieReloaded && ZR_IsClientHuman(client)))
			Equip(client, loadoutSlotIndex, itemName);
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
		PrintToChat(client, "%s%t", STORE_PREFIX, "Must be alive to equip");
		return Store_DoNothing;
	}
	
	if (g_zombieReloaded && !ZR_IsClientHuman(client))
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
		if (!Equip(client, loadoutSlotIndex, name))
			return Store_DoNothing;
		
		decl String:displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetItemDisplayName(itemId, displayName, sizeof(displayName));
		
		PrintToChat(client, "%s%t", STORE_PREFIX, "Equipped item", displayName);
		return Store_EquipItem;
	}
}

bool:Equip(client, loadoutSlot, const String:name[])
{
	Unequip(client, loadoutSlot);
		
	new equipment = -1;
	if (!GetTrieValue(g_equipmentNameIndex, name, equipment))
	{
		PrintToChat(client, "%s%t", STORE_PREFIX, "No item attributes");
		return false;
	}
	
	if (!LookupAttachment(client, g_equipment[equipment][EquipmentAttachment])) 
	{
		PrintToChat(client, "%s%t", STORE_PREFIX, "Player model unsupported");
		return false;
	}
	
	new Float:or[3];
	new Float:ang[3];
	new Float:fForward[3];
	new Float:fRight[3];
	new Float:fUp[3];
	
	GetClientAbsOrigin(client,or);
	GetClientAbsAngles(client,ang);

	new String:clientModel[PLATFORM_MAX_PATH];
	GetClientModel(client, clientModel, sizeof(clientModel));
	
	new playerModel = -1;
	for (new j = 0; j < g_playerModelCount; j++)
	{	
		if (StrEqual(g_equipment[equipment][EquipmentName], g_playerModels[j][EquipmentName]) && StrEqual(clientModel, g_playerModels[j][PlayerModelPath], false))
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

	new ent = CreateEntityByName("prop_dynamic_override");
	DispatchKeyValue(ent, "model", g_equipment[equipment][EquipmentModelPath]);
	DispatchKeyValue(ent, "spawnflags", "256");
	DispatchKeyValue(ent, "solid", "0");
	SetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity", client);
	
	DispatchSpawn(ent);	
	AcceptEntityInput(ent, "TurnOn", ent, ent, 0);
	
	strcopy(g_currentHats[client], STORE_MAX_NAME_LENGTH, name);
	g_iEquipment[client][loadoutSlot] = ent;
	
	SDKHook(ent, SDKHook_SetTransmit, ShouldHide);
	
	TeleportEntity(ent, or, ang, NULL_VECTOR); 
	
	SetVariantString("!activator");
	AcceptEntityInput(ent, "SetParent", client, ent, 0);
	
	SetVariantString(g_equipment[equipment][EquipmentAttachment]);
	AcceptEntityInput(ent, "SetParentAttachmentMaintainOffset", ent, ent, 0);
	
	return true;
}

bool:Unequip(client, loadoutSlot)
{      
	if (g_iEquipment[client][loadoutSlot] != 0 && IsValidEdict(g_iEquipment[client][loadoutSlot]))
	{
		SDKUnhook(g_iEquipment[client][loadoutSlot], SDKHook_SetTransmit, ShouldHide);
		AcceptEntityInput(g_iEquipment[client][loadoutSlot], "Kill");
	}
	
	g_iEquipment[client][loadoutSlot] = 0;
	return true;
}

UnequipAll(client)
{
	for (new index = 0, size = GetArraySize(g_loadoutSlotList); index < size; index++)
		Unequip(client, index);
}

public Action:ShouldHide(ent, client)
{
	if (g_toggleEffects)
		if (!ShowClientEffects(client))
			return Plugin_Handled;
			
	for (new index = 0, size = GetArraySize(g_loadoutSlotList); index < size; index++)
	{
		if (ent == g_iEquipment[client][index])
			return Plugin_Handled;
	}
	
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

public Action:Command_OpenEditor(client, args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "%sUsage: sm_editor <name>", STORE_PREFIX);
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
	new Handle:menu = CreateMenu(LoadoutSlotSelectHandle);
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

public LoadoutSlotSelectHandle(Handle:menu, MenuAction:action, client, slot)
{
	if (action == MenuAction_Select)
	{
		new String:value[48];
		if (GetMenuItem(menu, slot, value, sizeof(value)))
		{
			new String:values[2][16];
			ExplodeString(value, ",", values, sizeof(values), sizeof(values[]));

			OpenEditorLoadoutSlot(client, StringToInt(values[0]), StringToInt(values[1]));
		}
	}
	else if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
}

OpenEditorLoadoutSlot(client, target, loadoutSlot, Float:amount = 0.5)
{
	new Handle:menu = CreateMenu(ActionSelectHandle);
	SetMenuTitle(menu, "Select loadout slot:");

	for (new bool:add = true; add >= false; add--)
	{
		for (new axis = 'x'; axis <= 'z'; axis++)
		{
			AddEditorMenuItem(menu, target, "position", loadoutSlot, axis, add, amount);
		}
	}

	AddEditorMenuItem(menu, target, "save", loadoutSlot);
	DisplayMenu(menu, client, 0);
}

AddEditorMenuItem(Handle:menu, target, const String:actionType[], loadoutSlot, axis = 0, bool:add = false, Float:amount = 0.0)
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

		Format(text, sizeof(text), "%s %.1f", text, amount);
	}
	else
	{
		Format(text, sizeof(text), "Save");
	}

	AddMenuItem(menu, value, text);
}

public ActionSelectHandle(Handle:menu, MenuAction:action, client, slot)
{
	if (action == MenuAction_Select)
	{
		new String:value[128];
		if (GetMenuItem(menu, slot, value, sizeof(value)))
		{
			new String:values[5][32];
			ExplodeString(value, ",", values, sizeof(values), sizeof(values[]));

			new target = StringToInt(values[1]);
			new loadoutSlot = StringToInt(values[2]);

			new entity = g_iEquipment[target][loadoutSlot];

			new Float:position[3];
			GetEntPropVector(entity, Prop_Send, "m_vecOrigin", position);

			if (StrEqual(values[0], "save"))
			{
				decl String:modelPath[PLATFORM_MAX_PATH];
				GetClientModel(target, modelPath, sizeof(modelPath));

				SavePlayerModelPosition(client, g_currentHats[target], modelPath, position);
			}
			else
			{
				new axis = values[3][0];
				new bool:add = bool:StringToInt(values[4]);

				if (axis == 'x')
				{
					if (add)
						position[0] += 0.5;
					else
						position[0] -= 0.5;
				}
				else if (axis == 'y')
				{
					if (add)
						position[1] += 0.5;
					else
						position[1] -= 0.5;
				} 
				else if (axis == 'z')
				{
					if (add)
						position[2] += 0.5;
					else
						position[2] -= 0.5;
				}

				TeleportEntity(entity, position, NULL_VECTOR, NULL_VECTOR); 
				OpenEditorLoadoutSlot(client, target, loadoutSlot);				
			}
		}
	}
	else if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
}

SavePlayerModelPosition(client, const String:itemName[], const String:modelPath[], Float:position[])
{
	new Handle:pack = CreateDataPack();
	WritePackCell(pack, client);
	WritePackString(pack, modelPath);
	WritePackFloat(pack, position[0]);
	WritePackFloat(pack, position[1]);
	WritePackFloat(pack, position[2]);

	Store_GetItemAttributes(itemName, Editor_GetItemAttributesCallback, pack);
}

public Editor_GetItemAttributesCallback(const String:itemName[], const String:attrs[], any:pack)
{
	ResetPack(pack);

	new client = ReadPackCell(pack);

	decl String:modelPath[PLATFORM_MAX_PATH];
	ReadPackString(pack, modelPath, sizeof(modelPath));

	new Float:position[3];
	position[0] = ReadPackFloat(pack);
	position[1] = ReadPackFloat(pack);
	position[2] = ReadPackFloat(pack);

	CloseHandle(pack);

	new Handle:json = json_load(attrs);

	new Handle:angles = json_object_get(json, "angles");

	new Handle:playerModels = json_object_get(json, "playermodels");

	new bool:appendPlayerModels = false;
	if (playerModels == INVALID_HANDLE)
	{
		playerModels = json_array();
		appendPlayerModels = true;
	}

	new Handle:playerModel = INVALID_HANDLE;
	new index = 0;
	for (new size = json_array_size(playerModels); index < size; index++)
	{
		playerModel = json_array_get(playerModels, index);

		if (playerModel == INVALID_HANDLE)
			continue;

		if (json_typeof(playerModel) != JSON_OBJECT)
		{
			CloseHandle(playerModel);
			continue;
		}

		json_object_get_string(playerModel, "playermodel", g_playerModels[g_playerModelCount][PlayerModelPath], PLATFORM_MAX_PATH);

		if (StrEqual(g_playerModels[g_playerModelCount][PlayerModelPath], modelPath))
			return;
	}

	new bool:appendPlayerModel = false;
	if (playerModel == INVALID_HANDLE)
	{
		playerModel = json_object();
		appendPlayerModel = true;
	}

	json_object_set_new(playerModel, "playermodel", json_string(modelPath));	

	new Handle:playerModelPosition = json_object_get(playerModel, "position");
	if (playerModelPosition == INVALID_HANDLE)
		playerModelPosition = json_array();

	json_array_clear(playerModelPosition);

	json_object_set_new(playerModel, "angles", angles);	

	for (new i = 0; i <= 2; i++)
		json_array_append_new(playerModelPosition, json_real(position[i]));

	json_object_set_new(playerModel, "position", playerModelPosition);	
	
	if (appendPlayerModel)
		json_array_append_new(playerModels, playerModel);
	else
		json_array_set_new(playerModels, index, playerModel);

	if (appendPlayerModels)
		json_object_set_new(json, "playermodels", playerModels);	

	new String:sJSON[10 * 1024];
	json_dump(json, sJSON, sizeof(sJSON));

	/*CloseHandle(playerModelPosition);
	CloseHandle(playerModels);
	CloseHandle(playerModel);*/
	CloseHandle(json);

	Store_WriteItemAttributes(itemName, sJSON, Editor_OnSave, client);
}

public Editor_OnSave(bool:success, any:client)
{
	PrintToChat(client, "%sSave successful.", STORE_PREFIX);
}