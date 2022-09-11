local craftable_pockets = minetest.settings:get_bool("pocket_dimensions_craftable_pocket_dimensions", false)
if not craftable_pockets then return end

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

local portal_formspec_state = {}

local get_create_formspec = function(player_name)
	local state = portal_formspec_state[player_name]
	local pos = state.pos
	local inv_loc = "nodemeta:"..pos.x..","..pos.y..","..pos.z
	local meta = minetest.get_meta(pos)
	local current_value = meta:get_float("value")
	
	local formspec = {
		"formspec_version[2]"
		.."size[11,8.5]"
		.."container[1.5,0.5]"
			.."box[0,0;8,1;#222222ff]box[0,0.1;".. tostring(current_value/pocket_dimensions.pocket_forge_target_value * 8)..",0.85;#ff00ff44]"
			.."label[3.5,0.5;"..tostring(math.floor(current_value/pocket_dimensions.pocket_forge_target_value *1000000)/10000).."%]"
		.."container_end[]"
		.."list[current_player;main;0.625,3;8,4;]"
	}
	if current_value >= pocket_dimensions.pocket_forge_target_value then
		formspec[#formspec+1] = "button[4,2;3,0.5;create;"..S("Create Pocket Dimension").."]"
	else
		formspec[#formspec+1] = "list[" .. inv_loc .. ";main;5,1.75;1,1;]"
			.."listring[]"
	end
	return table.concat(formspec)
end

local portal_craft_formspec_name = "pocket_dimensions:portal_craft"
local update_infotext = function(pos)
	local meta = minetest.get_meta(pos)
	local value = meta:get_float("value")
	if value > 0 then
		if value < pocket_dimensions.pocket_forge_target_value then
			meta:set_string("infotext", S("Partly Charged Pocket Dimension Forge (@1%)", math.floor(value/pocket_dimensions.pocket_forge_target_value*100)))
		else
			meta:set_string("infotext", S("Fully Charged Pocket Dimension Forge"))
		end
	end
end

minetest.register_node("pocket_dimensions:pocket_forge", {
    description = S("Pocket Dimension Forge"),
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
	
	preserve_metadata = function(pos, oldnode, oldmeta, drops)
		local item_metadata = drops[1]:get_meta()
		local value = tonumber(oldmeta.value or 0)
		item_metadata:set_float("value", value)
		if value > 0 then
		if value < pocket_dimensions.pocket_forge_target_value then
			item_metadata:set_string("description", S("Partly Charged Pocket Dimension Forge (@1%)", math.floor(value/pocket_dimensions.pocket_forge_target_value*100)))
		else
			item_metadata:set_string("description", S("Fully Charged Pocket Dimension Forge"))
		end
		end
	end,

	after_place_node = function(pos, placer, itemstack, pointed_thing)
		local meta = minetest.get_meta(pos)
		local item_meta = itemstack:get_meta()
		local value = item_meta:get_float("value")
		meta:set_float("value", value)
		update_infotext(pos)
	end,
	
	allow_metadata_inventory_put = function(pos, listname, index, stack, player)
        -- Called when a player wants to put something into the inventory.
        -- Return value: number of items allowed to put.
		if pocket_dimensions.get_item_value(stack) > 0 then
			return -1
		end
		return 0
	end,
	
	on_metadata_inventory_put = function(pos, listname, index, stack, player)
		local player_name = player:get_player_name()
		local meta = minetest.get_meta(pos)
		local new_value = math.min(meta:get_float("value") + pocket_dimensions.get_item_value(stack), pocket_dimensions.pocket_forge_target_value)
		meta:set_float("value", new_value)
		update_infotext(pos)
		minetest.show_formspec(player_name, portal_craft_formspec_name, get_create_formspec(player_name))
	end,

	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		local player_name = clicker:get_player_name()
		portal_formspec_state[player_name] = {pos = pos}
		local meta = minetest.get_meta(pos)
		local inv = meta:get_inventory()
		inv:set_size("main", 1)
		minetest.show_formspec(player_name, "pocket_dimensions:portal_craft", get_create_formspec(player_name))
	end,
})

minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= portal_craft_formspec_name then return end
	local player_name = player:get_player_name()
	local pos = portal_formspec_state[player_name].pos
	local meta = minetest.get_meta(pos)
	local value = meta:get_float("value")
	if fields.create and value >= pocket_dimensions.pocket_forge_target_value then
		local new_pocket_name = pocket_dimensions.unused_pocket_name(player_name)
		local success, message = create_pocket(new_pocket_name, {type="copy location", origin_location = vector.subtract(pos, math.floor(pocket_dimensions.pocket_size/2))})
		if success then
			pocket_data = pocket_dimensions.get_pocket(new_pocket_name)
			set_owner(pocket_data, player_name)
			pocket_dimensions.teleport_to_pending(new_pocket_name, player_name, 1)
			minetest.set_node(pos, {name="pocket_dimensions:portal"})
			meta:set_string("pocket_dest", minetest.pos_to_string(pocket_data.minp))
			meta:set_string("infotext", S("Portal to @1", new_pocket_name))
		end
		minetest.chat_send_player(player_name, message)
	end
end)

