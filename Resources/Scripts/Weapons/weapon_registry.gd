@tool
extends Resource
class_name WeaponRegistry

# The list of first-person weapons, editable in the inspector. Double-click
# `Resources/Registries/weapon_registry.tres` in the FileSystem dock, add an element to `weapons`, and drag your
# weapon .tscn into its `scene` slot — that's the whole registration step (see WeaponListing).
#
# WeaponInventory preloads Resources/Registries/weapon_registry.tres, so this list is what feeds the equip/quick-swap
# system AND the server: ServerEconomy, NetworkManager (tracer lookup) and the FFA pool all read
# the same registry through WeaponInventory. Because it is a preloaded resource holding
# PackedScene references, the exporter tracks those scenes as dependencies and packs them into
# the dedicated-server build (a bare load("res://...") string would not be tracked and would
# ship missing). Re-export the server after adding a weapon — the scene must bake into the binary.
#
# Entry order is the quick-swap slot order (first = key 1, second = key 2, ...).

@export var weapons: Array[WeaponListing] = []
