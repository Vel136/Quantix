-- ModifierTypes.lua
--[[
	Defines all modifier types, their pipeline phases, and evaluation logic.
	StatController imports this and delegates all type-specific behavior here.

	Supports both numeric stat modifiers and table-based behavior modifiers.
	Behavior modifier types (BehaviorOverride, BehaviorDeepMerge, BehaviorHook,
	BehaviorExclusive, BehaviorReplace) allow attachments, ammo types, and perks
	to affect bullet physics and hooks through the same pipeline as stat modifiers.
]]

local Identity = "ModifierTypes"

-- ─── Phase order ─────────────────────────────────────────────────────────────

local PHASE_ORDER = {
	-- Numeric phases
	"SetBase",
	"FlatAdd",
	"AddPercent",
	"Multiply",
	"Override",
	"MinOverride",
	"MaxOverride",
	"Clamp",
	"Lock",
	-- Behavior phases
	"BehaviorReplace",
	"BehaviorOverride",
	"BehaviorDeepMerge",
	"BehaviorHook",
	"BehaviorExclusive",
}

local VALID_PHASES = {}
for i, phase in PHASE_ORDER do
	VALID_PHASES[phase] = i
end

-- ─── Registry ────────────────────────────────────────────────────────────────

local _registry       = {}   -- [typeName] = definition
local _phaseTypeOrder = {}   -- [phase] = { typeName, ... } in registration order
local _accTemplate    = {}   -- [typeName] = accumulator (reused each Evaluate call)

for _, phase in PHASE_ORDER do
	_phaseTypeOrder[phase] = {}
end

local ModifierTypes   = {}
ModifierTypes.__type  = Identity

-- ─── Internal helpers ─────────────────────────────────────────────────────────

local function _rebuildTemplate()
	table.clear(_accTemplate)
	for typeName, def in _registry do
		_accTemplate[typeName] = def.Initial()
	end
end

--- Recursively merges `override` into `base`, returning a fresh table.
local function _deepMerge(base: any, override: any): any
	if type(base) ~= "table" or type(override) ~= "table" then
		return override
	end
	local merged = table.clone(base)
	for k, v in override do
		merged[k] = _deepMerge(merged[k], v)
	end
	return merged
end

--- Builds a snapshot of active accumulators keyed by phase, for Trace output.
--- Called only when needed — not in the hot path.
local function _buildPhaseSnapshot(activeTypes: { [string]: boolean }): { [string]: any }
	local phases = {}
	for typeName in activeTypes do
		local def   = _registry[typeName]
		local phase = def.Phase
		if not phases[phase] then
			phases[phase] = {}
		end
		-- Behavior accumulators hold tables — store a shallow copy for safety
		local acc = _accTemplate[typeName]
		phases[phase][typeName] = type(acc) == "table" and table.clone(acc) or acc
	end
	return phases
end

-- ─── Registration ────────────────────────────────────────────────────────────

function ModifierTypes.Register(typeName: string, definition: any)
	assert(type(typeName) == "string" and #typeName > 0,
		"[ModifierTypes] Register: typeName must be a non-empty string")
	assert(not _registry[typeName],
		string.format("[ModifierTypes] Register: type '%s' is already registered", typeName))
	assert(VALID_PHASES[definition.Phase],
		string.format("[ModifierTypes] Register: unknown phase '%s' for type '%s'",
			tostring(definition.Phase), typeName))
	assert(type(definition.Collect) == "function",
		string.format("[ModifierTypes] Register: Collect must be a function (type '%s')", typeName))
	assert(type(definition.Initial) == "function",
		string.format("[ModifierTypes] Register: Initial must be a function (type '%s')", typeName))
	assert(type(definition.Apply) == "function",
		string.format("[ModifierTypes] Register: Apply must be a function (type '%s')", typeName))
	assert(definition.Reset == nil or type(definition.Reset) == "function",
		string.format("[ModifierTypes] Register: Reset must be a function or nil (type '%s')", typeName))

	_registry[typeName] = definition
	table.insert(_phaseTypeOrder[definition.Phase], typeName)
	_accTemplate[typeName] = definition.Initial()
end

function ModifierTypes.Get(typeName: string): any
	return _registry[typeName]
end

function ModifierTypes.Has(typeName: string): boolean
	return _registry[typeName] ~= nil
end

