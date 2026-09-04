# True First Person MOD

Palworld 第一人称 MOD —— 基于 UE4SS Lua 实现，当前开发版本 v3.19。

## 功能

- 稳定的第一人称视角体验
- 第一 / 第三人称自由切换
- FOV 调整
- 骑乘状态支持
- 与 Palworld 原生设置菜单集成

## 安装

1. 安装 [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)
2. 将本仓库的 `3769538724` 文件夹复制（或重命名）到：
   `Palworld/Mods/NativeMods/UE4SS/Mods/FirstPerson/`
3. 启动游戏

## 目录结构

```
3769538724/
├── Scripts/main.lua          # MOD 主逻辑（UE4SS Lua）
├── Scripts/balance_check.py  # 辅助脚本
├── Info.json                 # MOD 信息
├── .workshop.json            # Steam Workshop 元数据
├── thumbnail.png             # 封面
└── *.png                     # 游戏内截图
```

## 开发

- 开发规范见 [CLAUDE.md](CLAUDE.md)
- 原则：稳定运行 > 功能增加 > 代码美观
