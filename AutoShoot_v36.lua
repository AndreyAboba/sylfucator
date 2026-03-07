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
local GRAVITY              = 196.2   -- studs/s² (Roblox workspace gravity)
local AutoShootBallSpeed   = 400     -- Скорость мяча studs/s. Мяч выше цели → увеличь. Мяч ниже → уменьши.
local AutoShootDragComp    = 1.0     -- k (1/s): экспоненц. затухание v_h=V·e^(-k·t). Не долетает → увеличь. Летит выше → уменьши.
local FIXED_POWER          = 5.0
local GK_REACH_RADIUS      = 5.0    -- Радиус статичного покрытия GK (studs)
local GK_REACH_SPEED       = 12.0   -- Скорость реакции GK для предикта дайва (studs/s)
local SPIN_TRICK_DIST      = 72     -- Ниже этой дистанции спин/навесы не работают на сервере
local SPIN_TRICK_MULT      = 2.8    -- ShootVel множитель для обмана дистанции
local AutoShootDerivMult   = 4.5    -- studs деривации при d=100. Мяч улетает меньше → увеличь.
local BALL_RADIUS           = 1.168  -- радиус мяча: 2.336 / 2 studs
-- Безопасный отступ = радиус мяча + небольшой запас чтобы мяч не касался штанги
local INSET                = BALL_RADIUS + 0.35  -- ~1.52 studs (горизонтальный, от штанг)
-- Вертикальный инсет: центр мяча должен быть минимум BALL_RADIUS от перекладины/пола
-- Дополнительный запас 0.25 studs покрывает неточность физической модели
local Y_TOP_INSET          = BALL_RADIUS + 0.25   -- 1.42 studs от перекладины
local Y_BOT_INSET          = 0.30                 -- 0.30 studs от пола

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

-- DrawTrajectory: кубический Безье с боковым смещением для Магнус-эффекта.
-- P0=start, P3=land (красный куб), P1/P2 = управляющие точки для подъёма + Magnus curl.
-- spinStr: "Left" = мяч летит вправо, "Right" = мяч летит влево (инверсия в игре).
local function DrawTrajectory(startPos, peakPos, endPos, spinStr)
    if not peakPos or not endPos then
        for _, l in ipairs(TrajectoryLines) do l.Visible = false end; return
    end

    -- Боковой вектор (перпендикуляр к траектории в горизонтальной плоскости)
    local fwd = endPos - startPos
    fwd = Vector3.new(fwd.X, 0, fwd.Z)
    if fwd.Magnitude < 0.1 then fwd = Vector3.new(1,0,0) end
    fwd = fwd.Unit
    local right = Vector3.new(-fwd.Z, 0, fwd.X)  -- поворот на 90° вправо

    -- Боковое смещение на пике: "Right" = влево, "Left" = вправо (инверсия игры)
    local spinSign = (spinStr == "Right") and -1 or (spinStr == "Left") and 1 or 0
    -- peakPos уже смещён из-за деривации — дополнительно акцентируем боковую кривизну
    local peakLateral = peakPos + right * spinSign * 1.2

    -- Кубический Безье: start → (P1) → (P2=peakLateral) → end
    local P0 = startPos
    local P1 = Vector3.new(startPos.X + (peakLateral.X-startPos.X)*0.5,
                           startPos.Y + (peakLateral.Y-startPos.Y)*0.8,
                           startPos.Z + (peakLateral.Z-startPos.Z)*0.5)
    local P2 = peakLateral
    local P3 = endPos

    local function cubicBezier(t)
        local mt = 1 - t
        return P0*(mt*mt*mt) + P1*(3*mt*mt*t) + P2*(3*mt*t*t) + P3*(t*t*t)
    end

    for i = 1, TRAJ_SEGMENTS do
        local t0 = (i-1) / TRAJ_SEGMENTS
        local t1 = i     / TRAJ_SEGMENTS
        local p0 = cubicBezier(t0)
        local p1 = cubicBezier(t1)
        local s0, v0 = Camera:WorldToViewportPoint(p0)
        local s1, v1 = Camera:WorldToViewportPoint(p1)
        local l = TrajectoryLines[i]
        if v0 and v1 and s0.Z > 0 and s1.Z > 0 then
            l.From = Vector2.new(s0.X, s0.Y); l.To = Vector2.new(s1.X, s1.Y); l.Visible = true
        else l.Visible = false end
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
-- Начальная позиция мяча: Character.ball (реальное положение мяча на поле),
-- а не HumanoidRootPart (центр тела игрока, сдвинут на ~1-3 stud)
local function GetBallStartPos()
    local ballPart = Character:FindFirstChild("ball")
    if ballPart then
        if ballPart:IsA("BasePart")   then return ballPart.Position     end
        if ballPart:IsA("Attachment") then return ballPart.WorldPosition end
    end
    return HumanoidRootPart.Position
