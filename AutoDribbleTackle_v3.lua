-- [v3.2] AUTO DRIBBLE + AUTO TACKLE
-- Ключевые изменения v3.2:
-- [AutoTackle] Переписан предикт: Intercept Point через решение квадратного уравнения.
--   Учитывает: скорость врага (position history), скорость тякла, дистанцию, пинг (компенсация задержки клиента).
--   Позиция врага компенсируется вперёд на ping/2 секунды (т.к. мы видим его прошлое положение).
-- [AutoDribble] Убрана проверка скорости таклера. Реагируем только на угол + дистанцию.
--   Cooldown проверяется на уровне PerformDribble, не ShouldDribbleNow — убирает задержку реакции.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Camera = Workspace.CurrentCamera
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")
local Stats = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local Humanoid = Character:WaitForChild("Humanoid")

local ActionRemote = ReplicatedStorage.Remotes:WaitForChild("Action")
local SoftDisPlayerRemote = ReplicatedStorage.Remotes:WaitForChild("SoftDisPlayer")
local Animations = ReplicatedStorage:WaitForChild("Animations")
local DribbleAnims = Animations:WaitForChild("Dribble")

local DribbleAnimIds = {}
for _, anim in pairs(DribbleAnims:GetChildren()) do
    if anim:IsA("Animation") then table.insert(DribbleAnimIds, anim.AnimationId) end
end

-- === ПИНГ ===
local function GetPing()
    local ok, v = pcall(function()
        local s = Stats.Network.ServerStatsItem["Data Ping"]
        return tonumber(s:GetValueString():match("%d+")) or 0
    end)
    return (ok and v and v / 1000) or 0.1
end

-- === CONFIG ===
local AutoTackleConfig = {
    Enabled = false,
    Mode = "OnlyDribble", -- "OnlyDribble" | "EagleEye" | "ManualTackle"
    MaxDistance = 20,
    TackleDistance = 0,       -- Мгновенный такл при этой дистанции
    TackleSpeed = 47,         -- studs/sec скорость нашего тела при такле
    OnlyPlayer = true,
    RotationMethod = "Snap",  -- "Snap" | "Always" | "None"
    DribbleDelayTime = 0.63,
    EagleEyeMinDelay = 0.1,
    EagleEyeMaxDelay = 0.6,
    ManualTackleEnabled = true,
    ManualTackleKeybind = Enum.KeyCode.Q,
    ManualTackleCooldown = 0.5,
    ManualButton = false,
    ButtonScale = 1.0,
}

local AutoDribbleConfig = {
    Enabled = false,
    MaxDribbleDistance = 30,
    DribbleActivationDistance = 16,
    HeadOnAngleThreshold = 50,    -- угол (°) — таклер должен идти в нашу сторону
    MinAngleForDribble = 50,      -- то же самое, итоговый порог угла
}

local DebugConfig = { Enabled = true, MoveEnabled = false, Position = Vector2.new(0.5, 0.5) }

-- === STATES ===
local AutoTackleStatus = {
    Running = false, Connection = nil, HeartbeatConnection = nil,
    InputConnection = nil, ButtonGui = nil,
    TouchStartTime = 0, Dragging = false,
    DragStart = Vector2.new(0,0), StartPos = UDim2.new(0,0,0,0),
    Ping = 0.1, LastPingUpdate = 0,
    -- История позиций для предикта
    PosHistory = {},   -- [player] = { {t, pos}, ... }
    TargetCircles = {}
}

local AutoDribbleStatus = {
    Running = false, Connection = nil, HeartbeatConnection = nil,
    LastDribbleTime = 0,
}

local DribbleStates = {}
local TackleStates = {}
local PrecomputedPlayers = {}
local HasBall = false
local CanDribbleNow = false
local DribbleCooldownList = {}
local EagleEyeTimers = {}
local IsTypingInChat = false
local LastManualTackleTime = 0
local CurrentTargetOwner = nil

local SPECIFIC_TACKLE_ID = "rbxassetid://14317040670"

-- =============================================================
-- === ПРЕДИКТ: МЕТОД ТОЧКИ ПЕРЕХВАТА (INTERCEPT POINT)
-- =============================================================
-- Суть: мы хотим найти позицию P, в которой наш такл (летящий
-- со скоростью TackleSpeed) встретит врага (движущегося со
-- скоростью enemyVelocity).
--
-- Так как мы видим врага с задержкой ping/2 (half-RTT),
-- сначала компенсируем его реальную серверную позицию:
--   serverPos = knownPos + enemyVel * ping/2
--
-- Затем решаем: за какое время t наш такл покроет дистанцию до
-- точки перехвата P = serverPos + enemyVel * t?
--   |serverPos + enemyVel*t - myPos|² = (TackleSpeed*t)²
--
-- Это квадратное уравнение:
--   a*t² + b*t + c = 0
--   a = |enemyVel|² - TackleSpeed²
--   b = 2 * dot(offset, enemyVel)
--   c = |offset|²
--   offset = serverPos - myPos
--
-- Решение даёт t — время полёта, тогда точка перехвата:
--   interceptPos = serverPos + enemyVel * t
-- =============================================================

local POS_HISTORY_SIZE = 8
local POS_HISTORY_WINDOW = 0.18  -- секунды

local function RecordPos(player, pos)
    local h = AutoTackleStatus.PosHistory[player]
    if not h then h = {}; AutoTackleStatus.PosHistory[player] = h end
    table.insert(h, { t = tick(), pos = pos })
    while #h > POS_HISTORY_SIZE do table.remove(h, 1) end
end

