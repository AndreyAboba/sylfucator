-- [v36.0] AUTO SHOOT + AUTO PICKUP — Smart GK-aware, zero manual config
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Camera = Workspace.CurrentCamera
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local BallAttachment = Character:WaitForChild("ball")
local Humanoid = Character:WaitForChild("Humanoid")

local Shooter = ReplicatedStorage.Remotes:WaitForChild("ShootTheBaII")
local PickupRemote
for _, r in ReplicatedStorage.Remotes:GetChildren() do
    if r:IsA("RemoteEvent") and r:GetAttribute("Attribute") then
        PickupRemote = r; break
    end
end

local Animations = ReplicatedStorage:WaitForChild("Animations")
local RShootAnim = Humanoid:LoadAnimation(Animations:WaitForChild("RShoot"))
RShootAnim.Priority = Enum.AnimationPriority.Action4
local IsAnimating = false
local AnimationHoldTime = 0.6

-- ============================================================
-- КОНФИГ — только параметры которые не зависят от ворот/позиции
-- ============================================================
local AutoShootEnabled   = false
local AutoShootLegit     = true
local AutoShootManualShot = true
local AutoShootShootKey  = Enum.KeyCode.G
local AutoShootMaxDistance = 160
local AutoShootDebugText = true
local AutoShootManualButton = false
local AutoShootButtonScale  = 1.0
local AutoShootSpoofPowerEnabled = false
local AutoShootSpoofPowerType    = "math.huge"
-- Физика
local GRAVITY         = 196.2  -- studs/s² (Roblox workspace default)
local BALL_SPEED      = 200    -- studs/s — базовая скорость мяча (power=1 → ~200 studs/s)
local INSET           = 1.5    -- отступ от штанг внутрь (studs)

-- ============================================================
-- STATUS
-- ============================================================
local AutoShootStatus = {
    Running = false, Connection = nil, RenderConnection = nil,
    InputConnection = nil, ButtonGui = nil,
    TouchStartTime = 0, Dragging = false,
    DragStart = Vector2.new(0,0), StartPos = UDim2.new(0,0,0,0)
}
local AutoPickupEnabled    = true
local AutoPickupDist       = 180
local AutoPickupSpoofValue = 2.8
local AutoPickupStatus     = { Running = false, Connection = nil }

-- ============================================================
-- GUI
-- ============================================================
local Gui = nil
local function SetupGUI()
    Gui = {
        Status = Drawing.new("Text"), Dist   = Drawing.new("Text"),
        Target = Drawing.new("Text"), Power  = Drawing.new("Text"),
        Spin   = Drawing.new("Text"), GK     = Drawing.new("Text"),
        Debug  = Drawing.new("Text"), Mode   = Drawing.new("Text"),
        Goal   = Drawing.new("Text"),
    }
    local s = Camera.ViewportSize
    local cx, y = s.X / 2, s.Y * 0.46
    for i, v in ipairs({Gui.Status, Gui.Dist, Gui.Target, Gui.Power, Gui.Spin, Gui.GK, Gui.Debug, Gui.Mode, Gui.Goal}) do
        v.Size = 18; v.Color = Color3.fromRGB(255,255,255); v.Outline = true; v.Center = true
        v.Position = Vector2.new(cx, y + (i-1)*20); v.Visible = AutoShootDebugText
    end
    Gui.Status.Text = "v36.0: Ready"
end

local function ToggleDebugText(value)
    if not Gui then return end
    for _, v in pairs(Gui) do v.Visible = value end
end

-- ============================================================
-- 3D КУБЫ: зелёный = выбранная цель, красный = зона ворот, голубой = NoSpin
-- ============================================================
local TargetCube, GoalCube, NoSpinCube = {}, {}, {}
local function InitializeCubes()
    for i = 1, 12 do
        if TargetCube[i] and TargetCube[i].Remove then TargetCube[i]:Remove() end
        if GoalCube[i]   and GoalCube[i].Remove   then GoalCube[i]:Remove()   end
        if NoSpinCube[i] and NoSpinCube[i].Remove  then NoSpinCube[i]:Remove()  end
        TargetCube[i] = Drawing.new("Line")
        GoalCube[i]   = Drawing.new("Line")
        NoSpinCube[i] = Drawing.new("Line")
    end
    local function SC(cube, color, th)
        for _, l in ipairs(cube) do
            l.Color = color; l.Thickness = th or 2
            l.Transparency = 0.7; l.ZIndex = 1000; l.Visible = false
        end
    end
    SC(TargetCube, Color3.fromRGB(0,255,0),   6)  -- зелёный = куда летит мяч
    SC(GoalCube,   Color3.fromRGB(255,0,0),   4)  -- красный = желаемое место попадания (scored target)
    SC(NoSpinCube, Color3.fromRGB(0,255,255), 5)  -- голубой = без спина
