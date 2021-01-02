pocket_dimensions = {}
local S = minetest.get_translator(minetest.get_current_modname())
local MP = minetest.get_modpath(minetest.get_current_modname())
dofile(MP.."/voxelarea_iterator.lua")


local mapgen_chunksize = tonumber(minetest.get_mapgen_setting("chunksize"))
local mapblock_size = mapgen_chunksize * 16 -- should be 80 in almost all cases, but avoiding hardcoding it for extensibility
local block_grid_dimension = math.floor(61840 / mapblock_size) -- should be 773
local max_pockets = block_grid_dimension * block_grid_dimension

--The world is a cube of side length 61840. Coordinates go from −30912 to 30927 in any direction.
--The side length is a multiple of 80, an important number in Minetest.
--773 * 80 = 61840
-- so there are 773 * 773 = 597529 chunk in a horizontal layer

local layer_elevation = tonumber(minetest.settings:get("pocket_dimensions_altitude")) or 30000
layer_elevation = math.floor(layer_elevation / mapblock_size) * mapblock_size - 32 -- round to mapblock boundary


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

-- pocket data tables have the following properties:
-- pending = true -- pocket is being initialized, don't teleport there just yet
-- destination = a vector relative to the pocket's minp that is where new arrivals teleport tonumber
-- name = a name for the pocket.
-- owner = if set, this pocket is "owned" by this particular player.
-- protected = if true, this pocket is protected and only the owner can modify its contents

local pockets_by_hash = {}
local pockets_by_name = {}
local player_origin = {}

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
		data = f()
		pockets_by_hash = data.pockets_by_hash
		pockets_by_name = data.pockets_by_name
		player_origin = data.player_origin
	end
	
	-- validate and add saved protected areas
	local count_hash = 0
	local count_name = 0
	for hash, pocket_data in pairs(pockets_by_hash) do
		count_hash = count_hash + 1
		if hash ~= minetest.hash_node_position(pocket_data.minp) then
			minetest.log("error", "[pocket_dimensions] Hash mismatch for " .. tostring(hash) .. ", " .. dump(pocket_data))
		end
		
		if pocket_data.protected and pocket_data.owner then
			protected_areas:insert_area(pocket_data.minp, vector.add(pocket_data.minp, mapblock_size), pocket_data.owner)
		end
	end
	for name, pocket_data in pairs(pockets_by_name) do
		count_name = count_name + 1
		if name ~= pocket_data.name then
			minetest.log("error", "[pocket_dimensions] Name mismatch for " .. name .. ", " .. dump(pocket_data))
		end
	end
	if count_hash ~= count_name then
		minetest.log("error", "[pocket_dimensions] name/hash count mismatch.")
	end
end

local save_data = function()
	local data = {}
	data.pockets_by_hash = pockets_by_hash
	data.pockets_by_name = pockets_by_name
	data.player_origin = player_origin
	local file, e = io.open(filename, "w");
	if not file then
		return error(e);
	end
	file:write(minetest.serialize(data))
	file:close()
end

load_data()
----------------------------------------------------------------------------------------

local index_to_minp = function(index)
	assert(index >=0 and index < max_pockets, "index out of bounds")
	local x = math.floor(index / block_grid_dimension) * mapblock_size - 30912
	local z = (index % block_grid_dimension) * mapblock_size - 30912
	return {x=x, y=layer_elevation, z=z}
end

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

---------------------------------------------------------------
-- For simple terrain inside new pocket dimensions

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
    --flags = "defaults",
}

local perlin_noise = PerlinNoise(perlin_params)

-----------------------------------------------------------------------

minetest.register_node("pocket_dimensions:border", {
    description = S("The boundary of a pocket dimension"),
    groups = {not_in_creative_inventory = 1},
    drawtype = "normal",  -- See "Node drawtypes"
    tiles = {{
		name="pocket_dimensions_cloudy_seamless.png",
		animation = {
			type = "vertical_frames",
			aspect_w = 128,
			aspect_h = 128,
			length = 10.0,
		},
		tileable_vertical=true,
		tileable_horizontal=true,
		align_style="world",
		scale=8,
	}},
	light_source = 4,
    paramtype = "light",  -- See "Nodes"
    paramtype2 = "none",  -- See "Nodes"
    is_ground_content = false, -- If false, the cave generator and dungeon generator will not carve through this node.
    sunlight_propagates = true, -- If true, sunlight will go infinitely through this node
    walkable = true,  -- If true, objects collide with node
    pointable = true,  -- If true, can be pointed at
    diggable = false,  -- If false, can never be dug
    node_box = {type="regular"},  -- See "Node boxes"
    --sounds = 
    can_dig = function(pos, player) return false end,
    on_blast = function(pos, intensity) return false end,
	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		local clicker_pos = clicker:get_pos()
		if vector.distance(pos, clicker_pos) > 2 then
			return
		end
		local name = clicker:get_player_name()
		local origin = player_origin[name]
		if origin then
			clicker:set_pos(origin)
			player_origin[name] = nil
			save_data()
		end
	end,
})

