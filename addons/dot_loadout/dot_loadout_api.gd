extends RefCounted

## GameSpice Loadout's API level. The rule for bumping it is on [GSAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: everything before this file existed (an absent file reads as 1).
# 2: a server owner's rules and the loadout menu's server half: GSLoadoutRules (parse, check,
#    permits, CVAR_MENU/CVAR_ALLOW/CVAR_FIXED); GSLoadoutManager.rules, set_rules(),
#    rules_changed, players_choose(), choices_for(), offer_for(); the optional `rules` argument
#    of GSLoadoutValidator.validate/conform and GSLoadoutSchema.choices_for,
#    GSLoadoutValidator.apply_fixed(); GSLoadoutCommand (the `loadout` command, the
#    `loadout_menu` notice, the mp_loadout_* cvars, closed_fn for a game's own reason).
# 3: site tokens and TMC data: GSLoadoutSiteSource verifies the token (public_key, audience, verifier,
#    verify_token, cloud_verify, from_config, points_of, loadout_of, rejected, refreshed, settings;
#    layered's config argument); GSLoadoutSiteSettings; GSLoadoutConfig site_* and site_key().
# 4: GSLoadoutSiteSource reads v2 tokens (signed unlock ids, TOKEN_VERSION 2, OLDEST_TOKEN_VERSION),
#    purchase() (POST store/purchase, PURCHASE_PATH), ingest(), ensure(), mark_stale(); unsigned_grants
#    and GSLoadoutConfig.site_unsigned_grants now default to false.
const LEVEL := 4
const OLDEST := 1
