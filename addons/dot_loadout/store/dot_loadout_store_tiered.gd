class_name GSLoadoutStoreTiered
extends GSLoadoutStore

## Durable storage for players with a stable key, memory for the rest (guests and bots change
## key every session, so writing them only fills the disk). [member is_durable] says which.

var durable: GSLoadoutStore = null
var volatile: GSLoadoutStore = GSLoadoutStoreMemory.new()

## func(user_key: String) -> bool. Unset, every key is durable.
var is_durable: Callable = Callable()


static func of(p_durable: GSLoadoutStore, p_is_durable: Callable = Callable()) -> GSLoadoutStoreTiered:
	var s := new()
	s.durable = p_durable
	s.is_durable = p_is_durable
	return s


func _store_name() -> String:
	return "GSLoadoutStoreTiered"


func _pick(user_key: String) -> GSLoadoutStore:
	return durable if not is_durable.is_valid() or bool(is_durable.call(user_key)) else volatile


func _fetch(user_key: String) -> GSResult:
	return await _pick(user_key).fetch(user_key)


func _store(user_key: String, loadouts: Array[GSLoadout]) -> GSResult:
	return await _pick(user_key).store(user_key, loadouts)


func _remove(user_key: String) -> GSResult:
	return await _pick(user_key).remove(user_key)


func _writable() -> bool:
	return durable.is_writable()


func describe() -> Dictionary:
	var out := super.describe()
	out["durable"] = durable.describe()
	out["volatile"] = volatile.describe()
	return out
