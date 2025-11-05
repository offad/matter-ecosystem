local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Library
local Matter = require(ReplicatedStorage.Matter)

-- Constants:

local MAP_HALF = 150 -- Define -MAP_HALF to +MAP_HALF on X/Z
local SENSE_RADIUS = 50

local START_PLANT = 25
local START_HERBIVORE = 10
local START_CARNIVORE = 4

local PLANT_RESPAWN_PER_SEC = 6 -- try to keep food around

local MAX_HEALTH = 100

local MAX_FOOD = 200
local DEFAULT_FOOD = 40

local FOOD_TICK_PLANT = 2 -- passive gain (per second)
local FOOD_TICK_HERBIVORE = -3
local FOOD_TICK_CARNIVORE = -5
local FOOD_TO_REPRODUCE = 100

local CHILDREN_MIN, CHILDREN_MAX = 2, 3

local DIMINISH_AFTER_EACH_MEAL = 0.9 -- 10% less each subsequent meal

local MAX_SPEED = 20
local HEALTH_TICK_WHEN_STARVING = -20.0 -- regen when food <= 0
local HEALTH_TICK_WHEN_FED = 10.0 -- regen when food > 0

local EAT_RADIUS = 3 -- how close to count as "eaten"
local SEPARATION_RADIUS = 4 -- push away when too close
local SEPARATION_FORCE = 120
local BOUNDS_PADDING = 4
local BOUNDS_FORCE = 200

-- Variables:

-- Create world container
local container = Instance.new("Folder")
container.Name = "World"
container.Parent = game.Workspace

-- Define components
local Part = Matter.component() --> the visual Part
local Health = Matter.component()
local Food = Matter.component()
local Transform = Matter.component()
local Velocity = Matter.component()
local Target = Matter.component()
local Plant = Matter.component()
local Herbivore = Matter.component()
local Carnivore = Matter.component()

-- Create world
local world = Matter.World.new()
local loop = Matter.Loop.new(world) -- This makes Loop pass the world to all your systems.

-- Private functions:

local function rndUnitXZ()
	local ang = math.random() * math.pi * 2
	return Vector3.new(math.cos(ang), 0, math.sin(ang))
end

local function clampMag(v: Vector3, m: number)
	local mag = v.Magnitude
	if mag > m and mag > 0 then
		return v * (m / mag)
	end
	return v
end

-- Create a visual part
local function makePart(size: Vector3, color: Color3): BasePart
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
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
		component(),
		Part({
			part = part,
		}),
		Health({
			value = MAX_HEALTH
		}),
		Food({
			value = DEFAULT_FOOD,
			regen = foodRegen
		}),
		Transform({
			position = position,
		}),
		Velocity({
			value = Vector3.zero
		}),
		Target({
			value = nil
		})
	)
	
	-- Add part
	part:SetAttribute("entityId", id)
	part.Parent = container
	return id
end

local function rnd(a, b) return a + math.random() * (b - a) end
local function randomSpawnInMap()
	return Vector3.new(rnd(-MAP_HALF, MAP_HALF), 2, rnd(-MAP_HALF, MAP_HALF))
end

-- Spawn plant
local function spawnPlant(pos)
	return spawnEntity(
		pos or randomSpawnInMap(), 
		Plant, 
		Color3.fromRGB(80, 220, 120),
		Vector3.new(1.8, 1.8, 1.8),
		FOOD_TICK_PLANT
	) 
end

-- Spawn herbivore
local function spawnHerbivore(pos)
	return spawnEntity(
		pos or randomSpawnInMap(), 
		Herbivore, 
		Color3.fromRGB(255, 220, 0),
		Vector3.new(2.2, 2.2, 2.2),
		FOOD_TICK_HERBIVORE
	) 
end

-- Spawn carnivore
local function spawnCarnivore(pos)
	return spawnEntity(
		pos or randomSpawnInMap(), 
		Carnivore, 
		Color3.fromRGB(230, 70, 70),
		Vector3.new(2.6, 2.6, 2.6),
		FOOD_TICK_CARNIVORE
	)
end

-- Initial population
for _ = 1, START_PLANT do 
	spawnPlant()
