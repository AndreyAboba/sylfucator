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
-- ── Физика ──────────────────────────────────────────────────────────────────
-- GRAVITY:       гравитация Roblox (196.2 studs/s²)
-- AutoShootBallSpeed: реальная скорость мяча в studs/s, которую выдаёт сервер.
--   Power-параметр в игре НЕ влияет на скорость (только очень низкие <0.3).
--   Калибруй: если мяч летит ВЫШЕ цели → уменьши; НИЖЕ → увеличь.
-- AutoShootDrag: коэффициент линейного затухания скорости (air drag).
--   Roblox: AssemblyLinearVelocity затухает как v(t)=v0*e^(-drag*t).
--   Калибруй: если мяч НЕ ДОЛЕТАЕТ на дальних → увеличь Drag или уменьши BallSpeed.
-- INSET: отступ от штанг внутрь (studs)
local GRAVITY            = 196.2
local AutoShootBallSpeed = 240   -- studs/s; калибруй!
local AutoShootDrag      = 0.40  -- 0 = без затухания; 0.4 = умеренное
local FIXED_POWER        = 5.0   -- power на сервер (игнорируется им, но нужен)
local INSET              = 1.5

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
local TRAJ_SEGMENTS = 20               -- кол-во сегментов дуги траектории
local TrajectoryLines = {}             -- оранжевая пунктирная дуга
local PeakCube = {}                    -- жёлтый бокс: пик траектории
local function InitializeCubes()
    for i = 1, 12 do
        if TargetCube[i] and TargetCube[i].Remove then TargetCube[i]:Remove() end
        if GoalCube[i]   and GoalCube[i].Remove   then GoalCube[i]:Remove()   end
        if NoSpinCube[i] and NoSpinCube[i].Remove  then NoSpinCube[i]:Remove()  end
        if PeakCube[i]   and PeakCube[i].Remove    then PeakCube[i]:Remove()    end
        TargetCube[i] = Drawing.new("Line")
        GoalCube[i]   = Drawing.new("Line")
        NoSpinCube[i] = Drawing.new("Line")
        PeakCube[i]   = Drawing.new("Line")
    end
    -- Траектория: TRAJ_SEGMENTS линий
    for i = 1, TRAJ_SEGMENTS do
        if TrajectoryLines[i] and TrajectoryLines[i].Remove then TrajectoryLines[i]:Remove() end
        TrajectoryLines[i] = Drawing.new("Line")
        TrajectoryLines[i].Color        = Color3.fromRGB(255, 165, 0)  -- оранжевый
        TrajectoryLines[i].Thickness    = 2
        TrajectoryLines[i].Transparency = 0.4
        TrajectoryLines[i].ZIndex       = 999
        TrajectoryLines[i].Visible      = false
    end
    local function SC(cube, color, th)
        for _, l in ipairs(cube) do
            l.Color = color; l.Thickness = th or 2
            l.Transparency = 0.7; l.ZIndex = 1000; l.Visible = false
        end
    end
    SC(TargetCube, Color3.fromRGB(0,255,0),   5)   -- 🟢 зелёный = AimPoint (куда направлен ствол)
    SC(GoalCube,   Color3.fromRGB(255,0,0),   5)   -- 🔴 красный = PredictedLand (куда УПАДЁТ мяч)
    SC(NoSpinCube, Color3.fromRGB(0,200,255), 3)   -- 🔵 голубой = габарит ворот
    SC(PeakCube,   Color3.fromRGB(255,255,0), 4)   -- 🟡 жёлтый = пик дуги
end

