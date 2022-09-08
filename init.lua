pocket_dimensions = {}
local S = minetest.get_translator(minetest.get_current_modname())
local MP = minetest.get_modpath(minetest.get_current_modname())
dofile(MP.."/voxelarea_iterator.lua")
dofile(MP.."/api.lua")
dofile(MP.."/mapgen.lua")

local default_modpath = minetest.get_modpath("default")
local mcl_core_modpath = minetest.get_modpath("mcl_core")

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
local personal_pockets_key_uses = tonumber(minetest.settings:get("pocket_dimensions_personal_pockets_key_uses")) or 0
local personal_pockets_spawn = minetest.settings:get_bool("pocket_dimensions_personal_pockets_spawn", false)
local personal_pockets_respawn = minetest.settings:get_bool("pocket_dimensions_personal_pockets_respawn", false) and not minetest.settings:get_bool("engine_spawn")

local portal_keys_enabled = minetest.settings:get_bool("pocket_dimensions_portal_keys_enabled", false)

local personal_pockets_enabled = personal_pockets_chat_command or personal_pockets_key or personal_pockets_spawn or personal_pockets_respawn

-------------------------------------------------------------------------------
-- Portal node

local portal_formspec_state = {}

local get_select_formspec = function(player_name)
	local formspec = {
		"formspec_version[2]"
		.."size[8,2]"
		.."button_exit[7.0,0.25;0.5,0.5;close;X]"
		.."label[0.5,0.6;"..S("Link to pocket dimension:").."]dropdown[1,1;4,0.5;pocket_select;"
	}
	local names = {}
	for _, def in pairs(get_all_pockets()) do
		table.insert(names, minetest.formspec_escape(def.name))
	end
	table.sort(names)
	portal_formspec_state[player_name].names = names
	formspec[#formspec+1] = table.concat(names, ",") .. ";]"
	return table.concat(formspec)
end

minetest.register_node("pocket_dimensions:portal", {
    description = S("Pocket Dimension Access"),
    groups = {oddly_breakable_by_hand = 1},
	tiles = {"pocket_dimensions_portal.png"},
	is_ground_content=false,	
	drawtype = "nodebox",
	paramtype = "light",
	paramtype2 = "facedir",
	node_box = {
		type = "fixed",
		fixed = {
			{-0.5, -0.375, -0.5, 0.5, -0.25, 0.5},
			{-0.5, 0.25, -0.5, 0.5, 0.375, 0.5},
			{-0.3125, 0.125, -0.3125, 0.3125, 0.5, 0.3125},
			{-0.3125, -0.5, -0.3125, 0.3125, -0.125, 0.3125},
			{-0.125, -0.125, -0.125, 0.125, -0.0625, 0.125},
			{-0.125, 0.0625, -0.125, 0.125, 0.125, 0.125},
			{-0.0625, -0.0625, -0.0625, 0.0625, 0.0625, 0.0625},
		}
	},

	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		local player_name = clicker:get_player_name()
		local meta = minetest.get_meta(pos)
		local pocket_dest = minetest.string_to_pos(meta:get_string("pocket_dest"))
		if pocket_dest then
			local pocket_data = pocket_containing_pos(pocket_dest)
			if pocket_data then
				teleport_player_to_pocket(player_name, pocket_data.name)
				return
			end
		end
		portal_formspec_state[player_name] = {pos = pos}
		minetest.show_formspec(player_name, "pocket_dimensions:portal_select", get_select_formspec(player_name))
	end,
})

minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "pocket_dimensions:portal_select" then
		return
	end

	if fields.close then
		return
	end
	
	local player_name = player:get_player_name()
	local state = portal_formspec_state[player_name]
	if state == nil then
		return
	end
	
	if fields.pocket_select then
		for _, name in pairs(state.names) do
			if fields.pocket_select == name then
				local pocket_data = get_pocket(name) -- TODO: minetest.formspec_escape may screw up this lookup, do something different
				if pocket_data then
					local meta = minetest.get_meta(state.pos)
					meta:set_string("pocket_dest", minetest.pos_to_string(pocket_data.minp))
					meta:set_string("infotext", S("Portal to @1", name))
				end
				minetest.close_formspec(player_name, "pocket_dimensions:portal_select")
				return
			end
		end
	end
end)


