# GameSpice Loadout design

Why the addon is shaped the way it is, and why the obvious alternative is wrong at each point. The rules this produces are one line each in [CLAUDE.md](../CLAUDE.md).

## A loadout is a document of ids

**Validating a loadout must not require any content.** A dedicated server has no meshes, often no scenes, and possibly no downloaded content at all. It still has to decide whether the thing a client just sent is legal. So a `GSLoadout` is a mapping from slot ids to item ids, a `GSItem` is a description rather than an asset, and `GSItemCatalogue.resolver` (the only thing that turns an id into a real asset) is optional and only a client sets it.

`GSItemCatalogue.resolve()` without a resolver returns `CODE_STATE` saying so, rather than null. "Not downloaded yet" and "no such item" are different problems and only one of them is a bug.

## `validate` on the way in, `conform` on the way out

This is the distinction that matters, and it is easy to collapse.

**`conform` on the way out of a store.** Retiring an item, adding a required slot or tightening a budget makes every saved loadout containing the old thing invalid. Refusing those is a player who has not logged in for a month loading into an error rather than into a slightly different gun. `GSLoadoutValidator.conform` never fails, which is why `GSLoadoutSchema.validate` refuses a schema whose own defaults are not legal: a conform that could fail would leave a player unable to spawn.

**`validate` on the way in from a client.** `GSLoadoutManager.publish` validates and refuses. It does not conform. A client that can make the server repair its way to a legal loadout can put anything in any slot and have the server pick the nearest legal thing for it, which is a different feature from the one being offered.

## The trust boundary is `GSLoadoutManager.publish`

Everything else in the manager is convenience. That one method is where a document a client controls becomes one the game acts on, and every check it makes is there for a specific thing a hostile or buggy client does:

| Check | Without it |
| --- | --- |
| Rate limit | A loadout screen publishing on every click is a store write per frame |
| Per-player cap (`max_per_player`) | A client that can add loadouts without bound can fill a disk |
| Schema membership | A slot the schema does not have is not a slot |
| Entitlements | That is what an unlock is |
| Key usability (`GSLoadoutKey.is_usable`) | A malformed key reaching a filesystem path |

A refused publish still spends a rate-limit token. Spamming invalid loadouts is the abuse; exempting failures from the limit would exempt exactly the traffic worth limiting.

**The cache is not updated on a failed write.** A cache that disagrees with the store is worse than a refused publish: the player sees their change, plays with it, and loses it at the next load with no explanation.

## The synthesised default is an edit target, not a saved loadout

A player with nothing stored is handed `schema.default_loadout()` so they can spawn. Their first `publish` with no index replaces it rather than appending, and the manager tracks that in `_synthesised`. Appending leaves a player who has saved exactly once holding two loadouts, and on a schema with a cap of one the only publish they would ever make is refused. The self-test checks this.

## Entitlements default to nothing

`GSLoadoutEntitlements.none()` is the default and `entitlement_source` starts unset, so an unwired server permits only items marked `GSItem.free`.

The other default is worse in a way that is hard to notice. A server that granted everything by default would work in every test, ship, and quietly be a game where every unlock is free, and nobody files that bug. A server that grants nothing is wrong within thirty seconds of the first player pressing play.

`GSItem.entitlement_id` is the indirection that makes a bundle possible: several items naming one unlock are granted together.

## Site tokens

