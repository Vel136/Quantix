-- MIT License
--
-- Copyright (c) 2026 VeDevelopment

--[=[
	@class Quantix

	Deterministic, phase-ordered stat modifier system for Roblox Luau.

	Quantix manages numeric and table-based stats through a typed modifier
	pipeline. Modifiers are sorted into phases
	(`SetBase → FlatAdd → AddPercent → Multiply → Override → Clamp → Lock`),
	evaluated in a fixed order, and cached until invalidated.

	Behavior modifier types (`BehaviorOverride`, `BehaviorDeepMerge`,
	`BehaviorHook`, `BehaviorExclusive`, `BehaviorReplace`) run through the
	same pipeline, replacing ad-hoc merge logic for table-based stats.

	```lua
	local Quantix = require(ReplicatedStorage.Quantix)

	local stats = Quantix.new({
	    Damage  = 25,
	    Range   = 50,
	    Spread  = { Base = 1.5, ADS = 0.8 },
	})

	local id = stats:AddModifier({
	    Stat   = "Damage",
	    Type   = Quantix.Types.FlatAdd,
	    Value  = 10,
	    Source = Quantix.Sources.Attachment,
	})

	print(stats:Get("Damage"))   --> 35
	stats:RemoveModifier(id)
	print(stats:Get("Damage"))   --> 25
	```
]=]
local Quantix = {}

-- ─── Constructor ──────────────────────────────────────────────────────────────

--[=[
	@function new
	@within Quantix

	Creates a new `StatController`. Numeric leaf values in `data` are flattened
	into dot-separated stat keys.

	```lua
	-- Nested table → flat keys
	local stats = Quantix.new({
	    Damage = 25,
	    Spread = { Base = 1.5, ADS = 0.8 },
	})
	-- stats:Get("Spread.Base") → 1.5

	-- Manual registration
	local stats = Quantix.new({})
	stats:SetBase("Damage", 25)
	```

	@param data table -- Weapon/entity data table. Pass `{}` to register stats manually.
	@return StatController
]=]
function Quantix.new(data) end

-- ─── Constants ────────────────────────────────────────────────────────────────

--[=[
	@prop Types { [string]: string }
	@within Quantix

	Table of all registered modifier type name constants.

	| Key | Value |
	|-----|-------|
	| `SetBase` | `"SetBase"` |
	| `FlatAdd` | `"FlatAdd"` |
	| `AddPercent` | `"AddPercent"` |
	| `Multiply` | `"Multiply"` |
	| `Override` | `"Override"` |
	| `MinOverride` | `"MinOverride"` |
	| `MaxOverride` | `"MaxOverride"` |
	| `ClampMin` | `"ClampMin"` |
	| `ClampMax` | `"ClampMax"` |
	| `StackUnique` | `"StackUnique"` |
	| `Lock` | `"Lock"` |
	| `BehaviorReplace` | `"BehaviorReplace"` |
	| `BehaviorOverride` | `"BehaviorOverride"` |
	| `BehaviorDeepMerge` | `"BehaviorDeepMerge"` |
	| `BehaviorHook` | `"BehaviorHook"` |
	| `BehaviorExclusive` | `"BehaviorExclusive"` |

	```lua
	stats:AddModifier({ ..., Type = Quantix.Types.FlatAdd })
	```
]=]
Quantix.Types = nil

--[=[
	@prop Sources { [string]: string }
	@within Quantix

	Built-in source category constants for tagging modifiers.

	| Key | Value |
	|-----|-------|
	| `Attachment` | `"Attachment"` |
	| `Ammo` | `"Ammo"` |
	| `Perk` | `"Perk"` |
	| `State` | `"State"` |
	| `System` | `"System"` |
	| `Ballistics` | `"Ballistics"` |

	```lua
	stats:AddModifier({ ..., Source = Quantix.Sources.Attachment, SourceId = id })
	stats:RemoveBySource(Quantix.Sources.Attachment, id)
	```
]=]
Quantix.Sources = nil

-- ─── Signals ──────────────────────────────────────────────────────────────────

