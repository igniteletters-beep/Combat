local EntityService = {}
EntityService.__index = EntityService

-- Higher number = stronger state (harder to override)
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

	self._stateToken = 0 -- prevents old timers from overriding newer state

	stateVal.Changed:Connect(function(newVal)
		self.State = newVal
	end)

	return self
end

function EntityService:GetRoot()
	return self.Model.PrimaryPart or self.Model:FindFirstChild("HumanoidRootPart")
end

function EntityService:CanAct()
	return self.State ~= "Stunned"
end

function EntityService:SetState(newState, duration, force)
	local curPri = StatePriority[self.State] or 0
	local newPri = StatePriority[newState] or 0

	-- If stunned, only allow Idle or stronger override (unless force)
	if not force then
		if self.State == "Stunned" and newState ~= "Idle" then
			return false
		end

		-- Don’t allow weaker states to override stronger ones (except Idle)
		if newState ~= "Idle" and newPri < curPri then
			return false
		end
	end

	self._stateToken += 1
	local myToken = self._stateToken

	self.State = newState
	self.StateValue.Value = newState

	-- movement rules
	if newState == "Attacking" or newState == "Blocking" or newState == "ParryWindow" then
		self.Humanoid.WalkSpeed = 5
	elseif newState == "Stunned" then
		self.Humanoid.WalkSpeed = 0
	else
		self.Humanoid.WalkSpeed = self.DefaultWalkSpeed
	end

	if duration and duration > 0 then
		task.delay(duration, function()
			-- only revert if nothing else changed since
			if self._stateToken == myToken and self.StateValue.Value == newState then
				self:SetState("Idle", nil, true)
			end
		end)
	end

	return true
end

-- Break block/parry instantly
function EntityService:BreakDefense()
	self:SetState("Idle", nil, true)
end

-- Central hit resolver:
-- options = {
--   canParry=true/false,
--   canBlock=true/false,
--   unblockable=true/false (breaks block if blocking),
--   chip=0.2 (block chip),
-- }
function EntityService:TakeHit(attackerEntity, damage, options)
	options = options or {}

	local canParry = (options.canParry ~= false)
	local canBlock = (options.canBlock ~= false)
	local unblockable = (options.unblockable == true)
	local chip = options.chip or 0.2

	-- Parry check is handled by the server usually (needs attacker stun),
	-- but we keep this return for consistent logic if you want it.
	if canParry and self.State == "ParryWindow" then
		return "Parried"
	end

	if canBlock and self.State == "Blocking" then
		if unblockable then
			self:BreakDefense()
			self.Humanoid:TakeDamage(damage)
			return "GuardBroken"
		else
			self.Humanoid:TakeDamage(damage * chip)
			return "Blocked"
		end
	end

	self.Humanoid:TakeDamage(damage)
	return "Hit"
end

function EntityService:ForceDamage(damage)
	if self.Humanoid then
		self.Humanoid:TakeDamage(damage)
	end
end

return EntityService
