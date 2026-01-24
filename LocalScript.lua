-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Library
local Matter = require(ReplicatedStorage.Matter) -- Load the Matter ECS library open-source library

-- Vec2 Class (Metatable implementation for 2D vector math)
-- This class handles XZ plane operations since our simulation is 2D
local Vec2 = {}
Vec2.__index = Vec2 -- set metatable index to itself for method lookup

-- Define Vec2 type for type checking (includes fields and methods)
export type Vec2 = {
	x: number,
	z: number,
	magnitude: (self: Vec2) -> number,
	sqrMagnitude: (self: Vec2) -> number,
	unit: (self: Vec2) -> Vec2,
	dot: (self: Vec2, other: Vec2) -> number,
	toVector3: (self: Vec2, y: number?) -> Vector3,
}

-- Constructor: creates a new Vec2 instance
function Vec2.new(x: number, z: number)
	local self = setmetatable({}, Vec2) -- create table and set Vec2 as its metatable
	self.x = x or 0 -- default to 0 if nil
	self.z = z or 0
	return self
end

-- Create Vec2 from a Vector3 (extracts X and Z, ignores Y)
function Vec2.fromVector3(v: Vector3)
	return Vec2.new(v.X, v.Z)
end

-- Convert Vec2 back to Vector3 (with configurable Y value)
function Vec2:toVector3(y: number?): Vector3
	return Vector3.new(self.x, y or 0, self.z)
end

-- Calculate magnitude (length) of the vector
function Vec2:magnitude(): number
	return math.sqrt(self.x * self.x + self.z * self.z)
end

-- Calculate squared magnitude (avoids sqrt for performance)
function Vec2:sqrMagnitude(): number
	return self.x * self.x + self.z * self.z
end

-- Return normalized (unit) vector with magnitude 1
function Vec2:unit(): Vec2
	local mag = self:magnitude()
	if mag > 0 then
		return Vec2.new(self.x / mag, self.z / mag)
	end
	return Vec2.new(0, 0) -- return zero vector if magnitude is 0
end

-- Dot product of two Vec2s
function Vec2:dot(other: Vec2): number
	return self.x * other.x + self.z * other.z
end

-- Metamethod: addition operator overload (a + b)
function Vec2.__add(a: Vec2, b: Vec2): Vec2
	return Vec2.new(a.x + b.x, a.z + b.z)
end

-- Metamethod: subtraction operator overload (a - b)
function Vec2.__sub(a: Vec2, b: Vec2): Vec2
	return Vec2.new(a.x - b.x, a.z - b.z)
end

-- Metamethod: multiplication operator overload (a * b or a * number)
function Vec2.__mul(a: Vec2, b): Vec2
	if type(b) == "number" then
		return Vec2.new(a.x * b, a.z * b) -- scalar multiplication
	end
	return Vec2.new(a.x * b.x, a.z * b.z) -- component-wise multiplication
end

-- Metamethod: division operator overload (a / b or a / number)
function Vec2.__div(a: Vec2, b): Vec2
	if type(b) == "number" then
		return Vec2.new(a.x / b, a.z / b) -- scalar division
	end
	return Vec2.new(a.x / b.x, a.z / b.z) -- component-wise division
end

-- Metamethod: unary minus operator overload (-a)
function Vec2.__unm(a: Vec2): Vec2
	return Vec2.new(-a.x, -a.z)
end

-- Metamethod: equality operator overload (a == b)
function Vec2.__eq(a: Vec2, b: Vec2): boolean
	return a.x == b.x and a.z == b.z
end

-- Metamethod: tostring for debugging
function Vec2.__tostring(v: Vec2): string
	return string.format("Vec2(%.2f, %.2f)", v.x, v.z)
end

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

-- CFrame interpolation speed for smooth rotation
local ROTATION_LERP_SPEED = 0.15 -- how fast entities rotate toward movement direction

-- Variables:

-- Create world container
local container = Instance.new("Folder")
container.Name = "World"
container.Parent = game.Workspace -- put the folder in the Workspace

