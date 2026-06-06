---
sidebar_position: 1
---

# Getting Started

Quantix is a stat modifier library for Roblox Luau. Install it, create a `StatController` with your base stats, and start stacking modifiers.

---

## Installation

Get Quantix from the Roblox Creator Store:

**[Get Quantix on Creator Store](https://create.roblox.com/store/asset/TODO/Quantix)**

Drop the module into `ReplicatedStorage` and require it:

```lua
local Quantix = require(ReplicatedStorage.Quantix)
```

Quantix depends on **Signal** and **ModifierTypes**, both included in the package.

---

## Your First StatController

```lua
local Quantix = require(ReplicatedStorage.Quantix)

-- Pass a weapon data table; numeric leaf values become stat keys
local stats = Quantix.new({
    Damage  = 25,
    Range   = 50,
    Spread  = { Base = 1.5, ADS = 0.8 },
})

-- Read the base value
print(stats:Get("Damage"))          --> 25
print(stats:Get("Spread.Base"))     --> 1.5
```

---

## Adding Modifiers

```lua
-- +10 flat damage from an attachment
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

## Reacting to Changes

`StatController` fires signals whenever a stat's final value changes:

```lua
stats.Signals.OnStatChanged:Connect(function(statName, newValue, oldValue)
    print(statName, oldValue, "→", newValue)
end)

stats.Signals.OnModifierAdded:Connect(function(mod)
    print("Modifier added:", mod.Id, mod.Type)
end)
```

---

## Batching Multiple Changes

Wrap bulk modifier changes in a `Batch` to coalesce signals. One `OnStatChanged` fires per stat, not one per modifier:

```lua
stats:Batch(function()
    stats:RemoveBySource(Quantix.Sources.Attachment, attachmentId)
    stats:AddModifier({ Stat = "Damage",  Type = Quantix.Types.FlatAdd, Value = 5, Source = Quantix.Sources.Attachment, SourceId = attachmentId })
    stats:AddModifier({ Stat = "Range",   Type = Quantix.Types.Multiply, Value = 0.1, Source = Quantix.Sources.Attachment, SourceId = attachmentId })
end)
```

---

## Behavior Modifiers

Stats can also be tables. Use `RegisterBehavior` to set a base behavior, then modify it with `BehaviorOverride`, `BehaviorDeepMerge`, `BehaviorHook`, or `BehaviorExclusive`:

```lua
stats:RegisterBehavior("Bullet", {
    MaxPenetrations = 1,
    Gravity         = 9.81,
})

stats:AddModifier({
    Stat   = "Bullet",
    Type   = Quantix.Types.BehaviorOverride,
    Value  = { MaxPenetrations = 3 },
    Source = Quantix.Sources.Ammo,
})

local behavior, hooks = stats:Evaluate("Bullet", {})
print(behavior.MaxPenetrations)   --> 3
```

---

## Quick Reference

| I want to… | Method |
|------------|--------|
| Create a controller | [`Quantix.new`](../api/Quantix#new) |
| Read a stat | [`stats:Get`](../api/Quantix#Get) |
| Read all stats | [`stats:GetAll`](../api/Quantix#GetAll) |
| Read a group of stats | [`stats:GetGroup`](../api/Quantix#GetGroup) |
| Add a modifier | [`stats:AddModifier`](../api/Quantix#AddModifier) |
| Remove a modifier | [`stats:RemoveModifier`](../api/Quantix#RemoveModifier) |
| Remove all from a source | [`stats:RemoveBySource`](../api/Quantix#RemoveBySource) |
| Replace source modifiers | [`stats:ReplaceBySource`](../api/Quantix#ReplaceBySource) |
| Batch multiple changes | [`stats:Batch`](../api/Quantix#Batch) |
| Debug a stat pipeline | [`stats:Trace`](../api/Quantix#Trace) |
| See practical examples | [Use Cases](./guides/use-cases) |