`GSLoadoutSiteSource` reads `GET store/entitlements?player=<scoped key>&include=points,loadout` (STORE_READ) through any object with `get_integration` (gs-auth's `GSBackboneClient`, registry `gs_backbone_client`). TMC's answer carries an unsigned body (`items`, `points`, `loadout`) and a `token`: `<payload b64url>.<signature b64url>`, signed over the payload text, whose payload is `{v: 2, kid, aud, sub, iat, exp, items: [[store, key, expiresAt, unlock[]]], points?, loadout?: [[slot, store, key]]}` (v1 items lack `unlock`) (website-city docs/store-security.md). Only the token is trusted:

- The signature must verify against a key the site publishes (the default, see below) or, in strict mode, against the pinned key. The key is never taken from the answer it would verify: its `publicKey` is ignored while following and must match the pin in strict mode.
- `aud` must equal `site_audience` (this server's scope name; while following and left empty it is learnt from `GET me`, `target {kind, id}` as `kind:id`), `sub` the player asked about, `v` 1 or 2, and `exp` must be in the future. Nothing is used past `exp`.
- Ids, the points balance and the loadout come from the token. A v2 token signs each item's unlock ids, which are granted with it. The body only adds the points `label` and, only while `site_unsigned_grants` is on (default off), `grant.unlock` ids of items a v1 token verified, which signs no grant.
- Anything else (no key, no token, bad signature, wrong app or player, expired) clears the player's cached answer, logs an error on `loadout.site`, emits `rejected` and grants nothing. A rejected player is read again after `site_ttl_sec`.

The check itself is gs-cloud's, loaded by path (`res://addons/gs_cloud/verify/gs_cloud_signature.gd`) so this addon still requires only gs-core. An RSA PEM key goes to its RSA-SHA256 `verify`; TMC's raw Ed25519 key needs `verify_ed25519(bytes, signature, key_bytes) -> GSResult`, which gs-cloud provides (`GSCloudEd25519`, pure script; Godot's Crypto has no EdDSA). With a gs-cloud that predates it, or none installed, every TMC token is refused, loudly: that is the point, since the alternative is trusting an answer nobody checked. A token check costs about a second of script time, once per refresh.

### Following the site key list

With no key configured (the default), `GSLoadoutSiteKeys` follows `GET store/keys` (no credential needed): `{keys: [{kid, alg: "Ed25519", publicKey, current}]}`, current key first, retired keys still listed until the site drops them. A fresh server needs no key setting, and a rotation at the site needs nothing done on any server.

- The list is read through the same client as the entitlements, so from the same site origin with the same TLS validation. A plain-HTTP origin other than loopback is refused unless `site_keys_allow_http` is set (a lab only).
- Every entry is checked: alg `Ed25519`, a raw 32-byte key, and a `kid` equal to the first 16 base64url characters of the key's SHA-256. One bad entry refuses the whole answer, so an altered list cannot slip a key in; the last good list stays.
- A token names its `kid`; only that key is tried (a v1 token without `kid` tries every listed key). Any listed key verifies, current or retired.
- `site_keys_ttl_sec` (300; 0 keeps the list until an unknown `kid`) is how long a good list is used before it is read again. A token with an unknown `kid` reads the list again at once, at most once per `site_keys_refetch_min_sec` (30; 0 is no limit); if the kid is still unknown the token is refused.
- When the site cannot be read the last good list is kept, with an error logged on each failed read, for `site_keys_grace_sec` (86400; 0 is unlimited) past its ttl; after that every token is refused with the reason and the setting to change. A server that never read the list grants nothing.

Strict mode is the hardened option: set `site_public_key` (or `site_public_key_path`) and `site_audience`, and only that key is accepted; the key list is never read. A token from any other key is refused with an error saying the site rotated and to re-pin, or to clear both settings to follow. A strict server must be re-pinned by hand on every rotation, after the site publishes the new key and before the old one leaves its retired list.

A game wires it one of two ways. `GSLoadoutSiteSource.layered(base, config)` keeps the old one-liner and reads `site_*` from the given `GSLoadoutConfig`, or from a layered one (`GS_LOADOUT_SITE_KEYS_GRACE_SEC`, `--loadout-site-audience=...`) when none is given. `GSLoadoutSiteSource.from_config(config, client)` returns the source itself, for a game that also wants `points_of(player)` (`{enabled, balance, label}`, balance null while points are off), `loadout_of(player)` (`[{slot, store, key}]`) and the `refreshed`/`rejected` signals. `key_mode()` says `follow` or `pinned`, and `keys.describe()` the kids, list age, reads and last error, for a status command. On start the source logs `site token keys` with its mode.

Purchases count at once. `purchase(player, item_id, idem_key)` posts `store/purchase` (STORE_WRITE: `{player, itemId, idemKey, include}`) and TMC answers like the entitlements read plus `status` and `purchase`; its token goes through `ingest()`, the same checks as a read, so the item is granted without waiting for `site_ttl_sec`. A failure (no points, not for sale) is returned and nothing changes. A purchase made elsewhere is seen at the next read: `mark_stale(player)` makes the next lookup read while the old answer still counts, and `await ensure(player)` on join waits for the first read, because `source()` is the manager's synchronous lookup and only starts one.

`GSLoadoutSiteSettings` reads `GET settings` (any credential): `{appId, sections: {<name>: {version, values}}}` with TMC's public fields under each section (`store`, `avatars`, `stats`). `refresh()` reads once, `follow(tree)` reads every `site_settings_poll_sec` (0 reads once), and `section_changed(section, values, version)` fires for each section whose `version` moved. Values keep TMC's field names (`maxLoadoutSlots`, `appPointsEnabled`, `fallback`, `columns` ...). Set it as a source's `settings` and a store section with `enabled: false` grants nothing. gs-auth's client cannot send `If-None-Match`, so polling compares versions instead of using the ETag's bodyless 304.

## Retired is not deleted

`GSItem.retired` keeps an item valid in a saved loadout while removing it from `choices_for`. Deleting the item instead makes every loadout containing it invalid at once, and `conform` then silently changes what a large number of players are carrying on the same day.

## Pickups are deterministic

`GSPickup` counts respawn in ticks and stores a target tick (`respawn_tick`) rather than a countdown. Ticked twice on the same tick it respawns once; a countdown decremented per call brings things back early on a replayed tick.

Reach is a distance test, not an `Area3D` overlap, and it is a horizontal distance under a height gate rather than a sphere. A sphere makes a pickup at foot level unreachable by a player whose position is their feet on one machine and their centre on another; the height gate is what stops a pickup on the floor being taken from the walkway above it.

`GSPickupField` ticks all of them, from one caller, with one tick number, in one order. Sixty pickups each running their own `_physics_process` is sixty independent timelines a replay cannot reproduce.

## `GSLoadoutKey` is a copy, deliberately

It duplicates GameSpice User Avatar's `GSAvatarKey.is_usable`. Do not deduplicate it. Only GameSpice Core is a hard dependency in this family, and a game that wants loadouts without avatars must not have to install one to get the other: the same reason GameSpice User Avatar carries its own rather than reusing GameSpice User's.

## Coupling: nothing is imported

GameSpice Loadout names no class outside GameSpice Core in code. Not GameSpice Combat, not GameSpice Net, not GameSpice Weapon, not GameSpice Server.

- `GSLoadout.write` / `read` take `Variant` (a `GSNetWriter` / `GSNetReader` in practice), so this project parses without GameSpice Net installed. Inside `read`, the locals are typed rather than inferred: `var x := reader.read_string(...)` is a parse error under these projects' warning settings because a `Variant` return cannot be inferred.
- Ids go on the wire as strings, not indices into the schema. Indices are smaller and they are a version coupling: a schema that gains a slot renumbers every one after it, and two peers on different builds then decode each other's loadouts into the wrong slots without anything failing. A loadout is sent once per player per life, so the size does not matter.
- `GSLoadoutSlot.arsenal_slot` is a plain integer a game matches against a weapon's own slot (`GSWeaponDef.slot`). GameSpice Loadout never names GameSpice Weapon.
- `GSLoadoutManager.resolve` returns `{slot, arsenal_slot, item, count}` dictionaries rather than doing anything with them. GameSpice Weapon's `GSWeaponLoadoutBridge` consumes exactly that shape, duck-typed, so neither addon depends on the other.

## No backbone store yet, and why

`GSLoadoutStore` has the seam, but there is no `GSLoadoutStoreBackbone` and website-city has no loadout route. Decided 2026-10-11 (nightly `user-profile-routes-1`): a route now would be speculative, because nothing could call it and nothing would use it if something could.

- **There is no client.** This addon ships no HTTP store, so a site route would have no caller; GameSpice User and GameSpice User Avatar each ship their backbone store first and the site serves what that store sends.
- **No game keeps loadouts past a session.** game-fatal-contact, game-airdrift, game-hungario and game-playlot all build `GSLoadoutStoreMemory` on purpose (hungario's module says why: a loadout that outlives a session is a profile).
- **Games key loadouts by session, not by player.** Playlot publishes under `"u%d" % session_id` and hungario under `"hungry-%08d" % player_id`. A backbone store resolves only the site's scoped key (GameSpice Auth's `scoped_key` claim), so under today's keys every fetch would be a 404 and every save would fail.

Build it when a game wants loadouts to follow a player between servers: that game first keys loadouts by the scoped key, then this addon gains `GSLoadoutStoreBackbone` (shaped like gs-user's, including its parented `GSHttp`, see gs-user's docs/design.md "The backbone protocol") and website-city gains `user/{key}/loadouts` beside `user/{key}/profile`, stored per `UserScopeKey` like `UserScopeProfile`.

## A server owner's rules

Christian's first play test (2026-10-11): players choose their loadout on B by default, and a server owner can restrict it ("snipers only") or lock it. `GSLoadoutRules` is that owner's say, read from three cvars every game registers through `GSLoadoutCommand`: `mp_loadout_menu` (players choose, 1), `mp_loadout_allow` (`slot=item,tag:x,-item ...`, `*` every slot) and `mp_loadout_fixed` (`slot=item`, `none` for empty).

The menu's Random entry (`GSLoadoutRandom`, `/loadout random`) rolls a fresh set every use, from a persistent `GSRandomStream` so a seed makes a whole sequence repeatable. Its cvars: `mp_loadout_random` (0 off: the entry is hidden and the server refuses the command), `_count` (slots per roll, 0 all), `_slots` (`primary,secondary`), `_price` (`free`, `sum`, `flat:N`), `_dupes`, `_seed` and `_class` (`medic.count=2 sniper.slots=primary`). A roll starts from the current loadout, skips fixed slots, and respects the point and weight budgets, the player's money (`money_fn`/`charge_fn`) and the class's allowed items (`class_fn`/`class_rules_fn`), then goes through `publish` like any choice.

**Random at every spawn.** `mp_loadout_random_on_spawn` (0 off, 1 the player's toggle, 2 forced; a class can override with `class.spawn=N` in `mp_loadout_random_class`) makes the game ask `GSLoadoutCommand.roll_for_spawn(key)` at each spawn and respawn. The roll is never saved, so switching the toggle off brings the player's own loadout back; the toggle (`random_spawn`) is saved per player (`/loadout randomspawn on|off`). Bots have no key and are excluded.

**Free by default.** `GSItem.cost` comes from the game's catalogue (the weapon profile's `params.loadout_cost`) and counts only against a budget: `GSLoadoutSchema.point_budget`, overridden by `mp_loadout_budget` (0 = unlimited). With neither set nothing is priced and the menu shows no cost.

- **Separate from the schema and from entitlements.** The schema is the game's design and entitlements are one player's unlocks; both ship with the game. Rules are one server's tonight, changed while players are connected. Folding them into the schema means rebuilding it and re-conforming every saved loadout on a cvar change; folding them into entitlements loses the slot (a pistol allowed as a sidearm is not allowed everywhere).
- **Applied on the way out, never stored.** `active_for` hands back a conformed copy, so an owner who lifts "snipers only" gives every player back the rifle they saved, not the repair made while the rule was on. `validate`, `conform` and `choices_for` take the rules as an optional last argument; `publish` refuses what they do not permit with `CODE_FORBIDDEN`, as it refuses an item not unlocked.
- **A fixed slot is the owner's.** Not entitlement-checked (handing everybody a weapon nobody unlocked is the point), never trimmed by a budget, and in a publish overwritten rather than judged, so a screen opened before the owner fixed a slot still saves the slots it may choose.
- **A bad value changes nothing.** `GSLoadoutRules.check` refuses an unknown slot, a fixed item the slot cannot hold, a required slot fixed empty, and rules that leave a required slot no choice; `GSLoadoutCommand` puts that check on the allow and fixed cvars as their validator, so the console refuses the value and it never sits in the cvar (one left there would fail every later change to the other two), and if a value still arrives it keeps the old rules and logs a WARN naming it. A typo must not unlock everything, or leave everybody spawning with an empty primary.

## The menu's server half

`GSLoadoutCommand` is the wire, the same shape as GameSpice Vote's map menu: the client sends `/loadout` through its chat link (a prefixed line is a command and is never shown), the server answers with a `loadout_menu` notice carrying `GSLoadoutManager.offer_for` (`{choose, budget, points, note, slots: [{id, name, required, fixed, current, choices: [{id, name, cost, tags}]}]}`), and a choice is `/loadout slot=item ...`, published through the trust boundary. A hostile client typing the line gets exactly what the screen would have let it pick. The offer is ids, names and numbers only: art and statistics are the client's, from its own content, because a dedicated server may have none. `closed_fn` lets the game close the menu for a reason of its own (a mode that hands out the weapons): the offer then lets nothing be picked and says why, and a choice is refused with the same words. `applied_fn` lets the game hand the new loadout over at once (warmup, spawn protection) and say so; otherwise it is the next spawn. Nothing here names GameSpice Server: the host is anything with `add_command`/`add_cvar`, the notice script is loaded by path.

`offer_for(key, true)` also lists items the player does not own, each choice gaining `locked` and `store` (the manager's `store_url`); `request_store(item)` emits `store_requested(item, url)` for a menu's "Get in store" button. Default offers are unchanged and publish still refuses locked items.

## Saved loadouts and the website (design only, not built)

A player keeps named loadouts (`mp_loadout_max_saved`, 0 unlimited) under the key the game gives; `/loadout save|use|rename|delete` manage them and `selected` survives restarts. Guests are stored by `GSLoadoutStoreLocal` in `user://`. Editing them on the website needs the backbone to add `GET/PUT user/{key}/loadouts` beside `user/{key}/profile` (profile preferences hold 32 keys of 256 characters, too small), keyed by the scoped user key, a size limit for 256 loadouts, and a store that reads and writes it (a callable-backed `GSLoadoutStore`, since this addon names nothing outside GameSpice Core). The server still validates every loadout on use.

## Deliberately not here

- **A loadout screen.** It is GameSpice Menu's (`GSMenuLoadout`, on B), which reads the offer above and names nothing of this addon's; `GSLoadoutSchema.choices_for` deliberately returns what a player can actually take rather than everything a slot accepts, because a screen that shows the second and refuses on submit is a screen that lies.
- **Item to weapon mapping.** `arsenal_slot` is the hint; `GSWeaponLoadoutBridge` in GameSpice Weapon is the table, because importing GameSpice Weapon here would make loadouts unavailable to a game that does not use it.
- **Buying, currency, a shop.** Entitlements arrive from somewhere; `entitlement_source` is the whole seam.
- **Attachments and modifications.** A scope, a barrel and a stock on one weapon is a nested document with its own budget, a genuinely different shape from a flat slot map. Doing it badly now would be harder to undo than adding it later.
- **Per-team or per-class schemas.** One manager holds one schema. A game with two runs two managers, or swaps `schema` between rounds. Making the manager hold a set keyed by something would guess at what that something is.
- **Dropping and picking up a carried weapon.** `GSPickup` grants an item; nothing spawns one from a player's current arsenal on death. That needs an item's runtime state (its remaining ammunition), which is GameSpice Weapon's `GSWeaponSlot`.
