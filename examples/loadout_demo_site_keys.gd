extends "loadout_demo_spawn_pricing.gd"

## Suite section: following the site's published signing keys (rotation, unknown kid, an unreachable or
## altered list) and the strict pin. Keys are made at test time; a stand-in verifier accepts a signature
## that names its key, so this tests key selection, not Ed25519 (loadout_demo.gd does that).

const AUD := "server:7"

## The fake wall clock the key list reads, in Unix seconds.
var _clock := [1_000_000.0]


func _test_site_keys_follow() -> void:
	_section("site key list: bootstrap and rotation")
	var old_key := GSHash.base64url_encode(GSHash.random_bytes(32))
	var new_key := GSHash.base64url_encode(GSHash.random_bytes(32))
	var old_kid := GSLoadoutSiteKeys.kid_of(old_key)
	var new_kid := GSLoadoutSiteKeys.kid_of(new_key)
	_check(old_kid.length() == GSLoadoutSiteKeys.KID_CHARS and old_kid != new_kid, "a kid is 16 base64url characters of the key's SHA-256")
	var site := KeySite.new()
	site.keys_body = _key_list([old_key])
	site.me_body = {"ok": true, "target": {"kind": "server", "id": 7.0}}
	var cfg := GSLoadoutConfig.new()
	_check(cfg.site_key().ok and cfg.site_key().value == "" and not cfg.site_pinned(), "a fresh config needs no key: it follows the site's list")
	var made := GSLoadoutSiteSource.from_config(cfg, site)
	var src: GSLoadoutSiteSource = made.value
	_check(made.ok and src.key_mode() == "follow" and src.keys != null, "from_config with no pin follows the key list", str(made))
	_follow(src)
	site.body = _keyed_body("p1", old_key, ["skin.gold"])
	var res: GSResult = await src.refresh("p1")
	_check(res.ok and src.ids_of("p1") == ["skin.gold"], "the first token verifies against the fetched list", str(res))
	_check(site.reads("store/keys") == 1 and src.audience == AUD, "the list is read once and the audience comes from GET me", "%d %s" % [site.reads("store/keys"), src.audience])
	site.keys_body = _key_list([new_key, old_key])
	site.body = _keyed_body("p1", new_key, ["skin.new"])
	_clock[0] += 60.0
	res = await src.refresh("p1")
	_check(res.ok and src.ids_of("p1") == ["skin.new"] and site.reads("store/keys") == 2, "after a rotation the new kid is unknown, so the list is read again and it verifies", str(res))
	_check(src.keys.kids() == PackedStringArray([new_kid, old_kid]), "the list keeps the site's order, current first")
	site.body = _keyed_body("p1", old_key, ["skin.gold"])
	res = await src.refresh("p1")
	_check(res.ok and site.reads("store/keys") == 2, "a token from the retired but listed key still verifies, with no read", str(res))
	site.body = _keyed_body("p1", new_key, ["skin.gold"])
	site.body["publicKey"] = GSHash.base64url_encode(GSHash.random_bytes(32))
	_check((await src.refresh("p1")).ok, "following ignores the publicKey the answer carries")
	_done()
	await _test_site_keys_unknown(src, site, new_key)
	await _test_site_keys_tamper(src, site, new_key, old_key)
	await _test_site_keys_grace(src, site, new_key)
	await _test_site_keys_pinned(site, old_key, new_key)


