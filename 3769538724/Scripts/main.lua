-- ===== 脚本目录（用于配置文件路径） =====
local ScriptDir = nil
do
    local info = debug.getinfo(1, "S")
    local source = info and info.source
    if source then
        ScriptDir = string.gsub(string.gsub(source, "^@", ""), "main%.lua$", "")
    end
end

-- ===== 配置常量 =====
-- 第一人称
local FPRiding = true

-- ▸ 相机追头部动画（路线A）
--   相机挂 Pawn.Mesh（身体，保持可见 → 骨骼动画必然每帧更新）的头部 socket。
--   头骨 ≈ 最接近眼睛的位置（SDK 无独立 eye 骨骼），隐藏头后仍能追到头部动画。
local FPCameraSocket = "head"   -- 相机固定追头部 socket（≈ 眼睛位置，已实测可用）
-- 相机偏移（cm；X=前 Y=右 Z=上，负 Z=往下）
local FPSocketOffsets = {
    head = { X = 15, Y = 0, Z = 0 },   -- 徒步眼睛偏移（用户微调 2026-08-15）x:高度 y:前后 z:左右
}
local FPRidingSocketOffsets = {
    head = { X = 3, Y = 6, Z = 0 },  -- 骑乘眼睛偏移（按需微调）x:高度 y:前后 z:左右
}
-- 兼容旧引用（实际偏移由上方 per-socket 表提供）
local EyeOffsetX = FPSocketOffsets[FPCameraSocket].X
local EyeOffsetY = FPSocketOffsets[FPCameraSocket].Y
local EyeOffsetZ = FPSocketOffsets[FPCameraSocket].Z
local MountOffsetX = FPRidingSocketOffsets[FPCameraSocket].X
local MountOffsetY = FPRidingSocketOffsets[FPCameraSocket].Y
local MountOffsetZ = FPRidingSocketOffsets[FPCameraSocket].Z

-- FOV（独立渲染层覆盖，绝对角度；与原版 GraphicsSettings.FOV 完全隔离）
local FOV_HARD_MIN = 60
local FOV_HARD_MAX = 140
local DEFAULT_FP_FOV = 110
local DEFAULT_TP_FOV = 90

-- ===== 状态变量 =====
-- 第一人称
local FirstPerson = false
local PendingOff = false
local SavedMountCam = nil
local SavedMountParent = nil
local SavedMountSocket = nil
local SavedMountName = nil
-- 徒步相机原始状态（首次挂 head 前捕获，退出时精确还原，）
local SavedCamRef = nil
local SavedCamParent = nil
local SavedCamSocket = nil
local SavedCamRelLoc = nil
local SavedCamRelRot = nil
local SavedCamAbsLoc = false
local SavedCamAbsRot = false
local SavedCamUsePawnRot = false
local LastActivePawnName = nil
local PawnLostLogged = false

-- FOV（独立于原版 GraphicsSettings.FOV，由渲染层覆盖生效）
local ModFOVEnabled = false   -- Mod FOV 总开关（设置页开关控制）
local FirstPersonFOV = DEFAULT_FP_FOV   -- 第一人称目标 FOV（绝对角度）
local ThirdPersonFOV = DEFAULT_TP_FOV   -- 第三人称目标 FOV（绝对角度）
local AimActive = false
local AimGraceEnd = 0
local ConfigDirty = false  -- 延迟写标记，避免热键回调中同步写磁盘卡顿
local LastSaveErrorTime = 0  -- SaveConfig 失败日志节流（防失败重试每帧刷屏）
-- fp_config 里是否有 TP 值（首次播种用）。必须声明在 LoadConfig 之前：
-- Lua 词法作用域中 local 从声明点才进入作用域，否则 LoadConfig 内引用会落到全局，
-- 导致旧格式迁移标记不生效、TP 档案被 SeedFOV 意外改写成原版值
local ThirdPersonFOVConfigured = false

-- 武器偏移（仅对大型武器生效，RelativeLocation 为 0 时直接用偏移值）
local WeaponOffsetEnabled = true
local WeaponFrameCount = 0
-- 武器原始 transform 捕获（FP 首次设置偏移前读 mesh 默认值，
-- TP/关闭时还原用；仅记录曾设置过偏移的武器）。键 = shortName
local WeaponOrigTransforms = {}

local function RestoreWeaponOffsets(Pawn)
    for shortName, orig in pairs(WeaponOrigTransforms) do
        if orig and orig.loc and orig.rot then
            local mesh = orig.mesh
            if mesh and mesh:IsValid() then
                pcall(function() mesh.RelativeLocation = orig.loc end)
                pcall(function() mesh.RelativeRotation = orig.rot end)
                pcall(function() mesh:K2_SetRelativeRotation(orig.rot, false, {}, false) end)
                pcall(function() mesh:SetRelativeRotation(orig.rot) end)
            end
        end
    end
    WeaponOrigTransforms = {}
    print("[FP-WEAPON] restored all recorded offsets")
end

-- 需要调整的大型武器配置：关键字 → { 位置偏移, 旋转偏移 }
-- 旋转偏移: pitch=水平轴俯仰, yaw=竖直轴旋转, roll=前后轴翻滚
-- 关键字从武器 GetFullName() 中提取（不含 _C 后缀），子串匹配
local LargeWeaponConfig = {
    -- 🚀 发射器类（最需要偏移）
    -- 观察到了误偏移）→ 改准确词条 ["BeamLauncher"]，光剑不再匹配任何配置（不偏移）
    ["Launcher_Meteor"]  = { offsetX=10, offsetY=10, offsetZ=0, pitch=40,  yaw=-85, roll=10 },  -- 陨石发射器
    ["RocketLauncher"]   = { offsetX=8, offsetY=3, offsetZ=-10, pitch=5,  yaw=-10, roll=10 }, --火箭发射器（含等离子炮 BP_EnergyRocketLauncher）
    ["MissileLauncher"]  = { offsetX=8, offsetY=3, offsetZ=-10, pitch=5,  yaw=-10, roll=10 },  -- 追踪/多联装
    ["SkyGrenadeLauncher"] = { offsetX=4, offsetY=3, offsetZ=-10, pitch=5,  yaw=0, roll=0 },  -- 战术榴弹 BP_SkyGrenadeLauncher
    ["GrenadeLauncher"]  = { offsetX=4, offsetY=3, offsetZ=0, pitch=5,  yaw=-10, roll=10 },  -- 榴弹发射器 BP_GrenadeLauncher
    ["BeamLauncher"]     = { offsetX=8, offsetY=3, offsetZ=-15, pitch=5,  yaw=-10, roll=0 },  -- 光束炮发射器（准确词条，不含光剑）
    ["SphereLauncher"]   = { offsetX=8, offsetY=3, offsetZ=-4, pitch=5,  yaw=-10, roll=10 },  -- 帕鲁球发射器（各型号外观相同）
    -- 🏹 弓（2026-08-15 全 6 类类名实测；禁用 "Bow" 通配——会误吞 BP_Bowgun 十字弓。
    -- 十字弓模型特殊独立条目，其余 5 把共用一套，数值按用户微调）
    ["Bowgun"]           = { offsetX=5, offsetY=2, offsetZ=0,  pitch=-3, yaw=0,   roll=0 },  -- 十字弓（不动）
    ["CompoundBow"]      = { offsetX=5, offsetY=10, offsetZ=3, pitch=0, yaw=0,   roll=-115 },  -- 复合弓
    ["WeakerBow"]        = { offsetX=5, offsetY=10, offsetZ=3, pitch=0, yaw=0,   roll=-115 },  -- 陈旧的弓
    ["Bow_Triple"]       = { offsetX=5, offsetY=10, offsetZ=3, pitch=0, yaw=0,   roll=-115 },  -- 三连弓
    ["SFBow"]            = { offsetX=5, offsetY=10, offsetZ=3, pitch=0, yaw=0,   roll=-115 },  -- 卓越弓
    ["SkyBow"]           = { offsetX=5, offsetY=10, offsetZ=3, pitch=0, yaw=0,   roll=-115 },  -- 机械弓
    -- 🔫 特殊测试条目：观察原版手部动画是否追踪武器位置（手追武器）。
    -- 实测：神射手左轮=右手单手武器无锚点；爪钩枪=无锚点非双手前伸。数值按用户微调
    ["OctaviaRevolver"]  = { offsetX=-3, offsetY=0, offsetZ=0,  pitch=0, yaw=0,   roll=0 },  -- 神射手左轮（动画特殊，独立）
    ["GrapplingGun"]     = { offsetX=0, offsetY=0, offsetZ=0,  pitch=0, yaw=-6,   roll=0 },  -- 爪钩枪全 5 档（模型动作一致）
}

-- 操作机制确认：左键按住=拉弓，右键按住=瞄准姿态（武器举到胸前）
local BowConditionalKeys = {
    Bowgun = true, CompoundBow = true, WeakerBow = true,
    Bow_Triple = true, SFBow = true, SkyBow = true,
    _pullActive = false, -- 拉弓状态锁存（PullTrigger/ReleaseTrigger/
                         -- BowPullAnimeEnd hook 驱动；true = 按住左键拉弓中）
}

-- 模组界面语言（自动检测，无手动开关）
local LangUI = {
    auto = "zh",   -- 自动检测值（语言行 CJK 判定；检测失败保持现值）
    -- zh=简体中文 en=English；简体/繁体天然统一简体（用户需求）
    zh = {
        FirstPerson = "第一人称",
        FirstPersonRiding = "第一人称骑乘",
        ThirdPersonFOV = "第三人称 FOV",
        FirstPersonFOV = "第一人称 FOV",
        HotkeyFP = "第一人称",
        HotkeyRiding = "骑乘第一人称",
        -- 武器偏移开关（图像设定页【其他】下方）
        WeaponOffset = "第一人称武器偏移",
    },
    en = {
        FirstPerson = "First Person",
        FirstPersonRiding = "First Person Riding",
        ThirdPersonFOV = "Third Person FOV",
        FirstPersonFOV = "First Person FOV",
        HotkeyFP = "First Person",
        HotkeyRiding = "Riding First Person",
        WeaponOffset = "First Person Weapon Offset",
    },
    -- 按自动检测值取行名文本（未命中回退英文）
    t = function(self, key)
        local lang = self.auto
        local tab = lang == "zh" and self.zh or self.en
        return tab[key] or self.en[key]
    end,
}

-- 热键已迁移为原生可重映射 Player Action（见文末原生热键系统）

-- ===== 配置持久化 =====
local ConfigPath = ScriptDir and (ScriptDir .. "fp_config.lua") or nil

-- ===== 落盘日志系统  =====
-- 目的：崩溃/假死/状态损坏后，读日志文件末尾即可定位崩溃前最后 Mod 操作。
local LogThrottle = {}        -- 通用节流时间表（fovSwitchGrace 3 秒窗口标记等）



-- ConfigLoadResult 供 BOOT 显示加载状态；初始值 "not-run" 可暴露
-- "初始化流程根本没调用 LoadConfig"（比任何失败日志都重要）
local ConfigLoadResult = "not-run"

local function LoadConfig()
    if not ConfigPath then
        ConfigLoadResult = "failed(nil path)"
        return
    end
    local f = io.open(ConfigPath, "r")
    if not f then
        ConfigLoadResult = "failed(open)"
        return
    end
    local content = f:read("*a")
    f:close()
    local chunk = load(content, "fp_config", "t", {})
    if not chunk then
        ConfigLoadResult = "failed(load)"
        return
    end
    local ok, saved = pcall(chunk)
    if not ok or type(saved) ~= "table" then
        ConfigLoadResult = "failed(pcall)"
        return
    end
    if type(saved) == "table" then
        if type(saved.FirstPerson) == "boolean" then FirstPerson = saved.FirstPerson end
        if type(saved.FPRiding) == "boolean" then FPRiding = saved.FPRiding end
        if type(saved.ModFOVEnabled) == "boolean" then ModFOVEnabled = saved.ModFOVEnabled end
        -- 武器偏移开关（图像设定页【其他】下方，默认开）
        if type(saved.WeaponOffsetEnabled) == "boolean" then WeaponOffsetEnabled = saved.WeaponOffsetEnabled end
        ModFOVEnabled = true
        if type(saved.FirstPersonFOV) == "number" then
            FirstPersonFOV = math.min(FOV_HARD_MAX, math.max(FOV_HARD_MIN, saved.FirstPersonFOV))
        end
        if type(saved.ThirdPersonFOV) == "number" then
            ThirdPersonFOV = math.min(FOV_HARD_MAX, math.max(FOV_HARD_MIN, saved.ThirdPersonFOV))
            ThirdPersonFOVConfigured = true
        end
        if type(saved.ThirdPersonFOV) ~= "number"
            and type(saved.ModFOVEnabled) ~= "boolean" then
            ThirdPersonFOVConfigured = true
            ConfigDirty = true
            print("[FP] legacy fp_config detected, migrating to v3.6+ format")
        end
        -- ：成功状态（含加载到的实际值，BOOT 显示用）
        ConfigLoadResult = "loaded(FP=" .. tostring(FirstPerson)
            .. " ModFOV=" .. tostring(ModFOVEnabled)
            .. " TP-FOV=" .. string.format("%.0f", ThirdPersonFOV)
            .. " FP-FOV=" .. string.format("%.0f", FirstPersonFOV) .. ")"
    end
end

-- 失败时返回 false（不抛错 → 主循环协程存活），由调用方决定重试
local function SaveConfig()
    if not ConfigPath then return false end
    local f = io.open(ConfigPath, "w")
    if not f then
        -- 打开失败防护（磁盘满/只读/被锁）：nil:write() 会杀死主循环协程
        local now = os.clock()
        if now - LastSaveErrorTime > 10 then
            LastSaveErrorTime = now
            print("[FP] SaveConfig failed: cannot open " .. tostring(ConfigPath))
        end
        return false
    end
    local ok, err = pcall(function()
        f:write("return {\n")
        f:write(string.format("    FirstPerson = %s,\n", tostring(FirstPerson)))
        f:write(string.format("    FPRiding = %s,\n", tostring(FPRiding)))
        f:write(string.format("    ModFOVEnabled = %s,\n", tostring(ModFOVEnabled)))
        f:write(string.format("    WeaponOffsetEnabled = %s,\n", tostring(WeaponOffsetEnabled)))
        f:write(string.format("    FirstPersonFOV = %.0f,\n", FirstPersonFOV))
        f:write(string.format("    ThirdPersonFOV = %.0f,\n", ThirdPersonFOV))
        f:write("}\n")
    end)
    f:close()
    if not ok then
        print("[FP] SaveConfig write failed: " .. tostring(err))
        return false
    end
    return true
end

-- ===== 辅助：获取 Pawn（仅本地玩家，骑乘中也有效） =====
local function GetPawn()
    local pc = FindFirstOf("BP_PalPlayerController_C")
    if not pc or not pc:IsValid() then return nil end
    if not pc.Pawn or not pc.Pawn:IsValid() then return nil end
    if not pc.Pawn:IsLocallyControlled() then return nil end
    local controlledName = pc.Pawn:GetFullName()

    -- 第一优先级：pc.Pawn 本身就是 BP_Player_Female_C（非骑乘状态）
    if controlledName:find("BP_Player_Female_C") then
        return pc.Pawn
    end

    -- 第二优先级：骑乘中，遍历所有 BP_Player_Female_C 匹配 GetPalPlayerController
    local allPlayers = FindAllOf("BP_Player_Female_C")
    if not allPlayers then return nil end
    for _, p in ipairs(allPlayers) do
        if p and p:IsValid() then
            local pPC = p:GetPalPlayerController()
            if pPC and pPC:IsValid() and pPC:GetFullName() == pc:GetFullName() then
                return p
            end
        end
    end
    return nil
end

-- ===== 辅助：相机原始状态（捕获 / 精确还原，） =====
local function ReadCameraState(Camera)
    local parent = nil
    local socket = nil
    local relLoc = { X = 0, Y = 0, Z = 0 }
    local relRot = { Pitch = 0, Yaw = 0, Roll = 0 }
    local absLoc = false
    local absRot = false
    local usePawnRot = false
    pcall(function() parent = Camera:GetAttachParent() end)
    pcall(function() socket = Camera:GetAttachSocketName() end)
    pcall(function()
        relLoc = { X = Camera.RelativeLocation.X, Y = Camera.RelativeLocation.Y, Z = Camera.RelativeLocation.Z }
    end)
    pcall(function()
        relRot = { Pitch = Camera.RelativeRotation.Pitch, Yaw = Camera.RelativeRotation.Yaw, Roll = Camera.RelativeRotation.Roll }
    end)
    pcall(function() absLoc = Camera.bAbsoluteLocation end)
    pcall(function() absRot = Camera.bAbsoluteRotation end)
    pcall(function() usePawnRot = Camera.bUsePawnControlRotation end)
    return parent, socket, relLoc, relRot, absLoc, absRot, usePawnRot
end

local function ClearFootCameraState()
    SavedCamRef = nil
    SavedCamParent = nil
    SavedCamSocket = nil
    SavedCamRelLoc = nil
    SavedCamRelRot = nil
    SavedCamAbsLoc = false
    SavedCamAbsRot = false
    SavedCamUsePawnRot = false
end

-- 首次挂载徒步相机前捕获原始状态（幂等：已捕获则跳过）
local function CaptureFootCameraState(Camera)
    if not Camera or not Camera:IsValid() then return end
    if SavedCamRef ~= nil then return end
    SavedCamRef = Camera
    local parent, socket, relLoc, relRot, absLoc, absRot, usePawnRot = ReadCameraState(Camera)
    SavedCamParent, SavedCamSocket = parent, socket
    SavedCamRelLoc, SavedCamRelRot = relLoc, relRot
    SavedCamAbsLoc, SavedCamAbsRot = absLoc, absRot
    SavedCamUsePawnRot = usePawnRot
end

-- ===== 辅助：还原相机（优先用保存的原始状态精确还原，不依赖 GetPawn） =====
local function RestoreCameraToDefault(Pawn)
    local Camera = SavedCamRef
    if (not Camera or not Camera:IsValid()) and Pawn and Pawn:IsValid() then
        Camera = Pawn.FollowCamera
    end

    if Camera and Camera:IsValid() then
        local restored = false
        if SavedCamParent and SavedCamParent:IsValid() then
            -- 精确还原：恢复绝对标志 → 挂回原父级+socket → 写回原相对变换
            Camera.bAbsoluteLocation = SavedCamAbsLoc
            Camera.bAbsoluteRotation = SavedCamAbsRot
            pcall(function() Camera:K2_DetachFromComponent(1, 1, 1, false) end)
            pcall(function() Camera:K2_AttachTo(SavedCamParent, SavedCamSocket or FName(""), 2, false) end)
            if SavedCamRelLoc then
                pcall(function() Camera.RelativeLocation = SavedCamRelLoc end)
            end
            if SavedCamRelRot then
                pcall(function() Camera.RelativeRotation = SavedCamRelRot end)
            end
            Camera.bUsePawnControlRotation = SavedCamUsePawnRot
            restored = true
        end
        if not restored then
            -- 无保存状态：退回通用还原
            pcall(function() Camera:K2_DetachFromComponent(1, 1, 1, false) end)
            local boom = (Pawn and Pawn:IsValid() and Pawn.CameraBoom) or nil
            if boom and boom:IsValid() then
                Camera:K2_AttachTo(boom, FName(""), 2, false)
            end
            Camera.bUsePawnControlRotation = false
        end
    end

    ClearFootCameraState()

    local sc = (Pawn and Pawn:IsValid() and Pawn.ShooterComponent) or nil
    if sc and sc:IsValid() then
        sc:ResetOverrideRotationFlags()
    end
end

local function RestoreMountCamToDefault()
    if not SavedMountCam or not SavedMountCam:IsValid() then
        SavedMountCam, SavedMountParent, SavedMountSocket, SavedMountName = nil, nil, nil, nil
        return
    end
    SavedMountCam:K2_DetachFromComponent(1, 1, 1, false)
    if SavedMountParent and SavedMountParent:IsValid() then
        SavedMountCam:K2_AttachTo(SavedMountParent, SavedMountSocket or FName(""), 2, false)
    end
    SavedMountCam.bUsePawnControlRotation = false
    if SavedMountName then
        local om = FindFirstOf(SavedMountName:match("^(%S+)"))
        if om and om:IsValid() then om.bUseControllerRotationYaw = false end
    end
    SavedMountCam, SavedMountParent, SavedMountSocket, SavedMountName = nil, nil, nil, nil
