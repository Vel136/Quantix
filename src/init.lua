-- Quantix.lua [Stats that stack exactly as intended]
-- v1.1.0
--[[
	Copyright (c) 2026 VeDevelopment. All rights reserved.
	Proprietary software. Unauthorized use, copying, or distribution is strictly prohibited.
]]

local Identity = "StatController"

-- ─── Services ────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ─── Modules ─────────────────────────────────────────────────────────────────

local Signal        = require(ReplicatedStorage.Shared.Modules.Utilities.Signal)
local ModifierTypes = require(ReplicatedStorage.Shared.Modules.Utilities.Quantix.ModifierTypes)

-- ─── Constants ───────────────────────────────────────────────────────────────

local SOURCE_TYPES = {
	Attachment = "Attachment",
	Ammo       = "Ammo",
	Perk       = "Perk",
	State      = "State",
	System     = "System",
	Ballistics = "Ballistics",
}

local SOURCE_ID_ALL = "__all"

-- ─── Internal helpers ────────────────────────────────────────────────────────

local function _deepCopy(t: any): any
	local copy = {}
	for k, v in t do
		copy[k] = type(v) == "table" and _deepCopy(v) or v
	end
	return copy
end

--- Recursively flattens nested weapon data into dot-separated stat keys.
--- { Spread = { Base = 2.5 } } → { ["Spread.Base"] = 2.5 }
--- Only numeric leaf values are kept.
local function _flatten(t: any, out: { [string]: number }, prefix: string?)
	for k, v in t do
		local key = prefix and (prefix .. "." .. k) or tostring(k)
		if type(v) == "number" then
			out[key] = v
		elseif type(v) == "table" then
			_flatten(v, out, key)
		end
	end
end

local function _getPath(root: any, parts: { string }): any
	local cur = root
	for i = 1, #parts do
		if type(cur) ~= "table" then return nil end
		cur = cur[parts[i]]
	end
	return cur
end

local function _setPath(root: any, parts: { string }, value: any)
	local cur = root
	local n   = #parts
	for i = 1, n - 1 do
		local seg = parts[i]
		if type(cur[seg]) ~= "table" then cur[seg] = {} end
		cur = cur[seg]
	end
	cur[parts[n]] = value
end

local _idCounter = 0
local function _newId(): string
	_idCounter += 1
	return string.format("MOD_%08X", _idCounter)
end

local function _accToString(acc: any): string
	if type(acc) ~= "table" then
		return tostring(acc)
	end
	local parts = {}
	for k, v in acc do
		if type(v) == "table" then
			local inner = {}
			for ik, iv in v do
				table.insert(inner, tostring(ik) .. "=" .. tostring(iv))
			end
			table.insert(parts, tostring(k) .. "={" .. table.concat(inner, ", ") .. "}")
		else
			table.insert(parts, tostring(k) .. "=" .. tostring(v))
		end
	end
	table.sort(parts)
	return "{ " .. table.concat(parts, ", ") .. " }"
end

-- ─── Module ──────────────────────────────────────────────────────────────────

local StatController   = {}
StatController.__index = StatController
StatController.__type  = Identity

-- ─── Index management ────────────────────────────────────────────────────────

function StatController._IndexAdd(self: StatController, mod: any)
	local statBucket = self._byStat[mod.Stat]
	if not statBucket then
		statBucket = {}
		self._byStat[mod.Stat] = statBucket
	end
	statBucket[mod.Id] = mod

	local srcKey    = mod.Source or "__unknown"
	local sidKey    = tostring(mod.SourceId or SOURCE_ID_ALL)
	local srcBucket = self._bySource[srcKey]
	if not srcBucket then
		srcBucket = {}
		self._bySource[srcKey] = srcBucket
	end
	local sidBucket = srcBucket[sidKey]
	if not sidBucket then
		sidBucket = {}
		srcBucket[sidKey] = sidBucket
	end
	sidBucket[mod.Id] = mod

	self._byId[mod.Id] = mod

	if mod.Condition then
		self._hasCondition[mod.Stat] = true
	end
end

