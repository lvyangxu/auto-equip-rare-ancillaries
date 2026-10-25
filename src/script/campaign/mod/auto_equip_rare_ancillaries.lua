--====================================================================--
--  Auto Equip Rare Ancillaries
--  (AutoEquipRareAncillaries v1.13.0)
--====================================================================--
--  Standalone mod.  It used to live inside "AutoSkillPointsForAgents"; the
--  two are now completely independent packs and either one can be enabled
--  without the other.
--  Adds one button to the character details panel's equipment pool.
--  Clicking it moves every idle (not equipped by anybody) ancillary of the
--  local faction whose rarity is common, uncommon or rare (i.e. every tier up
--  to and including blue) onto the player's IMMORTAL agents.  Items above
--  that (unique / purple) stay in the pool.
--
--  Why immortal characters only?
--  -----------------------------
--  A character that is not immortal can be killed permanently when it is
--  defeated, and every ancillary it carries is destroyed with it.  The
--  "长生久视" (immortality) skill turns death into a wound, so equipment
--  given to such a character survives.  character_details():is_immortal()
--  is the engine flag that the skill sets, so only characters for which
--  it returns true are ever used as targets.
--
--  Never replaces anything
--  ------------------------
--  A slot that is already taken is never used: the number of items of a
--  category a character already wears is compared with the slot count of
--  that category, and the item is kept in the pool when the count is full.
--  The counts are read off the character (CcoCampaignCharacter.AncillaryList),
--  the same way the vanilla prologue achievements do it.
--
--  Which pool items are idle is arithmetic, not a guess:
--      idle instances of a key = (entries of that key in the faction list)
--                              - (characters wearing that key)
--  Both numbers come from AncillaryList reads (faction side and character
--  side respectively), the same shape the vanilla scripts use.  The owner
--  property of a pool entry (CharacterEquippedToContext) is never read: it is
--  a null context on idle items and reading it is what crashed the game in
--  v1.0.0 - v1.1.4.  cm:model():world():characters_owning_ancillary() is not
--  used either - its counts do not match reality ("pool=1 worn=5").
--
--  Why not every item on every hero?
--  ---------------------------------
--  Some rare items only boost missile (ranged) combat.  Giving those to a
--  melee hero wastes one of the hero's equipment slots, so when "avoid
--  ranged items on melee heroes" is enabled the item's db key is inspected
--  (e.g. "..._anc_weapon_bow_of_...").  Reading the effect list of an
--  ancillary (CcoEffect.EffectKey)
--  and the unit stats of a character (UnitDetailsContext / StatList) are two
--  documented-only-with-an-expression-state calls that crashed the game, so
--  both are switched off; an item that looks ranged is simply not handed to
--  a melee agent.
--
--  How the item is handed over
--  ---------------------------
--  cm:force_add_ancillary(character, key, true, false), the vanilla reward
--  path of wh_campaign_setup.lua:2068-2072.  It is issued on the campaign
--  tick (never inside the UI click callback) and one item at a time.
--
--  v1.2.x also called cm:force_remove_ancillary_from_faction() first and
--  died inside it; v1.2.3 - v1.3.1 tried CcoCampaignAncillary.
--  EquipToCharacter() instead, which either did nothing or answered
--  "AncillaryList.Size = nil".  Both routes are gone.
--
--  Diagnostics
--  -----------
--  With "debug" enabled the log shows a "phase n/4" line before every step,
--  so if the game ever dies during a run the log pinpoints the step.
--
--  UI and mod compatibility
--  ------------------------
--  Following the approach of the "Fusion Wizard" mod this script does NOT
--  override a single vanilla .twui.xml file.  The button is created at
--  runtime from the vanilla template
--  "ui/templates/square_large_text_button" and parented into the existing
--  equipment pool, so mods that edit the character panel layout cannot
--  conflict with it.  If Fusion Wizard is installed its button is detected
--  and this mod's button is stacked directly above it.
--
--  IMPORTANT: the engine lower-cases the file path inside the pack and then
--  calls the global function of that (lower-cased) name, so the file is
--  named auto_equip_rare_ancillaries.lua and the entry point below is
--  auto_equip_rare_ancillaries() - both must stay all lower case.
--====================================================================--

local AERA_VERSION    = "1.56.1";
-- The remove command takes every copy of a key, so a duplicate key is moved
-- as "remove all, equip one, put the other copies back".  Refuse very large
-- stacks: the caller would have to re-add too many copies in one tick.
local AERA_MAX_DUPLICATES = 10;
local AERA_LOG_PREFIX = "[auto_equip_rare_ancillaries] ";

----------------------------------------------------------------------
-- logging
----------------------------------------------------------------------

local aera_debug_enabled = false;

-- A second, self-managed copy of the log.
--
-- lua_mod_log.txt is written by the engine and sometimes stops echoing
-- halfway through a run, which makes it impossible to tell "the script died"
-- from "the log is behind".  Every line is therefore also appended to a file
-- this script owns and closes after each write, so nothing can stay in a
-- buffer.  If the sandbox has no io library the call fails once and the
-- mirroring turns itself off.
local AERA_TRACE_PATH    = "aera_trace.log";
local aera_trace_enabled = true;

local function aera_trace(msg)
	if not aera_trace_enabled then
		return;
	end;

	local ok = pcall(function()
		local file = io.open(AERA_TRACE_PATH, "a");
		if file == nil then
			return;
		end;

		file:write(tostring(msg) .. "\n");
		file:close();
	end);

	if not ok then
		aera_trace_enabled = false;
	end;
end;

local function aera_out(msg)
	-- Every line is gated by the MCT "output equipment debug log" switch.
	-- With the switch off the mod writes nothing at all.
	if not aera_debug_enabled then
		return;
	end;

	local text = AERA_LOG_PREFIX .. tostring(msg);

	-- out() and ModLog belong to other mods / the engine, so neither may be
	-- allowed to break the run: if one of them throws, the trace file still
	-- carries the line.
	pcall(function()
		out(text);
	end);

	aera_trace(text);

	if ModLog ~= nil then
		pcall(function()
			ModLog(text);
		end);
	end;
end;

local function aera_debug(msg)
	if aera_debug_enabled then
		aera_out("debug: " .. tostring(msg));
	end;
end;

-- Is the faction CCO usable from the thread this is called on?
--
-- v1.3.1 showed that a context opened at the start of a run answers
-- AncillaryList.Size for a while and then returns nil, and v1.5.1 saw the
-- same nil from a context opened only for the equip step.  Fusion Wizard
-- opens its faction context inside a UI click callback (_fw.lua:489), so the
-- suspicion is that CCO only resolves on the UI thread.  This probe is
-- called from both threads on every click, which tells the two apart.
local function aera_probe_context(where)
	local name = nil;
	pcall(function()
		name = cm:get_local_faction_name();
	end);

	if name == nil then
		aera_out("probe: " .. where .. " faction context: no local faction name");
		return;
	end;

	local ok, size = pcall(function()
		return cco("CcoCampaignFaction", name):Call("AncillaryList.Size");
	end);

	aera_out("probe: " .. where .. " faction context: AncillaryList.Size=" .. tostring(size)
		.. " (ok=" .. tostring(ok) .. ")");
end;

----------------------------------------------------------------------
-- Mod Configuration Tool (MCT) integration
----------------------------------------------------------------------
-- keys MUST match script/mct/settings/auto_equip_rare_ancillaries_settings.lua

local AERA_MCT_MOD_KEY        = "auto_equip_rare_ancillaries";
local AERA_MCT_OPTION_ENABLED = "equip_rare_enabled";
local AERA_MCT_OPTION_RANGED  = "equip_avoid_ranged_on_melee";
local AERA_MCT_OPTION_LORDS   = "equip_include_lords";
local AERA_MCT_OPTION_DEBUG   = "equip_debug";
local AERA_MCT_OPTION_AUTO_TURN = "equip_auto_each_turn";

local function aera_mct_get(option_key, fallback)
	if get_mct == nil then
		return fallback;
	end;

	local ok, value = pcall(function()
		local mct = get_mct();
		local mod = mct:get_mod_by_key(AERA_MCT_MOD_KEY);
		if mod == nil then
			return nil;
		end;

		local option = mod:get_option_by_key(option_key);
		if option == nil then
			return nil;
		end;

		return option:get_selected_setting();
	end);

	if ok and value ~= nil then
		return value;
	end;

	return fallback;
end;

----------------------------------------------------------------------
-- small helpers
----------------------------------------------------------------------

local function aera_contains_any(text, words)
	if text == nil then
		return false;
	end;

	local lower = string.lower(tostring(text));
	for i = 1, #words do
		if string.find(lower, words[i], 1, true) ~= nil then
			return true;
		end;
	end;

	return false;
end;

-- Is this a usable object at all?
--
-- Only real script interfaces (character, faction, ...) answer
-- is_null_interface().  Some objects the campaign hands out - the list of
-- characters of a faction, the list from characters_owning_ancillary() -
-- have num_items()/item_at() but no is_null_interface at all, and calling it
-- on them raised "attempt to call method 'is_null_interface' (a nil value)"
-- and aborted the whole run (v1.1.5 and v1.1.7).  So the call is guarded:
-- when the method is missing the object is simply treated as usable.
local function aera_is_valid_interface(interface)
	if interface == nil then
		return false;
	end;

	local ok, result = pcall(function()
		return interface:is_null_interface();
	end);

	if not ok then
		return true;
	end;

	return result == false;
end;

local function aera_is_local_faction(faction)
	if not aera_is_valid_interface(faction) then
		return false;
	end;

	if faction:name() == cm:get_local_faction_name() then
		return true;
	end;

	return faction:is_human();
end;

local function aera_is_multiplayer()
	local ok, result = pcall(function()
		return cm:is_multiplayer();
	end);

	return ok and result == true;
end;

----------------------------------------------------------------------
-- item classification: does this ancillary only help missile combat?
----------------------------------------------------------------------

-- words that show an effect / key is about ranged (missile) combat
local AERA_RANGED_WORDS = {
	"missile", "ranged", "projectile",      -- english db keys / english text
	"远程", "射程", "弹药",                  -- chinese localised text
};

-- defensive missile effects are fine on a melee hero, never classify them
-- as "ranged only"
local AERA_DEFENSIVE_WORDS = {
	"resist", "抗性", "抵抗",
};

-- ranged weapons inside an ancillary db key, e.g.
-- wh_main_anc_weapon_bow_of_..., wh2_dlc..._anc_enchanted_item_arrow_...
local AERA_ITEM_KEY_WORDS = {
	"_bow", "_arrow", "_archer", "_crossbow", "_handgun", "_gun",
	"_pistol", "_rifle", "_musket", "_missile", "_ranged", "_ammo",
	"_quarrel", "_javelin", "_sling", "_bombard", "_cannon", "_shot",
};

