--Please i used a module script like entity service just for some organization please don't decline my application because of that
--I can give a link to the module aswell if you want to view it but please do not decline because of this "https://github.com/igniteletters-beep/Combat/blob/main/EntityServer.lua"

--First we will get all of the variables
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

-- the module to handle states, dmg funcs and some other things
local EntityService = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("EntityService"))

-- remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ActionTRemote = Remotes:WaitForChild("ActionT")
local StartAttack = Remotes:WaitForChild("StartAttack")
local BlockRemote = Remotes:WaitForChild("BlockRemote")
local ParrySuccess = Remotes:WaitForChild("ParrySuccess")
local UppercutRemote = Remotes:WaitForChild("UppercutRemote")
local DownslamRemote = Remotes:WaitForChild("DownslamRemote")
local DashKickRemote = Remotes:WaitForChild("DashKick")

local Assets = ReplicatedStorage:WaitForChild("Assets")

-- tuning
local POSTURE_MAX = 100
local POSTURE_PER_BLOCK_HIT = 20
local POSTURE_DECAY_DELAY = 5
local POSTURE_DECAY_TIME = 15
local POSTURE_DECAY_RATE = POSTURE_MAX / POSTURE_DECAY_TIME

local BASE_M_DAMAGE = 10
local BASE_M_STUN = 0.5

local M4_KNOCKBACK_STUN = 1.0
local M4_COMBO_EXTEND_WINDOW = 1.25

-- M1 Hitbox
-- using GetPartBoundsInBox bc its modern and relaiable, and we can exclude the attacker so the attacker takes no damage
local M_HITBOX_SIZE = Vector3.new(7, 7, 8)
local M_HITBOX_FORWARD = 4.5
local M_HITBOX_UP = 2
local M_DAMAGE_WINDOW = 0.18

-- uppercut stuff
local UPPER_HITBOX_SIZE = Vector3.new(6, 7, 6)
local UPPER_HITBOX_OFFSET = Vector3.new(0, 2, -3)
local UPPER_DAMAGE = 12
local UPPER_STUN = 1.2

-- downslam stuff
local DOWNSLAM_DAMAGE = 25
local DOWNSLAM_STUN = 1.2
local DOWNSLAM_VEL = Vector3.new(0, -120, 0)

-- dashkick / chase stuff
local DASHKICK_DAMAGE = 15
local DASHKICK_STUN = 1.2

local CHASE_DAMAGE = 12
local CHASE_STUN = 1.0

-- storage stuff
local Entities = {}          -- [model] = entity
local PlayerData = {}        -- [userid] = stuff for hit windows

local AirStates = {}         -- [model] = pairedModel (air combo pair)
local ComboExtend = {}       -- [player] = {Target=model, Expires=time}
local PostureTasks = {}      -- [model] = decay task ref
local ActiveKnockbacks = {}  -- [model] = {Root=root, Tween=tween}
local ActiveAirDash = {}     -- [player] = {Hit=false, Tween=tween, Conn=conn, Expire=time}

-- helper functions, the things that help me do stuff faster and not make the script 100X longer :)

local function configureHumanoid(hum: Humanoid)
	-- stops the character from falling over and stuff, cuz roblox is kinda wierd ngl
	pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false) end)
	pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false) end)
	pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Physics, false) end)
	hum.AutoRotate = true
end

local function registerEntity(model: Model)
	-- makes sure every humanoid model has a cached entity object
	-- also cleans it up when model gets deleted
	if not model or not model.Parent then return nil end
	if not model:FindFirstChildOfClass("Humanoid") then return nil end
	if Entities[model] then return Entities[model] end

	local ent = EntityService.new(model)
	Entities[model] = ent
	configureHumanoid(ent.Humanoid)

	model.AncestryChanged:Connect(function(_, parent)
		if parent then return end
		Entities[model] = nil
		AirStates[model] = nil
		PostureTasks[model] = nil
		ActiveKnockbacks[model] = nil
	end)

	return ent
end

local function getPosture(model: Model): number
	-- nil means 0 posture so he is far from being block broken sicne 100 posture will block break
	return model:GetAttribute("Posture") or 0