function StatController._IndexRemove(self: StatController, mod: any)
	local statBucket = self._byStat[mod.Stat]
	if statBucket then
		statBucket[mod.Id] = nil
		if not next(statBucket) then
			self._byStat[mod.Stat] = nil
		end
	end

	local srcKey    = mod.Source or "__unknown"
	local sidKey    = tostring(mod.SourceId or SOURCE_ID_ALL)
	local srcBucket = self._bySource[srcKey]
	if srcBucket then
		local sidBucket = srcBucket[sidKey]
		if sidBucket then
			sidBucket[mod.Id] = nil
			if not next(sidBucket) then
				srcBucket[sidKey] = nil
			end
		end
		if not next(srcBucket) then
			self._bySource[srcKey] = nil
		end
	end

	self._byId[mod.Id] = nil

	if mod.Condition then
		local stillHas = false
		for _, m in self._byStat[mod.Stat] or {} do
			if m.Condition then
				stillHas = true
				break
			end
		end
		if not stillHas then
			self._hasCondition[mod.Stat] = nil
		end
	end
end

-- ─── Cache ───────────────────────────────────────────────────────────────────

function StatController._Invalidate(self: StatController, statName: string)
	self._cache[statName] = nil
end

function StatController._InvalidateAll(self: StatController)
	table.clear(self._cache)
end

-- ─── Batch ───────────────────────────────────────────────────────────────────

function StatController.BeginBatch(self: StatController)
	if self._batching then
		warn("[StatController] BeginBatch called inside an active batch — ignored")
		return
	end
	self._batching        = true
	self._pendingChanges  = {}
	self._pendingAdded    = {}
	self._pendingRemoved  = {}
end

function StatController.EndBatch(self: StatController)
	if not self._batching then
		warn("[StatController] EndBatch called without an active batch — ignored")
		return
	end
	self._batching = false

	for statName, oldValue in self._pendingChanges do
		local newValue = self:_Evaluate(statName)
		if newValue ~= oldValue then
			self.Signals.OnStatChanged:Fire(statName, newValue, oldValue)
		end
	end

	for _, mod in self._pendingAdded do
		self.Signals.OnModifierAdded:Fire(mod)
	end

	for _, id in self._pendingRemoved do
		self.Signals.OnModifierRemoved:Fire(id)
	end

	self._pendingChanges = nil
	self._pendingAdded   = nil
	self._pendingRemoved = nil

	self.Signals.OnBatchEnd:Fire()
end

function StatController.Batch(self: StatController, fn: () -> ())
	self:BeginBatch()
	local ok, err = pcall(fn)
	self:EndBatch()
	if not ok then
		error(err, 2)
	end
end

-- ─── Signal helpers ───────────────────────────────────────────────────────────

function StatController._TrackChange(self: StatController, statName: string): any
	local current = self:_Evaluate(statName)
	if self._batching and self._pendingChanges[statName] == nil then
		self._pendingChanges[statName] = current
	end
	return current
end

function StatController._FireStatChanged(self: StatController, statName: string, new: any, old: any)
	if not self._batching then
		self.Signals.OnStatChanged:Fire(statName, new, old)
	end
end

function StatController._FireModifierAdded(self: StatController, mod: any)
	if self._batching then
		table.insert(self._pendingAdded, mod)
	else
		self.Signals.OnModifierAdded:Fire(mod)
	end
end

function StatController._FireModifierRemoved(self: StatController, id: string)
	if self._batching then
		table.insert(self._pendingRemoved, id)
	else
		self.Signals.OnModifierRemoved:Fire(id)
	end
end

-- ─── Evaluation ──────────────────────────────────────────────────────────────

--- Collects active modifiers for a stat and delegates to ModifierTypes.Evaluate.
--- Supports both numeric and table base values.
function StatController._Evaluate(self: StatController, statName: string): any
	if self._cache[statName] ~= nil then
		return self._cache[statName]
	end

	local base = self._base[statName]
	if base == nil then
		warn(string.format("[StatController] _Evaluate: stat '%s' has no base value", statName))
		return nil
	end

	local activeMods = self:_CollectActive(statName)
	local r          = ModifierTypes.Evaluate(base, activeMods)

	-- Only cache results that have no condition gates (conditions are runtime-dependent)
	if not self._hasCondition[statName] then
		self._cache[statName] = r.final
	end

	-- Write result directly into the live data table
	if self._current then
		local parts = self._statParts[statName]
		if not parts then
			parts = string.split(statName, ".")
			self._statParts[statName] = parts
		end
		_setPath(self._current, parts, r.final)
	end

	return r.final
end

