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
local personal_pockets = {}

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
		personal_pockets = data.personal_pockets
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
		if pocket_data.protected and pocket_data.owner then
			protected_areas:insert_area(pocket_data.minp, vector.add(pocket_data.minp, mapblock_size), pocket_data.owner)
		end
	end
end

local save_data = function()
	local data = {}
	data.pockets_by_hash = pockets_by_hash
	data.player_origin = player_origin
	data.personal_pockets = personal_pockets
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
-- Various border types

local get_border_def = function(override)
	local def = {
		description = S("The boundary of a pocket dimension"),
		groups = {not_in_creative_inventory = 1},
		drawtype = "normal",  -- See "Node drawtypes"
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


minetest.register_node("pocket_dimensions:border_orange", get_border_def({tiles = {{name="pocket_dimensions_white.png", color="#ff8c00"}}}))
minetest.register_node("pocket_dimensions:border_black", get_border_def({tiles = {{name="pocket_dimensions_white.png", color="#000000"}}}))

local c_border_orange = minetest.get_content_id("pocket_dimensions:border_orange")
local c_border_black = minetest.get_content_id("pocket_dimensions:border_black")

local get_holodeck_border = function(x,y,z)
	x = x + 4
	y = y + 4
	z = z + 4
	if x%8 == 0 or y%8 == 0 or z%8 == 0 then
		return c_border_orange
	end
	return c_border_black
end

-- taken from lua_api.txt
--local default_sky_colors = {day_sky = "#8cbafa", day_horizon="#9bc1f0", dawn_sky="#b4bafa", dawn_horizon="#bac1f0", night_sky="#006aff", night_horizon="#4090ff"}

-- From midnight to midday
local sky_colors = {
	"#010103",
	"#010a18",
	"#01183a",
	"#002b69",
	"#01347b",
	"#304872",
	"#887061",
	"#886f61",
	"#c38a56",
	"#c1926a",
	"#a9a4ad",
	"#a2abc1",
	"#9ab0d2",
	"#95b4e2",
	"#91b7ef",
	"#8ebaf7",
	"#8cbbfa",
}

for i, color in ipairs(sky_colors) do
	minetest.register_node("pocket_dimensions:border_sky_" .. i, get_border_def(
	{
		tiles = {{name="pocket_dimensions_white.png", color=color}},
		-- NOTE! Only set the timer running on the node at minp. Otherwise chaos and destruction.
		on_timer = function(pos, elapsed)
			local timeofday = minetest.get_timeofday()
			--  0 for midnight, 0.5 for midday
			if timeofday < 0.5 then
				timeofday = math.ceil(timeofday * 16)
			else
				timeofday = math.ceil(math.abs(1 - timeofday) * 16)
			end
			if timeofday ~= i then
				local c_new_sky = minetest.get_content_id("pocket_dimensions:border_sky_" .. timeofday)
				local maxp = vector.add(pos, mapblock_size)
				local vm = minetest.get_voxel_manip(pos, maxp)
				local emin, emax = vm:get_emerged_area()
				local data = vm:get_data()
				local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}
				for vi, x, y, z in area:iterp_xyz(pos, maxp) do
					if x == pos.x or x == maxp.x or y == pos.y or y == maxp.y or z == pos.z or z == maxp.z then
						data[vi] = c_new_sky
					end
				end
				vm:set_data(data)
				vm:write_to_map()
			end
			minetest.get_node_timer(pos):start(30)
		end,
	}))
end

local c_border_sky = minetest.get_content_id("pocket_dimensions:border_sky_1")
local get_sky_border = function(x,y,z)
	return c_border_sky
end


minetest.register_node("pocket_dimensions:border_static", get_border_def(
	{tiles = {{name="pocket_dimensions_static.png", animation= {
			type = "vertical_frames",
			aspect_w = 16,
			aspect_h = 16,
			length = 1.0,
		},
		color="#888888"}}})
)
local c_border_static = minetest.get_content_id("pocket_dimensions:border_static")
local get_static_border= function(x,y,z)
	return c_border_static
end

minetest.register_node("pocket_dimensions:border_glass", get_border_def(
	{
		drawtype = "glasslike_framed_optional",
		tiles = {"pocket_dimensions_transparent.png"},
		paramtype2 = "glasslikeliquidlevel",
	}
))
local c_border_glass = minetest.get_content_id("pocket_dimensions:border_glass")
local get_glass_border = function(x,y,z)
	return c_border_glass
