# 一键装备蓝色装备（AutoEquipRareAncillaries）

一个《全面战争：战锤3》（Total War: WARHAMMER III）的脚本 Mod。

默认在每个自己回合开始时，自动把派系背包里**所有空闲的蓝色（稀有）装备**分给**已拥有「长生久视」的事务官**；也可以在 MCT 中开启手动按钮，随时点一次。

本 Mod 与 [AutoSkillPointsForAgents](../hero-auto-skill)（自动分配技能点）**完全独立**，可以单独启用 / 停用任意一个。

## 它做什么

默认不需要打开角色面板：每个自己回合开始时自动执行一次。若在 MCT 中开启「显示按钮」，角色详情面板 → 装备栏的「融合 / 分解」按钮上方会多出一行 **「一键装备蓝色装备」**，可以手动点一次。执行时：

1. 取本派系**所有空闲的蓝色（稀有）装备**（即背包池里、没有被任何角色装备的 `rare` 装备）；
2. 只把它们装到**已拥有「长生久视」（immortal）的事务官**身上；
3. 加**远程 / 射程 / 弹药**类加成的装备，不会给**近战事务官**；
4. 逐件检查该事务官能否装备（类别限制、槽位是否已满），装不上就换下一个事务官。

## 三条硬性规则

### 1. 只要长生久视的事务官

非长生久视的角色被击败会永久死亡，身上的装备会一起消失。所以本功能用引擎的 `character_details():is_immortal()` 判断，只把装备分给会「死亡变重伤」的角色。

### 2. 远程装备不进近战事务官

判断方式是：

- **装备侧**：只看装备的 db key 关键词（如 `_bow`、`_handgun`、`_arrow`、`_missile`…），同时排除 `resist / 抗性 / 抵抗` 这类防御加成。
  > 早期版本会先读装备的效果文本（`EffectText` / `EffectList`）来识别“远程 / 射程 / 弹药”。这条路径已经**移除**：遍历效果时调用的 `CcoEffect.EffectKey` 按引擎文档只对 `CAMPAIGN_EFFECT` 有效，对装备的 effect 调用会让**游戏直接崩溃**（`pcall` 也拦不住）。
- **事务官侧**：目前**默认关闭**。要判断一个事务官是否远程，只能读 `CcoCampaignCharacter.UnitDetailsContext` / `CcoUnitDetails.StatList`，而这两个接口的文档签名要求一个脚本里拿不到的 `ExpressionState` 参数，传错同样是原生崩溃。因此现阶段统一按“无法判定”处理（见下）。

无法判定事务官是否远程时，装备会**放行**（宁可不漏装）；开启「输出运行 / 分配调试日志」后，才会在 `lua_mod_log.txt` 写一行记录并显示每个候选的判定细节。

脚本里有一个常量 `AERA_READ_UNIT_STATS`（默认 `false`），等哪天确认 `UnitDetailsContext` 在某个游戏版本上可以安全调用，再打开它。

### 3. 只填空槽，绝不替换已有装备

目标事务官如果已经戴着同类装备（武器 / 护甲 / 护符 / 附魔物品 / 奥术物品 / 坐骑），这件装备就不会装给他，**更不会顶掉他身上的装备**。

原因：原版的 `CanEquipAncillary` 只回答「这个角色能不能用这类装备」，**不看槽位是否已满**；原版面板允许往已占用槽位放（那是 UI 的替换操作），`EquipToCharacter` 的第二个参数就是被替换掉的那件。所以脚本自己再数一遍角色身上同类装备的数量，只往真正的空槽里放。

数量是这样得到的：对候选 key 逐个调 `character:has_ancillary(key)`，累加出该角色每个类别已有几件，再与槽位数比较（v1.7.0 起不再读 `CcoCampaignCharacter.AncillaryList`，那条路径在部分游戏版本上会把 CCO 求值器弄坏）。找不到空槽时装备会留在背包里；开启调试后日志里计入 “kept back for lack of a free slot”。

## 补充说明

- 军旗类（`general` 类别）装备**不会**被处理，它们只能给部队。
- **多人战役会自动跳过**：脚本直接改装备数据有同步风险，因此只在单人战役中执行。
- 只在**本地玩家派系**下工作。
- 装备动作走的是**角色面板自己用的那套 UI 上下文命令**（`CcoCampaignAncillary.EquipToCharacter`），不再调用任何 `cm:` 写命令；装备后用 `character:has_ancillary(key)` 确认真的戴上了。

