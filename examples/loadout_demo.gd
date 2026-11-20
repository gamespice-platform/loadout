extends "loadout_demo_site_keys.gd"

## Entry point of the offline suite; the checks live in loadout_demo_base.gd and the parts that extend it.


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-loadout self-test")
	print("")

	DotPaths.remove_tree(LOADOUT_DIR)

	_catalogue = _build_catalogue()
	_schema = _build_schema()

	_test_items()
	_test_catalogue()
	_test_slots()
	_test_schema()
	_test_document()
	_test_entitlements()
	_test_text_order()
	_test_validation()
	_test_conform()
	_test_budgets()
	_test_wire()
	await _test_store_contract(DotLoadoutStoreMemory.new(), "memory")
	await _test_store_contract(DotLoadoutStoreLocal.at(LOADOUT_DIR), "local")
	await _test_manager()
	await _test_manager_entitlements()
	_test_pickups()
	_test_rules()
	await _test_manager_rules()
	await _test_command()
	await _test_instant_swap()
	_test_random()
	await _test_random_command()
	await _test_saved()
	await _test_persistence()
	await _test_random_spawn()
	await _test_free_by_default()
	await _test_site_source()
	await _test_site_source_ed25519()
	await _test_site_v2_purchase()
	await _test_site_keys_follow()

	DotPaths.remove_tree(LOADOUT_DIR)

	print("")
	# The two guards, as the last two checks. See docs/testing.md.
	_check(
		_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d)" % [_completed, SECTIONS]
	)
	_check(
		_passed + _failed + 1 == CHECKS,
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS]
	)
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _test_site_source() -> void:
	_section("site store entitlements")
	var site := FakeSite.new()
	site.body = _site_body("p1", [["app", "skin.gold", null], ["app", "pack.heavy", null]], {"key": "skin.forged", "grant": {"unlock": "rifle_z"}})
	var src := _signed_source(site)
	_check(not src.unsigned_grants, "the unsigned grant.unlock is ignored by default")
	src.unsigned_grants = true
	src.source("p1")
	_check(site.calls == 1, "the first lookup of a player starts a read")
	_check(site.query.get("include") == "points,loadout", "the read asks for points and loadout", str(site.query))
	var res: DotResult = await src.refresh("p1")
	_check(res.ok and (res.value as Array).size() == 4, "a verified token yields its item keys and their grant.unlock ids", str(res.value))
	var ent: DotLoadoutEntitlements = src.source("p1")
	_check(ent.allows(_item_for("skin.gold")) and ent.allows(_item_for("rifle_x")), "an owned key and a granted unlock are allowed")
	_check(not ent.allows(_item_for("skin.forged")) and not ent.allows(_item_for("rifle_z")), "an item only in the unsigned body grants nothing")
	_check(not ent.allows(_item_for("other")), "an unowned id is refused")
	var points := src.points_of("p1")
	_check(points.get("balance") == 120 and points.get("label") == "Gems" and points.get("enabled") == true, "points come from the token, the label from the body", str(points))
	var lo := src.loadout_of("p1")
	_check(lo.size() == 1 and lo[0] == {"slot": "primary", "store": "app", "key": "skin.gold"}, "the loadout comes from the token as {slot, store, key}", str(lo))
	var calls := site.calls
	src.source("p1")
	_check(site.calls == calls, "a fresh cache entry starts no read")
	_check(DotLoadoutSiteSource.ids_from({"items": "x"}).is_empty(), "a malformed body grants nothing")
	_check((await DotLoadoutSiteSource.new().refresh("p")).ok == false, "no client is a failure, not a grant")
	src.unsigned_grants = false
	await src.refresh("p1")
	_check(not src.source("p1").allows(_item_for("rifle_x")), "unsigned_grants off ignores grant.unlock")
	site.body = _site_body("p1", [["app", "old.skin", "2001-01-01T00:00:00.000Z"], ["app", "new.skin", "2999-01-01T00:00:00.000Z"]])
	await src.refresh("p1")
	_check(src.ids_of("p1") == ["new.skin"], "a token item past its expiresAt grants nothing", str(src.ids_of("p1")))
	var settings := DotLoadoutSiteSettings.new()
	settings._sections["store"] = {"version": 1, "values": {"enabled": false}}
	src.settings = settings
	_check(src.ids_of("p1").is_empty(), "the app's store turned off grants nothing")
	var layered := DotLoadoutSiteSource.layered(func(_k: String) -> DotLoadoutEntitlements: return DotLoadoutEntitlements.of(["base_x"]))
	var base_only: DotLoadoutEntitlements = layered.call("p9")
	_check(base_only.allows(_item_for("base_x")) and not base_only.allows(_item_for("rifle_x")), "layered without a backbone keeps only the base answer")
	_done()
	var cfg := await _test_site_token_rejection(site)
	await _test_site_app_settings(cfg)


