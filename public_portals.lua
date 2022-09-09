local S = minetest.get_translator(minetest.get_current_modname())

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

minetest.register_node("pocket_dimensions:uninitialized_portal", {
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
		portal_formspec_state[player_name] = {pos = pos}
		minetest.show_formspec(player_name, "pocket_dimensions:portal_select", get_select_formspec(player_name))
	end,
})

minetest.register_node("pocket_dimensions:portal", {
    description = S("Pocket Dimension Access Portal"),
    groups = {oddly_breakable_by_hand = 1, not_in_creative_inventory=1},
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
					minetest.set_node(state.pos, {name="pocket_dimensions:portal"})
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

