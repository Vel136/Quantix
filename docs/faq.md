---
sidebar_position: 4
---

# FAQ

Answers to the questions that come up most often.

---

## General

**What is Quantix?**

Quantix is a stat modifier library for Roblox Luau. It manages numeric and table-based stats through a typed, phase-ordered pipeline. Modifiers are grouped by type (FlatAdd, Multiply, Override, etc.), evaluated in a fixed order, and cached until invalidated. Stats stack exactly as intended regardless of how many modifiers are active.

---

**Is Quantix free?**

Yes. Quantix is released under the MIT License.

---

**What problems does Quantix solve?**

Manual stat stacking with scattered `+` and `*` operations leads to order-of-operations bugs, duplicate logic, and no single source of truth. Quantix centralises all modifier logic: one `Get` call returns the correct final value every time.

---

**Can I use Quantix on both server and client?**

Yes. Quantix has no service dependencies beyond `Signal`. Require it on the server, the client, or both.

---

## Modifiers

**What is the evaluation order?**

Phases run in this fixed order: `SetBase → FlatAdd → AddPercent → Multiply → Override → MinOverride → MaxOverride → Clamp → Lock`. Behavior phases follow: `BehaviorReplace → BehaviorOverride → BehaviorDeepMerge → BehaviorHook → BehaviorExclusive`.

---

**What is the difference between `FlatAdd` and `AddPercent`?**

`FlatAdd` adds a constant amount (`result + value`). `AddPercent` adds a percentage of the *base* value, not the current result (`result + base × (percent / 100)`). This means `AddPercent` is not affected by prior `FlatAdd` mods.

---

**What is the difference between `Override` and `Lock`?**

`Override` replaces the result at its phase in the pipeline; subsequent phases (Clamp, Lock) still run. `Lock` short-circuits the entire pipeline immediately; no other phase applies. Use `Lock` when a stat must be a specific value regardless of anything else (e.g. a stunned character who always deals 0 damage).

---

**How does `Multiply` work with multiple mods?**

Ungrouped `Multiply` mods are summed and applied as `result × (1 + sum)`. So two ungrouped mods of `0.1` each give `result × 1.2`. They are additive with each other, not compounding. To get compounding multiplication, assign mods to different `MultGroup` values; groups multiply together.

---

**What does `StackUnique` do?**

`StackUnique` is like `FlatAdd` but only the highest value per source contributes. It prevents the same source from stacking a bonus with itself while still allowing different sources to add their own bonus.

---

**What is `BehaviorReplace`?**

It sets a priority cutoff for behavior merging. Any `BehaviorOverride`, `BehaviorDeepMerge`, or `BehaviorHook` modifier with a priority lower than the active `BehaviorReplace` cutoff is ignored. Use it when an ammo type or attachment should completely replace the base behavior rather than patch it.

---

## Evaluation & Caching

**Are stat values cached?**

Yes. `Get` caches the final result for each stat after the first evaluation and returns the cached value on subsequent calls. The cache is invalidated whenever a modifier is added, removed, or the base value changes. Stats with a `Condition` function are never cached because their value depends on runtime state.

---

**When does `OnStatChanged` fire?**

After any modifier add/remove or `SetBase` call that results in a different final value. Inside a `Batch`, signals are deferred until `EndBatch`. One signal fires per stat that changed, not one per modifier.

---

## Sources

**What is `Source` and `SourceId` for?**

They tag modifiers so they can be removed in bulk. `Source` is a category (e.g. `"Attachment"`, `"Perk"`) and `SourceId` is the specific instance (e.g. the attachment's ID). `RemoveBySource("Attachment", id)` removes all modifiers applied by that specific attachment in one call.

---

**Do I have to use the built-in source constants?**

No. `Quantix.Sources` constants are provided for convenience, but `Source` is a plain string. Pass any value that makes sense for your project.

---

## Behaviors

**What is the difference between `BehaviorOverride` and `BehaviorDeepMerge`?**

`BehaviorOverride` does a shallow merge. Top-level keys in `mod.Value` overwrite the corresponding keys in the behavior table. `BehaviorDeepMerge` recurses into nested tables, so it can patch a specific sub-key without wiping its siblings.

---

**How do `BehaviorHook` functions get called?**

`Evaluate` returns `(finalBehavior, hooks)`. The `hooks` table is `{ [eventName] = { fn, fn, ... } }`. Your system is responsible for iterating and calling them at the appropriate lifecycle moment (e.g. `OnPierce`, `OnImpact`).

---

## Lifecycle

**How do I clean up a StatController?**

Call `stats:Destroy()`. It disconnects all signals, clears all internal tables, and makes the controller unusable. Always call `Destroy` when the owner (e.g. a weapon or character) is removed.

---

**What happens if I call `Get` on a stat with no base value?**

A warning is emitted and `nil` is returned. Register all stats via `Quantix.new(data)`, `SetBase`, or `RegisterBehavior` before adding modifiers.
