---
sidebar_position: 2
sidebar_label: "Overview"
---

# Quantix

*Stats that stack exactly as intended.*

Deterministic, phase-ordered stat modifier system for Roblox Luau.

Quantix is a per-instance `StatController` that manages numeric and table-based stats through a typed modifier pipeline. Modifiers are sorted into phases (SetBase, FlatAdd, AddPercent, Multiply, Override, Clamp, Lock), evaluated deterministically, and cached until invalidated. Behavior modifier types (BehaviorOverride, BehaviorDeepMerge, BehaviorHook, BehaviorExclusive, BehaviorReplace) run through the same pipeline, replacing what was previously ad-hoc merge logic.

---

## One File. One Require.

Drop Quantix into `ReplicatedStorage` and require it from any script.

```lua
local Quantix = require(ReplicatedStorage.Quantix)
```

---

## Creating a StatController

```lua
local stats = Quantix.new({
    Damage  = 25,
    Range   = 50,
    Spread  = { Base = 1.5, ADS = 0.8 },
})

-- Nested tables are flattened to dot-path keys
print(stats:Get("Spread.Base"))   --> 1.5
print(stats:Get("Spread.ADS"))    --> 0.8
```

Pass an empty table if you prefer to register stats manually:

```lua
local stats = Quantix.new({})
stats:SetBase("Damage", 25)
```

---

## Modifier Pipeline

Modifiers are evaluated in a fixed phase order. Within a phase, each type has its own accumulation and application logic.

| Phase | Types | What it does |
|-------|-------|--------------|
| `SetBase` | `SetBase` | Replaces the base value (highest priority wins) |
| `FlatAdd` | `FlatAdd`, `StackUnique` | Adds a flat amount to the result |
| `AddPercent` | `AddPercent` | Adds `base × (percent / 100)` |
| `Multiply` | `Multiply` | Multiplies the result; supports groups |
| `Override` | `Override` | Replaces the result (highest priority wins) |
| `MinOverride` | `MinOverride` | Raises the floor |
| `MaxOverride` | `MaxOverride` | Lowers the ceiling |
| `Clamp` | `ClampMin`, `ClampMax` | Final min/max clamp |
| `Lock` | `Lock` | Short-circuits everything; final value is locked |
| `BehaviorReplace` | `BehaviorReplace` | Sets a priority cutoff for behavior merging |
| `BehaviorOverride` | `BehaviorOverride` | Shallow-merges keys onto the behavior table |
| `BehaviorDeepMerge` | `BehaviorDeepMerge` | Recursively merges nested tables |
| `BehaviorHook` | `BehaviorHook` | Collects hook functions per event name |
| `BehaviorExclusive` | `BehaviorExclusive` | Tag-based winner-takes-all override |

---

## Numeric Modifier Types

### FlatAdd

Adds a flat value after the base phase. All `FlatAdd` modifiers are summed.

```lua
stats:AddModifier({ Stat = "Damage", Type = "FlatAdd", Value = 10, Source = "Attachment" })
```

### AddPercent

Adds `base × (percent / 100)`. All `AddPercent` modifiers are summed before applying.

```lua
-- +15% of base damage
stats:AddModifier({ Stat = "Damage", Type = "AddPercent", Value = 15, Source = "Perk" })
```

### Multiply

Multiplies the post-additive result. Ungrouped multipliers are summed then applied as `1 + sum`. Grouped multipliers multiply together per group.

```lua
-- Ungrouped: value is additive with other ungrouped Multiply mods
stats:AddModifier({ Stat = "Damage", Type = "Multiply", Value = 0.2, Source = "Perk" })

-- Grouped: multiplied together within the group
stats:AddModifier({ Stat = "Damage", Type = "Multiply", Value = 1.1, MultGroup = "WeaponBonus", Source = "State" })
```

### Override

Replaces the result entirely. Highest `Priority` wins when multiple Override mods exist.

```lua
stats:AddModifier({ Stat = "FireRate", Type = "Override", Value = 600, Priority = 10, Source = "State" })
```

### SetBase

Replaces the base value before any additive phases. Highest priority wins.

```lua
stats:AddModifier({ Stat = "Damage", Type = "SetBase", Value = 50, Priority = 1, Source = "System" })
```

### MinOverride / MaxOverride

Raises or lowers the result's floor or ceiling (applied after Multiply/Override).

```lua
stats:AddModifier({ Stat = "Damage", Type = "MinOverride", Value = 1,   Source = "System" })
stats:AddModifier({ Stat = "Damage", Type = "MaxOverride", Value = 999, Source = "System" })
```

### ClampMin / ClampMax

Hard clamp applied last (after all other phases except Lock).

```lua
stats:AddModifier({ Stat = "Spread", Type = "ClampMin", Value = 0.1, Source = "System" })
```

### StackUnique

Like `FlatAdd`, but only the highest value per `Source` contributes. Prevents the same source from stacking with itself.

```lua
stats:AddModifier({ Stat = "Damage", Type = "StackUnique", Value = 5, Source = "Perk" })
```

### Lock

Short-circuits the entire pipeline. The highest-priority `Lock` mod's value is the final result, ignoring all other phases.

