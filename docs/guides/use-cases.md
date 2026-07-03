---
sidebar_position: 1
---

# Use Cases

Practical patterns for the most common Quantix scenarios.

---

## Weapon Stats with Attachments

Create a controller from weapon data, apply attachment modifiers on equip, and remove them on unequip.

```lua
local Quantix = require(ReplicatedStorage.Quantix)

local stats = Quantix.new({
    Damage   = 25,
    Range    = 50,
    FireRate = 600,
    Spread   = { Base = 1.5, ADS = 0.8 },
})

local function onAttachmentEquipped(attachment)
    stats:Batch(function()
        for _, mod in attachment.Modifiers do
            mod.Source   = Quantix.Sources.Attachment
            mod.SourceId = attachment.Id
            stats:AddModifier(mod)
        end
    end)
end

local function onAttachmentUnequipped(attachment)
    stats:RemoveBySource(Quantix.Sources.Attachment, attachment.Id)
end
```

---

## Perk Bonuses (StackUnique)

A perk that gives +5 damage, but equipping the same perk twice should not double-stack it.

```lua
-- Only the highest value per source contributes
stats:AddModifier({
    Stat   = "Damage",
    Type   = Quantix.Types.StackUnique,
    Value  = 5,
    Source = Quantix.Sources.Perk,
    SourceId = "DamageBoost",
})

-- Adding the same source again replaces rather than stacks
stats:AddModifier({
    Stat   = "Damage",
    Type   = Quantix.Types.StackUnique,
    Value  = 5,
    Source = Quantix.Sources.Perk,
    SourceId = "DamageBoost",
})

print(stats:Get("Damage"))   --> 30 (not 35)
```

---

## Conditional Modifier (Rage Buff)

A bonus that only applies while the character has an active buff.

```lua
stats:AddModifier({
    Stat      = "Damage",
    Type      = Quantix.Types.FlatAdd,
    Value     = 15,
    Source    = Quantix.Sources.State,
    Condition = function() return character:HasBuff("Rage") end,
})

-- No cache is kept for conditional stats, always re-evaluated
print(stats:Get("Damage"))   -- includes +15 only when Rage is active
```

---

## Locking a Stat (Stun)

Force a stat to a fixed value regardless of all other modifiers.

```lua
local lockId = stats:AddModifier({
    Stat     = "Damage",
    Type     = Quantix.Types.Lock,
    Value    = 0,
    Priority = 99,
    Source   = Quantix.Sources.State,
})

print(stats:Get("Damage"))   --> 0

-- Remove the lock when stun ends
stats:RemoveModifier(lockId)
```

---

## Replacing Attachment Modifiers

Swap one attachment for another atomically. No intermediate state fires.

```lua
local function swapAttachment(old, new)
    local newMods = {}
    for _, mod in new.Modifiers do
        mod.Source   = Quantix.Sources.Attachment
        mod.SourceId = new.Id
        table.insert(newMods, mod)
    end

    -- Removes old, adds new, fires signals once per changed stat
    stats:ReplaceBySource(Quantix.Sources.Attachment, old.Id, newMods)
end
```

---

## Ammo Type: Behavior Override

Switch bullet behavior when a special ammo type is loaded, then restore defaults on unload.

```lua
stats:RegisterBehavior("Bullet", {
    MaxPenetrations = 1,
    Gravity         = 9.81,
    Damage          = 25,
})

local function onAmmoLoaded(ammo)
    stats:AddModifier({
        Stat     = "Bullet",
        Type     = Quantix.Types.BehaviorOverride,
        Value    = ammo.BehaviorOverrides,  -- e.g. { MaxPenetrations = 3, Gravity = 0 }
        Source   = Quantix.Sources.Ammo,
        SourceId = ammo.Id,
        Priority = 1,
    })
end

local function onAmmoUnloaded(ammo)
    stats:RemoveBySource(Quantix.Sources.Ammo, ammo.Id)
end

local behavior, hooks = stats:Evaluate("Bullet", {})
```

---

## Scope: BehaviorExclusive

Only one scope type should apply at a time. `BehaviorExclusive` with a shared `Tag` guarantees the highest-priority one wins.

```lua
stats:AddModifier({
    Stat     = "Bullet",
    Type     = Quantix.Types.BehaviorExclusive,
    Tag      = "Scope",
    Value    = { ZoomFactor = 2, AimSpeed = 0.8 },
    Source   = Quantix.Sources.Attachment,
    SourceId = "IronSights",
    Priority = 0,
})

stats:AddModifier({
    Stat     = "Bullet",
    Type     = Quantix.Types.BehaviorExclusive,
    Tag      = "Scope",
    Value    = { ZoomFactor = 4, AimSpeed = 0.6 },
    Source   = Quantix.Sources.Attachment,
    SourceId = "4xScope",
    Priority = 1,
})

-- Only 4xScope applies — it has the higher priority
local behavior, _ = stats:Evaluate("Bullet", {})
print(behavior.ZoomFactor)   --> 4
```

---

## Batch Replace on Loadout Change

Rebuild all perk modifiers at once after a loadout change, coalescing all signals into one pass.

```lua
local function onLoadoutChanged(newPerks)
    local mods = {}
    for _, perk in newPerks do
        for _, mod in perk:GetModifiers() do
            mod.Source = Quantix.Sources.Perk
            table.insert(mods, mod)
        end
    end
    stats:ReplaceBySource(Quantix.Sources.Perk, nil, mods)
end
```

---

## Blocking a Source (Non-Destructive Suppression)

Temporarily ignore all modifiers from a source without removing them. Useful when a game state should override normally active modifiers and then snap back.

```lua
-- A special flamethrower state that ignores ammo type modifiers
local function onSpecialActivated()
    stats:Block(Quantix.Sources.Ammo)
end

local function onSpecialDeactivated()
    stats:Unblock(Quantix.Sources.Ammo)
end

-- Block a specific attachment while it's "broken"
stats:Block(Quantix.Sources.Attachment, brokenAttachment.Id)
-- ... later ...
stats:Unblock(Quantix.Sources.Attachment, brokenAttachment.Id)
```

---

## Debug Trace

Inspect the full modifier pipeline for a specific stat during development.

```lua
print(stats:Trace("Damage"))
-- Stat:  Damage
-- Base:  25
-- Active modifiers: 3
--   [FlatAdd]    Attachment/scope  value=0   priority=0
--   [AddPercent] Perk/DmgBoost     value=15  priority=0
--   [Multiply]   State/rage        value=0.2 priority=0
-- Phase [FlatAdd]:
--   FlatAdd: { sum=0 }
-- Phase [AddPercent]:
--   AddPercent: { totalPercent=15 }
-- Phase [Multiply]:
--   Multiply: { ungroupedSum=0.2, groups={} }
-- = Final: 33.75
```