local function GetSmoothedVelocity(player)
    local h = AutoTackleStatus.PosHistory[player]
    if not h or #h < 2 then return Vector3.zero end
    local now = tick()
    -- Собираем точки в пределах окна
    local recent = {}
    for _, pt in ipairs(h) do
        if now - pt.t <= POS_HISTORY_WINDOW then table.insert(recent, pt) end
    end
    -- Если точек меньше 2 — берём последние 2 из всей истории
    if #recent < 2 then recent = { h[#h-1], h[#h] } end
    local oldest, newest = recent[1], recent[#recent]
    local dt = newest.t - oldest.t
    if dt < 0.001 then return Vector3.zero end
    return (newest.pos - oldest.pos) / dt
end

local function ComputeInterceptPoint(ownerRoot, player)
    if not ownerRoot then return ownerRoot.Position end

    RecordPos(player, ownerRoot.Position)

    local ping = AutoTackleStatus.Ping  -- RTT в секундах
    local halfPing = ping * 0.5         -- half-RTT = задержка видимости

    -- Компенсируем: реальная серверная позиция врага сейчас
    local enemyVel = GetSmoothedVelocity(player)
    local enemyVelFlat = Vector3.new(enemyVel.X, 0, enemyVel.Z)
    local serverPos = ownerRoot.Position + enemyVelFlat * halfPing

    local myPos = Vector3.new(HumanoidRootPart.Position.X, 0, HumanoidRootPart.Position.Z)
    local srvPos2D = Vector3.new(serverPos.X, 0, serverPos.Z)

    local offset = srvPos2D - myPos
    local s = AutoTackleConfig.TackleSpeed

    -- Квадратное уравнение: a*t^2 + b*t + c = 0
    local ev2D = Vector3.new(enemyVelFlat.X, 0, enemyVelFlat.Z)
    local a = ev2D:Dot(ev2D) - s * s
    local b = 2 * offset:Dot(ev2D)
    local c = offset:Dot(offset)

    local t = 0

    if math.abs(a) < 0.001 then
        -- Линейный случай (враг стоит или скорость ≈ скорости такла)
        if math.abs(b) > 0.001 then
            t = -c / b
        end
    else
        local disc = b*b - 4*a*c
        if disc >= 0 then
            local sqrtD = math.sqrt(disc)
            local t1 = (-b - sqrtD) / (2*a)
            local t2 = (-b + sqrtD) / (2*a)
            -- Выбираем наименьшее положительное t
            if t1 > 0 and t2 > 0 then
                t = math.min(t1, t2)
            elseif t1 > 0 then
                t = t1
            elseif t2 > 0 then
                t = t2
            end
        end
    end

    -- Зажимаем время в разумных пределах
    t = math.clamp(t, 0, 1.0)

    local interceptPos = serverPos + enemyVelFlat * t
    -- Восстанавливаем Y из реальной позиции врага
    interceptPos = Vector3.new(interceptPos.X, ownerRoot.Position.Y, interceptPos.Z)

    if Gui and AutoTackleConfig.Enabled then
        Gui.PredictionLabel.Text = string.format("Pred: t=%.2fs | v=%.1f | ping=%dms",
            t, enemyVelFlat.Magnitude, math.round(ping * 1000))
    end

    return interceptPos
end

-- === ПИНГ ===
local function UpdatePing()
    local now = tick()
    if now - AutoTackleStatus.LastPingUpdate > 1 then
        AutoTackleStatus.Ping = GetPing()
        AutoTackleStatus.LastPingUpdate = now
        if Gui and AutoTackleConfig.Enabled then
            Gui.PingLabel.Text = string.format("Ping: %dms", math.round(AutoTackleStatus.Ping * 1000))
        end
    end
end

-- === GUI ===
local Gui = nil
local function SetupGUI()
    Gui = {
        TackleWaitLabel      = Drawing.new("Text"),
        TackleTargetLabel    = Drawing.new("Text"),
        TackleDribblingLabel = Drawing.new("Text"),
        TackleTacklingLabel  = Drawing.new("Text"),
        EagleEyeLabel        = Drawing.new("Text"),
        DribbleStatusLabel   = Drawing.new("Text"),
        DribbleTargetLabel   = Drawing.new("Text"),
        DribbleTacklingLabel = Drawing.new("Text"),
        AutoDribbleLabel     = Drawing.new("Text"),
        CooldownListLabel    = Drawing.new("Text"),
        ModeLabel            = Drawing.new("Text"),
        ManualTackleLabel    = Drawing.new("Text"),
        PingLabel            = Drawing.new("Text"),
        AngleLabel           = Drawing.new("Text"),
        PredictionLabel      = Drawing.new("Text"),
        TargetRingLines      = {},
        TackleDebugLabels    = {},
        DribbleDebugLabels   = {}
    }

    local screenSize = Camera.ViewportSize
    local cx = screenSize.X / 2
    local ty = screenSize.Y * 0.6 + 30
    local dy = screenSize.Y * 0.6 - 50

    local tLabels = {
        Gui.TackleWaitLabel, Gui.TackleTargetLabel, Gui.TackleDribblingLabel,
        Gui.TackleTacklingLabel, Gui.EagleEyeLabel, Gui.CooldownListLabel,
        Gui.ModeLabel, Gui.ManualTackleLabel, Gui.PingLabel, Gui.AngleLabel, Gui.PredictionLabel
    }
    for _, l in ipairs(tLabels) do
        l.Size = 16; l.Color = Color3.fromRGB(255,255,255); l.Outline = true; l.Center = true
        l.Visible = DebugConfig.Enabled and AutoTackleConfig.Enabled
        table.insert(Gui.TackleDebugLabels, l)
    end
    Gui.TackleWaitLabel.Color = Color3.fromRGB(255,165,0)
    for _, l in ipairs(tLabels) do l.Position = Vector2.new(cx, ty); ty += 15 end

    local dLabels = { Gui.DribbleStatusLabel, Gui.DribbleTargetLabel, Gui.DribbleTacklingLabel, Gui.AutoDribbleLabel }
    for _, l in ipairs(dLabels) do
        l.Size = 16; l.Color = Color3.fromRGB(255,255,255); l.Outline = true; l.Center = true
        l.Visible = DebugConfig.Enabled and AutoDribbleConfig.Enabled
        table.insert(Gui.DribbleDebugLabels, l)
    end
    for _, l in ipairs(dLabels) do l.Position = Vector2.new(cx, dy); dy += 15 end

    Gui.TackleWaitLabel.Text = "Wait: 0.00"; Gui.TackleTargetLabel.Text = "Target: None"
    Gui.TackleDribblingLabel.Text = "isDribbling: false"; Gui.TackleTacklingLabel.Text = "isTackling: false"
    Gui.EagleEyeLabel.Text = "EagleEye: Idle"; Gui.CooldownListLabel.Text = "CooldownList: 0"
    Gui.ModeLabel.Text = "Mode: " .. AutoTackleConfig.Mode
    Gui.ManualTackleLabel.Text = "ManualTackle: Ready [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
    Gui.PingLabel.Text = "Ping: 0ms"; Gui.AngleLabel.Text = "Angle: -"; Gui.PredictionLabel.Text = "Pred: -"
    Gui.DribbleStatusLabel.Text = "Dribble: Ready"; Gui.DribbleTargetLabel.Text = "Targets: 0"
    Gui.DribbleTacklingLabel.Text = "Tackle: None"; Gui.AutoDribbleLabel.Text = "AutoDribble: Idle"

    for i = 1, 24 do
        local l = Drawing.new("Line")
        l.Thickness = 3; l.Color = Color3.fromRGB(255,0,0); l.Visible = false
        table.insert(Gui.TargetRingLines, l)
    end
end

local function UpdateDebugVisibility()
    if not Gui then return end
    local tv = DebugConfig.Enabled and AutoTackleConfig.Enabled
    for _, l in ipairs(Gui.TackleDebugLabels) do l.Visible = tv end
    local dv = DebugConfig.Enabled and AutoDribbleConfig.Enabled
    for _, l in ipairs(Gui.DribbleDebugLabels) do l.Visible = dv end
    if not AutoTackleConfig.Enabled then
        for _, l in ipairs(Gui.TargetRingLines) do l.Visible = false end
    end
    if AutoTackleStatus.ButtonGui and AutoTackleStatus.ButtonGui:FindFirstChild("ManualTackleButton") then
        AutoTackleStatus.ButtonGui.ManualTackleButton.Visible = AutoTackleConfig.ManualButton and AutoTackleConfig.Enabled
    end
end

local function CleanupDebugText()
    if not Gui then return end
    if not AutoTackleConfig.Enabled then
        Gui.TackleWaitLabel.Text = "Wait: 0.00"; Gui.TackleTargetLabel.Text = "Target: None"
        Gui.TackleDribblingLabel.Text = "isDribbling: false"; Gui.TackleTacklingLabel.Text = "isTackling: false"
        Gui.EagleEyeLabel.Text = "EagleEye: Idle"; Gui.ModeLabel.Text = "Mode: " .. AutoTackleConfig.Mode
        Gui.ManualTackleLabel.Text = "ManualTackle: Ready [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
        Gui.PingLabel.Text = "Ping: 0ms"; Gui.PredictionLabel.Text = "Pred: -"
    end
    if not AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text = "Dribble: Ready"; Gui.DribbleTargetLabel.Text = "Targets: 0"
        Gui.DribbleTacklingLabel.Text = "Tackle: None"; Gui.AutoDribbleLabel.Text = "AutoDribble: Idle"
    end
end

-- === 3D КРУГИ ===
local function Create3DCircle()
    local c = {}
    for i = 1, 24 do
        local l = Drawing.new("Line")
        l.Thickness = 3; l.Color = Color3.fromRGB(255,0,0); l.Visible = false
        table.insert(c, l)
    end
    return c
end

local function Update3DCircle(circle, pos, radius, color)
    if not circle then return end
    local n = #circle; local pts = {}
    for i = 1, n do
        local a = (i-1) * 2 * math.pi / n
        table.insert(pts, pos + Vector3.new(math.cos(a)*radius, 0, math.sin(a)*radius))
    end
    for i, line in ipairs(circle) do
        local sp = pts[i]; local ep = pts[i % n + 1]
        local ss, son = Camera:WorldToViewportPoint(sp)
        local es, eon = Camera:WorldToViewportPoint(ep)
        if son and eon and ss.Z > 0.1 and es.Z > 0.1 then
            line.From = Vector2.new(ss.X, ss.Y); line.To = Vector2.new(es.X, es.Y)
            line.Color = color; line.Visible = true
        else line.Visible = false end
    end
end

local function Hide3DCircle(c) if c then for _, l in ipairs(c) do l.Visible = false end end end

local function UpdateTargetCircles()
    local cur = {}
    for player, data in pairs(PrecomputedPlayers) do
        if data.IsValid and TackleStates[player] and TackleStates[player].IsTackling then
            cur[player] = true
            if not AutoTackleStatus.TargetCircles[player] then
                AutoTackleStatus.TargetCircles[player] = Create3DCircle()
            end
            local tr = data.RootPart
            if tr then
                local color = data.Distance <= AutoDribbleConfig.DribbleActivationDistance
                    and Color3.fromRGB(0,255,0)
                    or (data.Distance <= AutoDribbleConfig.MaxDribbleDistance
                        and Color3.fromRGB(255,165,0) or Color3.fromRGB(255,0,0))
                Update3DCircle(AutoTackleStatus.TargetCircles[player], tr.Position - Vector3.new(0,0.5,0), 2, color)
            end
        end
    end
    for player, circle in pairs(AutoTackleStatus.TargetCircles) do
        if not cur[player] then Hide3DCircle(circle) end
    end
end

-- === DEBUG ДВИЖЕНИЕ ===
local function SetupDebugMovement()
    if not DebugConfig.MoveEnabled or not Gui then return end
    local isDragging = false; local dragStart = Vector2.new(0,0); local startPositions = {}
    for _, l in ipairs(Gui.TackleDebugLabels) do startPositions[l] = l.Position end
    for _, l in ipairs(Gui.DribbleDebugLabels) do startPositions[l] = l.Position end
    local function upd(delta)
        for l, sp in pairs(startPositions) do if l.Visible then l.Position = sp + delta end end
    end
    UserInputService.InputBegan:Connect(function(inp, gp)
        if gp or not DebugConfig.MoveEnabled then return end
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            local mp = UserInputService:GetMouseLocation()
            for l in pairs(startPositions) do
                if l.Visible then
                    local p = l.Position; local tb = l.TextBounds
                    if mp.X >= p.X - tb.X/2 and mp.X <= p.X + tb.X/2 and
                       mp.Y >= p.Y - tb.Y/2 and mp.Y <= p.Y + tb.Y/2 then
                        isDragging = true; dragStart = mp; break
                    end
                end
            end
        end
    end)
    UserInputService.InputChanged:Connect(function(inp, gp)
        if gp or not DebugConfig.MoveEnabled or not isDragging then return end
        if inp.UserInputType == Enum.UserInputType.MouseMovement then
            upd(UserInputService:GetMouseLocation() - dragStart)
        end
    end)
    UserInputService.InputEnded:Connect(function(inp, gp)
        if gp or not DebugConfig.MoveEnabled then return end
        if inp.UserInputType == Enum.UserInputType.MouseButton1 and isDragging then
            local delta = UserInputService:GetMouseLocation() - dragStart
            for l, sp in pairs(startPositions) do startPositions[l] = sp + delta end
            isDragging = false
        end
    end)
end

-- === UTIL ===
local function CheckIfTypingInChat()
    local ok, res = pcall(function()
        local pg = LocalPlayer:WaitForChild("PlayerGui")
        for _, g in pairs(pg:GetChildren()) do
            if g:IsA("ScreenGui") and (g.Name == "Chat" or g.Name:find("Chat")) then
                local tb = g:FindFirstChild("TextBox", true)
                if tb then return tb:IsFocused() end
            end
        end
        return false
    end)
    return ok and res or false
end

-- === MANUAL TACKLE BUTTON ===
local function SetupManualTackleButton()
    if AutoTackleStatus.ButtonGui then AutoTackleStatus.ButtonGui:Destroy(); AutoTackleStatus.ButtonGui = nil end
    local bg = Instance.new("ScreenGui")
    bg.Name = "ManualTackleButtonGui"; bg.ResetOnSpawn = false; bg.IgnoreGuiInset = false
    bg.Parent = game:GetService("CoreGui")
    local size = 50 * AutoTackleConfig.ButtonScale
    local ss = Camera.ViewportSize
    local bf = Instance.new("Frame")
    bf.Name = "ManualTackleButton"; bf.Size = UDim2.new(0,size,0,size)
    bf.Position = UDim2.new(0, ss.X/2 - size/2, 0, ss.Y*0.7)
    bf.BackgroundColor3 = Color3.fromRGB(20,30,50); bf.BackgroundTransparency = 0.3
    bf.BorderSizePixel = 0; bf.Visible = AutoTackleConfig.ManualButton and AutoTackleConfig.Enabled
    bf.Parent = bg
    Instance.new("UICorner", bf).CornerRadius = UDim.new(0.5, 0)
    local bi = Instance.new("ImageLabel")
    bi.Size = UDim2.new(0, size*0.6, 0, size*0.6); bi.Position = UDim2.new(0.5,-size*0.3,0.5,-size*0.3)
    bi.BackgroundTransparency = 1; bi.Image = "rbxassetid://73279554401260"; bi.Parent = bf
    bf.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            AutoTackleStatus.TouchStartTime = tick()
            local mp = inp.UserInputType == Enum.UserInputType.Touch
                and Vector2.new(inp.Position.X, inp.Position.Y)
                or UserInputService:GetMouseLocation()
            AutoTackleStatus.Dragging = true; AutoTackleStatus.DragStart = mp; AutoTackleStatus.StartPos = bf.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch)
           and AutoTackleStatus.Dragging then
            local mp = inp.UserInputType == Enum.UserInputType.Touch
                and Vector2.new(inp.Position.X, inp.Position.Y)
                or UserInputService:GetMouseLocation()
            local delta = mp - AutoTackleStatus.DragStart
            bf.Position = UDim2.new(AutoTackleStatus.StartPos.X.Scale,
                AutoTackleStatus.StartPos.X.Offset + delta.X,
                AutoTackleStatus.StartPos.Y.Scale,
                AutoTackleStatus.StartPos.Y.Offset + delta.Y)
        end
    end)
    bf.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            AutoTackleStatus.Dragging = false; AutoTackleStatus.TouchStartTime = 0
        end
    end)
    AutoTackleStatus.ButtonGui = bg