end

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
local GkTrack = {}  -- { [name] = {pos=, time=, vel=} }

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
    -- Velocity tracking
    local now = tick()
    local tr  = GkTrack[best.name]
    local vel = Vector3.zero
    if tr and (now - tr.time) > 0.02 and (now - tr.time) < 0.8 then
        vel = (best.hrp.Position - tr.pos) / (now - tr.time)
    end
    GkTrack[best.name] = { pos = best.hrp.Position, time = now, vel = vel }

    -- localY: высота от реального пола ворот
    best.localY = best.hrp.Position.Y - (GoalFloorY or GoalCFrame.Position.Y)

    local isAggressive = not best.isInGoal
    if Gui then
        Gui.GK.Text = string.format("GK: %s%s X=%.1f Y=%.1f v=%.1f",
            best.name, isAggressive and " [RUSH]" or "",
            best.localX, best.localY, vel.Magnitude)
        Gui.GK.Color = isAggressive and Color3.fromRGB(255,80,0) or Color3.fromRGB(255,200,0)
    end
    return best.hrp, best.localX, best.localY, isAggressive, vel
end

-- ============================================================
-- ЯДРО: БАЛЛИСТИКА + SMART TARGET SELECTION
-- CalcLaunchDir: решает обратную задачу траектории.
-- Нам нужно попасть в точку targetPos стартуя из startPos.
-- Мяч летит под углом θ с начальной скоростью v.
-- По горизонтали: dist = v*cos(θ)*t  →  t = dist/(v*cos(θ))
-- По вертикали:   dh   = v*sin(θ)*t - 0.5*g*t²
-- Подстановка t и u=tan(θ):
--   k*u² - dist*u + (dh+k) = 0  где k = g*dist²/(2*v²)
-- Берём низкоугольное решение (более прямой удар).
-- ============================================================
local TargetPoint, ShootDir, ShootVel, CurrentSpin, CurrentPower, CurrentType
local AimPoint          = nil
local PredictedLand     = nil
local CurrentFlightTime = 0
local CurrentLaunchDir  = nil
local CurrentSpeed      = 0
local CurrentPeakPos    = nil
local CurrentIsLob      = false
local CurrentDist       = 0
local LastShoot = 0
local CanShoot  = true