## 配置（Mod Configuration Tool / MCT）

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| 显示「一键装备蓝色装备」按钮（默认隐藏） | **关（隐藏）** | 开启后角色面板才出现手动按钮；不影响每回合自动装备 |
| 每回合开始自动装备一次 | **开** | 每个自己回合开始时自动执行；只往空槽放，不会替换事务官已有的装备 |
| 远程类装备不给近战事务官 | **开** | 关闭后只按槽位 / 类别分配，不再区分近战远程 |
| 一键装备时也包含领主 | **关** | 开启后，每回合自动装备与手动按钮也会把装备分给长生久视的领主 / 将军 |
| 输出运行 / 分配调试日志 | **关** | 开启后才会输出运行日志（候选事务官、每件装备的分配结果、背包稀有度统计等）；关闭时完全不打印 |

未安装 MCT 时，Mod 使用上述内置默认值，功能照常工作。

## 实现原理

- 池子里有哪些蓝装：进战役后先读一次 db 表，把稀有度为 common / uncommon / rare 的 db key 缓存下来。**不再要求 `RandomlyDropped == true`**，所以融合 / 打造 / 任务版本的蓝装也能被看到（早期只收随机掉落，融合出来的同名蓝装会凭空消失）。之后每次运行只对这批 key 查询，不再遍历派系的 `CcoCampaignFaction.AncillaryList`。
- 哪几件是空闲的：不去读池子条目的 `CharacterEquippedToContext`（空闲时它是 **null 上下文**，读它的属性会让游戏直接崩溃）。改成算术：

  ```
  某个 key 的空闲件数 = 派系拥有件数 - 该 key 的穿戴人数
  ```

  - 派系拥有件数（包含池中与已佩戴）：`faction:num_ancillaries_owned(key)`；
  - 穿戴人数：遍历**本派系每个角色**，调 `character:has_ancillary(key)` 计数（原版 `wh3_campaign_magic_items.lua:259-272` 就是这么算的）。

  > 早期版本用 `cm:model():world():characters_owning_ancillary(key)` 数穿戴人数，实测数值不可信（某件池子里只有 1 件的装备会报「5 人佩戴」），已弃用。
- 事务官身上已占的槽位：对整个 category 里**派系实际拥有的** key 逐个调 `character:has_ancillary(key)`，累加出该角色这个 category 已有几件。只数背包候选会把「已经戴在身上、因此不在背包里」的那件漏掉，v1.27 就是这样在同一个槽位上把两件附魔来回替换的；而扫整个 category（几百个 key）在后期会很慢，所以每次运行先建一次 `owned index`，之后只扫派系拥有的那几十个 key。
- 性能：一次点击的扫描量大致是「所有可掉落 key 的 `num_ancillaries_owned` + 已拥有 key × 角色数 + 每件待装物品 × 目标数 × 该 category 已拥有 key 数」。开启「输出运行 / 分配调试日志」后，日志会输出 `EQUIP scan: N target(s), M item(s), X ms`，以及 `owned index ... ms` 和 `scan done ... ms`，后期事务官多时可以直接看实际耗时。
- 装备动作：分两个战役 tick 做，不能在同一次点击/同一个 tick 里连做。

  1. 点击后先 `cm:callback(..., 0)` 延迟到下一个战役 tick，再调 `cm:force_remove_ancillary_from_faction(faction, key)` 把池子里那件取走；
  2. 等 0.5 秒确认 `faction:num_ancillaries_owned(key) == 0`，再调 `cm:force_add_ancillary(character, key, true, true)` 直接装到角色身上；
  3. 如果第二步没戴上，或者移除的数量不对，用 `cm:add_ancillary_to_faction` 把缺少的副本补回原本的数量（不是只补 1 件）。

  **同名多件**：`force_remove_ancillary_from_faction` 会把这个 key 的所有副本一起拿走，所以只有在该 key 的**所有副本都 idle**（没有任何角色戴着）时才处理——先全部移走、给角色装 1 件、再把 N-1 件补回池子；只要有一件已经戴在角色身上，就整组跳过，避免把别人身上的装备一起拿走。`N > 10` 也跳过。日志里对应 `dup-queued=`、`partial=`、`too-many=`。

  > 同名多件且已有一件被戴着时，**脚本 API 无法只移动空闲的那一件**（v1.38 - v1.54 实测）：
  > `force_remove_ancillary_from_faction` 会删光所有副本；`force_add_ancillary` 不会消费空闲件，而是新建一件（`owned` 2→3）；CCO 的 `EquipToCharacter`、`RemoveAncillary`、`Salvage` 对空闲实例都是空操作。
  > 因此 mod 不自动处理这种组合，也不会复制或扒下已装备的件；玩家需要手动从全局池把空闲的一件拖到另一个角色的装备槽。这是当前游戏 API 的硬限制。

  一次只处理一件、每件之间隔 0.5 秒。

  > 关键：这两步不能放进 UI 点击回调，也不能在同一个 tick 里连做。v1.27 的实测日志证明，分开到两个 tick 后 `remove` 和 `add` 都返回 `ok=true`，`wears=true`、`owned=1`，物品确实从池子移到了角色身上。

  > 踩过的坑：把 `CcoCampaignAncillary.EquipToCharacter` 当成普通脚本命令调（v1.2 - v1.26）会静默失败，并把整个 CCO 求值器弄坏；随后角色面板刷新时空指针崩溃（`0xc0000005`）。对池子里已有的 key 直接 `force_add_ancillary(..., true, true)` 不会崩，但会**新建一件**（`owned` +1），不是消费空闲件，所以同名多件不能这样处理。`force_remove_ancillary_from_faction` 会删光所有副本，也不能用来单独回收空闲件。