end

local function ToggleManualTackleButton(value)
    AutoTackleConfig.ManualButton = value
    if value then SetupManualTackleButton()
    else if AutoTackleStatus.ButtonGui then AutoTackleStatus.ButtonGui:Destroy(); AutoTackleStatus.ButtonGui = nil end end
    UpdateDebugVisibility()
end

local function SetTackleButtonScale(value)
    AutoTackleConfig.ButtonScale = value
    if AutoTackleConfig.ManualButton then SetupManualTackleButton() end
end

-- === ПРОВЕРКИ СОСТОЯНИЙ ===
local function IsDribbling(targetPlayer)
    if not targetPlayer or not targetPlayer.Character or not targetPlayer.Parent
       or targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
    local h = targetPlayer.Character:FindFirstChild("Humanoid")
    if not h then return false end
    local a = h:FindFirstChild("Animator")
    if not a then return false end
    for _, track in pairs(a:GetPlayingAnimationTracks()) do
        if track.Animation and table.find(DribbleAnimIds, track.Animation.AnimationId) then return true end
    end
    return false
end

local function IsSpecificTackle(targetPlayer)
    if not targetPlayer or not targetPlayer.Character or not targetPlayer.Parent
       or targetPlayer.TeamColor == LocalPlayer.TeamColor then return false end
    local h = targetPlayer.Character:FindFirstChild("Humanoid")
    if not h then return false end
    local a = h:FindFirstChild("Animator")
    if not a then return false end
    for _, track in pairs(a:GetPlayingAnimationTracks()) do
        if track.Animation and track.Animation.AnimationId == SPECIFIC_TACKLE_ID then return true end
    end
    return false