end

local function DrawOrientedCube(cube, cframe, size)
    if not cframe or not size then for _, l in ipairs(cube) do l.Visible = false end; return end
    pcall(function()
        local h = size / 2
        local corners = {
            cframe * Vector3.new(-h.X,-h.Y,-h.Z), cframe * Vector3.new(h.X,-h.Y,-h.Z),
            cframe * Vector3.new(h.X,h.Y,-h.Z),   cframe * Vector3.new(-h.X,h.Y,-h.Z),
            cframe * Vector3.new(-h.X,-h.Y,h.Z),  cframe * Vector3.new(h.X,-h.Y,h.Z),
            cframe * Vector3.new(h.X,h.Y,h.Z),    cframe * Vector3.new(-h.X,h.Y,h.Z),
        }
        local edges = {{1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8}}
        for i, e in ipairs(edges) do
            local a, b = corners[e[1]], corners[e[2]]
            local as, av = Camera:WorldToViewportPoint(a)
            local bs, bv = Camera:WorldToViewportPoint(b)
            local l = cube[i]
            if av and bv and as.Z > 0 and bs.Z > 0 then
                l.From = Vector2.new(as.X, as.Y); l.To = Vector2.new(bs.X, bs.Y); l.Visible = true
            else l.Visible = false end
        end
    end)
end