end

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
	
	minetest.get_node_timer(minp):start(5) -- sets the sky updater node running
	for vi, x, y, z in area:iterp_xyz(minp, maxp) do
		if x == minp.x or x == maxp.x or y == minp.y or y == maxp.y or z == minp.z or z == maxp.z then
			data[vi] = get_glass_border(x,y,z)
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
			pockets_by_name[string.lower(pocket_name)] = pocket_data
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
	player:set_pos(dest)
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
	drawtype = "normal",
	tiles = {"pocket_dimensions_portal_base.png","pocket_dimensions_portal_base.png","pocket_dimensions_portal.png"},
	paramtype="light",
	paramtype2="facedir",
	is_ground_content=false,
	node_box={type="regular"},

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

local get_pocket_data = function(player_name, pocket_name)
	if pocket_name == "" or pocket_name == nil then
		minetest.chat_send_player(player_name, S("Please provide a name for the pocket dimension"))
		return
	end
	local pocket_data = pockets_by_name[string.lower(pocket_name)]
	if pocket_data == nil then
		minetest.chat_send_player(player_name, S("Pocket dimension doesn't exist"))
		return
	end
	if pocket_data.pending then
		minetest.chat_send_player(player_name, S("Pocket dimension not yet initialized"))
		return
	end
	return pocket_data
end

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

minetest.register_chatcommand("pocket_delete", {
	params = "pocketname",
	privs = {server = true},
	description = S("Delete a pocket dimension. Note that this does not affect the map, it only removes the dimension's location from pocket_dimension's records."),
	func = function(name, param)
		local pocket_data = get_pocket_data(name, param)
		if pocket_data == nil then
			return
		end
		
		pockets_by_name[string.lower(param)] = nil
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
		pockets_by_name[string.lower(pocket_name)] = pocket_data
		pockets_by_hash[minetest.hash_node_position(pocket_pos)] = pocket_data
		minetest.chat_send_player(name, S("Undeleted pocket dimension."))
		minetest.log("action", "[pocket_dimensions] " .. name .. " undeleted the pocket dimension " .. pocket_name .. " at " .. minetest.pos_to_string(pocket_pos))
		save_data()
	end,
})

-------------------------------------------------------------------------------------------------------

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
		.."]table[0.5,1.0;7,6;pocket_table;"
	
	local i = 0
	for name, dimension_data in pairs(pockets_by_name) do
		i = i + 1
		if i == state.row_index then
			state.selected_data = dimension_data
		end
		local owner = dimension_data.owner or "<none>"
		local protected = dimension_data.protected
		formspec[#formspec+1] = minetest.formspec_escape(dimension_data.name)
			..",".. minetest.formspec_escape(owner)
			..","..tostring(protected)
		formspec[#formspec+1] = ","
	end
	formspec[#formspec] = ";"..state.row_index.."]" -- don't use +1, this overwrites the last ","
	
	if state.selected_data then
	formspec[#formspec+1] = "container[0.5,7.25]"
		.."field[0.0,0.0;6,0.5;pocket_name;;" .. minetest.formspec_escape(state.selected_data.name) .."]"
		.."button[0,0.5;3,0.5;rename;"..S("Rename").."]"
		.."button[3.5,0.5;3,0.5;create;"..S("Create").."]"
		.."button[0,1;3,0.5;teleport;"..S("Teleport To").."]"
		.."button[3.5,1;3,0.5;protect;"..S("Toggle Protect").."]"
		.."field[0.0,1.5;3,0.5;owner;;".. minetest.formspec_escape(state.selected_data.owner or "").."]"
		.."button[3.5,1.5;3,0.5;set_owner;"..S("Set Owner").."]"
		.."container_end[]"
	end
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
	
	if fields.create then
		if create_new_pocket(fields.pocket_name, player_name) then
			refresh = true
		end
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
		minetest.chat_send_player(player_name, S("Teleport to personal pocket dimension failed after @1 tries.", count))
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
				minetest.chat_send_player(player_name, S("You need to give your personal pocket dimension a name. Use /pocket_personal pocketname"))
				return
			end

			pocket_data = create_new_pocket(param, player_name, player_name)
			if pocket_data then
				personal_pockets[player_name] = pocket_data
				teleport_to_pending(param, player_name, 1)
			end
		end,
	})
end



-----------------------------------------------------------------