end

local function IsPowerShooting(targetPlayer)
    if not targetPlayer then return false end
    local pf = Workspace:FindFirstChild(targetPlayer.Name)
    if not pf then return false end
    local bl = pf:FindFirstChild("Bools")
    if not bl then return false end
    local ps = bl:FindFirstChild("PowerShooting")
    return ps and ps.Value == true
end

-- === DRIBBLE STATES ===
local function UpdateDribbleStates()
    local now = tick()
    for _, player in pairs(Players:GetPlayers()) do
        if player == LocalPlayer or not player.Parent or player.TeamColor == LocalPlayer.TeamColor then continue end
        if not DribbleStates[player] then
            DribbleStates[player] = { IsDribbling = false, LastDribbleEnd = 0, IsProcessingDelay = false, HadDribble = false }
        end
        local s = DribbleStates[player]
        local curDrib = IsDribbling(player)
        if curDrib and not s.IsDribbling then
            s.IsDribbling = true; s.IsProcessingDelay = false; s.HadDribble = true
        elseif not curDrib and s.IsDribbling then
            s.IsDribbling = false; s.LastDribbleEnd = now; s.IsProcessingDelay = true
        elseif s.IsProcessingDelay and not curDrib then
            if now - s.LastDribbleEnd >= AutoTackleConfig.DribbleDelayTime then
                DribbleCooldownList[player] = now + 3.5; s.IsProcessingDelay = false
            end
        end
    end
    local rem = {}
    for player, endT in pairs(DribbleCooldownList) do
        if not player or not player.Parent or now >= endT then table.insert(rem, player) end
    end
    for _, p in ipairs(rem) do DribbleCooldownList[p] = nil; EagleEyeTimers[p] = nil end
    if Gui and AutoTackleConfig.Enabled then
        local cnt = 0; for _ in pairs(DribbleCooldownList) do cnt += 1 end
        Gui.CooldownListLabel.Text = "CooldownList: " .. cnt
    end
end

-- === PRECOMPUTE PLAYERS ===
local function PrecomputePlayers()
    PrecomputedPlayers = {}; HasBall = false; CanDribbleNow = false
    local ball = Workspace:FindFirstChild("ball")
    if ball and ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator") then
        HasBall = ball.creator.Value == LocalPlayer
    end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if bools then
        CanDribbleNow = not bools.dribbleDebounce.Value
        if Gui and AutoDribbleConfig.Enabled then
            Gui.DribbleStatusLabel.Text = bools.dribbleDebounce.Value and "Dribble: Cooldown" or "Dribble: Ready"
            Gui.DribbleStatusLabel.Color = bools.dribbleDebounce.Value and Color3.fromRGB(255,0,0) or Color3.fromRGB(0,255,0)
        end
    end
    for _, player in pairs(Players:GetPlayers()) do
        if player == LocalPlayer or not player.Parent or player.TeamColor == LocalPlayer.TeamColor then continue end
        local ch = player.Character; if not ch then continue end
        local hm = ch:FindFirstChild("Humanoid"); if not hm or hm.HipHeight >= 4 then continue end
        local tr = ch:FindFirstChild("HumanoidRootPart"); if not tr then continue end
        TackleStates[player] = TackleStates[player] or { IsTackling = false }
        TackleStates[player].IsTackling = IsSpecificTackle(player)
        local dist = (tr.Position - HumanoidRootPart.Position).Magnitude
        if dist > math.max(AutoDribbleConfig.MaxDribbleDistance, AutoTackleConfig.MaxDistance) then continue end
        PrecomputedPlayers[player] = {
            Distance = dist, IsValid = true,
            IsTackling = TackleStates[player].IsTackling,
            RootPart = tr, Velocity = tr.AssemblyLinearVelocity
        }
    end
end

-- === РОТАЦИЯ ===
local function RotateToTarget(targetPos)
    if AutoTackleConfig.RotationMethod == "None" then return end
    local my = HumanoidRootPart.Position
    local dir = Vector3.new(targetPos.X - my.X, 0, targetPos.Z - my.Z)
    if dir.Magnitude > 0.1 then
        HumanoidRootPart.CFrame = CFrame.new(my, my + dir)
    end
end