-- CalcLaunchDir: первопорядковая коррекция гравитации + трение.
--
-- Принцип: мяч летит со скоростью V (константа, не зависит от power).
-- За время полёта t ≈ horizDist/V гравитация роняет его на Δy_g = 0.5*g*t².
-- Трение замедляет мяч → он падает ещё ниже → компенсируем дополнительной высотой Δy_d.
-- Решение: целимся в точку targetPos + Vector3.yAxis*(Δy_g + Δy_d).
-- В отличие от квадратного уравнения — не зависит от точности оценки V.
-- Ошибка ≈ O((Δy/horizDist)²) — мала при небольших углах.
--
-- Возвращает: launchDir (unit vector), horizDist, flightTime
local function CalcLaunchDir(startPos, targetPos)
    local toTarget  = targetPos - startPos
    local horiz     = Vector3.new(toTarget.X, 0, toTarget.Z)
    local horizDist = horiz.Magnitude

    if horizDist < 0.5 then
        return Vector3.new(0, 1, 0), 0, 0.1
    end

    local V  = AutoShootBallSpeed
    local k  = AutoShootDragComp   -- 1/s, экспоненциальная модель v_h(t)=V·exp(-k·t)
    -- Горизонтальная дистанция: d = (V/k)·(1-exp(-k·t))  =>  t = -ln(1 - k·d/V) / k
    -- При k→0: t = d/V.  Непрерывная функция, нет if-костылей.
    local t
    if k < 1e-5 then
        t = horizDist / V
    else
        local kd = math.min(k * horizDist / V, 0.990)
        t = -math.log(1 - kd) / k
    end

    local gravComp = 0.5 * GRAVITY * t * t
    local corrY    = targetPos.Y + gravComp
    local dir      = (Vector3.new(targetPos.X, corrY, targetPos.Z) - startPos).Unit
    local cosAngle = math.sqrt(dir.X*dir.X + dir.Z*dir.Z)

    -- Уточняем realT с учётом реального косинуса угла (1 итерация достаточно).
    -- Горизонтальная скорость = V*cosAngle, поэтому время полёта длиннее при крутых углах.
    local realT
    if k < 1e-5 then
        realT = (cosAngle > 0.01) and (horizDist / (V * cosAngle)) or t
    else
        local kdCos = math.min(k * horizDist / math.max(V * cosAngle, 1), 0.990)
        realT = -math.log(1 - kdCos) / k
    end

    return dir, horizDist, realT
end

