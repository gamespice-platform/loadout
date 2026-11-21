# GameSpice Loadout

What a player takes into a match: a schema of slots, a catalogue of items, saved loadouts per player, entitlements, and deterministic world pickups. A loadout is a document of ids, so a dedicated server with no content can still decide whether one is legal.

Read the family [CLAUDE.md](../../CLAUDE.md) first.

**The distributable is `addons/gs_loadout/`.** It requires [GameSpice Core](../gs-core) and [GameSpice Save](../gs-save) (`ln -s ../../gs-save/addons/gs_save addons/gs_save`, gitignored; the file store lives there) (`ln -s ../../gs-core/addons/gs_core addons/gs_core`, gitignored); `GSLoadoutSiteSource` loads gs-cloud's signature verifier by path when it is installed, and without it refuses every site token. It names no class outside gs-core in code; gs-weapon's `GSWeaponLoadoutBridge` consumes `GSLoadoutManager.resolve`'s output by duck typing.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | changing the validator, the manager, the store, entitlements or pickups: ids not assets, validate vs conform, the trust boundary, the synthesised default, why nothing is imported, what is deliberately not here |

## Layout

| Path | What |
| --- | --- |
| `core/gs_loadout.gd` | `GSLoadout`: slot id to item id, dictionary and wire (`write`/`read`) forms |
| `core/gs_loadout_schema.gd`, `gs_loadout_slot.gd` | `GSLoadoutSchema` (slots, `default_loadout`, `choices_for`), `GSLoadoutSlot` (`arsenal_slot`) |
| `core/gs_item.gd`, `gs_item_catalogue.gd` | `GSItem` (`free`, `entitlement_id`, `retired`), `GSItemCatalogue` (optional client-side `resolver`) |
| `core/gs_loadout_validator.gd` | `GSLoadoutValidator.validate` (refuses) and `conform` (never fails) |
| `core/gs_loadout_entitlements.gd`, `gs_loadout_key.gd` | `GSLoadoutEntitlements` (`none()` default), `GSLoadoutKey.is_usable` |
| `core/gs_loadout_rules.gd` | `GSLoadoutRules`: a server owner's rules (players choose or not, allowed items per slot, fixed slots), from the `mp_loadout_*` cvars |
| `gs_loadout_manager.gd` | `GSLoadoutManager`: cache, `publish` (the trust boundary), `resolve`, `rules`, `offer_for` (what a loadout screen lists) |
| `integrations/gs_loadout_command.gd` | `GSLoadoutCommand`: the server half of the B menu: the `loadout` command, the `loadout_menu` notice, the three cvars |
| `gs_loadout_api.gd` | the API level (2) |
| `gs_loadout_config.gd` | `GSLoadoutConfig`: store backend, policy (`conform_on_load`, `enforce_entitlements`, `allow_default_loadout`), `publishes_per_minute`, `max_per_player`, cache size and TTL, the site store's keys (`site_*`: follow the key list by default, `site_keys_*` timings; `site_public_key` is the strict pin) |
| `store/` | `GSLoadoutStore` (interface), `GSLoadoutStoreLocal` (JSON file per key, versioned, capped), `GSLoadoutStoreMemory`, `GSLoadoutStoreTiered` (durable for stable keys, memory for the rest), `GSLoadoutStoreProfile` (stub for a member profile document) |
| `net/gs_loadout_site_keys.gd` | `GSLoadoutSiteKeys`: follows the site's published signing keys (`GET store/keys`): checks every entry's `kid`, ttl, re-read on an unknown `kid` (rate-limited), last good list kept for a grace while the site is unreachable. [design](docs/design.md#following-the-site-key-list) |
| `net/gs_loadout_site_source.gd` | `GSLoadoutSiteSource`: site store entitlements, app points and saved loadout (`GET store/entitlements?include=points,loadout`, STORE_READ) cached per player; trusts only the signed token (a key from the site's list or the strict pin, `aud`, `sub`, `exp`) and grants nothing otherwise; `source` is the manager's `entitlement_source`. [design](docs/design.md#site-tokens) |
| `net/gs_loadout_site_settings.gd` | `GSLoadoutSiteSettings`: the app's public settings (`GET settings`), `section_changed` per section whose `version` moved |
| `world/` | `GSPickup` (tick-counted respawn, distance reach), `GSPickupField` (ticks them all) |
| `examples/loadout_demo.tscn` | the suite, offline |

Paths except `examples/` are in `addons/gs_loadout/`.

## Running and testing

The family's two steps ([family CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/loadout_demo.tscn`; it exits non-zero on any failure. Run it after any change to the validator or the manager: several checks exist because the obvious implementation is wrong (the synthesised-default replacement, the store handing back copies rather than its own objects, the failed write that must not update the cache, and `from_dictionary` refusing a non-string item rather than coercing it).

## Rules that bite

- Validation never needs content; `GSItemCatalogue.resolve` without a resolver returns `CODE_STATE`, not null. [design](docs/design.md#a-loadout-is-a-document-of-ids)
- `conform` on the way out of a store, `validate` on the way in from a client; `publish` never conforms. [design](docs/design.md#validate-on-the-way-in-conform-on-the-way-out)
- `GSLoadoutSchema.validate` refuses a schema whose own defaults are illegal, because `conform` must never fail. [design](docs/design.md#validate-on-the-way-in-conform-on-the-way-out)
- A refused publish still spends a rate-limit token; a failed store write never updates the cache. [design](docs/design.md#the-trust-boundary-is-dotloadoutmanagerpublish)
- The first publish with no index replaces the synthesised default (`_synthesised`), it does not append. [design](docs/design.md#the-synthesised-default-is-an-edit-target-not-a-saved-loadout)
- A choice (`publish_selected`, what the command uses) edits the selected loadout; only `save_as` (`/loadout save NAME`) adds one. `mp_loadout_max_saved` caps how many (0 unlimited, store bound 256) and the refusal names it; the selection is kept in the stored loadout (`selected`). Names: `GSLoadoutNames`.
- `GSLoadoutStoreLocal` writes `{version, loadouts}` atomically; a file that will not parse, is over `mp_loadout_store_max_bytes` or is malformed is renamed `.corrupt` and reads as "no loadouts" (never deleted); a newer `version` is refused and left alone; a new player past `mp_loadout_store_max_files` is refused with `CODE_QUOTA`. A `:` in a key is `~` in the filename. A game keys by a stable per-server key (GameSpice Game `GSGameStatsFeed.key_for`) and wraps the store in `GSLoadoutStoreTiered` so session-keyed seats stay in memory.
- Entitlements default to nothing: an unwired server permits only `GSItem.free`. [design](docs/design.md#entitlements-default-to-nothing)
- A site answer without a token that verifies against a key from the site's published list (or the strict pin) grants nothing; a key is never taken from the answer it verifies, and an unreadable list past `site_keys_grace_sec` grants nothing and logs an error; never add a path that trusts the unsigned body. [design](docs/design.md#site-tokens)
- Retire an item (`GSItem.retired`), never delete it from the catalogue. [design](docs/design.md#retired-is-not-deleted)
- Pickups count ticks to a target tick, reach is horizontal distance under a height gate, and only `GSPickupField` ticks them. [design](docs/design.md#pickups-are-deterministic)
- `GSLoadoutKey` duplicates `GSAvatarKey` on purpose; do not deduplicate. [design](docs/design.md#gsloadoutkey-is-a-copy-deliberately)
- Lists of ids (`filled_slots`, `to_list`, `ids`) sort **by text** with `sort_custom`, never `sort()`: StringNames sort by interning, which differs per process, and `digest()` depends on it. [gdscript-hazards](../../docs/gdscript-hazards.md)
- A server owner's rules (`GSLoadoutRules`, `mp_loadout_menu` / `_allow` / `_fixed`) are applied on the way out (`active_for` hands back a conformed copy), never written into a stored loadout; a cvar value `check()` refuses keeps the old rules. [design](docs/design.md#a-server-owners-rules)
- Fixed slots are the owner's: never entitlement-checked, never trimmed by a budget, and overwritten (not judged) in a publish. [design](docs/design.md#a-server-owners-rules)
- The menu's wire is `GSLoadoutCommand`: `/loadout` answered by a `loadout_menu` notice, `/loadout slot=item ...` through `publish`; names no GameSpice Server class. [design](docs/design.md#the-menus-server-half)
- Name no class outside gs-core; `write`/`read` take `Variant` and type their locals explicitly. Ids go on the wire as strings, never schema indices. [design](docs/design.md#coupling-nothing-is-imported)

## Open

- **No backbone store, by decision (2026-10-11).** No client exists, every game uses the memory store, and games key loadouts by session id, which no backbone can resolve; so there is no website-city loadout route either. What would have to change first, and the shape to build: [design](docs/design.md#no-backbone-store-yet-and-why).

The screen itself is GameSpice Menu's (`GSMenuLoadout`, B). Deliberately not here: buying or a shop, attachments, per-team schemas, dropping a carried weapon. [design](docs/design.md#deliberately-not-here)