-- === ПРОВЕРКА CanTackle ===
local function CanTackle()
    local ball = Workspace:FindFirstChild("ball")
    if not ball or not ball.Parent then return false, nil, nil, nil end
    local hasOwner = ball:FindFirstChild("playerWeld") and ball:FindFirstChild("creator")
    local owner = hasOwner and ball.creator.Value or nil
    if AutoTackleConfig.OnlyPlayer and (not hasOwner or not owner or not owner.Parent) then return false, nil, nil, nil end
    if owner and owner.TeamColor == LocalPlayer.TeamColor then return false, nil, nil, nil end
    if Workspace:FindFirstChild("Bools") and
       (Workspace.Bools.APG.Value == LocalPlayer or Workspace.Bools.HPG.Value == LocalPlayer) then
        return false, nil, nil, nil
    end
    local dist = (HumanoidRootPart.Position - ball.Position).Magnitude
    if dist > AutoTackleConfig.MaxDistance then return false, nil, nil, nil end
    if owner and owner.Character then
        local oh = owner.Character:FindFirstChild("Humanoid")
        if oh and oh.HipHeight >= 4 then return false, nil, nil, nil end
    end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if bools and (bools.TackleDebounce.Value or bools.Tackled.Value
       or (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value)) then
        return false, nil, nil, nil
    end
    return true, ball, dist, owner
end

-- === PERFORM TACKLE ===
local function PerformTackle(ball, owner)
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not bools or bools.TackleDebounce.Value or bools.Tackled.Value
       or (Character:FindFirstChild("Bools") and Character.Bools.Debounce.Value) then return end

    local ownerRoot = owner and owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")

    -- Вычисляем точку перехвата
    local interceptPos
    if ownerRoot and owner then
        interceptPos = ComputeInterceptPoint(ownerRoot, owner)
    else
        interceptPos = ball.Position
    end

    -- Ротируемся к точке перехвата
    RotateToTarget(interceptPos)

    -- firetouchinterest для регистрации хита на сервере
    if ownerRoot then
        pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 0) end)
        pcall(function() firetouchinterest(HumanoidRootPart, ownerRoot, 1) end)
    end

    pcall(function() ActionRemote:FireServer("TackIe") end)

    local bv = Instance.new("BodyVelocity")
    bv.Parent = HumanoidRootPart
    bv.Velocity = HumanoidRootPart.CFrame.LookVector * AutoTackleConfig.TackleSpeed
    bv.MaxForce = Vector3.new(50000000, 0, 50000000)

    local tackleDuration = 0.65
    local startTime = tick()

    -- В режиме "Always" продолжаем пересчитывать interceptPos в полёте
    if AutoTackleConfig.RotationMethod == "Always" and ownerRoot and owner then
        local conn
        conn = RunService.Heartbeat:Connect(function()
            if tick() - startTime < tackleDuration then
                RotateToTarget(ComputeInterceptPoint(ownerRoot, owner))
            else conn:Disconnect() end
        end)
        task.delay(tackleDuration, function() conn:Disconnect() end)
    end

    Debris:AddItem(bv, tackleDuration)

    if owner and ball:FindFirstChild("playerWeld") then
        local d = (HumanoidRootPart.Position - ball.Position).Magnitude
        pcall(function() SoftDisPlayerRemote:FireServer(owner, d, false, ball.Size) end)
    end
end

-- === MANUAL TACKLE ===
local function ManualTackleAction()
    local now = tick()
    if now - LastManualTackleTime < AutoTackleConfig.ManualTackleCooldown then return false end
    local canTackle, ball, dist, owner = CanTackle()
    if canTackle then
        LastManualTackleTime = now; PerformTackle(ball, owner)
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text = "ManualTackle: EXECUTED! [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
            Gui.ManualTackleLabel.Color = Color3.fromRGB(0,255,0)
        end
        task.delay(0.3, function() if Gui and AutoTackleConfig.Enabled then Gui.ManualTackleLabel.Color = Color3.fromRGB(255,255,255) end end)
        return true
    else
        if Gui and AutoTackleConfig.Enabled then
            Gui.ManualTackleLabel.Text = "ManualTackle: FAILED [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
            Gui.ManualTackleLabel.Color = Color3.fromRGB(255,0,0)
        end
        task.delay(0.3, function() if Gui and AutoTackleConfig.Enabled then Gui.ManualTackleLabel.Color = Color3.fromRGB(255,255,255) end end)
        return false
    end
end

-- =============================================================
-- === AUTOTACKLE MODULE
-- =============================================================
local AutoTackle = {}
AutoTackle.Start = function()
    if AutoTackleStatus.Running then return end
    AutoTackleStatus.Running = true
    if not Gui then SetupGUI() end

    AutoTackleStatus.HeartbeatConnection = RunService.Heartbeat:Connect(function()
        pcall(UpdatePing)
        pcall(UpdateDribbleStates)
        pcall(PrecomputePlayers)
        pcall(UpdateTargetCircles)
        IsTypingInChat = CheckIfTypingInChat()
    end)

    AutoTackleStatus.InputConnection = UserInputService.InputBegan:Connect(function(inp, gp)
        if gp or not AutoTackleConfig.Enabled or not AutoTackleConfig.ManualTackleEnabled then return end
        if IsTypingInChat then return end
        if inp.KeyCode == AutoTackleConfig.ManualTackleKeybind then ManualTackleAction() end
    end)

    AutoTackleStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoTackleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end
        pcall(function()
            local canTackle, ball, dist, owner = CanTackle()
            if not canTackle or not ball then
                if Gui then
                    Gui.TackleTargetLabel.Text = "Target: None"; Gui.TackleDribblingLabel.Text = "isDribbling: false"
                    Gui.TackleTacklingLabel.Text = "isTackling: false"; Gui.TackleWaitLabel.Text = "Wait: 0.00"
                    Gui.EagleEyeLabel.Text = "EagleEye: Idle"
                    if AutoTackleConfig.Mode == "ManualTackle" then
                        Gui.ManualTackleLabel.Text = "ManualTackle: NO TARGET [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
                        Gui.ManualTackleLabel.Color = Color3.fromRGB(255,0,0)
                    end
                end
                CurrentTargetOwner = nil; return
            end

            if Gui then
                Gui.TackleTargetLabel.Text = "Target: " .. (owner and owner.Name or "None")
                Gui.TackleDribblingLabel.Text = "isDribbling: " .. tostring(owner and DribbleStates[owner] and DribbleStates[owner].IsDribbling or false)
                Gui.TackleTacklingLabel.Text = "isTackling: " .. tostring(owner and IsSpecificTackle(owner) or false)
            end

            -- Мгновенный такл при малой дистанции
            if dist <= AutoTackleConfig.TackleDistance then
                PerformTackle(ball, owner); if Gui then Gui.EagleEyeLabel.Text = "Instant Tackle" end; return
            end

            -- PowerShooting
            if owner and IsPowerShooting(owner) then
                PerformTackle(ball, owner); if Gui then Gui.EagleEyeLabel.Text = "PowerShooting!" end; return
            end

            CurrentTargetOwner = owner
            if AutoTackleConfig.Mode == "ManualTackle" then
                if Gui then
                    Gui.EagleEyeLabel.Text = "ManualTackle: Ready"
                    Gui.ManualTackleLabel.Text = "ManualTackle: READY [" .. tostring(AutoTackleConfig.ManualTackleKeybind) .. "]"
                    Gui.ManualTackleLabel.Color = Color3.fromRGB(0,255,0)
                end
                return
            end
            if not owner then return end

            local state = DribbleStates[owner] or { IsDribbling = false, LastDribbleEnd = 0, IsProcessingDelay = false }
            local isDribbling = state.IsDribbling
            local inCooldownList = DribbleCooldownList[owner] ~= nil
            local now = tick()

            -- ==================== OnlyDribble ====================
            if AutoTackleConfig.Mode == "OnlyDribble" then
                if inCooldownList then
                    PerformTackle(ball, owner); if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Tackling!" end
                elseif isDribbling then
                    if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Dribbling..."; Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f", AutoTackleConfig.DribbleDelayTime) end
                elseif state.IsProcessingDelay then
                    local rem = AutoTackleConfig.DribbleDelayTime - (now - state.LastDribbleEnd)
                    if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: DribDelay"; Gui.TackleWaitLabel.Text = string.format("Wait: %.2f", rem) end
                else
                    if Gui then Gui.EagleEyeLabel.Text = "OnlyDribble: Waiting dribble"; Gui.TackleWaitLabel.Text = "Wait: -" end
                end

            -- ==================== EagleEye ====================
            elseif AutoTackleConfig.Mode == "EagleEye" then
                if isDribbling then
                    EagleEyeTimers[owner] = nil
                    if Gui then Gui.TackleWaitLabel.Text = "Wait: DRIBBLE"; Gui.EagleEyeLabel.Text = "EagleEye: Dribbling (reset)" end
                elseif state.IsProcessingDelay then
                    EagleEyeTimers[owner] = nil
                    local rem = AutoTackleConfig.DribbleDelayTime - (now - state.LastDribbleEnd)
                    if Gui then Gui.TackleWaitLabel.Text = string.format("DDelay: %.2f", rem); Gui.EagleEyeLabel.Text = "EagleEye: DribbleDelay" end
                elseif inCooldownList then
                    PerformTackle(ball, owner); EagleEyeTimers[owner] = nil
                    if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Post-Dribble Tackle!" end
                else
                    if not EagleEyeTimers[owner] then
                        EagleEyeTimers[owner] = {
                            startTime = now,
                            waitTime = AutoTackleConfig.EagleEyeMinDelay +
                                math.random() * (AutoTackleConfig.EagleEyeMaxDelay - AutoTackleConfig.EagleEyeMinDelay)
                        }
                    end
                    local timer = EagleEyeTimers[owner]
                    local elapsed = now - timer.startTime
                    if elapsed >= timer.waitTime then
                        PerformTackle(ball, owner); EagleEyeTimers[owner] = nil
                        if Gui then Gui.EagleEyeLabel.Text = "EagleEye: Tackling!" end
                    else
                        if Gui then
                            Gui.TackleWaitLabel.Text = string.format("Wait: %.2f", timer.waitTime - elapsed)
                            Gui.EagleEyeLabel.Text = "EagleEye: Waiting"
                        end
                    end
                end
            end
        end)
    end)

    if AutoTackleConfig.ManualButton then SetupManualTackleButton() end
    if DebugConfig.MoveEnabled then SetupDebugMovement() end
    UpdateDebugVisibility()
    if notify then notify("AutoTackle", "Started", true) end
