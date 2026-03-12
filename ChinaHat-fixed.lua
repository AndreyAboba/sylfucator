local ChinaHat = {}

function ChinaHat.Init(UI, Core, notify)
local Players = Core.Services.Players
local RunService = Core.Services.RunService
local Workspace = Core.Services.Workspace
local UserInputService = Core.Services.UserInputService
local camera = Workspace.CurrentCamera

local LocalPlayer = Core.PlayerData.LocalPlayer
local localCharacter = LocalPlayer.Character
local localHumanoid = localCharacter and localCharacter:FindFirstChild("Humanoid")

local State = {
ChinaHat = {
    HatActive = { Value = false, Default = false },
    HatScale = { Value = 0.85, Default = 0.85 },
    HatParts = { Value = 50, Default = 50 },
    HatGradientSpeed = { Value = 4, Default = 4 },
    HatGradient = { Value = true, Default = true },
    HatColor = { Value = Color3.fromRGB(0, 0, 255), Default = Color3.fromRGB(0, 0, 255) },
    HatYOffset = { Value = 1.4, Default = 1.4 },
    OutlineCircle = { Value = false, Default = false }
},
Circle = {
    CircleActive = { Value = false, Default = false },
    CircleRadius = { Value = 1.7, Default = 1.7 },
    CircleParts = { Value = 30, Default = 30 },
    CircleGradientSpeed = { Value = 4, Default = 4 },
    CircleGradient = { Value = true, Default = true },
    CircleColor = { Value = Color3.fromRGB(0, 0, 255), Default = Color3.fromRGB(0, 0, 255) },
    JumpAnimate = { Value = false, Default = false },
    CircleYOffset = { Value = -3.2, Default = -3.2 }
},
Nimb = {
    NimbActive = { Value = false, Default = false },
    NimbRadius = { Value = 1.7, Default = 1.7 },
    NimbParts = { Value = 30, Default = 30 },
    NimbGradientSpeed = { Value = 4, Default = 4 },
    NimbGradient = { Value = true, Default = true },
    NimbColor = { Value = Color3.fromRGB(0, 0, 255), Default = Color3.fromRGB(0, 0, 255) },
    NimbYOffset = { Value = 3, Default = 3 }
}
}

local hatLines = {}
local hatCircleQuads = {}
local circleQuads = {}
local nimbQuads = {}
local jumpAnimationActive = false
local renderConnection
local humanoidConnection
local uiElements = {}

-- ── ShiftLock: финальная версия детекции ─────────────────────────────────────
-- Все предыдущие методы зависели от внешнего состояния (CameraSubject,
-- MouseBehavior), которое PlayerModule выставляет АСИНХРОННО. На первом
-- запуске это состояние ещё не установлено — отсюда баг.
--
-- Решение: читать только реальные значения (camera.CFrame + HRP.Position).
-- camera.CFrame доступен сразу на первом кадре, НЕ зависит от CameraSubject.
-- MouseBehavior используется как дополнительная проверка (OR), на случай
-- если геометрия не подходит (первое лицо, зум и т.д.).
local isShiftLockEnabled = false

local function updateShiftLock()
    -- Метод A: геометрия (надёжна с первого кадра, не требует CameraSubject)
    local hrp = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
    if hrp then
        local camPos  = camera.CFrame.Position
        local charPos = hrp.Position
        local dist    = (camPos - charPos).Magnitude
        if dist >= 8 and dist <= 50 then
            local dot = camera.CFrame.LookVector:Dot((charPos - camPos).Unit)
            if dot > 0.7 then
                isShiftLockEnabled = true
                return
            end
        end
    end
    -- Метод B: MouseBehavior (работает, когда PlayerModule уже инициализирован)
    isShiftLockEnabled = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
end
-- ─────────────────────────────────────────────────────────────────────────────

local function destroyParts(parts)
    for _, p in ipairs(parts) do if p and p.Destroy then p:Destroy() end end
    table.clear(parts)
end

local function interpolateColor(c1, c2, f)
    return Color3.new(c1.R+(c2.R-c1.R)*f, c1.G+(c2.G-c1.G)*f, c1.B+(c2.B-c1.B)*f)
end