--------------------------------------------------------------------------------'
-- Portal key, can be set to a destination from a portal node
if portal_keys_enabled then
	local trigger_wear_amount = 0
	local trigger_tool_capabilities = nil
	local trigger_help_addendum = ""

	if personal_pockets_key_uses > 0 then
		trigger_wear_amount = math.ceil(65535 / personal_pockets_key_uses)
		trigger_tool_capabilities = {
			full_punch_interval=1.5,
			max_drop_level=1,
			groupcaps={},
			damage_groups = {},
		}
		trigger_help_addendum = S(" This tool can be used @1 times before breaking.", personal_pockets_key_uses)
	end

	local key_teleport = function(user, dest)
		local dest = minetest.string_to_pos(dest)
		if not dest then
			return
		end
		local pocket_data = pocket_containing_pos(dest)
		if not pocket_data then
			return
		end
		local player_name = user:get_player_name()
		if trigger_wear_amount > 0 and not minetest.is_creative_enabled(player_name) then
			itemstack:add_wear(trigger_wear_amount)
		end
		teleport_player_to_pocket(player_name, pocket_data.name)
	end


	local trigger_def = {
		description = S("Pocket Dimensional Key"),
		_doc_items_longdesc = S("A triggering device that allows teleportation to a pocket dimension."),
		_doc_items_usagehelp = S("When triggered, this tool and its user will be teleported to the linked pocket dimension.") .. trigger_help_addendum,
		inventory_image = "pocket_dimensions_key.png",
		tool_capabilites = trigger_tool_capabilities,
		sound = {
			breaks = "pocket_dimensions_key_break",
		},
		on_use = function(itemstack, user, pointed_thing)
			local meta = itemstack:get_meta()
			local dest = meta:get_string("pocket_dest")
			if dest ~= "" then
				key_teleport(user, dest)
				return
			elseif pointed_thing.type=="node" then
				local node_target = minetest.get_node(pointed_thing.under)
				if node_target.name == "pocket_dimensions:portal" then
					local node_meta = minetest.get_meta(pointed_thing.under)
					local dest = node_meta:get_string("pocket_dest")
					local dest_pos = minetest.string_to_pos(dest)
					local dest_pocket = pocket_containing_pos(dest_pos)
					if dest_pocket then
						meta:set_string("pocket_dest", dest)
						meta:set_string("description", S('Key to Pocket Dimension "@1"', dest_pocket.name))
					end
				end
			end
		
			return itemstack
		end,
	}

	if trigger_tool_capabilities then
		minetest.register_tool("pocket_dimensions:key", trigger_def)
	else
		minetest.register_craftitem("pocket_dimensions:key", trigger_def)
	end
		
	if default_modpath then
		minetest.register_craft({
			output = "pocket_dimensions:key",
			recipe = {
			{"default:mese_crystal","default:skeleton_key","default:mese_crystal"},
		}})
	elseif mcl_core_modpath then
		minetest.register_craft({
			output = "pocket_dimensions:key",
			recipe = {
			{"mesecons_torch:redstoneblock","group:compass","mesecons_torch:redstoneblock"},
		}})		
	end
end

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
	if minetest.check_player_privs(player_name, {server = true}) then
		formspec[#formspec+1] = "button[0,1.5;3,0.5;admin;" .. S("Admin Screen") .. "]"
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
	
	if fields.admin and minetest.check_player_privs(player_name, {server = true}) then
		minetest.show_formspec(player_name, "pocket_dimensions:admin", get_admin_formspec(player_name))
	end
	
	if refresh then
		minetest.show_formspec(player_name, "pocket_dimensions:config", get_config_formspec(player_name, pocket_data))
	end
end)

--------------------------------------------------------------------------------------------------------
-- Personal pockets

