class_name DotLoadoutSiteSource
extends RefCounted

## Entitlements, app points and the saved loadout from the site store, for one game server.
## Bind [method source] to [member DotLoadoutManager.entitlement_source]; it answers from a cache,
## refreshes when stale, and wants [method refresh] on join. Needs the STORE_READ scope.
##
## Only the signed token is trusted: TMC's answer must carry a token that verifies against the pinned
## key ([member public_key]), names this server's scope ([member audience]) and this player, and has
## not expired. Anything else is logged as an error and grants nothing. See docs/design.md "Site tokens".

## A token was refused; the player gets no site entitlements until a read verifies.
signal rejected(player_key: String, reason: String)
## A token verified; [method ids_of], [method points_of] and [method loadout_of] answer from it.
signal refreshed(player_key: String)

const CHANNEL := "loadout.site"
const PATH := "store/entitlements"
## dot-cloud's verifier, loaded by path so a game without dot-cloud still runs (and refuses every token).
const CLOUD_SIGNATURE := "res://addons/dot_cloud/verify/dot_cloud_signature.gd"
const TOKEN_VERSION := 1
## The size of a raw Ed25519 public key, which is what TMC's `publicKey` holds.
const ED25519_KEY_BYTES := 32

## Any object with `get_integration(String, Dictionary) -> DotResult`.
var client: Object = null

## Seconds a player's answer is trusted before the next read is started; 0 keeps it until the token's `exp`.
var ttl_secs: float = 30.0

## The pinned key: TMC's `publicKey` (raw Ed25519, base64url) or an RSA public key PEM.
var public_key: String = ""

## This server's scope name; the token's `aud` must equal it.
var audience: String = ""

## Ask TMC for the member's app points and saved loadout too.
var include_points: bool = true
var include_loadout: bool = true

## Take `grant.unlock` from items the token verified. The grant itself is not in the token.
var unsigned_grants: bool = true

## Optional [DotLoadoutSiteSettings]; while its store section says `enabled: false` nothing is granted.
var settings: Object = null

## `func(bytes: PackedByteArray, signature: PackedByteArray, key: String) -> DotResult`; empty uses
## [method cloud_verify]. Tests inject one; a game should not.
var verifier: Callable = Callable()

## player key -> {"ids", "points", "loadout", "at", "exp"}
var _cache: Dictionary = {}
var _inflight: Dictionary = {}
var _configured := false


static func with_client(p_client: Object) -> DotLoadoutSiteSource:
	var s := DotLoadoutSiteSource.new()
	s.client = p_client
	return s


## A source set up from [param config] ([DotLoadoutConfig]). Fails when the pinned key cannot be read.
static func from_config(config: DotLoadoutConfig, p_client: Object = null) -> DotResult:
	var s := DotLoadoutSiteSource.with_client(p_client)
	var key := config.site_key()
	if not key.ok:
		return key
	s.public_key = key.value
	s.audience = config.site_audience
	s.ttl_secs = config.site_ttl_sec
	s.include_points = config.site_include_points
	s.include_loadout = config.site_include_loadout
	s.unsigned_grants = config.site_unsigned_grants
	return DotResult.success(s)


## Unlock ids from an entitlements response: each item's key, plus a string or array under `grant.unlock`.
## This reads the unsigned body; [method refresh] only uses it for keys the token verified.
static func ids_from(body: Dictionary) -> Array:
	var ids := {}
	var items: Variant = body.get("items", [])
	if not items is Array:
		return []
	for item: Variant in items:
		if not item is Dictionary:
			continue
		var d: Dictionary = item
		var key := str(d.get("key", ""))
		if key != "":
			ids[key] = true
		for e: String in _grant_ids(d):
			ids[e] = true
	return ids.keys()


