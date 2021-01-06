pocket_dimensions = {}
local S = minetest.get_translator(minetest.get_current_modname())
local MP = minetest.get_modpath(minetest.get_current_modname())
dofile(MP.."/voxelarea_iterator.lua")
dofile(MP.."/api.lua")

-- API
local get_pocket = pocket_dimensions.get_pocket
local get_all_pockets = pocket_dimensions.get_all_pockets
local get_deleted_pockets = pocket_dimensions.get_deleted_pockets
local rename_pocket = pocket_dimensions.rename_pocket
local register_pocket_type = pocket_dimensions.register_pocket_type
local create_pocket = pocket_dimensions.create_pocket
local delete_pocket = pocket_dimensions.delete_pocket
local undelete_pocket = pocket_dimensions.undelete_pocket
local set_protection = pocket_dimensions.set_protection
local pocket_containing_pos = pocket_dimensions.pocket_containing_pos
local set_destination = pocket_dimensions.set_destination
local get_personal_pocket = pocket_dimensions.get_personal_pocket
local set_personal_pocket = pocket_dimensions.set_personal_pocket
local set_owner = pocket_dimensions.set_owner
local teleport_player_to_pocket = pocket_dimensions.teleport_player_to_pocket
local return_player_to_origin = pocket_dimensions.return_player_to_origin

local pocket_size = pocket_dimensions.pocket_size

local personal_pockets_chat_command = minetest.settings:get_bool("pocket_dimensions_personal_pockets_chat_command", false)
local personal_pockets_key = minetest.settings:get_bool("pocket_dimensions_personal_pockets_key", false)
local personal_pockets_key_uses = tonumber(minetest.settings:get("pocket_dimensions_personal_pockets_key_uses")) or 0
local personal_pockets_spawn = minetest.settings:get_bool("pocket_dimensions_personal_pockets_spawn", false)
local personal_pockets_respawn = minetest.settings:get_bool("pocket_dimensions_personal_pockets_respawn", false) and not minetest.settings:get_bool("engine_spawn")

local personal_pockets_enabled = personal_pockets_chat_command or personal_pockets_key or personal_pockets_spawn or personal_pockets_respawn

local c_air = minetest.get_content_id("air")

local c_dirt
local c_dirt_with_grass
local c_stone
local c_water
local c_sand

local default_modpath = minetest.get_modpath("default")
if default_modpath then
	c_dirt = minetest.get_content_id("default:dirt")
	c_dirt_with_grass = minetest.get_content_id("default:dirt_with_grass")
	c_stone = minetest.get_content_id("default:stone")
	c_water = minetest.get_content_id("default:water_source")
	c_sand = minetest.get_content_id("default:sand")
end
local mcl_core_modpath = minetest.get_modpath("mcl_core")
if mcl_core_modpath then
	c_dirt = minetest.get_content_id("mcl_core:dirt")
	c_dirt_with_grass = minetest.get_content_id("mcl_core:dirt_with_grass")
	c_stone = minetest.get_content_id("mcl_core:stone")
	c_water = minetest.get_content_id("mcl_core:water_source")
	c_sand = minetest.get_content_id("mcl_core:sand")
end


-----------------------------------------------------------------
-- Border materials

local get_border_def = function(override)
	local def = {
		description = S("Boundary of a pocket dimension"),
		groups = {not_in_creative_inventory = 1},
		drawtype = "normal",  -- See "Node drawtypes"
		paramtype = "light",  -- See "Nodes"
		paramtype2 = "none",  -- See "Nodes"
		is_ground_content = false, -- If false, the cave generator and dungeon generator will not carve through this node.
		walkable = true,  -- If true, objects collide with node
		pointable = true,  -- If true, can be pointed at
		diggable = false,  -- If false, can never be dug
		node_box = {type="regular"},  -- See "Node boxes"
		sounds = {
            footstep = {name = "pocket_dimensions_footstep", gain = 0.25},
		},
		can_dig = function(pos, player) return false end,
		on_blast = function(pos, intensity) return false end,
        on_punch = function(pos, node, clicker, pointed_thing)
			if vector.distance(pos, clicker:get_pos()) > 2 then
				return
			end
			return_player_to_origin(clicker:get_player_name())
		end,
		on_construct = function(pos)
			-- if somehow a player gets ahold of one of these, ensure they can't place it anywhere.
			minetest.set_node(pos, {name="air"})
		end,
		after_destruct = function(pos, oldnode)
			-- likewise, don't let players remove these if they manage it somehow
			minetest.set_node(pos, oldnode)
		end,
	}
	for key, value in pairs(override) do
		def[key] = value
	end
	return def
