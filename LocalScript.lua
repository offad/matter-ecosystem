-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Library
local Matter = require(ReplicatedStorage.Matter) -- Load the Matter ECS library

-- Constants:

-- Define -MAP_HALF to +MAP_HALF on X/Z
local MAP_HALF = 150 -- Defines the playable area boundarie

-- Define default stats for entities
local MAX_HEALTH = 100
local DEFAULT_FOOD = 40
local MAX_SPEED = 20

-- Define initial population counts
local START_PLANT = 25
local START_HERBIVORE = 10
local START_CARNIVORE = 4

-- Define passive food gain/loss per second (plants gain, animals lose)
local FOOD_TICK_PLANT = 2 -- passive gain (per second)
local FOOD_TICK_HERBIVORE = -3
local FOOD_TICK_CARNIVORE = -5

-- Define health regen rates
local HEALTH_TICK_WHEN_STARVING = -20.0 -- regen when food <= 0
local HEALTH_TICK_WHEN_FED = 10.0 -- regen when food > 0

-- Try to keep food around
local PLANT_RESPAWN_PER_SEC = 6 -- how many plants to try to respawn per second

local FOOD_TO_REPRODUCE = 100 -- how much food to spend to reproduce

local CHILDREN_MIN, CHILDREN_MAX = 2, 3 -- how many kids per reproduction
local DIMINISH_AFTER_EACH_MEAL = 0.9 -- how much food is retained by eating (the rest is wasted energy in transfer)

-- Interaction distances
local SENSE_RADIUS = 50 -- how far creatures can "see" to find food/prey
local EAT_RADIUS = 3 -- how close to count as "eaten"
-- Boids parameters
local SEPARATION_RADIUS = 4 -- push away when too close
local SEPARATION_FORCE = 120 -- strength of separation force
local BOUNDS_PADDING = 4 -- how close to edge before applying force
local BOUNDS_FORCE = 200 -- strength of bounds force

-- Variables:

-- Create world container
local container = Instance.new("Folder")
container.Name = "World"
container.Parent = game.Workspace -- put the folder in the Workspace

-- Define components
local Part = Matter.component() -- create component to manage the visual Part
local Health = Matter.component() -- create component to manage health
local Food = Matter.component() -- create component to manage food
local Transform = Matter.component() -- create component to manage position
local Velocity = Matter.component() -- create component to manage velocity
local Target = Matter.component() -- create component to manage target entity
local Plant = Matter.component() -- component to tag plants
local Herbivore = Matter.component() -- component to tag herbivores
local Carnivore = Matter.component() -- component to tag carnivores

-- Create world
local world = Matter.World.new() -- This creates a new ECS world.
local loop = Matter.Loop.new(world) -- This makes Loop pass the world to all your systems.

-- Private functions:

-- Clamp vector magnitude to max number m
local function clampMag(v: Vector3, m: number)
	local mag = v.Magnitude -- current magnitude
	if mag > m then
		return v.Unit * m -- return clamped
	end
	return v
end

-- Random number between a and b
local function rnd(a: number, b: number)
	return a + math.random() * (b - a)
end

-- Generate random spawn position within map bounds
local function randomSpawnInMap()
	return Vector3.new(rnd(-MAP_HALF, MAP_HALF), 2, rnd(-MAP_HALF, MAP_HALF))
end

-- Create a visual part
local function makePart(size: Vector3, color: Color3): BasePart
	local p = Instance.new("Part") -- create a new Part
	p.Shape = Enum.PartType.Ball -- make it a sphere
	-- Set properties
	p.Anchored = true
	p.CanCollide = false
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

-- Spawn an entity
local function spawnEntity(position: Vector3, component, color: Color3, size: Vector3, foodRegen: number)
	-- Create part
	local part = makePart(size, color)

	-- Spawn in world
	local id = world:spawn(
		component(), -- tag component
		Part({
			part = part, -- reference to the visual part
		}),
		Health({
			value = MAX_HEALTH, -- start with full health
		}),
		Food({
			value = DEFAULT_FOOD, -- start with default food
			regen = foodRegen, -- passive food regen rate
		}),
		Transform({
			position = position, -- start position
		}),
		Velocity({
			value = Vector3.zero, -- start stationary
		}),
		Target({
			value = nil, -- no target initially
		})
	)

	-- Add part
	part:SetAttribute("entityId", id)
	part.Parent = container
	return id
