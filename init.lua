pocket_dimensions = {}
local S = minetest.get_translator(minetest.get_current_modname())
local MP = minetest.get_modpath(minetest.get_current_modname())
dofile(MP.."/voxelarea_iterator.lua")

--The world is a cube of side length 61840. Coordinates go from -30912 to 30927 in any direction.
--The side length is a multiple of 80
--773 * 80 = 61840
-- so there are 773 * 773 = 597529 chunk in a horizontal layer. Should be plenty for distributing these things in.

local mapgen_chunksize = tonumber(minetest.get_mapgen_setting("chunksize"))
local mapblock_size = mapgen_chunksize * 16 -- should be 80 in almost all cases, but avoiding hardcoding it for extensibility
local block_grid_dimension = math.floor(61840 / mapblock_size) -- should be 773
local min_coordinate = -30912

local layer_elevation = tonumber(minetest.settings:get("pocket_dimensions_altitude")) or 30000
layer_elevation = math.floor(layer_elevation / mapblock_size) * mapblock_size - 32 -- round to mapblock boundary

local personal_pockets_enabled = minetest.settings:get_bool("pocket_dimensions_personal_pockets", false)

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


-- pocket data tables have the following properties:
-- pending = true -- pocket is being initialized, don't teleport there just yet
-- destination = a vector relative to the pocket's minp that is where new arrivals teleport tonumber
-- name = a name for the pocket.
-- owner = if set, this pocket is "owned" by this particular player.
-- protected = if true, this pocket is protected and only the owner can modify its contents
-- minp = the lower corner of the pocket's region

local pockets_by_hash = {}
local pockets_by_name = {}
local player_origin = {}
local pockets_deleted = {} -- record deleted pockets for possible later undeletion, indexed by hash
local personal_pockets -- to be filled out if personal pockets are enabled

local protected_areas = AreaStore()

-- protection override
local old_is_protected = minetest.is_protected
function minetest.is_protected(pos, name)
	if minetest.check_player_privs(name, "protection_bypass") then
		return false
	end
	local protection = protected_areas:get_areas_for_pos(pos, false, true)
	for _, area in pairs(protection) do
		if area.data ~= name then
			return true
		end
	end
	return old_is_protected(pos, name)
end

--------------------------------------------------------------------------------------
-- Loading and saving data
local filename = minetest.get_worldpath() .. "/pocket_dimensions_data.lua"

local load_data = function()
	local f, e = loadfile(filename)
	if f then
		local data = f()
		pockets_by_hash = data.pockets_by_hash
		pockets_by_name = {} -- to be filled from pockets_by_hash
		player_origin = data.player_origin
		pockets_deleted = data.pockets_deleted
		if personal_pockets_enabled then
			personal_pockets = {}
			for hash, pocket_data in pairs(pockets_by_hash) do
				if pocket_data.personal then
					personal_pockets[pocket_data.personal] = pocket_data
				end
			end
		end
	else
		return
	end
	
	-- validate and add saved protected areas
	for hash, pocket_data in pairs(pockets_by_hash) do
		if hash ~= minetest.hash_node_position(pocket_data.minp) then
			minetest.log("error", "[pocket_dimensions] Hash mismatch for " .. tostring(hash) .. ", " .. dump(pocket_data))
			pocket_data.minp = minetest.get_position_from_hash(hash)
		end
		pockets_by_name[string.lower(pocket_data.name)] = pocket_data		
		if pocket_data.protected then
			protected_areas:insert_area(pocket_data.minp, vector.add(pocket_data.minp, mapblock_size), pocket_data.owner)
		end
	end
end

local save_data = function()
	local data = {}
	data.pockets_by_hash = pockets_by_hash
	data.player_origin = player_origin
	data.pockets_deleted = pockets_deleted
	local file, e = io.open(filename, "w");
	if not file then
		return error(e);
	end
	file:write(minetest.serialize(data))
	file:close()
end

load_data()
----------------------------------------------------------------------------------------