end

AutoTackle.Stop = function()
    if AutoTackleStatus.Connection then AutoTackleStatus.Connection:Disconnect(); AutoTackleStatus.Connection = nil end
    if AutoTackleStatus.HeartbeatConnection then AutoTackleStatus.HeartbeatConnection:Disconnect(); AutoTackleStatus.HeartbeatConnection = nil end
    if AutoTackleStatus.InputConnection then AutoTackleStatus.InputConnection:Disconnect(); AutoTackleStatus.InputConnection = nil end
    AutoTackleStatus.Running = false
    CleanupDebugText(); UpdateDebugVisibility()
    for _, circle in pairs(AutoTackleStatus.TargetCircles) do for _, l in ipairs(circle) do l:Remove() end end
    AutoTackleStatus.TargetCircles = {}
    if AutoTackleStatus.ButtonGui then AutoTackleStatus.ButtonGui:Destroy(); AutoTackleStatus.ButtonGui = nil end
    if notify then notify("AutoTackle", "Stopped", true) end
end

-- =============================================================
-- === AUTODRIBBLE MODULE
-- =============================================================
-- ShouldDribbleNow:
-- 1. Таклер активен (IsTackling)
-- 2. Угол: вектор движения таклера направлен в нас (< HeadOnAngleThreshold)
--    Используем CFrame.LookVector если скорость мала — т.к. при такле
--    игрок уже повёрнут в нужную сторону, скорость может быть 0 в начале
-- 3. Либо дистанция <= DribbleActivationDistance (реакция всегда)
-- Проверка скорости убрана — это была причина поздней реакции

local function ShouldDribbleNow(specificTarget, tacklerData)
    if not specificTarget or not tacklerData then return false end
    local tacklerRoot = tacklerData.RootPart
    if not tacklerRoot then return false end

    local myPos = Vector3.new(HumanoidRootPart.Position.X, 0, HumanoidRootPart.Position.Z)
    local tPos = Vector3.new(tacklerRoot.Position.X, 0, tacklerRoot.Position.Z)
    local dist = tacklerData.Distance

    -- Всегда реагируем при малой дистанции
    if dist <= AutoDribbleConfig.DribbleActivationDistance then return true end
    if dist > AutoDribbleConfig.MaxDribbleDistance then return false end

    local toMe = (myPos - tPos)
    if toMe.Magnitude < 0.1 then return false end
    local dirToMe = toMe.Unit

    -- Используем velocity если она достаточна, иначе LookVector (таклер уже в анимации)
    local vel = tacklerData.Velocity
    local flatVel = Vector3.new(vel.X, 0, vel.Z)
    local tacklerDir
    if flatVel.Magnitude > 2 then
        tacklerDir = flatVel.Unit
    else
        -- Берём LookVector из CFrame HRP
        local lv = tacklerRoot.CFrame.LookVector
        tacklerDir = Vector3.new(lv.X, 0, lv.Z).Unit
    end

    local dot = tacklerDir:Dot(dirToMe)
    local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))

    if Gui and AutoDribbleConfig.Enabled then
        Gui.AngleLabel.Text = string.format("Angle: %.1f° | dist=%.1f", angle, dist)
    end

    return angle < AutoDribbleConfig.HeadOnAngleThreshold
end

local function PerformDribble()
    local now = tick()
    if now - AutoDribbleStatus.LastDribbleTime < 0.05 then return end
    local bools = Workspace:FindFirstChild(LocalPlayer.Name) and Workspace[LocalPlayer.Name]:FindFirstChild("Bools")
    if not bools or bools.dribbleDebounce.Value then return end
    pcall(function() ActionRemote:FireServer("Deke") end)
    AutoDribbleStatus.LastDribbleTime = now
    if Gui and AutoDribbleConfig.Enabled then
        Gui.DribbleStatusLabel.Text = "Dribble: Cooldown"
        Gui.DribbleStatusLabel.Color = Color3.fromRGB(255,0,0)
        Gui.AutoDribbleLabel.Text = "AutoDribble: DEKE!"
    end
end