-- ============================================================
-- ОПРЕДЕЛЕНИЕ ВОРОТ — полностью автоматически по реальным позициям стоек
-- Не используем никаких Y-offset — берём реальные координаты из мира
-- ============================================================
local GoalCFrame, GoalWidth, GoalHeight, GoalCrossbarY
local function UpdateGoal()
    local myTeam, enemyGoalName = (function()
        local stats = Workspace:FindFirstChild("PlayerStats")
        if not stats then return nil, nil end
        if stats:FindFirstChild("Away") and stats.Away:FindFirstChild(LocalPlayer.Name) then return "Away", "HomeGoal"
        elseif stats:FindFirstChild("Home") and stats.Home:FindFirstChild(LocalPlayer.Name) then return "Home", "AwayGoal" end
        return nil, nil
    end)()
    if not enemyGoalName then return nil end

    local goalFolder = Workspace:FindFirstChild(enemyGoalName)
    if not goalFolder then return nil end
    local frame = goalFolder:FindFirstChild("Frame")
    if not frame then return nil end

    -- Ищем стойки и перекладину
    local posts, crossbar = {}, nil
    for _, part in ipairs(frame:GetChildren()) do
        if part:IsA("BasePart") then
            if part.Name == "Crossbar" then
                crossbar = part
            else
                local hasCylinder, hasSound = false, false
                for _, c in ipairs(part:GetChildren()) do
                    if c:IsA("CylinderMesh") then hasCylinder = true end
                    if c:IsA("Sound") then hasSound = true end
                end
                if hasCylinder and hasSound then table.insert(posts, part) end
            end
        end
    end

    if #posts < 2 then
        -- Fallback: просто левый/правый по X
        for _, part in ipairs(frame:GetChildren()) do
            if part:IsA("BasePart") and part.Name ~= "Crossbar" then
                table.insert(posts, part)
            end
        end
    end
    if #posts < 2 or not crossbar then return nil end

    -- Сортируем по X → leftPost, rightPost
    table.sort(posts, function(a,b) return a.Position.X < b.Position.X end)
    local leftPost, rightPost = posts[1], posts[#posts]

    -- Центр ворот — между стойками на уровне земли
    -- Горизонтальный центр
    local centerPos = (leftPost.Position + rightPost.Position) / 2

    -- Ширина — реальное расстояние между стойками (внутренний просвет)
    local width  = (leftPost.Position - rightPost.Position).Magnitude
    -- Высота — от нижней точки стоек до перекладины (реальная высота)
    local postBaseY  = math.min(leftPost.Position.Y, rightPost.Position.Y)
    local crossbarY  = crossbar.Position.Y
    local height = math.abs(crossbarY - postBaseY)

    -- CFrame ворот: центр у основания, ось X → правая стойка, ось Y → вверх
    local rightDir = (rightPost.Position - leftPost.Position).Unit
    local upDir    = Vector3.new(0, 1, 0)
    local fwdDir   = rightDir:Cross(upDir).Unit  -- нормаль ворот

    -- Центр для CFrame — середина нижней стороны ворот
    GoalCFrame   = CFrame.fromMatrix(centerPos, rightDir, upDir, -fwdDir)
    GoalWidth    = width
    GoalHeight   = height
    GoalCrossbarY = crossbarY

    return width
end

-- ============================================================
-- ОПРЕДЕЛЕНИЕ ВРАТАРЯ — точная позиция в локальных координатах ворот
-- Возвращает: hrp, localX (отступ от центра), localY (высота от пола ворот),
--             gkWidth (ширина тела ≈ 4 stud), isAggressive
-- ============================================================
local function GetEnemyGoalie()
    if not GoalCFrame or not GoalWidth then
        if Gui then Gui.GK.Text = "GK: No Goal" end
        return nil, 0, 0, false
    end
    local myTeam = (function()
        local stats = Workspace:FindFirstChild("PlayerStats")
        if not stats then return nil end
        if stats:FindFirstChild("Away") and stats.Away:FindFirstChild(LocalPlayer.Name) then return "Away"
        elseif stats:FindFirstChild("Home") and stats.Home:FindFirstChild(LocalPlayer.Name) then return "Home" end
    end)()

    local goalies = {}
    local halfW = GoalWidth / 2

    local function addGoalie(hrp, name)
        if not hrp then return end
        local local3 = GoalCFrame:PointToObjectSpace(hrp.Position)
        -- localX: смещение от центра ворот (+ = правая стойка, - = левая)
        -- localY: высота от пола ворот
        local localX = local3.X
        local localY = hrp.Position.Y - GoalCFrame.Position.Y
        local distGoal = (hrp.Position - GoalCFrame.Position).Magnitude
        local isInGoal = distGoal < 20 and math.abs(localX) < halfW + 3
        table.insert(goalies, {
            hrp = hrp, localX = localX, localY = localY,
            distGoal = distGoal, name = name, isInGoal = isInGoal
        })
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Team and player.Team.Name ~= myTeam then
            local char = player.Character
            if char then
                local hum = char:FindFirstChild("Humanoid")
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if hum and hrp and hum.HipHeight >= 4 then
                    addGoalie(hrp, player.Name)
                end
            end
        end
    end

    local npcName = myTeam == "Away" and "HomeGoalie" or "Goalie"
    local npc = Workspace:FindFirstChild(npcName)
    if npc and npc:FindFirstChild("HumanoidRootPart") then
        addGoalie(npc.HumanoidRootPart, "NPC")
    end

    if #goalies == 0 then
        if Gui then Gui.GK.Text = "GK: None"; Gui.GK.Color = Color3.fromRGB(150,150,150) end
        return nil, 0, 0, false
    end

    table.sort(goalies, function(a,b)
        if a.isInGoal ~= b.isInGoal then return a.isInGoal end
        return a.distGoal < b.distGoal
    end)

    local best = goalies[1]
    local isAggressive = not best.isInGoal
    if Gui then
        Gui.GK.Text = string.format("GK: %s%s X=%.1f Y=%.1f",
            best.name, isAggressive and " [RUSH]" or "",
            best.localX, best.localY)
        Gui.GK.Color = Color3.fromRGB(255, 200, 0)
    end
    return best.hrp, best.localX, best.localY, isAggressive
end

-- ============================================================
-- ЯДРО: SMART TARGET SELECTION
-- Логика:
--   1. Разбиваем ворота на сетку кандидатных точек (X × Y)
--   2. Для каждой точки считаем score = расстояние до вратаря - штрафы
--   3. Автоматически решаем: нужен спин или нет
--   4. Спин помогает когда вратарь близко к цели — мяч "объезжает"
--   5. Power рассчитывается по физике: t = dist/speed, h = v_y*t - 0.5*g*t²
--      откуда v_y = (h + 0.5*g*t²) / t, power ≈ speed / BALL_SPEED
-- ============================================================
local TargetPoint, ShootDir, ShootVel, CurrentSpin, CurrentPower, CurrentType
local LastShootRedBox = nil   -- точка куда ХОТЕЛИ ударить (красный бокс)
local LastShoot = 0
local CanShoot  = true

local function CalcPowerAndHeight(dist, targetLocalY)
    -- targetLocalY: желаемая высота точки ударения НАД ПОЛОМ ворот (studs)
    -- v_y нужна чтобы мяч прилетел на нужную высоту
    -- t = dist / (power * BALL_SPEED)  →  итерируем по power
    -- Используем физику: h_arrival = startH + v_y*t - 0.5*g*t²
    -- startH ≈ 3 (высота мяча у игрока)
    local startH = 3.0
    local goalH  = targetLocalY  -- желаемая высота прилёта над полом ворот
    -- Дельта высоты
    local dh = goalH - startH

    -- Power диапазон
    for _, power in ipairs({3.5, 4.0, 4.5, 5.0, 3.0, 2.5, 6.0, 7.0}) do
        local speed = power * BALL_SPEED
        local t = dist / speed
        if t > 0.05 and t < 3.0 then
            -- Нужная начальная вертикальная скорость
            local vy = (dh + 0.5 * GRAVITY * t * t) / t
            -- Максимальная высота: vy²/(2g)
            local maxH = startH + (vy * vy) / (2 * GRAVITY)
            if maxH < 200 and vy > 0 then
                return power, vy, t
            end
        end
    end
    -- Fallback: просто минимальная высота
    local power = 4.0
    local t = dist / (power * BALL_SPEED)
    local vy = (dh + 0.5 * GRAVITY * t * t) / t
    return power, math.max(vy, 1.0), t
end

local function GetTarget(dist, gkX, gkY, isAggressive, gkHrp)
    if not GoalCFrame or not GoalWidth or not GoalHeight then return nil end
    if dist > AutoShootMaxDistance then return nil end

    local startPos = HumanoidRootPart.Position
    local halfW    = GoalWidth  / 2 - INSET
    local halfH    = GoalHeight       -- высота ворот

    -- Сетка кандидатных точек в локальных координатах ворот
    -- X: [-halfW, -halfW*0.5, 0, halfW*0.5, halfW]
    -- Y: [0.4, 0.6, 0.8] × GoalHeight  (низ/середина/верх)
    local xPoints = {-halfW, -halfW * 0.6, 0, halfW * 0.6, halfW}
    local yFracs  = {0.2, 0.45, 0.75}

    local candidates = {}

    for _, xf in ipairs(xPoints) do
        for _, yf in ipairs(yFracs) do
            local localX = xf
            local localY = yf * halfH  -- высота над полом ворот (studs)

            -- 3D позиция кандидата
            local worldPos = GoalCFrame * Vector3.new(localX, localY, 0)

            -- Расстояние до вратаря в плоскости ворот
            local gkDistX = math.abs(gkX - localX)
            local gkDistY = math.abs(gkY - localY)
            local gkDist2D = math.sqrt(gkDistX*gkDistX + gkDistY*gkDistY)

            -- Базовый score = расстояние от GK (чем дальше — тем лучше)
            local score = gkDist2D * 2.0

            -- Бонус за угловые зоны (GK сложнее туда прыгать)
            local cornerBonus = (math.abs(localX) > halfW * 0.6) and 3.0 or 0.0
            score = score + cornerBonus

            -- Бонус за низкий мяч если GK стоит высоко
            if gkY > halfH * 0.5 and localY < halfH * 0.3 then
                score = score + 4.0
            end

            -- Штраф за центр (GK обычно стоит по центру)
            if math.abs(localX) < halfW * 0.2 then
                score = score - 2.0
            end

            -- Если GK rush — стреляем поверх него или мимо
            if isAggressive then
                local gkWorldPos = gkHrp and gkHrp.Position or nil
                if gkWorldPos then
                    local shootDir2D = (worldPos - startPos)
                    local gkDir2D    = (gkWorldPos - startPos)
                    local dot = shootDir2D.Unit:Dot(gkDir2D.Unit)
                    if dot > 0.92 then
                        score = score - 8.0  -- GK прямо на пути
                    else
                        score = score + 5.0  -- стреляем мимо
                    end
                end
            end

            -- Физика: power и vy
            local power, vy, flightTime = CalcPowerAndHeight(dist, localY)

            -- Решение о спине:
            -- Спин нужен если вратарь близко к выбранной точке (gkDist2D < 5)
            -- и дистанция достаточная (> 60 studs) чтобы спин успел сработать
            local useSpin = false
            local spinDir = "None"
            if dist > 60 and gkDist2D < 5.5 then
                useSpin = true
                -- Спин направлен ОТ вратаря: если GK правее цели → крутим влево (Left)
                spinDir = (gkX > localX) and "Left" or "Right"
                score = score + 2.0  -- спин помогает
            elseif dist > 100 then
                -- Далеко: иногда добавляем спин для непредсказуемости
                -- только если угол к воротам небольшой
                local goalDir = (GoalCFrame.Position - startPos).Unit
                local forwardDir = HumanoidRootPart.CFrame.LookVector
                local angle = math.deg(math.acos(math.clamp(goalDir:Dot(forwardDir), -1, 1)))
                if angle < 20 then
                    useSpin = true
                    spinDir = (localX >= 0) and "Right" or "Left"
                end
            end

            -- Деривация (боковое смещение от спина)
            local derivation = 0
            if useSpin then
                local dMult = math.clamp((dist / 100)^1.5 * 1.2, 0.3, 4.0)
                derivation = (spinDir == "Left" and 1 or -1) * dMult * power
            end
            local spinWorldPos = GoalCFrame * Vector3.new(
                math.clamp(localX + derivation, -GoalWidth/2+0.3, GoalWidth/2-0.3),
                localY, 0)

            table.insert(candidates, {
                idealPos  = worldPos,    -- куда ХОТИМ попасть (красный бокс)
                shootPos  = spinWorldPos, -- реальная позиция с учётом спина (зелёный бокс)
                localX    = localX,
                localY    = localY,
                spin      = spinDir,
                power     = power,
                vy        = vy,
                score     = score,
                gkDist    = gkDist2D,
            })
        end
    end

    if #candidates == 0 then return nil end

    -- Выбираем лучший
    table.sort(candidates, function(a,b) return a.score > b.score end)
    return candidates[1]
end

-- ============================================================
-- CALCULATE TARGET (вызывается каждый кадр)
-- ============================================================
local function CalculateTarget()
    local width = UpdateGoal()
    if not GoalCFrame or not width then
        TargetPoint = nil; LastShootRedBox = nil
        if Gui then Gui.Target.Text = "Target: --"; Gui.Power.Text = "Power: --"; Gui.Spin.Text = "Spin: --" end
        return
    end

    local dist = (HumanoidRootPart.Position - GoalCFrame.Position).Magnitude
    if Gui then
        Gui.Dist.Text = string.format("Dist: %.0f | Goal: %.0f×%.0f", dist, GoalWidth, GoalHeight)
    end

    if dist > AutoShootMaxDistance then
        TargetPoint = nil; LastShootRedBox = nil
        if Gui then Gui.Target.Text = "Too Far" end
        return
    end

    local gkHrp, gkX, gkY, isAggressive = GetEnemyGoalie()
    local result = GetTarget(dist, gkX or 0, gkY or 0, isAggressive or false, gkHrp)
    if not result then
        TargetPoint = nil; LastShootRedBox = nil
        if Gui then Gui.Target.Text = "No Candidate" end
        return
    end

    TargetPoint      = result.shootPos
    LastShootRedBox  = result.idealPos   -- красный бокс = идеальная точка
    CurrentSpin      = result.spin
    CurrentPower     = result.power
    CurrentType      = string.format("X=%.1f Y=%.1f gk=%.1f", result.localX, result.localY, result.gkDist)
    ShootDir         = (TargetPoint - HumanoidRootPart.Position).Unit
    ShootVel         = ShootDir * (result.power * BALL_SPEED)

    if Gui then
        Gui.Target.Text = "→ " .. CurrentType
        Gui.Power.Text  = string.format("Power: %.1f | Spin: %s", CurrentPower, CurrentSpin)
        Gui.Spin.Text   = string.format("vy=%.1f dist=%.0f", result.vy, dist)
        Gui.Goal.Text   = string.format("Goal W=%.1f H=%.1f", GoalWidth, GoalHeight)
    end
end

-- ============================================================
-- SPOOF POWER
-- ============================================================
local function GetSpoofPower()
    if not AutoShootSpoofPowerEnabled then return nil end
    if AutoShootSpoofPowerType == "math.huge" then return math.huge
    elseif AutoShootSpoofPowerType == "9999999" then return 9999999
    elseif AutoShootSpoofPowerType == "100"     then return 100 end
    return nil
end

local function GetKeyName(key)
    if key == Enum.KeyCode.Unknown then return "None" end
    local name = tostring(key):match("KeyCode%.(.+)") or tostring(key)
    local pretty = {LeftMouse="LMB",RightMouse="RMB",Space="Space",LeftShift="LShift",RightShift="RShift"}
    return pretty[name] or name
end
local function UpdateModeText()
    if not Gui then return end
    Gui.Mode.Text = AutoShootManualShot
        and string.format("Mode: Manual (%s)", GetKeyName(AutoShootShootKey))
        or "Mode: Auto"
end

-- ============================================================
-- SHOOT
-- ============================================================
local function DoShoot()
    if not ShootDir then return false end
    if IsAnimating and AutoShootLegit then return false end
    if AutoShootLegit then
        IsAnimating = true; RShootAnim:Play()
        task.delay(AnimationHoldTime, function() IsAnimating = false end)
    end
    local power = GetSpoofPower() or CurrentPower
    local ok = pcall(function()
        Shooter:FireServer(ShootDir, BallAttachment.CFrame, power, ShootVel, false, false, CurrentSpin, nil, false)
    end)
    return ok
end

-- ============================================================
-- MANUAL BUTTON
-- ============================================================
local function SetupManualButton()
    if AutoShootStatus.ButtonGui then AutoShootStatus.ButtonGui:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "ManualShootButtonGui"; gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = false; gui.Parent = game:GetService("CoreGui")
    local size = 50 * AutoShootButtonScale
    local sv = Camera.ViewportSize
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, size, 0, size)
    frame.Position = UDim2.new(0, sv.X/2 - size/2, 0, sv.Y/2 - size/2)
    frame.BackgroundColor3 = Color3.fromRGB(20,30,50); frame.BackgroundTransparency = 0.3
    frame.BorderSizePixel = 0; frame.Visible = AutoShootManualButton; frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0.5, 0)
    local icon = Instance.new("ImageLabel"); icon.Size = UDim2.new(0,size*0.6,0,size*0.6)
    icon.Position = UDim2.new(0.5,-size*0.3,0.5,-size*0.3); icon.BackgroundTransparency = 1
    icon.Image = "rbxassetid://73279554401260"; icon.Parent = frame

    frame.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            AutoShootStatus.TouchStartTime = tick(); AutoShootStatus.Dragging = true
            local mp = inp.UserInputType == Enum.UserInputType.Touch and Vector2.new(inp.Position.X, inp.Position.Y) or UserInputService:GetMouseLocation()
            AutoShootStatus.DragStart = mp; AutoShootStatus.StartPos = frame.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) and AutoShootStatus.Dragging then
            local mp = inp.UserInputType == Enum.UserInputType.Touch and Vector2.new(inp.Position.X, inp.Position.Y) or UserInputService:GetMouseLocation()
            local d = mp - AutoShootStatus.DragStart
            frame.Position = UDim2.new(AutoShootStatus.StartPos.X.Scale, AutoShootStatus.StartPos.X.Offset + d.X, AutoShootStatus.StartPos.Y.Scale, AutoShootStatus.StartPos.Y.Offset + d.Y)
        end
    end)
    frame.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            AutoShootStatus.Dragging = false
            if tick() - AutoShootStatus.TouchStartTime < 0.2 then
                local ball = Workspace:FindFirstChild("ball")
                local hasBall = ball and ball:FindFirstChild("playerWeld") and ball.creator.Value == LocalPlayer
                if hasBall and TargetPoint then pcall(CalculateTarget); DoShoot() end
            end
            AutoShootStatus.TouchStartTime = 0
        end
    end)
    AutoShootStatus.ButtonGui = gui
