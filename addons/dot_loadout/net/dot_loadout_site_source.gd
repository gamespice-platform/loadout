class_name DotLoadoutSiteSource
extends RefCounted

## Site store entitlements, points and loadout for one server ([method source] as the entitlement_source,
## [method refresh] on join). Trusts only an unexpired token for [member audience] and this player, signed
## by a key in the site's list ([member keys], default) or the strict pin [member public_key]. See docs/design.md.

## A token was refused; the player gets no site entitlements until a read verifies.
signal rejected(player_key: String, reason: String)
## A token verified; [method ids_of], [method points_of] and [method loadout_of] answer from it.
signal refreshed(player_key: String)

const CHANNEL := "loadout.site"
const PATH := "store/entitlements"
## GameSpice Cloud's verifier, loaded by path so a game without GameSpice Cloud still runs (and refuses every token).
const CLOUD_SIGNATURE := "res://addons/dot_cloud/verify/dot_cloud_signature.gd"
## The newest token version read; 2 signs each item's unlock ids, 1 signs only the item keys.
const TOKEN_VERSION := 2
const OLDEST_TOKEN_VERSION := 1
## STORE_WRITE: buys an item with the member's app points and answers like [constant PATH].
const PURCHASE_PATH := "store/purchase"
## Any credential: which target (`server:<id>`) this credential is for, the token's `aud`.
const ME_PATH := "me"
## The size of a raw Ed25519 public key, which is what TMC's `publicKey` holds.
const ED25519_KEY_BYTES := 32

## Any object with `get_integration(String, Dictionary) -> DotResult` ([method purchase] also needs `post_integration`).
var client: Object = null

## Seconds a player's answer is trusted before the next read is started; 0 keeps it until the token's `exp`.
var ttl_secs: float = 30.0

## The strict pin (hardened mode): the site's `publicKey` (raw Ed25519, base64url) or an RSA public key
## PEM. Empty (the default) verifies against [member keys], the site's published list.
var public_key: String = ""

## The followed key list, made on first use when [member public_key] is empty.
var keys: DotLoadoutSiteKeys = null

## This server's scope name; the token's `aud` must equal it. Empty while following asks the site (`GET me`).
var audience: String = ""

## Ask TMC for the member's app points and saved loadout too.
var include_points: bool = true
var include_loadout: bool = true

## Also take `grant.unlock` from the unsigned body for keys a v1 token verified. Off: a v2 token signs the unlock ids.
var unsigned_grants: bool = false

## Optional [DotLoadoutSiteSettings]; while its store section says `enabled: false` nothing is granted.
var settings: Object = null

## `func(bytes: PackedByteArray, signature: PackedByteArray, key: String) -> DotResult`; empty uses
## [method cloud_verify]. Tests inject one; a game should not.
var verifier: Callable = Callable()

## player key -> {"ids", "points", "loadout", "at", "exp"}
var _cache: Dictionary = {}
var _inflight: Dictionary = {}
var _configured := false
var _audience_tried_at: float = -1.0


static func with_client(p_client: Object) -> DotLoadoutSiteSource:
	var s := DotLoadoutSiteSource.new()
	s.client = p_client
	return s


## A source set up from [param config] ([DotLoadoutConfig]): following the site's key list, or pinned
## when the config sets a key. Fails only when a configured pin cannot be read.
static func from_config(config: DotLoadoutConfig, p_client: Object = null) -> DotResult:
	var s := DotLoadoutSiteSource.with_client(p_client)
	var key := config.site_key()
	if not key.ok:
		return key
	s.public_key = key.value
	if s.public_key == "":
		s.keys = DotLoadoutSiteKeys.from_config(config, p_client)
	s.audience = config.site_audience
	s.ttl_secs = config.site_ttl_sec
	s.include_points = config.site_include_points
	s.include_loadout = config.site_include_loadout
	s.unsigned_grants = config.site_unsigned_grants
	s._configured = true
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
	var grant: Variant = item.get("grant")
	return _unlock_ids((grant as Dictionary).get("unlock")) if grant is Dictionary else []


static func _unlock_ids(extra: Variant) -> Array:
	var out: Array = []
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
		return DotResult.fail(DotError.CODE_STATE, "No site key to verify against.")
	return verify_token_any(token, [pinned_key.strip_edges()], p_audience, player_key, now_unix, p_verifier)


