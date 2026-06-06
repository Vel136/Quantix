# Quantix

Stats that stack exactly as intended.

**[Documentation](https://vel136.github.io/Quantix/)** · **[Creator Store](https://create.roblox.com/store/asset/98164908675977)**

**Version:** V1.1.0

Quantix is a stat modifier library for Roblox Luau. It manages numeric and table-based stats through a typed, phase-ordered pipeline. Modifiers are sorted into phases (`SetBase → FlatAdd → AddPercent → Multiply → Override → Clamp → Lock`), evaluated deterministically, and cached until invalidated. Stats stack exactly as intended regardless of how many modifiers are active.

---

## Install

Get Quantix from the **[Roblox Creator Store](https://create.roblox.com/store/asset/98164908675977)**, drop the module into `ReplicatedStorage`, and require it:

```lua
local Quantix = require(ReplicatedStorage.Quantix)
```

Requires **Signal** (included in the package).

---

## Quick Start

```lua
local Quantix = require(ReplicatedStorage.Quantix)

local stats = Quantix.new({
    Damage  = 25,
    Range   = 50,
    Spread  = { Base = 1.5, ADS = 0.8 },
})

-- Nested tables are flattened to dot-path keys
print(stats:Get("Spread.Base"))   --> 1.5

-- Add a modifier
local id = stats:AddModifier({
    Stat   = "Damage",
    Type   = Quantix.Types.FlatAdd,
    Value  = 10,
    Source = Quantix.Sources.Attachment,
})

print(stats:Get("Damage"))   --> 35

-- Remove it later
stats:RemoveModifier(id)
print(stats:Get("Damage"))   --> 25
```

---

## Modifier Pipeline

| Phase | Types | What it does |
|-------|-------|--------------|
| `SetBase` | `SetBase` | Replaces the base value (highest priority wins) |
| `FlatAdd` | `FlatAdd`, `StackUnique` | Adds a flat amount |
| `AddPercent` | `AddPercent` | Adds `base × (percent / 100)` |
| `Multiply` | `Multiply` | Multiplies; supports named groups for compounding |
| `Override` | `Override` | Replaces the result (highest priority wins) |
| `MinOverride` | `MinOverride` | Raises the floor |
| `MaxOverride` | `MaxOverride` | Lowers the ceiling |
| `Clamp` | `ClampMin`, `ClampMax` | Hard min/max clamp |
| `Lock` | `Lock` | Short-circuits everything; value is locked |
| Behavior | `BehaviorReplace`, `BehaviorOverride`, `BehaviorDeepMerge`, `BehaviorHook`, `BehaviorExclusive` | Table-based stat merging |

---

## Signals

Each controller exposes a `Signals` table of [Signal](https://vel136.github.io/VeSignal/) connections:

| Signal | Parameters | Fires when |
|--------|-----------|------------|
| `OnStatChanged` | `statName, newValue, oldValue` | A stat's final value changed |
| `OnModifierAdded` | `modifier` | A modifier was added |
| `OnModifierRemoved` | `modifierId` | A modifier was removed |
| `OnBatchEnd` | (none) | A `Batch` completed |

```lua
stats.Signals.OnStatChanged:Connect(function(statName, newValue, oldValue)
    print(statName, oldValue, "→", newValue)
end)
```

---

## API

**Query**

| Method | Description |
|--------|-------------|
| `Quantix.new(data)` | Create a new controller; numeric leaf values are flattened to dot-path keys |
| `stats:Get(statName)` | Final evaluated value (cached) |
| `stats:GetBase(statName)` | Raw base value before modifiers |
| `stats:GetAll()` | All stats evaluated as a table |
| `stats:GetGroup(prefix)` | All stats under `prefix.`, with prefix stripped |

**Modifiers**

| Method | Description |
|--------|-------------|
| `stats:AddModifier(mod)` | Add a modifier; returns its ID |
| `stats:RemoveModifier(id)` | Remove a modifier by ID |
| `stats:RemoveBySource(source, sourceId?)` | Remove all modifiers from a source |
| `stats:ReplaceBySource(source, sourceId?, newMods)` | Swap source modifiers atomically |
| `stats:ClearAll()` | Remove every active modifier |
| `stats:SetBase(statName, value)` | Update a stat's base value |
| `stats:RegisterBehavior(key, baseTable)` | Register a table-based behavior stat |
| `stats:Evaluate(key, fallback)` | Evaluate a behavior stat; returns `(table, hooks)` |

**Batching**

| Method | Description |
|--------|-------------|
| `stats:Batch(fn)` | Run `fn` with signals deferred until completion |
| `stats:BeginBatch()` | Manually begin a batch |
| `stats:EndBatch()` | End the batch and flush signals |

**Modifier Query**

| Method | Description |
|--------|-------------|
| `stats:GetModifiersForStat(statName)` | All modifiers for a stat |
| `stats:GetModifiers()` | All active modifiers |
| `stats:GetModifierById(id)` | Single modifier by ID |

**Debug**

| Method | Description |
|--------|-------------|
| `stats:Trace(statName)` | Full pipeline trace as a formatted string |
| `stats:DebugDump()` | Print all stats and modifiers to console |
| `stats:Destroy()` | Destroy the controller and disconnect signals |

---

## Source Constants

```lua
Quantix.Sources.Attachment   -- "Attachment"
Quantix.Sources.Ammo         -- "Ammo"
Quantix.Sources.Perk         -- "Perk"
Quantix.Sources.State        -- "State"
Quantix.Sources.System       -- "System"
Quantix.Sources.Ballistics   -- "Ballistics"
```

---

## Batching Example

Wrap bulk changes in `Batch` to coalesce signals. One `OnStatChanged` fires per stat, not one per modifier:

```lua
stats:Batch(function()
    stats:RemoveBySource(Quantix.Sources.Attachment, attachment.Id)
    stats:AddModifier({ Stat = "Damage", Type = "FlatAdd",  Value = 8,   Source = "Attachment", SourceId = attachment.Id })
    stats:AddModifier({ Stat = "Range",  Type = "Multiply", Value = 0.1, Source = "Attachment", SourceId = attachment.Id })
end)
```

---

## Behavior Modifiers

Behavior modifiers operate on a registered table stat rather than a number:

```lua
stats:RegisterBehavior("Bullet", {
    MaxPenetrations = 1,
    Gravity         = 9.81,
})

stats:AddModifier({
    Stat   = "Bullet",
    Type   = Quantix.Types.BehaviorOverride,
    Value  = { MaxPenetrations = 3, Gravity = 0 },
    Source = Quantix.Sources.Ammo,
})

local behavior, hooks = stats:Evaluate("Bullet", {})
print(behavior.MaxPenetrations)   --> 3
```

---

## License

Copyright (c) 2026 VeDevelopment. All rights reserved.

Proprietary software. No use, copying, modification, or distribution without express written permission from VeDevelopment.