-- Аналитическая позиция мяча в момент t с учётом drag и гравитации.
-- Модель: dv/dt = -gravity*Y - drag*v  (линейное затухание + гравитация)
-- Решение: v_horiz(t) = v0h * e^(-drag*t)
--          v_vert(t)  = (v0y + g/drag)*e^(-drag*t) - g/drag
--          x(t) = (v0h/drag)*(1 - e^(-drag*t))         [с drag]
--          y(t) = (v0y/drag + g/drag²)*(1-e^(-drag*t)) - g*t/drag  [с drag]
--          (при drag→0 вырождается в стандартную параболу)
local function BallPos(startPos, launchDir, v0, drag, t)
    if drag < 0.001 then
        -- Без затухания: простая парабола
        return startPos + Vector3.new(
            launchDir.X * v0 * t,
            launchDir.Y * v0 * t - 0.5 * GRAVITY * t * t,
            launchDir.Z * v0 * t
        )
    end
    local ex = math.exp(-drag * t)
    local inv = 1 - ex
    local gd  = GRAVITY / drag
    return Vector3.new(
        startPos.X + (launchDir.X * v0 / drag) * inv,
        startPos.Y + (launchDir.Y * v0 / drag + GRAVITY / (drag * drag)) * inv - gd * t,
        startPos.Z + (launchDir.Z * v0 / drag) * inv
    )
end

-- Время полёта до горизонтальной дистанции R.
-- hCosT = горизонтальная составляющая launchDir (sqrt(dx²+dz²))
local function BallFlightTime(v0, hCosT, R, drag)
    local vx0 = v0 * hCosT
    if vx0 < 0.001 then return nil end
    if drag < 0.001 then return R / vx0 end
    local ratio = R * drag / vx0
    if ratio >= 0.9999 then return nil end  -- не долетит
    return -math.log(1 - ratio) / drag
end