--[=[
	@prop Signals StatControllerSignals
	@within Quantix

	Lifecycle signals for this controller.

	| Signal | Parameters | Fires when |
	|--------|-----------|------------|
	| `OnStatChanged` | `statName: string, newValue: any, oldValue: any` | A stat's final value changed |
	| `OnModifierAdded` | `modifier: Modifier` | A modifier was added |
	| `OnModifierRemoved` | `modifierId: string` | A modifier was removed |
	| `OnBatchEnd` | (none) | A `Batch` completed |

	```lua
	stats.Signals.OnStatChanged:Connect(function(statName, newValue, oldValue)
	    print(statName, oldValue, "→", newValue)
	end)
	```
]=]
Quantix.Signals = nil

-- ─── Query ────────────────────────────────────────────────────────────────────

--[=[
	@method Get
	@within Quantix

	Returns the final evaluated value of a stat. Result is cached until the
	stat is invalidated. Conditional stats are always re-evaluated.

	```lua
	print(stats:Get("Damage"))        --> 35
	print(stats:Get("Spread.Base"))   --> 1.5
	```

	@param statName string -- The stat key to evaluate.
	@return any -- The final value, or `nil` if the stat has no base.
]=]
function Quantix:Get(statName) end

--[=[
	@method GetBase
	@within Quantix

	Returns the raw base value of a stat before any modifiers are applied.

	```lua
	print(stats:GetBase("Damage"))   --> 25
	```

	@param statName string
	@return any
]=]
function Quantix:GetBase(statName) end

--[=[
	@method GetAll
	@within Quantix

	Evaluates all registered stats and returns them as a `{ [statName]: value }` table.

	```lua
	local all = stats:GetAll()
	print(all["Damage"], all["Range"])
	```

	@return { [string]: any }
]=]
function Quantix:GetAll() end

--[=[
	@method GetGroup
	@within Quantix

	Returns all stats whose keys start with `prefix.`, with the prefix stripped.

	```lua
	-- Given stats: Spread.Base = 1.5, Spread.ADS = 0.8
	local spread = stats:GetGroup("Spread")
	print(spread.Base, spread.ADS)   --> 1.5   0.8
	```

	@param prefix string -- The dot-path prefix to filter by.
	@return { [string]: any }
]=]
function Quantix:GetGroup(prefix) end

-- ─── Modifier management ──────────────────────────────────────────────────────

--[=[
	@method AddModifier
	@within Quantix

	Adds a modifier to the controller. Returns the modifier's auto-generated ID,
	which can be passed to `RemoveModifier` later.

	Required fields: `Stat`, `Type`, `Value`.

	```lua
	local id = stats:AddModifier({
	    Stat      = "Damage",
	    Type      = Quantix.Types.FlatAdd,
	    Value     = 10,
	    Source    = Quantix.Sources.Attachment,
	    SourceId  = attachment.Id,
	    Priority  = 0,
	})
	```

	@param modifier Modifier -- The modifier to add. `Id` is assigned automatically.
	@return string -- The auto-generated modifier ID.
]=]
function Quantix:AddModifier(modifier) end

--[=[
	@method RemoveModifier
	@within Quantix

	Removes a modifier by its ID. Returns `true` if the modifier was found and
	removed, `false` if it did not exist.

	```lua
	local removed = stats:RemoveModifier(id)
	```

	@param modifierId string
	@return boolean
]=]
function Quantix:RemoveModifier(modifierId) end

--[=[
	@method RemoveBySource
	@within Quantix

	Removes all modifiers with the given `Source` (and optionally `SourceId`).
	Runs inside an implicit `Batch`. Returns the number of modifiers removed.

	```lua
	-- Remove all modifiers from any attachment with this ID
	stats:RemoveBySource(Quantix.Sources.Attachment, attachment.Id)

	-- Remove all Perk modifiers regardless of SourceId
	stats:RemoveBySource(Quantix.Sources.Perk)
	```

	@param source string -- The source category to match.
	@param sourceId (string | number)? -- Optional specific source instance to match.
	@return number -- The number of modifiers removed.
]=]
function Quantix:RemoveBySource(source, sourceId) end

