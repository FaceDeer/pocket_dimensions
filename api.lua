local S = minetest.get_translator(minetest.get_current_modname())

local personal_pockets_chat_command = minetest.settings:get_bool("pocket_dimensions_personal_pockets_chat_command", false)
local personal_pockets_key = minetest.settings:get_bool("pocket_dimensions_personal_pockets_key", false)
local personal_pockets_key_uses = tonumber(minetest.settings:get("pocket_dimensions_personal_pockets_key_uses")) or 0
local personal_pockets_spawn = minetest.settings:get_bool("pocket_dimensions_personal_pockets_spawn", false)
local personal_pockets_respawn = minetest.settings:get_bool("pocket_dimensions_personal_pockets_respawn", false) and not minetest.settings:get_bool("engine_spawn")
local personal_pockets_enabled = personal_pockets_chat_command or personal_pockets_key or personal_pockets_spawn or personal_pockets_respawn


-- pocket data tables have the following properties:
-- pending = true -- pocket is being initialized, don't teleport there just yet
-- destination = a vector relative to the pocket's minp that is where new arrivals teleport to
-- name = a name for the pocket.
-- owner = if set, this pocket is "owned" by this particular player.
-- protected = if true, this pocket is protected and only the owner can modify its contents
-- minp = the lower corner of the pocket's region
-- last_accessed = the gametime when this pocket was last accessed (minetest.get_gametime())

local pockets_by_name = {}
local border_types_by_name = {}
local player_origin = {}
local pockets_deleted = {} -- record deleted pockets for possible later undeletion, indexed by hash
local personal_pockets = {} -- to be filled out if personal pockets are enabled
local protected_areas = AreaStore()

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

pocket_dimensions.pocket_size = mapblock_size
local pocket_size = pocket_dimensions.pocket_size

--------------------------------------------------------------------------------------
-- Loading and saving data
local filename = minetest.get_worldpath() .. "/pocket_dimensions_data.lua"

local load_data = function()
	local f, e = loadfile(filename)
	if f then
		local data = f()
		pockets_by_name = data.pockets_by_name
		player_origin = data.player_origin
		pockets_deleted = data.pockets_deleted
		if personal_pockets_enabled then
			for name, pocket_data in pairs(pockets_by_name) do
				if pocket_data.personal and pocket_data.owner then
					if personal_pockets[pocket_data.owner] then
						minetest.log("error", "[pocket_dimensions] "
							.. pocket_data.owner .. " owns multiple personal pockets, "
							.. personal_pockets[pocket_data.owner].name .. " and " .. pocket_data.name
							.. ".")
					end
					personal_pockets[pocket_data.owner] = pocket_data
				end
			end
		end
	else
		return
	end
	
	-- add saved protected areas
	for name, pocket_data in pairs(pockets_by_name) do
		if pocket_data.protected then
			protected_areas:insert_area(pocket_data.minp, vector.add(pocket_data.minp, mapblock_size), pocket_data.owner)
		end
	end
end

local save_data = function()
	local data = {}
	data.pockets_by_name = pockets_by_name
	data.player_origin = player_origin
	data.pockets_deleted = pockets_deleted
	local file, e = io.open(filename, "w");
	if not file then
		return error(e);
	end
	file:write(minetest.serialize(data))
	file:close()
end

pocket_dimensions.save_data = save_data

load_data()


--------------------------------------------------------------
-- protection

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

pocket_dimensions.set_protection = function(pocket_data, protection)
	pocket_data.protected = protection
	-- clear any existing protection
	local protected = protected_areas:get_areas_for_pos(pocket_data.minp)
	for id, _ in pairs(protected) do -- there should only be one result
		protected_areas:remove_area(id)
	end
	-- add protection if warranted
	if pocket_data.protected then
		protected_areas:insert_area(pocket_data.minp, vector.add(pocket_data.minp, mapblock_size), pocket_data.owner or "")
	end
	minetest.log("action", "[pocket_dimensions] Protection ownership of pocket dimension " .. pocket_data.name .. " set to " .. tostring(pocket_data.protected))
	save_data()