local function aera_item_key_is_ranged(key)
	if key == nil then
		return false;
	end;

	if aera_contains_any(key, AERA_DEFENSIVE_WORDS) then
		return false;
	end;

	if aera_contains_any(key, AERA_ITEM_KEY_WORDS) then
		return true;
	end;

	return aera_contains_any(key, AERA_RANGED_WORDS);
end;

-- Is this ancillary only useful for missile combat?
--
-- ONLY the db key is inspected.  It used to read the localised effect text
-- first (AncillaryRecordContext.EffectText / EffectList) and to walk the
-- effect entries with "At(i).EffectKey" - but CcoEffect.EffectKey is
-- documented as "only valid to call when created with a CAMPAIGN_EFFECT",
-- and calling it on an ancillary effect is a native crash (pcall cannot
-- catch it).  A key check is pure string matching and cannot crash.
local function aera_item_is_ranged(key)
	return aera_item_key_is_ranged(key);
end;

----------------------------------------------------------------------
-- agent helpers
----------------------------------------------------------------------

-- cqi -> true / false / nil (nil = could not be determined)
local aera_agent_ranged_cache = {};

local AERA_MISSILE_STAT_WORDS = {
	"missile", "ranged", "projectile", "ammo",
};

-- Reading a character's unit stats goes through
-- CcoCampaignCharacter.UnitDetailsContext, whose documented signature needs
-- an ExpressionState argument that script cannot produce.
-- CcoUnitDetails.StatList needs one as well.  A wrong call there crashes the
-- game instead of raising a Lua error (pcall cannot catch it), so the agent
-- side is switched off on purpose: "unknown" means the item is allowed
-- through, exactly as the README describes.  Only flip this to true after
-- that call has been proven safe on the running game build.
local AERA_READ_UNIT_STATS = false;

-- Read the character's own unit stats and look for a missile stat with a
-- positive value.  Returns true (ranged), false (melee) or nil (unknown).
local function aera_agent_is_ranged(cqi)
	if not AERA_READ_UNIT_STATS then
		return nil;
	end;

	local cached = aera_agent_ranged_cache[cqi];
	if cached ~= nil then
		return cached;
	end;

	local result = nil;

	local ok, err = pcall(function()
		local char_cco = cco("CcoCampaignCharacter", tostring(cqi));
		if char_cco == nil then
			return;
		end;

		local details = char_cco:Call("UnitDetailsContext");
		if details == nil then
			return;
		end;

		local stats = details:Call("StatList");
		if stats == nil then
			return;
		end;

		local count = stats:Call("Size");
		if type(count) ~= "number" then
			return;
		end;

		local found = false;
		for i = 0, count - 1 do
			local key = nil;
			local value = nil;

			pcall(function()
				key = stats:Call("At(" .. i .. ").Key");
			end);
			pcall(function()
				value = stats:Call("At(" .. i .. ").Value");
			end);

			if key ~= nil then
				key = string.lower(tostring(key));
				if aera_contains_any(key, AERA_MISSILE_STAT_WORDS)
					and not aera_contains_any(key, AERA_DEFENSIVE_WORDS)
					and type(value) == "number" and value > 0
				then
					found = true;
					break;
				end;
			end;

			aera_debug("cqi " .. tostring(cqi) .. " stat " .. tostring(key)
				.. " = " .. tostring(value));
		end;

		result = found;
	end);

	if not ok then
		aera_debug("could not read unit stats for cqi " .. tostring(cqi)
			.. ": " .. tostring(err));
	end;

	if result ~= nil then
		aera_agent_ranged_cache[cqi] = result;
	end;

	return result;
end;

local function aera_can_equip(character, key)
	local ok, result = pcall(function()
		return character:can_equip_ancillary(key);
	end);

	if not ok then
		-- the engine call is unavailable for some reason: do not filter the
		-- item out, let the equip attempt itself decide
		return true;
	end;

	return result == true;
end;

----------------------------------------------------------------------
-- free slot check
----------------------------------------------------------------------
-- can_equip_ancillary() only answers "may this character use this kind of
-- ancillary at all" - it ignores the slots that are already taken.  The
-- vanilla drop rule of the character panel is
--
--     CanEquipAncillary(this) && (IsContextValid(<item of that slot>) ||
--                                 ChildIndex == equipped_same_category + 1)
--
-- i.e. an occupied slot is a valid drop target (that is how swapping works
-- in the UI), and EquipToCharacter(item, swap) replaces the item that is
-- handed to it.  So equipping on a character whose slots for the category
-- are all taken replaces an item that was already worn.  This must never
-- happen here: the number of items of the same category the character
-- already wears is compared against the slot count of that category.

local AERA_CATEGORY_SLOT_COUNT = {
	weapon         = 1,
	armour         = 1,
	armor          = 1,
	talisman       = 1,
	enchanted_item = 1,
	arcane_item    = 1,
	mount          = 1,
};

local AERA_DEFAULT_SLOT_COUNT = 1;

local function aera_slot_count(category)
	if category == nil then
		return AERA_DEFAULT_SLOT_COUNT;
	end;

	local known = AERA_CATEGORY_SLOT_COUNT[string.lower(tostring(category))];
	if type(known) == "number" then
		return known;
	end;

	return AERA_DEFAULT_SLOT_COUNT;
end;

-- declared here so the helpers below can use it; the body is further down
local aera_pool_prop;

-- Which categories does a character wear, and how many of each?
--
-- Read straight off the character context, exactly the way the vanilla
-- scripts do it (wh3_prologue_kislev_expedition_achievements.lua):
--     AncillaryList.Size
--     AncillaryList.At(i).AncillaryRecordContext.CategoryContext.Key
-- Returns a table category -> count, or nil when the list cannot be read.
local function aera_character_worn(char_ctx)
	local counts = {};

	if char_ctx == nil then
		return nil;
	end;

	local n = aera_pool_prop(char_ctx, "AncillaryList.Size");
	if type(n) ~= "number" then
		return nil;
	end;

	for i = 0, n - 1 do
		local category = aera_pool_prop(
			char_ctx, "AncillaryList.At(" .. i .. ").AncillaryRecordContext.CategoryContext.Key"
		);

		if category ~= nil then
			category = tostring(category);
			counts[category] = (counts[category] or 0) + 1;
		end;
	end;

	return counts;
end;

-- CcoCampaignCharacter is addressed by the command queue index, which is what
-- wh3_dlc26_tyrants_demands.lua and episode_nagash_endgame.lua do as well.
local function aera_character_ctx(agent)
	if agent.cco == nil then
		local ok, ctx = pcall(function()
			return cco("CcoCampaignCharacter", agent.cqi);
		end);

		if ok then
			agent.cco = ctx;
		end;
	end;

	return agent.cco;
end;

local function aera_worn_count(worn, category)
	if worn == nil then
		return nil;
	end;

	return worn[category] or 0;
end;

local function aera_mark_worn(worn, category)
	if worn == nil or category == nil then
		return;
	end;

	worn[category] = (worn[category] or 0) + 1;
end;

-- true only when a genuinely empty slot of that category exists.  When the
-- character's own equipment cannot be read the answer is "no": this mod must
-- never guess its way into replacing something.
local function aera_has_free_slot(agent, item, worn)
	local category = item.category;
	if category == nil then
		aera_debug("cannot tell the category of " .. tostring(item.key)
			.. ", keeping it in the pool");
		return false;
	end;

	local used = aera_worn_count(worn, category);
	if used == nil then
		aera_debug("cannot read the equipped items of cqi " .. tostring(agent.cqi)
			.. ", keeping " .. tostring(item.key) .. " in the pool");
		return false;
	end;

	local capacity = aera_slot_count(category);
	if used >= capacity then
		aera_debug("cqi " .. tostring(agent.cqi) .. " already wears "
			.. tostring(used) .. "/" .. tostring(capacity) .. " " .. tostring(category)
			.. ", keeping " .. tostring(item.key) .. " in the pool");
		return false;
	end;

	return true;
end;

-- Immortal, on the map, player owned agents (lords optional).
local function aera_collect_agents(faction, include_lords)
	local agents = {};

	local list = faction:character_list();
	if list == nil then
		aera_out("targets: the faction has no character list");
		return agents;
	end;

	local count = list:num_items();
	aera_out("targets: " .. tostring(count) .. " character(s), lords "
		.. (include_lords and "included" or "excluded"));

	for i = 0, count - 1 do
		local character = list:item_at(i);

		if aera_is_valid_interface(character) then
			local is_agent = cm:char_is_agent(character);
			local is_lord = (not is_agent) and cm:char_is_general(character);

			if is_agent or is_lord then
				local details = character:character_details();
				local immortal = false;
				if aera_is_valid_interface(details) then
					immortal = details:is_immortal() == true;
				end;

				local alive = character:is_alive();
				local wounded = character:is_wounded();

				local subtype = "?";
				pcall(function()
					subtype = character:character_subtype_key();
				end);

				-- a run with no usable target has to say why, so this is not
				-- behind the debug option
				aera_out("targets: cqi " .. tostring(character:command_queue_index())
					.. " subtype=" .. tostring(subtype)
					.. " agent=" .. tostring(is_agent)
					.. " lord=" .. tostring(is_lord)
					.. " immortal=" .. tostring(immortal)
					.. " alive=" .. tostring(alive)
					.. " wounded=" .. tostring(wounded)
					.. " -> " .. ((immortal and alive and not wounded) and "used" or "skipped"));

				if immortal and alive and not wounded and (is_agent or include_lords) then
					agents[#agents + 1] = {
						character = character,
						cqi       = character:command_queue_index(),
					};
				end;
			end;
		end;
	end;

	return agents;
end;

----------------------------------------------------------------------
-- faction ancillary pool access (CcoCampaignFaction.AncillaryList)
----------------------------------------------------------------------

-- One property read on a context.  A single unsupported property must never
-- break the whole scan, so failures come back as nil.
aera_pool_prop = function(ctx, expr)
	if ctx == nil then
		return nil;
	end;

	local ok, value = pcall(function()
		return ctx:Call(expr);
	end);

	if ok then
		return value;
	end;

	return nil;
end;

----------------------------------------------------------------------
-- the ancillary database
----------------------------------------------------------------------
-- Which keys exist cannot be read off the campaign model: there is no cm:
-- call that enumerates the faction pool.  The vanilla magic item scripts
-- open the CcoAncillaryRecord database once and filter it by rarity
-- (wh3_campaign_magic_items.lua:58-68), and the same thing is done here -
-- once per session, at the first tick.
--
-- Everything a run needs after that is plain script interface work:
--     faction:num_ancillaries_owned(key)   -- pool + worn
--     character:has_ancillary(key)         -- worn
--     cm:force_add_ancillary(character, key, true, false)
--
-- v1.3.0 / v1.3.1 read CcoCampaignFaction.AncillaryList on every run (up to
-- four Call()s per pool entry).  After a few dozen reads the same context
-- starts answering nil ("fresh faction context: AncillaryList.Size=nil"),
-- and both crash dumps arrived 3 - 11 seconds after such a run, so those
-- reads are gone.