end

local function setPosture(model: Model, value: number)
	-- if posture is 0 we delete the attribute so ui can auto disappear and it makes it more cleaner cuz i like it
	if value <= 0 then
		model:SetAttribute("Posture", nil)
		return
	end
	model:SetAttribute("Posture", math.clamp(value, 0, POSTURE_MAX))
end

local function startPostureDecay(model: Model)
	-- 1 decay task per model max (cheap loop, runs only if posture exists)
	if PostureTasks[model] then return end

	PostureTasks[model] = task.spawn(function()
		while model.Parent do
			task.wait(1)

			-- last time they blocked smth
			local lastHit = model:GetAttribute("LastPostureHit")
			if not lastHit then break end

			-- wait a bit before decay starts so posture doesnt insta drop
			if os.clock() - lastHit >= POSTURE_DECAY_DELAY then
				local posture = getPosture(model) - POSTURE_DECAY_RATE
				setPosture(model, posture)
				if posture <= 0 then break end
			end
		end
		PostureTasks[model] = nil
	end)
end

local function emitAttachmentVFX(attachmentTemplate: Instance?, parentPart: BasePart?, lifetime: number?)
	-- quick vfx helper it helps me execute vfx much easier and i dont have to write this over and over
	if not attachmentTemplate or not parentPart then return end
	local vfx = attachmentTemplate:Clone()
	vfx.Parent = parentPart

	for _, obj in ipairs(vfx:GetChildren()) do
		if obj:IsA("ParticleEmitter") then
			obj:Emit(obj:GetAttribute("EmitCount") or 10)
		end
	end

	Debris:AddItem(vfx, lifetime or 1)
end

local function clearForces(model: Model)
	-- clears any old movement controllers so we dont stack forces from dfferent skills
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then return end

	for _, obj in ipairs(root:GetChildren()) do
		if obj:IsA("LinearVelocity") or obj:IsA("AngularVelocity") or obj:IsA("BodyGyro") then
			obj:Destroy()
		end
	end

	root.AssemblyLinearVelocity = Vector3.zero
end

local function isBehind(victimRoot: BasePart, attackerRoot: BasePart): boolean
	-- behind check if attacker attacks from the back it will cancel parry and blocking
	local dir = (attackerRoot.Position - victimRoot.Position).Unit
	return victimRoot.CFrame.LookVector:Dot(dir) < -0.2
end

local function stopKnockback(model: Model)
	-- cancel knockback tween if its still running and reset velocity it helps with the chase system thing
	local kb = ActiveKnockbacks[model]
	if not kb then return end

	if kb.Tween then pcall(function() kb.Tween:Cancel() end) end
	if kb.Root and kb.Root.Parent then
		kb.Root.Anchored = false
		kb.Root.AssemblyLinearVelocity = Vector3.zero
	end

	ActiveKnockbacks[model] = nil
end

local function tweenKnockback(victimRoot: BasePart, attackerRoot: BasePart, victimModel: Model)
	-- knockback done by anchoring + tween so its consistent for everyone so it does not really uses pysics rng if you get what i am saying
	-- also we set network owner nil so client cant fight the tween
	local dir = victimRoot.Position - attackerRoot.Position
	dir = Vector3.new(dir.X, 0, dir.Z)
	if dir.Magnitude < 0.01 then dir = attackerRoot.CFrame.LookVector end
	dir = dir.Unit

	local distance = 22
	local height = 0.5
	local duration = 0.25

	local targetPos = victimRoot.Position + dir * distance + Vector3.new(0, height, 0)
	local targetCF = CFrame.new(targetPos, targetPos + dir)

	stopKnockback(victimModel)

	pcall(function() victimRoot:SetNetworkOwner(nil) end)
	victimRoot.AssemblyLinearVelocity = Vector3.zero
	victimRoot.Anchored = true

	local tween = TweenService:Create(
		victimRoot,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = targetCF }
	)

	ActiveKnockbacks[victimModel] = { Root = victimRoot, Tween = tween }

	tween:Play()
	tween.Completed:Once(function()
		if victimRoot and victimRoot.Parent then
			victimRoot.Anchored = false
			victimRoot.AssemblyLinearVelocity = Vector3.zero
		end
		ActiveKnockbacks[victimModel] = nil
	end)
