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

-------------------------------------------------------------------------------
-- Portal nodes

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
    description = S("Uninitialized Pocket Dimension Portal"),
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

-----------------------------------------------------------------------------------------------------

minetest.register_node("pocket_dimensions:portal", {
    description = S("Pocket Dimension Portal"),
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
	
	preserve_metadata = function(pos, oldnode, oldmeta, drops)
		local item_metadata = drops[1]:get_meta()
		local value = oldmeta.pocket_dest
		item_metadata:set_string("pocket_dest", value)
		if value ~= nil then
			local minpos = minetest.string_to_pos(value)
			local pocket_data = pocket_containing_pos(minpos)
			item_metadata:set_string("description", S("Portal to @1", pocket_data.name))
		end
	end,

	after_place_node = function(pos, placer, itemstack, pointed_thing)
		local meta = minetest.get_meta(pos)
		local item_meta = itemstack:get_meta()
		local pocket_dest = item_meta:get_string("pocket_dest")
		meta:set_string("pocket_dest", pocket_dest)
		local minpos = minetest.string_to_pos(pocket_dest)
		local pocket_data = pocket_containing_pos(minpos)
		meta:set_string("infotext", S("Portal to @1", pocket_data.name))
	end,
})

minetest.register_abm({
	label = "pocket dimension portal teleportation",
	nodenames = {"pocket_dimensions:portal"},
	neighbors = {"air"},
	interval = 1.0,
	chance = 1,
	action = function(pos, node, active_object_count, active_object_count_wider)
		local meta = minetest.get_meta(pos)
		local pocket_dest = minetest.string_to_pos(meta:get_string("pocket_dest"))
		if pocket_dest then
			local pocket_data = pocket_containing_pos(pocket_dest)
			if pocket_data then
				for _, player in ipairs(minetest.get_connected_players()) do
					local player_pos = player:get_pos()
					player_pos = vector.floor(vector.add(player_pos, {x=0.5, y=0, z=0.5}))
					if vector.equals(pos, player_pos) then
						local player_name = player:get_player_name()
						teleport_player_to_pocket(player_name, pocket_data.name, {x=pos.x, y=pos.y, z=pos.z})
					end
				end
			end		
		end		
	end,
})