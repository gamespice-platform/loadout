class_name GSLoadoutStoreProfile
extends GSLoadoutStore

## Stub for loadouts kept in the profile document (route not implemented): every call refuses
## with CODE_UNSUPPORTED, so fall back to [GSLoadoutStoreTiered]. A real backend fills
## [member fetcher] and [member saver] (or subclasses `_fetch` and `_store`).

## func(user_key) -> GSResult of Array[GSLoadout] or null.
var fetcher: Callable = Callable()

## func(user_key, loadouts: Array[GSLoadout]) -> GSResult.
var saver: Callable = Callable()


func _store_name() -> String:
	return "GSLoadoutStoreProfile"


func _writable() -> bool:
	return saver.is_valid()


func _fetch(user_key: String) -> GSResult:
	if not fetcher.is_valid():
		return GSResult.fail(GSError.CODE_UNSUPPORTED, "No profile-document loadout backend is wired.")
	return await fetcher.call(user_key)


func _store(user_key: String, loadouts: Array[GSLoadout]) -> GSResult:
	if not saver.is_valid():
		return GSResult.fail(GSError.CODE_UNSUPPORTED, "No profile-document loadout backend is wired.")
	return await saver.call(user_key, loadouts)


func _remove(_user_key: String) -> GSResult:
	return GSResult.fail(GSError.CODE_UNSUPPORTED, "No profile-document loadout backend is wired.")