if personal_pockets_enabled then
	function teleport_to_pending(pocket_name, player_name, count)
		local teleported = teleport_player_to_pocket(player_name, pocket_name)
		if teleported then
			return
		end
		if not teleported and count < 10 then
			minetest.after(1, teleport_to_pending, pocket_name, player_name, count + 1)
			return
		end
		minetest.chat_send_player(player_name, S("Teleport to personal pocket dimension @1 failed after @2 tries.", pocket_name, count))
	end
	
	local teleport_to_personal_pocket = function(player_name)
		local pocket_data = get_personal_pocket(player_name)
		if pocket_data then
			teleport_player_to_pocket(player_name, pocket_data.name)
			return
		end

		-- Find an unused default name
		local new_pocket_name = player_name
		if get_pocket(new_pocket_name) then
			local count = 1
			local new_pocket_name_prefix = new_pocket_name
			new_pocket_name = new_pocket_name_prefix .. " " .. count
			while get_pocket(new_pocket_name) do
				count = count + 1
				new_pocket_name = new_pocket_name_prefix .. " " .. count
			end
		end

		local success, message = create_pocket(new_pocket_name, {type="grassy"})
		if success then
			pocket_data = get_pocket(new_pocket_name)
			set_personal_pocket(pocket_data, player_name)
			set_owner(pocket_data, player_name)
			teleport_to_pending(new_pocket_name, player_name, 1)
		end
		minetest.chat_send_player(player_name, message)
	end

	if personal_pockets_chat_command then
		minetest.register_chatcommand("pocket_personal", {
			params = "",
	--		privs = {}, -- TODO a new privilege here?
			description = S("Teleport to your personal pocket dimension"),
			func = function(player_name, param)
				teleport_to_personal_pocket(player_name)
			end,
		})
	end
	
	if personal_pockets_key then
		local trigger_stack_size
		local trigger_wear_amount = 0
		local trigger_tool_capabilities = nil
		local trigger_help_addendum = ""

		if personal_pockets_key_uses > 0 then
			trigger_stack_size = 1
			trigger_wear_amount = math.ceil(65535 / personal_pockets_key_uses)
			trigger_tool_capabilities = {
				full_punch_interval=1.5,
				max_drop_level=1,
				groupcaps={},
				damage_groups = {},
			}
			trigger_help_addendum = S(" This tool can be used @1 times before breaking.", personal_pockets_key_uses)
		end

		local trigger_def = {
			description = S("Personal Pocket Dimensional Key"),
			_doc_items_longdesc = S("A triggering device that allows teleportation to your personal pocket dimension."),
			_doc_items_usagehelp = S("When triggered, this tool and its user will be teleported to the user's personal pocket dimension.") .. trigger_help_addendum,
			inventory_image = "pocket_dimensions_personal_key.png",
			stack_max = trigger_stack_size,
			tool_capabilites = trigger_tool_capabilities,
			sound = {
				breaks = "pocket_dimensions_key_break",
			},
			on_use = function(itemstack, user, pointed_thing)
				local player_name = user:get_player_name()
				teleport_to_personal_pocket(player_name)
				if trigger_wear_amount > 0 and not minetest.is_creative_enabled(player_name) then
					itemstack:add_wear(trigger_wear_amount)
				end
				return itemstack
			end,
		}

		if trigger_tool_capabilities then
			minetest.register_tool("pocket_dimensions:personal_key", trigger_def)
		else
			minetest.register_craftitem("pocket_dimensions:personal_key", trigger_def)
		end
		
		if default_modpath then
			minetest.register_craft({
				output = "pocket_dimensions:personal_key",
				recipe = {
				{"default:mese_crystal","default:skeleton_key"}
			}})
		elseif mcl_core_modpath then
			minetest.register_craft({
				output = "pocket_dimensions:personal_key",
				recipe = {
				{"mesecons_torch:redstoneblock","group:compass"}
			}})		
		end
	end

	if personal_pockets_spawn then

		local return_methods = S("Make sure you take everything you want to before departing,\nthere is no conventional way to return here.")
		local return_method_list = {}
		if personal_pockets_respawn then
			table.insert(return_method_list, S("Dying and respawning"))
		end
		if personal_pockets_key then
			table.insert(return_method_list, S("Crafting and using a pocket dimension key"))
		end
		if personal_pockets_chat_command then
			table.insert(return_method_list, S("Entering the \"/pocket_personal\" chat command"))
		end
		
		if #return_method_list > 0 then
			return_methods = S("You can return to this pocket dimension by:")
			.. "\n* " .. table.concat(return_method_list, "\n* ")
		end	
	
		minetest.register_on_newplayer(function(player)
			local player_name = player:get_player_name()
			teleport_to_personal_pocket(player_name)
			
			minetest.show_formspec(player_name, "pocket_dimensions:intro",
				"formspec_version[2]"
				.."size[8,4]"
				.."button_exit[7.0,0.25;0.5,0.5;close;X]"
				.."textarea[0.25,0.25;6.5,3;;;"
				..S("You have spawned inside your own personal pocket dimension.\nTo leave, walk to within one meter of the pocket dimension's\nboundary and punch the barrier there.")
				.."\n\n"
				..return_methods				
				.."]")
			
			return true
		end)
	end

	if personal_pockets_respawn then
		minetest.register_on_respawnplayer(function(player)
			local player_name = player:get_player_name()
			-- HACK: due to API limitations in the default game's "spawn" mod, this 
			-- code can't override its behaviour cleanly. See https://github.com/minetest/minetest_game/issues/2630
			-- that's why this horrible minetest.after hack is here.
			if default_modpath then
				minetest.after(0, teleport_to_personal_pocket, player_name)
			else			
				teleport_to_personal_pocket(player_name)
			end
			return true
		end)
	end