-- Raycast parameters for line-of-sight checks
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude -- exclude specified instances
raycastParams.FilterDescendantsInstances = { container } -- ignore all simulation entities

-- Overlap parameters for spatial queries
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Include -- only include specified instances
overlapParams.FilterDescendantsInstances = { container } -- only check simulation entities

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

-- Clamp Vec2 magnitude to max number m (no strict typing due to metamethod operators)
local function clampMag2(v, m: number)
	local mag = v:magnitude()
	if mag > m then
		return v:unit() * m -- return clamped
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

-- Perform raycast to check line of sight between two positions
local function hasLineOfSight(from: Vector3, to: Vector3): boolean
	local direction = to - from -- calculate direction vector
	local result = workspace:Raycast(from, direction, raycastParams) -- cast ray
	return result == nil -- true if no obstacle hit (clear line of sight)
end

-- Get nearby parts using spatial query (more efficient than manual distance checks)
local function getNearbyParts(position: Vector3, radius: number): { BasePart }
	return workspace:GetPartBoundsInRadius(position, radius, overlapParams)
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
			value = Vec2.new(0, 0), -- start stationary (using Vec2)
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

-- Find nearest target using spatial query and line-of-sight raycast
local function findNearest(position: Vector3, world, component, radius: number): number?
	local best, bestDistSq = nil, radius * radius

	-- Use spatial query to get nearby parts efficiently
	local nearbyParts = getNearbyParts(position, radius)

	-- Check each nearby part
	for _, part in nearbyParts do
		local entityId = part:GetAttribute("entityId") -- get entity ID from part attribute
		if entityId and world:contains(entityId) then
			-- Check if entity has the required component
			if not world:get(entityId, component) then
				continue -- skip if wrong type
			end

			local health = world:get(entityId, Health)
			local transform = world:get(entityId, Transform)

			if health and health.value > 0 and transform then
				-- Calculate squared distance using Vec2 for efficiency
				local myPos = Vec2.fromVector3(position)
				local targetPos = Vec2.fromVector3(transform.position)
				local offset = targetPos - myPos
				local dsq = offset:sqrMagnitude() -- squared magnitude avoids sqrt

				-- Check if closer than current best
				if dsq < bestDistSq then
					-- Raycast to check line of sight (physics-based visibility)
					if hasLineOfSight(position, transform.position) then
						bestDistSq = dsq
						best = entityId
					end
				end
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

-- Separation steering using Vec2 math
local function separation(world, id, component): Vec2
	local acc = Vec2.new(0, 0) -- accumulated separation force
	local transform = world:get(id, Transform) -- get the Transform component of the entity with the given id
	local myPos = Vec2.fromVector3(transform.position) -- convert to Vec2

	-- Check nearby same-type entities
	for entityId, _, entityTransform in world:query(component, Transform) do -- for each entity with the specified component and Transform
		if id ~= entityId then -- ignore self
			-- Calculate offset using Vec2
			local entityPos = Vec2.fromVector3(entityTransform.position)
			local offset = myPos - entityPos
			local dist = math.max(0.001, offset:magnitude())
			if dist < SEPARATION_RADIUS then -- Check if within separation radius
				acc = acc + (offset / dist) -- push away (using Vec2 operator overload)
			end
		end
	end

	-- Return force
	return acc * SEPARATION_FORCE
end

-- Keep inside square map (soft force) using Vec2
local function keepInBounds(transform): Vec2
	-- Get position as Vec2
	local p = Vec2.fromVector3(transform.position)
	-- Determine x and z force direction depending on position
	local fx, fz = 0, 0
	if p.x > MAP_HALF - BOUNDS_PADDING then -- Check if past the right edge
		fx = fx - 1 -- apply leftward force
	end
	if p.x < -MAP_HALF + BOUNDS_PADDING then -- Check if past the left edge
		fx = fx + 1 -- apply rightward force
	end
	if p.z > MAP_HALF - BOUNDS_PADDING then -- Check if past the top edge
		fz = fz - 1 -- apply downward force
	end
	if p.z < -MAP_HALF + BOUNDS_PADDING then -- Check if past the bottom edge
		fz = fz + 1 -- apply upward force
	end
	if fx == 0 and fz == 0 then
		return Vec2.new(0, 0)
	end
	-- Return force using Vec2 unit and multiplication
	return Vec2.new(fx, fz):unit() * BOUNDS_FORCE