--[=[
	@method ReplaceBySource
	@within Quantix

	Removes all modifiers matching `source`/`sourceId`, then adds `newModifiers`
	atomically inside a single `Batch`. Returns a list of the new modifier IDs.

	```lua
	local ids = stats:ReplaceBySource(
	    Quantix.Sources.Attachment,
	    old.Id,
	    newAttachment.Modifiers
	)
	```

	@param source string
	@param sourceId (string | number)?
	@param newModifiers { Modifier }
	@return { string } -- IDs of the newly added modifiers.
]=]
function Quantix:ReplaceBySource(source, sourceId, newModifiers) end

--[=[
	@method ClearAll
	@within Quantix

	Removes every active modifier. Runs inside an implicit `Batch`.

	```lua
	stats:ClearAll()
	```
]=]
function Quantix:ClearAll() end

-- ─── Base mutation ────────────────────────────────────────────────────────────

--[=[
	@method SetBase
	@within Quantix

	Sets or updates the base value of a stat. Fires `OnStatChanged` if the
	final evaluated value changes.

	```lua
	stats:SetBase("Damage", 30)
	```

	@param statName string
	@param value any -- New base value (number or table).
]=]
function Quantix:SetBase(statName, value) end

--[=[
	@method RegisterBehavior
	@within Quantix

	Registers a base behavior table under a key so that behavior modifiers can
	be applied to it via `AddModifier`. Call once during setup.

	```lua
	stats:RegisterBehavior("Bullet", {
	    MaxPenetrations = 1,
	    Gravity         = 9.81,
	})
	```

	@param behaviorKey string -- Unique key for this behavior, used as the `Stat` field in modifiers.
	@param baseBehavior table -- The unmodified base behavior definition.
]=]
function Quantix:RegisterBehavior(behaviorKey, baseBehavior) end

-- ─── Behavior evaluation ──────────────────────────────────────────────────────

--[=[
	@method Evaluate
	@within Quantix

	Evaluates behavior modifiers for `behaviorKey` and returns the merged
	behavior table and collected hooks.

	```lua
	local behavior, hooks = stats:Evaluate("Bullet", baseBehavior)
	-- behavior: merged table (no _Hooks key)
	-- hooks: { [eventName] = { fn, fn, ... } }

	for _, fn in hooks.OnPierce or {} do
	    fn(ctx, result, velocity)
	end
	```

	@param behaviorKey string -- The behavior key (must be registered via `RegisterBehavior`).
	@param baseBehavior table -- Fallback if no modifiers have been applied yet.
	@return table -- The final merged behavior table.
	@return table -- Hooks table: `{ [eventName] = { fn, ... } }`.
]=]
function Quantix:Evaluate(behaviorKey, baseBehavior) end

-- ─── Batching ─────────────────────────────────────────────────────────────────

--[=[
	@method Batch
	@within Quantix

	Runs `fn` inside a batch. All `OnStatChanged`, `OnModifierAdded`, and
	`OnModifierRemoved` signals are deferred until `fn` returns, then fired
	once per changed stat. `OnBatchEnd` fires last.

	```lua
	stats:Batch(function()
	    stats:RemoveBySource(Quantix.Sources.Attachment, id)
	    stats:AddModifier({ Stat = "Damage", Type = "FlatAdd",  Value = 8,   Source = "Attachment", SourceId = id })
	    stats:AddModifier({ Stat = "Range",  Type = "Multiply", Value = 0.1, Source = "Attachment", SourceId = id })
	end)
	```
]=]
function Quantix:Batch(fn) end

--[=[
	@method BeginBatch
	@within Quantix

	Manually begins a batch. Prefer `Batch` for automatic error handling.

	```lua
	stats:BeginBatch()
	-- ... modifier changes ...
	stats:EndBatch()
	```
]=]
function Quantix:BeginBatch() end

--[=[
	@method EndBatch
	@within Quantix

	Ends the active batch, flushing deferred signals.
]=]
function Quantix:EndBatch() end