local function createHat()
    if not localCharacter or not localCharacter:FindFirstChild("Head") then return end
    destroyParts(hatLines); destroyParts(hatCircleQuads)
    for i = 1, State.ChinaHat.HatParts.Value do
        local line = Drawing.new("Line")
        line.Visible = false; line.Thickness = 0.06; line.Transparency = 0.5
        line.Color = State.ChinaHat.HatGradient.Value and
            interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, i/State.ChinaHat.HatParts.Value) or
            State.ChinaHat.HatColor.Value
        table.insert(hatLines, line)
    end
    if State.ChinaHat.OutlineCircle.Value then
        for i = 1, State.ChinaHat.HatParts.Value do
            local q = Drawing.new("Quad")
            q.Visible = false; q.Thickness = 1; q.Filled = false
            q.Color = State.ChinaHat.HatGradient.Value and
                interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, i/State.ChinaHat.HatParts.Value) or
                State.ChinaHat.HatColor.Value
            table.insert(hatCircleQuads, q)
        end
    end
end

local function createCircle()
    if not localCharacter or not localCharacter:FindFirstChild("HumanoidRootPart") then return end
    destroyParts(circleQuads)
    for i = 1, State.Circle.CircleParts.Value do
        local q = Drawing.new("Quad")
        q.Visible = false; q.Thickness = 1; q.Filled = false
        q.Color = State.Circle.CircleGradient.Value and
            interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, i/State.Circle.CircleParts.Value) or
            State.Circle.CircleColor.Value
        table.insert(circleQuads, q)
    end
end

local function createNimb()
    if not localCharacter or not localCharacter:FindFirstChild("HumanoidRootPart") then return end
    destroyParts(nimbQuads)
    for i = 1, State.Nimb.NimbParts.Value do
        local q = Drawing.new("Quad")
        q.Visible = false; q.Thickness = 1; q.Filled = false
        q.Color = State.Nimb.NimbGradient.Value and
            interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, i/State.Nimb.NimbParts.Value) or
            State.Nimb.NimbColor.Value
        table.insert(nimbQuads, q)
    end
end