function ModifierTypes.All(): { string }
	local out = {}
	for _, phase in PHASE_ORDER do
		for _, typeName in _phaseTypeOrder[phase] do
			table.insert(out, typeName)
		end
	end
	return out
end

-- ─── Evaluation ──────────────────────────────────────────────────────────────

--[[
	Runs the full pipeline for a stat given its base value and a list of
	active modifiers (already filtered for condition/scope by caller).

	Supports both numeric base values (stat modifiers) and table base values
	(behavior modifiers). The math.isfinite guard only applies to numeric results.

	Returns:
	  {
	    final  : any,   -- number for stats, table for behavior
	    phases : { [phaseName]: { [typeName]: accumulator } }  -- for Trace
	  }
]]
function ModifierTypes.Evaluate(base: any, activeMods: { any }): any
	-- Determine which types have active mods (skip all others)
	local activeTypes = {}
	for _, mod in activeMods do
		if _registry[mod.Type] and not activeTypes[mod.Type] then
			activeTypes[mod.Type] = true
		end
	end

	-- Reset only active accumulators
	for typeName in activeTypes do
		local def = _registry[typeName]
		local acc = _accTemplate[typeName]
		if def.Reset then
			def.Reset(acc)
		else
			_accTemplate[typeName] = def.Initial()
		end
	end

	-- Collect modifiers into their accumulators
	for _, mod in activeMods do
		local def = _registry[mod.Type]
		if not def then
			warn(string.format("[ModifierTypes] Evaluate: unknown modifier type '%s' — skipped",
				tostring(mod.Type)))
			continue
		end
		def.Collect(_accTemplate[mod.Type], mod)
	end

	-- Check for Lock first — short-circuit if any lock is active (numeric only)
	if activeTypes["Lock"] then
		local lockAcc = _accTemplate["Lock"]
		if lockAcc.active then
			return { final = lockAcc.value, phases = _buildPhaseSnapshot(activeTypes) }
		end
	end

	-- Apply phases in deterministic registration order, skipping idle types
	local result = base

	for _, phase in PHASE_ORDER do
		if phase == "Lock" then continue end

		for _, typeName in _phaseTypeOrder[phase] do
			if activeTypes[typeName] then
				local def = _registry[typeName]
				result = def.Apply(result, _accTemplate[typeName], base)
			end
		end
	end

	-- Guard only applies to numeric results
	if type(result) == "number" and not math.isfinite(result) then
		warn(string.format("[ModifierTypes] Evaluated to invalid number — falling back to base %g", base))
		result = base
	end

	return { final = result, phases = _buildPhaseSnapshot(activeTypes) }
end

-- ─── Numeric modifier type registrations ─────────────────────────────────────

-- ── SetBase ───────────────────────────────────────────────────────────────────
ModifierTypes.Register("SetBase", {
	Phase   = "SetBase",
	Initial = function() return { candidates = {} } end,
	Reset   = function(acc) table.clear(acc.candidates) end,
	Collect = function(acc, mod)
		table.insert(acc.candidates, { Priority = mod.Priority or 0, Value = mod.Value })
	end,
	Apply   = function(result, acc, _base)
		if #acc.candidates == 0 then return result end
		table.sort(acc.candidates, function(a, b) return a.Priority > b.Priority end)
		return acc.candidates[1].Value
	end,
})

-- ── FlatAdd ───────────────────────────────────────────────────────────────────
ModifierTypes.Register("FlatAdd", {
	Phase   = "FlatAdd",
	Initial = function() return { sum = 0 } end,
	Reset   = function(acc) acc.sum = 0 end,
	Collect = function(acc, mod)
		acc.sum += mod.Value
	end,
	Apply   = function(result, acc, _base)
		return result + acc.sum
	end,
})

-- ── AddPercent ────────────────────────────────────────────────────────────────
ModifierTypes.Register("AddPercent", {
	Phase   = "AddPercent",
	Initial = function() return { totalPercent = 0 } end,
	Reset   = function(acc) acc.totalPercent = 0 end,
	Collect = function(acc, mod)
		acc.totalPercent += mod.Value
	end,
	Apply   = function(result, acc, base)
		return result + base * (acc.totalPercent / 100)
	end,
})