end

-- Spawn plant
local function spawnPlant(pos)
	return spawnEntity(
		pos or randomSpawnInMap(),
		Plant, -- tag as plant
		Color3.fromRGB(80, 220, 120), -- greenish
		Vector3.new(1.8, 1.8, 1.8), -- small size
		FOOD_TICK_PLANT -- passive food regen
	)
end

-- Spawn herbivore
local function spawnHerbivore(pos)
	return spawnEntity(
		pos or randomSpawnInMap(),
		Herbivore, -- tag as herbivore
		Color3.fromRGB(255, 220, 0), -- yellowish
		Vector3.new(2.2, 2.2, 2.2), -- medium size
		FOOD_TICK_HERBIVORE -- passive food loss
	)
end

-- Spawn carnivore
local function spawnCarnivore(pos)
	return spawnEntity(
		pos or randomSpawnInMap(),
		Carnivore, -- tag as carnivore
		Color3.fromRGB(230, 70, 70), -- reddish
		Vector3.new(2.6, 2.6, 2.6), -- larger
		FOOD_TICK_CARNIVORE -- passive food loss
	)
end

-- Spawn nitial populations
for _ = 1, START_PLANT do -- loop from 1 to the initial number of plants
	spawnPlant() -- spawn plant
end
for _ = 1, START_HERBIVORE do -- loop from 1 to the initial number of herbivores
	spawnHerbivore() -- spawn herbivore
end
for _ = 1, START_CARNIVORE do -- loop from 1 to the initial number of carnivores
	spawnCarnivore() -- spawn carnivore
end

-- Define systems
local systems = {}

-- We update all arrays every frame:

-- 1) Passive food & health regeneration
local function regenEntity(world)
	-- Get deltaTime
	local deltaTime = Matter.useDeltaTime()

	-- Check food and health
	for id, health, food, part in world:query(Health, Food, Part) do -- for each entity with Health, Food, and Part components
		-- Passive food change
		local regen = food.regen or 0
		world:insert(
			id,
			food:patch({
				value = food.value + regen * deltaTime, -- passive food change
			})
		)

		-- Starvation & regen
		if food.value <= 0 then
			-- Starving: lose health
			health = health:patch({
				value = health.value + (HEALTH_TICK_WHEN_STARVING * deltaTime),
			})
		else
			-- Fed: gain health
			health = health:patch({
				value = health.value + (HEALTH_TICK_WHEN_FED * deltaTime),
			})
		end
		-- Clamp health
		health = health:patch({
			value = math.clamp(health.value, 0, MAX_HEALTH),
		})
		-- Update health
		world:insert(id, health)

		-- Die if no health
		if health.value <= 0 then
			part.part:Destroy()
			world:despawn(id)
		end
	end
end
table.insert(systems, regenEntity) -- add the regenEntity system to the systems array

-- Find nearest target index (linear scan; fine for small sims)
local function findNearest(position: Vector3, world, component, radius: number): number?
	local best, bestDistSq = nil, radius * radius
	-- Find nearest
	for id, _, health, transform in world:query(component, Health, Transform) do -- for each entity with the specified component, Health, and Transform
		if health.value > 0 then
			-- Calculate squared distance
			local d = (transform.position - position)
			local dsq = d.X * d.X + d.Z * d.Z -- ignore Y
			-- Check if best
			if dsq < bestDistSq then
				-- New best
				bestDistSq = dsq
				best = id
			end
		end
	end
	return best
end

-- 2) Define target
local function findTarget()
	-- Find herbivore targets
	for id, _, transform, target in world:query(Herbivore, Transform, Target) do -- for each herbivore with Transform and Target components
		-- Target selection
		local targetId = findNearest(transform.position, world, Plant, SENSE_RADIUS)

		-- Update target
		world:insert(
			id,
			target:patch({
				value = targetId, -- set target to nearest plant
			})
		)
	end

	-- Find carnivore targets
	for id, part, transform, target in world:query(Carnivore, Transform, Target) do -- for each carnivore with Transform and Target components
		-- Target selection
		local targetId = findNearest(transform.position, world, Herbivore, SENSE_RADIUS)

		-- Update target
		world:insert(
			id,
			target:patch({
				value = targetId, -- set target to nearest herbivore
			})
		)
	end