end

minetest.register_node("pocket_dimensions:border_glass", get_border_def({
	light_source = 4,
	sunlight_propagates = true, -- If true, sunlight will go infinitely through this node
	use_texture_alpha = true,
	tiles = {{name="pocket_dimensions_transparent.png",
		tileable_vertical=true,
		tileable_horizontal=true,
		align_style="world",
		scale=2,
	}},
}))

local c_border_glass = minetest.get_content_id("pocket_dimensions:border_glass")

minetest.register_node("pocket_dimensions:border_gray", get_border_def({
	tiles = {{name="pocket_dimensions_white.png", color="#888888"}}
}))

local c_border_gray = minetest.get_content_id("pocket_dimensions:border_gray")

---------------------------------------------------------------
-- Pocket mapgens

local scale_magnitude = 5

local perlin_params = {
    offset = 0,
    scale = scale_magnitude,
    spread = {x = pocket_size, y = pocket_size, z = pocket_size},
    seed = 577,
    octaves = 5,
    persist = 0.63,
    lacunarity = 2.0,
}

local perlin_noise = PerlinNoise(perlin_params)

-- TODO don't know why minetest.get_perlin_map isn't working here, but don't really care
-- pocket dimensions are distributed randomly so doesn't really matter whether their terrain
-- is world-seeded. Nobody will ever notice.
local terrain_map = PerlinNoiseMap(
	perlin_params,
	{x=pocket_size, y=pocket_size, z=pocket_size}
)

-- Once the map block for the new pocket dimension is loaded, this initializes its node layout and finds a default spot for arrivals to teleport to
local grassy_mapgen = function(pocket_data)
	local minp = pocket_data.minp
	local maxp = vector.add(minp, pocket_size)
	local vm = minetest.get_voxel_manip(minp, maxp)
	local emin, emax = vm:get_emerged_area()
	local data = vm:get_data()
	local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}
	local surface = minp.y + 40
	local terrain_values = terrain_map:get_2d_map(minp)
	
	-- Default is down on the floor of the border walls, in case default mod isn't installed and no landscape is created
	local middlep = {x=minp.x + math.floor(pocket_size/2), y=2, z=minp.z + math.floor(pocket_size/2)}

	local tree_spots = {}
	for vi, x, y, z in area:iterp_xyz(minp, maxp) do
		if x == minp.x or x == maxp.x or y == minp.y or y == maxp.y or z == minp.z or z == maxp.z then
			data[vi] = c_border_glass
		elseif default_modpath or mcl_core_modpath then
			local terrain_level = math.floor(terrain_values[x-minp.x+1][z-minp.z+1] + surface)
			local below_water = y < surface
			if y == terrain_level then
				if below_water then
					data[vi] = c_sand
				else
					data[vi] = c_dirt_with_grass
					if math.random() < 0.01 and x > minp.x + 3 and x < maxp.x - 3 and z > minp.z + 3 and z < maxp.z - 3 then
						table.insert(tree_spots, {x=x,y=y+1,z=z})
					end
				end
				if middlep.x == x and middlep.z == z then
					middlep.y = math.max(y + 1, minp.y + pocket_size/2) -- surface of the ground or water in the center of the block
				end
			elseif y == terrain_level - 1 then
				if below_water then
					data[vi] = c_sand
				else
					data[vi] = c_dirt
				end
			elseif y <= terrain_level - 2 then
				data[vi] = c_stone
			elseif below_water then
				data[vi] = c_water
			else
				data[vi] = c_air
			end
		end
	end
	
	vm:set_data(data)
	vm:write_to_map()
	
	for _, pos in pairs(tree_spots) do
		if default_modpath then
			default.grow_tree(pos, math.random() < 0.5)
		elseif mcl_core_modpath then
			mcl_core.generate_tree(pos, 1)
		end
	end
	
	return middlep