## A signed token is verified, and every way of failing that clears the player's grants.
func _test_site_token_rejection(site: FakeSite) -> DotLoadoutConfig:
	_section("site token rejection")
	var res: DotResult
	var why: Array = []
	site.body = _site_body("p2", [["app", "skin.gold", null]])
	var src := _signed_source(site)
	src.rejected.connect(func(_p: String, reason: String) -> void: why.append(reason))
	_check((await src.refresh("p2")).ok and src.ids_of("p2").size() == 1, "a good token is accepted first")
	site.body["token"] = str(site.body["token"]).get_slice(".", 0) + "." + DotHash.base64url_encode("forged".to_ascii_buffer())
	res = await src.refresh("p2")
	_check(not res.ok and src.ids_of("p2").is_empty() and src.points_of("p2").is_empty(), "a bad signature clears the player's grants", str(res))
	_check(why.size() == 1, "a rejection emits rejected")
	site.body = _site_body("p2", [["app", "skin.gold", null]], {}, -10)
	_check(not (await src.refresh("p2")).ok and src.ids_of("p2").is_empty(), "an expired token is refused")
	site.body = _site_body("p2", [["app", "skin.gold", null]], {}, 300, "other-app")
	res = await src.refresh("p2")
	_check(not res.ok and res.code() == DotError.CODE_FORBIDDEN, "a token for another app is refused", str(res))
	site.body = _site_body("p3", [["app", "skin.gold", null]])
	_check(not (await src.refresh("p2")).ok, "a token for another player is refused")
	site.body = _site_body("p2", [["app", "skin.gold", null]])
	site.body["publicKey"] = "ROTATED"
	res = await src.refresh("p2")
	_check(not res.ok and res.code() == DotError.CODE_INTEGRITY, "a publicKey other than the pinned one is refused", str(res))
	site.body = _site_body("p2", [["app", "skin.gold", null]])
	site.body.erase("token")
	_check(not (await src.refresh("p2")).ok and src.ids_of("p2").is_empty(), "an answer without a token grants nothing")
	var unpinned := DotLoadoutSiteSource.with_client(site)
	site.body = _site_body("p2", [["app", "skin.gold", null]])
	res = await unpinned.refresh("p2")
	_check(not res.ok and res.code() == DotError.CODE_NETWORK and unpinned.ids_of("p2").is_empty(), "no pin and no readable key list refuses every token", str(res))
	unpinned.public_key = "PINNED"
	unpinned.audience = "game-test"
	res = await unpinned.refresh("p2")
	_check(not res.ok and unpinned.ids_of("p2").is_empty(), "without dot-cloud's verifier the token is refused, not trusted", str(res))
	var raw := DotLoadoutSiteSource.cloud_verify(PackedByteArray(), PackedByteArray(), DotHash.base64url_encode(PackedByteArray([1, 2])))
	_check(not raw.ok, "cloud_verify fails loudly when it cannot verify", str(raw))
	_check(why.size() == 6, "every rejection was signalled", str(why.size()))
	var cfg := DotLoadoutConfig.new()
	_check(cfg.site_key().ok and cfg.site_key().value == "" and not cfg.site_pinned(), "a config with no pin follows the site's key list")
	cfg.site_public_key = "PINNED"
	cfg.site_audience = "game-test"
	_check(cfg.site_key().value == "PINNED", "site_public_key is the pinned key")
	var key_file := LOADOUT_DIR.path_join("site_key.txt")
	DirAccess.make_dir_recursive_absolute(LOADOUT_DIR)
	var f := FileAccess.open(key_file, FileAccess.WRITE)
	f.store_string("FROMFILE\n")
	f.close()
	cfg.site_public_key_path = key_file
	_check(not cfg.site_key().ok and not cfg.validate().ok, "a key by value and by path at once is refused")
	cfg.site_public_key = ""
	var made := DotLoadoutSiteSource.from_config(cfg, site)
	_check(made.ok and (made.value as DotLoadoutSiteSource).public_key == "FROMFILE", "site_public_key_path reads the key from a file", str(made))
	_done()
	return cfg