-- ─── Source blocking ──────────────────────────────────────────────────────────

--[=[
	@method Block
	@within Quantix

	Suppresses all modifiers from a source during evaluation without removing
	them. The modifiers stay indexed and are restored instantly when `Unblock`
	is called. Also suppresses any future modifiers added under the same
	source/sourceId while the block is active.

	`Block(source)` blocks every modifier from that source regardless of
	`SourceId`. `Block(source, sourceId)` blocks only that specific pair.

	```lua
	-- Ignore all ammo modifiers while a special state is active
	stats:Block(Quantix.Sources.Ammo)

	-- Block a specific attachment
	stats:Block(Quantix.Sources.Attachment, attachment.Id)
	```

	@param source string
	@param sourceId (string | number)?
]=]
function Quantix:Block(source, sourceId) end

--[=[
	@method Unblock
	@within Quantix

	Lifts a block set by `Block`, restoring the source's modifiers to
	evaluation. Returns `true` if a block was actually removed.

	```lua
	stats:Unblock(Quantix.Sources.Ammo)
	stats:Unblock(Quantix.Sources.Attachment, attachment.Id)
	```

	@param source string
	@param sourceId (string | number)?
	@return boolean -- `true` if a block was removed, `false` if none existed.
]=]
function Quantix:Unblock(source, sourceId) end

--[=[
	@method IsBlocked
	@within Quantix

	Returns `true` if a source (optionally a specific `SourceId`) is currently
	blocked. A specific `SourceId` also counts as blocked if a broad
	(all-sourceId) block exists for that source.

	```lua
	if stats:IsBlocked(Quantix.Sources.Ammo) then
	    -- ammo modifiers are suppressed
	end
	```

	@param source string
	@param sourceId (string | number)?
	@return boolean
]=]
function Quantix:IsBlocked(source, sourceId) end

-- ─── Modifier query ───────────────────────────────────────────────────────────

--[=[
	@method GetModifiersForStat
	@within Quantix

	Returns all active modifiers registered for `statName`.

	```lua
	for _, mod in stats:GetModifiersForStat("Damage") do
	    print(mod.Id, mod.Type, mod.Value)
	end
	```

	@param statName string
	@return { Modifier }
]=]
function Quantix:GetModifiersForStat(statName) end

--[=[
	@method GetModifiers
	@within Quantix

	Returns all active modifiers across all stats.

	@return { Modifier }
]=]
function Quantix:GetModifiers() end

--[=[
	@method GetModifierById
	@within Quantix

	Returns the modifier with the given ID, or `nil` if it does not exist.

	@param modifierId string
	@return Modifier?
]=]
function Quantix:GetModifierById(modifierId) end

-- ─── Debug ────────────────────────────────────────────────────────────────────

--[=[
	@method Trace
	@within Quantix

	Returns a formatted multi-line string showing the full evaluation pipeline
	for `statName`: base value, all active modifiers, per-phase accumulators,
	and final result. Skipped (condition-failed) modifiers are listed separately.

	```lua
	print(stats:Trace("Damage"))
	-- Stat:  Damage
	-- Base:  25
	-- Active modifiers: 2
	--   [FlatAdd] Attachment/  value=10  priority=0
	-- Phase [FlatAdd]:
	--   FlatAdd: { sum=10 }
	-- = Final: 35
	```

	@param statName string
	@return string
]=]
function Quantix:Trace(statName) end

--[=[
	@method DebugDump
	@within Quantix

	Prints a full dump of all registered stats and active modifiers to the
	Roblox console. Useful for in-editor inspection.

	```lua
	stats:DebugDump()
	```
]=]
function Quantix:DebugDump() end

-- ─── Lifecycle ────────────────────────────────────────────────────────────────

--[=[
	@method Destroy
	@within Quantix

	Destroys the controller. Disconnects all signals and clears all internal
	state. Always call this when the owning entity (weapon, character) is removed.

	```lua
	stats:Destroy()
	```
]=]
function Quantix:Destroy() end

return Quantix