end
local function ToggleManualButton(v)
    AutoShootManualButton = v
    if v then SetupManualButton()
    elseif AutoShootStatus.ButtonGui then AutoShootStatus.ButtonGui:Destroy(); AutoShootStatus.ButtonGui = nil end
end
local function SetButtonScale(v)
    AutoShootButtonScale = v
    if AutoShootManualButton then SetupManualButton() end
end

-- ============================================================
-- AUTO SHOOT MODULE
-- ============================================================
local AutoShoot = {}
AutoShoot.Start = function()
    if AutoShootStatus.Running then return end
    AutoShootStatus.Running = true
    SetupGUI(); InitializeCubes(); UpdateModeText()
    if AutoShootManualButton then SetupManualButton() end

    AutoShootStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoShootEnabled then return end
        pcall(CalculateTarget)
        local ball    = Workspace:FindFirstChild("ball")
        local hasBall = ball and ball:FindFirstChild("playerWeld") and ball.creator.Value == LocalPlayer
        local dist    = GoalCFrame and (HumanoidRootPart.Position - GoalCFrame.Position).Magnitude or 999

        if hasBall and TargetPoint and dist <= AutoShootMaxDistance then
            if Gui then
                Gui.Status.Text  = AutoShootManualShot and ("Ready [" .. GetKeyName(AutoShootShootKey) .. "]") or "Aiming..."
                Gui.Status.Color = Color3.fromRGB(0,255,0)
            end
        elseif hasBall then
            if Gui then Gui.Status.Text = dist > AutoShootMaxDistance and "Too Far" or "No Target"; Gui.Status.Color = Color3.fromRGB(255,100,0) end
        else
            if Gui then Gui.Status.Text = "No Ball"; Gui.Status.Color = Color3.fromRGB(255,165,0) end
        end

        if hasBall and TargetPoint and dist <= AutoShootMaxDistance and not AutoShootManualShot and tick() - LastShoot >= 0.3 then
            if DoShoot() then LastShoot = tick() end
        end
    end)

    AutoShootStatus.InputConnection = UserInputService.InputBegan:Connect(function(inp, gp)
        if gp or not AutoShootEnabled or not AutoShootManualShot or not CanShoot then return end
        if inp.KeyCode == AutoShootShootKey then
            local ball = Workspace:FindFirstChild("ball")
            local hasBall = ball and ball:FindFirstChild("playerWeld") and ball.creator.Value == LocalPlayer
            if hasBall and TargetPoint then
                pcall(CalculateTarget)
                if DoShoot() then
                    if Gui then Gui.Status.Text = "SHOT! [" .. CurrentType .. "]"; Gui.Status.Color = Color3.fromRGB(0,255,0) end
                    LastShoot = tick(); CanShoot = false
                    task.delay(0.3, function() CanShoot = true end)
                end
            end
        end
    end)

    AutoShootStatus.RenderConnection = RunService.RenderStepped:Connect(function()
        local width = UpdateGoal()
        -- Красный бокс = ЖЕЛАЕМАЯ точка попадания (куда мы хотели, до деривации спина)
        if LastShootRedBox then
            DrawOrientedCube(GoalCube, CFrame.new(LastShootRedBox), Vector3.new(3,3,3))
        else
            for _, l in ipairs(GoalCube) do l.Visible = false end
        end
        -- Зелёный бокс = реальная точка прицела (с учётом спина)
        if TargetPoint then
            DrawOrientedCube(TargetCube, CFrame.new(TargetPoint), Vector3.new(4,4,4))
        else
            for _, l in ipairs(TargetCube) do l.Visible = false end
        end
        -- Голубой бокс = ворота целиком
        if GoalCFrame and width then
            DrawOrientedCube(NoSpinCube, GoalCFrame * CFrame.new(0, GoalHeight/2, 0), Vector3.new(width, GoalHeight, 2))
        else
            for _, l in ipairs(NoSpinCube) do l.Visible = false end
        end
    end)