end

-----------------------------------------------------------------------------------------------------
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


------------------------------------------------------------------------------------------------

pocket_dimensions.get_pocket = function(pocket_name)
	return pockets_by_name[string.lower(pocket_name)]
end

pocket_dimensions.get_all_pockets = function()
	local ret = {}
	for name, def in pairs(pockets_by_name) do
		table.insert(ret, def)
	end
	return ret
end

pocket_dimensions.get_deleted_pockets = function()
	local ret = {}
	for hash, def in pairs(pockets_deleted) do
		table.insert(ret, def)
	end
	return ret
end

pocket_dimensions.pocket_containing_pos = function(pos)
	if pos == nil then return end
	for name, pocket_data in pairs(pockets_by_name) do
		local pos_diff = vector.subtract(pos, pocket_data.minp)
		if pos_diff.y >=0 and pos_diff.y <= mapblock_size and -- check y first to eliminate possibility player's not in a pocket dimension at all
			pos_diff.x >=0 and pos_diff.x <= mapblock_size and
			pos_diff.z >=0 and pos_diff.z <= mapblock_size then
			
			return pocket_data
		end
	end
end

pocket_dimensions.rename_pocket = function(old_name, new_name)
	local new_name_lower = string.lower(new_name)
	local old_name_lower = string.lower(old_name)
	if pockets_by_name[new_name_lower] or not pockets_by_name[old_name_lower] then
		return false
	end
	local pocket_data = pockets_by_name[old_name_lower]
	pockets_by_name[new_name_lower] = pocket_data
	pockets_by_name[old_name_lower] = nil
	pocket_data.name = new_name
	save_data()
	return true
end

pocket_dimensions.set_destination = function(pocket_data, destination)
	local dest = vector.round(destination)
	if not (dest.x > pocket_data.minp.x and dest.y > pocket_data.minp.y and dest.z > pocket_data.minp.z 
		and dest.x < pocket_data.minp.x + mapblock_size
		and dest.y < pocket_data.minp.y + mapblock_size
		and dest.z < pocket_data.minp.z + mapblock_size)
	then minetest.log("error",
			"[pocket_dimensions] attempting to set destination point " ..
			minetest.pos_to_string(dest) ..
			" that wasn't within pocket dimension "..
			pocket_data.name
			.. " (minp " .. minetest.pos_to_string(pocket_data.minp) .. ")")
		dest = {x=pocket_data.minp.x+2,y=pocket_data.minp.y+2,z=pocket_data.minp.z+2}
	end
	pocket_data.destination = dest
	save_data()
end

---------------------------------------------------------------------------------
-- entering and exiting

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

pocket_dimensions.teleport_player_to_pocket = function(player_name, pocket_name)
	local pocket_data = pocket_dimensions.get_pocket(pocket_name)
	if pocket_data == nil or pocket_data.pending then
		return false
	end

	local player = minetest.get_player_by_name(player_name)
	if not player_origin[player_name] then
		player_origin[player_name] = player:get_pos()
	end
	teleport_player(player, pocket_data.destination)
	pocket_data.last_accessed = minetest.get_gametime()
	save_data()
	return true
end

-- returns a place to put players if they have no origin recorded
local get_fallback_origin = function()
	local spawnpoint = minetest.setting_get_pos("static_spawnpoint")
	local count = 0
	spawnpoint = {}
	while not spawnpoint.y and count < 20 do
		local x = math.random()*1000 - 500
		local z = math.random()*1000 - 500
		local y = minetest.get_spawn_level(x,z) -- returns nil when unsuitable
		spawnpoint = {x=x,y=y,z=z}
		count = count + 1
	end
	if not spawnpoint.y then
		minetest.log("error", "[pocket_dimensions] Unable to find a fallback origin point to teleport the player, to sending them to 0,0,0")
		return {x=0,y=0,z=0}
	end
	return spawnpoint
