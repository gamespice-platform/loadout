class_name GSLoadoutStoreMemory
extends GSLoadoutStore

## Loadouts in a dictionary. For tests, for a listen server, and for a mode where
## loadouts are per-match and never outlive it.

var _records: Dictionary = {}


func _store_name() -> String:
	return "GSLoadoutStoreMemory"


func _fetch(user_key: String) -> GSResult:
	var held: Array = _records.get(user_key, [])
	var out: Array[GSLoadout] = []

	# Copies, not the stored objects. Handing out the stored instance lets a caller
	# mutate what is "saved" without ever calling store(), which then disagrees with
	# what a real backing store would have.
	for loadout in held:
		out.append((loadout as GSLoadout).duplicate_loadout())

	return GSResult.success(null if out.is_empty() else out)


func _store(user_key: String, loadouts: Array[GSLoadout]) -> GSResult:
	var copies: Array[GSLoadout] = []

	for loadout in loadouts:
		copies.append(loadout.duplicate_loadout())

	_records[user_key] = copies
	return GSResult.success(true)


func _remove(user_key: String) -> GSResult:
	_records.erase(user_key)
	return GSResult.success(true)


func size() -> int:
	return _records.size()


func clear() -> void:
	_records.clear()


func describe() -> Dictionary:
	var out := super.describe()
	out["players"] = size()
	return out
