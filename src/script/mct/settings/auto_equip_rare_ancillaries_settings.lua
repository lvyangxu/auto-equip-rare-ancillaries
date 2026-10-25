--====================================================================--
--  Auto Equip Rare Ancillaries - MCT settings page
--  (script/mct/settings/auto_equip_rare_ancillaries_settings.lua)
--====================================================================--
--  Registers this mod in the "Mod Configuration Tool" (MCT).
--
--  MCT automatically loads every *.lua file placed under
--  script/mct/settings/, so this file needs NO entry function of its own.
--  The main script reads the values back with:
--
--      get_mct():get_mod_by_key(<mod_key>)
--               :get_option_by_key(<option_key>)
--               :get_selected_setting()
--
--  The keys used here MUST match the ones in
--  script/campaign/mod/auto_equip_rare_ancillaries.lua.
--====================================================================--

-- MCT is optional: when it is not installed `get_mct` is nil and we bail,
-- leaving the mod on its built-in defaults (button on, ranged rule on,
-- lords excluded, debugging off).
if not get_mct then
	return;
end;

local mct = get_mct();

local mod = mct:register_mod("auto_equip_rare_ancillaries");
-- 不调用 set_author()：MCT 只有在 author 非空时才会创建 "Created by:" 行，
-- 这样配置页只显示 Mod 名字。
mod:set_title("一键装备蓝色装备");
mod:set_description("默认在每个自己回合开始时，自动把所有空闲的蓝色（稀有）装备分配给已拥有「长生久视」的事务官。也可以在 MCT 中开启「显示按钮」，在角色详情面板手动点一次。远程类装备不会给近战事务官。");

local show_button = mod:add_new_option("equip_rare_enabled", "checkbox");
show_button:set_default_value(false);
show_button:set_text("显示「一键装备蓝色装备」按钮（默认隐藏）");
show_button:set_tooltip_text("开启后，角色详情面板的装备栏会显示一个手动按钮。默认关闭，按钮隐藏；不显示按钮时，每回合自动装备仍然生效。");

local auto_turn = mod:add_new_option("equip_auto_each_turn", "checkbox");
auto_turn:set_default_value(true);
auto_turn:set_text("每回合开始自动装备一次");
auto_turn:set_tooltip_text("开启后，在每个自己派系回合开始时自动执行一次分配。只会装备到空槽位，不会替换事务官已有的装备。默认开启。");

local avoid_ranged = mod:add_new_option("equip_avoid_ranged_on_melee", "checkbox");
avoid_ranged:set_default_value(true);
avoid_ranged:set_text("远程类装备不给近战事务官");
avoid_ranged:set_tooltip_text("开启后，装备侧会识别远程 / 射程 / 弹药类关键词，尽量不把远程装备分给近战事务官；无法安全判定事务官是否远程时会放行，避免漏装。默认开启。");

local include_lords = mod:add_new_option("equip_include_lords", "checkbox");
include_lords:set_default_value(false);
include_lords:set_text("一键装备时也包含领主");
include_lords:set_tooltip_text("开启后，每回合自动装备与手动按钮也会把装备分给已拥有长生久视的领主 / 将军。默认关闭，只作用于事务官。");

local debug_log = mod:add_new_option("equip_debug", "checkbox");
debug_log:set_default_value(false);
debug_log:set_text("输出运行 / 分配调试日志");
debug_log:set_tooltip_text("开启后才会输出 Mod 的运行日志（候选事务官、每件装备的分配结果等），写入 lua_mod_log.txt 和 aera_trace.log；关闭时完全不打印。默认关闭。");