end
table.insert(systems, findTarget) -- add the findTarget system to the systems array

-- Separation steering
local function separation(world, id, component): Vector3
	local acc = Vector3.zero -- accumulated separation force
	local transform = world:get(id, Transform) -- get the Transform component of the entity with the given id
	local myPos = transform.position -- get the position of the entity

	-- Check nearby same-type entities
	for entityId, _, entityTransform in world:query(component, Transform) do -- for each entity with the specified component and Transform
		if id ~= entityId then -- ignore self
			-- Calculate offset
			local offset = myPos - entityTransform.position
			local dist = math.max(0.001, Vector3.new(offset.X, 0, offset.Z).Magnitude)
			if dist < SEPARATION_RADIUS then -- Check if within separation radius
				acc += (offset / dist) -- push away
			end
		end
	end

	-- Return force
	return acc * SEPARATION_FORCE
end

-- Keep inside square map (soft force)
local function keepInBounds(transform): Vector3
	-- Get position
	local p = transform.position
	-- Determine x and z force direction depending on position
	local fx, fz = 0, 0
	if p.X > MAP_HALF - BOUNDS_PADDING then -- Check if past the right edge
		fx = fx - 1 -- apply leftward force
	end
	if p.X < -MAP_HALF + BOUNDS_PADDING then -- Check if past the left edge
		fx = fx + 1 -- apply rightward force
	end
	if p.Z > MAP_HALF - BOUNDS_PADDING then -- Check if past the top edge
		fz = fz - 1 -- apply downward force
	end
	if p.Z < -MAP_HALF + BOUNDS_PADDING then -- Check if past the bottom edge
		fz = fz + 1 -- apply upward force
	end
	if fx == 0 and fz == 0 then
		return Vector3.zero
	end
	-- Return force
	return Vector3.new(fx, 0, fz).Unit * BOUNDS_FORCE
end

-- 3) Steering & movement (boids for consumers/hunters)
local function moveEntity(world)
	-- Get deltaTime
	local deltaTime = Matter.useDeltaTime()

	-- Update transform
	for id, transform, velocity, target in world:query(Transform, Velocity, Target) do -- for each entity with Transform, Velocity, and Target components
		-- Define force
		local force = Vector3.zero

		-- Seek force
		local targetId = target.value
		if targetId and world:contains(targetId) then -- check if target is valid
			-- Get target transform
			local targetTransform = world:get(targetId, Transform)
			-- Calculate desired velocity
			local desired = (targetTransform.position - transform.position)
			desired = Vector3.new(desired.X, 0, desired.Z)
			if desired.Magnitude > 0 then
				desired = desired.Unit * MAX_SPEED
				local steer = desired - velocity.value
				force += clampMag(steer, MAX_SPEED)
			end
		end

		-- Separation
		if world:get(id, Carnivore) then -- check if entity is a carnivore
			force += separation(world, id, Carnivore) -- apply separation force from other carnivores
		elseif world:get(id, Herbivore) then -- check if entity is a herbivore
			force += separation(world, id, Herbivore) -- apply separation force from other herbivores
		else
			-- Ignore any other kind of entities
			continue
		end

		-- Keep in bounds
		force += keepInBounds(transform)

		-- Integrate
		local v = velocity.value + force * deltaTime
		v = Vector3.new(v.X, 0, v.Z) -- keep Y zero
		v = clampMag(v, MAX_SPEED) -- clamp to max speed

		-- Update velocity
		velocity = velocity:patch({
			value = v, -- new velocity
		})
		world:insert(id, velocity) -- update velocity component
		-- Update position
		world:insert(
			id,
			transform:patch({
				position = transform.position + (v * deltaTime),
			})
		)
	end
end
table.insert(systems, moveEntity) -- add the moveEntity system to the systems array