static func _grant_ids(item: Dictionary) -> Array:
	var out: Array = []
	var grant: Variant = item.get("grant")
	if not grant is Dictionary:
		return out
	var extra: Variant = (grant as Dictionary).get("unlock")
	if extra is String and extra != "":
		out.append(extra)
	elif extra is Array:
		for e: Variant in extra:
			if e is String and e != "":
				out.append(e)
	return out


## Checks a token (`<payload b64url>.<signature b64url>`, signed over the payload text) and returns
## its payload. [param now_unix] is the wall clock in seconds.
static func verify_token(
	token: String, pinned_key: String, p_audience: String, player_key: String,
	now_unix: float, p_verifier: Callable = Callable()
) -> DotResult:
	if pinned_key.strip_edges() == "":
		return DotResult.fail(DotError.CODE_STATE, "No pinned site key; set site_public_key or site_public_key_path.")
	if p_audience == "":
		return DotResult.fail(DotError.CODE_STATE, "No site audience; set site_audience to this server's scope name.")
	var parts := token.split(".")
	if parts.size() != 2 or parts[0] == "" or parts[1] == "":
		return DotResult.fail(DotError.CODE_INTEGRITY, "The response carries no well-formed token.")
	var sig := DotHash.base64url_decode(parts[1])
	var signed := parts[0].to_ascii_buffer()
	var verified: Variant = p_verifier.call(signed, sig, pinned_key.strip_edges()) if p_verifier.is_valid() \
		else cloud_verify(signed, sig, pinned_key.strip_edges())
	if not verified is DotResult:
		return DotResult.fail(DotError.CODE_INTERNAL, "The token verifier returned no result.")
	if not (verified as DotResult).ok:
		return (verified as DotResult).wrap("The token signature did not verify")
	var payload: Variant = JSON.parse_string(DotHash.base64url_decode_text(parts[0]))
	if not payload is Dictionary:
		return DotResult.fail(DotError.CODE_PARSE, "The token payload is not an object.")
	var p: Dictionary = payload
	if int(p.get("v", 0)) != TOKEN_VERSION:
		return DotResult.fail(DotError.CODE_VERSION, "Unknown token version %s." % str(p.get("v")))
	if str(p.get("aud", "")) != p_audience:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "The token is for another app or server (aud %s)." % str(p.get("aud", "")))
	if str(p.get("sub", "")) != player_key:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "The token is for another player.")
	var expires: Variant = p.get("exp")
	if not (expires is float or expires is int) or float(expires) <= now_unix:
		return DotResult.fail(DotError.CODE_AUTH, "The token has expired.")
	return DotResult.success(p)


## The default verifier: dot-cloud's signature check. An RSA PEM key uses its RSA-SHA256 `verify`;
## a raw Ed25519 key needs its `verify_ed25519(bytes, signature, key_bytes)`, and fails loudly without.
static func cloud_verify(bytes: PackedByteArray, signature: PackedByteArray, key: String) -> DotResult:
	if not ResourceLoader.exists(CLOUD_SIGNATURE):
		return DotResult.fail(DotError.CODE_STATE, "dot-cloud is not installed, so site tokens cannot be verified.")
	var script: Script = load(CLOUD_SIGNATURE)
	if key.contains("BEGIN PUBLIC KEY"):
		return script.call("verify", bytes, Marshalls.raw_to_base64(signature), key)
	var raw := DotHash.base64url_decode(key)
	if raw.size() != ED25519_KEY_BYTES:
		return DotResult.fail(DotError.CODE_INVALID, "The pinned site key is neither an RSA PEM nor a raw Ed25519 key.")
	for m: Dictionary in script.get_script_method_list():
		if m.get("name") == "verify_ed25519":
			return script.call("verify_ed25519", bytes, signature, raw)
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This dot-cloud has no Ed25519 verifier, so TMC's token cannot be checked.")