end

-- ===== 辅助：相机追头部 socket（追眼睛动画，路线A） =====
-- head 骨骼 ≈ 最接近眼睛的位置。相机挂 Pawn.Mesh（身体，保持可见→骨骼动画
-- 必然每帧更新），所以隐藏头后依然能追到头骨动画。
local LastLoggedFPSocket = nil
local function ResolveFPCameraSocket(riding)
    local socket = FPCameraSocket
    local offsets = riding and FPRidingSocketOffsets[socket] or FPSocketOffsets[socket]
    return socket, offsets
end

local function AttachCameraToFPSocket(Camera, Pawn, riding)
    if not Camera or not Camera:IsValid() then return end
    if not Pawn or not Pawn:IsValid() or not Pawn.Mesh or not Pawn.Mesh:IsValid() then return end
    -- 徒步相机：首次挂载前捕获原始状态（退出时精确还原）
    if riding == false then
        CaptureFootCameraState(Camera)
    end
    local socket, offsets = ResolveFPCameraSocket(riding)
    pcall(function() Camera:K2_DetachFromComponent(1, 1, 1, false) end)
    Camera:K2_AttachTo(Pawn.Mesh, FName(socket), 2, 1)
    Camera.RelativeLocation = { X = offsets.X, Y = offsets.Y, Z = offsets.Z }
    Camera.bUsePawnControlRotation = true
    if socket ~= LastLoggedFPSocket then
        LastLoggedFPSocket = socket
        print("[FP] camera socket = " .. tostring(socket))
    end
    return socket
end

-- ===== 辅助：判断相机当前是否挂在指定组件上（用父级判断，避免 socket 名比较误判） =====
-- 之前用 AttachSocketName 比较，可能因 FName 返回格式不同导致每帧误判、
-- 反复 detach+attach 造成白帧。改为父级是否还是目标组件，更稳健。
local function IsCameraAttachedTo(Camera, Component)
    if not Camera or not Camera:IsValid() then return false end
    if not Component or not Component:IsValid() then return false end
    local parent = nil
    pcall(function() parent = Camera:GetAttachParent() end)
    if not parent or not parent:IsValid() then return false end
    return tostring(parent:GetFullName()) == tostring(Component:GetFullName())
end

-- ===== 辅助：抢坐骑相机（保存原始父级/socket，挂到玩家 head） =====
-- 可重复调用：错过首次抢相机窗口、或游戏把坐骑相机重新挂回第三人称时，自动补抢
local function StealMountCamera(ActivePawn, PlayerPawn)
    if not ActivePawn or not ActivePawn:IsValid() then return end
    if not PlayerPawn or not PlayerPawn:IsValid() then return end
    local MCam = ActivePawn.FollowCamera
    if not MCam or not MCam:IsValid() then return end

    -- 保存的是另一台相机：先还回去
    if SavedMountCam and SavedMountCam:IsValid() and SavedMountCam ~= MCam then
        SavedMountCam:K2_DetachFromComponent(1, 1, 1, false)
        if SavedMountParent and SavedMountParent:IsValid() then
            SavedMountCam:K2_AttachTo(SavedMountParent, SavedMountSocket or FName(""), 2, false)
        end
        SavedMountCam.bUsePawnControlRotation = false
        SavedMountCam, SavedMountParent, SavedMountSocket, SavedMountName = nil, nil, nil, nil
    end

    -- 新相机才记录原始状态（同一台相机被游戏重挂时，不能覆盖原父级/socket）
    if SavedMountCam ~= MCam then
        SavedMountCam = MCam
        SavedMountParent = MCam.AttachParent
        SavedMountSocket = MCam.AttachSocketName
        SavedMountName = ActivePawn:GetFullName()
    end
    AttachCameraToFPSocket(MCam, PlayerPawn, true)
end

-- ===== 辅助：隐藏/显示头和头发（隐藏时保持骨骼动画 + 保留影子） =====
-- 隐藏 HeadMesh 会让其骨骼停止 tick（旧教训#8），因此：
--   1) 保存原 VisibilityBasedAnimTickOption
--   2) 设为 0（AlwaysTickPoseAndRefreshBones）→ 隐藏后骨骼继续动画
--   3) 退出时恢复原值
-- 影子：，隐藏时把 bCastHiddenShadow 设为 true，
--   让头/头发即使不可见也继续投射阴影（否则第一人称影子会缺头）
local HiddenHeadAnimTick = nil   -- 保存的 HeadMesh.VisibilityBasedAnimTickOption
local HiddenHairAnimTick = nil   -- 保存的 HairMesh.VisibilityBasedAnimTickOption
local HiddenHeadCastShadow = nil -- 保存的 HeadMesh.bCastHiddenShadow
local HiddenHairCastShadow = nil -- 保存的 HairMesh.bCastHiddenShadow
local FPHeadMaintainTick = 0

local function HideFP(Pawn)
    if not Pawn or not Pawn:IsValid() then return end
    if Pawn.HeadMesh and Pawn.HeadMesh:IsValid() then
        if HiddenHeadAnimTick == nil then
            pcall(function() HiddenHeadAnimTick = Pawn.HeadMesh.VisibilityBasedAnimTickOption end)
        end
        if HiddenHeadCastShadow == nil then
            pcall(function() HiddenHeadCastShadow = Pawn.HeadMesh.bCastHiddenShadow end)
        end
        pcall(function() Pawn.HeadMesh.VisibilityBasedAnimTickOption = 0 end)
        pcall(function() Pawn.HeadMesh.bCastHiddenShadow = true end)
        pcall(function() Pawn.HeadMesh:SetVisibility(false, true) end)
    end
    if Pawn.HairMesh and Pawn.HairMesh:IsValid() then
        if HiddenHairAnimTick == nil then
            pcall(function() HiddenHairAnimTick = Pawn.HairMesh.VisibilityBasedAnimTickOption end)
        end
        if HiddenHairCastShadow == nil then
            pcall(function() HiddenHairCastShadow = Pawn.HairMesh.bCastHiddenShadow end)
        end
        pcall(function() Pawn.HairMesh.VisibilityBasedAnimTickOption = 0 end)
        pcall(function() Pawn.HairMesh.bCastHiddenShadow = true end)
        pcall(function() Pawn.HairMesh:SetVisibility(false, true) end)
    end
end

local function ShowFP(Pawn)
    if Pawn and Pawn:IsValid() then
        if Pawn.HeadMesh and Pawn.HeadMesh:IsValid() then
            pcall(function() Pawn.HeadMesh:SetVisibility(true, true) end)
            if HiddenHeadAnimTick ~= nil then
                pcall(function() Pawn.HeadMesh.VisibilityBasedAnimTickOption = HiddenHeadAnimTick end)
            end
            if HiddenHeadCastShadow ~= nil then
                pcall(function() Pawn.HeadMesh.bCastHiddenShadow = HiddenHeadCastShadow end)
            end
        end
        if Pawn.HairMesh and Pawn.HairMesh:IsValid() then
            pcall(function() Pawn.HairMesh:SetVisibility(true, true) end)
            if HiddenHairAnimTick ~= nil then
                pcall(function() Pawn.HairMesh.VisibilityBasedAnimTickOption = HiddenHairAnimTick end)
            end
            if HiddenHairCastShadow ~= nil then
                pcall(function() Pawn.HairMesh.bCastHiddenShadow = HiddenHairCastShadow end)
            end
        end
    end
    HiddenHeadAnimTick = nil
    HiddenHairAnimTick = nil
    HiddenHeadCastShadow = nil
    HiddenHairCastShadow = nil
end

-- ===== 辅助：每 60 帧维护一次（防游戏重置隐藏/动画/影子状态） =====
local function MaintainFPHead(Pawn)
    if not Pawn or not Pawn:IsValid() then return end
    if Pawn.HeadMesh and Pawn.HeadMesh:IsValid() then
        local tick = nil
        pcall(function() tick = Pawn.HeadMesh.VisibilityBasedAnimTickOption end)
        if tick ~= 0 then
            pcall(function() Pawn.HeadMesh.VisibilityBasedAnimTickOption = 0 end)
        end
        local castShadow = false
        pcall(function() castShadow = Pawn.HeadMesh.bCastHiddenShadow end)
        if castShadow ~= true then
            pcall(function() Pawn.HeadMesh.bCastHiddenShadow = true end)
        end
        local visible = false
        pcall(function() visible = Pawn.HeadMesh.bVisible end)
        if visible then
            pcall(function() Pawn.HeadMesh:SetVisibility(false, true) end)
        end
    end
    if Pawn.HairMesh and Pawn.HairMesh:IsValid() then
        local castShadow = false
        pcall(function() castShadow = Pawn.HairMesh.bCastHiddenShadow end)
        if castShadow ~= true then
            pcall(function() Pawn.HairMesh.bCastHiddenShadow = true end)
        end
        local visible = false
        pcall(function() visible = Pawn.HairMesh.bVisible end)
        if visible then
            pcall(function() Pawn.HairMesh:SetVisibility(false, true) end)
        end
    end
end

-- ===== FOV：瞄准 Hook（防闪屏） =====
RegisterHook("/Script/Pal.PalCharacterCameraComponent:OnStartAim", function()
    AimActive = true
end)
RegisterHook("/Script/Pal.PalCharacterCameraComponent:OnEndAim", function()
    AimActive = false
    AimGraceEnd = os.clock() + 1.0
end)

RegisterHook("/Script/Pal.PalShooterComponent:ChangeIsShooting_ToServer", function(self, id, isShooting, canShootOnRelease)
    pcall(function()
        local s = nil
        pcall(function() s = self:get() end)
        if s == nil then return end
        local shooting = false
        pcall(function()
            if isShooting ~= nil then
                shooting = (type(isShooting) == "boolean") and isShooting or (isShooting:get() == true)
            end
        end)
        if shooting then
            local w = nil
            pcall(function() w = s:GetHasWeapon() end)
            if w == nil then return end
            local nm = w:GetFullName()
            if not nm then return end
            local short = nm:match("^(%S+)_C") or nm
            if BowConditionalKeys[short] and not BowConditionalKeys._pullActive then
                BowConditionalKeys._pullActive = true
            end
        else
            if BowConditionalKeys._pullActive then
                BowConditionalKeys._pullActive = false
            end
        end
    end)
end)


-- FOV 常量
local FOV_BASE_FALLBACK = 90.0

-- FOV 运行时状态
local baseFOV = FOV_BASE_FALLBACK
local fovOffset = 0.0
local fovOffsetMin = FOV_HARD_MIN - FOV_BASE_FALLBACK
local fovOffsetMax = FOV_HARD_MAX - FOV_BASE_FALLBACK
local fovSeeded = false
local setGraphicsSettingsFn = nil
local warnedMissingOptions = false
local LastAppliedFOVDegrees = nil
local LastFOVRidingState = nil

-- 缓存
local cachedPC = nil
local cachedPCM = nil
local cachedCam = nil
local cachedOptions = nil

-- 管理器 FOV 锁
local managerFOVLockActive = false
local managerFOVLockDegrees = nil
local managerFOVLockError = nil

-- 徒步相机 tick 抑制
local footCameraTickSuppressed = false
local footCameraTickCamera = nil
local footCameraOriginalTickEnabled = nil
-- GS 发布节流（值变化或每 30 帧才检查一次）
local fovPublishThrottleTick = 0
local FOV_PUBLISH_INTERVAL = 30
-- 世界加载/角色初始化保护期帧数：期间 FOV 发布跳过，避免与角色初始化/相机挂载竞争
local worldInitProtectFrames = 0

-- 骑乘坐骑相机 FOVProfile
local mountedCameraFOVProfileCamera = nil
local mountedCameraFOVProfile = nil
local mountedCameraFOVProfileSupported = nil
local mountedCameraFOVProfileAppliedDegrees = nil
local mountedCameraFOVProfileIntegrityTick = 0
local mountedCameraFOVProfileIntegrityInterval = 30
local mountedCameraFOVProfileError = nil
local mountedCameraFOVTickSuppressed = false

-- 辅助
local function Valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v
end

local function SameObject(left, right)
    if not Valid(left) or not Valid(right) then return false end
    local ok, same = pcall(function() return left:GetAddress() == right:GetAddress() end)
    return ok and same
end

-- ===== 背武器隐藏：FP 隐藏背后武器模型，TP 恢复 =====
-- 三层抑制（SDK 头文件确认）：
--   ① APalWeaponBase:SetHiddenWeapon(FName, bool) 原生可组合 flag（Pal.hpp:14010）
--   ② BackWeaponModel 演员 SetActorHiddenInGame（Pal.hpp:14002；APalBackWeaponBase
--      无 SetHiddenWeapon UFunction，改其 flag map 不触发 BP 可见性刷新 → 演员级隐藏）
--   ③ stowed 武器主 mesh SetRenderInMainPass(false)（游戏把收起武器的主 mesh 挂背
--      socket 渲染，flag 管不住该 Blueprint 路径）
-- 本项目待验证（首次使用，每路独立 pcall + 失败日志 + 其他层兜底，不猜替代 API）：
--   SetHiddenWeapon / SetActorHiddenInGame / IsHidden / SetRenderInMainPass /
--   反射 TArray ForEach 遍历。顶层 local 配额 +1 → 200/200（上限，勿再加；
--   函数表方法化不占 local，§14.2 同款）。
local BackWeaponHide = {
    flagName = FName("FirstPersonHideBackWeapon"),
    weapons = {},    -- 武器 fullName -> 武器（已打 flag，退出/换持时还原）
    backModels = {}, -- 背模型演员 fullName -> { actor, hidden }（hidden=进入 FP 前快照）
    meshes = {},     -- 武器 fullName -> { mesh, pass }（pass=进入 FP 前 bRenderInMainPass）
    active = false,  -- 当前是否处于隐藏态（骑乘 FP/TP 每帧分支守卫，防全量遍历）
    lastCurrentName = nil, -- 手持武器 fullName（主循环每帧检测切换；Hide/Show 维护）
}

-- 手持武器重新成为 current 时的三路还原（viewmodel 必须可见）；背模型演员
-- 不在此时还原（BackWeaponModel 恒为背部表示，退出 FP 统一还原）
BackWeaponHide.RestoreWeaponLayers = function(weaponFn)
    local w = BackWeaponHide.weapons[weaponFn]
    if w then
        pcall(function() w:SetHiddenWeapon(BackWeaponHide.flagName, false) end)
        BackWeaponHide.weapons[weaponFn] = nil
    end
    local rec = BackWeaponHide.meshes[weaponFn]
    if rec then
        local ok = pcall(function() rec.mesh:SetRenderInMainPass(rec.pass) end)
        if not ok then
            ok = pcall(function() rec.mesh.bRenderInMainPass = rec.pass end)
        end
        BackWeaponHide.meshes[weaponFn] = nil
    end
end