-- ── Multiply ──────────────────────────────────────────────────────────────────
ModifierTypes.Register("Multiply", {
	Phase   = "Multiply",
	Initial = function() return { ungroupedSum = 0, groups = {} } end,
	Reset   = function(acc)
		acc.ungroupedSum = 0
		table.clear(acc.groups)
	end,
	Collect = function(acc, mod)
		if mod.MultGroup then
			acc.groups[mod.MultGroup] = (acc.groups[mod.MultGroup] or 1) * mod.Value
		else
			acc.ungroupedSum += mod.Value
		end
	end,
	Apply   = function(result, acc, _base)
		local combined = 1 + acc.ungroupedSum
		for _, prod in acc.groups do
			combined *= prod
		end
		return result * combined
	end,
})

-- ── Override ──────────────────────────────────────────────────────────────────
ModifierTypes.Register("Override", {
	Phase   = "Override",
	Initial = function() return { candidates = {} } end,
	Reset   = function(acc) table.clear(acc.candidates) end,
	Collect = function(acc, mod)
		table.insert(acc.candidates, { Priority = mod.Priority or 0, Value = mod.Value })
	end,
	Apply   = function(result, acc, _base)
		if #acc.candidates == 0 then return result end
		table.sort(acc.candidates, function(a, b) return a.Priority > b.Priority end)
		return acc.candidates[1].Value
	end,
})

-- ── MinOverride ───────────────────────────────────────────────────────────────
ModifierTypes.Register("MinOverride", {
	Phase   = "MinOverride",
	Initial = function() return { threshold = nil } end,
	Reset   = function(acc) acc.threshold = nil end,
	Collect = function(acc, mod)
		acc.threshold = acc.threshold and math.max(acc.threshold, mod.Value) or mod.Value
	end,
	Apply   = function(result, acc, _base)
		if acc.threshold == nil then return result end
		return math.max(result, acc.threshold)
	end,
})

-- ── MaxOverride ───────────────────────────────────────────────────────────────
ModifierTypes.Register("MaxOverride", {
	Phase   = "MaxOverride",
	Initial = function() return { threshold = nil } end,
	Reset   = function(acc) acc.threshold = nil end,
	Collect = function(acc, mod)
		acc.threshold = acc.threshold and math.min(acc.threshold, mod.Value) or mod.Value
	end,
	Apply   = function(result, acc, _base)
		if acc.threshold == nil then return result end
		return math.min(result, acc.threshold)
	end,
})

-- ── ClampMin ──────────────────────────────────────────────────────────────────
ModifierTypes.Register("ClampMin", {
	Phase   = "Clamp",
	Initial = function() return { value = nil } end,
	Reset   = function(acc) acc.value = nil end,
	Collect = function(acc, mod)
		acc.value = acc.value and math.max(acc.value, mod.Value) or mod.Value
	end,
	Apply   = function(result, acc, _base)
		if acc.value == nil then return result end
		return math.max(result, acc.value)
	end,
})

-- ── ClampMax ──────────────────────────────────────────────────────────────────
ModifierTypes.Register("ClampMax", {
	Phase   = "Clamp",
	Initial = function() return { value = nil } end,
	Reset   = function(acc) acc.value = nil end,
	Collect = function(acc, mod)
		acc.value = acc.value and math.min(acc.value, mod.Value) or mod.Value
	end,
	Apply   = function(result, acc, _base)
		if acc.value == nil then return result end
		return math.min(result, acc.value)
	end,
})

-- ── StackUnique ───────────────────────────────────────────────────────────────
ModifierTypes.Register("StackUnique", {
	Phase   = "FlatAdd",
	Initial = function() return { best = {} } end,
	Reset   = function(acc) table.clear(acc.best) end,
	Collect = function(acc, mod)
		local key = mod.Source or "__unknown"
		if not acc.best[key] or mod.Value > acc.best[key] then
			acc.best[key] = mod.Value
		end
	end,
	Apply   = function(result, acc, _base)
		local sum = 0
		for _, v in acc.best do
			sum += v
		end
		return result + sum
	end,
})

-- ── Lock ──────────────────────────────────────────────────────────────────────
ModifierTypes.Register("Lock", {
	Phase   = "Lock",
	Initial = function() return { active = false, value = 0, priority = -math.huge } end,
	Reset   = function(acc)
		acc.active   = false
		acc.value    = 0
		acc.priority = -math.huge
	end,
	Collect = function(acc, mod)
		local p = mod.Priority or 0
		if not acc.active or p > acc.priority then
			acc.active   = true
			acc.value    = mod.Value
			acc.priority = p
		end
	end,
	Apply   = function(result, acc, _base)
		return acc.active and acc.value or result
	end,
})