end

local function getFrontBoxCF(root: BasePart, forward: number, up: number)
	-- we build a rotated box in front of the attacker
	local pos = root.Position + root.CFrame.LookVector * forward + Vector3.new(0, up, 0)
	return CFrame.lookAt(pos, pos + root.CFrame.LookVector)
end

local function collectVictimModelsFromBox(boxCF: CFrame, boxSize: Vector3, attackerChar: Model)
	-- pulls parts in box, then returns a set of humanoid models
	-- set avoids double-hitting the same target bc of many parts in the character
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { attackerChar }

	local parts = workspace:GetPartBoundsInBox(boxCF, boxSize, overlap)

	local found = {}
	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model ~= attackerChar and model:FindFirstChildOfClass("Humanoid") then
			found[model] = true
		end
	end
	return found
end

-- hit resolver
-- this is the 1 place that decides: parry/block/behind/unblockable + posture and stuff
local function resolveHit(attackerEntity, victimEntity, damage: number, opts, attackerPlayerForParry: Player?)
	local victimRoot = victimEntity:GetRoot()
	local attackerRoot = attackerEntity:GetRoot()
	if not victimRoot or not attackerRoot then return end

	local behind = isBehind(victimRoot, attackerRoot)

	-- parry only works if attacker is not behind
	if opts.canParry ~= false and victimEntity.State == "ParryWindow" and not behind then
		-- parry stuns the attacker so the person that parried can attack the attacker like a counter
		attackerEntity:SetState("Stunned", 1.5, true)
		if attackerPlayerForParry then ParrySuccess:FireClient(attackerPlayerForParry) end

		local parryAtt = Assets:FindFirstChild("Parry") and Assets.Parry:FindFirstChild("Attachment")
		emitAttachmentVFX(parryAtt, victimRoot, 1)
		return "Parried"
	end

	-- if attacker is behind, we auto break defense, not block break it just cancels the blocking
	if behind and (victimEntity.State == "Blocking" or victimEntity.State == "ParryWindow") then
		victimEntity:BreakDefense()
	end

	-- blocking stuff
	if opts.canBlock ~= false and victimEntity.State == "Blocking" and not behind then
		local model = victimEntity.Model

		-- build posture per blocked hit this is the meter when it reaches 100 it block breaks
		local posture = getPosture(model) + POSTURE_PER_BLOCK_HIT
		model:SetAttribute("LastPostureHit", os.clock())
		setPosture(model, posture)
		startPostureDecay(model)

		-- guard break at max posture which is 100
		if posture >= POSTURE_MAX then
			setPosture(model, 0)
			model:SetAttribute("LastPostureHit", nil)
			victimEntity:SetState("Stunned", 2, true)

			local bbAtt = Assets:FindFirstChild("BlockBreak") and Assets.BlockBreak:FindFirstChild("Attachment")
			emitAttachmentVFX(bbAtt, victimRoot, 1)
			return "GuardBreak"
		end

		-- unblockable: break block and deal full dmg
		if opts.unblockable then
			victimEntity:BreakDefense()
			victimEntity:ForceDamage(damage)
			return "GuardBrokenByUnblockable"
		end

		-- normal block: small dmg, you can remove this if you dont want blocking to do any damage
		victimEntity:ForceDamage(damage * (opts.chip or 0.2))

		local blockAtt = Assets:FindFirstChild("Block") and Assets.Block:FindFirstChild("Attachment")
		emitAttachmentVFX(blockAtt, victimRoot, 1)
		return "Blocked"
	end

	-- normal hit no blocking no parry nothing
	victimEntity:ForceDamage(damage)
	return "Hit"
end

-- player setup stuff
local function setupPlayer(player: Player, character: Model)
	local ent = registerEntity(character)
	if not ent then return end

	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then configureHumanoid(hum) end

	PlayerData[player.UserId] = {
		IsLethal = false, -- dmg window toggle if its true then it can do damage if its false it cant
		TargetsHit = {}, -- this is the table that checks every character that has been hit
		LastCombo = 1,

		DamageConn = nil, -- heartbeat connection for dmg window
		DamageEndTime = 0,
	}
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		setupPlayer(player, character)
	end)