-- Рисует дугу мяча — 20 сегментов, аналитически с drag
local function DrawTrajectory(startPos, launchDir, v0, drag, flightTime)
    for i = 1, TRAJ_SEGMENTS do
        local t0 = flightTime * (i-1) / TRAJ_SEGMENTS
        local t1 = flightTime * i     / TRAJ_SEGMENTS
        local p0 = BallPos(startPos, launchDir, v0, drag, t0)
        local p1 = BallPos(startPos, launchDir, v0, drag, t1)
        local s0, ok0 = Camera:WorldToViewportPoint(p0)
        local s1, ok1 = Camera:WorldToViewportPoint(p1)
        local l = TrajectoryLines[i]
        if ok0 and ok1 and s0.Z > 0 and s1.Z > 0 then
            l.From = Vector2.new(s0.X, s0.Y)
            l.To   = Vector2.new(s1.X, s1.Y)
            l.Visible = true
        else
            l.Visible = false
        end
    end
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
local GoalCFrame, GoalWidth, GoalHeight, GoalFloorY
local function UpdateGoal()
    local myTeam, enemyGoalName = (function()
        local stats = Workspace:FindFirstChild("PlayerStats")
        if not stats then return nil, nil end
        if stats:FindFirstChild("Away") and stats.Away:FindFirstChild(LocalPlayer.Name) then return "Away","HomeGoal"
        elseif stats:FindFirstChild("Home") and stats.Home:FindFirstChild(LocalPlayer.Name) then return "Home","AwayGoal" end
        return nil, nil
    end)()
    if not enemyGoalName then return nil end

    local goalFolder = Workspace:FindFirstChild(enemyGoalName)
    if not goalFolder then return nil end
    local frame = goalFolder:FindFirstChild("Frame")
    if not frame then return nil end

    local posts, crossbar = {}, nil
    for _, part in ipairs(frame:GetChildren()) do
        if part:IsA("BasePart") then
            if part.Name == "Crossbar" then
                crossbar = part
            else
                local hasCyl, hasSnd = false, false
                for _, c in ipairs(part:GetChildren()) do
                    if c:IsA("CylinderMesh") then hasCyl = true end
                    if c:IsA("Sound")        then hasSnd = true end
                end
                if hasCyl and hasSnd then table.insert(posts, part) end
            end
        end
    end
    if #posts < 2 then
        for _, part in ipairs(frame:GetChildren()) do
            if part:IsA("BasePart") and part.Name ~= "Crossbar" then table.insert(posts, part) end
        end
    end
    if #posts < 2 or not crossbar then return nil end

    table.sort(posts, function(a,b) return a.Position.X < b.Position.X end)
    local leftPost, rightPost = posts[1], posts[#posts]

    -- Пол ворот = нижний торец стоек (центр поста - полувысота)
    -- Стойки — вертикальные цилиндры, Size.Y = их высота
    local lFloor = leftPost.Position.Y  - leftPost.Size.Y  / 2
    local rFloor = rightPost.Position.Y - rightPost.Size.Y / 2
    local floorY = math.min(lFloor, rFloor)

    -- Верхняя граница = нижний торец перекладины
    -- Перекладина — горизонтальный цилиндр, Size.Y = его длина вдоль оси, Size.X/Z = диаметр
    -- Реальный радиус перекладины: min(Size.X, Size.Z) / 2
    local crossbarRadius = math.min(crossbar.Size.X, crossbar.Size.Z) / 2
    local topY = crossbar.Position.Y - crossbarRadius

    -- Внутренняя ширина (между внутренними гранями стоек)
    local postRadiusL = math.min(leftPost.Size.X, leftPost.Size.Z) / 2
    local postRadiusR = math.min(rightPost.Size.X, rightPost.Size.Z) / 2
    local width = (leftPost.Position - rightPost.Position).Magnitude - postRadiusL - postRadiusR

    local height = math.abs(topY - floorY)

    -- CFrame: начало координат = центр пола ворот, X = вправо, Y = вверх
    local rightDir = (rightPost.Position - leftPost.Position).Unit
    local upDir    = Vector3.new(0, 1, 0)
    local fwdDir   = rightDir:Cross(upDir).Unit
    local floorCenter = Vector3.new(
        (leftPost.Position.X + rightPost.Position.X) / 2,
        floorY,
        (leftPost.Position.Z + rightPost.Position.Z) / 2
    )
    GoalCFrame  = CFrame.fromMatrix(floorCenter, rightDir, upDir, -fwdDir)
    GoalWidth   = width
    GoalHeight  = height
    GoalFloorY  = floorY
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
-- ЯДРО: БАЛЛИСТИКА + SMART TARGET SELECTION
-- ============================================================
-- ФИЗИЧЕСКОЕ ЯДРО с drag (линейное затухание скорости)
-- Модель: dv/dt = -g*ĵ - drag*v
-- Аналитическое решение:
--   vx(t) = vx0 * e^(-drag*t)
--   vy(t) = (vy0 + g/drag)*e^(-drag*t) - g/drag
--   x(t)  = (vx0/drag)*(1 - e^(-drag*t))
--   y(t)  = (vy0/drag + g/drag²)*(1 - e^(-drag*t)) - g*t/drag
-- При drag→0 формулы вырождаются в простую параболу (проверяется).
-- ============================================================
local TargetPoint, ShootDir, ShootVel, CurrentSpin, CurrentPower, CurrentType
local AimPoint          = nil
local PredictedLand     = nil
local CurrentFlightTime = 0
local CurrentLaunchDir  = nil
local CurrentSpeed      = 0
local CurrentPeakPos    = nil
local LastShoot = 0
local CanShoot  = true

-- Позиция мяча в момент t (аналитически, без итераций)
local function BallPos(startPos, launchDir, v0, drag, t)
    if drag < 0.001 then
        return startPos + Vector3.new(
            launchDir.X * v0 * t,
            launchDir.Y * v0 * t - 0.5 * GRAVITY * t * t,
            launchDir.Z * v0 * t)
    end
    local ex  = math.exp(-drag * t)
    local inv = 1.0 - ex
    return Vector3.new(
        startPos.X + (launchDir.X * v0 / drag) * inv,
        startPos.Y + (launchDir.Y * v0 / drag + GRAVITY / (drag*drag)) * inv - (GRAVITY/drag) * t,
        startPos.Z + (launchDir.Z * v0 / drag) * inv)
end

-- Время полёта до горизонтальной дистанции R
-- hCosT = горизонтальная составляющая launchDir (sqrt(Lx²+Lz²))
local function BallFlightTime(v0, hCosT, R, drag)
    local vx0 = v0 * hCosT
    if vx0 < 0.001 then return nil end
    if drag < 0.001 then return R / vx0 end
    local ratio = R * drag / vx0
    if ratio >= 0.9999 then return nil end
    return -math.log(1.0 - ratio) / drag
end

-- Высота мяча когда он достигает горизонтальной дистанции R,
-- при угле вылета tanTheta = tan(θ)
local function yAtRange(tanTheta, v0, drag, R)
    local theta = math.atan(tanTheta)
    local cosT  = math.cos(theta)
    local sinT  = math.sin(theta)
    if cosT < 0.005 then return nil end
    local t = BallFlightTime(v0, cosT, R, drag)
    if not t then return nil end
    if drag < 0.001 then
        return v0 * sinT * t - 0.5 * GRAVITY * t * t, t
    end
    local ex = math.exp(-drag * t)
    return (v0 * sinT / drag + GRAVITY / (drag*drag)) * (1 - ex) - (GRAVITY/drag) * t, t
end

-- Найти угол вылета (бинарный поиск) чтобы попасть в targetPos.
-- Возвращает: launchDir (unit), flightTime (sec), ok (bool)
local function CalcLaunchDir(startPos, targetPos, v0, drag)
    local toTarget = targetPos - startPos
    local horizVec = Vector3.new(toTarget.X, 0, toTarget.Z)
    local R        = horizVec.Magnitude
    local dh       = toTarget.Y
    if R < 0.5 then return Vector3.new(0, 1, 0), 0.1, true end
    local hDir = horizVec.Unit

    local lo, hi = -1.0, 4.0
    local yLo    = yAtRange(lo, v0, drag, R)
    local yHi    = yAtRange(hi, v0, drag, R)

    -- Сузить hi если угол слишком крутой (недостижимо из-за drag)
    for _ = 1, 20 do
        if yHi ~= nil then break end
        hi  = (lo + hi) / 2
        yHi = yAtRange(hi, v0, drag, R)
    end

    -- Fallback: если не можем покрыть dh → используем лучший доступный угол
    if yLo == nil then
        local dir = Vector3.new(hDir.X * 0.866, 0.5, hDir.Z * 0.866).Unit
        local ft  = BallFlightTime(v0, 0.866, R, drag) or (R / (v0 * 0.866))
        return dir, ft, false
    end
    if yHi ~= nil and yHi < dh then
        -- Максимальный угол всё ещё ниже цели — берём максимум
        local theta = math.atan(hi)
        local cosT  = math.cos(theta); local sinT = math.sin(theta)
        local ft    = BallFlightTime(v0, cosT, R, drag) or (R / math.max(v0*cosT, 0.01))
        return Vector3.new(hDir.X*cosT, sinT, hDir.Z*cosT).Unit, ft, false
    end
    if yLo ~= nil and yLo > dh then
        -- Даже минимальный угол выше цели — берём минимум
        local theta = math.atan(lo)
        local cosT  = math.cos(theta); local sinT = math.sin(theta)
        local ft    = BallFlightTime(v0, cosT, R, drag) or (R / math.max(v0*cosT, 0.01))
        return Vector3.new(hDir.X*cosT, sinT, hDir.Z*cosT).Unit, ft, false
    end

    -- Бинарный поиск: 50 итераций
    for _ = 1, 50 do
        local mid = (lo + hi) / 2
        local y   = yAtRange(mid, v0, drag, R)
        if y == nil then
            hi = mid
        elseif y < dh then
            lo = mid
        else
            hi = mid
        end
    end

    local tanBest = (lo + hi) / 2
    local theta   = math.atan(tanBest)
    local cosT    = math.cos(theta)
    local sinT    = math.sin(theta)
    local ft      = BallFlightTime(v0, cosT, R, drag) or (R / math.max(v0 * cosT, 0.01))
    return Vector3.new(hDir.X*cosT, sinT, hDir.Z*cosT).Unit, ft, true
end
end

local function GetTarget(dist, gkX, gkY, isAggressive, gkHrp)
    if not GoalCFrame or not GoalWidth or not GoalHeight then return nil end
    if dist > AutoShootMaxDistance then return nil end

    local startPos = HumanoidRootPart.Position
    local halfW    = GoalWidth / 2 - INSET

    -- Сетка кандидатов: 7 × 5 = 35 точек
    -- Включает верхние и нижние углы, пост-хаг зоны
    local xPoints = {-halfW, -halfW*0.7, -halfW*0.35, 0, halfW*0.35, halfW*0.7, halfW}
    -- yFracs: 10%=низкий, 30%=нижний угол, 55%=середина, 78%=верхний угол, 93%=самый верх
    local yFracs  = {0.10, 0.30, 0.55, 0.78, 0.93}

    local candidates = {}

    for _, xf in ipairs(xPoints) do
        for _, yf in ipairs(yFracs) do
            local localX = xf
            local localY = yf * GoalHeight  -- высота над полом ворот (studs), РЕАЛЬНАЯ

            -- 3D позиция цели (idealPos) — точка в плоскости ворот
            local idealPos = GoalCFrame * Vector3.new(localX, localY, 0)

            -- === SCORING ===
            -- 1. Ключевой критерий: 2D расстояние от GK до точки в плоскости ворот
            local gkDistX  = math.abs(gkX - localX)
            local gkDistY  = math.abs(gkY - localY)
            local gkDist2D = math.sqrt(gkDistX*gkDistX + gkDistY*gkDistY)
            local score    = gkDist2D * 2.5  -- основной вес

            -- 2. Бонус верхние углы: труднее всего для GK (нужен прыжок + смещение)
            local isTopCorner = (localY > GoalHeight * 0.70) and (math.abs(localX) > halfW * 0.55)
            local isCorner    = math.abs(localX) > halfW * 0.55
            local isTop       = localY > GoalHeight * 0.70
            if isTopCorner then score = score + 6.0 end  -- топ-угол — самый ценный
            if isCorner    then score = score + 2.5 end  -- любой угол
            if isTop and not isTopCorner then score = score + 1.5 end  -- верх по центру

            -- 3. Штраф за центр (GK стартует по центру)
            if math.abs(localX) < halfW * 0.15 then score = score - 3.0 end

            -- 4. GK высоко → низкий мяч выгоднее
            if gkY > GoalHeight * 0.55 and localY < GoalHeight * 0.25 then score = score + 5.0 end

            -- 5. "Дальний угол" бонус: угол противоположный от игрока
            local playerLocalX = GoalCFrame:PointToObjectSpace(startPos).X
            local isFarCorner  = (playerLocalX > 0 and localX < -halfW*0.4)
                               or (playerLocalX < 0 and localX >  halfW*0.4)
            if isFarCorner then score = score + 3.0 end

            -- 6. GK rush — штраф если он прямо на пути, бонус если уходим
            if isAggressive and gkHrp then
                local shootVec = (idealPos - startPos).Unit
                local gkVec    = (gkHrp.Position - startPos).Unit
                local dot = shootVec:Dot(gkVec)
                score = score + (dot > 0.92 and -10.0 or 6.0)
            end

            -- Power фиксированный (сервер его игнорирует); скорость задаётся слайдером
            local power = FIXED_POWER
            local speed = AutoShootBallSpeed

            -- Решение о спине
            local spinDir = "None"
            if dist > 65 and gkDist2D < 5.5 then
                -- GK близко к цели → спин огибает его
                spinDir = (gkX > localX) and "Left" or "Right"
                score   = score + 2.0
            elseif dist > 105 then
                local goalDir    = (GoalCFrame.Position - startPos).Unit
                local fwdDir     = HumanoidRootPart.CFrame.LookVector
                local fwdAngle   = math.deg(math.acos(math.clamp(goalDir:Dot(fwdDir), -1, 1)))
                if fwdAngle < 20 then
                    spinDir = localX >= 0 and "Right" or "Left"
                end
            end

            -- Деривация спина (горизонтальный сдвиг прицела)
            local derivation = 0
            if spinDir ~= "None" then
                local dMult  = math.clamp((dist / 100)^1.5 * 1.2, 0.3, 4.0)
                derivation   = (spinDir == "Left" and 1 or -1) * dMult * power
            end

            -- shootPos = с учётом деривации (реальная точка куда направляем мяч)
            local shootLocalX = math.clamp(localX + derivation, -GoalWidth/2+0.3, GoalWidth/2-0.3)
            local shootPos    = GoalCFrame * Vector3.new(shootLocalX, localY, 0)

            -- *** БАЛЛИСТИКА: рассчитываем LaunchDir с учётом гравитации ***
            -- Мы направляем ствол выше цели так чтобы дуга опустила мяч в shootPos
            local launchDir, flightTimeRaw, trajOk = CalcLaunchDir(startPos, shootPos, speed, AutoShootDrag)

            -- Штраф если траектория невозможна при данном power
            if not trajOk then score = score - 5.0 end

            -- AimPoint: куда смотрит ствол в момент вылета (extrapolation launchDir → цель)
            -- = позиция мяча на половине пути (mid-flight), чтобы бокс был заметен
            local aimPoint = BallPos(startPos, launchDir, speed, AutoShootDrag, flightTime * 0.4)

            -- Время полёта получено из CalcLaunchDir (с drag)
            local flightTime   = flightTimeRaw or 0.5
            local horizToShoot = Vector3.new(shootPos.X-startPos.X, 0, shootPos.Z-startPos.Z).Magnitude
            local cosH = math.sqrt(launchDir.X^2 + launchDir.Z^2)
            -- Пик дуги с drag: vy(t)=0  →  (vy0+g/drag)*e^(-drag*tPeak) = g/drag
            -- → tPeak = ln(1 + vy0*drag/g) / drag  (при drag>0)
            local vy0    = launchDir.Y * speed
            local tPeak
            if AutoShootDrag < 0.001 then
                tPeak = math.max(vy0 / GRAVITY, 0)
            else
                local r = 1 + vy0 * AutoShootDrag / GRAVITY
                tPeak = (r > 0) and (math.log(r) / AutoShootDrag) or 0
            end
            tPeak = math.clamp(tPeak, 0, flightTime)
            local peakPos = BallPos(startPos, launchDir, speed, AutoShootDrag, tPeak)
            table.insert(candidates, {
                idealPos   = idealPos,
                aimPoint   = aimPoint,
                shootPos   = shootPos,
                launchDir  = launchDir,
                localX     = localX,
                localY     = localY,
                spin       = spinDir,
                power      = power,
                speed      = speed,
                score      = score,
                gkDist     = gkDist2D,
                trajOk     = trajOk,
                flightTime = flightTime,
                peakPos    = peakPos,
                isTopCorner = isTopCorner,
            })
        end
    end

    if #candidates == 0 then return nil end
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

    ShootDir       = result.launchDir
    ShootVel       = ShootDir * AutoShootBallSpeed  -- скорость = фиксированная, power сервер игнорирует
    CurrentSpin    = result.spin
    CurrentPower   = FIXED_POWER
    CurrentType    = string.format("%sX=%.1f Y=%.1f/%.1f gk=%.1f",
                        result.isTopCorner and "[TC] " or "",
                        result.localX, result.localY, GoalHeight, result.gkDist)

    -- 🔴 Красный = PredictedLand: куда мяч ПРИЛЕТИТ (= idealPos в плоскости ворот)
    -- 🟢 Зелёный = AimPoint: куда направлен ствол (выше цели из-за дуги гравитации)
    -- 🟡 Жёлтый  = PeakPoint: наивысшая точка дуги (виден подъём мяча)
    -- 🟠 Оранж.  = TrajectoryLines: вся дуга полёта
    PredictedLand    = result.idealPos
    AimPoint         = result.aimPoint
    CurrentFlightTime = result.flightTime
    CurrentLaunchDir  = result.launchDir
    CurrentSpeed      = result.speed
    CurrentPeakPos    = result.peakPos
    TargetPoint       = result.shootPos

    if Gui then
        Gui.Target.Text = string.format("→ X=%.1f Y=%.1f/%.1f", result.localX, result.localY, GoalHeight)
        Gui.Power.Text  = string.format("Power: %.1f | Spin: %s | %s",
                            CurrentPower, CurrentSpin, result.trajOk and "arc OK" or "arc FAIL")
        Gui.Spin.Text   = string.format("spd=%.0f dist=%.0f gk=%.1f",
                            result.speed, dist, result.gkDist)
        Gui.Goal.Text   = string.format("Goal W=%.1f H=%.1f floor=%.1f", GoalWidth, GoalHeight, GoalFloorY)
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
        local hasTarget = TargetPoint ~= nil

        -- 🟠 Траектория дуги (оранжевые линии) — главный визуал
        if hasTarget and CurrentLaunchDir and CurrentFlightTime > 0 then
            DrawTrajectory(HumanoidRootPart.Position, CurrentLaunchDir, CurrentSpeed, AutoShootDrag, CurrentFlightTime)
        else
            for _, l in ipairs(TrajectoryLines) do l.Visible = false end
        end

        -- 🟢 Зелёный = AimPoint (куда смотрит ствол с поправкой на гравитацию)
        if AimPoint then
            DrawOrientedCube(TargetCube, CFrame.new(AimPoint), Vector3.new(2,2,2))
        else
            for _, l in ipairs(TargetCube) do l.Visible = false end
        end

        -- 🔴 Красный = PredictedLand (куда мяч прилетит — предикция траектории)
        if PredictedLand then
            DrawOrientedCube(GoalCube, CFrame.new(PredictedLand), Vector3.new(2.5,2.5,2.5))
        else
            for _, l in ipairs(GoalCube) do l.Visible = false end
        end

        -- 🟡 Жёлтый = пик дуги (наивысшая точка полёта)
        if CurrentPeakPos and hasTarget then
            DrawOrientedCube(PeakCube, CFrame.new(CurrentPeakPos), Vector3.new(2,2,2))
        else
            for _, l in ipairs(PeakCube) do l.Visible = false end
        end

        -- 🔵 Голубой = реальный габарит ворот (W × H)
        if GoalCFrame and width and GoalHeight then
            DrawOrientedCube(NoSpinCube, GoalCFrame * CFrame.new(0, GoalHeight/2, 0),
                Vector3.new(width, GoalHeight, 1))
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
        if PeakCube[i]   and PeakCube[i].Remove    then PeakCube[i]:Remove()    end
    end
    for i = 1, TRAJ_SEGMENTS do
        if TrajectoryLines[i] and TrajectoryLines[i].Remove then TrajectoryLines[i]:Remove() end
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

        uiElements.AutoShootBallSpeed = UI.Sections.AutoShoot:Slider({
            Name = "Ball Speed", Minimum = 50, Maximum = 600,
            Default = AutoShootBallSpeed, Precision = 1,
            Callback = function(v) AutoShootBallSpeed = v end
        }, "AutoShootBallSpeed")

        uiElements.AutoShootDrag = UI.Sections.AutoShoot:Slider({
            Name = "Air Drag", Minimum = 0.0, Maximum = 2.0,
            Default = AutoShootDrag, Precision = 2,
            Callback = function(v) AutoShootDrag = v end
        }, "AutoShootDrag")

        UI.Sections.AutoShoot:SubLabel({Text = "[ℹ] Ball Speed: реальная скорость мяча (studs/s). Мяч ВЫШЕ цели → уменьши. НИЖЕ → увеличь."})
        UI.Sections.AutoShoot:SubLabel({Text = "[ℹ] Air Drag: затухание скорости. Мяч НЕ ДОЛЕТАЕТ → увеличь. ПЕРЕЛЕТАЕТ → уменьши."})

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
        GoalCFrame = nil; TargetPoint = nil; PredictedLand = nil; AimPoint = nil
        CurrentFlightTime = 0; CurrentLaunchDir = nil; CurrentSpeed = 0; CurrentPeakPos = nil
        LastShoot = 0; IsAnimating = false; CanShoot = true
        if AutoShootEnabled then AutoShoot.Start() end
        if AutoPickupEnabled then AutoPickup.Start() end
    end)
end

function AutoShootModule:Destroy()
    AutoShoot.Stop(); AutoPickup.Stop()
end

return AutoShootModule
