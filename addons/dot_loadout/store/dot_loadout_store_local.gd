class_name DotLoadoutStoreLocal
extends DotLoadoutStore

## Loadouts as JSON files under a directory. The default, and it works unconfigured.
##
## One file per player, for the reason GameSpice User's profile store gives: a single file
## is rewritten in full on every change and loses everything rather than one record
## when a write is interrupted. The file carries a schema [constant VERSION]; a file this
## build cannot read is set aside as `.corrupt` (never deleted), so one bad file costs that
## player their saves and nothing else.

const LOCAL_CHANNEL := "loadout.store.local"

const VERSION := 1

## Largest file read or written, in bytes; 0 is unlimited. The `mp_loadout_store_max_bytes` cvar.
var max_file_bytes: int = 65536

## Most player files in the directory; 0 is unlimited. The `mp_loadout_store_max_files` cvar.
var max_files: int = 20000

var directory: String = "user://loadouts"

## Write through a temporary file and rename over the target. [DotSaveStoreFile] does the
## temporary file, the rename and the browser's IndexedDB flush.
var atomic_writes: bool = true

var _files: DotSaveStoreFile


static func at(path: String) -> DotLoadoutStoreLocal:
	# Not this class's own name. A script that names itself in an expression, loaded after
	# its base, cuts Godot 4.7.2's exit teardown short and leaks every script loaded before
	# it. See docs/gdscript-hazards.md, "A script that names itself".
	var s := new()
	s.directory = path
	return s


func _store_name() -> String:
	return "DotLoadoutStoreLocal"


func _open() -> DotResult:
	var made := DotPaths.ensure_dir(directory)

	if not made.ok:
		return made.wrap("Could not open the loadout directory.")

	DotLog.debug(LOCAL_CHANNEL, "loadout store open", {"directory": directory})
	return DotResult.success(true)


## The file store under this one, with the folder, quota and write mode as they stand now.
func files() -> DotSaveStoreFile:
	if _files == null:
		_files = DotSaveStoreFile.new()
		_files.suffix = ".json"
		_files.key_check = func(key: String) -> bool: return DotPaths.safe_relative(key + ".json").ok
	_files.directory = directory
	_files.atomic = atomic_writes
	_files.max_files = max_files
	return _files


# ':' is legal in a key but not in a filename on every platform; '~' is in neither's alphabet.
func _file_key(user_key: String) -> String:
	return user_key.replace(":", "~")


func _path_for(user_key: String) -> DotResult:
	var key := _file_key(user_key)
	var relative := DotPaths.safe_relative("%s.json" % key)

	if not relative.ok:
		return relative.wrap("That key is not a usable filename.")

	return DotResult.success(files().path_for(key))


func _fetch(user_key: String) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	if not FileAccess.file_exists(path.value):
		return DotResult.success(null)

	var size := _size_of(path.value)

	if max_file_bytes > 0 and size > max_file_bytes:
		return _set_aside(path.value, "the file is %d bytes, over the %d cap" % [size, max_file_bytes])

	var read := DotPaths.read_json(path.value)

	if not read.ok or not (read.value is Dictionary):
		return _set_aside(path.value, "the file does not parse")

	var data: Dictionary = read.value
	var version: Variant = data.get("version", 1)

	if typeof(version) != TYPE_INT and typeof(version) != TYPE_FLOAT:
		return _set_aside(path.value, "the version is not a number")

	if int(version) > VERSION:
		# Written by a newer build: keep it where it is, so rolling back loses nothing.
		return DotResult.fail(
			DotError.CODE_VERSION, "Stored loadouts are version %d, this build reads %d." % [int(version), VERSION]
		)

	var raw: Variant = data.get("loadouts", [])

	if typeof(raw) != TYPE_ARRAY:
		return _set_aside(path.value, "there is no loadout array")

	var out: Array[DotLoadout] = []

	for entry in (raw as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			continue

		var parsed := DotLoadout.from_dictionary(entry as Dictionary)

		if not parsed.ok:
			return _set_aside(path.value, "a loadout in it is malformed")

		out.append(parsed.value)

	return DotResult.success(null if out.is_empty() else out)


func _size_of(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_length() if file != null else 0


## Moves an unreadable file aside to `.corrupt` and reports "no loadouts": the player can save
## again, and the old bytes stay on disk for a person to recover.
func _set_aside(path: String, why: String) -> DotResult:
	var moved := files().set_aside(path.get_file().trim_suffix(".json"))
	if not moved.ok:
		DotLog.warn(LOCAL_CHANNEL, "a loadout file could not be set aside", {"path": path, "why": why})
	return DotResult.success(null)


func _store(user_key: String, loadouts: Array[DotLoadout]) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	var plain := []

	for loadout in loadouts:
		plain.append(loadout.to_dictionary())

	var text := JSON.stringify({"version": VERSION, "loadouts": plain}, "\t")

	if max_file_bytes > 0 and text.to_utf8_buffer().size() > max_file_bytes:
		return DotResult.fail(
			DotError.CODE_QUOTA, "Your saved loadouts are too large (mp_loadout_store_max_bytes %d)." % max_file_bytes
		)

	var written := files().write(_file_key(user_key), text)

	if written.code() == DotError.CODE_QUOTA:
		return DotResult.fail(
			DotError.CODE_QUOTA, "This server keeps no more players' loadouts (mp_loadout_store_max_files %d)." % max_files
		)

	if not written.ok:
		return written.wrap("Could not write the loadouts.")

	return DotResult.success(true)


func _remove(user_key: String) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	if not FileAccess.file_exists(path.value):
		return DotResult.success(true)

	var removed := files().remove(_file_key(user_key))

	if not removed.ok:
		return removed.wrap("Removing the loadouts")

	return DotResult.success(true)


func describe() -> Dictionary:
	var out := super.describe()
	out["directory"] = directory
	out["max_file_bytes"] = max_file_bytes
	out["max_files"] = max_files
	return out
