@tool
extends EditorPlugin

## Editor entry point for GameSpice Loadout. Registers inspector types only.
##
## No autoload, for the family's reason: a process may run a server and a client at
## once, and a singleton loadout manager makes that impossible. [GSLoadoutManager]
## registers itself in [GSRegistry] instead.

const _ICON := "res://addons/gs_loadout/icon_placeholder.svg"

const _TYPES := [
	[
		"GSLoadoutManager",
		"Node",
		"res://addons/gs_loadout/gs_loadout_manager.gd",
	],
	[
		"GSPickup",
		"Node3D",
		"res://addons/gs_loadout/world/gs_pickup.gd",
	],
	[
		"GSPickupField",
		"Node",
		"res://addons/gs_loadout/world/gs_pickup_field.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