-- 4) Eat targets if close enough
local function eatTarget(world)
	-- Get deltaTime
	local deltaTime = Matter.useDeltaTime()

	-- Update transform
	for id, transform, food, target in world:query(Transform, Food, Target) do -- for each entity with Transform, Food, and Target components
		local targetId = target.value
		-- Validate target
		if not (targetId and world:contains(targetId)) then
			continue
		end

		-- Get enemy transform
		local targetTransform, targetFood, targetPart = world:get(targetId, Transform, Food, Part) -- get target components by targetId
		if (transform.position - targetTransform.position).Magnitude > EAT_RADIUS then
			continue
		end

		-- Update food
		world:insert(
			id,
			food:patch({
				-- Gain diminished food from target
				value = food.value + targetFood.value * DIMINISH_AFTER_EACH_MEAL,
			})
		)
		-- Update target
		world:insert(
			id,
			target:patch({
				value = nil,
			})
		)

		-- Remove target
		targetPart.part:Destroy()
		world:despawn(targetId)
	end
end
table.insert(systems, eatTarget) -- add the eatTarget system to the systems array

-- 5) Draw all parts
local function drawEntity(world)
	-- Update all parts positions
	for id, part, transform, velocity in world:query(Part, Transform, Velocity) do -- for each entity with Part, Transform, and Velocity components
		-- Update part position
		part.part.CFrame = CFrame.new(transform.position)
	end
end
table.insert(systems, drawEntity) -- add the drawEntity system to the systems array

-- 6) Respawn more stuff
local timeAcc = 0
local function spawnChild(world)
	-- Get deltaTime
	local deltaTime = Matter.useDeltaTime()
	timeAcc += deltaTime -- accumulate time

	-- Check for reproduction
	for id, transform, food in world:query(Transform, Food) do -- for each entity with Transform and Food components
		if food.value < FOOD_TO_REPRODUCE then -- Check if enough food to reproduce
			continue
		end

		-- Spend food to multiply
		world:insert(
			id,
			food:patch({
				-- Reduce food by reproduction cost
				value = food.value - FOOD_TO_REPRODUCE,
			})
		)

		-- Make 2–3 children
		local kids = math.random(CHILDREN_MIN, CHILDREN_MAX) -- number of kids
		local totalMembers = kids + 1 -- total members (kids + parent)

		-- Share current food evenly across parent + kids (keeps population stable-ish)
		local share = FOOD_TO_REPRODUCE / totalMembers
		for k = 1, kids do
			-- Separation
			local childId
			if world:get(id, Carnivore) then
				childId = spawnCarnivore(transform.position) -- spawn carnivore child
			elseif world:get(id, Herbivore) then
				childId = spawnHerbivore(transform.position) -- spawn herbivore child
			elseif world:get(id, Plant) then
				childId = spawnPlant(transform.position) -- spawn plant child
			end

			-- Update food
			world:insert(
				childId,
				food:patch({
					value = share,
				})
			)
		end
	end

	-- Check if we can spawn any plants
	local want = math.floor(timeAcc * PLANT_RESPAWN_PER_SEC)
	if want > 0 then -- Check if the time accumulated is enough to spawn at least one plant
		timeAcc -= want / PLANT_RESPAWN_PER_SEC -- reduce accumulated time

		-- Spawn plants
		local toMake = want
		for _ = 1, toMake do
			spawnPlant() -- spawn a new plant
		end
	end

	print(`Alive: {world:size()}`) -- print current population size
end
table.insert(systems, spawnChild) -- add the spawnChild system to the systems array

-- Start the loop
loop:scheduleSystems(systems) -- schedule all defined systems
loop:begin({
	default = RunService.Heartbeat, -- use Heartbeat for default timing
})

-- Draw a faint square so you see the bounds
do
	local size = MAP_HALF * 2 -- full map size
	local floor = Instance.new("Part") -- create a new Part
	-- Set properties
	floor.Anchored = true
	floor.CanCollide = false
	floor.Size = Vector3.new(size, 1, size)
	floor.Position = Vector3.new(0, 1, 0)
	floor.Material = Enum.Material.SmoothPlastic
	floor.Color = Color3.fromRGB(40, 40, 40)
	floor.Transparency = 0.2
	floor.Parent = container -- put the floor in the world container
end