## [method verify_token] against any of [param keys]: the first that verifies the signature counts.
static func verify_token_any(
	token: String, keys: Array, p_audience: String, player_key: String,
	now_unix: float, p_verifier: Callable = Callable()
) -> DotResult:
	if keys.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "No site key to verify against.")
	if p_audience == "":
		return DotResult.fail(DotError.CODE_STATE, "No site audience; set site_audience to this server's scope name.")
	var parts := token.split(".")
	if parts.size() != 2 or parts[0] == "" or parts[1] == "":
		return DotResult.fail(DotError.CODE_INTEGRITY, "The response carries no well-formed token.")
	var sig := DotHash.base64url_decode(parts[1])
	var signed := parts[0].to_ascii_buffer()
	var verified: Variant = null
	for key: Variant in keys:
		verified = p_verifier.call(signed, sig, str(key)) if p_verifier.is_valid() else cloud_verify(signed, sig, str(key))
		if not verified is DotResult:
			return DotResult.fail(DotError.CODE_INTERNAL, "The token verifier returned no result.")
		if (verified as DotResult).ok:
			break
	if not (verified as DotResult).ok:
		return (verified as DotResult).wrap("The token signature did not verify")
	var payload: Variant = JSON.parse_string(DotHash.base64url_decode_text(parts[0]))
	if not payload is Dictionary:
		return DotResult.fail(DotError.CODE_PARSE, "The token payload is not an object.")
	var p: Dictionary = payload
	var version := int(p.get("v", 0))
	if version < OLDEST_TOKEN_VERSION or version > TOKEN_VERSION:
		return DotResult.fail(DotError.CODE_VERSION, "Unknown token version %s." % str(p.get("v")))
	if str(p.get("aud", "")) != p_audience:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "The token is for another app or server (aud %s)." % str(p.get("aud", "")))
	if str(p.get("sub", "")) != player_key:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "The token is for another player.")
	var expires: Variant = p.get("exp")
	if not (expires is float or expires is int) or float(expires) <= now_unix:
		return DotResult.fail(DotError.CODE_AUTH, "The token has expired.")
	return DotResult.success(p)


## The default verifier: GameSpice Cloud's signature check. An RSA PEM key uses its RSA-SHA256 `verify`;
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
	return await ingest(player_key, res.value)


## Applies a site store answer that carries a token (an entitlements read or a [method purchase]) at
## once, so a purchase counts without waiting for [member ttl_secs]. Same checks and value as
## [method refresh]. Await it: following the key list may read the list first.
func ingest(player_key: String, answer: Variant) -> DotResult:
	if public_key == "" and not _configured:
		_configure(null)
	if not answer is Dictionary:
		return _reject(player_key, DotResult.fail(DotError.CODE_INVALID, "The entitlements response is not an object."))
	var body: Dictionary = answer
	var token := str(body.get("token", ""))
	var trusted := await _keys_for(token, str(body.get("publicKey", "")))
	if not trusted.ok:
		return _reject(player_key, trusted)
	if audience == "" and public_key == "":
		await _learn_audience()
	var now := Time.get_unix_time_from_system()
	var checked := verify_token_any(token, trusted.value, audience, player_key, now, verifier)
	if not checked.ok:
		return _reject(player_key, checked)
	var entry := _entry_from(checked.value, body, now)
	_cache[player_key] = entry
	refreshed.emit(player_key)
	return DotResult.success(entry["ids"])


## The keys [param token] may verify against: the strict pin, or the followed list's key for its `kid`.
func _keys_for(token: String, sent_key: String) -> DotResult:
	var pin := public_key.strip_edges()
	if pin != "":
		var kid := DotLoadoutSiteKeys.token_kid(token)
		var raw := not pin.contains("BEGIN PUBLIC KEY")
		if raw and ((sent_key != "" and sent_key != pin) or (kid != "" and kid != DotLoadoutSiteKeys.kid_of(pin))):
			return DotResult.fail(DotError.CODE_INTEGRITY, ("The site signs with key %s, not the pinned site_public_key (%s): it rotated its key. "
				+ "Re-pin site_public_key, or clear site_public_key and site_public_key_path to follow the site's key list.") % [
				kid if kid != "" else DotLoadoutSiteKeys.kid_of(sent_key), DotLoadoutSiteKeys.kid_of(pin)])
		return DotResult.success([pin])
	if keys == null:
		keys = DotLoadoutSiteKeys.with_client(client)
	if keys.client == null:
		keys.client = client
	return await keys.keys_for(DotLoadoutSiteKeys.token_kid(token))


