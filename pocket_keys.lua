local portal_keys_enabled = minetest.settings:get_bool("pocket_dimensions_portal_keys_enabled", false)
if not portal_keys_enabled then return end

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

local personal_pockets_key_uses = tonumber(minetest.settings:get("pocket_dimensions_portal_key_uses")) or 0

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

local unimprinted_trigger_def = {
	description = S("Unimprinted Pocket Dimension Key"),
	_doc_items_longdesc = S("A triggering device that allows teleportation to a specific pocket dimension. This one has not yet been imprinted on a destination."),
	_doc_items_usagehelp = S("When triggered inside a pocket dimension, this tool will become permanently imprinted on it and will allow its user to teleport there.") .. trigger_help_addendum,
	inventory_image = "pocket_dimensions_key_unimprinted.png",
	on_use = function(itemstack, user, pointed_thing)
		local user_pos = user:get_pos()
		local pocket_data = pocket_containing_pos(user_pos)
		if pocket_data and (not pocket_data.owner or pocket_data.owner == user:get_player_name() or minetest.check_player_privs(user:get_player_name(), {server = true})) then
			local imprinted_key = ItemStack("pocket_dimensions:key")
			local meta = imprinted_key:get_meta()
			meta:set_string("pocket_dest", minetest.pos_to_string(pocket_data.minp))
			meta:set_string("description", S('Key to Pocket Dimension "@1"', pocket_data.name))
			return imprinted_key
		end
		return itemstack
	end,
}

local imprinted_trigger_def = {
	description = S("Pocket Dimension Key"),
	_doc_items_longdesc = S("A triggering device that allows teleportation to a specific pocket dimension."),
	_doc_items_usagehelp = S("When triggered this tool will teleport its user to its imprinted destination pocket dimension.") .. trigger_help_addendum,
	inventory_image = "pocket_dimensions_key.png",
	tool_capabilites = trigger_tool_capabilities,
	groups = {not_in_creative_inventory=1},
	sound = {
		breaks = "pocket_dimensions_key_break",
	},
	on_use = function(itemstack, user, pointed_thing)
		local meta = itemstack:get_meta()
		local dest = meta:get_string("pocket_dest")
		if dest ~= "" then
			local dest = minetest.string_to_pos(dest)
			if not dest then
				return
			end
			local pocket_data = pocket_containing_pos(dest)
			if not pocket_data then
				return
			end
			
			-- don't allow teleport to the pocket you're already in.
			local user_pos = user:get_pos()
			local user_in_pocket = pocket_containing_pos(user_pos)
			if user_in_pocket and user_in_pocket.name == pocket_data.name then
				return
			end
			
			local player_name = user:get_player_name()
			if trigger_wear_amount > 0 and not minetest.is_creative_enabled(player_name) then
				itemstack:add_wear(trigger_wear_amount)
			end
			teleport_player_to_pocket(player_name, pocket_data.name)
		end
		return itemstack
	end,
}

minetest.register_craftitem("pocket_dimensions:unimprinted_key", unimprinted_trigger_def)
if trigger_tool_capabilities then
	minetest.register_tool("pocket_dimensions:key", imprinted_trigger_def)
else
	minetest.register_craftitem("pocket_dimensions:key", imprinted_trigger_def)
end
