local default_modpath = minetest.get_modpath("default")
local mcl_core_modpath = minetest.get_modpath("mcl_core")

local personal_pockets_key = minetest.settings:get_bool("pocket_dimensions_personal_pockets_key", false)
if personal_pockets_key then
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

local portal_keys_enabled = minetest.settings:get_bool("pocket_dimensions_portal_keys_enabled", false)
if portal_keys_enabled then
	if default_modpath then
		minetest.register_craft({
			output = "pocket_dimensions:unimprinted_key",
			recipe = {
			{"default:mese_crystal","default:skeleton_key","default:mese_crystal"},
		}})
	elseif mcl_core_modpath then
		minetest.register_craft({
			output = "pocket_dimensions:unimprinted_key",
			recipe = {
			{"mesecons_torch:redstoneblock","group:compass","mesecons_torch:redstoneblock"},
		}})
	end
end

local craftable_portals = minetest.settings:get_bool("pocket_dimensions_craftable_portals", false)
--"pocket_dimensions:uninitialized_portal" recipe

local craftable_pockets = minetest.settings:get_bool("pocket_dimensions_craftable_pocket_dimensions", false)
if craftable_pockets then

	-- these are exposed so that other mods can fiddle with them
	pocket_dimensions.pocket_forge_target_value = 100
	pocket_dimensions.get_item_value = function(item_stack)
		local item_name = item_stack:get_name()
		local item_count = item_stack:get_count()
		
		if item_name == "pocket_dimensions:pocket_forge" then
			local meta = item_stack:get_meta()
			local value = meta:get_int("value")
			return 1/2560 + value
		end
		
		if item_name == "default:cobble" then
			return item_count
		end
		if minetest.registered_nodes[item_name] then
			return item_count * 1/2560
		end
		return 0
	end
	
	-- "pocket_dimensions:pocket_forge" recipe
end