end)

-- attack remote
-- client tells us if it is a start, enableDamage, finish, server owns the real hit checks so no dumb exploiters
StartAttack.OnServerEvent:Connect(function(player: Player, action: string, combo: number)
	local data = PlayerData[player.UserId]
	local character = player.Character
	local entity = character and Entities[character]
	if not data or not entity then return end
	if entity.State == "Stunned" then return end

	local function stopDamageWindow()
		data.IsLethal = false
		if data.DamageConn then
			data.DamageConn:Disconnect()
			data.DamageConn = nil
		end
	end

	if action == "Start" then
		-- start combo anim state on server (stops overlap w other states)
		entity:SetState("Attacking", 0.5, true)
		stopDamageWindow()

		data.LastCombo = combo
		table.clear(data.TargetsHit)

	elseif action == "EnableDamage" then
		-- this is the tiny window in the anim where dmg should be active
		stopDamageWindow()

		data.IsLethal = true
		data.DamageEndTime = os.clock() + M_DAMAGE_WINDOW

		local root = character:FindFirstChild("HumanoidRootPart")
		if not root then stopDamageWindow(); return end

		-- we use heartbeat so its consistent and not tied to fps
		data.DamageConn = RunService.Heartbeat:Connect(function()
			-- kill window if anything changes
			if not character.Parent then stopDamageWindow(); return end
			if entity.State == "Stunned" then stopDamageWindow(); return end
			if os.clock() > data.DamageEndTime then stopDamageWindow(); return end
			if not data.IsLethal then stopDamageWindow(); return end

			local boxCF = getFrontBoxCF(root, M_HITBOX_FORWARD, M_HITBOX_UP)
			local victimModels = collectVictimModelsFromBox(boxCF, M_HITBOX_SIZE, character)

			for victimModel in pairs(victimModels) do
				-- 1 hit per target per dmg window so 1 swing cant hit a lot of times
				if data.TargetsHit[victimModel] then continue end
				data.TargetsHit[victimModel] = true

				local victim = registerEntity(victimModel)
				if not victim then continue end

				local hitResult = resolveHit(
					entity,
					victim,
					BASE_M_DAMAGE,
					{ canParry = true, canBlock = true, unblockable = false, chip = 0.2 },
					player
				)

				-- only stun on real hits not on parry/block
				if hitResult == "Hit" or hitResult == "GuardBrokenByUnblockable" then
					victim:SetState("Stunned", BASE_M_STUN, true)

					-- I know i called it Mike, just change it to something else if you don't want it named Mike
					local hitAtt = Assets:FindFirstChild("Hit") and Assets.Hit:FindFirstChild("MIKE")
					emitAttachmentVFX(hitAtt, victim:GetRoot(), 1)
				end

				-- m1 the fourth attack = knockback + small extend window for chasing like a pro
				if data.LastCombo == 4 and (hitResult == "Hit" or hitResult == "GuardBrokenByUnblockable") then
					local vRoot = victim:GetRoot()
					local aRoot = entity:GetRoot()
					if vRoot and aRoot then
						tweenKnockback(vRoot, aRoot, victimModel)
					end

					victim:SetState("Stunned", M4_KNOCKBACK_STUN, true)

					ComboExtend[player] = {
						Target = victimModel,
						Expires = os.clock() + M4_COMBO_EXTEND_WINDOW,
					}

					-- cleanup extend window so old targets dont stick forever
					task.delay(M4_COMBO_EXTEND_WINDOW + 0.1, function()
						local ce = ComboExtend[player]
						if ce and ce.Target == victimModel then
							ComboExtend[player] = nil
						end
					end)
				end
			end
		end)

	elseif action == "Finish" then
		stopDamageWindow()
	end
end)