end
for _ = 1, START_HERBIVORE do 
	spawnHerbivore()
end
for _ = 1, START_CARNIVORE do 
	spawnCarnivore()
end

-- Define systems
local systems = {}

-- We update all arrays every frame:

-- 1) Passive food & health regeneration
local function regenEntity(world)
	-- Get deltaTime
	local deltaTime = Matter.useDeltaTime()
	
	-- Check food and health
	for id, health, food, part in world:query(Health, Food, Part) do
		-- Passive food change
		local regen = food.regen or 0
		world:insert(id, food:patch({
			value = food.value + regen * deltaTime
		}))

		-- Starvation & regen
		if food.value <= 0 then
			health = health:patch({
				value = health.value + (HEALTH_TICK_WHEN_STARVING * deltaTime)
			})
		else
			health = health:patch({
				value = health.value + (HEALTH_TICK_WHEN_FED * deltaTime)
			})
		end
		health = health:patch({
			value = math.clamp(health.value, 0, MAX_HEALTH)
		})
		world:insert(id, health)
		
		-- Die if no health
		if health.value <= 0 then
			part.part:Destroy()
			world:despawn(id)
		end
	end
end
table.insert(systems, regenEntity)

-- Find nearest target index (linear scan; fine for small sims)
local function findNearest(position: Vector3, world, component, radius: number): number?
	local best, bestDistSq = nil, radius * radius
	for id, _, health, transform in world:query(component, Health, Transform) do
		if health.value > 0 then
			local d = (transform.position - position)
			local dsq = d.X*d.X + d.Z*d.Z -- ignore Y
			if dsq < bestDistSq then
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
	for id, _, transform, target in world:query(Herbivore, Transform, Target) do
		-- Target selection
		local targetId = findNearest(transform.position, world, Plant, SENSE_RADIUS)

		-- Update target
		world:insert(id, target:patch({
			value = targetId
		}))
	end
	
	-- Find carnivore targets
	for id, part, transform, target in world:query(Carnivore, Transform, Target) do
		-- Target selection
		local targetId = findNearest(transform.position, world, Herbivore, SENSE_RADIUS)
		
		-- Update target
		world:insert(id, target:patch({
			value = targetId
		}))
	end
end
table.insert(systems, findTarget)

-- Separation steering
local function separation(world, id, component): Vector3
	local acc = Vector3.zero
	local transform = world:get(id, Transform)
	local myPos = transform.position
	for entityId, _, entityTransform in world:query(component, Transform) do
		if id ~= entityId then
			local offset = myPos - entityTransform.position
			local dist = math.max(0.001, Vector3.new(offset.X, 0, offset.Z).Magnitude)
			if dist < SEPARATION_RADIUS then
				acc += (offset / dist) -- push away
			end
		end
	end
	return acc * SEPARATION_FORCE
end

-- Keep inside square map (soft force)
local function keepInBounds(transform): Vector3
	local p = transform.position
	local fx, fz = 0, 0
	if p.X >  MAP_HALF - BOUNDS_PADDING then fx = fx - 1 end
	if p.X < -MAP_HALF + BOUNDS_PADDING then fx = fx + 1 end
	if p.Z >  MAP_HALF - BOUNDS_PADDING then fz = fz - 1 end
	if p.Z < -MAP_HALF + BOUNDS_PADDING then fz = fz + 1 end
	if fx == 0 and fz == 0 then return Vector3.zero end
	return Vector3.new(fx, 0, fz).Unit * BOUNDS_FORCE
end