local AERA_DB_ITEMS    = nil;      -- db key -> { rarity = ..., category = ... }
local AERA_DB_STATE    = "idle";   -- idle / loading / ready / failed
local AERA_DB_RARITIES = { "common", "uncommon", "rare" };
-- Every ancillary key of the categories a character can wear, not just the
-- droppable ones.  This is what the free-slot check counts with
-- has_ancillary(); a worn legendary that is not in AERA_DB_ITEMS would
-- otherwise look like an empty slot and get replaced.
local AERA_DB_CATEGORIES = {
	"weapon", "armour", "talisman", "enchanted_item", "arcane_item", "mount",
};
local AERA_ALL_KEYS_BY_CATEGORY = nil;
-- Built once per run: category -> the keys the faction actually owns, and
-- key -> owned count.  The worn-slot check then only has to ask
-- has_ancillary() about the owned keys instead of the whole category.
local AERA_OWNED_KEYS_BY_CATEGORY = nil;
local AERA_OWNED_COUNT = nil;

local function aera_db_load()
	if AERA_DB_STATE == "loading" or AERA_DB_STATE == "ready" then
		return;
	end;

	AERA_DB_STATE = "loading";

	local items  = {};
	local total  = 0;

	local ok, err = pcall(function()
		local root = cco("CcoCampaignRoot", "");
		if root == nil then
			return;
		end;

		local records = root:Call('DefaultDatabaseRecord("CcoAncillaryRecord")');
		if records == nil then
			return;
		end;

		for r = 1, #AERA_DB_RARITIES do
			local rarity = AERA_DB_RARITIES[r];
			-- every item of this rarity, not only RandomlyDropped == true:
			-- fused / crafted / quest versions are blue too and used to be
			-- invisible to the mod (they are not random drops)
			local list = records:Call(
				'RecordList.Filter(RarityState == "' .. rarity .. '")'
			);

			if type(list) == "table" then
				for i = 1, #list do
					local key_ok, key = pcall(function()
						return list[i]:Call("Key");
					end);

					if key_ok and key ~= nil then
						local cat_ok, category = pcall(function()
							return list[i]:Call("CategoryContext.Key");
						end);

						items[tostring(key)] = {
							rarity   = rarity,
							category = (cat_ok and category ~= nil) and tostring(category) or nil,
						};

						total = total + 1;
					end;
				end;
			end;
		end;

		-- All keys per wearable category, regardless of rarity or
		-- droppability.  Kept in its own pcall: if this extra pass is not
		-- supported on a build, the droppable cache above still works and
		-- the free-slot check falls back to it.
		local all_keys = {};
		local all_ok, all_err = pcall(function()
			for c = 1, #AERA_DB_CATEGORIES do
				local category = AERA_DB_CATEGORIES[c];
				local list = records:Call(
					'RecordList.Filter(CategoryContext.Key == "' .. category .. '")'
				);

				if type(list) == "table" then
					local keys = {};
					for i = 1, #list do
						local key_ok, key = pcall(function()
							return list[i]:Call("Key");
						end);

						if key_ok and key ~= nil then
							keys[#keys + 1] = tostring(key);
						end;
					end;

					all_keys[category] = keys;
					aera_debug("category " .. category .. ": "
						.. tostring(#keys) .. " key(s)");
				end;
			end;
		end);

		if all_ok then
			AERA_ALL_KEYS_BY_CATEGORY = all_keys;

			local parts = {};
			for c = 1, #AERA_DB_CATEGORIES do
				local category = AERA_DB_CATEGORIES[c];
				local keys = all_keys[category] or {};
				parts[#parts + 1] = category .. "=" .. tostring(#keys);
			end;
			aera_out("ancillary category keys: " .. table.concat(parts, " "));
		else
			aera_out("could not cache all ancillary keys by category: " .. tostring(all_err));
		end;
	end);

	if not ok or total == 0 then
		AERA_DB_STATE = "failed";
		AERA_DB_ITEMS = nil;
		aera_out("could not read the ancillary database: " .. tostring(err));
		return;
	end;

	AERA_DB_ITEMS = items;
	AERA_DB_STATE = "ready";

	aera_debug("ancillary database: " .. tostring(total) .. " droppable key(s) cached");
end;

-- Build the per-run "what does this faction own" index.
--
-- A character can only wear a key the faction owns, so the free-slot check
-- does not need to ask has_ancillary() about every key in the category
-- (hundreds), only about the owned ones (usually a few dozen).  The same
-- pass also gives collect_idle() the owned count, so it does not have to
-- call num_ancillaries_owned() a second time.
local function aera_build_owned_index(faction)
	local started = os.clock();
	local by_category = {};
	local counts = {};

	local source = AERA_ALL_KEYS_BY_CATEGORY;
	local source_total = 0;

	if source ~= nil then
		for _, list in pairs(source) do
			source_total = source_total + #list;
		end;
	end;

	if source == nil or source_total == 0 then
		-- fallback: the droppable cache, grouped by category
		source = {};
		if AERA_DB_ITEMS ~= nil then
			for key, meta in pairs(AERA_DB_ITEMS) do
				local category = meta.category;
				if category ~= nil and category ~= "general" then
					local list = source[category];
					if list == nil then
						list = {};
						source[category] = list;
					end;
					list[#list + 1] = key;
				end;
			end;
		end;
	end;

	local total_owned = 0;

	for category, keys in pairs(source) do
		local owned_list = {};

		for i = 1, #keys do
			local key = keys[i];
			local ok, owned = pcall(function()
				return faction:num_ancillaries_owned(key);
			end);

			if ok and type(owned) == "number" and owned > 0 then
				owned_list[#owned_list + 1] = key;
				counts[key] = owned;
				total_owned = total_owned + 1;
			end;
		end;

		by_category[category] = owned_list;
	end;

	AERA_OWNED_KEYS_BY_CATEGORY = by_category;
	AERA_OWNED_COUNT = counts;

	aera_debug("owned index: " .. tostring(total_owned)
		.. " key(s), " .. string.format("%.1f", (os.clock() - started) * 1000)
		.. " ms");
end;

-- Idle instances of a key = (owned by the faction) - (worn by a character).
--
-- faction:num_ancillaries_owned(key) counts the pool *and* the worn ones,
-- and the number of characters that answer has_ancillary() is the worn part,
-- so the difference is what is still lying in the pool.  This is exactly the
-- arithmetic of wh3_campaign_magic_items.lua:259-272.
--
-- Banners ("general") are skipped: they belong on units and a character has
-- no slot for them.  Each item carries `idle`, the number of idle instances
-- of that key, so a key that sits in the pool twice can still be handed to
-- two characters.
local function aera_collect_idle(faction)
	local items = {};

	if AERA_DB_ITEMS == nil then
		aera_debug("the ancillary database is not available, nothing to scan");
		return items;
	end;

	aera_build_owned_index(faction);

	if AERA_OWNED_COUNT == nil then
		aera_out("could not build the owned ancillary index, nothing to scan");
		return items;
	end;

	local scan_started = os.clock();

	local characters = {};
	local list = faction:character_list();

	if aera_is_valid_interface(list) then
		local n = 0;
		pcall(function()
			n = list:num_items();
		end);

		for i = 0, n - 1 do
			local character = list:item_at(i);

			if aera_is_valid_interface(character) then
				characters[#characters + 1] = character;
			end;
		end;
	end;

	local keys = {};
	for key in pairs(AERA_DB_ITEMS) do
		keys[#keys + 1] = key;
	end;
	table.sort(keys);

	local lines         = {};
	local idle_total    = 0;
	local idle_rarities = {};
	local owned_keys    = 0;

	for i = 1, #keys do
		local key  = keys[i];
		local meta = AERA_DB_ITEMS[key];

		if meta ~= nil and meta.category ~= "general" then
			local owned = AERA_OWNED_COUNT[key];

			if type(owned) == "number" and owned > 0 then
				owned_keys = owned_keys + 1;

				local worn = 0;
				for j = 1, #characters do
					local ok_has, has = pcall(function()
						return characters[j]:has_ancillary(key);
					end);

					if ok_has and has == true then
						worn = worn + 1;
					end;
				end;

				local idle = owned - worn;
				if idle > 0 then
					idle_total = idle_total + idle;

					local rarity = meta.rarity or "?";
					idle_rarities[rarity] = (idle_rarities[rarity] or 0) + idle;

					lines[#lines + 1] = "  " .. key
						.. " rarity=" .. tostring(meta.rarity)
						.. " category=" .. tostring(meta.category)
						.. " owned=" .. tostring(owned)
						.. " worn=" .. tostring(worn)
						.. " idle=" .. tostring(idle);

					items[#items + 1] = {
						key      = key,
						rarity   = meta.rarity,
						category = meta.category,
						owned    = owned,
						worn     = worn,
						idle     = idle,
					};
				end;
			end;
		end;
	end;

	local histogram = "";
	for rarity, n in pairs(idle_rarities) do
		histogram = histogram .. " " .. tostring(rarity) .. "=" .. tostring(n);
	end;

	-- the summary goes out first: whatever happens further down, the numbers
	-- that matter are already in the log
	aera_debug("pool: " .. tostring(owned_keys) .. " owned key(s), "
		.. tostring(idle_total) .. " idle, idle rarities:" .. histogram);

	for i = 1, #lines do
		aera_debug(lines[i]);
	end;

	aera_debug("scan done: " .. tostring(owned_keys) .. " owned key(s), "
		.. tostring(#items) .. " item(s) to place, "
		.. string.format("%.1f", (os.clock() - scan_started) * 1000) .. " ms");

	return items;
end;



----------------------------------------------------------------------
-- equipping
----------------------------------------------------------------------

-- How many instances of a key the faction owns (pool + worn).
local function aera_owned(faction, key)
	local ok, owned = pcall(function()
		return faction:num_ancillaries_owned(key);
	end);

	if ok and type(owned) == "number" then
		return owned;
	end;

	return nil;
end;

----------------------------------------------------------------------
-- equipping (v1.15.0: ui context takes the copy, cm: hands it over)
----------------------------------------------------------------------
--
-- What the log proved on this build:
--
--   cm:force_add_ancillary(character, key, true, true)
--       -> equips the item (wears=true) when the faction owns 0 of the key
--       -> native crash (0xc0000005, null read) when the faction already
--          owns it, which is true for everything sitting in the pool
--   cm:force_remove_ancillary_from_faction(faction, key)
--       -> returns "ok" and the item leaves the pool, but the campaign thread
--          does not survive the deferred model work
--   CcoCampaignFaction.CharacterList
--       -> does not resolve on this build (returns nil); asking for it kills
--          the context evaluator, and MCT (which builds its panel from CCO)
--          then cannot open any more
--
-- So the two halves are done with the one call shape that is proven for each:
--
--   1. take the copy out of the pool through the ui context object, the way
--      the Fusion Wizard mod removes a pool item before salvaging it
--      (_fw.lua:584): ancillary_cco:Call("RemoveAncillary")
--   2. hand the key to the character with cm:force_add_ancillary(..., true,
--      true), which is the shape that equips when the faction owns 0 of it
--
-- Step 2 only runs when step 1 really took the copy away, and the item is put
-- back in the pool if step 2 fails, so nothing can be lost.
local function aera_faction_cco(faction)
	local ok, res = pcall(function()
		return cco("CcoCampaignFaction", faction:name());
	end);

	if ok and res ~= nil then
		return res;
	end;

	aera_debug("  no CcoCampaignFaction for " .. tostring(faction:name()));
	return nil;
end;

-- Putting a pool copy on a character.
--
-- What the ui context can and cannot do on this build (v1.18.0 probes):
--
--   AncillaryList.At(i).AncillaryRecordContext.Key           works
--   AncillaryList.Filter(...).Size                          works
--   AncillaryList.Filter(...).At(0).AncillaryRecordContext.Key works
--   faction_cco:Call("AncillaryList.Filter(...).At(0)")       -> nil
--   StoreList(...)  twice in one run                        -> nil
--   ...At(0).RemoveAncillary()   -> runs, but does nothing for a pool entry
--      (the documentation is exact: it detaches an item from a character)
--
-- None of that is needed.  The character details panel equips a pool copy
-- with one single command, and it is the one the vanilla ui calls when the
-- player drags an item onto a slot (_cdp_details.twui.xml:5876):
--
--   ...SelectedObjectList.FirstContext.EquipToCharacter(<character>, <swap>)
--
-- The command sits on the ancillary (CcoCampaignAncillary, "Equips itself to
-- the specified character, and swaps with the ancillary passed in if this
-- exists"), so nothing is salvaged and nothing is created out of thin air.
--
-- The character argument is the hard part: a context cannot be handed back to
-- Lua (v1.18.0), it has to be named inside the same expression.  Two things
-- make that possible:
--
--   * argument expressions are evaluated against the context the chain was
--     started on - the Fusion Wizard mod relies on that when it fuses
--     (_fw.lua:526: "...At(i).FuseForPlayer(AncillaryList.Filter(...).At(j))";
--     the argument starts at the faction, not at the ancillary)
--   * CcoCampaignRoot has CharacterList ("all characters in the campaign")
--     and FactionList, so a chain started at the root can reach both the pool
--     copy and the character
--
-- v1.21.0 tried that from the faction instead and FactionList/CharacterList are
-- not properties of CcoCampaignFaction on this build: every property of that
-- handle came back nil afterwards (one bad name kills the whole handle), which
-- is why the root is the root from now on.
local function aera_root_cco()
	local ok, res = pcall(function()
		return cco("CcoCampaignRoot", "");
	end);

	if ok and res ~= nil then
		return res;
	end;

	aera_debug("  no CcoCampaignRoot");
	return nil;
end;

-- the pool copy, reached from the campaign root
local function aera_pool_expr(faction_name, key)
	return "FactionList.Filter(FactionRecordContext.Key == '" .. tostring(faction_name) .. "').At(0)"
		.. ".AncillaryList.Filter(AncillaryRecordContext.Key == '" .. tostring(key)
		.. "' && IsContextValid(CharacterEquippedToContext) == false).At(0)";
end;

local function aera_character_expr(cqi)
	return "CharacterList.Filter(CQI == " .. tostring(cqi) .. ").At(0)";
end;

local function aera_equip_expr(faction_name, key, cqi)
	return aera_pool_expr(faction_name, key)
		.. ".EquipToCharacter(" .. aera_character_expr(cqi) .. ")";
end;

local function aera_can_equip_expr(faction_name, key, cqi)
	return aera_pool_expr(faction_name, key)
		.. ".CanCharacterEquip(" .. aera_character_expr(cqi) .. ")";
end;

-- v1.23.0: one run gets one usable handle, so what it learns is kept
local aera_diag_done    = false;
local aera_variant_used = nil;

-- v1.24.0: the command takes the character as an argument, so there is no
-- guarantee which character it lands on (SelectedOrContainedCharacter is
-- whichever one the panel holds).  The answer is read back from every target
-- instead of from the one that was picked.
local function aera_first_wearer(agents, character, key)
	if agents ~= nil then
		for i = 1, #agents do
			local has = false;
			pcall(function()
				has = (agents[i].character:has_ancillary(key) == true);
			end);

			if has then
				return agents[i];
			end;
		end;

		return nil;
	end;

	local has = false;
	pcall(function()
		has = (character:has_ancillary(key) == true);
	end);

	if has then
		return { cqi = "?" };
	end;

	return nil;
end;

local function aera_probe_root_read(root_cco, label, expr)
	if root_cco == nil then
		aera_out("probe: " .. label .. " = <no context>");
		return nil;
	end;

	local res = nil;
	local ok, err = pcall(function()
		res = root_cco:Call(expr);
	end);

	aera_out("probe: " .. label .. " = " .. tostring(res)
		.. " (ok=" .. tostring(ok) .. ", err=" .. tostring(err) .. ")");

	return res;
end;

-- Every spelling of the one command that matters.
--
-- v1.24.0: the docs list global expression names that need no chain at all
-- (see _uidoc.html, "Misc" rows):
--
--   CampaignRoot                    CcoCampaignRoot      "Return the root campaign context in campaign"
--   PlayersFaction                  CcoCampaignFaction   "Return the players faction context"
--   FactionContextFromKey(String)   CcoCampaignFaction   "Returns the faction context for the faction key supplied if it exists"
--   SelectedOrContainedCharacter    CcoCampaignCharacter "Returns either the contained character(agent) if exists, or the selected character if any"
--
-- A global name is not part of a chain, so neither end of the command has to
-- be reached from the other one any more.  SelectedOrContainedCharacter is the
-- character whose panel is open, which is the character the button belongs to.
local function aera_equip_variants(faction_name, key, cqi)
	local pool = "FactionContextFromKey('" .. tostring(faction_name) .. "')"
		.. ".AncillaryList.Filter(AncillaryRecordContext.Key == '" .. tostring(key)
		.. "' && IsContextValid(CharacterEquippedToContext) == false).At(0)";

	return {
		{ name = "FactionContextFromKey + SelectedOrContainedCharacter",
			expr = pool .. ".EquipToCharacter(SelectedOrContainedCharacter)" },
		{ name = "FactionContextFromKey + CharacterList(CQI)",
			expr = pool .. ".EquipToCharacter(CharacterList.Filter(CQI == "
				.. tostring(cqi) .. ").At(0))" },
	};
end;

-- v1.22.0: the chain that does the work, checked step by step before it is
-- used.  One bad name makes a context answer nil for the rest of its life
-- (v1.21.0 lost AncillaryList that way), so the walk stops at the first empty
-- answer and reports where it was.
local function aera_root_chain_ok(root_cco, faction_name, sample_key, cqi)
	local faction = "FactionContextFromKey('" .. tostring(faction_name) .. "')";

	local steps = {
		{ name = "CharacterList.Size", expr = "CharacterList.Size" },
		{ name = "FactionContextFromKey(name).AncillaryList.Size",
			expr = faction .. ".AncillaryList.Size" },
	};

	if sample_key ~= nil then
		steps[#steps + 1] = { name = "pool copy key",
			expr = faction .. ".AncillaryList.Filter(AncillaryRecordContext.Key == '"
				.. tostring(sample_key) .. "').At(0).AncillaryRecordContext.Key" };
	end;

	if cqi ~= nil then
		steps[#steps + 1] = { name = "character by CQI",
			expr = aera_character_expr(cqi) .. ".CQI" };
	end;

	for i = 1, #steps do
		local res = nil;
		local ok, err = pcall(function()
			res = root_cco:Call(steps[i].expr);
		end);

		aera_out("probe: chain " .. tostring(i) .. "/" .. tostring(#steps) .. " "
			.. steps[i].name .. " = " .. tostring(res)
			.. " (ok=" .. tostring(ok) .. ", err=" .. tostring(err) .. ")");

		if res == nil then
			return false, steps[i].name;
		end;
	end;

	return true, nil;
end;

----------------------------------------------------------------------
-- v1.17.0: every read-only check that is worth a question, in one click
----------------------------------------------------------------------
--
-- One game start per round is expensive, so a single click now answers all of
-- the open questions about the ui context at once, in this order:
--
--   1. the plain script interface (always safe)
--   2. AncillaryList by index, without any filter
--   3. the same list through StoreList(), the way fusion uses it
--   4. the Filter() forms, from the simplest to the one that returned nothing
--   5. the character side of the context
--
-- Everything below only reads.  Every line goes into the trace file before the
-- next probe runs, so a context that gives up half way still leaves behind the
-- answers of the probes that came first.

local function aera_probe_read(label, target, expr)
	if target == nil then
		aera_out("probe: " .. label .. " = <no context>");
		return nil;
	end;

	local res = nil;
	local ok, err = pcall(function()
		res = target:Call(expr);
	end);

	aera_out("probe: " .. label .. " = " .. tostring(res)
		.. " (ok=" .. tostring(ok) .. ", err=" .. tostring(err) .. ")");

	return res;
end;

local function aera_probe_everything(faction, faction_cco, sample_key, character)
	aera_out("probe: ------------------ pool ------------------");
	aera_out("probe: context faction " .. tostring(faction:name())
		.. ", local faction " .. tostring(cm:get_local_faction_name()));

	-- 1. plain script interface
	if sample_key ~= nil then
		local owned = nil;
		local exists = nil;
		local can = nil;
		local has = nil;

		pcall(function() owned = faction:num_ancillaries_owned(sample_key); end);
		pcall(function() exists = faction:ancillary_exists(sample_key); end);

		if character ~= nil then
			pcall(function() can = character:can_equip_ancillary(sample_key); end);
			pcall(function() has = character:has_ancillary(sample_key); end);
		end;

		aera_out("probe: script api " .. tostring(sample_key) .. ": owned=" .. tostring(owned)
			.. " exists=" .. tostring(exists) .. " can_equip=" .. tostring(can)
			.. " wears=" .. tostring(has));
	end;

	-- 2. the list by index, no filter at all
	aera_probe_read("AncillaryList.Size", faction_cco, "AncillaryList.Size");
	aera_probe_read("AncillaryList.At(0).key", faction_cco,
		"AncillaryList.At(0).AncillaryRecordContext.Key");
	aera_probe_read("AncillaryList.At(1).key", faction_cco,
		"AncillaryList.At(1).AncillaryRecordContext.Key");
	aera_probe_read("AncillaryList.FirstContext.key", faction_cco,
		"AncillaryList.FirstContext.AncillaryRecordContext.Key");

	-- 3. the filter forms (StoreList was dropped: the second call in a run
	-- comes back empty, and a context never comes back to Lua anyway)
	if sample_key ~= nil then
		aera_probe_read("Filter(key, single quotes).Size", faction_cco,
			"AncillaryList.Filter(AncillaryRecordContext.Key == '" .. sample_key .. "').Size");
		aera_probe_read("Filter(key, double quotes).Size", faction_cco,
			"AncillaryList.Filter(AncillaryRecordContext.Key == \"" .. sample_key .. "\").Size");
		aera_probe_read("Filter(not worn).Size", faction_cco,
			"AncillaryList.Filter(IsContextValid(CharacterEquippedToContext) == false).Size");
		aera_probe_read("Filter(key && not worn).Size", faction_cco,
			"AncillaryList.Filter(AncillaryRecordContext.Key == '" .. sample_key
				.. "' && IsContextValid(CharacterEquippedToContext) == false).Size");
		aera_probe_read("Filter(not worn).At(0).key", faction_cco,
			"AncillaryList.Filter(IsContextValid(CharacterEquippedToContext) == false)"
				.. ".At(0).AncillaryRecordContext.Key");
	end;

	-- 5. the character side is probed last (see aera_probe_character): a name
	-- that does not resolve kills the context for the rest of the session, and
	-- the equipping below needs the context to stay alive
	aera_out("probe: ------------------ pool end ------------------");
end;

-- Read-only look at how a character context can be built from Lua at all.
-- Called only when the root chain is already dead, so nothing can be lost by
-- it.  The vanilla scripts build one with a *string* command queue index
-- (wh3_dlc26_tyrants_demands.lua:66 cco("CcoCampaignCharacter", cqi), where
-- the cqi comes out of a button name and is a string), so both forms are tried.
local function aera_probe_character(cqi)
	aera_out("probe: ---------------- character ----------------");

	if cqi == nil then
		aera_out("probe: no cqi to try");
		return;
	end;

	local ok_text, char_text = pcall(function()
		return cco("CcoCampaignCharacter", tostring(cqi));
	end);

	aera_out("probe: cco('CcoCampaignCharacter', '" .. tostring(cqi) .. "') -> "
		.. tostring(char_text) .. " (ok=" .. tostring(ok_text) .. ")");

	if ok_text and char_text ~= nil then
		aera_probe_read("  string id .CQI", char_text, "CQI");
		aera_probe_read("  string id .AncillaryList.Size", char_text, "AncillaryList.Size");
		aera_probe_read("  string id .FactionContext.FactionRecordContext.Key", char_text,
			"FactionContext.FactionRecordContext.Key");
	end;

	aera_out("probe: -------------- character end --------------");
end;

-- v1.26.0: the argument list was wrong all along.
--
-- CcoCampaignAncillary.EquipToCharacter is documented as
--
--      EquipToCharacter | Void | CcoCampaignCharacter, CcoCampaignAncillary
--      "Equips itself to the specified character, and swaps with the
--       ancillary passed in if this exists."
--
-- and the vanilla character details panel calls it with both arguments:
--
--      .SelectedObjectList.FirstContext.EquipToCharacter(
--          SelectedOrContainedCharacter, StoredContext("CcoCampaignAncillary"))
--
-- Every attempt up to v1.25.0 passed the character only, so the swap argument
-- never resolved - and an expression that does not resolve is exactly what
-- silences the whole evaluator (and MCT with it).  The call below is the
-- vanilla call with the swap set to the item itself; swapping an item with
-- itself changes nothing.
--
-- It is issued on the root context on purpose: CcoCampaignFaction documents
-- CharacterList, but on this build it resolves to nil there.  Only the root
-- context really has it (1380 characters in the save used for testing).
local function aera_equip_now(faction, character, key)
	local cqi = nil;
	pcall(function()
		cqi = character:command_queue_index();
	end);

	if cqi == nil then
		return false, "the character has no command queue index";
	end;

	local already = false;
	pcall(function()
		already = (character:has_ancillary(key) == true);
	end);

	if already then
		return false, "the character already wears it";
	end;

	local owned_before = aera_owned(faction, key);

	-- exactly one copy is moved; a key the faction holds more than once is left
	-- alone, because the removal would take all of them
	if owned_before ~= 1 then
		return false, "the faction owns " .. tostring(owned_before) .. " of it, not 1";
	end;

	local faction_key = nil;
	pcall(function()
		faction_key = faction:name();
	end);

	if faction_key == nil then
		return false, "the faction has no name";
	end;

	-- the pool copy, addressed from the root context
	local anc_expr = "FactionList.Filter(FactionRecordContext.Key == '"
		.. faction_key .. "').At(0).AncillaryList.Filter(AncillaryRecordContext.Key == '"
		.. key .. "' && IsContextValid(CharacterEquippedToContext) == false).At(0)";

	local expr = anc_expr .. ".EquipToCharacter(CharacterList.Filter(CQI == "
		.. tostring(cqi) .. ").At(0), " .. anc_expr .. ")";

	aera_out("  call: " .. expr);

	local ok_call, err_call = pcall(function()
		local root = cco("CcoCampaignRoot", "");

		if root == nil then
			error("the root context could not be built");
		end;

		root:Call(expr);
	end);

	local wore = false;
	pcall(function()
		wore = (character:has_ancillary(key) == true);
	end);

	local owned_after = aera_owned(faction, key);

	aera_out("  call -> ok=" .. tostring(ok_call) .. " err=" .. tostring(err_call)
		.. " owned " .. tostring(owned_before) .. "->" .. tostring(owned_after)
		.. " wears=" .. tostring(wore));

	if wore then
		return true, "EquipToCharacter took the copy out of the pool";
	end;

	-- the copy left the pool without reaching the character: hand it back
	if owned_after == 0 then
		local ok_back, err_back = pcall(function()
			cm:add_ancillary_to_faction(faction, key, true);
		end);

		aera_out("  given back to the pool -> ok=" .. tostring(ok_back)
			.. " err=" .. tostring(err_back) .. " owned=" .. tostring(aera_owned(faction, key)));

		return false, "the equip did not take, the copy is back in the pool";
	end;

	return false, "the equip did not take (owned=" .. tostring(owned_after) .. ")";
end;

-- Is the context evaluator still answering?  One expression that does not
-- resolve silences it for the rest of the session (MCT included), so a run
-- that notices it stops instead of hammering it with the rest of the list.
local function aera_root_alive()
	local alive = nil;

	pcall(function()
		local root = cco("CcoCampaignRoot", "");

		if root ~= nil then
			alive = root:Call("FactionList.Size");
		end;
	end);

	return alive;
end;

----------------------------------------------------------------------
-- the actual one-click action
----------------------------------------------------------------------

local aera_running = false;

-- v1.14.0: the run starts straight from the button again.  The equip no longer
-- touches a cm: command, it goes through the same ui contexts the panel uses,
-- so the panel being open is no longer a problem.

-- (v1.3.x also wrote the result into the button label.  That call touched a
-- UI component from the campaign tick, which is not a safe thread to do it
-- on, so it is gone - the trace file carries the result instead.)

-- force  = the caller already decided this run is allowed (per turn auto
--          equip), so the "button is disabled" option is not consulted.
-- silent = keep quiet unless something was actually changed.
local function aera_run(force, silent)
	if aera_running then
		return;
	end;

	aera_debug_enabled = aera_mct_get(AERA_MCT_OPTION_DEBUG, false) == true;
	aera_agent_ranged_cache = {};

	local function note(msg)
		if silent then
			aera_debug(msg);
		else
			aera_out(msg);
		end;
	end;

	if not force and not aera_mct_get(AERA_MCT_OPTION_ENABLED, true) then
		aera_out("the button is disabled in the mod configuration");
		return;
	end;

	if aera_is_multiplayer() then
		aera_out("skipped: changing equipment would desync a multiplayer campaign");
		return;
	end;

	local faction = cm:get_local_faction();
	if not aera_is_valid_interface(faction) or not aera_is_local_faction(faction) then
		note("skipped: no local faction");
		return;
	end;

	aera_running = true;
	aera_debug("=== run start ===");

	-- Fail-safe: if a native exception ever takes the campaign thread down in
	-- the middle of this function, the guard below would stay stuck and every
	-- later click would silently do nothing.  A scheduled callback still runs
	-- in that case and clears it again.
	cm:callback(function()
		aera_running = false;
	end, 30);

	local ok, err = pcall(function()
		local include_lords = aera_mct_get(AERA_MCT_OPTION_LORDS, false) == true;
		local avoid_ranged = aera_mct_get(AERA_MCT_OPTION_RANGED, true) == true;

		-- MCT lost its settings once already (the panel could not open for a
		-- while), so the effective configuration is always logged
		aera_out("mct: enabled=" .. tostring(aera_mct_get(AERA_MCT_OPTION_ENABLED, true))
			.. " include_lords=" .. tostring(include_lords)
			.. " avoid_ranged=" .. tostring(avoid_ranged)
			.. " auto_turn=" .. tostring(aera_mct_get(AERA_MCT_OPTION_AUTO_TURN, false))
			.. " debug=" .. tostring(aera_debug_enabled));

		aera_debug("phase 1/4: collecting target agents");
		local agents = aera_collect_agents(faction, include_lords);

		aera_debug("phase 2/4: ancillary database");

		-- The database is built once, at the first tick, from CcoCampaignRoot.
		-- A run deliberately does NOT build it: evaluating a CCO expression
		-- right before a cm: write is exactly the combination that crashed.
		if AERA_DB_STATE ~= "ready" then
			aera_out("the ancillary database is not ready yet, click again in a moment");
			return;
		end;

		if AERA_DB_ITEMS == nil then
			aera_out("could not read the ancillary database");
			return;
		end;

		aera_debug("phase 3/4: scanning the pool (owned - worn = idle)");

		local items = aera_collect_idle(faction);
		if #items == 0 then
			note("no idle ancillaries of the wanted rarity (common/uncommon/rare) in the pool");
			return;
		end;

		aera_debug("phase 4/4: equipping");

		-- What every target already wears, counted with has_ancillary() on the
		-- candidate keys only.  This stays on the script interface on purpose:
		-- it is the cheap, always-works read, and the category slots below
		-- depend on it.
		for j = 1, #agents do
			local agent = agents[j];
			agent.worn = {};

			for i = 1, #items do
				local ok_has, has = pcall(function()
					return agent.character:has_ancillary(items[i].key);
				end);

				if ok_has and has == true then
					aera_mark_worn(agent.worn, items[i].category);
				end;
			end;

			local parts = "";
			for category, n in pairs(agent.worn) do
				parts = parts .. " " .. tostring(category) .. "=" .. tostring(n);
			end;

			aera_debug("cqi " .. tostring(agent.cqi) .. " wears (pool keys only):"
				.. ((parts ~= "") and parts or " nothing"));
		end;

		local equipped_count = 0;
		local failed_count = 0;
		local skipped_ranged = 0;
		local skipped_full = 0;

		-- v1.25.0: the run touches no ui context at all.  Every CCO call that
		-- did not resolve left the whole evaluator answering nil for the rest of
		-- the session, which is what killed the MCT panel after a click, so the
		-- equipment is handled with cm: commands only.
		local faction_name = faction:name();

		if #agents == 0 then
			note("no immortal " .. (include_lords and "characters" or "agents")
				.. " of the local faction - nothing to do");
			return;
		end;

		local evaluator_dead = false;

		for i = 1, #items do
			local item = items[i];

			aera_debug("item " .. tostring(i) .. "/" .. tostring(#items) .. ": " .. item.key
				.. " (" .. tostring(item.category) .. ", idle " .. tostring(item.idle) .. ")");

			-- one item per pcall: a single bad item must not take the rest of
			-- the run (or the campaign thread) with it
			local ok_item, err_item = pcall(function()
				local target = nil;
				local blocked_by_slots = 0;

				-- classified here and not during the scan, so that the scan
				-- always finishes and the list is complete
				local item_ranged = aera_item_is_ranged(item.key);

				for j = 1, #agents do
					local agent = agents[j];

					local ranged_ok = true;
					if avoid_ranged and item_ranged then
						local agent_ranged = aera_agent_is_ranged(agent.cqi);
						-- nil = unknown => fail open, the item is used
						ranged_ok = (agent_ranged ~= false);
					end;

					if ranged_ok and aera_can_equip(agent.character, item.key) then
						if aera_has_free_slot(agent, item, agent.worn) then
							target = agent;
							break;
						end;

						-- the category is allowed but the slot is taken:
						-- that is "no room", never a reason to replace
						blocked_by_slots = blocked_by_slots + 1;
					end;
				end;

				if target == nil then
					if blocked_by_slots > 0 then
						skipped_full = skipped_full + 1;
						aera_debug("no free slot for " .. item.key
							.. ": the candidates already wear a "
							.. tostring(item.category) .. " item");
					elseif item_ranged and avoid_ranged then
						skipped_ranged = skipped_ranged + 1;
						aera_debug("no (ranged) target for " .. item.key);
					else
						aera_debug("no suitable carrier for " .. item.key);
					end;
				else
					local done, reason = aera_equip_now(faction, target.character, item.key);

					if done then
						equipped_count = equipped_count + 1;
						aera_mark_worn(target.worn, item.category);
						item.idle = item.idle - 1;
						aera_debug("cqi " .. tostring(target.cqi) .. " <- " .. item.key
							.. " (" .. tostring(reason) .. ")");
					else
						failed_count = failed_count + 1;
						aera_out("could not equip " .. item.key
							.. " on cqi " .. tostring(target.cqi) .. ": " .. tostring(reason));
					end;
				end;
			end);

			if not ok_item then
				aera_out("item " .. tostring(item.key) .. " aborted: " .. tostring(err_item));
			end;

			-- v1.26.0: once the evaluator is silent every further call is a
			-- no-op, so the run ends here and says how much was left alone
			if aera_root_alive() == nil then
				evaluator_dead = true;
			end;

			if evaluator_dead then
				aera_out("the context evaluator stopped answering - the remaining "
					.. tostring(#items - i) .. " item(s) stay in the pool");
				break;
			end;
		end;

		if equipped_count == 0 and failed_count == 0 then
			note("nothing equipped (" .. tostring(#items) .. " idle item(s) of the wanted rarity, "
				.. tostring(skipped_full) .. " kept back for lack of a free slot, "
				.. tostring(skipped_ranged) .. " ranged)");
		else
			aera_out("done: " .. tostring(equipped_count) .. " equipped, "
				.. tostring(failed_count) .. " failed, "
				.. tostring(skipped_ranged) .. " ranged item(s) kept away from melee agents, "
				.. tostring(skipped_full) .. " kept back for lack of a free slot"
				.. " (" .. tostring(#items) .. " idle item(s) of the wanted rarity, "
				.. tostring(#agents) .. " target(s))");
		end;

		-- v1.22.0: a last read of the pool through a fresh handle, so the log
		-- always says whether the pool changed, whatever the run decided
		aera_probe_context("end");
	end);

	aera_running = false;

	if not ok then
		aera_out("error while equipping: " .. tostring(err));
	end;

	aera_debug("run finished");
end;

----------------------------------------------------------------------
-- v1.28.0-test: working remove-then-add path
----------------------------------------------------------------------
-- The v1.27 experiment proved on this build that:
--   * cm:force_remove_ancillary_from_faction() on an idle pool item is safe
--     when it is called from a campaign tick (not from the click callback);
--   * once the model has processed the removal (0.5s later), the faction
--     owns 0 of the key, and
--   * cm:force_add_ancillary(character, key, true, true) then really equips
--     the item (has_ancillary == true, owned == 1).
--
-- The same experiment also exposed the old free-slot bug: it counted only
-- the keys that were idle in the pool, so a character wearing one of those
-- items looked like it had an empty slot and the next item replaced the
-- previous one.
--
-- This version keeps the remove/add sequence and counts the character's
-- worn items over AERA_ALL_KEYS_BY_CATEGORY (every key of that category,
-- not only the pool keys), so a filled slot is never reused.
--
-- One item is processed per 1.5s.  Nothing here calls CCO.

local aera_equip_running = false;
local aera_equip_queue = nil;
local aera_equip_agents = nil;
local aera_equip_faction = nil;
local aera_equip_worn_cache = nil;
local aera_equip_done = 0;
local aera_equip_failed = 0;
local aera_equip_skipped = 0;
local aera_equip_next;   -- forward declaration

local function aera_equip_character_ok(character)
	if character == nil then
		return false;
	end;

	local ok, is_null = pcall(function()
		return character:is_null_interface();
	end);

	if ok then
		return is_null == false;
	end;

	-- some interfaces do not expose is_null_interface; treat them as usable
	return true;
end;

local function aera_equip_category_keys(category)
	-- the owned index is built by collect_idle() at the start of every run;
	-- a character cannot wear a key the faction does not own
	if AERA_OWNED_KEYS_BY_CATEGORY ~= nil then
		return AERA_OWNED_KEYS_BY_CATEGORY[category] or {};
	end;

	if AERA_ALL_KEYS_BY_CATEGORY ~= nil then
		local keys = AERA_ALL_KEYS_BY_CATEGORY[category];
		if keys ~= nil and #keys > 0 then
			return keys;
		end;
	end;

	-- fallback for a build where the all-category pass was not available
	local keys = {};
	if AERA_DB_ITEMS ~= nil then
		for key, meta in pairs(AERA_DB_ITEMS) do
			if meta.category == category then
				keys[#keys + 1] = key;
			end;
		end;
	end;

	return keys;
end;

local function aera_equip_worn_count(agent, category)
	if category == nil then
		-- cannot tell which slot this item belongs to: treat every slot as
		-- full rather than risk replacing something
		return 99;
	end;

	local cache_key = tostring(agent.cqi) .. "|" .. tostring(category);
	local cached = aera_equip_worn_cache[cache_key];
	if cached ~= nil then
		return cached;
	end;

	local keys = aera_equip_category_keys(category);
	local count = 0;

	for i = 1, #keys do
		local ok, has = pcall(function()
			return agent.character:has_ancillary(keys[i]);
		end);

		if ok and has == true then
			count = count + 1;
		end;
	end;

	aera_equip_worn_cache[cache_key] = count;
	return count;
end;

local function aera_equip_bump_worn(agent, category)
	local cache_key = tostring(agent.cqi) .. "|" .. tostring(category);
	aera_equip_worn_cache[cache_key] = (aera_equip_worn_cache[cache_key] or 0) + 1;
end;

local function aera_equip_any_target_wears(key, agents)
	agents = agents or aera_equip_agents;

	for j = 1, #agents do
		local agent = agents[j];
		local character = nil;

		pcall(function()
			character = cm:get_character_by_cqi(agent.cqi);
		end);

		if not aera_equip_character_ok(character) then
			character = agent.character;
		end;

		if aera_equip_character_ok(character) then
			local ok_has, has = pcall(function()
				return character:has_ancillary(key);
			end);

			if ok_has and has == true then
				return true;
			end;
		end;
	end;

	return false;
end;

-- Is this key worn by ANY character of the faction?  Used immediately
-- before the remove: a duplicate key may only be removed as a whole when
-- every copy is still idle, and even a single-copy key must not be pulled
-- off a character.
-- Returns true / false, or nil when the character list cannot be read.
local function aera_equip_worn_anywhere(key)
	local list = nil;
	pcall(function()
		list = aera_equip_faction:character_list();
	end);

	if not aera_is_valid_interface(list) then
		return nil;
	end;

	local n = 0;
	pcall(function()
		n = list:num_items();
	end);

	for i = 0, n - 1 do
		local character = list:item_at(i);

		if aera_is_valid_interface(character) then
			local ok_has, has = pcall(function()
				return character:has_ancillary(key);
			end);

			if ok_has and has == true then
				return true;
			end;
		end;
	end;

	return false;
end;

local function aera_equip_pick_target(item)
	if item.category == nil then
		return nil;
	end;

	for j = 1, #aera_equip_agents do
		local agent = aera_equip_agents[j];

		local ok_has, has = pcall(function()
			return agent.character:has_ancillary(item.key);
		end);

		if not (ok_has and has == true) and aera_can_equip(agent.character, item.key) then
			local used = aera_equip_worn_count(agent, item.category);
			if used < aera_slot_count(item.category) then
				return agent;
			end;
		end;
	end;

	return nil;
end;

-- Put copies back until the faction owns `target_owned` of the key.  Used
-- after a duplicate key was removed as a whole: the character has taken one
-- copy, and the other N-1 copies have to be restored to the pool.
local function aera_equip_refill(key, target_owned)
	target_owned = tonumber(target_owned) or 1;

	local current = aera_owned(aera_equip_faction, key);
	if current == nil then
		aera_out("EQUIP refill " .. key .. " aborted: cannot read the owned count");
		return;
	end;

	if current >= target_owned then
		aera_out("EQUIP refill " .. key .. ": already " .. tostring(current)
			.. "/" .. tostring(target_owned));
		return;
	end;

	local to_add = target_owned - current;
	aera_out("EQUIP refill " .. key .. ": " .. tostring(to_add)
		.. " copy(ies) back, currently " .. tostring(current));

	for i = 1, to_add do
		local ok, err = pcall(function()
			cm:add_ancillary_to_faction(aera_equip_faction, key, true);
		end);

		current = aera_owned(aera_equip_faction, key);

		if not ok or current == nil then
			aera_out("EQUIP refill " .. key .. " failed after " .. tostring(i)
				.. ": ok=" .. tostring(ok) .. " err=" .. tostring(err)
				.. " owned=" .. tostring(current));
			return;
		end;

		if current >= target_owned then
			break;
		end;
	end;

	aera_out("EQUIP refill " .. key .. " -> owned="
		.. tostring(aera_owned(aera_equip_faction, key))
		.. "/" .. tostring(target_owned));
end;

local function aera_equip_finish()
	aera_out("EQUIP finished: " .. tostring(aera_equip_done) .. " equipped, "
		.. tostring(aera_equip_failed) .. " failed, "
		.. tostring(aera_equip_skipped) .. " left in the pool");

	aera_equip_running = false;
	aera_equip_queue = nil;
	aera_equip_agents = nil;
	aera_equip_faction = nil;
	aera_equip_worn_cache = nil;
	AERA_OWNED_KEYS_BY_CATEGORY = nil;
	AERA_OWNED_COUNT = nil;
end;

local function aera_equip_add(item, agent, attempt)
	local key = item.key;
	local target_owned = tonumber(item.owned) or 1;
	local owned = aera_owned(aera_equip_faction, key);

	if owned ~= 0 then
		if attempt < 5 then
			aera_out("EQUIP add wait " .. tostring(attempt)
				.. ": owned=" .. tostring(owned) .. " of " .. key);
			cm:callback(function()
				aera_equip_add(item, agent, attempt + 1);
			end, 0.5);
		else
			aera_out("EQUIP add aborted: the faction still owns "
				.. tostring(owned) .. " of " .. key
				.. ", restoring the missing copy(ies)");
			aera_equip_refill(key, target_owned);
			aera_equip_skipped = aera_equip_skipped + 1;
			aera_equip_next();
		end;
		return;
	end;

	-- the target might have received something while we waited
	local used = aera_equip_worn_count(agent, item.category);
	if used >= aera_slot_count(item.category) then
		aera_out("EQUIP slot filled while waiting for " .. key
			.. ", restoring " .. tostring(target_owned) .. " copy(ies)");
		aera_equip_refill(key, target_owned);
		aera_equip_skipped = aera_equip_skipped + 1;
		aera_equip_next();
		return;
	end;

	local character = nil;
	pcall(function()
		character = cm:get_character_by_cqi(agent.cqi);
	end);

	if not aera_equip_character_ok(character) then
		character = agent.character;
	end;

	if not aera_equip_character_ok(character) then
		aera_out("EQUIP add aborted: no valid character interface for cqi "
			.. tostring(agent.cqi));
		aera_equip_refill(key, target_owned);
		aera_equip_failed = aera_equip_failed + 1;
		aera_equip_next();
		return;
	end;

	aera_out("EQUIP add cqi " .. tostring(agent.cqi) .. ": " .. key
		.. " (attempt " .. tostring(attempt)
		.. ", target-owned=" .. tostring(target_owned) .. ")");

	local ok, err = pcall(function()
		cm:force_add_ancillary(character, key, true, true);
	end);

	local wears = false;
	pcall(function()
		wears = (character:has_ancillary(key) == true);
	end);

	local owned_after = aera_owned(aera_equip_faction, key);

	aera_out("EQUIP add -> ok=" .. tostring(ok)
		.. " err=" .. tostring(err)
		.. " wears=" .. tostring(wears)
		.. " owned=" .. tostring(owned_after));

	if wears then
		aera_equip_done = aera_equip_done + 1;
		aera_equip_bump_worn(agent, item.category);

		if target_owned > 1 then
			aera_equip_refill(key, target_owned);
		end;
	else
		aera_equip_failed = aera_equip_failed + 1;

		-- keep the total count intact even if the copy landed in the
		-- character's inventory but was not equipped
		if owned_after == nil or owned_after < target_owned then
			aera_equip_refill(key, target_owned);
		end;
	end;

	cm:callback(function()
		aera_equip_next();
	end, 0.5);
end;

local function aera_equip_remove(item, agent)
	local key = item.key;
	local expected = tonumber(item.owned) or 1;
	local before = aera_owned(aera_equip_faction, key);

	if before ~= expected then
		aera_out("EQUIP skip " .. key .. ": owned changed from expected "
			.. tostring(expected) .. " to " .. tostring(before));
		aera_equip_skipped = aera_equip_skipped + 1;
		aera_equip_next();
		return;
	end;

	local worn = aera_equip_worn_anywhere(key);
	if worn ~= false then
		aera_out("EQUIP skip " .. key
			.. ": worn by a character (or could not verify), not removing it");
		aera_equip_skipped = aera_equip_skipped + 1;
		aera_equip_next();
		return;
	end;

	if expected > 1 then
		aera_out("EQUIP remove " .. key .. " from the pool (owned="
			.. tostring(before) .. ", moving one, returning "
			.. tostring(before - 1) .. ", target cqi "
			.. tostring(agent.cqi) .. ")");
	else
		aera_out("EQUIP remove " .. key .. " from the pool (target cqi "
			.. tostring(agent.cqi) .. ")");
	end;

	local ok, err = pcall(function()
		cm:force_remove_ancillary_from_faction(aera_equip_faction, key);
	end);

	aera_out("EQUIP remove -> ok=" .. tostring(ok)
		.. " err=" .. tostring(err)
		.. " owned=" .. tostring(aera_owned(aera_equip_faction, key)));

	cm:callback(function()
		aera_equip_add(item, agent, 1);
	end, 0.5);
end;

aera_equip_next = function()
	if aera_equip_queue == nil then
		return;
	end;

	local item = table.remove(aera_equip_queue, 1);
	if item == nil then
		aera_equip_finish();
		return;
	end;

	aera_out("EQUIP item " .. item.key .. " (" .. tostring(item.category)
		.. ", idle " .. tostring(item.idle) .. ")");

	local target = aera_equip_pick_target(item);
	if target == nil then
		aera_out("EQUIP no free target for " .. item.key .. ", leaving it in the pool");
		aera_equip_skipped = aera_equip_skipped + 1;
		cm:callback(function()
			aera_equip_next();
		end, 0);
		return;
	end;

	aera_equip_remove(item, target);
end;

local function aera_equip_all(retried_lords)
	-- Refresh the MCT debug switch before anything can log.
	aera_debug_enabled = aera_mct_get(AERA_MCT_OPTION_DEBUG, false) == true;

	if aera_equip_running then
		aera_out("EQUIP ignored: a run is already in progress");
		return;
	end;

	local faction = cm:get_local_faction();
	if not aera_is_valid_interface(faction) or not aera_is_local_faction(faction) then
		aera_out("EQUIP aborted: no local faction");
		return;
	end;

	if AERA_DB_ITEMS == nil then
		aera_out("EQUIP aborted: the ancillary database is not ready");
		return;
	end;

	local include_lords = aera_mct_get(AERA_MCT_OPTION_LORDS, false) == true;
	local scan_started = os.clock();
	local agents = aera_collect_agents(faction, include_lords);

	if #agents == 0 and not include_lords and not retried_lords then
		-- MCT may still be applying the saved profile on the first click
		aera_out("EQUIP no targets with lords excluded, retrying once in case MCT is still loading");
		cm:callback(function()
			if aera_mct_get(AERA_MCT_OPTION_LORDS, false) == true then
				aera_equip_all(true);
			else
				aera_out("EQUIP no targets: lords are excluded in the configuration");
			end;
		end, 0.5);
		return;
	end;

	if #agents == 0 then
		aera_out("EQUIP aborted: no immortal target");
		return;
	end;

	local items = aera_collect_idle(faction);
	local queue = {};
	local duplicates_queued = 0;
	local worn_skipped = 0;
	local partial_skipped = 0;
	local too_many_skipped = 0;
	local duplicate_examples = {};
	local partial_examples = {};
	local worn_examples = {};

	for i = 1, #items do
		local item = items[i];
		local owned = aera_owned(faction, item.key);

		if owned == nil or owned <= 0 then
			-- the item disappeared between the scan and the queue build
		elseif aera_equip_any_target_wears(item.key, agents) then
			worn_skipped = worn_skipped + 1;
			if #worn_examples < 8 then
				worn_examples[#worn_examples + 1] = item.key;
			end;
		elseif owned == 1 then
			queue[#queue + 1] = item;
		else
			-- duplicate key.  force_remove_ancillary_from_faction takes
			-- every copy, so this is only safe when every copy was idle:
			-- remove all, equip one, put the other copies back.
			local worn = (owned - (item.idle or 0));

			if worn > 0 or item.idle ~= owned then
				partial_skipped = partial_skipped + 1;
				if #partial_examples < 8 then
					partial_examples[#partial_examples + 1] =
						item.key .. "(owned=" .. tostring(owned)
						.. ", idle=" .. tostring(item.idle) .. ")";
				end;
			elseif owned > AERA_MAX_DUPLICATES then
				too_many_skipped = too_many_skipped + 1;
				if #duplicate_examples < 8 then
					duplicate_examples[#duplicate_examples + 1] =
						item.key .. "(owned=" .. tostring(owned) .. ")";
				end;
			else
				item.owned = owned;
				queue[#queue + 1] = item;
				duplicates_queued = duplicates_queued + 1;
			end;
		end;
	end;

	-- keys the faction owns but the mod's droppable cache does not contain
	-- (crafted / non-randomly-dropped / legendary): these can never be
	-- queued, so say so instead of silently ignoring them
	local not_droppable = 0;
	local not_droppable_examples = {};
	if AERA_OWNED_COUNT ~= nil then
		for key in pairs(AERA_OWNED_COUNT) do
			if AERA_DB_ITEMS[key] == nil then
				not_droppable = not_droppable + 1;
				if #not_droppable_examples < 8 then
					not_droppable_examples[#not_droppable_examples + 1] = key;
				end;
			end;
		end;
	end;

	aera_out("EQUIP scan: " .. tostring(#agents) .. " target(s), "
		.. tostring(#queue) .. " item(s), idle=" .. tostring(#items)
		.. ", dup-queued=" .. tostring(duplicates_queued)
		.. ", partial=" .. tostring(partial_skipped)
		.. ", too-many=" .. tostring(too_many_skipped)
		.. ", target-worn=" .. tostring(worn_skipped)
		.. ", not-droppable=" .. tostring(not_droppable)
		.. ", " .. string.format("%.1f", (os.clock() - scan_started) * 1000) .. " ms");

	if #worn_examples > 0 then
		aera_out("EQUIP target-worn keys: " .. table.concat(worn_examples, ", "));
	end;
	if #partial_examples > 0 then
		aera_out("EQUIP duplicate keys with a worn copy: "
			.. table.concat(partial_examples, ", "));
	end;
	if #duplicate_examples > 0 then
		aera_out("EQUIP duplicate keys over the cap: "
			.. table.concat(duplicate_examples, ", "));
	end;
	if #not_droppable_examples > 0 then
		aera_out("EQUIP owned keys outside the droppable cache: "
			.. table.concat(not_droppable_examples, ", "));
	end;

	if #queue == 0 then
		aera_out("EQUIP aborted: no eligible item");
		return;
	end;

	aera_equip_running = true;
	aera_equip_faction = faction;
	aera_equip_agents = agents;
	aera_equip_queue = queue;
	aera_equip_worn_cache = {};
	aera_equip_done = 0;
	aera_equip_failed = 0;
	aera_equip_skipped = 0;

	-- safety: if a callback is lost (save/load, panel teardown, ...), the
	-- guard must not block every later click forever
	cm:callback(function()
		if aera_equip_running then
			aera_out("EQUIP watchdog: the run did not finish in 120s, clearing the guard");
			aera_equip_running = false;
			aera_equip_queue = nil;
			aera_equip_agents = nil;
			aera_equip_faction = nil;
			aera_equip_worn_cache = nil;
			AERA_OWNED_KEYS_BY_CATEGORY = nil;
			AERA_OWNED_COUNT = nil;
		end;
	end, 120);

	aera_out("EQUIP start: " .. tostring(#queue) .. " item(s), "
		.. tostring(#agents) .. " target(s), include_lords="
		.. tostring(include_lords));

	aera_equip_next();
end;

----------------------------------------------------------------------
-- UI: build the button at runtime (Fusion Wizard style, no xml override)
----------------------------------------------------------------------

local AERA_BUTTON_NAME        = "aera_equip_rare_button";
local AERA_PANEL_NAME         = "character_details_panel";
-- button added by the "Fusion Wizard" mod, used to stack above it
local AERA_FUSION_BUTTON_NAME = "item_fusion_assistant_button";

local AERA_BUTTON_TEXT    = "一键装备蓝及以下装备";
local AERA_BUTTON_TOOLTIP =
	"把所有空闲的白色/绿色/蓝色装备（即蓝色及以下，不含紫色独特装备），" ..
	"自动装备到已拥有「长生久视」的事务官身上。" ..
	"远程类装备不会装备到近战事务官，避免浪费。";

-- Vertical gap between two stacked buttons, in pixels.  The vanilla row
-- pitch is 38px (a 34px button plus 4px), so anything above 4 keeps this
-- button clearly separated from the one below it.
local AERA_STACK_GAP = 6;
-- Fallback height, used only if the template reports a silly value.
local AERA_BUTTON_HEIGHT_FALLBACK = 34;

-- per panel-open bookkeeping, reset whenever the panel is opened / closed
local aera_layout_state = {
	list_base_height = nil,
	list_reserved    = 0,
};

local function aera_reset_layout_state()
	aera_layout_state.list_base_height = nil;
	aera_layout_state.list_reserved = 0;
end;

-- The equipment pool lives somewhere under the character details panel and
-- only exists while that panel is open.  find_uicomponent() walks the tree
-- recursively, so the exact depth does not matter.  The path used by the
-- "Fusion Wizard" mod is tried first because it is known to work, the
-- panel-scoped one is kept as a fallback.
local function aera_find_pool()
	local pool = find_uicomponent(
		core:get_ui_root(), "equipment_holder", "global_pool"
	);

	if is_uicomponent(pool) then
		return pool;
	end;

	pool = find_uicomponent(
		core:get_ui_root(), AERA_PANEL_NAME, "equipment_holder", "global_pool"
	);

	if is_uicomponent(pool) then
		return pool;
	end;

	return nil;
end;

local function aera_layout_button(create)
	local pool = aera_find_pool();
	if pool == nil then
		aera_out("equipment_holder / global_pool not found, the character "
			.. "details panel is probably not open");
		return nil;
	end;

	local holder = find_uicomponent(pool, "fusing_salvaging_buttons_holder");
	if not is_uicomponent(holder) then
		aera_out("fusing_salvaging_buttons_holder not found in the equipment pool");
		return nil;
	end;

	local button = find_uicomponent(pool, AERA_BUTTON_NAME);
	if not is_uicomponent(button) then
		if not create then
			return nil;
		end;

		button = UIComponent(pool:CreateComponent(
			AERA_BUTTON_NAME, "ui/templates/square_large_text_button"
		));

		if not is_uicomponent(button) then
			aera_out("could not create the equip button");
			return nil;
		end;

		button:SetCanResizeWidth(true);
		button:SetTooltipText(AERA_BUTTON_TOOLTIP, true);

		local label = find_uicomponent(button, "button_txt");
		if is_uicomponent(label) then
			label:SetStateText(AERA_BUTTON_TEXT);
		end;
	end;

	-- Stack above the vanilla fusing / salvaging row and, when present,
	-- above the "Fusion Wizard" button so both stay clickable.
	--
	-- The step is derived from the button's real height plus a small gap
	-- instead of a hard coded 28: with a 34px button the vanilla row pitch
	-- is 38, so a fixed 28 made the two buttons overlap.
	local button_h = button:Height();
	if type(button_h) ~= "number" or button_h < 20 then
		button_h = AERA_BUTTON_HEIGHT_FALLBACK;
	end;

	local step = button_h + AERA_STACK_GAP;

	local holder_x, holder_y = holder:Position();
	local top_y = holder_y - 28;   -- the offset Fusion Wizard uses

	local fusion_button = find_uicomponent(pool, AERA_FUSION_BUTTON_NAME);
	if is_uicomponent(fusion_button) then
		local _, fusion_y = fusion_button:Position();
		top_y = fusion_y - step;   -- one full row above it
	end;

	button:Resize(holder:Width(), button_h);
	button:MoveTo(holder_x, top_y);
	button:SetVisible(true);

	-- Make room for the extra row(s) so the items list does not overflow
	-- into the buttons.  The vanilla height is remembered once per panel.
	local list = find_uicomponent(pool, "global_ancillaries_listview");
	if is_uicomponent(list) then
		if aera_layout_state.list_base_height == nil then
			aera_layout_state.list_base_height = list:Height();
		end;

		-- Only OUR row has to be paid for here: Fusion Wizard already
		-- shrinks the list by 38 for its own button, so reserving two
		-- rows would leave a pointless gap at the bottom.
		local reserved = step;
		if aera_layout_state.list_reserved ~= reserved then
			local new_height = aera_layout_state.list_base_height - reserved;

			-- never squeeze the item list into nothing
			if new_height > 60 then
				list:SetCanResizeHeight(true);
				list:Resize(list:Width(), new_height);
				aera_layout_state.list_reserved = reserved;
			end;
		end;
	end;

	return button;
end;

local function aera_on_panel_opened()
	aera_debug_enabled = aera_mct_get(AERA_MCT_OPTION_DEBUG, false) == true;
	aera_reset_layout_state();

	-- second chance for the database: it is normally built at the first
	-- tick, but a reload or a very early click may have missed it.  This runs
	-- on the UI thread, a long way away from any cm: write.
	if AERA_DB_STATE ~= "ready" then
		aera_db_load();
	end;

	if not aera_mct_get(AERA_MCT_OPTION_ENABLED, false) then
		aera_out("the button is hidden in the mod configuration");
		return;
	end;

	-- The panel is not always fully built when the event fires, and the
	-- "Fusion Wizard" mod may create its own button a moment later, so the
	-- layout is repeated a couple of times.  aera_layout_button() only
	-- creates the component when it is missing, and the list resize is
	-- idempotent, so repeating it is harmless.
	aera_layout_button(true);

	cm:real_callback(function()
		aera_layout_button(true);
	end, 0.3);

	cm:real_callback(function()
		aera_layout_button(true);
	end, 0.8);
end;

----------------------------------------------------------------------
-- entry point - called on the first campaign tick.
-- NOTE: name MUST equal the (lower-cased) file name, all lower case.
----------------------------------------------------------------------

function auto_equip_rare_ancillaries()
	aera_debug_enabled = aera_mct_get(AERA_MCT_OPTION_DEBUG, false) == true;

	-- the character details panel was (re)opened
	core:add_listener(
		"aera_panel_opened",
		"PanelOpenedCampaign",
		function(context)
			return context.string == AERA_PANEL_NAME;
		end,
		function(context)
			aera_on_panel_opened();
		end,
		true
	);

	core:add_listener(
		"aera_panel_closed",
		"PanelClosedCampaign",
		function(context)
			return context.string == AERA_PANEL_NAME;
		end,
		function(context)
			aera_reset_layout_state();
		end,
		true
	);

	-- our button
	core:add_listener(
		"aera_button_clicked",
		"ComponentLClickUp",
		function(context)
			return context.string == AERA_BUTTON_NAME;
		end,
		function(context)
			aera_out("EQUIP button clicked, deferring to the campaign tick");
			cm:callback(function()
				aera_equip_all();
			end, 0);
		end,
		true
	);

	-- optional: run the same assignment once at the start of every own turn
	core:add_listener(
		"aera_turn_start",
		"FactionTurnStart",
		function(context)
			local faction = context:faction();
			return aera_is_valid_interface(faction)
				and faction:is_human()
				and faction:name() == cm:get_local_faction_name();
		end,
		function(context)
			if aera_mct_get(AERA_MCT_OPTION_AUTO_TURN, true) ~= true then
				return;
			end;

			-- FactionTurnStart is dispatched after the model update, so the
			-- run can happen right here - not from a cm:callback timer.
			aera_equip_all();
		end,
		true
	);

	-- Build the key -> rarity table once, on the campaign tick.  It is the
	-- only CCO work left in this mod (the vanilla magic item scripts do the
	-- same), and doing it up front keeps the first click instant.
	cm:callback(function()
		aera_debug_enabled = aera_mct_get(AERA_MCT_OPTION_DEBUG, false) == true;
		aera_db_load();
	end, 1);

	aera_out("v" .. AERA_VERSION .. " loaded");
end;