local c_border = minetest.get_content_id("pocket_dimensions:border")

--------------------------------------------------------------------------------------------------

-- TODO don't know why minetest.get_perlin_map isn't working here
local terrain_map = PerlinNoiseMap(
	perlin_params,
	{x=mapblock_size, y=mapblock_size, z=mapblock_size}
)

-- Once the map block for the new pocket dimension is loaded, this initializes its node layout and finds a spot for arrivals to teleport to
local emerge_callback = function(blockpos, action, calls_remaining, pocket_data)
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
	local rock = minp.y + 38
	local terrain_values = terrain_map:get_2d_map(minp)
	
	-- Default is down on the floor of the border walls, in case default mod isn't installed and no landscape is created
	local middlep = {x=minp.x+math.floor(mapblock_size/2), y=minp.y+2, z=minp.z+math.floor(mapblock_size/2)}
	
	for vi, x, y, z in area:iterp_xyz(minp, maxp) do
		if x == minp.x or x == maxp.x or y == minp.y or y == maxp.y or z == minp.z or z == maxp.z then
			data[vi] = c_border
		elseif default_modpath then
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
	minetest.log("action", "[pocket_dimensions] Finished initializing map for pocket dimension " .. pocket_data.name)
end

local create_new_pocket = function(pocket_name, player_name, set_as_owner)
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
		local index = math.random(0, max_pockets)
		local pos = index_to_minp(index)
		local hash = minetest.hash_node_position(pos)
		if pockets_by_hash[hash] == nil then
			local pocket_data = {pending=true, minp=pos, name=pocket_name}
			pockets_by_hash[hash] = pocket_data
			pockets_by_name[pocket_name] = pocket_data
			if set_as_owner then
				pocket_data.owner = set_as_owner
			end
			minetest.emerge_area(pos, pos, emerge_callback, pocket_data)
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
	local pocket_data = pockets_by_name[pocket_name]
	if pocket_data == nil then
		return false
	end

	local dest = vector.add(pocket_data.minp, pocket_data.destination)
	player = minetest.get_player_by_name(player_name)
	if not player_origin[player_name] then
		player_origin[player_name] = player:get_pos()
		save_data()
	end
	player:set_pos(dest)
	return true
end


-------------------------------------------------------------------------------

minetest.register_node("pocket_dimensions:portal", {
    description = S("Pocket Dimension Access"),
    groups = {oddly_breakable_by_hand = 1},
	drawtype = "normal",
	tiles = {"something.png"},
	paramtype="light",
	paramtype2="facedir",
	is_ground_content=false,
	node_box={type="regular"},
	on_construct = function(pos)
		local meta = minetest.get_meta(pos)
		meta:set_string("formspec", "field[text;;${text}]")
	end,
	on_receive_fields = function(pos, formname, fields, sender)
		local player_name = sender:get_player_name()
		if minetest.is_protected(pos, player_name) then
			minetest.record_protection_violation(pos, player_name)
			return
		end
		local text = fields.text
		if not text then
			return
		end

		local pocket_data = pockets_by_name[text]
		if pocket_data == nil then
			create_new_pocket(text, player_name)
		end
		
		local meta = minetest.get_meta(pos)
		meta:set_string("pocket_name", text)
		meta:set_string("formspec", "")
		meta:set_string("infotext", S("Teleporter to pocket dimension\n@1", text))
	end,

	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		local meta = minetest.get_meta(pos)
		local pocket_name = meta:get_string("pocket_name")
		if pocket_name then
			teleport_player_to_pocket(clicker:get_player_name(), pocket_name)
		end	
	end,
})


-------------------------------------------------------------------------------
-- Admin commands


local get_pocket_data = function(player_name, pocket_name)
	if pocket_name == "" or pocket_name == nil then
		minetest.chat_send_player(player_name, S("Please provide a name for the pocket dimension"))
		return
	end
	local pocket_data = pockets_by_name[pocket_name]
	if pocket_data == nil then
		minetest.chat_send_player(player_name, S("Pocket dimension doesn't exist"))
		return
	end
	if pocket_data.pending then
		minetest.chat_send_player(name, S("Pocket dimension not yet initialized"))
		return
	end
	return pocket_data
end

minetest.register_chatcommand("pocket_teleport", {
	params = "pocketname",
	privs = {server=true},
	description = S("Teleport to a pocket dimension, if it exists."),
	func = function(name, param)
		local pocket_data = get_pocket_data(name, param)
		if pocket_data then
			teleport_player_to_pocket(player_name, pocket_name)
		end
	end,
})