## The app's settings feed: sections announced once, then only when their version changes.
func _test_site_app_settings(cfg: DotLoadoutConfig) -> void:
	_section("site app settings")
	var res: DotResult
	var feed := FakeSite.new()
	feed.body = {"appId": "app1", "sections": {
		"store": {"version": 3, "values": {"enabled": true, "maxLoadoutSlots": 0}},
		"avatars": {"version": 1, "values": {"appOnly": false, "fallback": "FIRST_ENABLED"}},
		"stats": {"version": 2, "values": {"public": true, "columns": ["kills"]}},
	}}
	var st := DotLoadoutSiteSettings.with_client(feed, 0.0)
	var seen: Array = []
	st.section_changed.connect(func(name: String, _v: Dictionary, ver: int) -> void: seen.append("%s@%d" % [name, ver]))
	res = await st.refresh()
	_check(res.ok and seen.size() == 3 and feed.last_path == "settings", "the first read announces every section", str(seen))
	_check(st.value("avatars", "fallback") == "FIRST_ENABLED" and st.version("stats") == 2 and st.app_id == "app1", "values and versions read back with TMC's field names")
	seen.clear()
	await st.refresh()
	_check(seen.is_empty(), "an unchanged version announces nothing")
	feed.body["sections"]["avatars"] = {"version": 2, "values": {"appOnly": true}}
	await st.refresh()
	_check(seen == ["avatars@2"] and st.value("avatars", "appOnly") == true, "a changed version is announced with its values", str(seen))
	feed.body = {"oops": true}
	res = await st.refresh()
	_check(not res.ok and st.value("store", "enabled") == true, "a malformed answer fails and keeps the last good settings")
	await st.follow(null)
	_check(feed.calls == 5, "follow with no timer reads once", str(feed.calls))
	_check(st.section("missing").is_empty() and st.version("missing") == -1, "an absent section is empty")
	_check(DotLoadoutSiteSettings.from_config(cfg, feed).poll_sec == cfg.site_settings_poll_sec, "from_config takes site_settings_poll_sec")
	_done()


## A source pinned to "PINNED" for audience "game-test", with a verifier that accepts the "sig-ok" signature.
## One token signed by an independent Ed25519 implementation, checked through GameSpice Cloud's verifier
## with no stand-in verifier. It skips (and says so) where GameSpice Cloud, or a GameSpice Cloud with verify_ed25519, is not beside this addon.
const ED25519_SITE_KEY := "85Z3S4z-hQJcLBXdopf0QbpShS7IyO8RPSLuHZaOSwA"
const ED25519_SITE_TOKEN := "eyJ2IjogMSwgImF1ZCI6ICJnYW1lLXRlc3QiLCAic3ViIjogInAxIiwgImlhdCI6IDE3MDAwMDAwMDAsICJleHAiOiA0MTAyNDQ0ODAwLCAiaXRlbXMiOiBbWyJhcHAiLCAic2tpbi5nb2xkIiwgbnVsbF1dLCAicG9pbnRzIjogMTIwLCAibG9hZG91dCI6IFtbInByaW1hcnkiLCAiYXBwIiwgInNraW4uZ29sZCJdXX0.6gt575erZsThmaQFQuOzW7s4-0ngNT9RaVE-DK5AFtISCXjnGdiQ3FWsRMlKbtFGgqhxJqdjDjXrj3SYEFmYAw"