-- block and parry
BlockRemote.OnServerEvent:Connect(function(player: Player, action: string)
	local character = player.Character
	local entity = character and Entities[character]
	if not entity or entity.State == "Stunned" then return end

	if action == "InputBegan" then
		-- parry window first, then it turns into hold-block
		entity:SetState("ParryWindow", 0.2, true)
		task.delay(0.2, function()
			if entity.State == "ParryWindow" then
				entity:SetState("Blocking", nil, true)
			end
		end)

	elseif action == "InputEnded" then
		entity:SetState("Idle", nil, true)
	end
end)

-- uppercut helper sutff

local function liftCharacter(model: Model, liftVel: number, liftTime: number, lockTime: number)
	-- lifts up then "locks" in air for a bit for air combo feel
	-- platformstand disables normal humanoid movement so they dont fight the force
	local root = model:FindFirstChild("HumanoidRootPart")
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not root or not hum then return end

	clearForces(model)

	-- bodygyro keeps them from spinning like crazy mid air
	local bg = Instance.new("BodyGyro")
	bg.P = 8000
	bg.D = 300
	bg.MaxTorque = Vector3.new(1e7, 1e7, 1e7)
	bg.CFrame = root.CFrame
	bg.Parent = root

	local att = Instance.new("Attachment")
	att.Name = "LiftAttachment"
	att.Parent = root

	hum.PlatformStand = true
	root.AssemblyLinearVelocity = Vector3.zero

	local lv = Instance.new("LinearVelocity")
	lv.Name = "AirComboForce"
	lv.MaxForce = 9e6
	lv.VectorVelocity = Vector3.new(0, liftVel, 0)
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.Parent = root

	-- after lift, stop moving, then release after lockTime
	task.delay(liftTime, function()
		if lv and lv.Parent then lv.VectorVelocity = Vector3.zero end

		task.delay(lockTime, function()
			if lv and lv.Parent then lv:Destroy() end
			if att and att.Parent then att:Destroy() end
			if bg and bg.Parent then bg:Destroy() end
			if hum and hum.Parent then hum.PlatformStand = false end
		end)
	end)
end

-- uppercut remote
UppercutRemote.OnServerEvent:Connect(function(player: Player)
	local character = player.Character
	if not character then return end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local attacker = registerEntity(character)
	if not attacker or attacker.State == "Stunned" then return end

	-- find 1 victim in a rotated box in front good for uppercut aim
	local boxCF = root.CFrame * CFrame.new(UPPER_HITBOX_OFFSET)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = { character }
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	local parts = workspace:GetPartBoundsInBox(boxCF, UPPER_HITBOX_SIZE, overlapParams)

	local victimModel: Model?
	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model ~= character and model:FindFirstChildOfClass("Humanoid") then
			victimModel = model
			break
		end
	end
	if not victimModel then return end

	local victim = registerEntity(victimModel)
	if not victim then return end

	local victimRoot = victim:GetRoot()
	if not victimRoot then return end

	-- uppercut is "unblockable" but still parryable
	local hitResult = resolveHit(
		attacker,
		victim,
		UPPER_DAMAGE,
		{ canParry = true, canBlock = true, unblockable = true },
		player
	)

	-- if they parried, resolveHit already stunned attacker, so we end here
	if hitResult == "Parried" then return end

	-- force stop defense and stun the enemy
	victim:BreakDefense()
	victim:SetState("Stunned", UPPER_STUN, true)

	-- vfx
	local upAtt = Assets:FindFirstChild("Uptilt") and Assets.Uptilt:FindFirstChild("Attachment")
	emitAttachmentVFX(upAtt, victimRoot, 1)

	-- set both as uppercut state so follow-ups can check air pair
	attacker:SetState("Uppercut", 1.8, true)
	victim:SetState("Uppercut", 1.8, true)

	-- lift both for air combo feel
	liftCharacter(character, 55, 0.25, 1.5)
	liftCharacter(victimModel, 55, 0.25, 1.5)

	-- store pair
	AirStates[character] = victimModel
	AirStates[victimModel] = character

	-- cleanup pair after a bit in case smth bugs out which it won't i hope
	task.delay(3.35, function()
		AirStates[character] = nil
		AirStates[victimModel] = nil
	end)
end)

