class_name GSLoadoutSiteKeys
extends RefCounted

## The site's published entitlement signing keys (`GET store/keys`, no credential needed), followed so
## a key rotation at the site needs nothing done on any server. The list comes over the same client
## (and so the same validated HTTPS origin) as the entitlements themselves; a key is never taken from
## the entitlements answer it would verify. See docs/design.md#following-the-site-key-list.

## A good read changed the set of keys; [param kids] is the new list, current key first.
signal changed(kids: PackedStringArray)
## A read failed or was refused; the last good list stays in use (until the grace runs out).
signal failed(reason: String)

const CHANNEL := "loadout.site"
const PATH := "store/keys"
const ALG := "Ed25519"
const ED25519_KEY_BYTES := 32
## A `kid` is this many base64url characters of the SHA-256 of the raw key (website-city's EntitlementKid).
const KID_CHARS := 16

## Any object with `get_integration(String, Dictionary) -> GSResult`; a `config.backbone_url` names the origin.
var client: Object = null

## Seconds a good list is used before it is read again; 0 keeps it until a token names an unknown `kid`.
var ttl_sec: float = 300.0

## Least seconds between two reads (an unknown `kid` or a failing site); 0 is no limit.
var refetch_min_sec: float = 30.0

## Seconds past [member ttl_sec] the last good list is still used while the site cannot be read; 0 is unlimited.
var grace_sec: float = 86400.0

## Follow a plain-HTTP origin other than loopback. Off: refused, since anyone on the path could hand over a key.
var allow_http: bool = false

## `func() -> float`, the wall clock in Unix seconds; empty is the system clock. Tests set it.
var now_fn: Callable = Callable()

## kid -> raw public key (base64url), and the kids in the site's order (current first).
var _keys: Dictionary = {}
var _order: PackedStringArray = []
var _ok_at: float = -1.0
var _tried_at: float = -1.0
var _last_error: String = ""
var _fetching := false
var _reads: int = 0


static func with_client(p_client: Object) -> GSLoadoutSiteKeys:
	var k := GSLoadoutSiteKeys.new()
	k.client = p_client
	return k


static func from_config(config: GSLoadoutConfig, p_client: Object) -> GSLoadoutSiteKeys:
	var k := with_client(p_client)
	k.ttl_sec = config.site_keys_ttl_sec
	k.refetch_min_sec = config.site_keys_refetch_min_sec
	k.grace_sec = config.site_keys_grace_sec
	k.allow_http = config.site_keys_allow_http
	return k