end

-------------------------------------------------------------------------------------------------------
-- Player commands

minetest.register_chatcommand("pocket_entry", {
	params = "",
--	privs = {}, -- TODO a new privilege here?
	description = S("Set the entry point of the pocket dimension you're in to where you're standing."),
	func = function(player_name, param)
		local pos = minetest.get_player_by_name(player_name):get_pos()
		local pocket_data = pocket_containing_pos(pos)
		if not pocket_data then
			minetest.chat_send_player(player_name, S("You're not inside a pocket dimension right now."))
			return
		end
		if player_name ~= pocket_data.owner and not minetest.check_player_privs(player_name, "server") then
			minetest.chat_send_player(player_name, S("You don't have permission to change the entry point of pocket dimension @1.", pocket_data.name))
			return
		end
		set_destination(pocket_data, pos)
		minetest.chat_send_player(player_name, S("The entry point for pocket dimension @1 has been updated", pocket_data.name))
	end,
})

minetest.register_chatcommand("pocket_rename", {
	params = "pocketname",
--	privs = {}, -- TODO a new privilege here?
	description = S("Renames the pocket dimension you're inside."),
	func = function(player_name, param)
		if param == nil or param == "" then
			minetest.chat_send_player(player_name, S("Please provide a name as a parameter to this command."))
			return
		end
		local pos = minetest.get_player_by_name(player_name):get_pos()
		local pocket_data = pocket_containing_pos(pos)
		if not pocket_data then
			minetest.chat_send_player(player_name, S("You're not inside a pocket dimension right now."))
			return
		end		
		if player_name ~= pocket_data.owner and not minetest.check_player_privs(player_name, "server") then
			minetest.chat_send_player(player_name, S("You don't have permission to change the name of pocket dimension @1.", pocket_data.name))
			return
		end
		local oldname = pocket_data.name
		if rename_pocket(oldname, param) then
			minetest.chat_send_player(player_name, S("The name of pocket dimension @1 has been changed to \"@2\".", oldname, param))
		else
			minetest.chat_send_player(player_name, S("A pocket dimension with that name already exists"))
		end
	end,
})

minetest.register_chatcommand("pocket_name", {
	params = "",
--	privs = {}, -- TODO a new privilege here?
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