end

AutoShoot.Stop = function()
    if AutoShootStatus.Connection     then AutoShootStatus.Connection:Disconnect();      AutoShootStatus.Connection     = nil end
    if AutoShootStatus.RenderConnection then AutoShootStatus.RenderConnection:Disconnect(); AutoShootStatus.RenderConnection = nil end
    if AutoShootStatus.InputConnection  then AutoShootStatus.InputConnection:Disconnect();  AutoShootStatus.InputConnection  = nil end
    AutoShootStatus.Running = false
    if Gui then for _, v in pairs(Gui) do if v.Remove then v:Remove() end end; Gui = nil end
    for i = 1, 12 do
        if TargetCube[i] and TargetCube[i].Remove then TargetCube[i]:Remove() end
        if GoalCube[i]   and GoalCube[i].Remove   then GoalCube[i]:Remove()   end
        if NoSpinCube[i] and NoSpinCube[i].Remove  then NoSpinCube[i]:Remove()  end
    end
    if AutoShootStatus.ButtonGui then AutoShootStatus.ButtonGui:Destroy(); AutoShootStatus.ButtonGui = nil end
end

AutoShoot.SetDebugText = function(v)
    AutoShootDebugText = v; ToggleDebugText(v)
end

-- ============================================================
-- AUTO PICKUP
-- ============================================================
local AutoPickup = {}
AutoPickup.Start = function()
    if AutoPickupStatus.Running then return end
    AutoPickupStatus.Running = true
    AutoPickupStatus.Connection = RunService.Heartbeat:Connect(function()
        if not AutoPickupEnabled or not PickupRemote then return end
        local ball = Workspace:FindFirstChild("ball")
        if not ball or ball:FindFirstChild("playerWeld") then return end
        if (HumanoidRootPart.Position - ball.Position).Magnitude <= AutoPickupDist then
            pcall(function() PickupRemote:FireServer(AutoPickupSpoofValue) end)
        end
    end)