-- check if players have got out of pocket dimensions by other means and clear their origin locations
local since_last_check = 0
minetest.register_globalstep(function(dtime)
	since_last_check = since_last_check + dtime
	if since_last_check > 10 then
		for name, _ in pairs(player_origin) do
			local pos = minetest.get_player_by_name(name):get_pos()
			if pos.y < layer_elevation or pos.y > layer_elevation + mapblock_size then
				player_origin[name] = nil -- somehow, player escaped the pocket dimension layer
				since_last_check = 0 -- note that we changed data
			end
		end
		if since_last_check == 0 then
			save_data()
			return
		end
		since_last_check = 0
	end
end)

------------------------------------------------------------------------------------------
-- Teleport effects

local particle_node_pos_spread = vector.new(0.5,0.5,0.5)
local particle_user_pos_spread = vector.new(0.5,1.5,0.5)
local particle_speed_spread = vector.new(0.1,0.1,0.1)
local particle_poof = function(pos)
	minetest.add_particlespawner({
		amount = 100,
		time = 0.1,
		minpos = vector.subtract(pos, particle_node_pos_spread),
		maxpos = vector.add(pos, particle_user_pos_spread),
		minvel = particle_speed_spread,
		maxvel = particle_speed_spread,
		minacc = {x=0, y=0, z=0},
		maxacc = {x=0, y=0, z=0},
		minexptime = 0.1,
		maxexptime = 0.5,
		minsize = 1,
		maxsize = 1,
		collisiondetection = false,
		vertical = false,
		texture = "pocket_dimensions_spark.png",
	})		
end
local teleport_player = function(player, dest)
	local source_pos = player:get_pos()
	particle_poof(source_pos)
	minetest.sound_play({name="pocket_dimensions_teleport_from"}, {pos = source_pos}, true)
	player:set_pos(dest)
	particle_poof(dest)
	minetest.sound_play({name="pocket_dimensions_teleport_to"}, {pos = dest}, true)
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
			local clicker_pos = clicker:get_pos()
			if vector.distance(pos, clicker_pos) > 2 then
				return
			end
			local name = clicker:get_player_name()
			local origin = player_origin[name]
			if origin then
				teleport_player(clicker, origin)
				player_origin[name] = nil
				save_data()
			end
			-- TODO: some fallback that gets the player out of the pocket dimension if their origin got lost somehow
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
-- Pocket creation

local spread_magnitude = mapblock_size
local scale_magnitude = 5

local perlin_params = {
    offset = 0,
    scale = scale_magnitude,
    spread = {x = spread_magnitude, y = spread_magnitude, z = spread_magnitude},
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
	{x=mapblock_size, y=mapblock_size, z=mapblock_size}
)

-- Once the map block for the new pocket dimension is loaded, this initializes its node layout and finds a default spot for arrivals to teleport to
local emerge_grassy_callback = function(blockpos, action, calls_remaining, pocket_data)
	if pocket_data.pending ~= true then
		return
	end
	local minp = pocket_data.minp
	local maxp = vector.add(minp, mapblock_size)
	local vm = minetest.get_voxel_manip(minp, maxp)
	local emin, emax = vm:get_emerged_area()
	local data = vm:get_data()
	local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}
	local surface = minp.y + 40
	local terrain_values = terrain_map:get_2d_map(minp)
	
	-- Default is down on the floor of the border walls, in case default mod isn't installed and no landscape is created
	local middlep = {x=minp.x + math.floor(mapblock_size/2), y=2, z=minp.z + math.floor(mapblock_size/2)}
	
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
				end
				if middlep.x == x and middlep.z == z then
					middlep.y = math.max(y + 1 - minp.y, mapblock_size/2) -- surface of the ground or water in the center of the block
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
	
	middlep.x = math.floor(mapblock_size/2)
	middlep.z = math.floor(mapblock_size/2)
	
	pocket_data.pending = nil
	pocket_data.destination = middlep
	save_data()
	minetest.log("action", "[pocket_dimensions] Finished initializing terrain map for pocket dimension " .. pocket_data.name)
end

local emerge_cave_callback = function(blockpos, action, calls_remaining, pocket_data)
	if pocket_data.pending ~= true then
		return
	end
	local minp = pocket_data.minp
	local maxp = vector.add(minp, mapblock_size)
	local vm = minetest.get_voxel_manip(minp, maxp)
	local emin, emax = vm:get_emerged_area()
	local data = vm:get_data()
	local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}
	local terrain_values = terrain_map:get_3d_map(minp)
	
	local nearest_to_center = vector.add(minp, 2) -- start off down in the corner
	local center = vector.add(minp, math.floor(mapblock_size/2))
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
	
	pocket_data.pending = nil
	pocket_data.destination = vector.subtract(nearest_to_center, minp)
	save_data()
	minetest.log("action", "[pocket_dimensions] Finished initializing map for pocket dimension " .. pocket_data.name)