end

pocket_dimensions.return_player_to_origin = function(player_name)
	local player = minetest.get_player_by_name(player_name)
	local origin = player_origin[player_name]
	if origin then
		teleport_player(player, origin)
		player_origin[player_name] = nil
		save_data()
		return
	end
	-- If the player's lost their origin data somehow, dump them somewhere using the spawn system to find an adequate place.
	local spawnpoint = get_fallback_origin()
	minetest.log("error", "[pocket_dimensions] Somehow "..player_name.." was at "..minetest.pos_to_string(player:get_pos())..
		" inside a pocket dimension but they had no origin point recorded when they tried to leave. Sending them to "..
		minetest.pos_to_string(spawnpoint).." as a fallback.")
	teleport_player(player, spawnpoint)
end

-------------------------------------------------------------------------------------
-- pocket creation

local mapgens = {}
pocket_dimensions.register_pocket_type = function(type_name, mapgen_callback)
	mapgens[type_name] = mapgen_callback
end
pocket_dimensions.get_all_pocket_types = function()
	local ret = {}
	for name, def in pairs(mapgens) do
		table.insert(ret, name)
	end
	return ret
end

local emerge_callback = function(blockpos, action, calls_remaining, pocket_data)
	local mapgen_callback = mapgens[pocket_data.type]
	if mapgen_callback == nil then
		minetest.log("error", "[pocket_dimensions] pocket type " .. pocket_data.type .. " had no registered mapgen callback")
		return
	end
	local dest = mapgen_callback(pocket_data)
	pocket_dimensions.set_destination(pocket_data, dest)
	pocket_data.pending = nil
	save_data()
	minetest.log("action", "[pocket_dimensions] Finished initializing terrain map for pocket dimension " .. pocket_data.name)
end

pocket_dimensions.create_pocket = function(pocket_name, pocket_data_override)
	pocket_data_override = pocket_data_override or {}
	pocket_data_override.type = pocket_data_override.type or "grassy"
	if pocket_name == nil or pocket_name == "" then
		return false, S("Please provide a name for the pocket dimension")
	end

	local pocket_name_lower = string.lower(pocket_name)
	if pockets_by_name[pocket_name_lower] then
		return false, S("The name @1 is already in use.", pocket_name)
	end

	local count = 0
	while count < 100 do
		local x = math.random(0, block_grid_dimension) * mapblock_size + min_coordinate
		local z = math.random(0, block_grid_dimension) * mapblock_size + min_coordinate
		local pos = {x=x, y=layer_elevation, z=z}
		if pocket_dimensions.pocket_containing_pos(pos) == nil then
			local pocket_data = {pending=true, minp=pos, name=pocket_name}
			pockets_by_name[pocket_name_lower] = pocket_data
			for key, value in pairs(pocket_data_override) do
				pocket_data[key] = value
			end
			minetest.emerge_area(pos, pos, emerge_callback, pocket_data)
			pocket_data.last_accessed = minetest.get_gametime()
			save_data()
			minetest.log("action", "[pocket_dimensions] Created a pocket dimension named " .. pocket_name .. " at " .. minetest.pos_to_string(pos))
			return true, S("Pocket dimension @1 created", pocket_name)
		end
	end

	return false, S("Failed to find a new location for this pocket dimension.")
end