end

register_pocket_type("grassy", grassy_mapgen)

local cave_mapgen = function(pocket_data)
	local minp = pocket_data.minp
	local maxp = vector.add(minp, pocket_size)
	local vm = minetest.get_voxel_manip(minp, maxp)
	local emin, emax = vm:get_emerged_area()
	local data = vm:get_data()
	local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}
	local terrain_values = terrain_map:get_3d_map(minp)
	
	local nearest_to_center = vector.add(minp, 2) -- start off down in the corner
	local center = vector.add(minp, math.floor(pocket_size/2))
	for vi, x, y, z in area:iterp_xyz(minp, maxp) do
		if x == minp.x or x == maxp.x or y == minp.y or y == maxp.y or z == minp.z or z == maxp.z then
			data[vi] = c_border_gray
		elseif default_modpath or mcl_core_modpath then
			local terrain_level = terrain_values[x-minp.x+1][y-minp.y+1][z-minp.z+1]
			if terrain_level <= 2 then
				data[vi] = c_stone
			else
				data[vi] = c_air
				if vector.distance({x=x,y=y,z=z}, center) < vector.distance(nearest_to_center, center) then
					nearest_to_center = {x=x,y=y,z=z}
				end
			end
		end
	end
	
	vm:set_data(data)
	vm:write_to_map()
	
	-- drop the entry point downward until it hits non-air.
	while minetest.get_node(nearest_to_center).name == "air" and nearest_to_center.y > minp.y do
		nearest_to_center.y = nearest_to_center.y -1
	end
	nearest_to_center.y = nearest_to_center.y + 2
	
	return nearest_to_center
end

register_pocket_type("cave", cave_mapgen)


-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- Admin commands

local formspec_state = {}
local get_admin_formspec = function(player_name)
	formspec_state[player_name] = formspec_state[player_name] or {row_index=1}
	local state = formspec_state[player_name]

	local formspec = {
		"formspec_version[2]"
		.."size[8,10]"
		.."button_exit[7.0,0.25;0.5,0.5;close;X]"
	}
	
	formspec[#formspec+1] = "tablecolumns[text,tooltip="..S("Name")
		..";text,tooltip="..S("Owner")
		..";text,tooltip="..S("Protected")
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
	
	local i = 0
	for _, pocket_data in pairs(table_to_use) do
		i = i + 1
		if i == state.row_index then
			state.selected_data = pocket_data
		end
		local owner = pocket_data.owner or "<none>"
		formspec[#formspec+1] = minetest.formspec_escape(pocket_data.name)
			..",".. minetest.formspec_escape(owner)
			..","..tostring(pocket_data.protected or "false")
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
		.."dropdown[5.5,0.5;1,0.5;create_type;grassy,cave;1]"
		.."button[0,1;3,0.5;teleport;"..S("Teleport To").."]"
		.."button[3.5,1;3,0.5;protect;"..S("Toggle Protect").."]"
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
	local state = formspec_state[player_name]
	local pocket_data = state.selected_data
	if state == nil then
		return
	end

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
		local success, message = create_pocket(fields.pocket_name, {type=fields.create_type})
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
	
	if fields.protect then
		set_protection(pocket_data, not pocket_data.protected)
		refresh = true
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
			set_protection(pocket_data, true)
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
		local trigger_stack_size = 99
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
				.."size[8,3]"
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