end


local create_new_pocket = function(pocket_name, player_name, pocket_data_override)
	pocket_data_override = pocket_data_override or {}
	pocket_data_override.type = pocket_data_override.type or "grassy"
	if pocket_name == nil or pocket_name == "" then
		if player_name then
			minetest.chat_send_player(player_name, S("Please provide a name for the pocket dimension"))
		end
		return
	end

	if pockets_by_name[string.lower(pocket_name)] then
		if player_name then
			minetest.chat_send_player(player_name, S("The name @1 is already in use.", pocket_name))
		end
		return
	end

	local count = 0
	while count < 100 do
		local x = math.random(0, block_grid_dimension) * mapblock_size + min_coordinate
		local z = math.random(0, block_grid_dimension) * mapblock_size + min_coordinate
		local pos = {x=x, y=layer_elevation, z=z}
		local hash = minetest.hash_node_position(pos)
		if pockets_by_hash[hash] == nil and pockets_deleted[hash] == nil then
			local pocket_data = {pending=true, minp=pos, name=pocket_name}
			pockets_by_hash[hash] = pocket_data
			pockets_by_name[string.lower(pocket_name)] = pocket_data
			for key, value in pairs(pocket_data_override) do
				pocket_data[key] = value
			end
			if pocket_data.type == "grassy" then
				minetest.emerge_area(pos, pos, emerge_grassy_callback, pocket_data)
			else
				minetest.emerge_area(pos, pos, emerge_cave_callback, pocket_data)
			end
			save_data()
			minetest.chat_send_player(player_name, S("Pocket dimension @1 created", pocket_name))
			minetest.log("action", "[pocket_dimensions] " .. player_name .. " Created a pocket dimension named " .. pocket_name .. " at " .. minetest.pos_to_string(pos))
			return pocket_data
		end
	end
	
	if player_name then
		minetest.chat_send_player(player_name, S("Failed to find a new location for this pocket dimension."))
	end
	return nil
end

local teleport_player_to_pocket = function(player_name, pocket_name)
	local pocket_data = pockets_by_name[string.lower(pocket_name)]
	if pocket_data == nil or pocket_data.pending then
		return false
	end

	local dest = vector.add(pocket_data.minp, pocket_data.destination)
	local player = minetest.get_player_by_name(player_name)
	if not player_origin[player_name] then
		player_origin[player_name] = player:get_pos()
		save_data()
	end
	teleport_player(player, dest)
	return true
end


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
	for name, def in pairs(pockets_by_name) do
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
			local pocket_data = pockets_by_hash[minetest.hash_node_position(pocket_dest)]
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
				local pocket_data = pockets_by_name[string.lower(name)] -- TODO: minetest.formspec_escape may screw up this lookup, do something different
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

local update_protected = function(pocket_data)
	-- clear any existing protection
	protected = protected_areas:get_areas_for_pos(pocket_data.minp)
	for id, _ in pairs(protected) do
		protected_areas:remove_area(id)
	end
	-- add protection if warranted
	if pocket_data.protected then
		protected_areas:insert_area(pocket_data.minp, vector.add(pocket_data.minp, mapblock_size), pocket_data.owner)
	end
