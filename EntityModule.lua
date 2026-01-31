local EntityService = {}
EntityService.__index = EntityService

-- higher number is more important so u cant do smth less important while in a big important state
local StatePriority = {
	Idle = 0,
	Attacking = 1,
	Blocking = 1,

	ParryWindow = 2,
	Uppercut = 2,

	Stunned = 3,
}

function EntityService.new(model)
	local self = setmetatable({}, EntityService)
	self.Model = model
	self.Humanoid = model:WaitForChild("Humanoid")

	-- making a string value to keep track of what the guy is doing
	local stateVal = model:FindFirstChild("ActionState")
	if not stateVal then
		stateVal = Instance.new("StringValue")
		stateVal.Name = "ActionState"
		stateVal.Value = "Idle"
		stateVal.Parent = model
	end

	self.StateValue = stateVal
	self.State = stateVal.Value
	self.DefaultWalkSpeed = self.Humanoid.WalkSpeed

	self._stateToken = 0 -- stops old stuff from breaking new stuff

	stateVal.Changed:Connect(function(newVal)
		self.State = newVal
	end)

	return self
end

function EntityService:GetRoot()
	-- gets the main part of the body
	return self.Model.PrimaryPart or self.Model:FindFirstChild("HumanoidRootPart")
end

function EntityService:CanAct()
	-- check if ur not stunned so u can do smth
	return self.State ~= "Stunned"
end

function EntityService:SetState(newState, duration, force)
	local curPri = StatePriority[self.State] or 0
	local newPri = StatePriority[newState] or 0

	-- if forced it just works otherwise check if ur allowed to change state
	if not force then
		if self.State == "Stunned" and newState ~= "Idle" then
			return false
		end

		-- dont let weak states stop strong ones
		if newState ~= "Idle" and newPri < curPri then
			return false
		end
	end

	self._stateToken += 1
	local myToken = self._stateToken

	self.State = newState
	self.StateValue.Value = newState

	-- makes u slow or fast based on what u do
	if newState == "Attacking" or newState == "Blocking" or newState == "ParryWindow" then
		self.Humanoid.WalkSpeed = 5
	elseif newState == "Stunned" then
		self.Humanoid.WalkSpeed = 0
	else
		self.Humanoid.WalkSpeed = self.DefaultWalkSpeed
	end

	if duration and duration > 0 then
		task.delay(duration, function()
			-- wait a bit then go back to idle if smth else didnt happen
			if self._stateToken == myToken and self.StateValue.Value == newState then
				self:SetState("Idle", nil, true)
			end
		end)
	end

	return true
end

-- stops the blocking or parrying right now
function EntityService:BreakDefense()
	self:SetState("Idle", nil, true)
end

-- handles getting hit and checking for blocks/parries
function EntityService:TakeHit(attackerEntity, damage, options)
	options = options or {}

	local canParry = (options.canParry ~= false)
	local canBlock = (options.canBlock ~= false)
	local unblockable = (options.unblockable == true)
	local chip = options.chip or 0.2

	-- if parry window is on return parried
	if canParry and self.State == "ParryWindow" then
		return "Parried"
	end

	-- if blocking check if move is unblockable
	if canBlock and self.State == "Blocking" then
		if unblockable then
			self:BreakDefense()
			self.Humanoid:TakeDamage(damage)
			return "GuardBroken"
		else
			-- takes a bit of damage even if blocking
			self.Humanoid:TakeDamage(damage * chip)
			return "Blocked"
		end
	end

	-- just a normal hit
	self.Humanoid:TakeDamage(damage)
	return "Hit"
end

function EntityService:ForceDamage(damage)
	-- just hurts the guy no matter what
	if self.Humanoid then
		self.Humanoid:TakeDamage(damage)
	end
end

return EntityService