local function GetTarget(dist, gkX, gkY, isAggressive, gkHrp, gkVel)
    if not GoalCFrame or not GoalWidth or not GoalHeight then return nil end
    if dist > AutoShootMaxDistance then return nil end

    local startPos     = GetBallStartPos()
    local halfW        = GoalWidth / 2 - INSET
    local playerLocalX = GoalCFrame:PointToObjectSpace(startPos).X
    gkVel = gkVel or Vector3.zero

    -- Предикт позиции GK через approxT секунд
    local approxT    = dist / AutoShootBallSpeed
    local gkPredW    = gkHrp and (gkHrp.Position + gkVel * math.min(approxT, 0.8)) or nil
    local gkPredLoc  = gkPredW and GoalCFrame:PointToObjectSpace(gkPredW) or nil
    local pgkX       = gkPredLoc and gkPredLoc.X or gkX
    local pgkY       = gkPredLoc and (gkPredW.Y - (GoalFloorY or GoalCFrame.Position.Y)) or gkY
    -- Зона дайва GK: статичный радиус + то что успеет пробежать за time
    local diveRange  = GK_REACH_RADIUS + GK_REACH_SPEED * approxT

    local xPoints = {-halfW, -halfW*0.7, -halfW*0.35, 0, halfW*0.35, halfW*0.7, halfW}
    -- Добавлены навесные фракции 0.88 и 0.96
    local yFracs  = {0.10, 0.30, 0.55, 0.78, 0.88, 0.96}

    local candidates = {}

    for _, xf in ipairs(xPoints) do
        for _, yf in ipairs(yFracs) do
            local localX = xf
            -- Цель с учётом вертикального инсета: центр мяча никогда не доходит
            -- до перекладины или пола ближе чем на радиус мяча + запас точности.
            local yRange = math.max(0.5, GoalHeight - Y_TOP_INSET - Y_BOT_INSET)
            local localY = Y_BOT_INSET + yf * yRange  -- гарантированно внутри ворот

            -- 3D позиция цели (idealPos) — точка в плоскости ворот
            local idealPos = GoalCFrame * Vector3.new(localX, localY, 0)

            -- === SCORING (предикт где GK будет когда мяч прилетит) ===
            local gkDistX   = math.abs(gkX - localX)
            local gkDistY   = math.abs(gkY - localY)
            local gkDist2D  = math.sqrt(gkDistX*gkDistX + gkDistY*gkDistY)
            local pgkDistX  = math.abs(pgkX - localX)
            local pgkDistY  = math.abs(pgkY - localY)
            local pgkDist2D = math.sqrt(pgkDistX*pgkDistX + pgkDistY*pgkDistY)

            -- Основа: расстояние предиктной позиции GK от точки
            -- Штраф если в зоне дайва: GK достанет
            local reachability = math.clamp(1 - pgkDist2D / diveRange, 0, 1)
            local score = pgkDist2D * 2.8 - reachability * 9.0

            local isTopCorner = (localY > GoalHeight * 0.72) and (math.abs(localX) > halfW * 0.5)
            local isCorner    = math.abs(localX) > halfW * 0.5
            local isLobShot   = (yf >= 0.85)

            -- Верхние углы: прыжок + смещение = труднее всего
            if isTopCorner then score = score + 7.0 end
            if isCorner and not isTopCorner then score = score + 2.5 end

            -- Навес: ценен когда GK низко или выходит вперёд
            if isLobShot then
                if pgkY < GoalHeight * 0.55 then score = score + 5.0 end
                if isAggressive             then score = score + 7.0 end
                -- На малых дистанциях навес бесполезен — мяч не успевает подняться
                if dist < 50 then score = score - 12.0 end
            end

            -- На близких дистанциях (<45 studs) штраф за очень высокие точки (>85% H)
            if dist < 45 and localY > GoalHeight * 0.82 then score = score - 8.0 end

            -- Центр: штраф
            if math.abs(localX) < halfW * 0.15 then score = score - 3.5 end

            -- Дальний угол (противоположный стороне игрока)
            local isFarCorner = (playerLocalX > halfW*0.2 and localX < -halfW*0.4)
                             or (playerLocalX < -halfW*0.2 and localX >  halfW*0.4)
            if isFarCorner then score = score + 3.5 end

            -- GK rush: прямо на пути = плохо, сбоку = хорошо
            if isAggressive and gkHrp then
                local dot = (idealPos - startPos).Unit:Dot((gkHrp.Position - startPos).Unit)
                score = score + (dot > 0.90 and -12.0 or 7.0)
            end

            -- GK движется к точке: штраф
            if gkVel.Magnitude > 2 and gkHrp then
                local toT = (idealPos - gkHrp.Position).Unit
                if gkVel.Unit:Dot(toT) > 0.65 then score = score - 4.5 end
            end

            -- Тень тела GK: проекция на плоскость ворот.
            -- Если candidate попадает в силуэт GK → сильный штраф (удар блокируется телом).
            if gkHrp then
                local gkProj = GoalCFrame:PointToObjectSpace(gkHrp.Position)
                local gkBX   = gkProj.X
                local gkBY   = gkHrp.Position.Y - (GoalFloorY or GoalCFrame.Position.Y)
                local inShadow = math.abs(localX - gkBX) < 1.3
                             and localY > (gkBY - 1.5)
                             and localY < (gkBY + 2.5)
                if inShadow then score = score - 14.0 end
            end

            -- Power не влияет на траекторию → константа
            local power = FIXED_POWER
            local speed = AutoShootBallSpeed

            -- Решение о спине
            local spinDir = "None"
            -- ВАЖНО: в игре спин инвертирован относительно интуиции:
            --   "Right" label → мяч летит ВЛЕВО (Магнус)
            --   "Left"  label → мяч летит ВПРАВО
            -- Поэтому: GK справа → хотим огнуть ВЛЕВО → шлём "Right" на сервер
            if dist > 65 and gkDist2D < 5.5 then
                spinDir = (gkX > localX) and "Right" or "Left"
                score   = score + 2.0
            elseif dist > 105 then
                local goalDir  = (GoalCFrame.Position - startPos).Unit
                local fwdDir   = HumanoidRootPart.CFrame.LookVector
                local fwdAngle = math.deg(math.acos(math.clamp(goalDir:Dot(fwdDir), -1, 1)))
                if fwdAngle < 20 then
                    -- "Right" огибает влево → для цели слева используем "Right" чтобы закрутить туда
                    spinDir = localX >= 0 and "Left" or "Right"
                end
            end

            -- Деривация: "Right" огибает ВЛЕВО → целимся ПРАВЕЕ цели (+dMult)
            --            "Left"  огибает ВПРАВО → целимся ЛЕВЕЕ  (-dMult)
            local derivation = 0
            if spinDir ~= "None" then
                local dMult  = AutoShootDerivMult * (dist / 100)^2
                derivation   = (spinDir == "Right" and 1 or -1) * dMult
            end

            -- shootPos = с учётом деривации (реальная точка куда направляем мяч)
            -- Clamp: центр мяча должен быть минимум BALL_RADIUS от внутреннего края штанги
            local safeEdge    = GoalWidth/2 - BALL_RADIUS
            local shootLocalX = math.clamp(localX + derivation, -safeEdge, safeEdge)
            local shootPos    = GoalCFrame * Vector3.new(shootLocalX, localY, 0)

            -- *** БАЛЛИСТИКА: рассчитываем LaunchDir с учётом гравитации + трения ***
            local launchDir, horizD, flightT = CalcLaunchDir(startPos, shootPos)
            -- sinTheta = launchDir.Y. sinTheta > 0.64 → угол > 40° (слишком крутой для обычного удара)
            local launchAngleDeg = math.deg(math.asin(math.clamp(launchDir.Y, -1, 1)))
            local trajOk = (launchAngleDeg < 42)  -- больше 42° — крутой, штраф

            -- Штраф за крутую траекторию (выше 42° = риск перелёта)
            if not trajOk then
                score = score - 5.0
                if launchAngleDeg > 55 then score = score - 6.0 end  -- очень крутой = сильный штраф
            end

            -- AimPoint: где физически находится мяч в момент пересечения плоскости ворот
            -- Это точка на НАШЕЙ параболе при t=flightT (должна совпасть с shootPos если формула верна)
            local V    = AutoShootBallSpeed
            local cosA = math.sqrt(launchDir.X^2 + launchDir.Z^2)
            local aimPoint
            if cosA > 0.01 and flightT > 0 then
                aimPoint = Vector3.new(
                    startPos.X + launchDir.X * V * flightT,
                    startPos.Y + launchDir.Y * V * flightT - 0.5 * GRAVITY * flightT * flightT,
                    startPos.Z + launchDir.Z * V * flightT
                )
            else
                aimPoint = shootPos
            end

            -- ШТРАФ за прицел выше безопасной зоны (gravComp поднимает aim выше цели).
            -- aimPoint.Y ≈ targetPos.Y (куда мяч ПРИЛЕТИТ), а не куда мы ЦЕЛИМСЯ.
            -- Прицел = localY + gravComp. Безопасный максимум = GoalHeight - Y_TOP_INSET.
            local gravCompHere = 0.5 * GRAVITY * flightT * flightT
            local aimLocalY    = localY + gravCompHere   -- высота прицела внутри ворот
            local safeTop      = GoalHeight - Y_TOP_INSET
            if aimLocalY > safeTop then
                local over = aimLocalY - safeTop
                -- Штраф растёт квадратично: маленький перелёт — небольшой штраф,
                -- большой перелёт (близкая дистанция + высокая цель) — очень большой
                score = score - over * over * 6.0 - over * 4.0
            end

            -- flightTime уже рассчитан CalcLaunchDir
            local flightTime = flightT
            -- Пик дуги: момент когда vy - g*t = 0
            local vyComp  = launchDir.Y * speed
            local tPeak   = math.max(vyComp / GRAVITY, 0)
            local peakPos = startPos + Vector3.new(
                launchDir.X * speed * tPeak,
                launchDir.Y * speed * tPeak - 0.5 * GRAVITY * tPeak * tPeak,
                launchDir.Z * speed * tPeak
            )
            table.insert(candidates, {
                idealPos    = idealPos,
                aimPoint    = aimPoint,
                shootPos    = shootPos,
                launchDir   = launchDir,
                localX      = localX,
                localY      = localY,
                spin        = spinDir,
                power       = power,
                speed       = speed,
                score       = score,
                gkDist      = gkDist2D,
                trajOk      = trajOk,
                flightTime  = flightTime,
                peakPos     = peakPos,
                isTopCorner = isTopCorner,
                isLobShot   = isLobShot,
            })
        end
    end

    -- ================================================================
    -- РИКОШЕТЫ ОТ ШТАНГ
    -- Мяч намеренно бьётся об внутреннюю грань штанги и отскакивает в ворота.
    -- Полезно когда вратарь перекрывает прямой путь, а угловой путь заблокирован.
    -- Геометрия:
    --   Центр мяча при касании штанги = innerEdge + BALL_RADIUS (в сторону центра)
    --   Нормаль отражения = горизонтальный вектор от штанги к центру ворот
    --   d_out = d_in - 2*(d_in·n)*n
    -- ================================================================
    local ricochetEnabled = (dist > 15)  -- рикошет бесполезен вплотную
    if ricochetEnabled then
        local postDefs = {
            { side =  1, postLocalX = -GoalWidth/2 },  -- левая штанга, нормаль = +X (вправо)
            { side = -1, postLocalX =  GoalWidth/2 },  -- правая штанга, нормаль = -X (влево)
        }
        -- Нормаль отражения: от штанги к центру ворот (горизонтальная)
        -- side=+1 → левая штанга → нормаль смотрит вправо (+X в goal local)
        -- side=-1 → правая штанга → нормаль смотрит влево (-X в goal local)
        for _, pd in ipairs(postDefs) do
            local normalLocal = Vector3.new(pd.side, 0, 0)
            local nWorld      = GoalCFrame:VectorToWorldSpace(normalLocal)

            -- Открытость угла рикошета
            -- Если игрок с той же стороны что и штанга — угол закрыт (летим почти параллельно)
            -- pd.postLocalX < 0 = левая штанга; playerLocalX < -halfW*0.25 = игрок слева
            local isClosedAngle = (pd.postLocalX < 0 and playerLocalX < -halfW * 0.20)
                                or (pd.postLocalX > 0 and playerLocalX >  halfW * 0.20)

            for _, hf in ipairs({0.20, 0.45, 0.72}) do
                local hitY      = hf * GoalHeight
                local hitLocalX = pd.postLocalX + pd.side * BALL_RADIUS
                local hitWorld  = GoalCFrame * Vector3.new(hitLocalX, hitY, 0)

                -- Вектор прихода мяча (без вертикальной коррекции — для вычисления отражения)
                local dInFlat = Vector3.new(
                    hitWorld.X - startPos.X, 0, hitWorld.Z - startPos.Z
                ).Unit

                -- Отражение: d_out = d_in - 2*(d_in·n)*n
                local dotVal = dInFlat:Dot(nWorld)
                local dOut   = (dInFlat - 2 * dotVal * nWorld).Unit

                -- Угол падения на штангу (cosIncidence = |d_in · n|)
                local cosInc = math.abs(dotVal)
                local incDeg = math.deg(math.acos(math.clamp(cosInc, 0, 1)))
                -- Хороший рикошет: 20°-72° (слишком мелкий = скользящий, слишком большой = назад)
                local badAngle = isClosedAngle or (incDeg < 18) or (incDeg > 74)

                local dOutLocalZ = GoalCFrame:VectorToObjectSpace(dOut).Z
                local goesIn = (dOutLocalZ < 0.1) and not badAngle

                if goesIn then
                    -- Трейс dOut до задней сетки ворот (Z_local = -NET_DEPTH)
                    local NET_DEPTH  = 5
                    local dOutLoc    = GoalCFrame:VectorToObjectSpace(dOut)
                    local hitLoc     = GoalCFrame:PointToObjectSpace(hitWorld)
                    local tNet       = (dOutLoc.Z < -0.01)
                                        and ((-NET_DEPTH - hitLoc.Z) / dOutLoc.Z)
                                        or  5
                    local landLocal  = hitLoc + dOutLoc * tNet
                    local landX      = landLocal.X
                    local landY      = landLocal.Y

                    -- Scoring: как далеко от вратаря место приземления?
                    -- Predicted GK scoring для рикошета
                    local rpgkDistX = math.abs(pgkX - landX)
                    local rpgkDistY = math.abs(pgkY - landY)
                    local rpgkDist  = math.sqrt(rpgkDistX*rpgkDistX + rpgkDistY*rpgkDistY)
                    local rReach    = math.clamp(1 - rpgkDist / diveRange, 0, 1)
                    local rscore    = rpgkDist * 3.0 - rReach * 8.0

                    -- Мяч после рикошета летит на противоположную сторону от GK
                    local crossSide = (pgkX > 0 and landX < -GoalWidth*0.20)
                                   or (pgkX < 0 and landX >  GoalWidth*0.20)
                    if crossSide then rscore = rscore + 7.0 end

                    -- Бонус за угол рикошета близкий к 45° (идеальный отскок)
                    rscore = rscore + (30 - math.abs(incDeg - 45)) * 0.1

                    rscore = rscore - 1.0  -- базовый штраф за сложность

                    -- LaunchDir на точку касания (с гравитационной коррекцией)
                    local rLaunchDir, rHorizD, rFlightT = CalcLaunchDir(startPos, hitWorld)
                    local rcosA = math.sqrt(rLaunchDir.X^2 + rLaunchDir.Z^2)
                    local rAimPoint
                    if rcosA > 0.01 then
                        rAimPoint = Vector3.new(
                            startPos.X + rLaunchDir.X * AutoShootBallSpeed * rFlightT,
                            startPos.Y + rLaunchDir.Y * AutoShootBallSpeed * rFlightT
                                       - 0.5 * GRAVITY * rFlightT * rFlightT,
                            startPos.Z + rLaunchDir.Z * AutoShootBallSpeed * rFlightT
                        )
                    else rAimPoint = hitWorld end

                    local ryComp  = rLaunchDir.Y * AutoShootBallSpeed
                    local rtPeak  = math.max(ryComp / GRAVITY, 0)
                    local rPeak   = Vector3.new(
                        startPos.X + rLaunchDir.X * AutoShootBallSpeed * rtPeak,
                        startPos.Y + rLaunchDir.Y * AutoShootBallSpeed * rtPeak
                                   - 0.5 * GRAVITY * rtPeak * rtPeak,
                        startPos.Z + rLaunchDir.Z * AutoShootBallSpeed * rtPeak
                    )

                    table.insert(candidates, {
                        idealPos    = hitWorld,    -- красный бокс = точка касания штанги
                        aimPoint    = rAimPoint,
                        shootPos    = hitWorld,
                        launchDir   = rLaunchDir,
                        localX      = hitLocalX,
                        localY      = hitY,
                        spin        = "None",      -- для рикошета спин не нужен
                        power       = FIXED_POWER,
                        speed       = AutoShootBallSpeed,
                        score       = rscore,
                        gkDist      = rgkDist,
                        trajOk      = (rLaunchDir.Y < 0.85),
                        flightTime  = rFlightT,
                        peakPos     = rPeak,
                        isTopCorner = false,
                        isRicochet  = true,
                    })
                end
            end
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

    local dist = (GetBallStartPos() - GoalCFrame.Position).Magnitude
    if Gui then
        Gui.Dist.Text = string.format("Dist: %.0f | Goal: %.0f×%.0f", dist, GoalWidth, GoalHeight)
    end

    if dist > AutoShootMaxDistance then
        TargetPoint = nil; LastShootRedBox = nil
        if Gui then Gui.Target.Text = "Too Far" end
        return
    end

    local gkHrp, gkX, gkY, isAggressive, gkVel = GetEnemyGoalie()
    local result = GetTarget(dist, gkX or 0, gkY or 0, isAggressive or false, gkHrp, gkVel)
    if not result then
        TargetPoint = nil; LastShootRedBox = nil
        if Gui then Gui.Target.Text = "No Candidate" end
        return
    end

    ShootDir       = result.launchDir
    -- TRICK: ниже SPIN_TRICK_DIST сервер не применяет спин/навесы.
    -- Умножаем ShootVel → сервер "видит" большую дистанцию и применяет нужный эффект.
    local needsTrick = CurrentDist < SPIN_TRICK_DIST and (CurrentSpin ~= "None" or CurrentIsLob)
    ShootVel = ShootDir * (FIXED_POWER * 1400 * (needsTrick and SPIN_TRICK_MULT or 1.0))
    CurrentSpin    = result.spin
    CurrentPower   = FIXED_POWER  -- power константа, не влияет на траекторию
    local typePrefix = result.isRicochet and "[RIC] "
        or (result.isLobShot and "[LOB] "
        or (result.isTopCorner and "[TC] " or ""))
    CurrentType    = string.format("%sX=%.1f Y=%.1f/%.1f gk=%.1f",
                        typePrefix, result.localX, result.localY, GoalHeight, result.gkDist)

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
    CurrentIsLob      = result.isLobShot or false
    CurrentDist       = dist
    TargetPoint       = result.shootPos

    if Gui then
        Gui.Target.Text = string.format("→ X=%.1f Y=%.1f/%.1f", result.localX, result.localY, GoalHeight)
        local cosA_d = math.sqrt(result.launchDir.X^2 + result.launchDir.Z^2)
        local launchAngle = math.deg(math.atan(result.launchDir.Y / math.max(cosA_d, 0.01)))
        Gui.Power.Text  = string.format("θ=%.1f° t=%.2fs %s | Spin=%s",
                            launchAngle, result.flightTime,
                            result.trajOk and "OK" or "!steep",
                            result.spin)
        Gui.Spin.Text   = string.format("V=%.0f k=%.2f drv=%.1f d=%.0f",
                            AutoShootBallSpeed, AutoShootDragComp, AutoShootDerivMult, dist)
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
        local dist    = GoalCFrame and (GetBallStartPos() - GoalCFrame.Position).Magnitude or 999

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
            DrawTrajectory(GetBallStartPos(), CurrentPeakPos, PredictedLand, CurrentSpin)
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
            Name = "Ball Speed", Minimum = 100, Maximum = 1000,
            Default = AutoShootBallSpeed, Precision = 1,
            Callback = function(v) AutoShootBallSpeed = v end
        }, "AutoShootBallSpeed")
        UI.Sections.AutoShoot:SubLabel({Text = "~400 studs/s. Мяч выше цели → увеличь | Мяч ниже → уменьши"})

        uiElements.AutoShootDragComp = UI.Sections.AutoShoot:Slider({
            Name = "Drag Compensation", Minimum = 0, Maximum = 1.0,
            Default = AutoShootDragComp, Precision = 2,
            Callback = function(v) AutoShootDragComp = v end
        }, "AutoShootDragComp")
        UI.Sections.AutoShoot:SubLabel({Text = "[↑] Мяч не долетает → увеличь  |  Перелёт → уменьши"})

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