end

-- 3) Steering & movement (boids for consumers/hunters) using Vec2
local function moveEntity(world)
	-- Get deltaTime
	local deltaTime = Matter.useDeltaTime()

	-- Update transform
	for id, transform, velocity, target in world:query(Transform, Velocity, Target) do -- for each entity with Transform, Velocity, and Target components
		-- Define force as Vec2
		local force = Vec2.new(0, 0)

		-- Seek force
		local targetId = target.value
		if targetId and world:contains(targetId) then -- check if target is valid
			-- Get target transform
			local targetTransform = world:get(targetId, Transform)
			-- Calculate desired velocity using Vec2
			local myPos = Vec2.fromVector3(transform.position)
			local targetPos = Vec2.fromVector3(targetTransform.position)
			local desired = targetPos - myPos -- Vec2 subtraction via metamethod
			if desired:magnitude() > 0 then
				desired = desired:unit() * MAX_SPEED -- normalize and scale
				local steer = desired - velocity.value -- Vec2 subtraction
				force = force + clampMag2(steer, MAX_SPEED)
			end
		end

		-- Separation
		if world:get(id, Carnivore) then -- check if entity is a carnivore
			force = force + separation(world, id, Carnivore) -- apply separation force from other carnivores
		elseif world:get(id, Herbivore) then -- check if entity is a herbivore
			force = force + separation(world, id, Herbivore) -- apply separation force from other herbivores
		else
			-- Ignore any other kind of entities
			continue
		end

		-- Keep in bounds
		force = force + keepInBounds(transform)

		-- Integrate velocity using Vec2
		local v = velocity.value + force * deltaTime -- Vec2 addition and scalar multiply
		v = clampMag2(v, MAX_SPEED) -- clamp to max speed

		-- Update velocity
		velocity = velocity:patch({
			value = v, -- new velocity (Vec2)
		})
		world:insert(id, velocity) -- update velocity component

		-- Update position (convert Vec2 velocity to Vector3 for position)
		local displacement = v:toVector3(0) * deltaTime
		world:insert(
			id,
			transform:patch({
				position = transform.position + displacement,
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

		-- Calculate distance using Vec2 for XZ plane distance
		local myPos = Vec2.fromVector3(transform.position)
		local targetPos = Vec2.fromVector3(targetTransform.position)
		local distance = (targetPos - myPos):magnitude()

		if distance > EAT_RADIUS then
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

-- 5) Draw all parts with CFrame rotation toward movement direction
local function drawEntity(world)
	-- Update all parts positions and rotations
	for id, part, transform, velocity in world:query(Part, Transform, Velocity) do -- for each entity with Part, Transform, and Velocity components
		local pos = transform.position
		local vel = velocity.value -- Vec2

		-- Check if entity is moving (has velocity)
		if vel:magnitude() > 0.1 then
			-- Calculate look target position (current pos + velocity direction)
			local lookTarget = pos + vel:toVector3(0)
			-- Create target CFrame using CFrame.lookAt (faces movement direction)
			local targetCFrame = CFrame.lookAt(pos, lookTarget)
			-- Get current CFrame for smooth interpolation
			local currentCFrame = part.part.CFrame
			-- Lerp between current and target CFrame for smooth rotation
			part.part.CFrame = currentCFrame:Lerp(targetCFrame, ROTATION_LERP_SPEED)
		else
			-- Not moving, just update position without rotation change
			local currentRotation = part.part.CFrame - part.part.CFrame.Position -- extract rotation only
			part.part.CFrame = currentRotation + pos -- apply rotation at new position
		end
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