## Following, with no [member audience] set: asks the site which target this credential is for
## (`GET me` -> `target {kind, id}`), at most once per [member DotLoadoutSiteKeys.refetch_min_sec].
func _learn_audience() -> void:
	var now := Time.get_unix_time_from_system()
	var gap := keys.refetch_min_sec if keys != null else 30.0
	if client == null or (_audience_tried_at >= 0.0 and gap > 0.0 and now - _audience_tried_at < gap):
		return
	_audience_tried_at = now
	var res: DotResult = await client.call("get_integration", ME_PATH, {})
	var target: Variant = (res.value as Dictionary).get("target") if res.ok and res.value is Dictionary else null
	if not target is Dictionary or str((target as Dictionary).get("kind", "")) == "" or (target as Dictionary).get("id") == null:
		DotLog.error(CHANNEL, "site audience unknown; set site_audience to this server's scope name (server:<id>)",
			{"error": str(res.error) if not res.ok else "no target in the me answer"})
		return
	var id: Variant = target["id"]
	audience = "%s:%s" % [str(target["kind"]), str(int(id)) if id is float else str(id)]
	DotLog.info(CHANNEL, "site audience from the credential", {"audience": audience})


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


## Ids come from the token's `items` ([store, key, expiresAt] in v1, plus the unlock ids in v2); with
## [member unsigned_grants] the body's `grant.unlock` is added for those keys.
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
			for e: String in _unlock_ids(a[3] if a.size() > 3 else null):
				ids[e] = true
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
	if entry.is_empty() or entry.get("stale", false):
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


## An `entitlement_source`: [param base] (player key -> [DotLoadoutEntitlements]; invalid is none) plus
## what the site store says the player owns. Client from [DotRegistry] on first use (none: [param base]
## stands); [param config] holds site_* (null: a layered [DotLoadoutConfig]).
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
	var made := DotLoadoutSiteSource.from_config(cfg, client)
	if not made.ok:
		DotLog.error(CHANNEL, "site key config unusable; the site grants nothing", {"error": str(made.error)})
		return
	var s: DotLoadoutSiteSource = made.value
	public_key = s.public_key
	if keys == null:
		keys = s.keys
	audience = s.audience
	ttl_secs = s.ttl_secs
	include_points = s.include_points
	include_loadout = s.include_loadout
	unsigned_grants = s.unsigned_grants
	DotLog.info(CHANNEL, "site token keys", {"mode": "pinned" if public_key != "" else "follow the site key list",
		"audience": audience if audience != "" else "(asked of the site)"})


## "pinned" with a strict [member public_key], else "follow".
func key_mode() -> String:
	return "pinned" if public_key.strip_edges() != "" else "follow"


## Buys [param item_id] for the player with their app points (TMC's STORE_WRITE scope) and applies the
## answer's token at once. The value is TMC's answer (`status`, `purchase`, `points`, `items`). An empty
## [param idem_key] makes one, so a retry of the same press must pass the same key.
func purchase(player_key: String, item_id: String, idem_key: String = "") -> DotResult:
	if client == null or not client.has_method("post_integration"):
		return DotResult.fail(DotError.CODE_STATE, "No backbone client with post_integration.")
	if player_key == "" or item_id == "":
		return DotResult.fail(DotError.CODE_INVALID, "A purchase needs a player and an item.")
	var body := _query(player_key)
	body["itemId"] = item_id
	body["idemKey"] = idem_key if idem_key != "" else "%s:%s:%d:%d" % [player_key, item_id, Time.get_unix_time_from_system(), randi()]
	var res: DotResult = await client.call("post_integration", PURCHASE_PATH, body)
	if not res.ok:
		DotLog.warn(CHANNEL, "store purchase failed", {"player": player_key, "item": item_id, "error": str(res.error)})
		return res
	var applied: DotResult = await ingest(player_key, res.value)
	return DotResult.success(res.value) if applied.ok else applied


## Waits for a read when the player's answer is stale (or [param force]); a fresh one is returned as is.
## Call on join so the first loadout check sees the site items, not an empty answer.
func ensure(player_key: String, force: bool = false) -> DotResult:
	if not force and not _stale(_cache.get(player_key, {})):
		return DotResult.success(ids_of(player_key))
	while _inflight.has(player_key):
		await Engine.get_main_loop().process_frame
	if not force and not _stale(_cache.get(player_key, {})):
		return DotResult.success(ids_of(player_key))
	return await refresh(player_key)


## The next lookup reads again while the old answer still counts (a purchase made on the website).
func mark_stale(player_key: String) -> void:
	if _cache.has(player_key):
		(_cache[player_key] as Dictionary)["stale"] = true


func forget(player_key: String) -> void:
	_cache.erase(player_key)