## A kid nobody publishes: refused, and the list is read again only once per refetch_min_sec.
func _test_site_keys_unknown(src: GSLoadoutSiteSource, site: KeySite, new_key: String) -> void:
	_section("site key list: unknown kid")
	var rogue := GSHash.base64url_encode(GSHash.random_bytes(32))
	_clock[0] += src.keys.refetch_min_sec + 1.0
	var reads := site.reads("store/keys")
	site.body = _keyed_body("p1", rogue, ["skin.gold"])
	var res: GSResult = await src.refresh("p1")
	_check(not res.ok and res.code() == GSError.CODE_INTEGRITY and src.ids_of("p1").is_empty(), "a token from an unlisted key is refused and grants nothing", str(res))
	_check(site.reads("store/keys") == reads + 1, "an unknown kid reads the list again", str(site.reads("store/keys")))
	res = await src.refresh("p1")
	_check(not res.ok and site.reads("store/keys") == reads + 1, "a second unknown kid inside refetch_min_sec does not read again")
	_check(res.error.message.contains("site_keys_refetch_min_sec"), "the refusal says when the list may be read again", res.error.message)
	_clock[0] += src.keys.refetch_min_sec + 1.0
	await src.refresh("p1")
	_check(site.reads("store/keys") == reads + 2, "past refetch_min_sec an unknown kid reads again")
	src.keys.refetch_min_sec = 0.0
	await src.refresh("p1")
	await src.refresh("p1")
	_check(site.reads("store/keys") == reads + 4, "refetch_min_sec 0 is no limit")
	src.keys.refetch_min_sec = 30.0
	site.body = _keyed_body("p1", new_key, ["skin.new"])
	_check((await src.refresh("p1")).ok, "the listed key still verifies afterwards")
	_done()


## An altered list (a kid that is not its key's hash, a wrong alg, no keys) is refused whole; the last good stays.
func _test_site_keys_tamper(src: GSLoadoutSiteSource, site: KeySite, new_key: String, old_key: String) -> void:
	_section("site key list: tampered answer")
	var attacker := GSHash.base64url_encode(GSHash.random_bytes(32))
	var bad := _key_list([new_key])
	(bad["keys"] as Array).append({"kid": GSLoadoutSiteKeys.kid_of(new_key), "alg": "Ed25519", "publicKey": attacker, "current": false})
	var parsed := GSLoadoutSiteKeys.parse(bad)
	_check(not parsed.ok and parsed.code() == GSError.CODE_INTEGRITY, "a kid that is not its key's hash refuses the whole list", str(parsed))
	var wrong_alg := _key_list([new_key])
	wrong_alg["keys"][0]["alg"] = "HS256"
	_check(not GSLoadoutSiteKeys.parse(wrong_alg).ok, "a key with another alg refuses the list")
	_check(not GSLoadoutSiteKeys.parse({"keys": []}).ok and not GSLoadoutSiteKeys.parse({"keys": [{"kid": "x", "alg": "Ed25519", "publicKey": "AAAA"}]}).ok,
		"an empty list or a short key is refused")
	site.keys_body = bad
	_clock[0] += src.keys.ttl_sec + 1.0
	var signed_by_attacker := _keyed_body("p1", attacker, ["skin.all"])
	signed_by_attacker["token"] = _token("p1", attacker, ["skin.all"], GSLoadoutSiteKeys.kid_of(new_key))
	site.body = signed_by_attacker
	var res: GSResult = await src.refresh("p1")
	_check(not res.ok and src.ids_of("p1").is_empty(), "a token signed by the slipped-in key under a real kid is refused", str(res))
	_check(src.keys.kids() == PackedStringArray([GSLoadoutSiteKeys.kid_of(new_key), GSLoadoutSiteKeys.kid_of(old_key)]), "the last good list is kept")
	site.body = _keyed_body("p1", new_key, ["skin.new"])
	_check((await src.refresh("p1")).ok, "the real key still verifies")
	site.keys_body = _key_list([new_key, old_key])
	_done()