## Reads the player's entitlements, points and loadout now. The value is the id array. A token that
## does not verify clears what was cached for the player, logs an error and emits [signal rejected].
## With no [member public_key] set, the first read takes the site_* keys from a layered [DotLoadoutConfig].
func refresh(player_key: String) -> DotResult:
	if client == null or not client.has_method("get_integration"):
		return DotResult.fail(DotError.CODE_STATE, "No backbone client with get_integration.")
	if _inflight.has(player_key):
		return DotResult.success(ids_of(player_key))
	if public_key == "" and not _configured:
		_configure(null)
	_inflight[player_key] = true
	var res: DotResult = await client.call("get_integration", PATH, _query(player_key))
	_inflight.erase(player_key)
	if not res.ok:
		DotLog.warn(CHANNEL, "store entitlements read failed", {"error": str(res.error)})
		return res
	if not res.value is Dictionary:
		return _reject(player_key, DotResult.fail(DotError.CODE_INVALID, "The entitlements response is not an object."))
	var body: Dictionary = res.value
	var sent_key := str(body.get("publicKey", ""))
	if sent_key != "" and public_key.strip_edges() != "" and not public_key.contains("BEGIN PUBLIC KEY") and sent_key != public_key.strip_edges():
		return _reject(player_key, DotResult.fail(DotError.CODE_INTEGRITY,
			"TMC signs with a key other than the pinned one (AUTH_SECRET rotated?); re-pin site_public_key."))
	var now := Time.get_unix_time_from_system()
	var checked := verify_token(str(body.get("token", "")), public_key, audience, player_key, now, verifier)
	if not checked.ok:
		return _reject(player_key, checked)
	var entry := _entry_from(checked.value, body, now)
	_cache[player_key] = entry
	refreshed.emit(player_key)
	return DotResult.success(entry["ids"])


func _query(player_key: String) -> Dictionary:
	var q := {"player": player_key}
	var include: PackedStringArray = []
	if include_points:
		include.append("points")
	if include_loadout:
		include.append("loadout")
	if not include.is_empty():
		q["include"] = ",".join(include)
	return q


func _reject(player_key: String, why: DotResult) -> DotResult:
	_cache[player_key] = {"ids": [], "points": {}, "loadout": [], "at": Time.get_ticks_msec() / 1000.0, "exp": 0.0}
	DotLog.error(CHANNEL, "site token rejected; granting nothing", {"player": player_key, "error": str(why.error)})
	rejected.emit(player_key, why.error.message)
	return why


## Ids come from the token's `items` ([store, key, expiresAt]); `grant.unlock` only for those keys.
func _entry_from(p: Dictionary, body: Dictionary, now: float) -> Dictionary:
	var ids := {}
	var items: Variant = p.get("items", [])
	if items is Array:
		for it: Variant in items:
			if not it is Array or (it as Array).size() < 2:
				continue
			var a: Array = it
			if a.size() > 2 and a[2] is String and a[2] != "" and _iso_unix(a[2]) <= now:
				continue
			if str(a[1]) != "":
				ids[str(a[1])] = true
	if unsigned_grants:
		var body_items: Variant = body.get("items", [])
		if body_items is Array:
			for item: Variant in body_items:
				if item is Dictionary and ids.has(str((item as Dictionary).get("key", ""))):
					for e: String in _grant_ids(item):
						ids[e] = true
	var points := {}
	if p.has("points"):
		var shown: Variant = body.get("points")
		var label := str((shown as Dictionary).get("label", "")) if shown is Dictionary else ""
		points = {"enabled": p["points"] != null, "balance": p["points"], "label": label}
	var loadout: Array = []
	var slots: Variant = p.get("loadout", [])
	if slots is Array:
		for s: Variant in slots:
			if s is Array and (s as Array).size() >= 3:
				loadout.append({"slot": str(s[0]), "store": str(s[1]), "key": str(s[2])})
	return {"ids": ids.keys(), "points": points, "loadout": loadout,
		"at": Time.get_ticks_msec() / 1000.0, "exp": float(p.get("exp", 0.0))}