local function updateHat()
    if not State.ChinaHat.HatActive.Value or not localCharacter or not localCharacter:FindFirstChild("Head") then
        for _, l in ipairs(hatLines) do l.Visible = false end
        for _, q in ipairs(hatCircleQuads) do q.Visible = false end
        return
    end
    local head = localCharacter.Head
    local y = head.Position.Y + State.ChinaHat.HatYOffset.Value
    local t = tick()
    local hatHeight = 2.15 * State.ChinaHat.HatScale.Value
    local hatRadius = 1.95 * State.ChinaHat.HatScale.Value
    for i, line in ipairs(hatLines) do
        local angle = (i/State.ChinaHat.HatParts.Value)*2*math.pi
        local bP = Vector3.new(head.Position.X, y, head.Position.Z)
        local tP = Vector3.new(head.Position.X+math.cos(angle)*hatRadius, y-hatHeight/3, head.Position.Z+math.sin(angle)*hatRadius)
        local eP = tP + (tP-bP).Unit*0.03
        local sS, osS = camera:WorldToViewportPoint(bP)
        local sE, osE = camera:WorldToViewportPoint(eP)
        if osS and osE and sS.Z>0 and sE.Z>0 then
            line.From = Vector2.new(sS.X,sS.Y); line.To = Vector2.new(sE.X,sE.Y); line.Visible = true
            if State.ChinaHat.HatGradient.Value then
                local f = (math.sin(t*State.ChinaHat.HatGradientSpeed.Value+(i/State.ChinaHat.HatParts.Value)*2*math.pi)+1)/2
                line.Color = interpolateColor(Core.GradientColors.Color1.Value,Core.GradientColors.Color2.Value,f)
            else line.Color = State.ChinaHat.HatColor.Value end
        else line.Visible = false end
    end
    if State.ChinaHat.OutlineCircle.Value and #hatCircleQuads>0 then
        local topCenter,cnt = Vector3.new(),0
        for i,line in ipairs(hatLines) do
            if line.Visible then
                local angle = (i/State.ChinaHat.HatParts.Value)*2*math.pi
                topCenter = topCenter + Vector3.new(head.Position.X+math.cos(angle)*hatRadius, y-hatHeight/3, head.Position.Z+math.sin(angle)*hatRadius)
                cnt = cnt+1
            end
        end
        topCenter = cnt>0 and topCenter/cnt or Vector3.new(head.Position.X,y-hatHeight/3,head.Position.Z)
        local sc,osc = camera:WorldToViewportPoint(topCenter)
        if osc and sc.Z>0 then
            local cR = 2.0*State.ChinaHat.HatScale.Value
            local t2 = tick()
            for i,q in ipairs(hatCircleQuads) do
                local a1=((i-1)/#hatCircleQuads)*2*math.pi; local a2=(i/#hatCircleQuads)*2*math.pi
                local p1=topCenter+Vector3.new(math.cos(a1)*cR,0,math.sin(a1)*cR)
                local p2=topCenter+Vector3.new(math.cos(a2)*cR,0,math.sin(a2)*cR)
                local sp1,os1=camera:WorldToViewportPoint(p1); local sp2,os2=camera:WorldToViewportPoint(p2)
                if os1 and os2 and sp1.Z>0 and sp2.Z>0 then
                    q.PointA=Vector2.new(sp1.X,sp1.Y);q.PointB=Vector2.new(sp2.X,sp2.Y)
                    q.PointC=Vector2.new(sp2.X,sp2.Y);q.PointD=Vector2.new(sp1.X,sp1.Y);q.Visible=true
                    if State.ChinaHat.HatGradient.Value then
                        local f=(math.sin(t2*State.ChinaHat.HatGradientSpeed.Value+(i/#hatCircleQuads)*2*math.pi)+1)/2
                        q.Color=interpolateColor(Core.GradientColors.Color1.Value,Core.GradientColors.Color2.Value,f)
                    else q.Color=State.ChinaHat.HatColor.Value end
                else q.Visible=false end
            end
        else for _,q in ipairs(hatCircleQuads) do q.Visible=false end end
    end
end

local function updateCircle()
    if not State.Circle.CircleActive.Value or not localCharacter or not localCharacter:FindFirstChild("HumanoidRootPart") then
        for _,q in ipairs(circleQuads) do q.Visible=false end; return
    end
    local rootPart = localCharacter.HumanoidRootPart
    local circleHeight
    if isShiftLockEnabled then
        local hum = localCharacter:FindFirstChild("Humanoid")
        circleHeight = rootPart.Position.Y + State.Circle.CircleYOffset.Value - ((hum and hum.HipHeight or 2.0)*0.5)
    else
        circleHeight = rootPart.Position.Y + State.Circle.CircleYOffset.Value
    end
    local t = tick()
    local center = Vector3.new(rootPart.Position.X, circleHeight, rootPart.Position.Z)
    local sc,osc = camera:WorldToViewportPoint(center)
    if not(osc and sc.Z>0) then for _,q in ipairs(circleQuads) do q.Visible=false end; return end
    local r,n = State.Circle.CircleRadius.Value, #circleQuads
    for i,q in ipairs(circleQuads) do
        local a1=((i-1)/n)*2*math.pi; local a2=(i/n)*2*math.pi
        local p1=center+Vector3.new(math.cos(a1)*r,0,math.sin(a1)*r)
        local p2=center+Vector3.new(math.cos(a2)*r,0,math.sin(a2)*r)
        local sp1,os1=camera:WorldToViewportPoint(p1); local sp2,os2=camera:WorldToViewportPoint(p2)
        if os1 and os2 and sp1.Z>0 and sp2.Z>0 then
            q.PointA=Vector2.new(sp1.X,sp1.Y);q.PointB=Vector2.new(sp2.X,sp2.Y)
            q.PointC=Vector2.new(sp2.X,sp2.Y);q.PointD=Vector2.new(sp1.X,sp1.Y);q.Visible=true
            if State.Circle.CircleGradient.Value then
                local f=(math.sin(t*State.Circle.CircleGradientSpeed.Value+(i/n)*2*math.pi)+1)/2
                q.Color=interpolateColor(Core.GradientColors.Color1.Value,Core.GradientColors.Color2.Value,f)
            else q.Color=State.Circle.CircleColor.Value end
        else q.Visible=false end
    end
end

local function updateNimb()
    if not State.Nimb.NimbActive.Value or not localCharacter then
        for _,q in ipairs(nimbQuads) do q.Visible=false end; return
    end
    local head = localCharacter:FindFirstChild("Head")
    if not head then for _,q in ipairs(nimbQuads) do q.Visible=false end; return end
    local center = Vector3.new(head.Position.X, head.Position.Y+State.Nimb.NimbYOffset.Value, head.Position.Z)
    local sc,osc = camera:WorldToViewportPoint(center)
    if not(osc and sc.Z>0) then for _,q in ipairs(nimbQuads) do q.Visible=false end; return end
    local t,r,n = tick(),State.Nimb.NimbRadius.Value,#nimbQuads
    for i,q in ipairs(nimbQuads) do
        local a1=((i-1)/n)*2*math.pi; local a2=(i/n)*2*math.pi
        local p1=center+Vector3.new(math.cos(a1)*r,0,math.sin(a1)*r)
        local p2=center+Vector3.new(math.cos(a2)*r,0,math.sin(a2)*r)
        local sp1,os1=camera:WorldToViewportPoint(p1); local sp2,os2=camera:WorldToViewportPoint(p2)
        if os1 and os2 and sp1.Z>0 and sp2.Z>0 then
            q.PointA=Vector2.new(sp1.X,sp1.Y);q.PointB=Vector2.new(sp2.X,sp2.Y)
            q.PointC=Vector2.new(sp2.X,sp2.Y);q.PointD=Vector2.new(sp1.X,sp1.Y);q.Visible=true
            if State.Nimb.NimbGradient.Value then
                local f=(math.sin(t*State.Nimb.NimbGradientSpeed.Value+(i/n)*2*math.pi)+1)/2
                q.Color=interpolateColor(Core.GradientColors.Color1.Value,Core.GradientColors.Color2.Value,f)
            else q.Color=State.Nimb.NimbColor.Value end
        else q.Visible=false end
    end
end

local function animateJump()
    if not State.Circle.JumpAnimate.Value or #circleQuads==0 or jumpAnimationActive then return end
    jumpAnimationActive=true
    local t,dur=0,0.55; local iR=State.Circle.CircleRadius.Value; local mR=iR*1.6
    while t<dur do
        local dt=RunService.RenderStepped:Wait(); t=t+dt
        State.Circle.CircleRadius.Value=iR+(mR-iR)*math.sin((t/dur)*math.pi)
        updateCircle()
    end
    State.Circle.CircleRadius.Value=iR; jumpAnimationActive=false
end

local function toggleHat(v) State.ChinaHat.HatActive.Value=v; if v then createHat(); notify("ChinaHat","Hat Enabled",true) else destroyParts(hatLines);destroyParts(hatCircleQuads);notify("ChinaHat","Hat Disabled",true) end end
local function toggleCircle(v) State.Circle.CircleActive.Value=v; if v then createCircle();notify("Circle","Circle Enabled",true) else destroyParts(circleQuads);notify("Circle","Circle Disabled",true) end end
local function toggleNimb(v) State.Nimb.NimbActive.Value=v; if v then createNimb();notify("Nimb","Nimb Enabled",true) else destroyParts(nimbQuads);notify("Nimb","Nimb Disabled",true) end end

local function onStateChanged(_,ns)
    if State.Circle.JumpAnimate.Value and ns==Enum.HumanoidStateType.Jumping and not jumpAnimationActive then animateJump() end
end

local function connectHumanoid(character)
    if humanoidConnection then humanoidConnection:Disconnect() end
    localCharacter = character
    camera = Workspace.CurrentCamera
    local hum = character:WaitForChild("Humanoid",5)
    if hum then localHumanoid=hum; humanoidConnection=hum.StateChanged:Connect(onStateChanged) end
    if State.ChinaHat.HatActive.Value  then createHat()   end
    if State.Circle.CircleActive.Value then createCircle() end
    if State.Nimb.NimbActive.Value     then createNimb()   end
end

local function SynchronizeConfigValues()
    if not uiElements then return end
    local function ss(e,cur,fn) if e and e.GetValue then local v=e:GetValue(); if v~=cur then fn(v) end end end
    ss(uiElements.HatScale,        State.ChinaHat.HatScale.Value,         function(v) State.ChinaHat.HatScale.Value=v;         if State.ChinaHat.HatActive.Value  then createHat()   end end)
    ss(uiElements.HatParts,        State.ChinaHat.HatParts.Value,         function(v) State.ChinaHat.HatParts.Value=v;         if State.ChinaHat.HatActive.Value  then createHat()   end end)
    ss(uiElements.HatGradientSpeed,State.ChinaHat.HatGradientSpeed.Value, function(v) State.ChinaHat.HatGradientSpeed.Value=v end)
    ss(uiElements.HatYOffset,      State.ChinaHat.HatYOffset.Value,       function(v) State.ChinaHat.HatYOffset.Value=v        end)
    ss(uiElements.CircleRadius,    State.Circle.CircleRadius.Value,       function(v) State.Circle.CircleRadius.Value=v;       if State.Circle.CircleActive.Value then createCircle() end end)
    ss(uiElements.CircleParts,     State.Circle.CircleParts.Value,        function(v) State.Circle.CircleParts.Value=v;        if State.Circle.CircleActive.Value then createCircle() end end)
    ss(uiElements.CircleGradientSpeed,State.Circle.CircleGradientSpeed.Value,function(v) State.Circle.CircleGradientSpeed.Value=v end)
    ss(uiElements.CircleYOffset,   State.Circle.CircleYOffset.Value,      function(v) State.Circle.CircleYOffset.Value=v       end)
    ss(uiElements.NimbRadius,      State.Nimb.NimbRadius.Value,           function(v) State.Nimb.NimbRadius.Value=v;           if State.Nimb.NimbActive.Value     then createNimb()   end end)
    ss(uiElements.NimbParts,       State.Nimb.NimbParts.Value,            function(v) State.Nimb.NimbParts.Value=v;            if State.Nimb.NimbActive.Value     then createNimb()   end end)
    ss(uiElements.NimbGradientSpeed,State.Nimb.NimbGradientSpeed.Value,   function(v) State.Nimb.NimbGradientSpeed.Value=v     end)
    ss(uiElements.NimbYOffset,     State.Nimb.NimbYOffset.Value,          function(v) State.Nimb.NimbYOffset.Value=v           end)
end

renderConnection = RunService.RenderStepped:Connect(function()
    -- updateShiftLock использует только camera.CFrame + HRP.Position —
    -- оба значения доступны с первого кадра, без зависимости от CameraSubject
    updateShiftLock()
    if localCharacter then
        updateHat(); updateCircle(); updateNimb()
    else
        for _,l in ipairs(hatLines) do l.Visible=false end
        for _,q in ipairs(hatCircleQuads) do q.Visible=false end
        for _,q in ipairs(circleQuads) do q.Visible=false end
        for _,q in ipairs(nimbQuads) do q.Visible=false end
    end
end)

LocalPlayer.CharacterAdded:Connect(connectHumanoid)
if localCharacter then
    connectHumanoid(localCharacter)
else
    task.spawn(function() connectHumanoid(LocalPlayer.CharacterAdded:Wait()) end)
end

if UI.Tabs and UI.Tabs.Visuals then
    local chS = UI.Sections.ChinaHat or UI.Tabs.Visuals:Section({Name="ChinaHat",Side="Left"})
    UI.Sections.ChinaHat = chS
    chS:Header({Name="China Hat"}); chS:SubLabel({Text="Displays a hat above the player head"})
    uiElements.HatEnabled       = chS:Toggle({Name="Enabled",Default=State.ChinaHat.HatActive.Default,Callback=function(v) toggleHat(v) end},"HatEnabled")
    chS:Divider()
    uiElements.HatScale         = chS:Slider({Name="Scale",Minimum=0.5,Maximum=2.0,Default=State.ChinaHat.HatScale.Default,Precision=2,Callback=function(v) State.ChinaHat.HatScale.Value=v;if State.ChinaHat.HatActive.Value then createHat() end;notify("ChinaHat","Scale: "..v,false) end},"HatScale")
    uiElements.HatParts         = chS:Slider({Name="Parts",Minimum=20,Maximum=150,Default=State.ChinaHat.HatParts.Value,Precision=0,Callback=function(v) State.ChinaHat.HatParts.Value=v;if State.ChinaHat.HatActive.Value then createHat() end;notify("ChinaHat","Parts: "..v,false) end},"HatParts")
    chS:Divider()
    uiElements.HatGradientSpeed = chS:Slider({Name="Gradient Speed",Minimum=1,Maximum=10,Default=State.ChinaHat.HatGradientSpeed.Default,Precision=1,Callback=function(v) State.ChinaHat.HatGradientSpeed.Value=v;notify("ChinaHat","Gradient Speed: "..v,false) end},"HatGradientSpeed")
    uiElements.HatGradient      = chS:Toggle({Name="Gradient",Default=State.ChinaHat.HatGradient.Default,Callback=function(v) State.ChinaHat.HatGradient.Value=v;if State.ChinaHat.HatActive.Value then createHat() end;notify("ChinaHat","Gradient: "..(v and"On"or"Off"),true) end},"HatGradient")
    uiElements.HatColor         = chS:Colorpicker({Name="Color",Default=State.ChinaHat.HatColor.Default,Callback=function(v) State.ChinaHat.HatColor.Value=v;if State.ChinaHat.HatActive.Value and not State.ChinaHat.HatGradient.Value then createHat() end;notify("ChinaHat","Color updated",false) end},"HatColor")
    chS:Divider()
    uiElements.HatYOffset       = chS:Slider({Name="Y Offset",Minimum=-5,Maximum=5,Default=State.ChinaHat.HatYOffset.Default,Precision=2,Callback=function(v) State.ChinaHat.HatYOffset.Value=v;notify("ChinaHat","Y Offset: "..v,false) end},"HatYOffset")
    uiElements.OutlineCircle    = chS:Toggle({Name="Outline Circle",Default=State.ChinaHat.OutlineCircle.Default,Callback=function(v) State.ChinaHat.OutlineCircle.Value=v;if State.ChinaHat.HatActive.Value then createHat() end;notify("ChinaHat","Outline: "..(v and"On"or"Off"),true) end},"OutlineCircle")

    local cS = UI.Sections.Circle or UI.Tabs.Visuals:Section({Name="Circle",Side="Left"})
    UI.Sections.Circle = cS
    cS:Header({Name="Circle"}); cS:SubLabel({Text="Displays a circle at the player feet"})
    uiElements.CircleEnabled      = cS:Toggle({Name="Enabled",Default=State.Circle.CircleActive.Default,Callback=function(v) toggleCircle(v) end},"CircleEnabled")
    cS:Divider()
    uiElements.CircleRadius       = cS:Slider({Name="Radius",Minimum=1.0,Maximum=3.0,Default=State.Circle.CircleRadius.Default,Precision=1,Callback=function(v) State.Circle.CircleRadius.Value=v;if State.Circle.CircleActive.Value then createCircle() end;notify("Circle","Radius: "..v,false) end},"CircleRadius")
    uiElements.CircleParts        = cS:Slider({Name="Parts",Minimum=20,Maximum=100,Default=State.Circle.CircleParts.Default,Precision=0,Callback=function(v) State.Circle.CircleParts.Value=v;if State.Circle.CircleActive.Value then createCircle() end;notify("Circle","Parts: "..v,false) end},"CircleParts")
    cS:Divider()
    uiElements.CircleGradientSpeed= cS:Slider({Name="Gradient Speed",Minimum=1,Maximum=10,Default=State.Circle.CircleGradientSpeed.Default,Precision=1,Callback=function(v) State.Circle.CircleGradientSpeed.Value=v;notify("Circle","Gradient Speed: "..v,false) end},"CircleGradientSpeed")
    uiElements.CircleGradient     = cS:Toggle({Name="Gradient",Default=State.Circle.CircleGradient.Default,Callback=function(v) State.Circle.CircleGradient.Value=v;if State.Circle.CircleActive.Value then createCircle() end;notify("Circle","Gradient: "..(v and"On"or"Off"),true) end},"CircleGradient")
    uiElements.CircleColor        = cS:Colorpicker({Name="Color",Default=State.Circle.CircleColor.Default,Callback=function(v) State.Circle.CircleColor.Value=v;if State.Circle.CircleActive.Value and not State.Circle.CircleGradient.Value then createCircle() end;notify("Circle","Color updated",false) end},"CircleColor")
    cS:Divider()
    uiElements.JumpAnimate        = cS:Toggle({Name="Jump Animate",Default=State.Circle.JumpAnimate.Default,Callback=function(v) State.Circle.JumpAnimate.Value=v;notify("Circle","Jump Animate: "..(v and"On"or"Off"),true) end},"JumpAnimate")
    uiElements.CircleYOffset      = cS:Slider({Name="Y Offset",Minimum=-5,Maximum=0,Default=State.Circle.CircleYOffset.Default,Precision=1,Callback=function(v) State.Circle.CircleYOffset.Value=v;notify("Circle","Y Offset: "..v,false) end},"CircleYOffset")

    local nS = UI.Sections.Nimb or UI.Tabs.Visuals:Section({Name="Nimb",Side="Right"})
    UI.Sections.Nimb = nS
    nS:Header({Name="Nimb"}); nS:SubLabel({Text="Displays a circle above the player head"})
    uiElements.NimbEnabled       = nS:Toggle({Name="Nimb Enabled",Default=State.Nimb.NimbActive.Default,Callback=function(v) toggleNimb(v) end},"NimbEnabled")
    nS:Divider()
    uiElements.NimbRadius        = nS:Slider({Name="Radius",Minimum=1.0,Maximum=3.0,Default=State.Nimb.NimbRadius.Default,Precision=1,Callback=function(v) State.Nimb.NimbRadius.Value=v;if State.Nimb.NimbActive.Value then createNimb() end;notify("Nimb","Radius: "..v,false) end},"NimbRadius")
    uiElements.NimbParts         = nS:Slider({Name="Parts",Minimum=20,Maximum=100,Default=State.Nimb.NimbParts.Default,Precision=0,Callback=function(v) State.Nimb.NimbParts.Value=v;if State.Nimb.NimbActive.Value then createNimb() end;notify("Nimb","Parts: "..v,false) end},"NimbParts")
    nS:Divider()
    uiElements.NimbGradientSpeed = nS:Slider({Name="Gradient Speed",Minimum=1,Maximum=10,Default=State.Nimb.NimbGradientSpeed.Default,Precision=1,Callback=function(v) State.Nimb.NimbGradientSpeed.Value=v;notify("Nimb","Gradient Speed: "..v,false) end},"NimbGradientSpeed")
    uiElements.NimbGradient      = nS:Toggle({Name="Gradient",Default=State.Nimb.NimbGradient.Default,Callback=function(v) State.Nimb.NimbGradient.Value=v;if State.Nimb.NimbActive.Value then createNimb() end;notify("Nimb","Gradient: "..(v and"On"or"Off"),true) end},"NimbGradient")
    uiElements.NimbColor         = nS:Colorpicker({Name="Color",Default=State.Nimb.NimbColor.Default,Callback=function(v) State.Nimb.NimbColor.Value=v;if State.Nimb.NimbActive.Value and not State.Nimb.NimbGradient.Value then createNimb() end;notify("Nimb","Color updated",false) end},"NimbColor")
    nS:Divider()
    uiElements.NimbYOffset       = nS:Slider({Name="Y Offset",Minimum=0,Maximum=5,Default=State.Nimb.NimbYOffset.Default,Precision=1,Callback=function(v) State.Nimb.NimbYOffset.Value=v;notify("Nimb","Y Offset: "..v,false) end},"NimbYOffset")
end

local syncTimer = 0
RunService.Heartbeat:Connect(function(dt)
    syncTimer=syncTimer+dt; if syncTimer>=0.5 then syncTimer=0; SynchronizeConfigValues() end
end)

function ChinaHat:Destroy()
    destroyParts(hatLines);destroyParts(hatCircleQuads);destroyParts(circleQuads);destroyParts(nimbQuads)
    if renderConnection then renderConnection:Disconnect() end
    if humanoidConnection then humanoidConnection:Disconnect() end
end

return ChinaHat
end

return ChinaHat
