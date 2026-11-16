class_name DotLoadoutSiteSettings
extends RefCounted

## The app's public settings as TMC serves them (`GET settings`, any credential): `{appId, sections:
## {<name>: {version, values}}}`, sections `store`, `avatars` and `stats` among them. [method refresh]
## reads them; [method follow] keeps reading every [member poll_sec]. Each section whose `version`
## changed emits [signal section_changed], so a game follows an owner's edits without a restart.

## A section is new or its version changed. [param values] are TMC's field names as sent.
signal section_changed(section: String, values: Dictionary, version: int)
## A read failed; the last good sections stay in place.
signal failed(reason: String)

const CHANNEL := "loadout.site"
const PATH := "settings"

## Any object with `get_integration(String, Dictionary) -> DotResult`.
var client: Object = null

## Seconds between reads in [method follow]; 0 reads once and stops.
var poll_sec: float = 60.0

## TMC's app id from the last good read.
var app_id: String = ""

## section name -> {"version": int, "values": Dictionary}
var _sections: Dictionary = {}
## Bumped by [method follow] and [method stop]; a loop whose generation is old ends.
var _generation: int = 0
var _following := false


static func with_client(p_client: Object, p_poll_sec: float = 60.0) -> DotLoadoutSiteSettings:
	var s := DotLoadoutSiteSettings.new()
	s.client = p_client
	s.poll_sec = p_poll_sec
	return s


## A reader polling every [member DotLoadoutConfig.site_settings_poll_sec].
static func from_config(config: DotLoadoutConfig, p_client: Object) -> DotLoadoutSiteSettings:
	return with_client(p_client, config.site_settings_poll_sec)


## Reads the settings now. The value is the names of the sections that changed.
func refresh() -> DotResult:
	if client == null or not client.has_method("get_integration"):
		return DotResult.fail(DotError.CODE_STATE, "No backbone client with get_integration.")
	var res: DotResult = await client.call("get_integration", PATH, {})
	if not res.ok:
		DotLog.warn(CHANNEL, "app settings read failed", {"error": str(res.error)})
		failed.emit(res.error.message)
		return res
	var sections: Variant = (res.value as Dictionary).get("sections") if res.value is Dictionary else null
	if not sections is Dictionary:
		var bad := DotResult.fail(DotError.CODE_PARSE, "The settings response has no sections object.")
		DotLog.error(CHANNEL, "app settings malformed; keeping the last good ones", {"error": str(bad.error)})
		failed.emit(bad.error.message)
		return bad
	app_id = str((res.value as Dictionary).get("appId", app_id))
	var changed: PackedStringArray = []
	for name: Variant in (sections as Dictionary).keys():
		var sec: Variant = sections[name]
		if not sec is Dictionary or not (sec as Dictionary).get("values") is Dictionary:
			DotLog.warn(CHANNEL, "app settings section malformed; skipped", {"section": str(name)})
			continue
		var ver := int((sec as Dictionary).get("version", 0))
		var old: Dictionary = _sections.get(str(name), {})
		if not old.is_empty() and int(old["version"]) == ver:
			continue
		var values: Dictionary = (sec as Dictionary)["values"]
		_sections[str(name)] = {"version": ver, "values": values}
		changed.append(str(name))
		section_changed.emit(str(name), values, ver)
	return DotResult.success(changed)


## Reads now, then every [member poll_sec] until [method stop]. Needs a [SceneTree] for the timer.
func follow(tree: SceneTree) -> void:
	if _following:
		return
	_following = true
	_generation += 1
	var mine := _generation
	while mine == _generation:
		await refresh()
		if poll_sec <= 0.0 or tree == null or mine != _generation:
			break
		await tree.create_timer(poll_sec).timeout
	if mine == _generation:
		_following = false


func stop() -> void:
	_generation += 1
	_following = false


## The section's values, empty before the first good read.
func section(name: String) -> Dictionary:
	return (_sections.get(name, {}) as Dictionary).get("values", {})


## The section's version, -1 before the first good read.
func version(name: String) -> int:
	return int((_sections.get(name, {}) as Dictionary).get("version", -1))


## One field of a section, or [param fallback] when the section or field is absent.
func value(section_name: String, field: String, fallback: Variant = null) -> Variant:
	return section(section_name).get(field, fallback)