static func _iso_unix(iso: String) -> float:
	return Time.get_unix_time_from_datetime_string(iso.trim_suffix("Z").get_slice(".", 0))


func _live(player_key: String) -> Dictionary:
	var entry: Dictionary = _cache.get(player_key, {})
	if entry.is_empty() or Time.get_unix_time_from_system() >= float(entry.get("exp", 0.0)):
		return {}
	return entry


## What is cached for the player; empty when nothing verified, the token expired or the store is off.
func ids_of(player_key: String) -> Array:
	if not _store_enabled():
		return []
	return _live(player_key).get("ids", [])


## The member's app points from the token: {enabled, balance, label}; empty when not read or rejected.
## `balance` is null while points are off for the app.
func points_of(player_key: String) -> Dictionary:
	return _live(player_key).get("points", {})


## The member's saved loadout from the token: [{slot, store, key}]; empty when not read or rejected.
func loadout_of(player_key: String) -> Array:
	return _live(player_key).get("loadout", [])


func _store_enabled() -> bool:
	if settings == null or not settings.has_method("section"):
		return true
	var store: Dictionary = settings.call("section", "store")
	return bool(store.get("enabled", true))


## Past [member ttl_secs] (when set) or the token's `exp`. A rejected answer (exp 0) waits only for the ttl,
## so a bad key does not turn every lookup into a read; with ttl 0 it is re-read on each lookup.
func _stale(entry: Dictionary) -> bool:
	if entry.is_empty():
		return true
	if ttl_secs > 0.0 and Time.get_ticks_msec() / 1000.0 - float(entry["at"]) > ttl_secs:
		return true
	var expires := float(entry.get("exp", 0.0))
	return (expires > 0.0 or ttl_secs <= 0.0) and Time.get_unix_time_from_system() >= expires


## The manager's `entitlement_source`.
func source(player_key: String) -> DotLoadoutEntitlements:
	if _stale(_cache.get(player_key, {})) and client != null:
		refresh(player_key)
	return DotLoadoutEntitlements.of(ids_of(player_key))


## An `entitlement_source` that answers [param base] (a Callable taking the player key and returning a
## [DotLoadoutEntitlements]; invalid means none) plus what the site store says the player owns.
## The backbone client is looked up from [DotRegistry] on first use, so a game with no backbone keeps
## exactly its [param base] answer. [param config] holds the pinned key; null reads a layered
## [DotLoadoutConfig] (file, `DOT_LOADOUT_*`, `--loadout-*`). Without a pinned key the site grants nothing.
static func layered(base: Callable = Callable(), config: DotLoadoutConfig = null) -> Callable:
	var site := DotLoadoutSiteSource.new()
	return func(key: String) -> DotLoadoutEntitlements:
		var ent: DotLoadoutEntitlements = DotLoadoutEntitlements.none()
		if base.is_valid():
			var got: Variant = base.call(key)
			if got is DotLoadoutEntitlements:
				ent.merge(got)
		if site.client == null:
			site.client = DotRegistry.get_service(&"dot_backbone_client")
		if site.client != null and not site._configured:
			site._configure(config)
		if site.client != null:
			ent.merge(site.source(key))
		return ent


func _configure(config: DotLoadoutConfig) -> void:
	_configured = true
	var cfg := config
	if cfg == null:
		cfg = DotLoadoutConfig.new()
		cfg.load_layered()
	var made := DotLoadoutSiteSource.from_config(cfg)
	if not made.ok:
		DotLog.error(CHANNEL, "site key unusable; the site grants nothing", {"error": str(made.error)})
		return
	var s: DotLoadoutSiteSource = made.value
	public_key = s.public_key
	audience = s.audience
	ttl_secs = s.ttl_secs
	include_points = s.include_points
	include_loadout = s.include_loadout
	unsigned_grants = s.unsigned_grants


func forget(player_key: String) -> void:
	_cache.erase(player_key)