--- Returns true if a modifier is suppressed by an active block. A source can be
--- blocked broadly (all SourceIds) via the SOURCE_ID_ALL key, or for a specific
--- SourceId. Either match suppresses the modifier — non-destructively; the mod
--- stays indexed and is restored the moment the block is lifted.
function StatController._IsModBlocked(self: StatController, mod: any): boolean
	local blockedSids = self._blocked[mod.Source or "__unknown"]
	if not blockedSids then return false end
	if blockedSids[SOURCE_ID_ALL] then return true end
	return blockedSids[tostring(mod.SourceId or SOURCE_ID_ALL)] == true
end

function StatController._CollectActive(self: StatController, statName: string): { any }
	local active = {}
	for _, mod in self._byStat[statName] or {} do
		if (not mod.Condition or mod.Condition()) and not self:_IsModBlocked(mod) then
			table.insert(active, mod)
		end
	end
	return active
end

-- ─── Public: Behavior evaluation ─────────────────────────────────────────────

--[[
	Evaluates behavior modifiers for a given behavior name/key.

	@param behaviorKey  string   Key used to look up behavior modifiers (e.g. behavior name)
	@param baseBehavior table    The base behavior definition table

	Returns:
	  finalBehavior : table   — merged behavior table
	  hooks         : table   — { [eventName] = { fn, ... } } collected hook lists
]]
function StatController.Evaluate(self, behaviorKey, baseBehavior)
	local final = self:_Evaluate(behaviorKey) or baseBehavior
	local hooks = (final and final._Hooks) or {}

	if final and final._Hooks then
		final = table.clone(final)
		final._Hooks = nil
	end

	return final, hooks
end

-- ─── Public: Query ───────────────────────────────────────────────────────────

function StatController.Get(self: StatController, statName: string): any
	return self:_Evaluate(statName)
end

function StatController.GetBase(self: StatController, statName: string): any
	return self._base[statName]
end

function StatController.GetAll(self: StatController): { [string]: any }
	local out = {}
	for statName in self._base do
		out[statName] = self:_Evaluate(statName)
	end
	return out
end