pocket_dimensions.delete_pocket = function(pocket_data, permanent)
	local pocket_name_lower = string.lower(pocket_data.name)
	local pocket_hash = minetest.hash_node_position(pocket_data.minp)
	if not permanent then
		pockets_deleted[pocket_hash] = pocket_data
	else
		-- you can permanently delete a pocket that's already been deleted
		-- this removes it from the undelete cache
		pockets_deleted[pocket_hash] = nil
	end	
	pockets_by_name[pocket_name_lower] = nil
	for name, personal_pocket_data in pairs(personal_pockets) do
		if pocket_data == personal_pocket_data then
			-- we're deleting a personal pocket, remove its record
			personal_pockets[name] = nil
			break
		end
	end
	save_data()
	
	local permanency_log = function(permanent) if permanent then return " Deletion was permanent." else return "" end end
	local permanency_message = function(permanent) if permanent then return " " .. S("Deletion was permanent.") else return "" end end
	minetest.log("action", "[pocket_dimensions] Deleted the pocket dimension " .. pocket_data.name .. " at " .. minetest.pos_to_string(pocket_data.minp).. "." .. permanency_log())
	return true, S("Deleted pocket dimension @1 at @2. Note that this doesn't affect the map, it only removes this from the pocket dimension list.", pocket_data.name, minetest.pos_to_string(pocket_data.minp)) .. permanency_message()
end

pocket_dimensions.undelete_pocket = function(pocket_data)
	local pocket_hash = minetest.hash_node_position(pocket_data.minp)
	local pocket_name_lower = string.lower(pocket_data.name)
	if pockets_by_name[pocket_name_lower] then
		return false, S("Cannot undelete, a pocket dimension with the name @1 already exists", pocket_name)
	end
	pockets_deleted[pocket_hash] = nil
	pockets_by_name[pocket_name_lower] = pocket_data
	if pocket_data.personal and pocket_data.owner and not personal_pockets[pocket_data.owner] then
		-- it was a personal pocket and the player hasn't created a new one, so restore that association
		personal_pockets[pocket_data.owner] = pocket_data
	end
	save_data()
	
	minetest.log("action", "[pocket_dimensions] Undeleted the pocket dimension " .. pocket_data.name .. " at " .. minetest.pos_to_string(pocket_data.minp))
	return true, S("Undeleted pocket dimension @1 at @2. Note that this doesn't affect the map, just moves this pocket dimension out of regular access and into the deleted list.", pocket_data.name, minetest.pos_to_string(pocket_data.minp))
end

pocket_dimensions.register_border_type = function(border_name, node_data)
	border_types_by_name[border_name] = node_data
end

pocket_dimensions.get_all_border_types = function()
	return border_types_by_name
end

pocket_dimensions.set_border = function(pocket_name, border_name)
	local pocket_data = pockets_by_name[pocket_name]
	if not pocket_data then return false end
	local border = border_types_by_name[border_name]
	if not border then return false end
	
	local c_border = minetest.get_content_id(border.name)
	local param2 = border.param2 or 0
	local minp = pocket_data.minp
	local maxp = vector.add(minp, pocket_size)
	local vm = minetest.get_voxel_manip(minp, maxp)
	local emin, emax = vm:get_emerged_area()
	local data = vm:get_data()
	local dataparam2 = vm:get_param2_data()
	local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}

	for vi, x, y, z in area:iterp_xyz(minp, maxp) do
		if x == minp.x or x == maxp.x or y == minp.y or y == maxp.y or z == minp.z or z == maxp.z then
			data[vi] = c_border
			dataparam2[vi] = param2
		end
	end
	
	vm:set_data(data)
	vm:set_param2_data(dataparam2)
	vm:write_to_map()

	return true
end

------------------------------------------------------------------

-- TODO: some cross-validation to ensure only owned pockets are personal and only one pocket is personal per player

pocket_dimensions.get_personal_pocket = function(player_name)
	return personal_pockets[player_name]
end

pocket_dimensions.set_personal_pocket = function(pocket_data, player_name)
	if pocket_data.personal and not player_name then
		-- clear personal pocket
		personal_pockets[player] = nil
		pocket_data.personal = nil
	else
		pocket_data.personal = true
		pocket_data.owner = player_name
		personal_pockets[player_name] = pocket_data
	end
	save_data()
end

pocket_dimensions.set_owner = function(pocket_data, player_name)
	pocket_data.owner = player_name
	save_data()
end