end

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
	if personal_pockets then
		formspec[#formspec+1] = ";text,tooltip="..S("Personal")
	end
	formspec[#formspec+1] = "]table[0.5,1.0;7,5.75;pocket_table;"
	
	local table_to_use = pockets_by_name
	local delete_label = S("Delete")
	local undelete_toggle = "false"
	if state.undelete == "true" then
		table_to_use = pockets_deleted
		delete_label = S("Undelete")
		undelete_toggle = "true"
	end
	
	local i = 0
	for _, dimension_data in pairs(table_to_use) do
		i = i + 1
		if i == state.row_index then
			state.selected_data = dimension_data
		end
		local owner = dimension_data.owner or "<none>"
		formspec[#formspec+1] = minetest.formspec_escape(dimension_data.name)
			..",".. minetest.formspec_escape(owner)
			..","..tostring(dimension_data.protected or "false")
		if personal_pockets then
			formspec[#formspec+1] = ","..tostring(dimension_data.personal)
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
		if pockets_by_name[string.lower(fields.pocket_name)] then
			minetest.chat_send_player(player_name, S("A pocket dimension with that name already exists"))
		else
			pockets_by_name[string.lower(fields.pocket_name)] = pocket_data
			pockets_by_name[string.lower(pocket_data.name)] = nil
			pocket_data.name = fields.pocket_name
			save_data()
			refresh=true
		end
	end
	
	if fields.undelete_toggle then
		state.undelete = fields.undelete_toggle
		refresh = true
	end
	
	if fields.create then
		if create_new_pocket(fields.pocket_name, player_name, {type=fields.create_type}) then
			refresh = true
		end
	end
	
	if fields.delete then
		local pocket_hash = minetest.hash_node_position(pocket_data.minp)
		if state.undelete == "true" then
			if pockets_by_name[string.lower(pocket_data.name)] then
				minetest.chat_send_player(player_name, S("Cannot undelete, a pocket dimension with that name already exists"))
			else
				pockets_deleted[pocket_hash] = nil
				pockets_by_name[string.lower(pocket_data.name)] = pocket_data
				pockets_by_hash[pocket_hash] = pocket_data
				if pocket_data.personal and personal_pockets and not personal_pockets[pocket_data.personal] then
					-- it was a personal pocket and the player hasn't created a new one, so restore that association
					personal_pockets[pocket_data.personal] = pocket_data
				end
				minetest.chat_send_player(player_name, S("Undeleted pocket dimension @1 at @2. Note that this doesn't affect the map, just moves this pocket dimension out of regular access and into the deleted list.", pocket_data.name, minetest.pos_to_string(pocket_data.minp)))
				minetest.log("action", "[pocket_dimensions] " .. player_name .. " undeleted the pocket dimension " .. pocket_data.name .. " at " .. minetest.pos_to_string(pocket_data.minp))
			end				
		else
			pockets_deleted[pocket_hash] = pocket_data
			pockets_by_name[string.lower(pocket_data.name)] = nil
			pockets_by_hash[pocket_hash] = nil
			if personal_pockets then
				for name, personal_pocket_data in pairs(personal_pockets) do
					if pocket_data == personal_pocket_data then
						-- we're deleting a personal pocket, remove its record
						personal_pockets[name] = nil
						break
					end
				end
			end
			minetest.chat_send_player(player_name, S("Deleted pocket dimension @1 at @2. Note that this doesn't affect the map, just moves this pocket dimension out of regular access and into the deleted list.", pocket_data.name, minetest.pos_to_string(pocket_data.minp)))
			minetest.log("action", "[pocket_dimensions] " .. player_name .. " deleted the pocket dimension " .. pocket_data.name .. " at " .. minetest.pos_to_string(pocket_data.minp))
		end
		save_data()
		state.row_index = 1
		refresh = true
	end
	
	if fields.protect then
		pocket_data.protected = not pocket_data.protected
		update_protected(pocket_data)
		minetest.log("action", "[pocket_dimensions] " .. player_name .. " set protection ownership of pocket dimension " .. pocket_data.name .. " to " .. tostring(pocket_data.protected))
		save_data()
		refresh = true
	end
	
	if fields.teleport and pocket_data then
		teleport_player_to_pocket(player_name, state.selected_data.name)
	end
	
	if fields.set_owner and pocket_data.owner ~= fields.owner then
		if fields.owner == "" then
			pocket_data.owner = nil
		else
			pocket_data.owner = fields.owner
		end
		save_data()
		refresh = true
	end
	
	if refresh then
		minetest.show_formspec(player_name, "pocket_dimensions:admin", get_admin_formspec(player_name))
	end
end)

-------------------------------------------------------------------------------------------------------
-- Player commands

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

	minetest.register_chatcommand("pocket_personal", {
		params = "[pocketname]",
--		privs = {}, -- TODO a new privilege here?
		description = S("Teleport to your personal pocket dimension"),
		func = function(player_name, param)
	
			local pocket_data = personal_pockets[player_name]
			if pocket_data then
				teleport_player_to_pocket(player_name, pocket_data.name)
				return
			end
	
			if param == nil or param == "" then
				minetest.chat_send_player(player_name, S("You need to give your personal pocket dimension a name the first time you visit it. Use /pocket_personal pocketname. You can rename it later with /pocket_rename"))
				return
			end

			pocket_data = create_new_pocket(param, player_name, {protected=true, owner=player_name, personal=player_name, type="grassy"})
			if pocket_data then
				personal_pockets[player_name] = pocket_data
				teleport_to_pending(param, player_name, 1)
			end
		end,
	})
end

minetest.register_chatcommand("pocket_entry", {
	params = "",
--	privs = {}, -- TODO a new privilege here?
	description = S("Set the entry point of the pocket dimension you're in to where you're standing."),
	func = function(player_name, param)
		local pos = minetest.get_player_by_name(player_name):get_pos()
		-- Find the pocket the player's in
		for hash, pocket_data in pairs(pockets_by_hash) do
			local pos_diff = vector.subtract(pos, pocket_data.minp)
			if pos_diff.y >=0 and pos_diff.y <= mapblock_size and -- check y first to eliminate possibility player's not in a pocket dimension at all
				pos_diff.x >=0 and pos_diff.x <= mapblock_size and
				pos_diff.z >=0 and pos_diff.z <= mapblock_size then
				
				if player_name == pocket_data.owner or minetest.check_player_privs(player_name, "server") then
					pocket_data.destination = vector.round(pos_diff)
					save_data()
					minetest.chat_send_player(player_name, S("The entry point for pocket dimension @1 has been updated", pocket_data.name))
				else
					minetest.chat_send_player(player_name, S("You don't have permission to change the entry point of pocket dimension @1.", pocket_data.name))
				end				
				return
			end
		end
		minetest.chat_send_player(player_name, S("You're not inside a pocket dimension right now."))
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
		-- Find the pocket the player's in
		for hash, pocket_data in pairs(pockets_by_hash) do
			local pos_diff = vector.subtract(pos, pocket_data.minp)
			if pos_diff.y >=0 and pos_diff.y <= mapblock_size and -- check y first to eliminate possibility player's not in a pocket dimension at all
				pos_diff.x >=0 and pos_diff.x <= mapblock_size and
				pos_diff.z >=0 and pos_diff.z <= mapblock_size then
				
				if player_name == pocket_data.owner or minetest.check_player_privs(player_name, "server") then
					if pockets_by_name[string.lower(param)] then
						minetest.chat_send_player(player_name, S("A pocket dimension with that name already exists"))
					else
						minetest.chat_send_player(player_name, S("The name of pocket dimension @1 has been changed to \"@2\".", pocket_data.name, param))
						pockets_by_name[string.lower(pocket_data.name)] = nil
						pockets_by_name[string.lower(param)] = pocket_data
						pocket_data.name = param
						save_data()
					end
				else
					minetest.chat_send_player(player_name, S("You don't have permission to change the name of pocket dimension @1.", pocket_data.name))
				end
				return
			end
		end
		minetest.chat_send_player(player_name, S("You're not inside a pocket dimension right now."))
	end,
})


minetest.register_chatcommand("pocket_name", {
	params = "",
--	privs = {}, -- TODO a new privilege here?
	description = S("Finds the name of the pocket dimension you're inside right now."),
	func = function(player_name, param)
		local pos = minetest.get_player_by_name(player_name):get_pos()
		-- Find the pocket the player's in
		for hash, pocket_data in pairs(pockets_by_hash) do
			local pos_diff = vector.subtract(pos, pocket_data.minp)
			if pos_diff.y >=0 and pos_diff.y <= mapblock_size and -- check y first to eliminate possibility player's not in a pocket dimension at all
				pos_diff.x >=0 and pos_diff.x <= mapblock_size and
				pos_diff.z >=0 and pos_diff.z <= mapblock_size then
				
				minetest.chat_send_player(player_name, S("You're inside pocket dimension \"@1\"", pocket_data.name))
				return
			end
		end
		minetest.chat_send_player(player_name, S("You're not inside a pocket dimension right now."))
	end,
})