-- ─── Behavior modifier type registrations ────────────────────────────────────
--[[
	Behavior modifiers operate on a table base value (the behavior definition)
	rather than a number. They mirror what mergeAllModifiers did in VetraNet's
	Client.lua and Server.lua, but now run through the same Quantix pipeline.

	A modifier that affects behavior carries its data in mod.Value as a table:

	  BehaviorReplace:
	    mod.Value = true   -- signals "start merge fresh from this modifier"
	    mod.Priority determines which Replace wins when multiple exist.

	  BehaviorOverride:
	    mod.Value = { MaxPenetrations = 3, Gravity = 0 }
	    Keys are shallow-merged onto the behavior table (last priority wins per key).

	  BehaviorDeepMerge:
	    mod.Value = { MaterialRestitution = { Grass = 0.2 } }
	    Keys are recursively merged — safe for nested config tables.

	  BehaviorHook:
	    mod.Value = { OnPierce = function(ctx, result, velocity) ... end }
	    Multiple hooks for the same event are collected into a list, called in
	    priority order at the matching solver lifecycle moment.

	  BehaviorExclusive:
	    mod.Value  = { ... }   -- same as BehaviorOverride value
	    mod.Tag    = "Scope"   -- only the highest-priority mod per tag applies
	    Prevents multiple Exclusive mods with the same Tag from stacking.
]]

-- ── BehaviorReplace ───────────────────────────────────────────────────────────
-- Signals that merge should start fresh from this modifier's priority point.
-- Highest priority Replace wins. All modifiers with lower priority are ignored.
-- mod.Value = true (the signal itself; actual overrides come from BehaviorOverride)
ModifierTypes.Register("BehaviorReplace", {
	Phase   = "BehaviorReplace",
	Initial = function() return { priority = nil } end,
	Reset   = function(acc) acc.priority = nil end,
	Collect = function(acc, mod)
		local p = mod.Priority or 0
		if acc.priority == nil or p > acc.priority then
			acc.priority = p
		end
	end,
	-- Apply is a no-op here — BehaviorReplace only sets the cutoff priority
	-- that BehaviorOverride and BehaviorDeepMerge read from their accumulator.
	-- The actual pruning happens in those types' Collect via mod.Priority check.
	Apply   = function(result, _acc, _base)
		return result
	end,
})

-- ── BehaviorOverride ──────────────────────────────────────────────────────────
-- Shallow-merges mod.Value keys onto the behavior table.
-- Respects BehaviorReplace cutoff: modifiers below the Replace priority are skipped.
-- mod.Value = { [key] = value, ... }
ModifierTypes.Register("BehaviorOverride", {
	Phase   = "BehaviorOverride",
	Initial = function() return { entries = {} } end,
	Reset   = function(acc) table.clear(acc.entries) end,
	Collect = function(acc, mod)
		-- Value must be a table of key-value overrides
		if type(mod.Value) ~= "table" then return end
		table.insert(acc.entries, { Priority = mod.Priority or 0, Value = mod.Value })
	end,
	Apply   = function(result, acc, _base)
		if #acc.entries == 0 then return result end
		-- Sort ascending so highest priority applies last (wins)
		table.sort(acc.entries, function(a, b) return a.Priority < b.Priority end)
		-- Get Replace cutoff from BehaviorReplace accumulator
		local replaceAcc = _accTemplate["BehaviorReplace"]
		local cutoff     = replaceAcc and replaceAcc.priority

		local merged = result
		local cloned = false
		for _, entry in acc.entries do
			if cutoff and entry.Priority < cutoff then continue end
			if not cloned then merged = table.clone(merged); cloned = true end
			for k, v in entry.Value do
				merged[k] = v
			end
		end
		return merged
	end,
})

