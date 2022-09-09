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
local personal_pockets_public_key = minetest.settings:get_bool("pocket_dimensions_personal_pockets_public_key", false)

local portal_keys_enabled = minetest.settings:get_bool("pocket_dimensions_portal_keys_enabled", false)

local personal_pockets_enabled = personal_pockets_chat_command or personal_pockets_key or personal_pockets_spawn or personal_pockets_respawn or personal_pockets_public_key

if not personal_pockets_enabled then return end

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

if personal_pockets_key then
	local trigger_def = {
		description = S("Personal Pocket Dimensional Key"),
		_doc_items_longdesc = S("A triggering device that allows teleportation to your personal pocket dimension."),
		_doc_items_usagehelp = S("When triggered, this tool and its user will be teleported to the user's personal pocket dimension.") .. trigger_help_addendum,
		inventory_image = "pocket_dimensions_key.png",
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