local AutoDribble = {}
AutoDribble.Start = function()
    if AutoDribbleStatus.Running then return end
    AutoDribbleStatus.Running = true

    AutoDribbleStatus.HeartbeatConnection = RunService.Heartbeat:Connect(function()
        if not AutoDribbleConfig.Enabled then return end
        pcall(function()
            UpdatePing(); UpdateDribbleStates(); PrecomputePlayers(); UpdateTargetCircles()
            IsTypingInChat = CheckIfTypingInChat()
        end)
    end)

    if not Gui then SetupGUI() end

    -- RenderStepped для минимальной задержки реакции
    AutoDribbleStatus.Connection = RunService.RenderStepped:Connect(function()
        if not AutoDribbleConfig.Enabled then CleanupDebugText(); UpdateDebugVisibility(); return end
        pcall(function()
            local specificTarget, minDist, targetCount, nearestData = nil, math.huge, 0, nil
            for player, data in pairs(PrecomputedPlayers) do
                if data.IsValid and TackleStates[player] and TackleStates[player].IsTackling then
                    targetCount += 1
                    if data.Distance < minDist then
                        minDist = data.Distance; specificTarget = player; nearestData = data
                    end
                end
            end
            if Gui then
                Gui.DribbleTargetLabel.Text = "Targets: " .. targetCount
                Gui.DribbleTacklingLabel.Text = specificTarget and string.format("Tackle: %.1f", minDist) or "Tackle: None"
            end
            if HasBall and CanDribbleNow and specificTarget and nearestData then
                if ShouldDribbleNow(specificTarget, nearestData) then
                    PerformDribble()
                else
                    if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Waiting" end
                end
            else
                if Gui then Gui.AutoDribbleLabel.Text = "AutoDribble: Idle" end
            end
        end)
    end)

    UpdateDebugVisibility()
    if notify then notify("AutoDribble", "Started", true) end
end

AutoDribble.Stop = function()
    if AutoDribbleStatus.Connection then AutoDribbleStatus.Connection:Disconnect(); AutoDribbleStatus.Connection = nil end
    if AutoDribbleStatus.HeartbeatConnection then AutoDribbleStatus.HeartbeatConnection:Disconnect(); AutoDribbleStatus.HeartbeatConnection = nil end
    AutoDribbleStatus.Running = false
    CleanupDebugText(); UpdateDebugVisibility()
    if notify then notify("AutoDribble", "Stopped", true) end
end

-- =============================================================
-- === UI
-- =============================================================
local uiElements = {}
local function SetupUI(UI)
    if UI.Sections.AutoTackle then
        UI.Sections.AutoTackle:Header({ Name = "AutoTackle" })
        UI.Sections.AutoTackle:Divider()

        uiElements.AutoTackleEnabled = UI.Sections.AutoTackle:Toggle({
            Name = "Enabled", Default = AutoTackleConfig.Enabled,
            Callback = function(v) AutoTackleConfig.Enabled = v
                if v then AutoTackle.Start() else AutoTackle.Stop() end; UpdateDebugVisibility() end
        }, "AutoTackleEnabled")

        uiElements.AutoTackleMode = UI.Sections.AutoTackle:Dropdown({
            Name = "Mode", Default = AutoTackleConfig.Mode,
            Options = { "OnlyDribble", "EagleEye", "ManualTackle" },
            Callback = function(v) AutoTackleConfig.Mode = v; if Gui then Gui.ModeLabel.Text = "Mode: " .. v end end
        }, "AutoTackleMode")

        UI.Sections.AutoTackle:Divider()

        uiElements.AutoTackleMaxDistance = UI.Sections.AutoTackle:Slider({
            Name = "Max Distance", Minimum = 5, Maximum = 50,
            Default = AutoTackleConfig.MaxDistance, Precision = 1,
            Callback = function(v) AutoTackleConfig.MaxDistance = v end
        }, "AutoTackleMaxDistance")

        uiElements.AutoTackleTackleDistance = UI.Sections.AutoTackle:Slider({
            Name = "Instant Tackle Distance", Minimum = 0, Maximum = 20,
            Default = AutoTackleConfig.TackleDistance, Precision = 1,
            Callback = function(v) AutoTackleConfig.TackleDistance = v end
        }, "AutoTackleTackleDistance")

        uiElements.AutoTackleTackleSpeed = UI.Sections.AutoTackle:Slider({
            Name = "Tackle Speed", Minimum = 10, Maximum = 100,
            Default = AutoTackleConfig.TackleSpeed, Precision = 1,
            Callback = function(v) AutoTackleConfig.TackleSpeed = v end
        }, "AutoTackleTackleSpeed")

        UI.Sections.AutoTackle:Divider()

        uiElements.AutoTackleOnlyPlayer = UI.Sections.AutoTackle:Toggle({
            Name = "Only Player", Default = AutoTackleConfig.OnlyPlayer,
            Callback = function(v) AutoTackleConfig.OnlyPlayer = v end
        }, "AutoTackleOnlyPlayer")

        uiElements.AutoTackleRotationMethod = UI.Sections.AutoTackle:Dropdown({
            Name = "Rotation Method", Default = AutoTackleConfig.RotationMethod,
            Options = { "Snap", "Always", "None" },
            Callback = function(v) AutoTackleConfig.RotationMethod = v end
        }, "AutoTackleRotationMethod")

        UI.Sections.AutoTackle:Divider()

        uiElements.AutoTackleDribbleDelay = UI.Sections.AutoTackle:Slider({
            Name = "Dribble Delay", Minimum = 0.0, Maximum = 2.0,
            Default = AutoTackleConfig.DribbleDelayTime, Precision = 2,
            Callback = function(v) AutoTackleConfig.DribbleDelayTime = v end
        }, "AutoTackleDribbleDelay")

        uiElements.AutoTackleEagleEyeMinDelay = UI.Sections.AutoTackle:Slider({
            Name = "EagleEye Min Delay", Minimum = 0.0, Maximum = 2.0,
            Default = AutoTackleConfig.EagleEyeMinDelay, Precision = 2,
            Callback = function(v) AutoTackleConfig.EagleEyeMinDelay = v end
        }, "AutoTackleEagleEyeMinDelay")

        uiElements.AutoTackleEagleEyeMaxDelay = UI.Sections.AutoTackle:Slider({
            Name = "EagleEye Max Delay", Minimum = 0.0, Maximum = 2.0,
            Default = AutoTackleConfig.EagleEyeMaxDelay, Precision = 2,
            Callback = function(v) AutoTackleConfig.EagleEyeMaxDelay = v end
        }, "AutoTackleEagleEyeMaxDelay")

        UI.Sections.AutoTackle:Divider()

        uiElements.AutoTackleManualTackleEnabled = UI.Sections.AutoTackle:Toggle({
            Name = "Manual Tackle Enabled", Default = AutoTackleConfig.ManualTackleEnabled,
            Callback = function(v) AutoTackleConfig.ManualTackleEnabled = v end
        }, "AutoTackleManualTackleEnabled")

        uiElements.AutoTackleManualTackleKeybind = UI.Sections.AutoTackle:Keybind({
            Name = "Manual Tackle Key", Default = AutoTackleConfig.ManualTackleKeybind,
            Callback = function(v) AutoTackleConfig.ManualTackleKeybind = v end
        }, "AutoTackleManualTackleKeybind")

        uiElements.AutoTackleManualButton = UI.Sections.AutoTackle:Toggle({
            Name = "Manual Button", Default = AutoTackleConfig.ManualButton,
            Callback = ToggleManualTackleButton
        }, "AutoTackleManualButton")

        uiElements.AutoTackleButtonScale = UI.Sections.AutoTackle:Slider({
            Name = "Button Scale", Minimum = 0.5, Maximum = 2.0,
            Default = AutoTackleConfig.ButtonScale, Precision = 2,
            Callback = SetTackleButtonScale
        }, "AutoTackleButtonScale")

        UI.Sections.AutoTackle:Divider()
        UI.Sections.AutoTackle:Paragraph({
            Header = "Предикт (Intercept Point)",
            Body = "Такл летит к точке перехвата, решая уравнение встречи.\n" ..
                   "Позиция врага компенсируется на ping/2 вперёд (мы видим его прошлое).\n" ..
                   "TackleSpeed влияет на точность — ставь реальное значение.\n" ..
                   "OnlyDribble: ждёт дриббл врага → DribbleDelay → таклит\n" ..
                   "EagleEye: рандомный таймер; сброс при дрибе → DribbleDelay → такл\n" ..
                   "ManualTackle: только по кнопке"
        })
    end

    if UI.Sections.AutoDribble then
        UI.Sections.AutoDribble:Header({ Name = "AutoDribble" })
        UI.Sections.AutoDribble:Divider()

        uiElements.AutoDribbleEnabled = UI.Sections.AutoDribble:Toggle({
            Name = "Enabled", Default = AutoDribbleConfig.Enabled,
            Callback = function(v) AutoDribbleConfig.Enabled = v
                if v then AutoDribble.Start() else AutoDribble.Stop() end; UpdateDebugVisibility() end
        }, "AutoDribbleEnabled")

        UI.Sections.AutoDribble:Divider()

        uiElements.AutoDribbleMaxDistance = UI.Sections.AutoDribble:Slider({
            Name = "Max Distance", Minimum = 10, Maximum = 50,
            Default = AutoDribbleConfig.MaxDribbleDistance, Precision = 1,
            Callback = function(v) AutoDribbleConfig.MaxDribbleDistance = v end
        }, "AutoDribbleMaxDistance")

        uiElements.AutoDribbleActivationDistance = UI.Sections.AutoDribble:Slider({
            Name = "Activation Distance", Minimum = 5, Maximum = 30,
            Default = AutoDribbleConfig.DribbleActivationDistance, Precision = 1,
            Callback = function(v) AutoDribbleConfig.DribbleActivationDistance = v end
        }, "AutoDribbleActivationDistance")

        uiElements.AutoDribbleHeadOnAngle = UI.Sections.AutoDribble:Slider({
            Name = "Head-On Angle (°)", Minimum = 10, Maximum = 90,
            Default = AutoDribbleConfig.HeadOnAngleThreshold, Precision = 0,
            Callback = function(v) AutoDribbleConfig.HeadOnAngleThreshold = v; AutoDribbleConfig.MinAngleForDribble = v end
        }, "AutoDribbleHeadOnAngle")

        UI.Sections.AutoDribble:Divider()
        UI.Sections.AutoDribble:Paragraph({
            Header = "Информация",
            Body = "Head-On Angle: угол в котором таклер должен смотреть на тебя (меньше = строже).\n" ..
                   "При dist ≤ Activation Distance реагируем всегда независимо от угла.\n" ..
                   "Проверка скорости убрана — реакция максимально быстрая."
        })
    end

    if UI.Sections.Debug then
        UI.Sections.Debug:Header({ Name = "Debug" })
        UI.Sections.Debug:SubLabel({ Text = "* Only for AutoDribble/AutoTackle" })
        UI.Sections.Debug:Divider()

        uiElements.DebugEnabled = UI.Sections.Debug:Toggle({
            Name = "Debug Text Enabled", Default = DebugConfig.Enabled,
            Callback = function(v) DebugConfig.Enabled = v; UpdateDebugVisibility() end
        }, "DebugEnabled")

        uiElements.DebugMoveEnabled = UI.Sections.Debug:Toggle({
            Name = "Move Debug Text", Default = DebugConfig.MoveEnabled,
            Callback = function(v) DebugConfig.MoveEnabled = v; if v then SetupDebugMovement() end end
        }, "DebugMoveEnabled")
    end