-- downslam
local function doDownslam(player: Player)
	local character = player.Character
	if not character then return end

	local attacker = registerEntity(character)
	if not attacker or attacker.State == "Stunned" then return end

	-- downslam only works if you currently have an air pair target so you have to uppercut first then press T to downslam
	local victimModel = AirStates[character]
	if not victimModel or not victimModel.Parent then
		AirStates[character] = nil
		return
	end

	local vRoot = victimModel:FindFirstChild("HumanoidRootPart")
	local vHum = victimModel:FindFirstChildOfClass("Humanoid")
	if not vRoot or not vHum then
		AirStates[character] = nil
		AirStates[victimModel] = nil
		return
	end

	clearForces(victimModel)
	vHum.PlatformStand = true

	-- push them down fast so you can start combo extending them once they are down
	local att = Instance.new("Attachment")
	att.Name = "Downslam_Attachment"
	att.Parent = vRoot

	local lv = Instance.new("LinearVelocity")
	lv.MaxForce = 9e6
	lv.VectorVelocity = DOWNSLAM_VEL
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.Parent = vRoot

	Debris:AddItem(lv, 0.6)
	Debris:AddItem(att, 0.6)

	-- stop the slam when we touch ground without this the enemy just flings and it's super annyoing
	task.spawn(function()
		local rayParams = RaycastParams.new()
		rayParams.FilterDescendantsInstances = { victimModel, character }
		rayParams.FilterType = Enum.RaycastFilterType.Exclude

		local start = os.clock()
		while os.clock() - start < 1 do
			local ray = workspace:Raycast(vRoot.Position, Vector3.new(0, -6, 0), rayParams)
			if ray then
				if lv.Parent then lv:Destroy() end
				vRoot.AssemblyLinearVelocity = Vector3.zero
				vHum.PlatformStand = false

				-- snap slightly above ground (prevents clipping)
				vRoot.CFrame = CFrame.new(ray.Position + Vector3.new(0, 3, 0)) * CFrame.Angles(0, math.rad(vRoot.Orientation.Y), 0)

				local slamAtt = Assets:FindFirstChild("Slam") and Assets.Slam:FindFirstChild("Attachment")
				emitAttachmentVFX(slamAtt, vRoot, 1)
				break
			end
			task.wait()
		end
	end)

	-- dmg part also parryable, but unblockable
	local victim = registerEntity(victimModel)
	if victim then
		local hitResult = resolveHit(
			attacker,
			victim,
			DOWNSLAM_DAMAGE,
			{ canParry = true, canBlock = true, unblockable = true },
			player
		)

		if hitResult ~= "Parried" then
			victim:BreakDefense()
			victim:SetState("Stunned", DOWNSLAM_STUN, true)
		end
	end

	-- clear air pair
	AirStates[character] = nil
	AirStates[victimModel] = nil
end

DownslamRemote.OnServerEvent:Connect(doDownslam)

-- action t chasing, if you knockback and press T you chase them super cool ngl
ActionTRemote.OnServerEvent:Connect(function(player: Player)
	local character = player.Character
	if not character then return end

	local entity = Entities[character]
	if not entity or entity.State == "Stunned" then return end

	-- if you're in air combo right now, action t becomes downslam
	if AirStates[character] then
		doDownslam(player)
		return
	end

	-- only allowed after m4 hit and only for a short time
	local extend = ComboExtend[player]
	if not extend or extend.Expires <= os.clock() then return end

	local target = extend.Target
	if not target or not target.Parent then return end

	local root = character:FindFirstChild("HumanoidRootPart")
	local targetRoot = target:FindFirstChild("HumanoidRootPart")
	if not root or not targetRoot then return end

	-- stop victim knockback so chase doesnt fight it
	stopKnockback(target)
	clearForces(target)
	targetRoot.AssemblyLinearVelocity = Vector3.zero

	-- stop attacker too
	clearForces(character)
	root.AssemblyLinearVelocity = Vector3.zero

	-- chase to a point right in front of the target based on our directioin to them
	local dir = targetRoot.Position - root.Position
	if dir.Magnitude < 0.1 then return end
	dir = dir.Unit

	local STOP_DISTANCE = 2.5
	local stopPos = targetRoot.Position - dir * STOP_DISTANCE
	local attackerCF = CFrame.lookAt(stopPos, targetRoot.Position)

	-- server owns the snap so it looks same for everyone
	pcall(function() root:SetNetworkOwner(nil) end)
	root.Anchored = true

	local tween = TweenService:Create(
		root,
		TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = attackerCF }
	)

	tween:Play()
	tween.Completed:Once(function()
		if not root or not root.Parent then return end
		root.Anchored = false
		root.AssemblyLinearVelocity = Vector3.zero

		entity:SetState("Attacking", 0.4, true)
		ComboExtend[player] = nil

		local targetEnt = registerEntity(target)
		if not targetEnt then return end

		-- chase hit has no knockback, just dmg + stun if it lands
		local hitResult = resolveHit(
			entity,
			targetEnt,
			CHASE_DAMAGE,
			{ canParry = true, canBlock = true, unblockable = false },
			player
		)

		if hitResult ~= "Parried" and hitResult ~= "Blocked" then
			targetEnt:SetState("Stunned", CHASE_STUN, true)
		end
	end)