-- ── BehaviorDeepMerge ─────────────────────────────────────────────────────────
-- Recursively merges mod.Value into the behavior table.
-- Safe for nested config tables like MaterialRestitution.
-- mod.Value = { [key] = { ... }, ... }
ModifierTypes.Register("BehaviorDeepMerge", {
	Phase   = "BehaviorDeepMerge",
	Initial = function() return { entries = {} } end,
	Reset   = function(acc) table.clear(acc.entries) end,
	Collect = function(acc, mod)
		if type(mod.Value) ~= "table" then return end
		table.insert(acc.entries, { Priority = mod.Priority or 0, Value = mod.Value })
	end,
	Apply   = function(result, acc, _base)
		if #acc.entries == 0 then return result end
		table.sort(acc.entries, function(a, b) return a.Priority < b.Priority end)
		local replaceAcc = _accTemplate["BehaviorReplace"]
		local cutoff     = replaceAcc and replaceAcc.priority

		local merged = result
		local cloned = false
		for _, entry in acc.entries do
			if cutoff and entry.Priority < cutoff then continue end
			if not cloned then merged = table.clone(merged); cloned = true end
			for k, v in entry.Value do
				merged[k] = _deepMerge(merged[k], v)
			end
		end
		return merged
	end,
})

-- ── BehaviorHook ──────────────────────────────────────────────────────────────
-- Collects hook functions into a per-event list on the result table.
-- result._Hooks[eventName] = { fn, fn, ... } in priority order.
-- mod.Value = { [eventName] = function(ctx, result, velocity) ... end, ... }
ModifierTypes.Register("BehaviorHook", {
	Phase   = "BehaviorHook",
	Initial = function() return { entries = {} } end,
	Reset   = function(acc) table.clear(acc.entries) end,
	Collect = function(acc, mod)
		if type(mod.Value) ~= "table" then return end
		table.insert(acc.entries, { Priority = mod.Priority or 0, Value = mod.Value })
	end,
	Apply   = function(result, acc, _base)
		if #acc.entries == 0 then return result end
		table.sort(acc.entries, function(a, b) return a.Priority < b.Priority end)
		local replaceAcc = _accTemplate["BehaviorReplace"]
		local cutoff     = replaceAcc and replaceAcc.priority

		-- Hooks are stored on _Hooks so they don't pollute the behavior table itself
		local hooks = result._Hooks
		if not hooks then
			result = table.clone(result)
			hooks  = {}
			result._Hooks = hooks
		end

		for _, entry in acc.entries do
			if cutoff and entry.Priority < cutoff then continue end
			for eventName, fn in entry.Value do
				if type(fn) ~= "function" then continue end
				local list = hooks[eventName]
				if not list then
					list = {}
					hooks[eventName] = list
				end
				table.insert(list, fn)
			end
		end
		return result
	end,
})

-- ── BehaviorExclusive ─────────────────────────────────────────────────────────
-- Tag-based winner-takes-all override. Only the highest-priority mod per Tag
-- applies its Value as a shallow override. Prevents stacking of mutually
-- exclusive options (e.g. two different scope types on the same weapon).
-- mod.Tag   = "Scope"
-- mod.Value = { ZoomFactor = 4, ... }
ModifierTypes.Register("BehaviorExclusive", {
	Phase   = "BehaviorExclusive",
	Initial = function() return { winners = {} } end,
	Reset   = function(acc) table.clear(acc.winners) end,
	Collect = function(acc, mod)
		if type(mod.Value) ~= "table" then return end
		local tag  = mod.Tag or "__untagged"
		local p    = mod.Priority or 0
		local curr = acc.winners[tag]
		if not curr or p > curr.Priority then
			acc.winners[tag] = { Priority = p, Value = mod.Value }
		end
	end,
	Apply   = function(result, acc, _base)
		if not next(acc.winners) then return result end
		local merged = table.clone(result)
		for _, winner in acc.winners do
			for k, v in winner.Value do
				merged[k] = v
			end
		end
		return merged
	end,
})

-- ─── Type name constants ──────────────────────────────────────────────────────

ModifierTypes.Types = {
	-- Numeric
	SetBase           = "SetBase",
	FlatAdd           = "FlatAdd",
	AddPercent        = "AddPercent",
	Multiply          = "Multiply",
	Override          = "Override",
	MinOverride       = "MinOverride",
	MaxOverride       = "MaxOverride",
	ClampMin          = "ClampMin",
	ClampMax          = "ClampMax",
	StackUnique       = "StackUnique",
	Lock              = "Lock",
	-- Behavior
	BehaviorReplace   = "BehaviorReplace",
	BehaviorOverride  = "BehaviorOverride",
	BehaviorDeepMerge = "BehaviorDeepMerge",
	BehaviorHook      = "BehaviorHook",
	BehaviorExclusive = "BehaviorExclusive",
}

ModifierTypes.Phases = PHASE_ORDER

return ModifierTypes