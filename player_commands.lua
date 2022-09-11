local S = minetest.get_translator(minetest.get_current_modname())

-- API
local get_pocket = pocket_dimensions.get_pocket
local get_all_pockets = pocket_dimensions.get_all_pockets
local get_deleted_pockets = pocket_dimensions.get_deleted_pockets
local rename_pocket = pocket_dimensions.rename_pocket
local create_pocket = pocket_dimensions.create_pocket
local delete_pocket = pocket_dimensions.delete_pocket
local undelete_pocket = pocket_dimensions.undelete_pocket
local pocket_containing_pos = pocket_dimensions.pocket_containing_pos
local set_destination = pocket_dimensions.set_destination
local get_personal_pocket = pocket_dimensions.get_personal_pocket
local set_personal_pocket = pocket_dimensions.set_personal_pocket
local set_owner = pocket_dimensions.set_owner
local teleport_player_to_pocket = pocket_dimensions.teleport_player_to_pocket
local get_all_border_types = pocket_dimensions.get_all_border_types
local set_border = pocket_dimensions.set_border

local pocket_size = pocket_dimensions.pocket_size

local personal_pockets_chat_command = minetest.settings:get_bool("pocket_dimensions_personal_pockets_chat_command", false)
local personal_pockets_key = minetest.settings:get_bool("pocket_dimensions_personal_pockets_key", false)
local personal_pockets_key_uses = tonumber(minetest.settings:get("pocket_dimensions_portal_key_uses")) or 0
local personal_pockets_spawn = minetest.settings:get_bool("pocket_dimensions_personal_pockets_spawn", false)
local personal_pockets_respawn = minetest.settings:get_bool("pocket_dimensions_personal_pockets_respawn", false) and not minetest.settings:get_bool("engine_spawn")

local portal_keys_enabled = minetest.settings:get_bool("pocket_dimensions_portal_keys_enabled", false)

local personal_pockets_enabled = personal_pockets_chat_command or personal_pockets_key or personal_pockets_spawn or personal_pockets_respawn





local get_config_formspec
local get_admin_formspec

-------------------------------------------------------------------------------
-- Admin commands