## The site cannot be read: the last good list is used for site_keys_grace_sec past its ttl, then refused.
func _test_site_keys_grace(src: GSLoadoutSiteSource, site: KeySite, new_key: String) -> void:
	_section("site key list: unreachable site")
	_clock[0] += src.keys.ttl_sec + 1.0
	site.body = _keyed_body("p1", new_key, ["skin.new"])
	_check((await src.refresh("p1")).ok, "a fresh read before the outage")
	site.keys_result = GSResult.fail(GSError.CODE_NETWORK, "connection refused")
	_clock[0] += src.keys.ttl_sec + 60.0
	var reads := site.reads("store/keys")
	var res: GSResult = await src.refresh("p1")
	_check(res.ok and site.reads("store/keys") == reads + 1, "a stale list that cannot be re-read is still used inside the grace", str(res))
	_clock[0] += src.keys.grace_sec
	res = await src.refresh("p1")
	_check(not res.ok and res.code() == GSError.CODE_NETWORK and src.ids_of("p1").is_empty(), "past the grace every token is refused", str(res))
	_check(res.error.message.contains("site_keys_grace_sec") and res.error.message.contains("connection refused"), "the refusal names the setting and the cause", res.error.message)
	src.keys.grace_sec = 0.0
	_check((await src.refresh("p1")).ok, "site_keys_grace_sec 0 keeps the last good list for ever")
	site.keys_result = null
	var fresh := GSLoadoutSiteSource.from_config(GSLoadoutConfig.new(), site).value as GSLoadoutSiteSource
	_follow(fresh)
	site.keys_result = GSResult.fail(GSError.CODE_NETWORK, "connection refused")
	res = await fresh.refresh("p1")
	_check(not res.ok and res.error.message.contains("never been read"), "a server that never read the list grants nothing and says why", str(res))
	site.keys_result = null
	_clock[0] += fresh.keys.refetch_min_sec + 1.0
	_check((await fresh.refresh("p1")).ok, "once the site answers, the same server verifies")
	_check(await _concurrent_first_read(), "players asking at once on a fresh server share one read and all verify")
	var lab := GSLoadoutSiteKeys.with_client(site)
	site.config = AuthCfg.new()
	site.config.backbone_url = "http://example.test"
	_check(not (await lab.fetch()).ok and lab.insecure_origin() != "", "a plain-HTTP origin is not followed")
	site.config.backbone_url = "http://127.0.0.1:3000"
	_check((await lab.fetch()).ok, "loopback over HTTP is followed")
	site.config.backbone_url = "http://example.test"
	lab.allow_http = true
	_check((await lab.fetch()).ok, "site_keys_allow_http follows plain HTTP")
	site.config = null
	src.keys.ttl_sec = 0.0
	reads = site.reads("store/keys")
	_clock[0] += 10_000_000.0
	_check((await src.refresh("p1")).ok and site.reads("store/keys") == reads, "site_keys_ttl_sec 0 keeps the list until an unknown kid")
	_check(await _concurrent_audience(new_key), "bots verifying at once on a fresh server share one GET me and all verify")
	_done()


## The hardened mode: a configured key is the only key, and a rotation is refused with what to do.
func _test_site_keys_pinned(site: KeySite, old_key: String, new_key: String) -> void:
	_section("site key list: strict pin")
	var cfg := GSLoadoutConfig.new()
	cfg.site_public_key = old_key
	cfg.site_audience = AUD
	var src: GSLoadoutSiteSource = GSLoadoutSiteSource.from_config(cfg, site).value
	_check(src.key_mode() == "pinned" and src.keys == null and cfg.site_pinned(), "an explicit site_public_key pins")
	src.verifier = _key_verifier()
	var reads := site.reads("store/keys")
	site.body = _keyed_body("p1", old_key, ["skin.gold"])
	_check((await src.refresh("p1")).ok, "the pinned key verifies")
	site.body = _keyed_body("p1", new_key, ["skin.new"])
	var res: GSResult = await src.refresh("p1")
	_check(not res.ok and res.code() == GSError.CODE_INTEGRITY and src.ids_of("p1").is_empty(), "a token from the rotated key is refused", str(res))
	_check(res.error.message.contains("Re-pin site_public_key") and res.error.message.contains("follow"), "the refusal says to re-pin or follow", res.error.message)
	_check(site.reads("store/keys") == reads, "a pinned server never reads the key list")
	cfg.site_audience = ""
	src = GSLoadoutSiteSource.from_config(cfg, site).value
	src.verifier = _key_verifier()
	site.body = _keyed_body("p1", old_key, ["skin.gold"])
	res = await src.refresh("p1")
	_check(not res.ok and src.audience == "", "a pinned server does not take its audience from the site", str(res))
	_done()