BackWeaponHide.Hide = function(Pawn)
    if not Pawn or not Pawn:IsValid() then return end

    local current = nil
    local sc = Pawn.ShooterComponent
    if sc and sc:IsValid() then
        pcall(function() current = sc:GetHasWeapon() end)
        if not current then
            pcall(function() current = sc.HasWeapon end)
        end
    end
    local currentName = nil
    if current and current:IsValid() then
        currentName = current:GetFullName()
    end

    local selector = nil
    pcall(function() selector = Pawn.LoadoutSelectorComponent end)
    if not selector or not selector:IsValid() then
        BackWeaponHide.lastCurrentName = currentName
        return
    end

    -- 收集武器清单：spawnedWeaponsArray（反射 TArray，ForEach + get() 解包；
    -- 失败只记日志跳过该容器，不猜替代遍历 API）+ 单武器属性
    local list = {}
    pcall(function()
        selector.spawnedWeaponsArray:ForEach(function(_, element)
            local v = nil
            pcall(function() v = element:get() end)
            if v == nil then v = element end
            if v and v:IsValid() then
                list[#list + 1] = v
            end
        end)
    end)
    pcall(function()
        local t = selector.ThrowOtomoPalWeapon
        if t and t:IsValid() then list[#list + 1] = t end
    end)
    pcall(function()
        local d = selector.DummyBall
        if d and d:IsValid() then list[#list + 1] = d end
    end)
    -- （已隐藏的保持隐藏），不隐藏任何未记录武器、不释放任何东西——
    -- 防止把游戏正要放到手上的新武器误隐；current 就位后由主循环每帧
    -- 身份检测立即触发完整 Hide（≤1 帧释放新手持武器）。
    if currentName == nil then
        for _, weapon in ipairs(list) do
            local fn = weapon:GetFullName()
            if BackWeaponHide.weapons[fn] then
                pcall(function() weapon:SetHiddenWeapon(BackWeaponHide.flagName, true) end)
            end
            local mrec = BackWeaponHide.meshes[fn]
            if mrec then
                pcall(function() mrec.mesh:SetRenderInMainPass(false) end)
            end
        end
        for _, brec in pairs(BackWeaponHide.backModels) do
            if brec.actor and brec.actor:IsValid() then
                pcall(function() brec.actor:SetActorHiddenInGame(true) end)
            end
        end
        BackWeaponHide.lastCurrentName = nil
        return
    end

    for _, weapon in ipairs(list) do
        local fn = weapon:GetFullName()
        if currentName ~= nil and fn == currentName then
            -- 手持武器：释放我们写过的 flag/mesh（武器刚上手的过渡）；
            -- 其 BackWeaponModel 不隐藏也不在此还原
            BackWeaponHide.RestoreWeaponLayers(fn)
        else
            -- ① 原生 flag（幂等：已记录只重新断言，不覆盖快照）
            if not BackWeaponHide.weapons[fn] then
                if pcall(function() weapon:SetHiddenWeapon(BackWeaponHide.flagName, true) end) then
                    BackWeaponHide.weapons[fn] = weapon
                end
            else
                pcall(function() weapon:SetHiddenWeapon(BackWeaponHide.flagName, true) end)
            end

            -- ② stowed 主 mesh 渲染通道
            local mesh = nil
            pcall(function() mesh = weapon:GetMainMesh() end)
            if mesh and mesh:IsValid() then
                if not BackWeaponHide.meshes[fn] then
                    local pass = nil
                    pcall(function() pass = mesh.bRenderInMainPass end)
                    if type(pass) ~= "boolean" then pass = true end
                    local ok = pcall(function() mesh:SetRenderInMainPass(false) end)
                    if not ok then
                        ok = pcall(function() mesh.bRenderInMainPass = false end)
                    end
                    if ok then
                        BackWeaponHide.meshes[fn] = { mesh = mesh, pass = pass }
                    end
                else
                    pcall(function() mesh:SetRenderInMainPass(false) end)
                end
            end

            -- ③ 背模型演员
            local bw = nil
            pcall(function() bw = weapon.BackWeaponModel end)
            if bw and bw:IsValid() then
                local bfn = bw:GetFullName()
                if not BackWeaponHide.backModels[bfn] then
                    local hidden = nil
                    local readOK = pcall(function() hidden = bw:IsHidden() end)
                    if not readOK or type(hidden) ~= "boolean" then
                        pcall(function() hidden = bw.bHidden end)
                    end
                    if type(hidden) ~= "boolean" then hidden = false end
                    if pcall(function() bw:SetActorHiddenInGame(true) end) then
                        BackWeaponHide.backModels[bfn] = { actor = bw, hidden = hidden }
                    end
                else
                    pcall(function() bw:SetActorHiddenInGame(true) end)
                end
            end
        end
    end
    BackWeaponHide.lastCurrentName = currentName
    BackWeaponHide.active = true
end

-- 全量还原（无条件执行，不受 FirstPerson/开关门控——§18.9 教训）
BackWeaponHide.Show = function()
    for _, w in pairs(BackWeaponHide.weapons) do
        if w and w:IsValid() then
            pcall(function() w:SetHiddenWeapon(BackWeaponHide.flagName, false) end)
        end
    end
    for _, rec in pairs(BackWeaponHide.backModels) do
        if rec.actor and rec.actor:IsValid() then
            pcall(function() rec.actor:SetActorHiddenInGame(rec.hidden) end)
        end
    end
    for _, rec in pairs(BackWeaponHide.meshes) do
        if rec.mesh and rec.mesh:IsValid() then
            local ok = pcall(function() rec.mesh:SetRenderInMainPass(rec.pass) end)
            if not ok then
                pcall(function() rec.mesh.bRenderInMainPass = rec.pass end)
            end
        end
    end
    BackWeaponHide.weapons = {}
    BackWeaponHide.backModels = {}
    BackWeaponHide.meshes = {}
    BackWeaponHide.lastCurrentName = nil
    BackWeaponHide.active = false
end

local function ClampFOV(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function FindRuntimeObjects()
    local ok = pcall(function()
        cachedPC = FindFirstOf("BP_PalPlayerController_C")
        cachedOptions = FindFirstOf("PalOptionSubsystem")
        cachedCam = nil
        if Valid(cachedPC) then
            pcall(function() cachedPCM = cachedPC.PlayerCameraManager end)
            if Valid(cachedPC.Pawn) then
                pcall(function() cachedCam = cachedPC.Pawn.FollowCamera end)
            end
        end
    end)
    return ok and Valid(cachedPC) and Valid(cachedOptions)
end

local function ReadStructFOV(propertyName)
    if not Valid(cachedOptions) then return nil end
    local ok, value = pcall(function()
        return cachedOptions[propertyName].FOV
    end)
    if ok and type(value) == "number" then return value end
    return nil
end

local function ReadFOVLimits()
    -- 只返回我们自己的 offset 边界（FOV_HARD_MIN/MAX 对应 baseFov），
    -- 不修改原版 OptionLocalStaticSettings.FOV 范围（原版 70~90 保持不变）
    local minimum = FOV_HARD_MIN - baseFOV
    local maximum = FOV_HARD_MAX - baseFOV
    return minimum, maximum
end

-- 首次播种：读 BaseFov；TP 档案未配置时播种成当前原版 FOV（避免启用瞬间跳变）
local function SeedFOV()
    if fovSeeded or not Valid(cachedOptions) then return false end
    local value = nil
    pcall(function() value = cachedOptions.BaseFov end)
    if type(value) == "number" and value >= 60 and value <= 120 then
        baseFOV = value
    else
        baseFOV = FOV_BASE_FALLBACK
    end
    fovOffsetMin, fovOffsetMax = ReadFOVLimits()
    local storedOffset = ReadStructFOV("GraphicsSettings")
        or ReadStructFOV("CommonSettings") or 0.0
    local nativeDegrees = baseFOV + ClampFOV(storedOffset, fovOffsetMin, fovOffsetMax)
    if not ThirdPersonFOVConfigured then
        ThirdPersonFOV = ClampFOV(nativeDegrees, FOV_HARD_MIN, FOV_HARD_MAX)
        ThirdPersonFOVConfigured = true  -- 播种后立即标记：防首次 SaveConfig 失败时世界重载反复从原生值播种
        ConfigDirty = true
    end
    fovSeeded = true
    return true
end

local function CallGraphicsSetter(graphics)
    local graphicsSet, graphicsErr = pcall(function()
        cachedOptions:SetGraphicsSettings(graphics)
    end)
    if not graphicsSet then
        if not Valid(setGraphicsSettingsFn) then
            setGraphicsSettingsFn = StaticFindObject(
                "/Script/Pal.PalOptionSubsystem:SetGraphicsSettings")
        end
        if Valid(setGraphicsSettingsFn) then
            graphicsSet, graphicsErr = pcall(function()
                setGraphicsSettingsFn(cachedOptions, graphics)
            end)
        end
    end
    return graphicsSet, graphicsErr
end

-- 发布 offset 到原版 GS.FOV（幂等：两者已匹配则跳过，不空发完整 graphics delegate）
local function PublishNativeFOVOffset(offset)
    if not Valid(cachedOptions) then FindRuntimeObjects() end
    if not Valid(cachedOptions) then
        return false, "PalOptionSubsystem is unavailable"
    end
    offset = ClampFOV(offset, fovOffsetMin, fovOffsetMax)

    local currentGraphicsOffset = ReadStructFOV("GraphicsSettings")
    local currentCommonOffset = ReadStructFOV("CommonSettings")
    local graphicsMatches = type(currentGraphicsOffset) == "number"
        and math.abs(currentGraphicsOffset - offset) <= 0.001
    local commonMatches = type(currentCommonOffset) == "number"
        and math.abs(currentCommonOffset - offset) <= 0.001
    if graphicsMatches and commonMatches then
        if Valid(cachedCam) then
            pcall(function() cachedCam.FieldOfView = baseFOV + offset end)
        end
        return true
    end

    local graphics = nil
    local common = nil
    local graphicsWrite = pcall(function()
        graphics = cachedOptions.GraphicsSettings
        graphics.FOV = offset
    end)
    local commonWrite = pcall(function()
        common = cachedOptions.CommonSettings
        common.FOV = offset
    end)
    if not graphicsWrite or not commonWrite then
        return false, "FOV option fields were not writable"
    end

    local graphicsSet, graphicsErr = CallGraphicsSetter(graphics)
    if Valid(cachedCam) then
        pcall(function() cachedCam.FieldOfView = baseFOV + offset end)
    end
    return graphicsSet, graphicsErr
end

-- 管理器 FOV 锁（PCM:SetFOV / LockedFOV 兜底通道）
local function SetCameraManagerFOV(degrees)
    if not Valid(cachedPCM) or type(degrees) ~= "number" then return false end
    degrees = ClampFOV(degrees, FOV_HARD_MIN, FOV_HARD_MAX)
    if managerFOVLockActive
        and type(managerFOVLockDegrees) == "number"
        and math.abs(managerFOVLockDegrees - degrees) <= 0.001 then
        return true
    end
    local applied, err = pcall(function() cachedPCM:SetFOV(degrees) end)
    if not applied then
        applied, err = pcall(function() cachedPCM.LockedFOV = degrees end)
    end
    if applied then
        managerFOVLockActive = true
        managerFOVLockDegrees = degrees
        managerFOVLockError = nil
    else
        managerFOVLockError = tostring(err)
    end
    return applied
end

local function ReleaseCameraManagerFOV()
    if not managerFOVLockActive then return true end
    local released, err = false, nil
    if Valid(cachedPCM) then
        released, err = pcall(function() cachedPCM:UnlockFOV() end)
        if not released then
            released, err = pcall(function() cachedPCM.LockedFOV = 0.0 end)
        end
    end
    managerFOVLockActive = false
    managerFOVLockDegrees = nil
    managerFOVLockError = (released or err == nil) and nil or tostring(err)
    return released
end

-- 骑乘坐骑相机 FOVProfile：坐骑相机 tick 会用自身 Walk/Sprint/Aim FOV 目标拉回，
-- 需直接写这些目标 + 必要时抑制 tick（）
local function RestoreMountedCameraFOVProfile()
    local camera = mountedCameraFOVProfileCamera
    local profile = mountedCameraFOVProfile
    local restored = true
    local restoreError = nil
    if Valid(camera) and profile ~= nil then
        restored, restoreError = pcall(function()
            if type(profile.WalkFOV) == "number" then camera.WalkFOV = profile.WalkFOV end
            if type(profile.SprintFOV) == "number" then camera.SprintFOV = profile.SprintFOV end
            if type(profile.AimFOV) == "number" then camera.AimFOV = profile.AimFOV end
            if type(profile.FieldOfView) == "number" then camera.FieldOfView = profile.FieldOfView end
            if type(profile.TickEnabled) == "boolean" then
                camera:SetComponentTickEnabled(profile.TickEnabled)
            end
        end)
    end
    mountedCameraFOVProfileCamera = nil
    mountedCameraFOVProfile = nil
    mountedCameraFOVProfileSupported = nil
    mountedCameraFOVProfileAppliedDegrees = nil
    mountedCameraFOVProfileIntegrityTick = 0
    mountedCameraFOVTickSuppressed = false
    if not restored then
        mountedCameraFOVProfileError = "restore: " .. tostring(restoreError)
    end
    return restored
end

local function CaptureMountedCameraFOVProfile(camera)
    if not Valid(camera) then return false end
    if Valid(mountedCameraFOVProfileCamera)
        and SameObject(mountedCameraFOVProfileCamera, camera)
        and mountedCameraFOVProfile ~= nil then
        return true
    end
    if mountedCameraFOVProfile ~= nil then
        RestoreMountedCameraFOVProfile()
    end
    local profile = {}
    local steadyDriverCount = 0
    local function Capture(propertyName, steadyDriver)
        local read, value = pcall(function() return camera[propertyName] end)
        if read and type(value) == "number" then
            profile[propertyName] = value
            if steadyDriver then steadyDriverCount = steadyDriverCount + 1 end
        end
    end
    Capture("FieldOfView", false)
    Capture("WalkFOV", true)
    Capture("SprintFOV", true)
    Capture("AimFOV", false)
    local tickRead, tickEnabled = pcall(function()
        return camera:IsComponentTickEnabled()
    end)
    if tickRead and type(tickEnabled) == "boolean" then
        profile.TickEnabled = tickEnabled
    end
    mountedCameraFOVProfileCamera = camera
    mountedCameraFOVProfile = profile
    mountedCameraFOVProfileSupported = steadyDriverCount > 0
        or type(profile.TickEnabled) == "boolean"
    mountedCameraFOVProfileAppliedDegrees = nil
    mountedCameraFOVProfileIntegrityTick = 0
    mountedCameraFOVTickSuppressed = false
    if not mountedCameraFOVProfileSupported then
        mountedCameraFOVProfileError =
            "Pal camera exposes no steady FOV targets or tick control"
    end
    return type(profile.FieldOfView) == "number"
end

local function MaintainMountedCameraFOVProfile(camera, degrees)
    camera = camera or cachedCam
    if not Valid(camera) then return false end
    if not Valid(mountedCameraFOVProfileCamera)
        or not SameObject(mountedCameraFOVProfileCamera, camera)
        or mountedCameraFOVProfile == nil then
        CaptureMountedCameraFOVProfile(camera)
    end
    local profile = mountedCameraFOVProfile
    if profile == nil then return false end
    degrees = ClampFOV(
        type(degrees) == "number" and degrees or (baseFOV + fovOffset),
        FOV_HARD_MIN, FOV_HARD_MAX)
    mountedCameraFOVProfileIntegrityTick =
        mountedCameraFOVProfileIntegrityTick + 1
    local lastDegrees = mountedCameraFOVProfileAppliedDegrees
    local endpointChanged = type(lastDegrees) ~= "number"
        or math.abs(degrees - lastDegrees) > 0.001
    local integrityDue = mountedCameraFOVProfileIntegrityTick
        >= mountedCameraFOVProfileIntegrityInterval
    if not endpointChanged and not integrityDue then return true end

    local applied, applyError = pcall(function()
        if type(profile.TickEnabled) == "boolean"
            and (not mountedCameraFOVTickSuppressed or integrityDue) then
            camera:SetComponentTickEnabled(false)
        end
        camera.FieldOfView = degrees
        if type(profile.WalkFOV) == "number" then camera.WalkFOV = degrees end
        if type(profile.SprintFOV) == "number" then camera.SprintFOV = degrees end
        if type(profile.AimFOV) == "number" then camera.AimFOV = degrees end
    end)
    if applied then
        mountedCameraFOVProfileAppliedDegrees = degrees
        mountedCameraFOVProfileIntegrityTick = 0
        mountedCameraFOVTickSuppressed =
            type(profile.TickEnabled) == "boolean"
        mountedCameraFOVProfileError = nil
    else
        mountedCameraFOVProfileError = "apply: " .. tostring(applyError)
    end
    return applied
end

-- 恢复徒步相机 tick（Mod FOV 关闭 / 世界重载时）
-- 注意：必须在 EnsureFootCameraTickSuppressed 之前定义（后者内部调用它，Lua local 顺序）
local function RestoreFootCameraTick()
    if footCameraTickSuppressed and Valid(footCameraTickCamera)
        and type(footCameraOriginalTickEnabled) == "boolean" then
        pcall(function()
            footCameraTickCamera:SetComponentTickEnabled(footCameraOriginalTickEnabled)
        end)
    end
    footCameraTickCamera = nil
    footCameraTickSuppressed = false
    footCameraOriginalTickEnabled = nil
end

-- 抑制徒步相机 tick（幂等：相机未变则跳过），返回是否成功
local function EnsureFootCameraTickSuppressed(camera)
    if not Valid(camera) then return false end
    if footCameraTickSuppressed and Valid(footCameraTickCamera)
        and SameObject(footCameraTickCamera, camera) then
        return true
    end
    RestoreFootCameraTick()
    local ok, enabled = pcall(function()
        return camera:IsComponentTickEnabled()
    end)
    if not ok or type(enabled) ~= "boolean" then return false end
    footCameraOriginalTickEnabled = enabled
    local suppressed = pcall(function() camera:SetComponentTickEnabled(false) end)
    if not suppressed then return false end
    footCameraTickCamera = camera
    footCameraTickSuppressed = true
    return true
end

-- 当前视角是否为第一人称视图（骑乘+FPRiding off 视为第三人称）
local function IsFPViewActive()
    if not FirstPerson then return false end
    local PC = cachedPC
    if not Valid(PC) then PC = FindFirstOf("BP_PalPlayerController_C") end
    if Valid(PC) and Valid(PC.Pawn) then
        local name = PC.Pawn:GetFullName()
        local riding = name and not name:find("BP_Player_Female_C")
        if riding then return FPRiding end
    end
    return true
end

-- 应用当前 FOV（事件 + 每帧幂等保活；瞄准时跳过）
local function ApplyRuntimeFOV(reason)
    if not ModFOVEnabled then return false end
    if not FirstPerson and LogThrottle["fovSwitchGrace"]
        and os.clock() - LogThrottle["fovSwitchGrace"] < 3.0 then
        pcall(function()
            if Valid(cachedOptions) then
                local offset = ClampFOV(ThirdPersonFOV - baseFOV,
                    fovOffsetMin, fovOffsetMax)
                -- 单变量实验：仅值变化时写入+广播（PublishNativeFOVOffset 同款
                -- 匹配判定；消除 TP 3 秒窗口内的同值重复广播）
                local current = ReadStructFOV("GraphicsSettings")
                if not (type(current) == "number"
                    and math.abs(current - offset) <= 0.001) then
                    local gs = cachedOptions.GraphicsSettings
                    gs.FOV = offset
                    local cs = cachedOptions.CommonSettings
                    cs.FOV = offset
                    CallGraphicsSetter(gs)
                end
            end
        end)
        -- 状态诚实化：TP 窗口内发布的就是 TP 目标——若不维护，LastAppliedFOVDegrees
        -- 残留上次 FP 值，EndAim 后 1s 内切回 FP 时 Gate 3 旁路失效（同值误判目标
        -- 未变）→ 宽限整秒拦截 → FP FOV 滞留 90（FOV-DIAG 实测，2026-08-20）
        LastAppliedFOVDegrees = ThirdPersonFOV
        return false
    end
    if AimActive then return false end
    local glidingNow = false
    pcall(function()
        local PC2 = cachedPC
        if not Valid(PC2) then PC2 = FindFirstOf("BP_PalPlayerController_C") end
        if Valid(PC2) and Valid(PC2.Pawn) then
            local jg = PC2.Pawn.PalJetpackGlider
            if Valid(jg) then
                local f = false
                pcall(function() f = (jg.bIsJetpackGliding == true) end)
                if not f then
                    pcall(function() f = (jg:IsJetpackGliding() == true) end)
                end
                glidingNow = f
            end
            if not glidingNow then
                local g = PC2.Pawn.GliderComponent
                if Valid(g) then glidingNow = (g.bIsGliding == true) end
            end
        end
    end)
    if glidingNow then
        pcall(function()
            local PC3 = cachedPC
            if not Valid(PC3) then PC3 = FindFirstOf("BP_PalPlayerController_C") end
            if Valid(PC3) and Valid(PC3.Pawn) then
                local activeCam = PC3.Pawn.FollowCamera
                if Valid(activeCam) then
                    activeCam:StopCameraModifier(nil)
                    local list = nil
                    pcall(function() list = activeCam.CameraModifierList end)
                    if list ~= nil then
                        for i = 1, #list do
                            local m = list[i]
                            if Valid(m) then
                                pcall(function() m.TargetFoV = 0.0 end)
                            end
                        end
                    end
                end
            end
        end)
        -- 继续走下方发布（不 return）→ 滑翔中 FOV = 档案值
    end
    -- 宽限期（OnEndAim 后 1s，防 AimFOV 缓动回程闪屏）仅在 FOV 目标
    -- 未变化时跳过——瞄准中切换视角后目标已变（LastAppliedFOVDegrees 仍是旧视角值）
    -- → 立即发布纠正，否则旧视角 FOV 保持 1 秒（实测：TP 瞄准→切 FP→松右键→FOV
    -- 保持 TP 值 1 秒后才回归 FP 设定值，知识库 §16.6/16.8）
    if os.clock() < AimGraceEnd then
        local degreesNow = IsFPViewActive() and FirstPersonFOV or ThirdPersonFOV
        if LastAppliedFOVDegrees ~= nil
            and math.abs(LastAppliedFOVDegrees - degreesNow) < 0.001 then
            return false
        end
    end
    if not Valid(cachedOptions) or not Valid(cachedCam) then
        FindRuntimeObjects()
    end
    if not Valid(cachedOptions) or not Valid(cachedCam) then return false end
    if not fovSeeded then SeedFOV() end

    local riding = false
    if Valid(cachedPC) and Valid(cachedPC.Pawn) then
        local name = cachedPC.Pawn:GetFullName()
        riding = name and not name:find("BP_Player_Female_C")
    end
    -- 骑乘结束 → 恢复坐骑相机 FOVProfile
    if LastFOVRidingState == true and not riding then
        RestoreMountedCameraFOVProfile()
    end
    LastFOVRidingState = riding

    local degrees = IsFPViewActive() and FirstPersonFOV or ThirdPersonFOV
    local offset = ClampFOV(degrees - baseFOV, fovOffsetMin, fovOffsetMax)

    if riding then
        -- 坐骑相机有自己的 FOV 目标：直接维护其 FOVProfile；GS.FOV 兜底发布
        pcall(function() MaintainMountedCameraFOVProfile(cachedCam, degrees) end)
        pcall(function() PublishNativeFOVOffset(offset) end)
    else
        -- 徒步：通道——直写相机 FOV + 每帧发布 GS（保证 FOV 跟随视角
        -- 只写相机 FOV 不驱动渲染，必须经 GS.FOV 通道）。设置页打开期间也照常发布。游戏刷新 CurrentValue 的误读由 thumb-first 读取 + 显示同步规避
        pcall(function() cachedCam.FieldOfView = degrees end)
        PublishNativeFOVOffset(offset)
        SetCameraManagerFOV(degrees)
    end

    if LastAppliedFOVDegrees == nil
        or math.abs(LastAppliedFOVDegrees - degrees) > 0.001 then
        LastAppliedFOVDegrees = degrees
        print(string.format("[FOV] apply -> %.0f deg (riding=%s)%s",
            degrees, tostring(riding),
            type(reason) == "string" and (" | " .. reason) or ""))
    end
    return true
end

-- 关闭 Mod FOV：恢复坐骑 profile、恢复徒步相机 tick、释放管理器锁、把 TP 档案发布回原版
local function ReleaseFOV(reason)
    RestoreMountedCameraFOVProfile()
    RestoreFootCameraTick()
    ReleaseCameraManagerFOV()
    fovPublishThrottleTick = 0
    LastAppliedFOVDegrees = nil
    LastFOVRidingState = nil
    if fovSeeded then
        local offset = ClampFOV(ThirdPersonFOV - baseFOV, fovOffsetMin, fovOffsetMax)
        pcall(function() PublishNativeFOVOffset(offset) end)
    end
    print("[FOV] released" .. (type(reason) == "string" and (" | " .. reason) or ""))
end

-- 设置页拖动期间的直写通道：
-- 写 GS/Common 结构 offset + 相机 FieldOfView；不调 SetGraphicsSettings，
-- 避免广播 graphics delegate 与设置页 UI 刷新竞态
local function ApplySettingsPageFOV(degrees)
    local offset = ClampFOV(degrees - baseFOV, fovOffsetMin, fovOffsetMax)
    if Valid(cachedOptions) then
        pcall(function() cachedOptions.GraphicsSettings.FOV = offset end)
        pcall(function() cachedOptions.CommonSettings.FOV = offset end)
    end
    if Valid(cachedCam) then
        pcall(function() cachedCam.FieldOfView = degrees end)
    end
end

-- 滑轨接线：更新档案（内部按需应用 + 落盘）。settingPage=true 时只直写相机 FOV
-- 给即时视觉反馈，不发布 GS（避免 CallGraphicsSetter 广播 graphics delegate 触发
-- 游戏刷新设置页 UI → 重建/更新控件 → 与拖动竞争 → EXCEPTION_ACCESS_VIOLATION）
-- 视角门控：只当修改的是"当前视角对应的档案"时才直写/应用；修改非当前视角
-- 档案只保存配置、不碰渲染通道
local function SetFirstPersonFOV(degrees, reason, persist, settingPage)
    if not fovSeeded and Valid(cachedOptions) then SeedFOV() end
    degrees = math.floor(ClampFOV(degrees, FOV_HARD_MIN, FOV_HARD_MAX) + 0.5)
    local changed = math.abs(degrees - FirstPersonFOV) > 0.001
    FirstPersonFOV = degrees
    if changed and persist ~= false then ConfigDirty = true end
    if changed and ModFOVEnabled and IsFPViewActive() then
        if settingPage then
            ApplySettingsPageFOV(degrees)
        else
            ApplyRuntimeFOV(type(reason) == "string" and reason or "FP FOV changed")
        end
    end
    return changed
end

-- 视角门控：当前视角为第三人称时直写/应用；当前视角为第一人称时，
-- 原生 TP 行拖动已被游戏写进 GS → 只存档案 + 用当前（第一人称）档案重新发布
-- 渲染通道把画面纠正回来
local function SetThirdPersonFOV(degrees, reason, persist, settingPage)
    if not fovSeeded and Valid(cachedOptions) then SeedFOV() end
    degrees = math.floor(ClampFOV(degrees, FOV_HARD_MIN, FOV_HARD_MAX) + 0.5)
    local changed = math.abs(degrees - ThirdPersonFOV) > 0.001
    ThirdPersonFOV = degrees
    if changed and persist ~= false then ConfigDirty = true end
    if changed and ModFOVEnabled then
        if IsFPViewActive() then
            if settingPage then
                -- 第一人称中拖动原生 TP 行：游戏已把 TP offset 写进 GS（原生 OnFOVChanged），
                -- 只存档案不够 → 用当前（第一人称）档案重新发布渲染通道把画面纠正回来
                ApplySettingsPageFOV(FirstPersonFOV)
            end
            -- 非设置页路径（如 SetDefault）：档案已存；ApplyRuntimeFOV 本就按视角选值，
            -- 无需在此发布
        elseif settingPage then
            ApplySettingsPageFOV(degrees)
        else
            ApplyRuntimeFOV(type(reason) == "string" and reason or "TP FOV changed")
        end
    end
    return changed
end

-- Mod FOV 总开关（设置页开关）
local function SetModFOV(enabled)
    if enabled == ModFOVEnabled then return end
    ModFOVEnabled = enabled
    ConfigDirty = true
    if ModFOVEnabled then
        FindRuntimeObjects()
        if not fovSeeded then SeedFOV() end
        ApplyRuntimeFOV("ModFOV enabled")
        print("[FOV] ModFOV ON")
    else
        ReleaseFOV("ModFOV disabled")
        print("[FOV] ModFOV OFF")
    end
end

-- ===== 开关逻辑（热键与设置页共用） =====

-- F6 / 设置页开关：第一人称开关（enable/disable 共用）
local function SetFP(enabled)
    if enabled == FirstPerson then return end
    FirstPerson = enabled
    ConfigDirty = true
    -- 切换时刻标记（ApplyRuntimeFOV 的 TP 3 秒发布宽限用——
    -- 飞行中 FP→TP 的 FOV 竞争闪屏：我们发布 TP 值 vs 游戏飞行 FOV 缓动 → 抖动）
    LogThrottle["fovSwitchGrace"] = os.clock()

    if FirstPerson then
        -- 开启：需要有效的 Pawn 和相机，否则回滚
        local Pawn = GetPawn()
        if not Pawn or not Pawn:IsValid() then
            FirstPerson = false
            return
        end
        local Camera = Pawn.FollowCamera
        if not Camera or not Camera:IsValid() then
            FirstPerson = false
            return
        end
        PendingOff = false
        AttachCameraToFPSocket(Camera, Pawn, false)
        local sc = Pawn.ShooterComponent
        if sc and sc:IsValid() then
            sc:SetOverrideRotationFlags(true, false)
        end
        LastActivePawnName = Pawn:GetFullName()
        HideFP(Pawn)
        BackWeaponHide.Hide(Pawn)
        print("[FP] ON")
        -- 切换后立即应用 FOV（设置页期间由无广播保活接管，无需此处）
        if not FP_SettingsPageActive then
            ApplyRuntimeFOV("view switched to first person")
        end
    else
        -- 关闭：不依赖 Pawn/相机是否有效，交给 LoopAsync 用保存的状态还原
        PendingOff = true
        print("[FP] OFF pending...")
    end
end

-- Alt+F6 / 设置页开关：骑乘第一人称开关（enable/disable 共用）
local function SetFPRiding(enabled)
    if enabled == FPRiding then return end
    FPRiding = enabled
    ConfigDirty = true
    print("[FP] RidingFP: " .. tostring(FPRiding))

    if not FirstPerson then return end
    local Pawn = GetPawn()
    if not Pawn then return end
    local PC = FindFirstOf("BP_PalPlayerController_C")
    if not PC or not PC:IsValid() then return end

    if FPRiding then
        if PC.Pawn and PC.Pawn:IsValid() and PC.Pawn:GetFullName() ~= Pawn:GetFullName() then
            local MCam = PC.Pawn.FollowCamera
            if MCam and MCam:IsValid() and SavedMountCam ~= MCam then
                if SavedMountCam and SavedMountCam:IsValid() then
                    SavedMountCam:K2_DetachFromComponent(1, 1, 1, false)
                    if SavedMountParent and SavedMountParent:IsValid() then
                        SavedMountCam:K2_AttachTo(SavedMountParent, SavedMountSocket or FName(""), 2, false)
                    end
                end
                SavedMountCam = MCam
                SavedMountParent = MCam.AttachParent
                SavedMountSocket = MCam.AttachSocketName
                SavedMountName = PC.Pawn:GetFullName()
                AttachCameraToFPSocket(MCam, Pawn, true)
                print("[FP] stole mount cam on toggle")
            end
        end
    else
        if SavedMountCam and SavedMountCam:IsValid() then
            SavedMountCam:K2_DetachFromComponent(1, 1, 1, false)
            if SavedMountParent and SavedMountParent:IsValid() then
                SavedMountCam:K2_AttachTo(SavedMountParent, SavedMountSocket or FName(""), 2, false)
            end
            SavedMountCam.bUsePawnControlRotation = false
            SavedMountCam, SavedMountParent, SavedMountSocket, SavedMountName = nil, nil, nil, nil
            print("[FP] restored mount cam on toggle")
        end
    end

    -- 骑乘视角切换后立即应用 FOV（设置页期间由无广播保活接管）
    if not FP_SettingsPageActive then
        ApplyRuntimeFOV("riding view changed")
    end
end

-- ============================================================
-- 原生可重映射热键
-- 注册原生 Player Action → 出现在游戏原生"控制设置"页 → 可重映射 → 键位由原生
-- KeyConfigSettings 持久化。输入用 WasInputKeyJustPressed 轮询（不依赖 Action 注册）。
-- ============================================================
local FP_HOTKEY_ACTION = FName("PalFPModToggleFirstPerson")
local FP_HOTKEY_LABEL = "First Person"
local FP_HOTKEY_MESSAGE_ID = "SETTING_KEY_PalFPModToggleFirstPerson"
local FP_HOTKEY_DEFAULT_KEY = { KeyName = FName("F6") }

local RIDING_HOTKEY_ACTION = FName("PalFPModToggleRidingFirstPerson")
local RIDING_HOTKEY_LABEL = "Riding First Person"
local RIDING_HOTKEY_MESSAGE_ID = "SETTING_KEY_PalFPModToggleRidingFirstPerson"
local RIDING_HOTKEY_DEFAULT_KEY = { KeyName = FName("None") }  -- 默认不绑定
local UNBOUND_KEY = { KeyName = FName("None") }  -- 手柄默认不绑定（显示用）

local KeySettings = {
    page = nil,
    pagePending = false,
    pageCandidate = nil,
    pageAttempts = 0,
    pageMaxAttempts = 60,
    attached = false,
    actionRegistered = false,
    actionRetryFrames = 0,
    inputRefreshTick = 0,
    inputRefreshInterval = 15,
    pageWasVisible = false,
    inputReleaseBlockFrames = 0,
    mainKey = {},       -- actionName -> { KeyName = ... }（键鼠 category 0）
    secondaryKey = {},  -- actionName -> { KeyName = ... }（键鼠 category 0）
    gamepadMainKey = {},      -- actionName -> { KeyName = ... }（手柄 category 1）
    gamepadSecondaryKey = {}, -- actionName -> { KeyName = ... }（手柄 category 1）
    downState = {},     -- actionName -> 上一帧是否按住（自检上升沿）
    lastToggleTime = {}, -- actionName -> 上次触发时间（去抖）
}

-- ① 注册原生 Action（AddActionMapping 内部 AddUnique 防重；不调 SaveKeyMappings，
--    保存权交给原生 KeyConfigSettings）
local function RegisterHotkeyAction(actionName, defaultKey)
    local inputSettings = StaticFindObject("/Script/Engine.Default__InputSettings")
    if not Valid(inputSettings) then return false end
    local mapping = {
        ActionName = actionName,
        Key = defaultKey,
        bShift = false,
        bCtrl = false,
        bAlt = false,
        bCmd = false,
    }
    local added, addError = pcall(function()
        inputSettings:AddActionMapping(mapping, true)
    end)
    if not added then
        local addActionMapping = StaticFindObject(
            "/Script/Engine.InputSettings:AddActionMapping")
        if not Valid(addActionMapping) then return false end
        added = pcall(function() addActionMapping(inputSettings, mapping, true) end)
    end
    return added
end

local function EnsureHotkeyActions()
    if KeySettings.actionRegistered then return true end
    if KeySettings.actionRetryFrames > 0 then
        KeySettings.actionRetryFrames = KeySettings.actionRetryFrames - 1
        return false
    end
    KeySettings.actionRetryFrames = 60
    local ok = RegisterHotkeyAction(FP_HOTKEY_ACTION, FP_HOTKEY_DEFAULT_KEY)
        and RegisterHotkeyAction(RIDING_HOTKEY_ACTION, RIDING_HOTKEY_DEFAULT_KEY)
    if ok then
        KeySettings.actionRegistered = true
        KeySettings.actionRetryFrames = 0
        print("[FP-KEY] native actions registered (F6 / unbound)")
    else
        print("[FP-KEY] action registration FAILED, will retry")
    end
    return ok
end

-- ② 读取已保存键位（兜底链：KeyConfigSettings → PlayerInput → 默认键）
local function UnwrapMapValue(value)
    if value == nil then return nil end
    local unwrapped = nil
    local ok = pcall(function() unwrapped = value:get() end)
    return ok and unwrapped or value
end

local function CopyKeyName(key)
    if key == nil then return nil end
    local keyName = nil
    pcall(function() keyName = key.KeyName end)
    if keyName == nil then return nil end
    return { KeyName = keyName }
end

local function CacheActionKeys(actionName, keys, inputCategory)
    if keys == nil then return false end
    local mainKey, secondaryKey = nil, nil
    pcall(function()
        mainKey = CopyKeyName(keys.MainKey)
        secondaryKey = CopyKeyName(keys.SecondaryKey)
    end)
    if mainKey == nil and secondaryKey == nil then return false end
    if inputCategory == 1 then
        KeySettings.gamepadMainKey[actionName] = mainKey
        KeySettings.gamepadSecondaryKey[actionName] = secondaryKey
    else
        KeySettings.mainKey[actionName] = mainKey
        KeySettings.secondaryKey[actionName] = secondaryKey
    end
    return true
end

local function ReadActionKeyFromOptions(actionName, inputCategory)
    if not Valid(cachedOptions) then return false end
    local keys = nil
    local ok = pcall(function()
        local mappings = nil
        if inputCategory == 1 then
            mappings = cachedOptions.KeyConfigSettings.GamePadActionMappings
        else
            mappings = cachedOptions.KeyConfigSettings.MouseAndKeyboardActionMappings
        end
        -- action 未注册时 TMap:Find 抛 "Map key not found"（高频错误源），先 Contains 检查
        if mappings:Contains(actionName) then
            keys = UnwrapMapValue(mappings:Find(actionName))
        end
    end)
    return ok and CacheActionKeys(actionName, keys, inputCategory)
end

local function ReadActionKeyFromPlayerInput(playerInput, actionName, inputCategory)
    if not Valid(playerInput) then return false end
    local keys = nil
    local ok = pcall(function()
        keys = playerInput:GetActionConfigKeys(actionName, inputCategory)
    end)
    return ok and CacheActionKeys(actionName, keys, inputCategory)
end

local function RefreshHotkeyKeys()
    KeySettings.inputRefreshTick = 0
    local playerInput = nil
    if Valid(cachedPC) then
        pcall(function() playerInput = cachedPC.PlayerInput end)
    end
    if not Valid(playerInput) then
        pcall(function() playerInput = FindFirstOf("PalPlayerInput") end)
    end
    local function RefreshAction(actionName, defaultKey)
        -- 仅 action 注册成功后读 options/playerInput（未注册时 TMap:Find/GetActionConfigKeys
        -- 高频抛错），否则直接 fallback 默认键
        local ready = false
        if KeySettings.actionRegistered then
            ready = ReadActionKeyFromOptions(actionName, 0)
            if not ready and Valid(playerInput) then
                ready = ReadActionKeyFromPlayerInput(playerInput, actionName, 0)
            end
        end
        if not ready then
            KeySettings.mainKey[actionName] = CopyKeyName(defaultKey)
            KeySettings.secondaryKey[actionName] = nil
        end
        -- 手柄（category 1）：无默认绑定，未读到则保持 unbound
        local gpReady = false
        if KeySettings.actionRegistered then
            gpReady = ReadActionKeyFromOptions(actionName, 1)
            if not gpReady and Valid(playerInput) then
                gpReady = ReadActionKeyFromPlayerInput(playerInput, actionName, 1)
            end
        end
        if not gpReady then
            KeySettings.gamepadMainKey[actionName] = nil
            KeySettings.gamepadSecondaryKey[actionName] = nil
        end
    end
    RefreshAction(FP_HOTKEY_ACTION, FP_HOTKEY_DEFAULT_KEY)
    RefreshAction(RIDING_HOTKEY_ACTION, RIDING_HOTKEY_DEFAULT_KEY)
end

-- 控制设置页打开/关闭瞬间屏蔽输入（避免改键时触发切换）
local function HotkeysBlockedByKeySettings()
    local page = KeySettings.page
    if not Valid(page) then page = KeySettings.pageCandidate end
    local visible, mounted = false, false
    if Valid(page) then
        pcall(function()
            visible = page:IsVisible()
            mounted = Valid(page:GetParent())
        end)
    end
    if visible and mounted then
        KeySettings.pageWasVisible = true
        KeySettings.inputReleaseBlockFrames = 2
        return true
    end
    if KeySettings.pageWasVisible then
        KeySettings.pageWasVisible = false
        KeySettings.inputReleaseBlockFrames = 2
    end
    if KeySettings.inputReleaseBlockFrames > 0 then
        KeySettings.inputReleaseBlockFrames = KeySettings.inputReleaseBlockFrames - 1
        return true
    end
    return false
end

-- ③ 轮询按键 → 调共享 SetFP/SetFPRiding
-- 用状态检测（IsInputKeyDown 每帧返回按住状态，不会丢帧）+ 自检上升沿 + 去抖，
-- 避免 WasInputKeyJustPressed 帧边沿错位 / LoopAsync 同帧重复触发导致的概率性无响应。
-- 保留 WasInputKeyJustPressed 作为快速连点的 OR 兜底。
local function PollHotkeyAction(actionName, toggleFn)
    -- 键鼠 + 手柄四键（键盘/手柄共用同一 action，去抖与上升沿按 action 共享）
    local keys = {
        KeySettings.mainKey[actionName],
        KeySettings.secondaryKey[actionName],
        KeySettings.gamepadMainKey[actionName],
        KeySettings.gamepadSecondaryKey[actionName],
    }

    -- 按住状态（状态检测，不依赖帧边沿）
    local down = false
    for _, key in ipairs(keys) do
        if key ~= nil and not down then
            pcall(function() down = cachedPC:IsInputKeyDown(key) end)
        end
    end

    -- 帧边沿兜底（快速连点可能被状态轮询错过）
    local justPressed = false
    for _, key in ipairs(keys) do
        if key ~= nil and not justPressed then
            pcall(function() justPressed = cachedPC:WasInputKeyJustPressed(key) end)
        end
    end

    local prevDown = KeySettings.downState[actionName] or false
    KeySettings.downState[actionName] = down

    local shouldToggle = justPressed or (down and not prevDown)
    if not shouldToggle then return end
    -- 去抖：防同一次按下被重复处理（LoopAsync 同帧多次触发 / 边沿残留）
    local now = os.clock()
    local last = KeySettings.lastToggleTime[actionName] or 0
    if now - last < 0.08 then return end
    KeySettings.lastToggleTime[actionName] = now
    toggleFn()
end

local function PollHotkeys()
    if not Valid(cachedPC) then FindRuntimeObjects() end
    if not Valid(cachedPC) then return end
    if not KeySettings.actionRegistered then
        -- Action 注册失败也继续轮询（默认键兜底），不能因注册失败跳过热键功能
        EnsureHotkeyActions()
    end
    local blocked = HotkeysBlockedByKeySettings()
    KeySettings.inputRefreshTick = KeySettings.inputRefreshTick + 1
    if blocked or KeySettings.inputRefreshTick >= KeySettings.inputRefreshInterval then
        RefreshHotkeyKeys()
    end
    if blocked then return end

    PollHotkeyAction(FP_HOTKEY_ACTION, function()
        SetFP(not FirstPerson)
    end)
    PollHotkeyAction(RIDING_HOTKEY_ACTION, function()
        SetFPRiding(not FPRiding)
    end)
end

-- ④ 控制设置页注入：构造前把 action 加进 InputActionsMap_KM，游戏原生 Construct
--    自动建行（委托绑定完整，改键可直接用）→ 我们只设图标/标签/可见性
local KEY_SETTINGS_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/" ..
    "WBP_Key_Settings.WBP_Key_Settings_C"

local function PrepareKeySettingsPage(page)
    if not Valid(page) then return false end
    local ok, err = pcall(function()
        -- 仅注入键鼠区（InputActionsMap_KM）——手柄区（InputActionsMap_GP）
        -- 不再注入：原版手柄键位已满，行显示空绑定仍触发"按键重复"确认弹窗
        -- （ClearGamepadBindings 实测未解决），直接移除手柄区两行
        local keyboardActions = page.InputActionsMap_KM
        if not keyboardActions:Contains(FP_HOTKEY_ACTION) then
            keyboardActions:Add(FP_HOTKEY_ACTION, nil)
        end
        if not keyboardActions:Contains(RIDING_HOTKEY_ACTION) then
            keyboardActions:Add(RIDING_HOTKEY_ACTION, nil)
        end
    end)
    return ok
end

local function FindHotkeyRow(page, actionName, inputCategory)
    if not Valid(page) then return nil end
    local row = nil
    pcall(function()
        local actions = page.InputActionsMap_KM
        if inputCategory == 1 then actions = page.InputActionsMap_GP end
        row = UnwrapMapValue(actions:Find(actionName))
    end)
    return Valid(row) and row or nil
end

local function AttachKeySettingsPage(page)
    -- 仅键鼠区两行（手柄区行已不再注入，无 GP 行可挂接）
    local fpRow = FindHotkeyRow(page, FP_HOTKEY_ACTION, 0)
    local ridingRow = FindHotkeyRow(page, RIDING_HOTKEY_ACTION, 0)
    if not Valid(fpRow) or not Valid(ridingRow) then
        return false, "native rows not ready"
    end
    local ok, err = pcall(function()
        if not Valid(fpRow.BP_PalTextBlock_Name)
            or not Valid(ridingRow.BP_PalTextBlock_Name) then
            error("labels unavailable")
        end
        RefreshHotkeyKeys()
        local fpKey = KeySettings.mainKey[FP_HOTKEY_ACTION]
            or KeySettings.secondaryKey[FP_HOTKEY_ACTION]
            or FP_HOTKEY_DEFAULT_KEY
        local ridingKey = KeySettings.mainKey[RIDING_HOTKEY_ACTION]
            or KeySettings.secondaryKey[RIDING_HOTKEY_ACTION]
            or RIDING_HOTKEY_DEFAULT_KEY
        pcall(function() fpRow:SetKeyIcon(fpKey, 0) end)
        pcall(function() ridingRow:SetKeyIcon(ridingKey, 0) end)
        -- 热键行名 SetText 快速初值 + 主循环保活
        -- （MaintainHotkeyRowNames，0.5s 节流）。实证链：2.8.2 去掉 SetText →
        -- 行名恒为 key 本体（游戏翻译表无模组动作条目，原生不翻译）→ SetText 必需；
        -- 2.8.3 采样诊断 → 游戏在 attach 后 ≤0.5s 内一次性写入 key 本体，之后不再
        -- 刷新，胜负成块延续。保活让我们的写入永远晚于游戏写入 → 稳定显示
        fpRow.BP_PalTextBlock_Name:SetText(FText(LangUI:t("HotkeyFP")))
        ridingRow.BP_PalTextBlock_Name:SetText(FText(LangUI:t("HotkeyRiding")))
        fpRow:SetVisibility(0)
        ridingRow:SetVisibility(0)
    end)
    if not ok then return false, tostring(err) end
    KeySettings.page = page
    KeySettings.attached = true
    print("[FP-KEY] key settings attached (KM only): " .. FP_HOTKEY_LABEL
        .. " / " .. RIDING_HOTKEY_LABEL)
    return true
end

-- 热键行名保活（主循环每帧调用，内部 0.5s 节流）。
-- 实证：游戏在 attach 后 ≤0.5s 内一次性把行名写回 key 本体（SETTING_KEY_...），
-- 之后不再刷新。本函数保证我们的写入永远晚于游戏写入 → 稳定显示模组语言文本。
-- 开销：仅热键页对象存在（attached + Valid）期间每 0.5s 2 次 SetText；页面销毁后
-- Valid 为假自动停止。
local HotkeyMaintainLast = 0
local function MaintainHotkeyRowNames()
    if not KeySettings.attached then return end
    local page = KeySettings.page
    if not Valid(page) then return end
    local nowt = os.clock()
    if nowt - HotkeyMaintainLast < 0.5 then return end
    HotkeyMaintainLast = nowt
    local fpRow = FindHotkeyRow(page, FP_HOTKEY_ACTION, 0)
    if Valid(fpRow) then
        pcall(function() fpRow.BP_PalTextBlock_Name:SetText(FText(LangUI:t("HotkeyFP"))) end)
    end
    local ridingRow = FindHotkeyRow(page, RIDING_HOTKEY_ACTION, 0)
    if Valid(ridingRow) then
        pcall(function() ridingRow.BP_PalTextBlock_Name:SetText(FText(LangUI:t("HotkeyRiding"))) end)
    end
end

local function ProcessKeySettingsAttach()
    if not KeySettings.pagePending then return end
    local page = KeySettings.pageCandidate
    if not Valid(page) then
        KeySettings.pagePending = false
        KeySettings.pageCandidate = nil
        return
    end
    KeySettings.pageAttempts = KeySettings.pageAttempts + 1
    local ok, err = AttachKeySettingsPage(page)
    if ok then
        KeySettings.pagePending = false
        KeySettings.pageCandidate = nil
        return
    end
    if KeySettings.pageAttempts >= KeySettings.pageMaxAttempts then
        KeySettings.pagePending = false
        KeySettings.pageCandidate = nil
        print("[FP-KEY] key settings attach timed out: " .. tostring(err))
    end
end

pcall(function()
    NotifyOnNewObject(KEY_SETTINGS_PATH, function(page)
        PrepareKeySettingsPage(page)
        KeySettings.pageCandidate = page
        KeySettings.pageAttempts = 0
        KeySettings.pagePending = true
        KeySettings.attached = false
    end)
end)

-- ⑤ 标签改写：已移除 TextBlock:SetText hook（两次崩溃 dump 均指向该 hook——游戏每次
-- SetText 时触发，设置页关闭瞬间处理销毁中的 TextBlock 导致原生访问违规崩溃）。
-- 改键弹窗标题显示原始 SETTING_KEY_ ID（可接受），控制设置页行标签仍由
-- AttachKeySettingsPage 直接 SetText 正常显示。

-- 启动即注册 Action（InputSettings 未就绪时由 PollHotkeys 重试）
pcall(function()
    EnsureHotkeyActions()
end)

-- 加载配置（FirstPerson/FPRiding/ModFOVEnabled/FOV 档案）
LoadConfig()

-- ===== 统一每帧循环 =====
-- 设置页关闭下降沿检测状态（）：FP_SettingsPageActive 由 SettingsUITick 维护，
-- 此处只在主循环内做边沿检测，下降沿触发一次 ApplyRuntimeFOV
local FPSettingsPageWasActive = false

LoopAsync(0, function()
    -- ▸▸▸ 原生热键轮询（含 Action 注册重试）与按键页注入重试
    PollHotkeys()
    ProcessKeySettingsAttach()
    -- 热键行名保活（内部 0.5s 节流，仅热键页存在期间执行）
    MaintainHotkeyRowNames()

    -- ▸▸▸ 第一人称：PawnLost 检测
    if FirstPerson and not PendingOff then
        if not GetPawn() then
            -- 只重置状态，不还原相机：Pawn 短暂失效（切图/骑乘/重生瞬间）时若还原相机，
            -- 会在"还原第三人称→下一帧重新抢回"之间反复，造成镜头闪烁。
            -- 真正的世界重载清理由 OnCompleteInitializeParameter 钩子负责。
            LastActivePawnName = nil
            if not PawnLostLogged then
                PawnLostLogged = true
                print("[FP] pawn lost, waiting for world reload...")
            end
            return  -- Pawn 消失时 FOV 也不跑，防止主菜单失控
        elseif PawnLostLogged then
            PawnLostLogged = false
        end
    end

    -- ▸▸▸ 第一人称：PendingOff 收尾
    if PendingOff then
        local Pawn = GetPawn()
        RestoreMountCamToDefault()
        RestoreCameraToDefault(Pawn)
        if Pawn then
            ShowFP(Pawn)
        end
        -- F6 关闭时还原武器偏移（此后 FirstPerson=false 主循环
        -- 武器偏移分支不再执行；不还原则 mesh 残留偏移穿帮）
        -- 去掉 WeaponOffsetEnabled 门控——开关关闭后退出也必须还原，
        -- 否则已写偏移永久残留（关闭状态 TP 穿帮、进出 FP 无法恢复，实测）；
        -- RestoreWeaponOffsets 现为全量还原（所有记录过的武器），幂等
        RestoreWeaponOffsets(Pawn)
        BackWeaponHide.Show()
        LastActivePawnName = nil
        FirstPerson = false
        PendingOff = false
        SaveConfig()
        print("[FP] OFF done")
        return
    end

    -- ▸▸▸ 第一人称：核心逻辑
    if FirstPerson then
        local Pawn = GetPawn()
        if not Pawn then return end

        local PawnName = Pawn:GetFullName()

        local PCam = Pawn.FollowCamera
        if PCam and PCam:IsValid() then
            PCam.bUsePawnControlRotation = true
        end
        local sc = Pawn.ShooterComponent
        if sc and sc:IsValid() then
            sc:SetOverrideRotationFlags(true, false)
        end

        local PC = FindFirstOf("BP_PalPlayerController_C")
        if not PC or not PC:IsValid() then return end

        local ActivePawn = PC.Pawn
        if not ActivePawn or not ActivePawn:IsValid() then return end
        local ActiveName = ActivePawn:GetFullName()

        if ActiveName ~= LastActivePawnName then
            if SavedMountName then
                local om = FindFirstOf(SavedMountName:match("^(%S+)"))
                if om and om:IsValid() then
                    om.bUseControllerRotationYaw = false
                end
            end
            if SavedMountCam and SavedMountCam:IsValid() and SavedMountName ~= ActiveName then
                SavedMountCam:K2_DetachFromComponent(1, 1, 1, false)
                if SavedMountParent and SavedMountParent:IsValid() then
                    SavedMountCam:K2_AttachTo(SavedMountParent, SavedMountSocket or FName(""), 2, false)
                end
                SavedMountCam.bUsePawnControlRotation = false
                SavedMountCam, SavedMountParent, SavedMountSocket, SavedMountName = nil, nil, nil, nil
            end

            if ActiveName ~= PawnName then
                if FPRiding then
                    StealMountCamera(ActivePawn, Pawn)
                end
            end

            LastActivePawnName = ActiveName
        end

        if ActiveName ~= PawnName then
            local asc = ActivePawn.ShooterComponent
            if asc and asc:IsValid() then
                asc:SetOverrideRotationFlags(true, false)
            end
        end

        if SavedMountCam and SavedMountCam:IsValid() and ActiveName == SavedMountName then
            SavedMountCam.bUsePawnControlRotation = true
        end

        -- 头部显隐 + 背武器显隐（镜像同分支；active 守卫防每帧全量遍历）
        if ActiveName ~= PawnName then
            if FPRiding then
                HideFP(Pawn)
                if not BackWeaponHide.active then BackWeaponHide.Hide(Pawn) end
            else
                ShowFP(Pawn)
                if BackWeaponHide.active then BackWeaponHide.Show() end
            end
        else
            HideFP(Pawn)
            if not BackWeaponHide.active then BackWeaponHide.Hide(Pawn) end
        end

        -- ▸▸▸ 相机防闪保活（每帧校验挂载父级，确实被游戏重挂时才重新挂载）
        --   v3.5（无保活）步行从不闪，证明步行时游戏不会重挂相机；之前用 socket 名
        --   比较可能每帧误判、反复 detach+attach，反而制造了白帧。这里改为"父级是否
        --   还是身体 Mesh"，只有相机真的被游戏挂回 CameraBoom/坐骑时才纠正。
        if ActiveName == PawnName then
            local FCam = Pawn.FollowCamera
            if FCam and FCam:IsValid() and not IsCameraAttachedTo(FCam, Pawn.Mesh) then
                AttachCameraToFPSocket(FCam, Pawn, false)
            end
        elseif FPRiding and ActivePawn and ActivePawn:IsValid() then
            local MCam = ActivePawn.FollowCamera
            if MCam and MCam:IsValid() and not IsCameraAttachedTo(MCam, Pawn.Mesh) then
                StealMountCamera(ActivePawn, Pawn)
            end
        end

        -- ▸▸▸ 头部动画保活（每 60 帧，路线A核心保证）
        --   游戏若重置隐藏/AnimTick，重新断言
        FPHeadMaintainTick = FPHeadMaintainTick + 1
        if FPHeadMaintainTick >= 60 then
            FPHeadMaintainTick = 0
            MaintainFPHead(Pawn)
            -- 背武器三路保活（同 tick；仅 FP 视角断言——TP 骑乘不隐藏）
            if IsFPViewActive() then
                BackWeaponHide.Hide(Pawn)
            end
        end

        -- ▸▸▸ 背武器：每帧检测手持武器变化（v2.12a 修复切换后空手）
        --   切换瞬间 current 就位后 ≤1 帧触发完整 Hide → 新武器立即释放、
        --   旧武器上背即隐藏；60 帧维护只做保活重断言。active 守卫防 TP 骑乘触发。
        local bwShooter = Pawn.ShooterComponent
        local bwCurrentName = nil
        if bwShooter and bwShooter:IsValid() then
            local bwWeapon = nil
            pcall(function() bwWeapon = bwShooter:GetHasWeapon() end)
            if not bwWeapon then
                pcall(function() bwWeapon = bwShooter.HasWeapon end)
            end
            if bwWeapon and bwWeapon:IsValid() then
                bwCurrentName = bwWeapon:GetFullName()
            end
        end
        if BackWeaponHide.active and bwCurrentName ~= BackWeaponHide.lastCurrentName then
            BackWeaponHide.Hide(Pawn)
        end

        -- ▸▸▸ 武器偏移（仅大型武器）。仅 FP 视角设置偏移（徒步或
        --   骑乘+FPRiding）；非 FP 视角（TP 骑乘）还原已写偏移——
        --   偏移写进 mesh 持久属性，只停写不还原则 TP 下残留穿帮（用户两轮实测）
        if WeaponOffsetEnabled then
            WeaponFrameCount = WeaponFrameCount + 1
            local shooter = Pawn.ShooterComponent
            if shooter and shooter:IsValid() then
                local weapon = nil
                pcall(function() weapon = shooter:GetHasWeapon() end)
                if not weapon then
                    pcall(function() weapon = shooter.HasWeapon end)
                end

                if weapon and weapon:IsValid() then
                    local weaponName = weapon:GetFullName()
                    local shortName = weaponName:match("^(%S+)_C") or weaponName

                    -- 匹配大型武器配置（最长关键字优先，避免 GrenadeLauncher 被 Grenade 误匹配）
                    local config, bestLen, bestKey = nil, 0, nil
                    for key, cfg in pairs(LargeWeaponConfig) do
                        if shortName:find(key, 1, true) and #key > bestLen then
                            config, bestLen, bestKey = cfg, #key, key
                        end
                    end

                    if config then
                        -- 弓拉弓状态兜底轮询（hook 外第二信号源）。
                        -- ObjectDump 实证：拉弓链路 = ChangeIsShooting_ToServer RPC +
                        -- bChangeIsShootingPulling/bIsShooting/bIsShootingHold 属性 +
                        -- SetShootingHold(IsHold) + IsShooting()。每 5 帧读属性，
                        -- 观察拉弓时哪个信号为 true（读到的任一 true 即置位，日志标注 poll）。
                        if BowConditionalKeys[bestKey] and WeaponFrameCount % 5 == 0 then
                            local pulling = false
                            pcall(function() pulling = (shooter.bChangeIsShootingPulling == true) end)
                            if not pulling then
                                pcall(function() pulling = (shooter.bIsShooting == true) end)
                            end
                            if not pulling then
                                pcall(function() pulling = (shooter:IsShooting() == true) end)
                            end
                            if pulling and not BowConditionalKeys._pullActive then
                                BowConditionalKeys._pullActive = true
                            end
                        end
                        local mesh = nil
                        pcall(function() mesh = weapon:GetMainMesh() end)

                        if mesh and mesh:IsValid() then
                            if IsFPViewActive() then
                                -- 首次设置前捕获 mesh 原始 transform
                                -- （默认 0,0,0），TP/关闭时还原用
                                if not WeaponOrigTransforms[shortName] then
                                    WeaponOrigTransforms[shortName] = { loc = nil, rot = nil, mesh = nil }
                                    -- 记录 mesh 引用——全量还原不再依赖
                                    -- GetHasWeapon 现取（旧武器已不在手上也能还原）
                                    WeaponOrigTransforms[shortName].mesh = mesh
                                    pcall(function()
                                        local rl, rr = mesh.RelativeLocation, mesh.RelativeRotation
                                        WeaponOrigTransforms[shortName].loc = {X=rl.X or 0, Y=rl.Y or 0, Z=rl.Z or 0}
                                        WeaponOrigTransforms[shortName].rot = {Pitch=rr.Pitch or 0, Yaw=rr.Yaw or 0, Roll=rr.Roll or 0}
                                    end)
                                end

                                -- 弓条件偏移——弓平时握持有单手锚点不穿帮，
                                -- 仅在瞄准姿态（AimActive，右键按住）或拉弓（左键按住）时
                                -- 应用偏移。
                                -- 探测结论：IsInputKeyDown 被 Enhanced
                                -- Input 旁路（left 恒 false）、GetChargeRate 等 30 候选函数
                                -- 四路 FindFunction 全 NONE（ObjectDump 阳性对照验证可信）。
                                -- 改用 PalShooterComponent:PullTrigger/
                                -- ReleaseTrigger/BowPullAnimeEnd 事件 hook 锁存拉弓状态
                                -- （BowConditionalKeys._pullActive），见顶部 hook 注册区。
                                if BowConditionalKeys[bestKey] and not (AimActive or BowConditionalKeys._pullActive) then
                                    -- 非瞄准/拉弓姿态：还原（与 TP 还原同款三路写）
                                    local orig = WeaponOrigTransforms[shortName]
                                    if orig and orig.loc and orig.rot then
                                        pcall(function() mesh.RelativeLocation = orig.loc end)
                                        pcall(function() mesh.RelativeRotation = orig.rot end)
                                        pcall(function() mesh:K2_SetRelativeRotation(orig.rot, false, {}, false) end)
                                        pcall(function() mesh:SetRelativeRotation(orig.rot) end)
                                    end
                                else
                                    -- 直接应用偏移（武器 RelativeLocation 通常为 0,0,0，偏移即目标值）
                                    local tgtX = config.offsetX
                                    local tgtY = config.offsetY
                                    local tgtZ = config.offsetZ
                                    pcall(function()
                                        mesh.RelativeLocation = {X=tgtX, Y=tgtY, Z=tgtZ}
                                    end)

                                    -- 旋转：只写幂等的相对旋转（每帧写同一绝对值，不累积）。
                                    -- ⚠️ 删除了第 4 路 K2_SetWorldRotation(当前世界旋转+偏移)：
                                    -- 当前世界旋转已含上次叠加的偏移，每帧再加 = 武器持续自转
                                    -- （实测 rot 值不断跳变）。相对旋转是覆盖式赋值，不会累加。
                                    pcall(function()
                                        mesh.RelativeRotation = {Pitch=config.pitch, Yaw=config.yaw, Roll=config.roll}
                                    end)
                                    pcall(function()
                                        mesh:K2_SetRelativeRotation({Pitch=config.pitch, Yaw=config.yaw, Roll=config.roll}, false, {}, false)
                                    end)
                                    pcall(function()
                                        mesh:SetRelativeRotation({Pitch=config.pitch, Yaw=config.yaw, Roll=config.roll})
                                    end)

                                end
                            else
                                -- 非 FP 视角（TP 骑乘）→ 还原已写偏移。
                                -- 仅还原"曾设置过偏移"的武器（orig 有记录）；从未被偏移
                                -- 的武器不碰（还原会覆盖游戏默认 transform）。幂等三路写。
                                local orig = WeaponOrigTransforms[shortName]
                                if orig and orig.loc and orig.rot then
                                    pcall(function() mesh.RelativeLocation = orig.loc end)
                                    pcall(function() mesh.RelativeRotation = orig.rot end)
                                    pcall(function() mesh:K2_SetRelativeRotation(orig.rot, false, {}, false) end)
                                    pcall(function() mesh:SetRelativeRotation(orig.rot) end)
                                end
                            end
                        end
                    end
                end
            end
        end

        -- 阻止抚摸/睡觉动画切视角
        local VT = PC:GetViewTarget()
        if VT and VT:IsValid() then
            local vtName = VT:GetFullName()
            if vtName:find("PettingCamera") or vtName:find("PlayerBedCamera") then
                pcall(function() PC:SetViewTargetWithBlend(Pawn, 0, 0, 0, false) end)
            end
        end
    end

    -- ▸▸▸ FOV：设置页关闭下降沿 → 完整档案恢复兜底
    -- （ 起保活连续运行不再暂停，此分支仅为关闭瞬间的保险；
    --  页面已关，广播无 UI 竞态（ 崩溃仅发生在页面打开期），
    --  且正确走骑乘档案分支）
    if FP_SettingsPageActive then
        FPSettingsPageWasActive = true
    elseif FPSettingsPageWasActive then
        FPSettingsPageWasActive = false
        if ModFOVEnabled then
            ApplyRuntimeFOV("settings page closed")
        end
    end

    -- ▸▸▸ FOV：每帧保活（ 根治冻结——不再暂停）
    -- 设置页打开期间用无广播直写路径（ 崩溃根因是"设置页期间广播
    --  SetGraphicsSettings"；无广播直写在  拖动期已实测安全）：
    --   → 拖动 3 帧内生效、画面永不偏离档案、退出页面无缝衔接、视角切换立即生效
    -- 非设置页期间用广播路径（ApplyRuntimeFOV，幂等跳过）
    if ModFOVEnabled then
        if FP_SettingsPageActive then
            if not Valid(cachedOptions) or not Valid(cachedCam) then
                FindRuntimeObjects()
            end
            local degrees = IsFPViewActive() and FirstPersonFOV or ThirdPersonFOV
            ApplySettingsPageFOV(degrees)
            -- 骑乘期间不动相机管理器锁（mount cam FOV 由骑乘档案单独管理，
            -- 设置页期间锁管理器会覆盖它；退出设置后下降沿走骑乘分支纠正）
            if not FPRiding then
                SetCameraManagerFOV(degrees)
            end
        else
            ApplyRuntimeFOV()
        end
    end

    -- 延迟写配置（避免热键回调中同步磁盘 I/O 卡顿；仅成功才清标志，失败下帧重试）
    if ConfigDirty and SaveConfig() then
        ConfigDirty = false
    end
end)

-- ===== 角色初始化钩子 =====
RegisterHook("/Script/Pal.PalPlayerCharacter:OnCompleteInitializeParameter", function(context)
    local Character = context:get()
    if not Character or not Character:IsValid() then return end

    ExecuteWithDelay(500, function()
        if not Character or not Character:IsValid() then return end
        LoadConfig()
        -- 强制还原干净第三人称
        RestoreCameraToDefault(Character)
        ShowFP(Character)
        BackWeaponHide.Show()
        RestoreMountCamToDefault()

        -- 重置 FOV 状态（世界重载）
        ReleaseFOV("world reload reset")
        fovSeeded = false
        LastAppliedFOVDegrees = nil
        LastFOVRidingState = nil
        if ModFOVEnabled then
            FindRuntimeObjects()
            if not fovSeeded then SeedFOV() end
            ApplyRuntimeFOV("world reload")
        end

        -- 之前是第一人称则重新应用
        if FirstPerson then
            local Pawn = GetPawn()
            if Pawn and Pawn:IsValid() then
                PendingOff = false
                local Camera = Pawn.FollowCamera
                if Camera and Camera:IsValid() then
                    AttachCameraToFPSocket(Camera, Pawn, false)
                end
                local sc = Pawn.ShooterComponent
                if sc and sc:IsValid() then
                    sc:SetOverrideRotationFlags(true, false)
                end
                LastActivePawnName = Pawn:GetFullName()
                HideFP(Pawn)
                BackWeaponHide.Hide(Pawn)
                print("[FP] auto-restored after world load")
            else
                FirstPerson = false
                SaveConfig()
                print("[FP] pawn mismatch, reset")
            end
        end
    end)
end)

-- ============================================================
-- 设置页注入：WBP_Graphic_Settings（3 开关 + 2 滑轨）
-- ============================================================
--  模式：NotifyOnNewObject 回调只入队（回调时子控件未绑定），
-- 由帧循环重试注入（60 次上限）。RegisterHook 对蓝图 Construct 无效，不能走 hook。
local GRAPHIC_SETTINGS_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/" ..
    "WBP_Graphic_Settings.WBP_Graphic_Settings_C"

-- 备用行候选（平台/特性相关打包行，运行时已折叠才可复用）
-- ✅  全复刻 ：任意隐藏行拿来即 SetSlider——该函数会把
-- 行内容切为滑轨形态（ListContentSlider），无论原始是开关/档位/滑轨。之前 
-- 的 sliderVisible 类型检查是自废武功（错误假设档位行不能转滑轨）。
local SLIDER_SPARE_CANDIDATES = {
    "WBP_OptionSettings_DrawDIstance_MapObject",
    "WBP_OptionSettings_LODBias",
    "WBP_OptionSettings_FrameGeneration",
    "WBP_OptionSettings_NVIDIAReflex",
    "WBP_OptionSettings_Arachnophobia",
}
--  弃用：Mod FOV 开关行已移除，不再有开关 spare 需求。
-- 保留定义以备将来复用（不删代码）。
local SWITCH_SPARE_CANDIDATES = {
    -- Mod FOV 开关的 spare 候选（列表）
    "WBP_OptionSettings_FrameGeneration",
    "WBP_OptionSettings_NVIDIAReflex",
    "WBP_OptionSettings_Arachnophobia",
}

-- 滑轨拖动检测已移除：改 thumb 优先读取（见 ReadSliderValue），无需拖动检测。
-- （此前 Slider 捕获 hook / 值保活方案无效：拖动被强行拉回，已废弃）

local SettingsUI = {
    page = nil,
    pagePending = false,
    pageCandidate = nil,
    pageAttempts = 0,
    pageMaxAttempts = 60,
    attached = false,
    usedRows = {},
    rows = {},       -- name -> row
    contents = {},   -- name -> ListContentSlider（滑轨）
    switches = {},   -- name -> ListContentSwitch（开关）
    lastSwitch = { FP = nil, RidingFP = nil, ModFOV = nil },
    switchPending = {},   -- 开关两帧去抖暂存（）
    switchAddrs = {},     -- 开关行地址跟踪（：行重建检测）
    lastSlider = { FirstPersonFOV = nil, ThirdPersonFOV = nil },
    sliderCorrectTime = {},   -- name -> os.clock()（显示纠正节流，防每帧 SetValueInt）
    pageAttachTime = 0,       -- 页面最近附着时间（用于附着后 5s 强制纠正显示）
    sliderInitDone = {},      -- name -> bool（该滑轨已完成初始化纠正或被轮询接管）
    -- 行列表结构检测状态（纯取证，不改行为）
    treeCheckTick = 0,        -- D4：Children 数检测节拍
    treeChildCount = nil,     -- D4：上次记录的行列表 Children 数
    -- 布局测量可信重试状态（baseH < 40 = GetDesiredSize 未完成，
    -- 平移被推迟；SettingsUITick 1s 节流重跑直到可信）
    layoutPendingRetry = false,  -- 布局等待重试（上次测量不可信）
    layoutRetryTime = 0,         -- 最近一次布局重试时刻（os.clock）
    -- notify 后注入延迟（Slate 树构造缓冲）
    pageNotifyTime = 0,          -- notify 时刻（os.clock）；注入前需等待 ≥0.3s
}

local function IsValidObj(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

-- 滑轨显示同步（对齐 ）：SetValueInt 用档案值刷新 CurrentValue+thumb+标签。
-- 仅从安全事件点调用（轮询变化后 / MaintainSliderDisplay 保活），不做每帧无条件刷新——
-- 避免打断用户拖动。先校验 Slider 子控件有效再调 SetValueInt（防对半构造/档位态控件调
-- UFunction 致 native 崩）。
local function RefreshSliderDisplay(content, value)
    if not IsValidObj(content) then return false end
    local slider = nil
    pcall(function() slider = content.Slider end)
    if not IsValidObj(slider) then
        -- 形态非滑轨（档位态）/子控件未就绪：直接写 CurrentValue（避免调 UFunction）
        pcall(function() content.CurrentValue = value end)
        return false
    end
    local ok = false
    pcall(function() ok = content:SetValueInt(value, FOV_HARD_MIN, FOV_HARD_MAX) end)
    if not ok then
        -- 兜底：直接写 CurrentValue
        pcall(function() content.CurrentValue = value end)
    end
    return ok
end

-- 滑轨显示保活（每帧）：游戏刷新可能把渲染 FOV 写进 CurrentValue。
-- 仅当 thumb == 档案（用户未拖动）且 CurrentValue 偏离时纠正（2s 节流）。
-- 原生 FOV 行（TP）游戏自己管值，我们只纠正 CurrentValue 显示（不改 thumb）。
local function MaintainSliderDisplay(content, profile, key)
    if not IsValidObj(content) then return end
    local thumb = nil
    pcall(function() thumb = content.Slider:GetValue() end)
    if type(thumb) ~= "number" then return end
    local thumbInt = math.floor(math.min(FOV_HARD_MAX, math.max(FOV_HARD_MIN, thumb)) + 0.5)
    if math.abs(thumbInt - profile) > 0.001 then
        -- thumb 偏离档案——区分"用户拖动"与"游戏初始化"
        -- 用户拖动：CurrentValue 未提交（thumb 是拖动中值）→ 不打断，交给轮询
        -- 游戏初始化：thumb==CurrentValue（如 GS 原生 70 vs 档案 140）→ 可纠正
        -- （旧逻辑一律 return，导致 Mod 关闭/启动期行显示停在原生值不纠正）
        -- 双条件——仅"注入后 5s 内"且"该滑轨未被接管"才允许 init 纠正。
        -- 拖动期 thumb==CurrentValue 也成立（游戏实时同步），时间窗口 + 接管状态
        -- 才能可靠区分；轮询 APPLY 后置 sliderInitDone=true → 用户已接管，永不纠正
        local cv = nil
        pcall(function() cv = content.CurrentValue end)
        if type(cv) == "number" and math.abs(cv - thumb) < 0.01 then
            local key2 = key or "?"
            if not SettingsUI.sliderInitDone[key2]
                and os.clock() - SettingsUI.pageAttachTime <= 5 then
                local now = os.clock()
                local last = SettingsUI.sliderCorrectTime[key2]
                if type(last) ~= "number" or now - last >= 2.0 then
                    SettingsUI.sliderCorrectTime[key2] = now
                    SettingsUI.sliderInitDone[key2] = true
                    RefreshSliderDisplay(content, profile)
                end
            end
        end
        return
    end
    local cv = nil
    pcall(function() cv = content.CurrentValue end)
    if type(cv) ~= "number" or math.abs(cv - profile) > 0.001 then
        local now = os.clock()
        local last = SettingsUI.sliderCorrectTime[key or "?"]
        if type(last) == "number" and now - last < 2.0 then return end
        SettingsUI.sliderCorrectTime[key or "?"] = now
        RefreshSliderDisplay(content, profile)
    end
end

-- 行是否已被占用（GetAddress 比对）
local function IsRowUsed(row, excluded)
    for _, u in ipairs(excluded) do
        if IsValidObj(u) then
            local same = false
            pcall(function() same = row:GetAddress() == u:GetAddress() end)
            if same then return true end
        end
    end
    return false
end

-- 获取滑轨行：① 优先 FindSpareOptionRow（任意隐藏行，SetSlider 即切为滑轨形态）
-- ② 没有隐藏行才克隆 template（非 FOV 滑轨行类，游戏不初始化 → 不写 130）
local function AcquireSliderRow(page, template, owningPlayer, excluded)
    for _, prop in ipairs(SLIDER_SPARE_CANDIDATES) do
        local row = nil
        local hidden = false
        pcall(function()
            row = page[prop]
            hidden = IsValidObj(row) and not row:IsVisible()
        end)
        if IsValidObj(row) and hidden and not IsRowUsed(row, excluded) then
            -- 不检查行内子控件当前形态——SetSlider 会切到滑轨形态
            table.insert(excluded, row)
            print("[FP-UI] slider row <- spare: " .. tostring(prop))
            return row
        end
    end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not IsValidObj(lib) or not IsValidObj(template) then return nil end
    local cls = nil
    pcall(function() cls = template:GetClass() end)
    if not IsValidObj(cls) then return nil end
    local row = nil
    pcall(function() row = lib:Create(page, cls, owningPlayer) end)
    if IsValidObj(row) then
        table.insert(excluded, row)
        print("[FP-UI] slider row <- clone template: " .. tostring(template:GetFullName()))
        return row
    end
    return nil
end

--  恢复启用：第一人称武器偏移开关 spare 行（ 曾因 Mod FOV
-- 开关行移除而闲置）。
-- 获取开关行：优先备用开关候选（需含 ListContentSwitch 子控件），否则克隆原生开关行类
local function AcquireSwitchRow(page, switchTemplate, owningPlayer, excluded)
    for _, prop in ipairs(SWITCH_SPARE_CANDIDATES) do
        local row = nil
        local hidden = false
        pcall(function()
            row = page[prop]
            hidden = IsValidObj(row) and not row:IsVisible()
        end)
        if IsValidObj(row) and hidden and not IsRowUsed(row, excluded) then
            local sw = nil
            pcall(function() sw = row.WBP_OptionSettings_ListContentSwitch end)
            if IsValidObj(sw) then
                table.insert(excluded, row)
                return row
            end
        end
    end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not IsValidObj(lib) or not IsValidObj(switchTemplate) then return nil end
    local cls = nil
    pcall(function() cls = switchTemplate:GetClass() end)
    if not IsValidObj(cls) then return nil end
    local row = nil
    pcall(function() row = lib:Create(page, cls, owningPlayer) end)
    if IsValidObj(row) then
        table.insert(excluded, row)
        return row
    end
    return nil
end

-- 移动行：RemoveChild → AddChild 到锚点行父容器末尾，复制锚点行 Slot.Padding
local function MoveOptionRow(row, anchorRow)
    local ok, err = pcall(function()
        local oldParent = row:GetParent()
        local targetParent = anchorRow:GetParent()
        if not IsValidObj(targetParent) then error("anchor parent unavailable") end
        local targetSlot = anchorRow.Slot
        if not IsValidObj(targetSlot) then error("anchor slot unavailable") end
        local tp = targetSlot.Padding
        local padding = { Left = tp.Left, Top = tp.Top, Right = tp.Right, Bottom = tp.Bottom }
        if IsValidObj(oldParent) then
            oldParent:RemoveChild(row)
        end
        local slot = targetParent:AddChild(row)
        if slot ~= nil then
            slot:SetPadding(padding)
        end
    end)
    if not ok then
        print("[FP-UI] row move failed: " .. tostring(err))
    end
    -- + 移动结果日志：行地址 + 父容器 children 数变化（确认移动真实发生；
    return ok
end

-- 真重排：把 rows 依次插到 anchorRow 之后（镜头区顶部），锚点之后的原生行整体下移。
-- UPanelWidget 无原生 insert API（仅 AddChild/RemoveChild/RemoveChildAt），因此：
--   ① 把我们的行从旧父容器移除 → ② 从尾往前移除锚点后的所有行并记录各自 Slot.Padding
--   → ③ 追加我们的行（复制锚点 Padding）→ ④ 恢复尾部行（各自 Padding）。
-- 失败返回 false，由调用方回退到追加式布局（非致命）。
-- ⚠️ 已停用：批量移除/重加锚点后原生行的真重排，曾导致打开设置页概率性闪退
-- （Abort signal received，大量 UE4SS 帧；页面构造/布局期间批量改 Slate 树不稳定）。
-- 保留本函数仅供将来在页面完全稳定后（延迟重排）复用。
local function InsertRowsAtAnchor(anchorRow, rows)
    local ok, err = pcall(function()
        local panel = anchorRow:GetParent()
        if not IsValidObj(panel) then error("anchor parent unavailable") end

        -- ① 先把我们的行从旧父容器移除（spare/克隆行可能在 panel 内任意位置）
        for _, row in ipairs(rows) do
            local oldParent = row:GetParent()
            if IsValidObj(oldParent) then
                oldParent:RemoveChild(row)
            end
        end

        -- 锚点索引（在移除我们的行之后计算，保证索引准确）
        local anchorIndex = panel:GetChildIndex(anchorRow)
        if anchorIndex < 0 then error("anchor index unavailable") end

        -- 复制锚点行的 Slot.Padding，作为我们 5 行的统一间距
        local anchorPadding = nil
        pcall(function()
            local slot = anchorRow.Slot
            if IsValidObj(slot) then
                local p = slot.Padding
                anchorPadding = { Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom }
            end
        end)

        -- ② 收集锚点之后的所有行（含各自 Padding），从尾往前移除
        local tail = {}
        local count = panel:GetChildrenCount()
        for i = count - 1, anchorIndex + 1, -1 do
            local w = panel:GetChildAt(i)
            if IsValidObj(w) then
                local padding = nil
                pcall(function()
                    local slot = w.Slot
                    if IsValidObj(slot) then
                        local p = slot.Padding
                        padding = { Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom }
                    end
                end)
                panel:RemoveChildAt(i)
                table.insert(tail, 1, { widget = w, padding = padding })
            end
        end

        -- ③ 追加我们的 5 行（复制锚点 Padding）
        for _, row in ipairs(rows) do
            local slot = panel:AddChild(row)
            if slot ~= nil and anchorPadding ~= nil then
                pcall(function() slot:SetPadding(anchorPadding) end)
            end
        end

        -- ④ 恢复尾部行（各自 Padding）
        for _, t in ipairs(tail) do
            local slot = panel:AddChild(t.widget)
            if slot ~= nil and t.padding ~= nil then
                pcall(function() slot:SetPadding(t.padding) end)
            end
        end
    end)
    if not ok then
        print("[FP-UI] reorder into camera section failed: " .. tostring(err))
    end
    return ok
end

-- 拦截 WBP_Graphic_Settings_C:SetDefault，
-- 用户点"恢复默认"时同步重置 Mod 设置到默认值。全局只注册一次。
local function EnsureGraphicsDefaultHook()
    if SettingsUI.graphicsDefaultHooked then return true end
    local ok = pcall(function()
        RegisterHook(
            '/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/' ..
                'WBP_Graphic_Settings.WBP_Graphic_Settings_C:SetDefault',
            function()
                -- 重置所有 Mod 设置到默认
                SettingsUI.lastSwitch = { FP = FirstPerson, RidingFP = FPRiding, ModFOV = ModFOVEnabled }
                SettingsUI.lastSlider = { FirstPersonFOV = FirstPersonFOV, ThirdPersonFOV = ThirdPersonFOV }
                SetFP(false)
                SetFPRiding(false)
                -- ：Mod FOV 开关行已移除（ModFOVEnabled 恒 true），恢复默认不再关闭
                SetFirstPersonFOV(DEFAULT_FP_FOV, 'Restore to Default', true)
                SetThirdPersonFOV(DEFAULT_TP_FOV, 'Restore to Default', true)
                -- ：表方法化（local 直引在 hook 回调里是 global nil，见
                -- SettingsUI.MaintainSettingsRows 挂表处注释；pcall 防维护期异常）
                pcall(function() SettingsUI.MaintainSettingsRows() end)
                RefreshSliderDisplay(SettingsUI.contents.FirstPersonFOV, FirstPersonFOV)
                RefreshSliderDisplay(SettingsUI.contents.ThirdPersonFOV, ThirdPersonFOV)
            end)
    end)
    SettingsUI.graphicsDefaultHooked = ok
    return ok
end

-- 单行版布局（）：仅 FP FOV 滑轨 spare 行（Mod FOV 已移除）。
-- spare 行已通过 MoveOptionRow 追加到父容器末尾（树位置不变）→ SetRenderTranslation
-- 视觉平移搬到 First Person 行正下方（镜头晃动之前）：
--   ① FP FOV 行上移 fpMoveUp = 区间(FirstPerson+1 .. fpFOVIdx-1)行高总和
--   ② 该区间内原生行下移 insertedSpan = FP FOV 行高（修正后），给其腾位
--  插入行视觉填入锚点下方、中间行整体下移）
local function ApplySettingsLayout()
    if not IsValidObj(SettingsUI.page) then
        print("[FP-UI] layout skipped: page unavailable")
        return false
    end
    local fpFOVRow = SettingsUI.rows.FirstPersonFOV
    local fpRow = SettingsUI.rows.FP  -- First Person 原生开关行（锚点）
    if not IsValidObj(fpFOVRow) or not IsValidObj(fpRow) then
        print("[FP-UI] layout skipped: spare/FP rows unavailable")
        return false
    end
    local ok = pcall(function()
        local panel = fpRow:GetParent()
        local fpIdx = panel:GetChildIndex(fpRow)
        local fpFOVIdx = panel:GetChildIndex(fpFOVRow)
        if fpIdx < 0 or fpFOVIdx < 0 or fpFOVIdx <= fpIdx then
            error("row indices unavailable (fp=" .. tostring(fpIdx) .. " fpFOV=" .. tostring(fpFOVIdx) .. ")")
        end

        -- 测量一行高度（含 slot padding）
        -- baseH 修正（v3.19.3 实证方案）：滑轨行 GetDesiredSize 返回紧凑内容高而非外层行
        -- pitch → 任何行 span < baseH×0.75 用 baseH 兜底
        local function RowSpan(row)
            local h = 0.0
            local d = row:GetDesiredSize()
            if type(d.Y) == "number" and d.Y > 1.0 then h = d.Y end
            pcall(function()
                local s = row.Slot
                if IsValidObj(s) then
                    local p = s.Padding
                    if type(p.Top) == "number" then h = h + p.Top end
                    if type(p.Bottom) == "number" then h = h + p.Bottom end
                end
            end)
            return h > 1.0 and h or 64.0  -- 兜底 64px
        end
        local baseH = RowSpan(fpRow)
        -- 测量可信阈值——GetDesiredSize 在 Slate layout pass 完成前
        -- 返回 0（仅 padding，baseH=4.0 假测量；实测 06:48-07:01 状态 A/B 随机交替，
        -- 假测量致 FP FOV 错误上移 28px 覆盖"显示同伴特效"行）。正常行高 50（状态 B
        -- 实测），40 为安全区分点。不可信 → 不执行任何平移，标记重试（SettingsUITick
        -- 1s 节流重跑，SetRenderTranslation 绝对覆盖幂等自愈）。
        if baseH < 40.0 then
            SettingsUI.layoutPendingRetry = true
            return false
        end
        SettingsUI.layoutPendingRetry = false
        local function RowSpanFixed(row)
            local span = RowSpan(row)
            if span < baseH * 0.75 then span = baseH end
            return span
        end

        -- FP FOV 行上移量：越过区间 (fpIdx+1 .. fpFOVIdx-1) 的全部行。
        -- 单行版区间端点天然排除自身，无 v3.19.5 的 row ~= modFOVRow 排除失败问题
        -- 不可见行（存档内懒显示/分区标签，实测最终都会显示）
        -- 此前完全跳过 → 上移不足 → FP FOV 与中间行重叠（08-15 隔离测试：
        -- spans=[25:50 26:50 27:hid 28:39.7 29:50] fpMoveUp=189.7 vs 正常 239.7）。
        -- 现在不可见行按 baseH 计入（真实高度 39.7~50，误差 ≤10px，不再整行重叠）
        local fpMoveUp = 0.0
        for i = fpIdx + 1, fpFOVIdx - 1 do
            local row = panel:GetChildAt(i)
            if IsValidObj(row) then
                local vis = false
                pcall(function() vis = row:IsVisible() end)
                local span = RowSpanFixed(row)
                if not vis then span = baseH end
                fpMoveUp = fpMoveUp + span
            end
        end
        -- 插入行高度（修正后）：中间行整体下移量
        local insertedSpan = RowSpanFixed(fpFOVRow)

        -- 下移区：First Person 之后到 FP FOV 之前的行整体下移，给 FP FOV 腾位。
        -- 不再跳过不可见行——hid 行最终显示且占据空间，
        -- 不位移则与上移后的 FP FOV 重叠（与上移量修复同源）
        for i = fpIdx + 1, fpFOVIdx - 1 do
            local row = panel:GetChildAt(i)
            if IsValidObj(row) then
                row:SetRenderTranslation({X = 0.0, Y = insertedSpan})
            end
        end
        -- FP FOV 行上移：翻到 First Person 正下方
        fpFOVRow:SetRenderTranslation({X = 0.0, Y = -fpMoveUp})
    end)
    if not ok then return false end
    print("[FP-UI] layout applied (SetRenderTranslation): FP FOV moved under First Person")
    return true
end
-- 注入设置页
local function InjectSettingsPage(page)
    -- 开头更新 FOV 限制
    if Valid(cachedOptions) then
        fovOffsetMin, fovOffsetMax = ReadFOVLimits()
    end
    if not IsValidObj(page) then return false, "page is invalid" end
    EnsureGraphicsDefaultHook()

    -- 直接拿原生行，不克隆
    local fpRow = page.WBP_OptionSettings_CameraRecoil        -- → "First Person" 开关
    local ridingRow = page.WBP_OptionSettings_AutoContrast    -- → "Riding First Person" 开关
    local fovRow = page.WBP_OptionSettings_FOV                -- → "Third Person FOV"（原生，改名+扩范围）

    if not IsValidObj(fpRow) or not IsValidObj(ridingRow) or not IsValidObj(fovRow) then
        return false, "native CameraRecoil/AutoContrast/FOV rows unavailable"
    end

    -- 整个附着逻辑包在 pcall 里，内部用 error() 做校验
    local movedRows = {}   -- {row, oldParent}：失败回滚用（，防残留行被重试克隆成重复行）
    local ok, err = pcall(function()
        local owningPlayer = nil
        pcall(function() owningPlayer = page:GetOwningPlayer() end)
        local excluded = SettingsUI.usedRows

        -- ：Mod Field of View 开关行已移除（模组默认使用 FP FOV）——
        -- 仅注入 FP FOV 滑轨 spare 行（ 同款）
        local fpFOVRow = AcquireSliderRow(page, fovRow, owningPlayer, excluded)
        if not IsValidObj(fpFOVRow) then error("no spare row for First Person FOV") end

        -- 追加 spare 行到 FOV 锚点父容器末尾
        local function NoteMove(row)
            local p = nil
            pcall(function() p = row:GetParent() end)
            table.insert(movedRows, { row = row, parent = p })
        end
        NoteMove(fpFOVRow)
        if not MoveOptionRow(fpFOVRow, fovRow) then error("First Person FOV row move failed") end

        -- 配置开关（ SetSwitcher + SetVisibility + SetText）
        fpRow:SetSwitcher(FirstPerson)
        fpRow:SetVisibility(0)
        fpRow.BP_PalTextBlock_Name:SetText(FText(LangUI:t("FirstPerson")))
        local fpSw = fpRow.WBP_OptionSettings_ListContentSwitch
        if not IsValidObj(fpSw) then error("First Person switch child was not created") end
        SettingsUI.switches.FP = fpSw

        ridingRow:SetSwitcher(FPRiding)
        ridingRow:SetVisibility(0)
        ridingRow.BP_PalTextBlock_Name:SetText(FText(LangUI:t("FirstPersonRiding")))
        local ridingSw = ridingRow.WBP_OptionSettings_ListContentSwitch
        if not IsValidObj(ridingSw) then error("First Person Riding switch child was not created") end
        SettingsUI.switches.RidingFP = ridingSw

        -- 第一人称武器偏移开关（spare 开关行，MoveOptionRow 追加到
        -- 列表末尾 = 【其他】分组下方；AcquireSwitchRow 复用）。
        -- 树位置=追加末尾、视觉位置=列表末尾（无重排），SetRenderTranslation 布局不受影响
        -- （新行树序在 fpFOVIdx 之后，fpMoveUp 区间不含它）。
        local wpRow = AcquireSwitchRow(page, fpRow, owningPlayer, excluded)
        if not IsValidObj(wpRow) then error("no spare row for weapon offset switch") end
        NoteMove(wpRow)
        if not MoveOptionRow(wpRow, fovRow) then error("weapon offset row move failed") end
        wpRow:SetSwitcher(WeaponOffsetEnabled)
        wpRow:SetVisibility(0)
        wpRow.BP_PalTextBlock_Name:SetText(FText(LangUI:t("WeaponOffset")))
        local wpSw = wpRow.WBP_OptionSettings_ListContentSwitch
        if not IsValidObj(wpSw) then error("weapon offset switch child was not created") end
        SettingsUI.switches.WeaponOffset = wpSw
        SettingsUI.rows.WeaponOffset = wpRow
        SettingsUI.lastSwitch.WeaponOffset = WeaponOffsetEnabled

        -- 配置 FP FOV 滑轨（ SetSlider）
        fpFOVRow:SetSlider(FirstPersonFOV, FOV_HARD_MIN, FOV_HARD_MAX, 1.0, true)
        fpFOVRow:SetVisibility(0)
        fpFOVRow.BP_PalTextBlock_Name:SetText(FText(LangUI:t("FirstPersonFOV")))
        local fpContent = fpFOVRow.WBP_OptionSettings_ListContentSlider
        if not IsValidObj(fpContent) then error("First Person FOV slider child was not created") end
        SettingsUI.contents.FirstPersonFOV = fpContent
        local fpSlider = fpContent.Slider
        if not IsValidObj(fpSlider) then error("First Person FOV Slider widget is unavailable") end
        fpSlider:SetMinValue(FOV_HARD_MIN)
        fpSlider:SetMaxValue(FOV_HARD_MAX)

        -- 配置 TP FOV（原生 FOV 行改名 + 扩 Slider 范围）
        fovRow.BP_PalTextBlock_Name:SetText(FText(LangUI:t("ThirdPersonFOV")))
        local tpContent = fovRow.WBP_OptionSettings_ListContentSlider
        if not IsValidObj(tpContent) then error("Third Person FOV slider child is unavailable") end
        SettingsUI.contents.ThirdPersonFOV = tpContent
        local tpSlider = tpContent.Slider
        if not IsValidObj(tpSlider) then error("Third Person FOV Slider widget is unavailable") end
        tpSlider:SetMinValue(FOV_HARD_MIN)
        tpSlider:SetMaxValue(FOV_HARD_MAX)

        -- 保存行引用
        SettingsUI.rows.FP = fpRow
        SettingsUI.rows.RidingFP = ridingRow
        SettingsUI.rows.FirstPersonFOV = fpFOVRow
        SettingsUI.rows.ThirdPersonFOV = fovRow

        -- 基线
        SettingsUI.lastSwitch.FP = FirstPerson
        SettingsUI.lastSwitch.RidingFP = FPRiding
        SettingsUI.lastSwitch.ModFOV = ModFOVEnabled
        SettingsUI.lastSlider.FirstPersonFOV = FirstPersonFOV
        SettingsUI.lastSlider.ThirdPersonFOV = ThirdPersonFOV
    end)

    -- pcall 失败 → 回滚已移动行 + 清理 + 返回 false
    if not ok then
        -- 回滚（）：把已移入页面的 spare 行移回原父容器末尾——
        -- 不回滚则行残留在页面上，重试时已可见 → 克隆新行 → 重复行
        local rollbackCount = 0
        local visFlags = {}
        for _, m in ipairs(movedRows) do
            if IsValidObj(m.row) and IsValidObj(m.parent) then
                -- +：回滚前记录行可见性（已 SetVisibility(0) 的行回滚后仍可见
                -- → 残留可见行 → 重试 Acquire 取新行 → 重复行。此字段验证该机制）
                local vis = "?"
                pcall(function() vis = tostring(m.row:IsVisible()) end)
                table.insert(visFlags, tostring(m.row:GetAddress()) .. ":" .. vis)
                pcall(function() m.parent:AddChild(m.row) end)
                rollbackCount = rollbackCount + 1
            end
        end
        SettingsUI.rows = {}
        SettingsUI.contents = {}
        SettingsUI.switches = {}
        SettingsUI.page = nil
        return false, "menu attach: " .. tostring(err)
    end

    -- 附着成功后刷新 FOV 显示（RefreshFOV）
    RefreshSliderDisplay(SettingsUI.contents.FirstPersonFOV, FirstPersonFOV)
    RefreshSliderDisplay(SettingsUI.contents.ThirdPersonFOV, ThirdPersonFOV)

    SettingsUI.page = page
    SettingsUI.attached = true
    SettingsUI.pageAttachTime = os.clock()

    -- ：布局重新启用（单行版）。延迟 500ms 执行——populate 稳定窗口
    -- （ 注入后立即执行致原生行/spare 行重叠的教训）
    ExecuteWithDelay(500, function()
        if SettingsUI.attached and IsValidObj(SettingsUI.page) then
            ApplySettingsLayout()
        end
    end)

    print("[FP-UI] settings page attached (style: CameraRecoil/AutoContrast/native FOV + 1 spare)")
    return true, nil
end

-- 读滑轨值（thumb 优先，CurrentValue 兜底）
-- thumb（Slider:GetValue）是用户拖动源、游戏刷新不改它；我们每帧发 GS 时游戏会把渲染
-- FOV 写进 CurrentValue，先读 CurrentValue 会把被刷新的值误读成档案 → 误写 130
local function ReadSliderValue(content)
    if not IsValidObj(content) then return nil end
    local v = nil
    pcall(function() v = content.Slider:GetValue() end)
    if type(v) ~= "number" then
        pcall(function() v = content.CurrentValue end)
    end
    if type(v) ~= "number" then return nil end
    return math.floor(math.min(FOV_HARD_MAX, math.max(FOV_HARD_MIN, v)) + 0.5)
end

-- 读开关状态（读 CurrentIsOn 属性；不用 IsOn()——该 UFunction 期望参数，无参调用报错，
-- 被 UE4SS 高频记录是崩溃/卡顿诱因）
local function ReadSwitchState(sw)
    if not IsValidObj(sw) then return nil end
    local ok, v = pcall(function() return sw.CurrentIsOn end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

-- 反向同步：开关显示与实际状态不一致时重跑 SetSwitcher 刷新显示
local function SyncSwitchDisplay(row, sw, actual, key)
    local read = ReadSwitchState(sw)
    if type(read) == "boolean" and read ~= actual and IsValidObj(row) then
        pcall(function() row:SetSwitcher(actual) end)
    end
end

-- 滑轨形态保活：被游戏刷新切成档位形态时切回滑轨
local function MaintainSliderRow(row, content, value)
    if not IsValidObj(row) or not IsValidObj(content) then return end
    local visible = false
    pcall(function() visible = content:IsVisible() end)
    if not visible then
        pcall(function() row:SetSlider(value, FOV_HARD_MIN, FOV_HARD_MAX, 1.0, true) end)
    end
end

-- 游戏 SetDefault/Construct 可能重建行 → 检测可见性，
-- 不可见就重设 SetSlider/SetSwitcher/SetText。FP/Riding 是原生行（游戏自己管），
-- TP FOV 是原生 FOV 行（游戏自己管），主要兜底 spare 行（FP FOV + ModFOV）。
-- 行维护 + 原生行重建自愈（ F3c+F4）
-- F4：游戏 SetDefault/刷新会销毁并重建原生行（实测：重建后原生 FOV 行显示回原生值
--  70、CameraRecoil/AutoContrast 改名丢失）→ 行引用失效时从页面属性重取并重设。
--  注意：spare 行（FP FOV / Mod FOV）由游戏管理时不会单独重建，引用失效即页面
--  销毁，放弃维护等新页面（NotifyOnNewObject 会重来）。
-- F3c：文本/滑杆范围幂等重设（SetText 幂等、50ms 一次开销可忽略，对齐每 tick
--  Maintain），防游戏 SetDefault/刷新重置内容后显示错乱。
local function MaintainSettingsRows()
    if not IsValidObj(SettingsUI.page) then return false end
    local page = SettingsUI.page

    -- F4：原生行引用失效 → 从页面属性重取
    local rebindNeeded = false
    for _, k in ipairs({ "FP", "RidingFP", "ThirdPersonFOV" }) do
        if not IsValidObj(SettingsUI.rows[k]) then rebindNeeded = true end
    end
    if rebindNeeded then
        local fpRow, ridingRow, fovRow = nil, nil, nil
        pcall(function() fpRow = page.WBP_OptionSettings_CameraRecoil end)
        pcall(function() ridingRow = page.WBP_OptionSettings_AutoContrast end)
        pcall(function() fovRow = page.WBP_OptionSettings_FOV end)
        if IsValidObj(fpRow) then SettingsUI.rows.FP = fpRow end
        if IsValidObj(ridingRow) then SettingsUI.rows.RidingFP = ridingRow end
        if IsValidObj(fovRow) then
            SettingsUI.rows.ThirdPersonFOV = fovRow
            local tc = nil
            pcall(function() tc = fovRow.WBP_OptionSettings_ListContentSlider end)
            SettingsUI.contents.ThirdPersonFOV = tc
            if IsValidObj(tc) then
                pcall(function() RefreshSliderDisplay(tc, ThirdPersonFOV) end)
            end
        end
        if not IsValidObj(SettingsUI.rows.FirstPersonFOV) then return false end
    end

    -- F3c：文本/范围幂等重设（游戏 SetDefault/重建行会重置内容）
    -- 行名随自动检测语言（游戏 SetDefault/重建行重置文本后恢复）
    pcall(function() SettingsUI.rows.FP.BP_PalTextBlock_Name:SetText(FText(LangUI:t("FirstPerson"))) end)
    pcall(function() SettingsUI.rows.RidingFP.BP_PalTextBlock_Name:SetText(FText(LangUI:t("FirstPersonRiding"))) end)
    pcall(function() SettingsUI.rows.ThirdPersonFOV.BP_PalTextBlock_Name:SetText(FText(LangUI:t("ThirdPersonFOV"))) end)
    pcall(function() SettingsUI.rows.FirstPersonFOV.BP_PalTextBlock_Name:SetText(FText(LangUI:t("FirstPersonFOV"))) end)
    -- 武器偏移开关行文本幂等重设（游戏 SetDefault/重建行重置后恢复；
    -- rows.WeaponOffset 未注入（nil）时 pcall 兜住，与上方行同款模式）
    pcall(function() SettingsUI.rows.WeaponOffset.BP_PalTextBlock_Name:SetText(FText(LangUI:t("WeaponOffset"))) end)
    -- ：Mod FOV 开关行已移除，无 rows.ModFOV 可维护
    local fpSlider = nil
    pcall(function() fpSlider = SettingsUI.contents.FirstPersonFOV and SettingsUI.contents.FirstPersonFOV.Slider end)
    if IsValidObj(fpSlider) then
        pcall(function() fpSlider:SetMinValue(FOV_HARD_MIN) end)
        pcall(function() fpSlider:SetMaxValue(FOV_HARD_MAX) end)
    end
    local tpSlider = nil
    pcall(function() tpSlider = SettingsUI.contents.ThirdPersonFOV and SettingsUI.contents.ThirdPersonFOV.Slider end)
    if IsValidObj(tpSlider) then
        pcall(function() tpSlider:SetMinValue(FOV_HARD_MIN) end)
        pcall(function() tpSlider:SetMaxValue(FOV_HARD_MAX) end)
    end

    -- 行形态/可见性异常 → 重设（游戏刷新可能把 spare 行切回档位态/隐藏）
    -- ：Mod FOV 开关行已移除，只维护 FP FOV 滑轨 spare 行
    -- 武器偏移开关行独立保活（不耦合下方 fp 行判定——fp 行正常而
    -- wp 行异常时不能提前 return 跳过）。spare 行被切回档位态/隐藏 → 重设开关形态
    local wpRowVis = false
    pcall(function() wpRowVis = IsValidObj(SettingsUI.rows.WeaponOffset) and SettingsUI.rows.WeaponOffset:IsVisible() end)
    if not wpRowVis and IsValidObj(SettingsUI.rows.WeaponOffset) then
        pcall(function() SettingsUI.rows.WeaponOffset:SetSwitcher(WeaponOffsetEnabled) end)
        pcall(function() SettingsUI.rows.WeaponOffset:SetVisibility(0) end)
        pcall(function() SettingsUI.switches.WeaponOffset = SettingsUI.rows.WeaponOffset.WBP_OptionSettings_ListContentSwitch end)
    end

    local fpRowOk = false
    local fpContentOk = false
    pcall(function() fpRowOk = SettingsUI.rows.FirstPersonFOV:IsVisible() end)
    pcall(function() fpContentOk = IsValidObj(SettingsUI.contents.FirstPersonFOV) and SettingsUI.contents.FirstPersonFOV:IsVisible() end)

    if fpRowOk and fpContentOk then return true end

    if IsValidObj(SettingsUI.rows.FirstPersonFOV) then
        pcall(function() SettingsUI.rows.FirstPersonFOV:SetSlider(FirstPersonFOV, FOV_HARD_MIN, FOV_HARD_MAX, 1.0, true) end)
        pcall(function() SettingsUI.rows.FirstPersonFOV:SetVisibility(0) end)
        pcall(function() SettingsUI.contents.FirstPersonFOV = SettingsUI.rows.FirstPersonFOV.WBP_OptionSettings_ListContentSlider end)
    end
    -- 布局重跑由注入后 500ms / D4 children 变化重跑触发，此处不调用
    return false
end

--  修复：挂表供 EnsureGraphicsDefaultHook 回调运行时解析
-- （local 词法作用域：hook 回调定义点在 MaintainSettingsRows 之前 → 直接引用
--  解析为 global nil → SetDefault 时崩溃，记忆文件 lua-local-scope-hook-nil 实证）
SettingsUI.MaintainSettingsRows = MaintainSettingsRows

-- 页面填充完成检测（）：列表末尾行可见 → populate 完成 → 注入位置稳定。
-- 顺序从列表尾部候选往前取（PalAura → Arachnophobia → FOV 兜底）；
-- 注意 Arachnophobia 是 SLIDER_SPARE_CANDIDATES 之一，但 spare 行在注入前
-- 不可见，不影响判定。
local function IsPagePopulated(page)
    for _, prop in ipairs({
        "WBP_OptionSettings_PalAura",
        "WBP_OptionSettings_Arachnophobia",
        "WBP_OptionSettings_FOV",
    }) do
        local row = nil
        pcall(function() row = page[prop] end)
        if IsValidObj(row) then
            local vis = false
            pcall(function() vis = row:IsVisible() end)
            if vis then return true end
        end
    end
    return false
end

-- 菜单 tick：注入重试 + 轮询滑块/开关（双向同步）
local function SettingsUITick()
    -- 设置页活动标志（供主循环 FOV 保活判断）：页面 pending/attached 且可见期间置 true
    -- （ 加可见性判定：页面已隐藏/关闭（IsVisible=false）→ 视为非设置页，
    --  保活走完整 ApplyRuntimeFOV 广播路径。安全性：tab 切换不改变 GraphicSettings
    --  可见性，仅真正关闭后才 false → 不会在页面打开期引入  式广播竞态）
    local pageVisible = false
    if SettingsUI.attached and IsValidObj(SettingsUI.page) then
        pcall(function() pageVisible = SettingsUI.page:IsVisible() end)
    end
    -- ：可见性变化日志（打开/关闭瞬间记录，崩溃分析关键时间线）
    FP_SettingsPageActive = SettingsUI.pagePending or pageVisible

    -- 注入队列
    if SettingsUI.pagePending then
        if not IsValidObj(SettingsUI.pageCandidate) then
            SettingsUI.pagePending = false
        else
            -- notify 后 300ms Slate 就绪缓冲——快速开关设置页时
            -- UObject 行已存在（IsPagePopulated 通过）但 Slate/SWidget 树尚未构造，
            -- 此时 MoveOptionRow 的 AddChild 访问 null Slate → 0xC0000005 @ 0x0
            -- （08-15 00:27:41 崩溃实证，pcall 无法保护原生崩溃）。
            -- 未满 300ms 不注入（attempts 不计入），页面即开即关（<300ms）则不注入
            if (os.clock() - SettingsUI.pageNotifyTime) < 0.3 then
                return
            end
            SettingsUI.pageAttempts = SettingsUI.pageAttempts + 1
            -- ：等待页面 populate 完成再注入（spare 行落在列表末尾、位置稳定；
            -- 实测注入过早 → 每次打开位置漂移、行出现在【图像设定】中段）。
            -- 超时（pageAttempts >= max）保底直接注入。
            if not IsPagePopulated(SettingsUI.pageCandidate)
                and SettingsUI.pageAttempts < SettingsUI.pageMaxAttempts then
                return
            end
            --  修正：IsInViewport 在 UE4SS 未导出（pcall 捕获错误 → 恒 false →
            -- 注入全取消，实测 20 次开关全部取消）。改检测"页面已从树中移除/销毁"：
            -- GetParent 无效（已 RemoveFromParent/销毁）→ 放弃注入等新页面；
            -- 有效 → 放行（populate 等待已保证页面就绪）
            local parentOk = true
            pcall(function()
                local parent = SettingsUI.pageCandidate:GetParent()
                if not IsValidObj(parent) then parentOk = false end
            end)
            if not parentOk then
                SettingsUI.pagePending = false
                SettingsUI.pageCandidate = nil
                return
            end
            local ok, err = InjectSettingsPage(SettingsUI.pageCandidate)
            if ok then
                SettingsUI.pagePending = false
                SettingsUI.pageCandidate = nil
            elseif SettingsUI.pageAttempts >= SettingsUI.pageMaxAttempts then
                SettingsUI.pagePending = false
                SettingsUI.pageCandidate = nil
                print("[FP-UI] settings page attach timed out: " .. tostring(err))
            end
        end
    end

    if not SettingsUI.attached or not IsValidObj(SettingsUI.page) then return end

    -- ：页面不可见（关闭动画后/隐藏）→ 跳过维护与轮询，等新页面通知；
    -- 不重置状态（重开时 NotifyOnNewObject 重置），降低关闭期 UMG 操作密度
    if not pageVisible then return end

    -- 同一页面对象已附着 → 走 Maintain 而非完整重注入
    if SettingsUI.pageCandidate and IsValidObj(SettingsUI.pageCandidate) then
        local samePage = false
        pcall(function() samePage = SettingsUI.page:GetAddress() == SettingsUI.pageCandidate:GetAddress() end)
        if samePage then
            local maintained = MaintainSettingsRows()
            SettingsUI.pageCandidate = nil
            SettingsUI.pagePending = false
            if not maintained then return end
        end
    end

    -- 页面可见性双重校验：IsVisible + GetParent，防操作已销毁/未挂载控件
    local pageVisible = false
    pcall(function()
        pageVisible = SettingsUI.page:IsVisible()
        if pageVisible then
            local parent = SettingsUI.page:GetParent()
            if not IsValidObj(parent) then pageVisible = false end
        end
    end)
    if not pageVisible then return end

    -- 游戏重建行后重新 SetSlider/SetSwitcher
    if not MaintainSettingsRows() then return end

    -- 布局测量重试——上次执行时 GetDesiredSize 未返回真实高度
    -- （baseH=4.0 假测量）→ 每 1s 重跑直到可信或页面关闭；此处 attached+可见+rows
    -- 均已保证。SetRenderTranslation 绝对覆盖 → 重试成功自动纠正错误平移（幂等自愈）。
    if SettingsUI.layoutPendingRetry and (os.clock() - SettingsUI.layoutRetryTime) >= 1.0 then
        SettingsUI.layoutRetryTime = os.clock()
        ApplySettingsLayout()
    end

    -- 滑轨形态保活
    MaintainSliderRow(SettingsUI.rows.FirstPersonFOV, SettingsUI.contents.FirstPersonFOV, FirstPersonFOV)
    MaintainSliderRow(SettingsUI.rows.ThirdPersonFOV, SettingsUI.contents.ThirdPersonFOV, ThirdPersonFOV)

    -- 滑轨显示保活：游戏写入的渲染 FOV 显示（130）用档案值覆盖（拖动中自动跳过，2s 节流）
    MaintainSliderDisplay(SettingsUI.contents.FirstPersonFOV, FirstPersonFOV, "FirstPersonFOV")
    MaintainSliderDisplay(SettingsUI.contents.ThirdPersonFOV, ThirdPersonFOV, "ThirdPersonFOV")

    -- 行列表结构变化检测（每 100 tick ≈ 5s，纯读取检测；
    -- 注入后游戏若增删行（重 populate）→ 300ms 后重跑布局）
    SettingsUI.treeCheckTick = SettingsUI.treeCheckTick + 1
    if SettingsUI.treeCheckTick >= 100 then
        SettingsUI.treeCheckTick = 0
        local n = -1
        pcall(function()
            local panel = SettingsUI.rows.ThirdPersonFOV:GetParent()
            if IsValidObj(panel) then n = panel:GetChildrenCount() end
        end)
        if SettingsUI.treeChildCount ~= nil and n >= 0 and n ~= SettingsUI.treeChildCount then
            -- ：游戏重 populate 后重跑布局（幂等 SetRenderTranslation，
            -- 延迟 300ms 等行重建稳定；页面已销毁则 ApplySettingsLayout 内部跳过）
            ExecuteWithDelay(300, function()
                if SettingsUI.attached and IsValidObj(SettingsUI.page) then
                    ApplySettingsLayout()
                end
            end)
        end
        if n >= 0 then SettingsUI.treeChildCount = n end
    end

    -- 滑轨轮询（值变化 → 更新档案 + 应用 + 落盘 + 显示同步）
    -- 读 thumb 优先（游戏刷新 CurrentValue 不误读）；变化后 RefreshSliderDisplay 用新档案
    -- 刷新显示（SetValueInt 设 thumb=新值，与拖动一致不打断）
    -- 注意：lastSlider 可能被异步 NotifyOnNewObject 中途清空 → 必须 nil 守卫
    local fpv = ReadSliderValue(SettingsUI.contents.FirstPersonFOV)
    local fpLast = SettingsUI.lastSlider.FirstPersonFOV
    if type(fpv) == "number" and type(fpLast) == "number" and math.abs(fpv - fpLast) > 0.001 then
        SettingsUI.lastSlider.FirstPersonFOV = fpv
        -- 值已被轮询接管（用户拖动或游戏改动）→ 该滑轨永不 init 纠正
        SettingsUI.sliderInitDone["FirstPersonFOV"] = true
        SetFirstPersonFOV(fpv, "settings menu", true, true)
        -- 不再 RefreshSliderDisplay——拖动期 SetValueInt 与游戏刷新并发是
        -- 竞态崩溃源（TP 视角拖 TP 行实测崩溃）；用户拖动时 thumb 本就正确，
        -- CurrentValue 由游戏刷新，显示纠正交给 MaintainSliderDisplay 2s 节流兜底
    end
    local tpv = ReadSliderValue(SettingsUI.contents.ThirdPersonFOV)
    local tpLast = SettingsUI.lastSlider.ThirdPersonFOV
    if type(tpv) == "number" and type(tpLast) == "number" and math.abs(tpv - tpLast) > 0.001 then
        SettingsUI.lastSlider.ThirdPersonFOV = tpv
        -- 同上——该滑轨已被轮询接管
        SettingsUI.sliderInitDone["ThirdPersonFOV"] = true
        SetThirdPersonFOV(tpv, "settings menu", true, true)
        -- 同上（不 RefreshSliderDisplay）
    end

    -- 开关轮询（状态变化 → 调共享 SetFP/SetFPRiding / 更新 ModFOVEnabled）
    --  两帧去抖：页面关闭动画/行重建过渡期 CurrentIsOn 可能被游戏瞬时重置为
    -- false，单帧误读会误触发 SetFP(false)/SetModFOV(false) → 视图还原 + 保活停止
    -- → FOV 被锁成 TP 档案值并保持（实测现象）。第一帧记 pending，第二帧仍一致才
    -- 生效；误读是瞬时的，下一帧行销毁/恢复 → pending 取消。点击生效延迟 50~100ms
    -- （UI 动画掩盖）。注意：lastSwitch 可能被异步 NotifyOnNewObject 中途清空 → nil 守卫
    --  两道额外守卫（防"关闭设置页 → 自动变 TP"复现）：
    --  A1 行地址跟踪：游戏重建行后新行 CurrentIsOn=false，直接读会误触发
    --    SetFP(false)；地址变化 → 状态未知 → 不应用，写回真实状态 + 同步 lastSwitch
    --  A2 页面可见性：页面隐藏/关闭后残留读值不应用
    local function PollSwitch(key, sw, row, applyFn, actual)
        local read = ReadSwitchState(sw)
        local swAddr = nil
        pcall(function() swAddr = sw:GetAddress() end)
        local lastAddr = SettingsUI.switchAddrs[key]
        if type(lastAddr) == "string" and swAddr ~= lastAddr then
            SettingsUI.switchAddrs[key] = swAddr
            SettingsUI.switchPending[key] = nil
            SettingsUI.lastSwitch[key] = actual
            SyncSwitchDisplay(row, sw, actual, key)
            return
        end
        if type(lastAddr) ~= "string" then
            SettingsUI.switchAddrs[key] = swAddr
        end
        local last = SettingsUI.lastSwitch[key]
        if type(read) ~= "boolean" or type(last) ~= "boolean" then
            SettingsUI.switchPending[key] = nil
            return
        end
        if read == last then
            SettingsUI.switchPending[key] = nil
            return
        end
        if not pageVisible then
            SettingsUI.switchPending[key] = nil
            return
        end
        local pend = SettingsUI.switchPending[key]
        if pend == read then
            SettingsUI.switchPending[key] = nil
            SettingsUI.lastSwitch[key] = read
            applyFn(read)
            SyncSwitchDisplay(row, sw, read, key)
        else
            SettingsUI.switchPending[key] = read
        end
    end
    PollSwitch("FP", SettingsUI.switches.FP, SettingsUI.rows.FP, SetFP, FirstPerson)
    PollSwitch("RidingFP", SettingsUI.switches.RidingFP, SettingsUI.rows.RidingFP, SetFPRiding, FPRiding)
    -- ：Mod FOV 开关行已移除（ModFOVEnabled 恒 true），不再轮询
    -- 武器偏移开关轮询（applyFn 用匿名闭包——不新增顶层 local，
    -- 当前 main chunk 顶层 local 199 卡 200 限制，.6/2.8.9 两次踩坑实证）。
    -- 关闭 → 立即还原当前武器已写偏移（RestoreWeaponOffsets 三路写幂等）；
    -- 开启 → 主循环 WeaponOffsetEnabled 分支恢复应用。
    PollSwitch("WeaponOffset", SettingsUI.switches.WeaponOffset, SettingsUI.rows.WeaponOffset, function(v)
        v = (v == true)
        if WeaponOffsetEnabled ~= v then
            WeaponOffsetEnabled = v
            ConfigDirty = true
            if not v then
                pcall(function() RestoreWeaponOffsets(GetPawn()) end)
            end
        end
    end, WeaponOffsetEnabled)
end

-- ============================================================
-- 语言自动检测正式版（实证链：.6a 首次读出行名
-- 「语言」；.7 稳定性测试 5/5 次一致 cjk=true → 检测可靠）
-- 判定：NotifyOnNewObject(WBP_Other_Settings) → 延迟 1.5s（页面构造完成后读，
-- 同图像设定页"notify 回调时子控件未绑定"的教训）→ 读语言行行名文本 →
-- HasCJK（0x4E00-0x9FFF，简体/繁体天然统一简体）→ LangUI.auto。
-- 检测失败 → 保持 LangUI.auto 现值（下轮设置打开再试）；只在变化时 Log
-- （防每次打开设置刷屏）。证据：ObjectDump 实证语言行 =
-- WBP_Other_Settings_C.WBP_OptionSettings_Language（WBP_OptionSettings_ListContent_C）
-- ============================================================
local OTHER_SETTINGS_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/" ..
    "WBP_Other_Settings.WBP_Other_Settings_C"

-- CJK 判定：UTF-8 解码，文本含中日韩统一表意文字（0x4E00-0x9FFF）→ 中文环境
local function HasCJK(s)
    if type(s) ~= "string" then return false end
    local i = 1
    while i <= #s do
        local b = string.byte(s, i)
        local cp = 0
        if b < 0x80 then
            i = i + 1
        elseif b < 0xE0 then
            cp = ((b - 0xC0) * 0x40) + string.byte(s, i + 1) - 0x80
            i = i + 2
        elseif b < 0xF0 then
            cp = ((b - 0xE0) * 0x1000) + (string.byte(s, i + 1) - 0x80) * 0x40
                + string.byte(s, i + 2) - 0x80
            i = i + 3
        else
            i = i + 4
        end
        if cp >= 0x4E00 and cp <= 0x9FFF then return true end
    end
    return false
end

-- 语言自动检测主函数：notify 回调延迟 1.5s 执行 → 读行名 → CJK → LangUI.auto
-- （LangUI 定义在变量区，词法作用域安全）
local function DetectAutoLanguage(w)
    ExecuteWithDelay(1500, function()
        if not IsValidObj(w) then
            return
        end
        local row = nil
        pcall(function() row = w.WBP_OptionSettings_Language end)
        if not IsValidObj(row) then
            return
        end
        local nameText = nil
        pcall(function()
            local tb = row.BP_PalTextBlock_Name
            if IsValidObj(tb) then
                local t = tb:GetText()
                if t ~= nil then nameText = tostring(t:ToString()) end
            end
        end)
        if type(nameText) ~= "string" or nameText == "" then
            return
        end
        local detected = HasCJK(nameText) and "zh" or "en"
        if detected ~= LangUI.auto then
            LangUI.auto = detected
            -- 热键页行名不再刷新：行名由游戏原生 key 绑定
            -- 自动翻译，跟随游戏语言，与检测同源，无需模组写入
        end
    end)
end

-- 注册：游戏设置页（Other_Settings）通知 → 自动检测（与图像设定页注入无关）
pcall(function()
    NotifyOnNewObject(OTHER_SETTINGS_PATH, function(w)
        if IsValidObj(w) then DetectAutoLanguage(w) end
    end)
end)

-- 注册设置页通知 + 菜单 tick 循环
pcall(function()
    NotifyOnNewObject(GRAPHIC_SETTINGS_PATH, function(w)
        -- 幂等：同一页面对象的重复通知（UE4SS 构造期可能多次触发）不重置
        -- 状态——重置会清 rows/usedRows 并重注入，已可见的 spare 行不再是候选 →
        -- 克隆新行 → 重复行 + 行-档案绑定错配（实测：双 First Person FOV 行、滑杆
        -- 显示交叉）。页面已销毁（page 无效）时正常处理新页面。
        if SettingsUI.attached and IsValidObj(SettingsUI.page) then
            local same = false
            pcall(function() same = w:GetAddress() == SettingsUI.page:GetAddress() end)
            if same then
                return
            end
        end
        SettingsUI.pageCandidate = w
        SettingsUI.pageAttempts = 0
        SettingsUI.pagePending = true
        -- 新页面重置布局重试状态（重新判断测量时机）
        SettingsUI.layoutPendingRetry = false
        SettingsUI.layoutRetryTime = 0
        -- 记录 notify 时刻，注入队列需等待 Slate 树构造
        SettingsUI.pageNotifyTime = os.clock()
        -- 清空旧页面引用（旧控件已销毁，dangling 指针访问 = use-after-free 崩溃）
        SettingsUI.usedRows = {}
        SettingsUI.rows = {}
        SettingsUI.contents = {}
        SettingsUI.switches = {}
        SettingsUI.lastSwitch = { FP = FirstPerson, RidingFP = FPRiding, ModFOV = ModFOVEnabled }
        SettingsUI.switchPending = {}
        SettingsUI.switchAddrs = {}
        SettingsUI.lastSlider = { FirstPersonFOV = FirstPersonFOV, ThirdPersonFOV = ThirdPersonFOV }
        SettingsUI.sliderCorrectTime = {}
        SettingsUI.sliderInitDone = {}   -- 新页面重新初始化
        SettingsUI.pageAttachTime = 0
        SettingsUI.attached = false
        SettingsUI.page = nil
    end)
end)

-- ：SettingsUITick 顶层 pcall 兜底——协程内任何未捕获错误不再杀死
-- LoopAsync 协程（旧表现：mod 半死——热键失效、注入行消失），改为记录日志继续
local function SettingsUITickSafe()
    local ok, err = pcall(SettingsUITick)
    if not ok then
        print("[FP-UI] tick error: " .. tostring(err))
    end
end

LoopAsync(50, SettingsUITickSafe)

-- ===== 启动 =====
print("[FP] v3.7 loaded | FP=" .. tostring(FirstPerson) .. " Riding=" .. tostring(FPRiding) .. " ModFOV=" .. tostring(ModFOVEnabled) .. " WeaponOffset=" .. tostring(WeaponOffsetEnabled) .. " FP-FOV=" .. string.format("%.0f", FirstPersonFOV) .. " TP-FOV=" .. string.format("%.0f", ThirdPersonFOV) .. " | Config=" .. tostring(ConfigLoadResult))
print("[FP] Hotkeys: native remappable (FP=F6 default / Riding=unbound) | gamepad rows removed")