local admin_formspec_state = {}
get_admin_formspec = function(player_name)
	admin_formspec_state[player_name] = admin_formspec_state[player_name] or {row_index=1}
	local state = admin_formspec_state[player_name]

	local formspec = {
		"formspec_version[2]"
		.."size[8,10]"
		.."button_exit[7.0,0.25;0.5,0.5;close;X]"
	}
	
	formspec[#formspec+1] = "tablecolumns[text,tooltip="..S("Name")
		..";text,tooltip="..S("Owner")
		..";text,tooltip="..S("Seconds since last access")
	if personal_pockets_enabled then
		formspec[#formspec+1] = ";text,tooltip="..S("Personal")
	end
	formspec[#formspec+1] = "]table[0.5,1.0;7,5.75;pocket_table;"
	
	local table_to_use
	local delete_label
	local undelete_toggle
	if state.undelete == "true" then
		table_to_use = get_deleted_pockets()
		delete_label = S("Undelete")
		undelete_toggle = "true"
	else
		table_to_use = get_all_pockets()
		delete_label = S("Delete")
		undelete_toggle = "false"
	end
	
	local current_gametime = minetest.get_gametime()
	local i = 0
	for _, pocket_data in pairs(table_to_use) do
		i = i + 1
		if i == state.row_index then
			state.selected_data = pocket_data
		end
		local owner = pocket_data.owner or "<none>"
		formspec[#formspec+1] = minetest.formspec_escape(pocket_data.name)
			..",".. minetest.formspec_escape(owner)
			..","..tostring(current_gametime - (pocket_data.last_accessed or 0))
		if personal_pockets_enabled then
			formspec[#formspec+1] = ","..tostring(pocket_data.personal)
		end
		formspec[#formspec+1] = ","
	end
	formspec[#formspec] = ";"..state.row_index.."]" -- don't use +1, this overwrites the last ","
	
	local selected_data = state.selected_data or {}
	
	formspec[#formspec+1] = "container[0.5,7]"
		.."field[0.0,0.0;6.5,0.5;pocket_name;;" .. minetest.formspec_escape(selected_data.name or "") .."]"
		.."button[0,0.5;3,0.5;rename;"..S("Rename").."]"
		.."button[3.5,0.5;2,0.5;create;"..S("Create").."]"
		.."dropdown[5.5,0.5;1,0.5;create_type;"
		..table.concat(pocket_dimensions.get_all_pocket_types(), ",")..";1]"
		.."button[0,1;3,0.5;teleport;"..S("Teleport To").."]"
		.."button[3.5,1;3,0.5;config;"..S("Configure Selected").."]"
		.."button[0,1.5;3,0.5;delete;"..delete_label.."]"		
		.."field[0.0,2;3,0.5;owner;;".. minetest.formspec_escape(selected_data.owner or "").."]"
		.."button[3.5,2;3,0.5;set_owner;"..S("Set Owner").."]"
		.."checkbox[0,2.75;undelete_toggle;"..S("Show deleted")..";"..undelete_toggle.."]"
		.."container_end[]"
	return table.concat(formspec)
end

minetest.register_chatcommand("pocket_admin", {
	params = "",
	privs = {server=true},
	description = S("Administrate pocket dimensions"),
	func = function(player_name, param)
		minetest.show_formspec(player_name, "pocket_dimensions:admin", get_admin_formspec(player_name))
	end
})

minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "pocket_dimensions:admin" then
		return
	end

	if fields.close then
		return
	end
	
	local player_name = player:get_player_name()
	if not minetest.check_player_privs(player_name, {server = true}) then
		minetest.chat_send_player(player_name, S("This command is for server admins only."))
		return
	end
	
	local refresh = false
	local state = admin_formspec_state[player_name]
	if state == nil then return end
	
	local pocket_data = state.selected_data

	if fields.pocket_table then
		local table_event = minetest.explode_table_event(fields.pocket_table)
		if table_event.type == "CHG" then
			state.row_index = table_event.row
			refresh = true
		end
	end

	if fields.rename and fields.pocket_name ~= pocket_data.name then
		if not rename_pocket(pocket_data.name, fields.pocket_name)then
			minetest.chat_send_player(player_name, S("A pocket dimension with that name already exists"))
		else
			refresh=true
		end
	end
	
	if fields.undelete_toggle then
		state.undelete = fields.undelete_toggle
		refresh = true
	end
	
	if fields.create then
		local override_def = {type=fields.create_type}
		if fields.create_type == "copy location" then
			override_def.origin_location=vector.subtract(vector.round(player:get_pos()), math.floor(pocket_size/2))
			override_def.copy_origin_metadata = true
		end
		local success, message = create_pocket(fields.pocket_name, override_def)
		if success then
			refresh = true
		end
		minetest.chat_send_player(player_name, message)
	end
	
	if fields.delete then
		if state.undelete == "true" then
			local success, message = undelete_pocket(pocket_data)
			minetest.chat_send_player(player_name, message)
		else
			local success, message = delete_pocket(pocket_data)
			minetest.chat_send_player(player_name, message)
		end
		state.row_index = 1
		refresh = true
	end
	
	if fields.config then
		minetest.show_formspec(player_name, "pocket_dimensions:config", get_config_formspec(player_name, pocket_data))
		return
	end
	
	if fields.teleport and pocket_data then
		teleport_player_to_pocket(player_name, state.selected_data.name)
	end
	
	if fields.set_owner and pocket_data.owner ~= fields.owner then
		if fields.owner == "" then
			set_owner(pocket_data, nil)
		else
			set_owner(pocket_data, fields.owner)
		end
		refresh = true
	end
	
	if refresh then
		minetest.show_formspec(player_name, "pocket_dimensions:admin", get_admin_formspec(player_name))
	end
end)

--------------------------------------------------------------------------------------------------------
-- Per-pocket configuration

local border_types = get_all_border_types()
local border_names = {}
for name, _ in pairs(border_types) do
	table.insert(border_names, name)
end
table.sort(border_names)

local config_formspec_state = {}
get_config_formspec = function(player_name, pocket_data)
	config_formspec_state[player_name] = config_formspec_state[player_name] or {row_index=1}
	local state = config_formspec_state[player_name]
	state.pocket_data = pocket_data
	
	local formspec = {
		"formspec_version[2]"
		.."size[8,9.5]"
		.."label[0.5,0.5;"..S("Players that can bypass protection:").."]"
		.."button_exit[7.0,0.25;0.5,0.5;close;X]"
	}
	
	formspec[#formspec+1] = "tablecolumns[text,tooltip="..S("Player Name")
	formspec[#formspec+1] = "]table[0.5,1.0;7,5.75;permitted_table;"
	
	local protection_permitted = pocket_data.protection_permitted or {}
	pocket_data.protection_permitted = protection_permitted
	local i = 0
	for permitted_player, _ in pairs(protection_permitted) do
		i = i + 1
		if i == state.row_index then
			state.selected_player = permitted_player
		end
		formspec[#formspec+1] = minetest.formspec_escape(permitted_player)
		formspec[#formspec+1] = ","
	end
	formspec[#formspec] = ";"..state.row_index.."]" -- don't use +1, this overwrites the last ","
	
	formspec[#formspec+1] = "container[0.5,7]"
		.."field[0.0,0.0;6.5,0.5;pocket_name;;" .. minetest.formspec_escape(pocket_data.name or "") .."]"
		.."button[0,0.5;3,0.5;rename;"..S("Rename").."]"
		.."button[3.5,0.5;2,0.5;border;"..S("Change Border").."]"
		.."dropdown[5.5,0.5;1,0.5;border_type;"
		..table.concat(border_names, ",")..";1]"
		.."button[3.5,1.5;3,0.5;remove_permission;"..S("Remove Permission").."]"		
		.."field[0.0,1;3,0.5;name_permitted;;]"
		.."label[3.25,1.25;<-]"
		.."button[3.5,1;3,0.5;give_permission;"..S("Give Permission").."]"
		.."button[0,1.5;3,0.5;set_entry;"..S("Set Entry Location").."]"
	if minetest.check_player_privs(player_name, {server = true}) then
		formspec[#formspec+1] = "button[1.75,2;3,0.5;admin;" .. S("Admin Screen") .. "]"
	end
	formspec[#formspec+1] = "container_end[]"
	return table.concat(formspec)
end

minetest.register_chatcommand("pocket_config", {
	params = "[pocket name]",
	description = S("Configure a pocket dimension"),
	func = function(player_name, param)
		local pocket_data = get_pocket(param)
		if not pocket_data then
			local player = minetest.get_player_by_name(player_name)
			local player_pos = player:get_pos()
			pocket_data = pocket_containing_pos(player_pos)
			if not pocket_data then
				if param ~= "" then
					minetest.chat_send_player(player_name, S("A pocket dimension named @1 doesn't exist.", param))
				else
					minetest.chat_send_player(player_name, S("Unable to find a pocket dimension to configure."))
				end
				return
			end
		end
		minetest.show_formspec(player_name, "pocket_dimensions:config", get_config_formspec(player_name, pocket_data))
	end
})

minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "pocket_dimensions:config" then
		return
	end

	if fields.close then
		return
	end

	local player_name = player:get_player_name()
	local state = config_formspec_state[player_name]
	if state == nil then return end
	
	local pocket_data = state.pocket_data
	
	if not (minetest.check_player_privs(player_name, {server = true}) or
		pocket_data.owner == player_name)
	then
		minetest.chat_send_player(player_name, S("This command is for server admins and pocket owners only."))
		return
	end
	
	local refresh = false
	
	if fields.permitted_table then
		local table_event = minetest.explode_table_event(fields.permitted_table)
		if table_event.type == "CHG" then
			state.row_index = table_event.row
			refresh = true
		end
	end

	if fields.rename and fields.pocket_name ~= pocket_data.name then
		if not rename_pocket(pocket_data.name, fields.pocket_name)then
			minetest.chat_send_player(player_name, S("A pocket dimension with that name already exists"))
		else
			refresh=true
		end
	end
	
	if fields.border then
		local success = set_border(pocket_data.name, fields.border_type)
		if success then
			minetest.chat_send_player(player_name, S("Border type for pocket updated to @1", fields.border_type))
		else
			minetest.chat_send_player(player_name, S("Failed to update pocket dimension border type to @1", fields.border_type))
		end
	end
	
	if fields.remove_permission then
		local is_permitted = pocket_data.protection_permitted[state.selected_player]
		if is_permitted then
			pocket_data.protection_permitted[state.selected_player] = nil
			state.row_index = 1
			refresh = true
		end
	end
	
	if fields.give_permission and not (fields.name_permitted == "" or pocket_data.protection_permitted[fields.name_permitted]) then
		pocket_data.protection_permitted[fields.name_permitted] = true
		refresh = true
	end
	
	if fields.set_entry then
		local pos = player:get_pos()
		local current_pocket_data = pocket_containing_pos(pos)
		if not current_pocket_data then
			minetest.chat_send_player(player_name, S("You're not inside a pocket dimension right now."))
			return
		end
		if player_name ~= current_pocket_data.owner and not minetest.check_player_privs(player_name, "server") then
			minetest.chat_send_player(player_name, S("You don't have permission to change the entry point of pocket dimension @1.", current_pocket_data.name))
			return
		end
		set_destination(current_pocket_data, pos)
		minetest.chat_send_player(player_name, S("The entry point for pocket dimension @1 has been updated", current_pocket_data.name))
	end
	
	if fields.admin and minetest.check_player_privs(player_name, {server = true}) then
		minetest.show_formspec(player_name, "pocket_dimensions:admin", get_admin_formspec(player_name))
	end
	
	if refresh then
		minetest.show_formspec(player_name, "pocket_dimensions:config", get_config_formspec(player_name, pocket_data))
	end
end)

-------------------------------------------------------------------------------------------------------
-- Player commands

minetest.register_chatcommand("pocket_name", {
	params = "",
	description = S("Finds the name of the pocket dimension you're inside right now."),
	func = function(player_name, param)
		local pos = minetest.get_player_by_name(player_name):get_pos()
		local pocket_data = pocket_containing_pos(pos)
		if pocket_data then
			minetest.chat_send_player(player_name, S("You're inside pocket dimension \"@1\"", pocket_data.name))
		else
			minetest.chat_send_player(player_name, S("You're not inside a pocket dimension right now."))
		end
	end,
})