end
AutoPickup.Stop = function()
    if AutoPickupStatus.Connection then AutoPickupStatus.Connection:Disconnect(); AutoPickupStatus.Connection = nil end
    AutoPickupStatus.Running = false
end

-- ============================================================
-- UI
-- ============================================================
local uiElements = {}
local function SetupUI(UI)
    if UI.Sections.AutoShoot then
        UI.Sections.AutoShoot:Header({ Name = "AutoShoot v36" })
        UI.Sections.AutoShoot:Divider()

        uiElements.AutoShootEnabled = UI.Sections.AutoShoot:Toggle({
            Name = "Enabled", Default = AutoShootEnabled,
            Callback = function(v) AutoShootEnabled = v; if v then AutoShoot.Start() else AutoShoot.Stop() end end
        }, "AutoShootEnabled")

        uiElements.AutoShootLegit = UI.Sections.AutoShoot:Toggle({
            Name = "Legit Animation", Default = AutoShootLegit,
            Callback = function(v) AutoShootLegit = v end
        }, "AutoShootLegit")

        UI.Sections.AutoShoot:Divider()

        uiElements.AutoShootManual = UI.Sections.AutoShoot:Toggle({
            Name = "Manual Shot", Default = AutoShootManualShot,
            Callback = function(v) AutoShootManualShot = v; UpdateModeText() end
        }, "AutoShootManual")

        uiElements.AutoShootKey = UI.Sections.AutoShoot:Keybind({
            Name = "Shoot Key", Default = AutoShootShootKey,
            Callback = function(v) AutoShootShootKey = v; UpdateModeText() end
        }, "AutoShootKey")

        uiElements.AutoShootManualButton = UI.Sections.AutoShoot:Toggle({
            Name = "Manual Button", Default = AutoShootManualButton,
            Callback = function(v) ToggleManualButton(v) end
        }, "AutoShootManualButton")

        uiElements.AutoShootButtonScale = UI.Sections.AutoShoot:Slider({
            Name = "Button Scale", Minimum = 0.5, Maximum = 2.0,
            Default = AutoShootButtonScale, Precision = 2,
            Callback = function(v) SetButtonScale(v) end
        }, "AutoShootButtonScale")

        UI.Sections.AutoShoot:Divider()

        uiElements.AutoShootMaxDist = UI.Sections.AutoShoot:Slider({
            Name = "Max Distance", Minimum = 50, Maximum = 300,
            Default = AutoShootMaxDistance, Precision = 1,
            Callback = function(v) AutoShootMaxDistance = v end
        }, "AutoShootMaxDist")

        UI.Sections.AutoShoot:Divider()

        uiElements.AutoShootSpoofPower = UI.Sections.AutoShoot:Toggle({
            Name = "Spoof Power", Default = AutoShootSpoofPowerEnabled,
            Callback = function(v) AutoShootSpoofPowerEnabled = v end
        }, "AutoShootSpoofPower")

        uiElements.AutoShootSpoofType = UI.Sections.AutoShoot:Dropdown({
            Name = "Spoof Power Type", Default = AutoShootSpoofPowerType,
            Options = {"math.huge", "9999999", "100"}, Required = true,
            Callback = function(v) AutoShootSpoofPowerType = v end
        }, "AutoShootSpoofType")

        uiElements.AutoShootDebugText = UI.Sections.AutoShoot:Toggle({
            Name = "Debug Text", Default = AutoShootDebugText,
            Callback = function(v) AutoShoot.SetDebugText(v) end
        }, "AutoShootDebugText")
    end

    if UI.Sections.AutoPickup then
        UI.Sections.AutoPickup:Header({ Name = "AutoPickup" })
        UI.Sections.AutoPickup:Divider()

        uiElements.AutoPickupEnabled = UI.Sections.AutoPickup:Toggle({
            Name = "Enabled", Default = AutoPickupEnabled,
            Callback = function(v) AutoPickupEnabled = v; if v then AutoPickup.Start() else AutoPickup.Stop() end end
        }, "AutoPickupEnabled")

        uiElements.AutoPickupDist = UI.Sections.AutoPickup:Slider({
            Name = "Pickup Distance", Minimum = 10, Maximum = 300,
            Default = AutoPickupDist, Precision = 1,
            Callback = function(v) AutoPickupDist = v end
        }, "AutoPickupDist")

        uiElements.AutoPickupSpoof = UI.Sections.AutoPickup:Slider({
            Name = "Spoof Value", Minimum = 0.1, Maximum = 5.0,
            Default = AutoPickupSpoofValue, Precision = 2,
            Callback = function(v) AutoPickupSpoofValue = v end
        }, "AutoPickupSpoof")

        UI.Sections.AutoPickup:SubLabel({Text = "[💠] Distance sent to server for pickup"})
    end
end

-- ============================================================
-- MODULE INIT
-- ============================================================
local AutoShootModule = {}
function AutoShootModule.Init(UI, coreParam, notifyFunc)
    local notify = notifyFunc or function(t,m) print("["..t.."]: "..m) end
    SetupUI(UI)

    LocalPlayer.CharacterAdded:Connect(function(newChar)
        task.wait(1)
        Character     = newChar
        Humanoid      = newChar:WaitForChild("Humanoid")
        HumanoidRootPart = newChar:WaitForChild("HumanoidRootPart")
        BallAttachment   = newChar:WaitForChild("ball")
        RShootAnim       = Humanoid:LoadAnimation(Animations:WaitForChild("RShoot"))
        RShootAnim.Priority = Enum.AnimationPriority.Action4
        GoalCFrame = nil; TargetPoint = nil; LastShootRedBox = nil
        LastShoot = 0; IsAnimating = false; CanShoot = true
        if AutoShootEnabled then AutoShoot.Start() end
        if AutoPickupEnabled then AutoPickup.Start() end
    end)
end

function AutoShootModule:Destroy()
    AutoShoot.Stop(); AutoPickup.Stop()
end

return AutoShootModule
