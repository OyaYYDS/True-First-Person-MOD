# Palworld First Person Mod Development Rules

 项目定位:这是一个基于 UE4SS Lua 的 Palworld 第一人称 Mod 项目。

目标：

- 实现稳定的第一人称体验
- 保持与 Palworld 原生系统兼容
- 避免因为修改导致游戏崩溃
- 优先稳定性，而不是代码重构

当前主要开发文件：
开发版本：C:\Oya_Someitem\3.ZTLWJ\Ai\Claude_Code\3769538724\Scripts\main.lua
Steam游戏模组位置：E:\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\Mods\FirstPerson\Scripts\main.lua
---

## 知识库与记忆（回答前必读）

- **项目知识库**（完整事实数据库，3300+ 行）：`参考内容/模组制作的知识点/帕鲁第一人称/帕鲁第一人称-开发知识库.md`
  - 最新章节从文件末尾往前读：§14（v3.19 振荡/hook nil）、§13（参考模组取证）、§12（v3.18-diag 判读）、§9（UE4SS 环境事实）、§2（历史失败路径）
  - 写入规则：置信度 ≥90%，只写已验证/已复现/已确认失败的事实；无法确认标【待验证】
- **Memory 文件**（原理级速记，会话自动载入）：`memory/MEMORY.md` — 自激振荡机制 / Lua 词法作用域 hook nil / MoveOptionRow 追加末尾语义
- 讨论代码问题时先查上述两处，避免重复推导已证实结论。
- **SDK参考**:"C:\Oya_Someitem\3.ZTLWJ\Ai\Claude_Code\参考内容\SDK调用参考"
- **Lua参考**："C:\Oya_Someitem\3.ZTLWJ\Ai\Claude_Code\参考内容\Lua调用参考"
---

## 核心开发原则

### 1. 最小修改原则

默认情况下：

- 不进行大规模重构
- 不删除已有逻辑
- 不改变已经验证稳定的代码路径
- 优先使用最小 diff 修复问题

如果预计修改超过 50 行代码：
必须先说明：

1. 为什么需要大量修改
2. 影响范围
3. 风险
4. 是否可以拆分

---

### 2. 修改前必须备份

任何修改 main.lua 前必须创建备份。
备份路径：参考内容/模组制作的知识点/帕鲁第一人称/备份
格式：main_x_x_x_版本号-(额外注释).lua
例如：main_2026_8_7_v3.7-设置添加项.lua
禁止直接覆盖原文件。

---

### 3. 修改流程

严格遵循：
分析问题-提出修改方案-等待确认-修改代码-检查代码-输出修改报告-等待用户确认-执行部署
禁止未经确认直接修改核心文件。

---

### 4. Steam部署规则

开发文件:C:\Oya_Someitem\3.ZTLWJ\Ai\Claude_Code\3769538724\Scripts\main.lua
Steam游戏模组位置:E:\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\Mods\FirstPerson\Scripts\main.lua
修改完成后：自动覆盖 Steam游戏模组位置。
必须等待用户确认。
用户确认后执行：复制开发版本 main.lua 覆盖 Steam 测试版本 main.lua
部署前确认：

- 文件存在
- 修改没有语法错误
- 目标路径正确

---

### 5. Palworld / UE4SS 特殊规则

这是 UE4SS Lua Mod。
修改代码时必须注意：

#### UObject安全

任何 UObject 操作：
必须考虑：

- Valid()
- IsValidObj()
- pcall保护

禁止默认假设对象一定存在。

---

#### 生命周期

Palworld UI 和 UObject 存在异步创建过程。
不要假设NotifyOnNewObject 回调时对象已经完全Construct。
涉及：

- Widget
- Settings UI
- Camera
- Player对象

必须考虑初始化时机。

---

#### Hook规则

不要随意增加：
RegisterHook
特别是：
UI Construct
Slate
Widget事件
除非：

1. 已证明轮询无法实现
2. 有明确测试
3. 说明风险

---

#### LoopAsync规则

不要随意增加：
LoopAsync(0)

或者无限循环。

新增循环必须说明：

- 为什么需要
- 执行频率
- 是否会影响性能

---

### 6. 设置菜单修改规则

Palworld设置菜单属于高风险区域。
修改：

- WBP_OptionSettings
- WBP_Graphic_Settings
- Widget Tree
- AddChild
- RemoveChild
- Move Widget
必须先分析生命周期。
禁止直接尝试改变Widget结构。

---

### 7. 知识库规则

文件：帕鲁第一人称-开发知识库.md
这是项目事实数据库。
修改要求：置信度必须 >= 90%。
允许写入：

- 已验证成功的方法
- 已复现的问题
- 已确认失败的方法
- 已确认SDK信息
- 已测试参数

禁止写入：

- 猜测
- 理论推断
- 未验证方案

如果无法确认使用：【待验证】标记。

---

### 8. 每次修改后报告

完成修改后必须输出：

#### 修改内容

修改了哪些文件。
哪些函数。

#### 修改原因

解决什么问题。

#### 风险

可能影响什么。

#### 测试方案

例如：

1. 启动游戏
2. 打开设置
3. 切换第一/第三人称
4. 测试FOV
5. 测试骑乘
6. 查看日志

---

### 9. 调试优先级

遇到问题：

优先：

1. 阅读现有代码
2. 查找已有实现
3. 对比参考Mod
4. 分析调用链
5. 修改

不要：

看到问题立即重写。

---

### 10. 参考Mod规则

参考Mod：Immersive-Palworld

可以：

- 学习设计思想
- 对比实现方式

禁止：直接复制大量代码。

任何参考代码必须说明：

- 为什么需要
- 与当前实现区别
- 是否可能引入副作用

---

### 11. Git / 文件安全

如果发现：

- 大量修改
- 删除代码
- 结构变化

必须提醒用户，不要主动删除旧代码。

优先注释旧逻辑，保留回滚可能。

---

## 最终目标

这个项目优先级：稳定运行 > 功能增加 > 代码美观
任何方案：如果增加崩溃概率，即使代码更优雅，也不优先采用。