## UI 与其他 Mod 的兼容

按钮采用与 **Fusion Wizard** 相同的思路：**不覆盖任何原版 `.twui.xml`**，而是在运行时创建。

- 模板直接复用原版 `ui/templates/square_large_text_button`，挂在 `character_details_panel / equipment_holder / global_pool` 下；
- 定位在「融合 / 分解」按钮行之上，并把装备列表高度缩小相应像素腾出空间；
- 监听 `PanelOpenedCampaign`（`character_details_panel`）重建布局，`PanelClosedCampaign` 复位记录；
- 若检测到 Fusion Wizard 的 `item_fusion_assistant_button`，本按钮会叠在它上面，两个按钮同时可用；
- 配有 `cm:real_callback` 二次布局，即使对方 Mod 比本 Mod 更晚创建按钮也能正确堆叠。

因此任何修改角色面板布局的 Mod 都不会与本 Mod 的按钮直接冲突。

## 安装

在 Steam 创意工坊订阅本 Mod 即可，游戏会自动从工坊下载目录加载，**不需要**手动放置任何文件。订阅后在启动器的 Mod 列表里勾选「一键装备蓝色装备」即可。

## 目录结构

```
src/
  script/campaign/mod/auto_equip_rare_ancillaries.lua           按钮 + 分配逻辑
  script/mct/settings/auto_equip_rare_ancillaries_settings.lua  MCT 配置页
dist/     打包好的 .pack 与缩略图
tools/    构建 / 结构校验辅助脚本（不随 Mod 发布）
```

## 自行构建

```
python tools/build_pack.py src dist/AutoEquipRareAncillaries.pack
```

**发布更新流程**（工坊下载目录是唯一真源）：

1. 构建到 `dist/AutoEquipRareAncillaries.pack`；
2. 覆盖到工坊下载目录：`<Steam 库>\steamapps\workshop\content\1142710\3821299822\AutoEquipRareAncillaries.pack`；
3. 启动器里对该 Mod 点「更新」，上传到创意工坊；
4. 进游戏后在 `lua_mod_log.txt` 确认出现 `[auto_equip_rare_ancillaries] v1.15.0 loaded`。

> 工坊目录由 Steam 托管：校验文件完整性 / 取消再订阅 / 重新下载都会把它还原成旧版本，请始终保留 `dist\` 里的构建产物，随时能重新覆盖。

> 开发提示：引擎会把 pack 内的路径统一转成小写，再调用与（小写）文件名同名的全局入口函数。
> 因此脚本文件 `auto_equip_rare_ancillaries.lua` 与入口函数 `auto_equip_rare_ancillaries()` 必须保持**全小写且一致**，否则 Mod 会静默失效。