end)

-- dashkick
DashKickRemote.OnServerEvent:Connect(function(player: Player, direction: Vector3)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local attackerEntity = character and Entities[character]
	if not root or not humanoid or not attackerEntity then return end
	if attackerEntity.State == "Stunned" then return end
	if typeof(direction) ~= "Vector3" or direction.Magnitude < 0.1 then return end

	-- server air check floor can lag a bit so we also check state
	local st = humanoid:GetState()
	local isAir = humanoid.FloorMaterial == Enum.Material.Air
		or st == Enum.HumanoidStateType.Jumping
		or st == Enum.HumanoidStateType.Freefall
		or st == Enum.HumanoidStateType.FallingDown

	if not isAir then return end
	direction = direction.Unit

	-- cancel old dash if it exists prevents stacked heartbeat conns so its optimization stuff
	local old = ActiveAirDash[player]
	if old then
		if old.Conn then old.Conn:Disconnect() end
		if old.Tween then pcall(function() old.Tween:Cancel() end) end
		ActiveAirDash[player] = nil
	end

	attackerEntity:SetState("Attacking", 0.5, true)

	local BASE_DIST = 30
	local EXTEND_DIST = 50
	local DASH_DURATION = 0.25
	local STOP_OFFSET = 2

	local PROX_RADIUS = 6
	local FRONT_DEPTH = 7
	local FRONT_SIZE = Vector3.new(7, 7, FRONT_DEPTH)

	-- ray used for extend check + wall clip
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { character }
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	-- overlap used for hit confirm boxes
	local overlap = OverlapParams.new()
	overlap.FilterDescendantsInstances = { character }
	overlap.FilterType = Enum.RaycastFilterType.Exclude

	-- extend only if you're actually aiming at a humanoid target so does not have to be exact
	local chosenDist = BASE_DIST
	local extendHit = workspace:Raycast(root.Position, direction * EXTEND_DIST, rayParams)
	if extendHit and extendHit.Instance then
		local model = extendHit.Instance:FindFirstAncestorOfClass("Model")
		if model and model ~= character and model:FindFirstChildOfClass("Humanoid") then
			local distTo = (extendHit.Position - root.Position).Magnitude
			chosenDist = math.clamp(distTo - STOP_OFFSET, BASE_DIST, EXTEND_DIST)
		end
	end

	-- dont go through walls without this you either fling or go thoru a wall
	local wallHit = workspace:Raycast(root.Position, direction * chosenDist, rayParams)
	if wallHit then
		chosenDist = math.max(0, (wallHit.Position - root.Position).Magnitude - STOP_OFFSET)
	end

	local targetPos = root.Position + direction * chosenDist
	local targetCF = CFrame.new(targetPos, targetPos + direction)

	-- anchor + tween so dash looks same for everyone
	pcall(function() root:SetNetworkOwner(nil) end)
	root.AssemblyLinearVelocity = Vector3.zero
	root.Anchored = true

	local tween = TweenService:Create(
		root,
		TweenInfo.new(DASH_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = targetCF }
	)

	local dashState = {
		Hit = false,
		Tween = tween,
		Conn = nil,
		Expire = os.clock() + 1.2,
	}
	ActiveAirDash[player] = dashState

	local function cleanup()
		if dashState.Conn then dashState.Conn:Disconnect() end
		if ActiveAirDash[player] == dashState then
			ActiveAirDash[player] = nil
		end
	end

	local function confirmHit(victimModel: Model)
		if dashState.Hit then return end
		dashState.Hit = true

		if dashState.Tween then pcall(function() dashState.Tween:Cancel() end) end
		root.Anchored = false
		root.AssemblyLinearVelocity = Vector3.zero

		-- snap to a nice stop point in front of target does not have to be infront facing each other just infrfont
		local vRoot = victimModel:FindFirstChild("HumanoidRootPart")
		if vRoot then
			local d = (vRoot.Position - root.Position)
			if d.Magnitude > 0.1 then
				d = d.Unit
				local stopPos = vRoot.Position - d * STOP_OFFSET
				root.CFrame = CFrame.lookAt(stopPos, vRoot.Position)
			end
		end

		local victim = registerEntity(victimModel)
		if victim then
			local hitResult = resolveHit(
				attackerEntity,
				victim,
				DASHKICK_DAMAGE,
				{ canParry = true, canBlock = true, unblockable = false },
				player
			)

			if hitResult ~= "Parried" and hitResult ~= "Blocked" then
				victim:SetState("Stunned", DASHKICK_STUN, true)
			end
		end

		cleanup()
	end

	tween:Play()

	-- heartbeat hit confirm while dashing front box first, then prox fallback
	dashState.Conn = RunService.Heartbeat:Connect(function()
		if not character.Parent or not root.Parent then cleanup(); return end

		local s = humanoid:GetState()
		local stillAir = humanoid.FloorMaterial == Enum.Material.Air
			or s == Enum.HumanoidStateType.Jumping
			or s == Enum.HumanoidStateType.Freefall
			or s == Enum.HumanoidStateType.FallingDown

		if not stillAir or os.clock() > dashState.Expire then cleanup(); return end
		if dashState.Hit then cleanup(); return end

		-- front box check (aimed hits)
		local forward = root.CFrame.LookVector.Unit
		local boxCF = CFrame.new(root.Position + forward * (FRONT_DEPTH * 0.5), root.Position + forward)
		local partsFront = workspace:GetPartBoundsInBox(boxCF, FRONT_SIZE, overlap)

		for _, part in ipairs(partsFront) do
			local model = part:FindFirstAncestorOfClass("Model")
			if model and model ~= character and model:FindFirstChildOfClass("Humanoid") then
				confirmHit(model)
				return
			end
		end

		-- prox check (helps if you barely clip them)
		local proxSize = Vector3.new(PROX_RADIUS * 2, PROX_RADIUS * 2, PROX_RADIUS * 2)
		local partsNear = workspace:GetPartBoundsInBox(CFrame.new(root.Position), proxSize, overlap)

		local nearest: Model?
		local nearestDist: number?

		for _, part in ipairs(partsNear) do
			local model = part:FindFirstAncestorOfClass("Model")
			if model and model ~= character and model:FindFirstChildOfClass("Humanoid") then
				local vRoot2 = model:FindFirstChild("HumanoidRootPart")
				if vRoot2 then
					local dist = (vRoot2.Position - root.Position).Magnitude
					if dist <= PROX_RADIUS and (not nearestDist or dist < nearestDist) then
						nearest = model
						nearestDist = dist
					end
				end
			end
		end

		if nearest then
			confirmHit(nearest)
		end
	end)

	-- safety: always unanchor even if tween ends naturally so yeah your not stuck
	tween.Completed:Once(function()
		if root and root.Parent then
			root.Anchored = false
			root.AssemblyLinearVelocity = Vector3.zero
		end
	end)
end)

-- auto register humanoid models that spawn in workspace (good for npc dummies)
workspace.ChildAdded:Connect(function(child)
	if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then
		registerEntity(child)
	end
end)