minetest.register_chatcommand("pocket_create", {
	params = "pocketname",
	privs = {server=true},
	description = S("Create a pocket dimension."),
	func = function(name, param)
		create_new_pocket(param, name)
	end,
})


local update_protected = function(pocket_data)
	-- clear any existing protection
	protected = protected_areas:get_areas_for_pos(pocket_data.minp)
	for id, _ in pairs(protected) do
		protected_areas:remove_area(id)
	end
	-- add protection if warranted
	if pocket_data.protected and pocket_data.owner then
		protected_areas:insert_area(pocket_data.minp, vector.add(pocket_data.minp, mapblock_size), pocket_data.owner)
	end
end

-- TODO doesn't handle pocket names with spaces
minetest.register_chatcommand("pocket_set_owner", {
	params = "pocketname [ownername]",
	privs = {server=true},
	description = S("Set the ownership of a pocket dimension."),
	func = function(name, param)
		param = param:split(" ")
		if #param < 1 or #param > 2 then
			minetest.chat_send_player(name, S("Incorrect parameter count"))
			return
		end
		
		local pocket_name = param[1]
		local player_name = param[2] -- can be nil
		local pocket_data = get_pocket_data(name, pocket_name)
		if pocket_data == nil then
			return
		end
		pocket_data.owner = player_name
		update_protected(pocket_data)		
		minetest.log("action", "[pocket_dimensions] " .. name .. " changed ownership of pocket dimension " .. pocket_name .. " from " .. tostring(pocket_data.owner).. " to " .. tostring(player_name))
		save_data()
	end,
})

minetest.register_chatcommand("pocket_protect", {
	params = "pocketname",
	privs = {server=true},
	description = S("Toggles whether a pocket is protected (only has an effect if the pocket also has an owner)."),
	func = function(name, param)
		local pocket_data = get_pocket_data(name, param)
		if pocket_data == nil then
			return
		end		
		pocket_data.protected = not pocket_data.protected
		update_protected(pocket_data)
		minetest.log("action", "[pocket_dimensions] " .. name .. " set protection ownership of pocket dimension " .. param .. " to " .. tostring(pocket_data.protected))
		save_data()
	end,
})

minetest.register_chatcommand("pocket_delete", {
	params = "pocketname",
	privs = {server = true},
	description = S("Delete a pocket dimension. Note that this does not affect the map, it only removes the dimension's location from pocket_dimension's records."),
	func = function(name, param)
		local pocket_data = get_pocket_data(name, param)
		if pocket_data == nil then
			return
		end
		
		pockets_by_name[param] = nil
		pockets_by_hash[minetest.hash_node_position(pocket_data.minp)] = nil
		minetest.chat_send_player(name, S("Deleted pocket dimension " .. param .. " at " .. minetest.pos_to_string(pocket_data.minp)))
		minetest.log("action", "[pocket_dimensions] " .. name .. " deleted the pocket dimension " .. param .. " at " .. minetest.pos_to_string(pocket_data.minp))
		save_data()
	end,
})

minetest.register_chatcommand("pocket_undelete", {
	params = "pocketname (x,y,z)",
	privs = {server = true},
	description = S("Restore a deleted pocket dimension. Be certain to get the coordinates exactly right, no checking is done to ensure the map is correctly configured."),
	func = function(name, param)
		local param = param:split(" ")
		if #param ~= 2 then
			minetest.chat_send_player(name, S("Incorrect number of parameters"))
			return
		end
		local pocket_name = param[1]
		local pocket_pos = minetest.string_to_pos(param[2])
		if pocket_name == nil or pocket_pos == nil then
			minetest.chat_send_player(name, S("Unable to parse parameters"))
			return
		end
		local pocket_data = {name = pocket_name, minp = pocket_pos, destination = {x=mapblock_size/2, y=mapblock_size/2, z=mapblock_size/2}}
		pockets_by_name[pocket_name] = pocket_data
		pockets_by_hash[minetest.hash_node_position(pocket_pos)] = pocket_data
		minetest.chat_send_player(name, S("Undeleted pocket dimension."))
		minetest.log("action", "[pocket_dimensions] " .. name .. " undeleted the pocket dimension " .. pocket_name .. " at " .. minetest.pos_to_string(pocket_pos))
		save_data()
	end,
})

minetest.register_chatcommand("pocket_list", {
	params = "",
	privs = {server=true},
	description = S("List all pocket dimensions"),
	func = function(player_name, param)
		for name, pocket_data in pairs(pockets_by_name) do
			minetest.chat_send_player(player_name, name .. ": owned by " .. tostring(pocket_data.owner) .. ", protected: " .. tostring(pocket_data.protected))
		end
	end,
})



-----------------------------------------------------------------
