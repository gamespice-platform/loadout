@tool
class_name GSLoadoutConfig
extends GSConfig

## Everything configurable about loadouts. Layered like every [GSConfig]: exported
## defaults, then a JSON file, then [code]DOT_LOADOUT_*[/code] environment variables,
## then [code]--loadout-*[/code] arguments.

@export_group("Storage")

## Where loadouts live: [code]local[/code] or [code]memory[/code].
@export_enum("local", "memory") var backend: String = "local"

## Directory for the [code]local[/code] backend.
@export var directory: String = "user://loadouts"

@export var read_only: bool = false

## Largest saved-loadout file for one player, in bytes; 0 is unlimited (`mp_loadout_store_max_bytes`).
@export_range(0, 1048576, 1) var store_max_bytes: int = 65536

## Most players' files the [code]local[/code] backend keeps; 0 is unlimited (`mp_loadout_store_max_files`).
@export_range(0, 10000000, 1) var store_max_files: int = 20000

@export_group("Policy")

## Give a player with no saved loadout the schema's default and let them play.
##
## Off holds them at a loadout screen until they pick one, which is a game with a
## meaningful choice. On is what a deathmatch wants: spawn with the rifle.
@export var allow_default_loadout: bool = true

## Repair a loadout that no longer fits the schema instead of refusing it.
##
## [b]On is strongly recommended.[/b] Retiring an item or adding a required slot makes
## existing loadouts invalid, and refusing them means a player who has not logged in
## for a month loads into an error rather than a slightly different gun.
@export var conform_on_load: bool = true

## Check entitlements when validating. [b]Never turn this off on a server.[/b]
##
## It exists for a client previewing its own work and for a creator sandbox. A server
## with it off accepts any loadout carrying anything.
@export var enforce_entitlements: bool = true

## Let a player change loadout while alive. Off means the change takes effect on their
## next spawn, which is what almost every shooter does and what stops a player
## swapping to a rocket launcher mid-fight.
##
## [b]The game enforces this, not the manager.[/b] A publish is stored either way —
## refusing it would lose the player's choice — and "alive" is something only the
## game knows. Read this when deciding whether to re-equip on publish or wait for
## the next spawn; dot-2d-hungry sets it false and equips on spawn.
@export var allow_live_changes: bool = false

@export_group("Limits")

## Saved loadouts one player may keep; 0 is unlimited (the store's own bound, [constant GSLoadout.MAX_SAVED]).
## A server sets it with the `mp_loadout_max_saved` cvar.
@export_range(0, 256, 1) var max_per_player: int = 0

## Loadout publishes allowed per player per minute.
##
## A client in a loadout screen can publish on every click. Without a limit that is a
## store write per frame.
@export_range(1, 240, 1) var publishes_per_minute: int = 12

## Players held in memory at once. 0 is unlimited.
@export_range(0, 100000, 64) var max_cached: int = 2048

## Seconds a fetched loadout stays cached after the player leaves.
@export_range(0.0, 3600.0, 5.0) var cache_ttl_sec: float = 300.0

@export_group("Site store")

## Strict pin (the hardened mode): the site's `publicKey` (raw Ed25519, base64url) copied once over a
## trusted channel, or an RSA public key PEM. Set, only this key verifies and a rotation at the site
## needs it re-pinned on this server. Empty (the default) follows the site's published key list.
@export var site_public_key: String = ""

## A file holding [member site_public_key] instead; set one of the two, not both.
@export var site_public_key_path: String = ""

## This server's scope name at the site (its credential's target, `server:<id>`); the token's `aud` must
## equal it. Empty while following the key list asks the site (`GET me`); a strict pin needs it set.
@export var site_audience: String = ""

## Seconds a player's site answer is trusted before the next read; 0 keeps it until the token's `exp`.
@export_range(0.0, 3600.0, 1.0, "or_greater") var site_ttl_sec: float = 30.0

## Ask TMC for the member's app points and saved loadout with the entitlements.
@export var site_include_points: bool = true
@export var site_include_loadout: bool = true

## Also take the body's `grant.unlock` ids for items a v1 token verified (v1 does not sign the grant; v2 does).
@export var site_unsigned_grants: bool = false

## Following the key list: seconds a good list is used before it is read again; 0 keeps it until a
## token names an unknown `kid`.
@export_range(0.0, 86400.0, 1.0, "or_greater") var site_keys_ttl_sec: float = 300.0

## Least seconds between two reads of the key list (an unknown `kid`, a failing site); 0 is no limit.
@export_range(0.0, 3600.0, 1.0, "or_greater") var site_keys_refetch_min_sec: float = 30.0

## Seconds past `site_keys_ttl_sec` the last good list is still used while the site cannot be read, after
## which every token is refused; 0 is unlimited.
@export_range(0.0, 2592000.0, 1.0, "or_greater") var site_keys_grace_sec: float = 86400.0

## Follow the key list over a plain-HTTP origin that is not loopback. Off: refused (a lab switch only).
@export var site_keys_allow_http: bool = false

## Seconds between reads of the app's settings (store, avatars, stats); 0 reads once and stops.
@export_range(0.0, 86400.0, 1.0, "or_greater") var site_settings_poll_sec: float = 60.0


## The strict pin from [member site_public_key] or [member site_public_key_path]; "" means none is set
## and the site's key list is followed. Fails only on a set but unusable pin.
func site_key() -> GSResult:
	if site_public_key != "" and site_public_key_path != "":
		return GSResult.fail(GSError.CODE_INVALID, "Set site_public_key or site_public_key_path, not both.")
	if site_public_key_path != "":
		if not FileAccess.file_exists(site_public_key_path):
			return GSResult.fail(GSError.CODE_IO, "site_public_key_path does not exist: %s (clear it to follow the site's key list)" % site_public_key_path)
		var text := FileAccess.get_file_as_string(site_public_key_path).strip_edges()
		if text == "":
			return GSResult.fail(GSError.CODE_INVALID, "site_public_key_path is empty: %s (clear it to follow the site's key list)" % site_public_key_path)
		return GSResult.success(text)
	return GSResult.success(site_public_key.strip_edges())


## True when a strict pin is configured, false when the site's key list is followed.
func site_pinned() -> bool:
	return site_public_key.strip_edges() != "" or site_public_key_path != ""


func env_prefix() -> String:
	return "DOT_LOADOUT_"


func cli_prefix() -> String:
	return "--loadout-"


func validate() -> GSResult:
	if backend == "local" and directory.strip_edges() == "":
		return GSResult.fail(
			GSError.CODE_INVALID, "The local backend needs a directory."
		)

	if not enforce_entitlements:
		# Loud, because it is the one setting here that turns off a security control
		# and the symptom is players carrying things they have not unlocked, which
		# nobody reports as a bug.
		GSLog.warn(
			"loadout.config",
			"enforce_entitlements is off; any loadout will be accepted"
		)

	if site_public_key != "" and site_public_key_path != "":
		return GSResult.fail(GSError.CODE_INVALID, "Set site_public_key or site_public_key_path, not both.")

	return GSResult.success(null)


func describe_summary() -> String:
	return "%s%s%s" % [
		backend,
		" read-only" if read_only else "",
		"" if enforce_entitlements else " UNENFORCED",
	]