```lua
stats:AddModifier({ Stat = "Damage", Type = "Lock", Value = 0, Priority = 99, Source = "State" })
```

---

## Behavior Modifier Types

Behavior modifiers operate on a table base value registered via `RegisterBehavior`.

### BehaviorOverride

Shallow-merges `mod.Value` keys onto the behavior table. Higher priority wins per key.

```lua
stats:AddModifier({
    Stat   = "Bullet",
    Type   = "BehaviorOverride",
    Value  = { MaxPenetrations = 3, Gravity = 0 },
    Source = "Ammo",
})
```

### BehaviorDeepMerge

Recursively merges `mod.Value` into the behavior table. Safe for nested config tables.

```lua
stats:AddModifier({
    Stat   = "Bullet",
    Type   = "BehaviorDeepMerge",
    Value  = { MaterialRestitution = { Grass = 0.2 } },
    Source = "Ammo",
})
```

### BehaviorHook

Collects hook functions per event name. Multiple hooks for the same event are called in priority order.

```lua
stats:AddModifier({
    Stat   = "Bullet",
    Type   = "BehaviorHook",
    Value  = {
        OnPierce = function(ctx, result, velocity)
            velocity *= 0.8
        end,
    },
    Source = "Perk",
})
```

### BehaviorExclusive

Tag-based winner-takes-all. Only the highest-priority mod per `Tag` applies. Prevents multiple conflicting mods from stacking (e.g. two different scope types).

```lua
stats:AddModifier({
    Stat   = "Bullet",
    Type   = "BehaviorExclusive",
    Tag    = "Scope",
    Value  = { ZoomFactor = 4 },
    Source = "Attachment",
    Priority = 1,
})
```

### BehaviorReplace

Sets a priority cutoff. Behavior modifiers with lower priority than the highest `BehaviorReplace` are ignored. Use to make an attachment fully override the base behavior.

```lua
stats:AddModifier({
    Stat     = "Bullet",
    Type     = "BehaviorReplace",
    Value    = true,
    Priority = 5,
    Source   = "Ammo",
})
```

---

## Signals

| Signal | Parameters | Fires when |
|--------|-----------|------------|
| `OnStatChanged` | `statName, newValue, oldValue` | A stat's final value changed |
| `OnModifierAdded` | `modifier` | A modifier was added |
| `OnModifierRemoved` | `modifierId` | A modifier was removed |
| `OnBatchEnd` | (none) | A batch completed |

```lua
stats.Signals.OnStatChanged:Connect(function(statName, newValue, oldValue)
    print(statName, oldValue, "→", newValue)
end)
```

---

## Batching

Wrap multiple modifier changes in `Batch` to coalesce signals. `OnStatChanged` fires once per stat at the end, not once per modifier.

```lua
stats:Batch(function()
    stats:RemoveBySource("Attachment", id)
    stats:AddModifier({ Stat = "Damage", Type = "FlatAdd",  Value = 8,   Source = "Attachment", SourceId = id })
    stats:AddModifier({ Stat = "Range",  Type = "Multiply", Value = 0.1, Source = "Attachment", SourceId = id })
end)
-- OnStatChanged fires for "Damage" and "Range" once each
```

---

## Source Tagging

Every modifier can carry a `Source` and `SourceId` to group modifiers by what applied them. `RemoveBySource` removes all modifiers from a source in one call.

```lua
-- Apply all mods from an attachment
stats:AddModifier({ Stat = "Damage", ..., Source = "Attachment", SourceId = attachment.Id })
stats:AddModifier({ Stat = "Range",  ..., Source = "Attachment", SourceId = attachment.Id })

-- Remove them all when the attachment is unequipped
stats:RemoveBySource("Attachment", attachment.Id)
```

Built-in source constants are available as `Quantix.Sources`:

| Constant | Value |
|----------|-------|
| `Attachment` | `"Attachment"` |
| `Ammo` | `"Ammo"` |
| `Perk` | `"Perk"` |
| `State` | `"State"` |
| `System` | `"System"` |
| `Ballistics` | `"Ballistics"` |

---

## Conditional Modifiers

Pass a `Condition` function to a modifier. It is called on every evaluation. If it returns `false`, the modifier is skipped. Conditional stats are never cached.

```lua
stats:AddModifier({
    Stat      = "Damage",
    Type      = "FlatAdd",
    Value     = 10,
    Source    = "Perk",
    Condition = function() return character:HasBuff("Rage") end,
})
```

---

## Debugging

### Trace

Returns a formatted string showing the full evaluation pipeline for a stat.

```lua
print(stats:Trace("Damage"))
-- Stat:  Damage
-- Base:  25
-- Active modifiers: 2
--   [FlatAdd] Attachment/  value=10  priority=0
--   [Multiply] Perk/  value=0.2  priority=0
-- Phase [FlatAdd]:
--   FlatAdd: { sum=10 }
-- Phase [Multiply]:
--   Multiply: { ungroupedSum=0.2, groups={} }
-- = Final: 42
```

### DebugDump

Prints a full dump of all stats and active modifiers to the console.

```lua
stats:DebugDump()
```
