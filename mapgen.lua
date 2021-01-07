local S = minetest.get_translator(minetest.get_current_modname())

local default_modpath = minetest.get_modpath("default")
local mcl_core_modpath = minetest.get_modpath("mcl_core")

local pocket_size = pocket_dimensions.pocket_size
local register_pocket_type = pocket_dimensions.register_pocket_type
local return_player_to_origin = pocket_dimensions.return_player_to_origin

local c_air = minetest.get_content_id("air")

local c_dirt
local c_dirt_with_grass
local c_stone
local c_water
local c_sand

if default_modpath then
	c_dirt = minetest.get_content_id("default:dirt")
	c_dirt_with_grass = minetest.get_content_id("default:dirt_with_grass")
	c_stone = minetest.get_content_id("default:stone")
	c_water = minetest.get_content_id("default:water_source")
	c_sand = minetest.get_content_id("default:sand")
elseif mcl_core_modpath then
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
		groups = {not_in_creative_inventory = 1, dimensional_boundary = 1},
		is_ground_content = false, -- If false, the cave generator and dungeon generator will not carve through this node.
		diggable = false,  -- If false, can never be dug
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


-----------------------------------------------------------------------------------------------------

minetest.register_node("pocket_dimensions:border_collapsing", get_border_def({
	light_source = minetest.LIGHT_MAX,
	paramtype = "light",
	tiles = {{name="pocket_dimensions_pit_plasma.png",
	    animation = {
			type = "vertical_frames",
			aspect_w = 32,
			aspect_h = 32,
			length = 1.0,
		},
		tileable_vertical=true,
		tileable_horizontal=true,
		align_style="world",
		scale=2,
	}},
	damage_per_second = 100,
}))

local c_border_collapsing = minetest.get_content_id("pocket_dimensions:border_collapsing")

function collapse_pocket(pocket_data)
	local collapse = pocket_data.collapse
	if not collapse then
		return
	end
	local tick = collapse.tick
	if tick >= pocket_size/2 then
		-- done
		minetest.delete_area(pocket_data.minp, vector.add(pocket_data.minp, pocket_size))
		pocket_dimensions.delete_pocket(pocket_data, true)
		return
	end
	local minp = vector.add(pocket_data.minp, tick)
	local maxp = vector.add(minp, pocket_size-tick*2)
	local vm = minetest.get_voxel_manip(minp, maxp)
	local emin, emax = vm:get_emerged_area()
	local data = vm:get_data()
	local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}
	for vi, x, y, z in area:iterp_xyz(minp, maxp) do
		if x == minp.x or x == maxp.x or y == minp.y or y == maxp.y or z == minp.z or z == maxp.z then
			data[vi] = c_border_collapsing
		end
	end
	vm:set_data(data)
	vm:write_to_map()

	collapse.tick = tick + 1
	pocket_dimensions.save_data()
	minetest.after(collapse.seconds_per_tick, collapse_pocket, pocket_data)
end

local destroy_pocket_dramatically = function(pocket_data, seconds_per_tick)
	pocket_data.collapse = {seconds_per_tick = seconds_per_tick, tick = 0}
	pocket_dimensions.save_data()
	collapse_pocket(pocket_data)
end

minetest.register_chatcommand("pocket_destroy", {
	params = "pocketname",
	privs = {server=true},
	description = S("Destroy a named pocket dramatically"),
	func = function(player_name, param)
		local pocket_data = pocket_dimensions.get_pocket(param)
		if not pocket_data then
			minetest.chat_send_player(player_name, S("Unable to find a pocket dimension with that name."))
			return
		end
		destroy_pocket_dramatically(pocket_data, 10)
	end
})

local test_collapse = function()
	for _, def in pairs(pocket_dimensions.get_all_pockets()) do
		if def.collapse then
			collapse_pocket(def)
		end
	end
end

minetest.after(1, test_collapse)