end

local function SynchronizeConfigValues()
    if not uiElements then return end
    local sync = {
        { uiElements.AutoTackleMaxDistance,       function(v) AutoTackleConfig.MaxDistance = v end },
        { uiElements.AutoTackleTackleDistance,    function(v) AutoTackleConfig.TackleDistance = v end },
        { uiElements.AutoTackleTackleSpeed,       function(v) AutoTackleConfig.TackleSpeed = v end },
        { uiElements.AutoTackleDribbleDelay,      function(v) AutoTackleConfig.DribbleDelayTime = v end },
        { uiElements.AutoTackleEagleEyeMinDelay,  function(v) AutoTackleConfig.EagleEyeMinDelay = v end },
        { uiElements.AutoTackleEagleEyeMaxDelay,  function(v) AutoTackleConfig.EagleEyeMaxDelay = v end },
        { uiElements.AutoTackleButtonScale,       function(v) AutoTackleConfig.ButtonScale = v end },
        { uiElements.AutoDribbleMaxDistance,      function(v) AutoDribbleConfig.MaxDribbleDistance = v end },
        { uiElements.AutoDribbleActivationDistance, function(v) AutoDribbleConfig.DribbleActivationDistance = v end },
        { uiElements.AutoDribbleHeadOnAngle,      function(v) AutoDribbleConfig.HeadOnAngleThreshold = v; AutoDribbleConfig.MinAngleForDribble = v end },
    }
    for _, pair in ipairs(sync) do
        local elem, setter = pair[1], pair[2]
        if elem and elem.GetValue then pcall(function() setter(elem:GetValue()) end) end
    end
end

-- === МОДУЛЬ ===
local AutoDribbleTackleModule = {}
function AutoDribbleTackleModule.Init(UI, coreParam, notifyFunc)
    core = coreParam; Services = core.Services; PlayerData = core.PlayerData
    notify = notifyFunc; LocalPlayerObj = PlayerData.LocalPlayer

    SetupUI(UI)

    local syncTimer = 0
    RunService.Heartbeat:Connect(function(dt)
        syncTimer += dt
        if syncTimer >= 1.0 then syncTimer = 0; SynchronizeConfigValues() end
    end)

    LocalPlayerObj.CharacterAdded:Connect(function(newChar)
        task.wait(1)
        Character = newChar
        Humanoid = newChar:WaitForChild("Humanoid")
        HumanoidRootPart = newChar:WaitForChild("HumanoidRootPart")
        DribbleStates = {}; TackleStates = {}; PrecomputedPlayers = {}
        DribbleCooldownList = {}; EagleEyeTimers = {}
        AutoTackleStatus.PosHistory = {}; AutoTackleStatus.TargetCircles = {}
        CurrentTargetOwner = nil
        if AutoTackleConfig.Enabled and not AutoTackleStatus.Running then AutoTackle.Start() end
        if AutoDribbleConfig.Enabled and not AutoDribbleStatus.Running then AutoDribble.Start() end
    end)
end

function AutoDribbleTackleModule:Destroy()
    AutoTackle.Stop(); AutoDribble.Stop()
end

return AutoDribbleTackleModule