function StatController.GetGroup(self: StatController, prefix: string): { [string]: any }
	local out    = {}
	local search = prefix .. "."
	for statName in self._base do
		if string.sub(statName, 1, #search) == search then
			out[string.sub(statName, #search + 1)] = self:_Evaluate(statName)
		end
	end
	return out
end

-- ─── Public: Modifier management ─────────────────────────────────────────────

function StatController.AddModifier(self: StatController, modifier: any): string
	assert(modifier.Stat,         "[StatController] AddModifier: Stat is required")
	assert(modifier.Type,         "[StatController] AddModifier: Type is required")
	assert(modifier.Value ~= nil, "[StatController] AddModifier: Value is required")
	assert(ModifierTypes.Has(modifier.Type),
		string.format("[StatController] AddModifier: unknown type '%s'", tostring(modifier.Type)))

	local id    = _newId()
	modifier.Id = id

	local old = self:_TrackChange(modifier.Stat)

	self:_IndexAdd(modifier)
	self:_Invalidate(modifier.Stat)

	local new = self:_Evaluate(modifier.Stat)

	if new ~= old then
		self:_FireStatChanged(modifier.Stat, new, old)
	end

	self:_FireModifierAdded(modifier)

	return id
end

function StatController.RemoveModifier(self: StatController, modifierId: string): boolean
	local mod = self._byId[modifierId]
	if not mod then return false end

	local old = self:_TrackChange(mod.Stat)

	self:_IndexRemove(mod)
	self:_Invalidate(mod.Stat)

	local new = self:_Evaluate(mod.Stat)

	if new ~= old then
		self:_FireStatChanged(mod.Stat, new, old)
	end

	self:_FireModifierRemoved(modifierId)

	return true
end

function StatController.RemoveBySource(self: StatController, source: string, sourceId: (string | number)?): number
	local srcBucket = self._bySource[source]
	if not srcBucket then return 0 end

	local ids = {}
	if sourceId ~= nil then
		local sidKey    = tostring(sourceId)
		local sidBucket = srcBucket[sidKey]
		if sidBucket then
			for id in sidBucket do
				table.insert(ids, id)
			end
		end
	else
		for _, sidBucket in srcBucket do
			for id in sidBucket do
				table.insert(ids, id)
			end
		end
	end

	self:Batch(function()
		for _, id in ids do
			self:RemoveModifier(id)
		end
	end)

	return #ids
end

--- Collects the distinct stat names touched by modifiers under a source
--- (optionally a specific sourceId). Used to invalidate/refire exactly the
--- stats a block or unblock affects.
function StatController._StatsForSource(self: StatController, source: string, sourceId: (string | number)?): { [string]: true }
	local stats     = {}
	local srcBucket = self._bySource[source]
	if not srcBucket then return stats end

	local function scan(sidBucket: any)
		for _, mod in sidBucket do
			stats[mod.Stat] = true
		end
	end

	if sourceId ~= nil then
		local sidBucket = srcBucket[tostring(sourceId)]
		if sidBucket then scan(sidBucket) end
	else
		for _, sidBucket in srcBucket do
			scan(sidBucket)
		end
	end
	return stats
end

--- Suppresses modifiers from a source (optionally a specific sourceId) during
--- evaluation WITHOUT removing them. Reversible via Unblock — the modifiers stay
--- indexed and are restored intact when unblocked. Also suppresses any future
--- modifiers added under the same source/sourceId while the block is active.
---
--- Block(source)            → blocks every modifier from that source.
--- Block(source, sourceId)  → blocks only that source/sourceId pair.
---
--- e.g. gun.StatController:Block("Ammo") makes the flamethrower ignore all
--- ammo-type modifiers while keeping them attached.
function StatController.Block(self: StatController, source: string, sourceId: (string | number)?)
	assert(type(source) == "string" and #source > 0, "[StatController] Block: source must be a non-empty string")

	local sidKey       = sourceId ~= nil and tostring(sourceId) or SOURCE_ID_ALL
	local blockedSids  = self._blocked[source]
	if blockedSids and blockedSids[sidKey] then
		return -- already blocked; no-op (keeps Block idempotent)
	end
	if not blockedSids then
		blockedSids        = {}
		self._blocked[source] = blockedSids
	end

	-- Stats affected are computed BEFORE flipping the block on, so we capture the
	-- current (unblocked) values to compare against.
	local affected = self:_StatsForSource(source, sourceId)

	self:Batch(function()
		for statName in affected do
			self:_TrackChange(statName)
		end
		blockedSids[sidKey] = true
		for statName in affected do
			self:_Invalidate(statName)
		end
	end)
end

--- Lifts a block set by Block, restoring the source's modifiers to evaluation.
--- Returns true if a block was actually removed.
function StatController.Unblock(self: StatController, source: string, sourceId: (string | number)?): boolean
	local blockedSids = self._blocked[source]
	if not blockedSids then return false end

	local sidKey = sourceId ~= nil and tostring(sourceId) or SOURCE_ID_ALL
	if not blockedSids[sidKey] then return false end

	local affected = self:_StatsForSource(source, sourceId)

	self:Batch(function()
		for statName in affected do
			self:_TrackChange(statName)
		end
		blockedSids[sidKey] = nil
		if not next(blockedSids) then
			self._blocked[source] = nil
		end
		for statName in affected do
			self:_Invalidate(statName)
		end
	end)
	return true
end

--- Returns whether a source (optionally a specific sourceId) is currently blocked.
--- A specific sourceId counts as blocked if a broad (all-sourceId) block exists.
function StatController.IsBlocked(self: StatController, source: string, sourceId: (string | number)?): boolean
	local blockedSids = self._blocked[source]
	if not blockedSids then return false end
	if blockedSids[SOURCE_ID_ALL] then return true end
	if sourceId == nil then return false end
	return blockedSids[tostring(sourceId)] == true
end

function StatController.ReplaceBySource(self: StatController, source: string, sourceId: (string | number)?, newModifiers: { any }): { string }
	local ids = {}
	self:Batch(function()
		self:RemoveBySource(source, sourceId)
		for _, mod in newModifiers do
			table.insert(ids, self:AddModifier(mod))
		end
	end)
	return ids
end

function StatController.ClearAll(self: StatController)
	self:Batch(function()
		local ids = {}
		for id in self._byId do
			table.insert(ids, id)
		end
		for _, id in ids do
			self:RemoveModifier(id)
		end
	end)
end

-- ─── Public: Base mutation ────────────────────────────────────────────────────

function StatController.SetBase(self: StatController, statName: string, value: any)
	local old = self:_TrackChange(statName)
	self._base[statName] = value
	self:_Invalidate(statName)
	local new = self:_Evaluate(statName)
	if new ~= old then
		self:_FireStatChanged(statName, new, old)
	end
end

-- ─── Public: Behavior base registration ──────────────────────────────────────

--[[
	Registers a base behavior table under a key so that behavior modifiers
	can be added via AddModifier with Stat = behaviorKey.
	Call this once per behavior during setup (e.g. when the gun is created).

	@param behaviorKey  string   Unique key, typically the behavior name
	@param baseBehavior table    The unmodified base behavior definition
]]
function StatController.RegisterBehavior(self: StatController, behaviorKey: string, baseBehavior: any)
	assert(type(behaviorKey) == "string" and #behaviorKey > 0,
		"[StatController] RegisterBehavior: behaviorKey must be a non-empty string")
	assert(type(baseBehavior) == "table",
		"[StatController] RegisterBehavior: baseBehavior must be a table")
	self._base[behaviorKey] = baseBehavior
end

-- ─── Public: Modifier query ───────────────────────────────────────────────────

function StatController.GetModifiersForStat(self: StatController, statName: string): { any }
	local out = {}
	for _, mod in self._byStat[statName] or {} do
		table.insert(out, mod)
	end
	return out
end

function StatController.GetModifiers(self: StatController): { any }
	local out = {}
	for _, mod in self._byId do
		table.insert(out, mod)
	end
	return out
end

function StatController.GetModifierById(self: StatController, modifierId: string): any
	return self._byId[modifierId]
end

-- ─── Public: Debug / Trace ───────────────────────────────────────────────────

function StatController.Trace(self: StatController, statName: string): string
	local base = self._base[statName]
	if base == nil then
		return string.format("[StatController] Trace: stat '%s' has no base value", statName)
	end

	local lines      = {}
	local activeMods = self:_CollectActive(statName)
	local skipped    = {}
	local blocked    = {}

	for _, mod in self._byStat[statName] or {} do
		if self:_IsModBlocked(mod) then
			table.insert(blocked, mod)
		elseif mod.Condition and not mod.Condition() then
			table.insert(skipped, mod)
		end
	end

	local baseDisplay = type(base) == "table" and "[table]" or tostring(base)
	table.insert(lines, string.format("Stat:  %s", statName))
	table.insert(lines, string.format("Base:  %s", baseDisplay))
	table.insert(lines, string.format("Active modifiers: %d", #activeMods))

	for _, mod in activeMods do
		local label    = string.format("%s/%s", mod.Source or "?", tostring(mod.SourceId or ""))
		local valDisplay = type(mod.Value) == "table" and "[table]" or tostring(mod.Value)
		table.insert(lines, string.format("  [%s] %s  value=%s  priority=%d%s",
			mod.Type, label, valDisplay, mod.Priority or 0,
			mod.MultGroup and ("  group=" .. mod.MultGroup) or ""))
	end

	for _, mod in skipped do
		local label = string.format("%s/%s", mod.Source or "?", tostring(mod.SourceId or ""))
		table.insert(lines, string.format("  [SKIPPED condition] [%s] %s", mod.Type, label))
	end

	for _, mod in blocked do
		local label = string.format("%s/%s", mod.Source or "?", tostring(mod.SourceId or ""))
		table.insert(lines, string.format("  [BLOCKED source] [%s] %s", mod.Type, label))
	end

	local r = ModifierTypes.Evaluate(base, activeMods)
	table.insert(lines, "")

	for _, phase in ModifierTypes.Phases do
		local phaseAccs = r.phases[phase]
		if not phaseAccs then continue end
		local hasAny = false
		for _ in phaseAccs do hasAny = true break end
		if hasAny then
			table.insert(lines, string.format("Phase [%s]:", phase))
			for typeName, acc in phaseAccs do
				table.insert(lines, string.format("  %s: %s", typeName, _accToString(acc)))
			end
		end
	end

	local finalDisplay = type(r.final) == "table" and "[table]" or tostring(r.final)
	table.insert(lines, string.format("= Final: %s", finalDisplay))

	return table.concat(lines, "\n")
end

function StatController.DebugDump(self: StatController)
	print("[StatController] ── Debug dump ──────────────────────────")
	for statName in self._base do
		local base  = self._base[statName]
		local final = self:_Evaluate(statName)
		local baseStr  = type(base)  == "table" and "[table]" or string.format("%-8g", base)
		local finalStr = type(final) == "table" and "[table]" or tostring(final)
		print(string.format("  %-28s  base=%-8s  final=%s", statName, baseStr, finalStr))
	end

	local modCount = 0
	for _ in self._byId do modCount += 1 end

	print(string.format("[StatController] ── Modifiers (%d total) ────────────────", modCount))
	for id, mod in self._byId do
		local valStr = type(mod.Value) == "table" and "[table]" or string.format("%-8g", mod.Value)
		print(string.format("  [%s]  stat=%-20s  type=%-18s  value=%-8s  source=%s/%s",
			id, mod.Stat, mod.Type, valStr, mod.Source or "?", tostring(mod.SourceId or "?")))
	end
	print("[StatController] ────────────────────────────────────────")
end

-- ─── Lifecycle ───────────────────────────────────────────────────────────────

function StatController.Destroy(self: StatController)
	self.Signals.OnStatChanged:Destroy()
	self.Signals.OnModifierAdded:Destroy()
	self.Signals.OnModifierRemoved:Destroy()
	self.Signals.OnBatchEnd:Destroy()

	table.clear(self._byStat)
	table.clear(self._bySource)
	table.clear(self._byId)
	table.clear(self._cache)
	table.clear(self._base)
	table.clear(self._hasCondition)
	table.clear(self._statParts)
	table.clear(self._blocked)
	self._current = nil
end

-- ─── Constructor ─────────────────────────────────────────────────────────────

local module = {}

module.Types   = ModifierTypes.Types
module.Sources = SOURCE_TYPES

--[[
	Creates a new StatController.

	@param data  any   Weapon data table. Numeric leaf values are flattened into
	                   dot-path stat keys. Pass an empty table if registering
	                   stats manually via SetBase/RegisterBehavior.
]]
function module.new(data: any): StatController
	assert(data, "[StatController] new: data is required")

	local self = setmetatable({}, StatController)

	self._base           = {}
	self._byStat         = {}
	self._bySource       = {}
	self._byId           = {}
	self._cache          = {}
	self._hasCondition   = {}
	self._statParts      = {}
	self._blocked        = {}
	self._current        = data
	self._batching       = false
	self._pendingChanges = nil
	self._pendingAdded   = nil
	self._pendingRemoved = nil

	_flatten(_deepCopy(data), self._base)

	self.Signals = {
		OnStatChanged     = Signal.new(),
		OnModifierAdded   = Signal.new(),
		OnModifierRemoved = Signal.new(),
		OnBatchEnd        = Signal.new(),
	}

	return self
end

-- ─── Types ───────────────────────────────────────────────────────────────────

export type Modifier = {
	Id        : string,
	Stat      : string,
	Type      : string,
	Value     : any,        -- number for stat modifiers, table for behavior modifiers
	Source    : string,
	SourceId  : (string | number)?,
	Priority  : number?,
	Condition : ((...any) -> boolean)?,
	MultGroup : string?,
	Tag       : string?,    -- used by BehaviorExclusive
}

export type StatControllerSignals = {
	OnStatChanged     : Signal.Signal<(statName: string, newValue: any, oldValue: any) -> ()>,
	OnModifierAdded   : Signal.Signal<(modifier: Modifier) -> ()>,
	OnModifierRemoved : Signal.Signal<(modifierId: string) -> ()>,
	OnBatchEnd        : Signal.Signal<() -> ()>,
}

export type StatController = typeof(setmetatable({} :: {
	_base           : { [string]: any },
	_byStat         : { [string]: { [string]: Modifier } },
	_bySource       : { [string]: { [string]: { [string]: Modifier } } },
	_byId           : { [string]: Modifier },
	_cache          : { [string]: any },
	_hasCondition   : { [string]: true },
	_statParts      : { [string]: { string } },
	_blocked        : { [string]: { [string]: true } },
	_current        : any?,
	_batching       : boolean,
	_pendingChanges : { [string]: any }?,
	_pendingAdded   : { Modifier }?,
	_pendingRemoved : { string }?,
	Signals         : StatControllerSignals,
}, { __index = StatController }))

return setmetatable(module, { __index = StatController })