## Three callers hit a fresh server while the first key read is still in flight: none may be told the list was never read.
func _concurrent_first_read() -> bool:
	var key := GSHash.base64url_encode(GSHash.random_bytes(32))
	var site := KeySite.new()
	site.keys_body = _key_list([key])
	site.delay_frames = 3
	var keys := GSLoadoutSiteKeys.with_client(site)
	keys.now_fn = func() -> float: return _clock[0]
	var results: Array = []
	var run := func() -> void:
		results.append(await keys.keys_for(""))
	run.call()
	run.call()
	run.call()
	while results.size() < 3:
		await Engine.get_main_loop().process_frame
	var all_ok := true
	for r: GSResult in results:
		all_ok = all_ok and r.ok
	return all_ok and site.reads("store/keys") == 1


## Three bots ingest while the first GET me is in flight: none may fail with "No site audience".
func _concurrent_audience(key: String) -> bool:
	var site := KeySite.new()
	site.keys_body = _key_list([key])
	site.me_body = {"ok": true, "target": {"kind": "server", "id": 7.0}}
	site.delay_frames = 3
	var src: GSLoadoutSiteSource = GSLoadoutSiteSource.from_config(GSLoadoutConfig.new(), site).value
	_follow(src)
	var results: Array = []
	var run := func(p: String) -> void:
		results.append(await src.ingest(p, _keyed_body(p, key, ["skin.gold"])))
	run.call("p1")
	run.call("p2")
	run.call("p3")
	while results.size() < 3:
		await Engine.get_main_loop().process_frame
	var all_ok := true
	for r: GSResult in results:
		all_ok = all_ok and r.ok
	return all_ok and site.reads(GSLoadoutSiteSource.ME_PATH) == 1


func _follow(src: GSLoadoutSiteSource) -> void:
	src.verifier = _key_verifier()
	src.keys.now_fn = func() -> float: return _clock[0]


## Accepts a signature that is "sig:" + the key it was checked against.
func _key_verifier() -> Callable:
	return func(_bytes: PackedByteArray, sig: PackedByteArray, key: String) -> GSResult:
		if sig == ("sig:" + key).to_ascii_buffer():
			return GSResult.success(null)
		return GSResult.fail(GSError.CODE_INTEGRITY, "bad signature")


func _key_list(keys: Array) -> Dictionary:
	var out: Array = []
	for k: String in keys:
		out.append({"kid": GSLoadoutSiteKeys.kid_of(k), "alg": "Ed25519", "publicKey": k, "current": out.is_empty()})
	return {"keys": out}


func _token(player: String, key: String, items: Array, kid: String = "") -> String:
	var now := int(Time.get_unix_time_from_system())
	var signed: Array = []
	for it: String in items:
		signed.append(["app", it, null, []])
	var payload := {"v": 2, "kid": kid if kid != "" else GSLoadoutSiteKeys.kid_of(key), "aud": AUD, "sub": player,
		"iat": now, "exp": now + 300, "items": signed}
	return GSHash.base64url_encode_text(JSON.stringify(payload)) + "." + GSHash.base64url_encode(("sig:" + key).to_ascii_buffer())


func _keyed_body(player: String, key: String, items: Array) -> Dictionary:
	return {"ok": true, "player": player, "items": [], "token": _token(player, key, items), "alg": "Ed25519",
		"publicKey": key, "kid": GSLoadoutSiteKeys.kid_of(key)}


class AuthCfg:
	extends RefCounted
	var backbone_url: String = ""


## A site answering each path: the entitlements body, the key list (or a failure) and `me`.
class KeySite:
	extends RefCounted
	var config: AuthCfg = null
	var body: Dictionary = {}
	var keys_body: Dictionary = {}
	var keys_result: GSResult = null
	var me_body: Dictionary = {}
	var _reads: Dictionary = {}
	var delay_frames: int = 0

	func reads(path: String) -> int:
		return int(_reads.get(path, 0))

	func get_integration(path: String, _query: Dictionary = {}) -> GSResult:
		_reads[path] = reads(path) + 1
		for _i in delay_frames:
			await Engine.get_main_loop().process_frame
		if path == GSLoadoutSiteKeys.PATH:
			return keys_result if keys_result != null else GSResult.success(keys_body)
		if path == GSLoadoutSiteSource.ME_PATH:
			return GSResult.success(me_body)
		return GSResult.success(body)