func _cloud_has_ed25519() -> bool:
	if not ResourceLoader.exists(DotLoadoutSiteSource.CLOUD_SIGNATURE):
		return false
	var script: Script = load(DotLoadoutSiteSource.CLOUD_SIGNATURE)
	for m: Dictionary in script.get_script_method_list():
		if m.get("name") == "verify_ed25519":
			return true
	return false


func _test_site_source_ed25519() -> void:
	_section("site token, real Ed25519")
	if not _cloud_has_ed25519():
		_check(true, "skipped: no dot-cloud with verify_ed25519 beside this addon")
		_check(true, "skipped: no Ed25519 verifier to refuse an edited payload")
		_check(true, "skipped: no Ed25519 verifier to refuse another key")
		_done()
		return
	var site := FakeSite.new()
	site.body = {"ok": true, "player": "p1", "items": [], "points": {"enabled": true, "balance": 120, "label": "Gems"},
		"token": ED25519_SITE_TOKEN, "ttl": 300, "alg": "Ed25519", "publicKey": ED25519_SITE_KEY}
	var src := DotLoadoutSiteSource.with_client(site)
	src.public_key = ED25519_SITE_KEY
	src.audience = "game-test"
	var res: DotResult = await src.refresh("p1")
	_check(res.ok and src.ids_of("p1") == ["skin.gold"], "a token signed with Ed25519 verifies through dot-cloud and grants its items", str(res))
	var parts := ED25519_SITE_TOKEN.split(".")
	site.body["token"] = DotHash.base64url_encode_text(DotHash.base64url_decode_text(parts[0]).replace("skin.gold", "skin.free")) + "." + parts[1]
	res = await src.refresh("p1")
	_check(not res.ok and src.ids_of("p1").is_empty(), "the same signature over an edited payload is refused and grants nothing", str(res))
	site.body["token"] = ED25519_SITE_TOKEN
	var other := DotLoadoutSiteSource.with_client(site)
	other.public_key = DotHash.base64url_encode(PackedByteArray([1]) + PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	other.audience = "game-test"
	site.body["publicKey"] = other.public_key
	res = await other.refresh("p1")
	_check(not res.ok and other.ids_of("p1").is_empty(), "a different pinned key refuses the token", str(res))
	_done()


func _signed_source(client: Object) -> DotLoadoutSiteSource:
	var src := DotLoadoutSiteSource.with_client(client)
	src.public_key = "PINNED"
	src.audience = "game-test"
	src.verifier = func(_bytes: PackedByteArray, sig: PackedByteArray, key: String) -> DotResult:
		if key == "PINNED" and sig == "sig-ok".to_ascii_buffer():
			return DotResult.success(null)
		return DotResult.fail(DotError.CODE_INTEGRITY, "bad signature")
	return src


## An entitlements answer shaped as TMC sends it, with a token for [param player].
## [param version] 2 signs each item's unlock ids into the token.
func _site_body(player: String, items: Array, extra_item: Dictionary = {}, ttl: int = 300, aud: String = "game-test", version: int = 1) -> Dictionary:
	var now := int(Time.get_unix_time_from_system())
	var signed: Array = []
	var body_items: Array = []
	for it: Array in items:
		var grant: Variant = {"unlock": ["rifle_x", "smg_y"]} if it[1] == "pack.heavy" else null
		body_items.append({"key": it[1], "kind": "WEAPON", "grant": grant, "expiresAt": it[2]})
		signed.append(it + [grant["unlock"] if grant != null else []] if version >= 2 else it)
	var payload := {"v": version, "aud": aud, "sub": player, "iat": now, "exp": now + ttl, "items": signed,
		"points": 120, "loadout": [["primary", "app", "skin.gold"]]}
	if not extra_item.is_empty():
		body_items.append(extra_item)
	var token := DotHash.base64url_encode_text(JSON.stringify(payload)) + "." + DotHash.base64url_encode("sig-ok".to_ascii_buffer())
	return {"ok": true, "player": player, "items": body_items, "points": {"enabled": true, "balance": 120, "label": "Gems"},
		"loadout": [{"slot": "primary", "store": "app", "key": "skin.gold"}], "token": token, "ttl": 300,
		"alg": "Ed25519", "publicKey": "PINNED"}


func _item_for(id: String) -> DotItem:
	return DotItem.make(StringName(id), DotItem.KIND_WEAPON, false)


class FakeSite:
	extends RefCounted
	var calls: int = 0
	var body: Dictionary = {}
	var query: Dictionary = {}
	var last_path: String = ""

	func get_integration(path: String, p_query: Dictionary = {}) -> DotResult:
		calls += 1
		last_path = path
		query = p_query
		return DotResult.success(body)

	var post_body: Dictionary = {}
	## Null answers [member body]; set a failure to stand for TMC refusing the purchase.
	var post_result: DotResult = null

	func post_integration(path: String, p_body: Dictionary) -> DotResult:
		last_path = path
		post_body = p_body
		return post_result if post_result != null else DotResult.success(body)


## v2 tokens sign the unlock ids; a purchase answer's token counts at once; a stale answer is read again.
func _test_site_v2_purchase() -> void:
	_section("site v2 tokens and purchases")
	var site := FakeSite.new()
	site.body = _site_body("p1", [["app", "pack.heavy", null]], {}, 300, "game-test", 2)
	var src := _signed_source(site)
	var res: DotResult = await src.refresh("p1")
	_check(res.ok and src.source("p1").allows(_item_for("rifle_x")) and src.ids_of("p1").size() == 3, "a v2 token's signed unlock ids are granted with unsigned grants off", str(res.value))
	site.body = _site_body("p1", [["app", "pack.heavy", null]], {}, 300, "game-test", 3)
	res = await src.refresh("p1")
	_check(not res.ok and res.code() == DotError.CODE_VERSION, "a token version newer than this addon reads is refused", str(res))
	_check(not (await DotLoadoutSiteSource.new().purchase("p1", "item-7")).ok, "a purchase without post_integration fails")
	site.body = _site_body("p1", [["app", "skin.gold", null], ["app", "skin.new", null]], {}, 300, "game-test", 2)
	site.body["status"] = "purchased"
	var calls := site.calls
	res = await src.purchase("p1", "item-7", "k1")
	_check(res.ok and (res.value as Dictionary).get("status") == "purchased" and src.ids_of("p1").has("skin.new"), "a purchase answer's token is applied at once", str(res))
	_check(site.calls == calls and site.last_path == DotLoadoutSiteSource.PURCHASE_PATH
		and site.post_body.get("player") == "p1" and site.post_body.get("itemId") == "item-7" and site.post_body.get("idemKey") == "k1",
		"the purchase posts the player, item and idempotency key, with no extra read", str(site.post_body))
	site.post_result = DotResult.fail(DotError.CODE_FORBIDDEN, "insufficient_points")
	res = await src.purchase("p1", "item-8", "k2")
	_check(not res.ok and src.ids_of("p1").has("skin.new"), "a refused purchase fails and keeps what the player owns", str(res))
	site.post_result = null
	await src.purchase("p1", "item-7")
	_check(str(site.post_body.get("idemKey", "")) != "", "an empty idempotency key is made")
	calls = site.calls
	await src.ensure("p1")
	_check(site.calls == calls, "ensure on a fresh answer starts no read")
	src.mark_stale("p1")
	_check(src.ids_of("p1").has("skin.new"), "a stale answer still counts until the next read")
	await src.ensure("p1")
	_check(site.calls == calls + 1, "ensure on a stale answer waits for a read")
	await src.ensure("p1", true)
	_check(site.calls == calls + 2, "ensure with force always reads")
	_done()