-- 3) Steering & movement (boids for consumers/hunters)
local function moveEntity(world)
	-- Get deltaTime
	local deltaTime = Matter.useDeltaTime()
	
	-- Update transform
	for id, transform, velocity, target in world:query(Transform, Velocity, Target) do
		-- Define force
		local force = Vector3.zero

		-- Seek force
		local targetId = target.value
		if targetId and world:contains(targetId) then
			local targetTransform = world:get(targetId, Transform)
			local desired = (targetTransform.position - transform.position)
			desired = Vector3.new(desired.X, 0, desired.Z)
			if desired.Magnitude > 0 then
				desired = desired.Unit * MAX_SPEED
				local steer = desired - velocity.value
				force += clampMag(steer, MAX_SPEED)
			end
		end

		-- Separation
		if world:get(id, Carnivore) then
			force += separation(world, id, Carnivore)
		elseif world:get(id, Herbivore) then
			force += separation(world, id, Herbivore)
		else
			-- Ignore plants
			continue
		end

		-- Keep in bounds
		force += keepInBounds(transform)

		-- Integrate
		local v = velocity.value + force * deltaTime
		v = Vector3.new(v.X, 0, v.Z)
		v = clampMag(v, MAX_SPEED)
		
		-- Update velocity
		velocity = velocity:patch({
			value = v
		})
		world:insert(id, velocity)
		-- Update position
		world:insert(id, transform:patch({
			position = transform.position + (v * deltaTime)
		}))
	end
end
table.insert(systems, moveEntity)

-- 4) Eat targets if close enough
local function eatTarget(world)
	-- Get deltaTime
	local deltaTime = Matter.useDeltaTime()

	-- Update transform
	for id, transform, food, target in world:query(Transform, Food, Target) do
		local targetId = target.value
		if not (targetId and world:contains(targetId)) then
			continue
		end
		
		-- Get enemy transform
		local targetTransform, targetFood, targetPart = world:get(targetId, Transform, Food, Part)
		if (transform.position - targetTransform.position).Magnitude > EAT_RADIUS then 
			continue 
		end

		-- Update food
		world:insert(id, food:patch({
			value = food.value + targetFood.value * DIMINISH_AFTER_EACH_MEAL
		}))
		-- Update target
		world:insert(id, target:patch({
			value = nil
		}))
		
		-- Remove target
		targetPart.part:Destroy()
		world:despawn(targetId)
	end
end
table.insert(systems, eatTarget)

-- 5) Draw all parts
local function drawEntity(world)
	for id, part, transform, velocity in world:query(Part, Transform, Velocity) do
		part.part.CFrame = CFrame.new(transform.position)
	end
end
table.insert(systems, drawEntity)

-- 6) Respawn more stuff
local timeAcc = 0
local function spawnChild(world)
	-- Get deltaTime
	local deltaTime = Matter.useDeltaTime()
	timeAcc += deltaTime
	
	-- Reproduction
	for id, transform, food in world:query(Transform, Food) do
		if food.value < FOOD_TO_REPRODUCE then continue end

		-- Spend food to multiply
		world:insert(id, food:patch({
			value = food.value - FOOD_TO_REPRODUCE
		}))

		-- Make 2–3 children
		local kids = math.random(CHILDREN_MIN, CHILDREN_MAX)
		local totalMembers = kids + 1

		-- Share current food evenly across parent + kids (keeps population stable-ish)
		local share = FOOD_TO_REPRODUCE / totalMembers
		for k = 1, kids do
			-- Separation
			local childId
			if world:get(id, Carnivore) then
				childId = spawnCarnivore(transform.position)
			elseif world:get(id, Herbivore) then
				childId = spawnHerbivore(transform.position)
			elseif world:get(id, Plant) then
				childId = spawnPlant(transform.position)
			end
			
			-- Update food
			world:insert(id, food:patch({
				value = share
			}))
		end
	end
	
	-- Check if we can spawn any plants
	local want = math.floor(timeAcc * PLANT_RESPAWN_PER_SEC)
	if want > 0 then
		timeAcc -= want / PLANT_RESPAWN_PER_SEC

		-- Spawn plants
		local toMake = want
		for _ = 1, toMake do
			spawnPlant()
		end
	end
	
	print(`Alive: {world:size()}`)
end
table.insert(systems, spawnChild)

-- Start the loop
loop:scheduleSystems(systems)
loop:begin({
	default = RunService.Heartbeat
})

-- Draw a faint square so you see the bounds
do
	local size = MAP_HALF * 2
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.CanCollide = false
	floor.Size = Vector3.new(size, 1, size)
	floor.Position = Vector3.new(0, 1, 0)
	floor.Material = Enum.Material.SmoothPlastic
	floor.Color = Color3.fromRGB(40, 40, 40)
	floor.Transparency = 0.2
	floor.Parent = container
end