## The `kid` the site gives [param public_key] (raw Ed25519, base64url): 16 base64url characters of its SHA-256.
static func kid_of(public_key: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(GSHash.base64url_decode(public_key.strip_edges()))
	return GSHash.base64url_encode(ctx.finish()).substr(0, KID_CHARS)


## The `kid` in a token's payload, or "" when it has none (a v1 token) or is not a token.
static func token_kid(token: String) -> String:
	var payload: Variant = JSON.parse_string(GSHash.base64url_decode_text(token.get_slice(".", 0)))
	return str((payload as Dictionary).get("kid", "")) if payload is Dictionary else ""


## Checks a `store/keys` answer, `{keys: [{kid, alg, publicKey, current}]}`. The value is `[[kid, key], ...]`
## in the site's order. One bad entry (wrong alg, not 32 bytes, a `kid` that is not its key's) refuses all.
static func parse(body: Variant) -> GSResult:
	var list: Variant = (body as Dictionary).get("keys") if body is Dictionary else null
	if not list is Array or (list as Array).is_empty():
		return GSResult.fail(GSError.CODE_PARSE, "The key list answer has no keys array.")
	var out: Array = []
	for e: Variant in list:
		if not e is Dictionary:
			return GSResult.fail(GSError.CODE_PARSE, "A key list entry is not an object.")
		var d: Dictionary = e
		var key := str(d.get("publicKey", "")).strip_edges()
		var kid := str(d.get("kid", ""))
		if str(d.get("alg", "")) != ALG:
			return GSResult.fail(GSError.CODE_UNSUPPORTED, "Key %s has alg %s, not %s." % [kid, str(d.get("alg", "")), ALG])
		if GSHash.base64url_decode(key).size() != ED25519_KEY_BYTES:
			return GSResult.fail(GSError.CODE_INVALID, "Key %s is not a raw 32-byte Ed25519 key." % kid)
		if kid != kid_of(key):
			return GSResult.fail(GSError.CODE_INTEGRITY, "Key %s does not hash to its kid; the list was altered." % kid)
		out.append([kid, key])
	return GSResult.success(out)


## The keys a token naming [param kid] may verify against; the value is an Array of keys. Reads the list
## when it is stale or [param kid] is unknown (rate-limited by [member refetch_min_sec]); an empty
## [param kid] (a v1 token) gets every listed key. Fails, with what to do, when there is no usable list.
func keys_for(kid: String) -> GSResult:
	var now := _now()
	var stale := _ok_at < 0.0 or (ttl_sec > 0.0 and now - _ok_at >= ttl_sec)
	if _fetching:
		# A read is already in flight (several players at once on a fresh server): wait for it, so a
		# caller is never told "never been read" for a list that is arriving.
		await fetch()
		now = _now()
		stale = _ok_at < 0.0 or (ttl_sec > 0.0 and now - _ok_at >= ttl_sec)
	if (stale or (kid != "" and not _keys.has(kid))) and _may_read(now):
		await fetch()
		now = _now()
	if _ok_at < 0.0:
		return GSResult.fail(GSError.CODE_NETWORK, "The site's key list (%s) has never been read (%s); the site grants nothing until it is." % [where(), _last_error])
	if grace_sec > 0.0 and ttl_sec > 0.0 and now - _ok_at > ttl_sec + grace_sec:
		return GSResult.fail(GSError.CODE_NETWORK, "The site's key list (%s) was last read %d s ago, past site_keys_grace_sec (%d s), so nothing is granted (%s)." % [
			where(), int(now - _ok_at), int(grace_sec), _last_error])
	if kid == "":
		return GSResult.success(Array(_order).map(func(k: String) -> String: return _keys[k]))
	if not _keys.has(kid):
		return GSResult.fail(GSError.CODE_INTEGRITY, "The token's kid %s is not in the site's key list (%s: %s); it was not signed by the site.%s" % [
			kid, where(), ", ".join(_order), _wait_note(now)])
	return GSResult.success([_keys[kid]])


## Reads the list now. A failed or refused read keeps the last good list and logs why, once per read.
func fetch() -> GSResult:
	while _fetching:
		await Engine.get_main_loop().process_frame
		if not _fetching:
			return GSResult.success(_order) if _last_error == "" else GSResult.fail(GSError.CODE_NETWORK, _last_error)
	_fetching = true
	_tried_at = _now()
	_reads += 1
	var res := await _read()
	_fetching = false
	if not res.ok:
		_last_error = str(res.error)
		GSLog.error(CHANNEL, "site key list unusable; keeping the last good one", {"origin": where(), "error": _last_error,
			"last_good_age_sec": int(_now() - _ok_at) if _ok_at >= 0.0 else -1})
		failed.emit(_last_error)
		return res
	_last_error = ""
	_ok_at = _now()
	var order := PackedStringArray()
	var keys := {}
	for pair: Array in res.value:
		keys[pair[0]] = pair[1]
		order.append(pair[0])
	if order != _order:
		var was := _order
		_keys = keys
		_order = order
		GSLog.info(CHANNEL, "site signing keys", {"current": order[0], "kids": ", ".join(order), "was": ", ".join(was)})
		changed.emit(order)
	return GSResult.success(order)


func _read() -> GSResult:
	if client == null or not client.has_method("get_integration"):
		return GSResult.fail(GSError.CODE_STATE, "No backbone client with get_integration to read the key list.")
	var insecure := insecure_origin()
	if insecure != "":
		return GSResult.fail(GSError.CODE_FORBIDDEN, insecure)
	var res: GSResult = await client.call("get_integration", PATH, {})
	if not res.ok:
		return res.wrap("Reading %s failed" % where())
	return parse(res.value)


## Why the origin may not be followed ("" when it may): plain HTTP to anything but loopback, unless allowed.
func insecure_origin() -> String:
	var url := origin()
	if allow_http or not url.begins_with("http://"):
		return ""
	var authority := url.trim_prefix("http://").get_slice("/", 0)
	var host := authority.get_slice("]", 0) + "]" if authority.begins_with("[") else authority.get_slice(":", 0)
	if host in ["localhost", "127.0.0.1", "[::1]"]:
		return ""
	return "The site origin %s is plain HTTP, so its key list could come from anyone on the path. Use https, pin site_public_key, or set site_keys_allow_http for a lab." % url


## The site origin the client talks to, "" when it does not say.
func origin() -> String:
	if client == null or not "config" in client:
		return ""
	var cfg: Variant = client.get("config")
	return str(cfg.get("backbone_url")).trim_suffix("/") if cfg is Object and "backbone_url" in cfg else ""


## Where the list is read from, for messages.
func where() -> String:
	return (origin() if origin() != "" else "<site>") + "/api/integration/v1/" + PATH


func _may_read(now: float) -> bool:
	return refetch_min_sec <= 0.0 or _tried_at < 0.0 or now - _tried_at >= refetch_min_sec


func _wait_note(now: float) -> String:
	if _may_read(now):
		return ""
	return " Read again in %d s at the earliest (site_keys_refetch_min_sec)." % int(ceil(refetch_min_sec - (now - _tried_at)))


func _now() -> float:
	return float(now_fn.call()) if now_fn.is_valid() else Time.get_unix_time_from_system()


## The listed kids, current first.
func kids() -> PackedStringArray:
	return _order


## For a status command: the kids, how old the list is, how many reads, the last error.
func describe() -> Dictionary:
	return {"origin": where(), "kids": ", ".join(_order), "age_sec": int(_now() - _ok_at) if _ok_at >= 0.0 else -1,
		"reads": _reads, "last_error": _last_error}
