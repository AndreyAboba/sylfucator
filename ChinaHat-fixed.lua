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

-- ── isShiftLockEnabled и updateShiftLockState ПОЛНОСТЬЮ УДАЛЕНЫ ───────────────
-- Причина: круг рисуется в 3D-мировых координатах и проецируется через
-- WorldToViewportPoint. Эта функция сама учитывает положение/угол камеры.
-- ShiftLock меняет только камеру, но НЕ мировые координаты персонажа, поэтому
-- ShiftLock не влияет на то, куда WorldToViewportPoint проецирует 3D-точку.
--
-- Старый код добавлял коррекцию "- hipHeight * 0.5" при ShiftLock ON.
-- Это не исправляло баг — оно БЫЛО багом:
--   • Первый запуск: детекция ShiftLock сломана → коррекция НЕ применялась → позиция A
--   • После ресета: детекция случайно начинала работать → коррекция применялась → позиция B
-- Пользователь видел "правильное" B после ресета и "неправильное" A при первом запуске.
-- Убираем ВСЮ ShiftLock-логику → формула одна для всех режимов → поведение одинаковое.
-- ─────────────────────────────────────────────────────────────────────────────

local function destroyParts(parts)
for _, part in ipairs(parts) do
if part and part.Destroy then part:Destroy() end
end
table.clear(parts)
end

local function interpolateColor(color1, color2, factor)
return Color3.new(
color1.R + (color2.R - color1.R) * factor,
color1.G + (color2.G - color1.G) * factor,
color1.B + (color2.B - color1.B) * factor
)
end

local function createHat()
if not localCharacter or not localCharacter:FindFirstChild("Head") then return end
destroyParts(hatLines)
destroyParts(hatCircleQuads)
for i = 1, State.ChinaHat.HatParts.Value do
local line = Drawing.new("Line")
line.Visible = false
line.Thickness = 0.06
line.Transparency = 0.5
line.Color = State.ChinaHat.HatGradient.Value and
interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, i / State.ChinaHat.HatParts.Value) or
State.ChinaHat.HatColor.Value
table.insert(hatLines, line)
end
if State.ChinaHat.OutlineCircle.Value then
for i = 1, State.ChinaHat.HatParts.Value do
local quad = Drawing.new("Quad")
quad.Visible = false
quad.Thickness = 1
quad.Filled = false
quad.Color = State.ChinaHat.HatGradient.Value and
interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, i / State.ChinaHat.HatParts.Value) or
State.ChinaHat.HatColor.Value
table.insert(hatCircleQuads, quad)
end
end
end

local function createCircle()
if not localCharacter or not localCharacter:FindFirstChild("HumanoidRootPart") then return end
destroyParts(circleQuads)
for i = 1, State.Circle.CircleParts.Value do
local quad = Drawing.new("Quad")
quad.Visible = false
quad.Thickness = 1
quad.Filled = false
quad.Color = State.Circle.CircleGradient.Value and
interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, i / State.Circle.CircleParts.Value) or
State.Circle.CircleColor.Value
table.insert(circleQuads, quad)
end
end

local function createNimb()
if not localCharacter or not localCharacter:FindFirstChild("HumanoidRootPart") then return end
destroyParts(nimbQuads)
for i = 1, State.Nimb.NimbParts.Value do
local quad = Drawing.new("Quad")
quad.Visible = false
quad.Thickness = 1
quad.Filled = false
quad.Color = State.Nimb.NimbGradient.Value and
interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, i / State.Nimb.NimbParts.Value) or
State.Nimb.NimbColor.Value
table.insert(nimbQuads, quad)
end
end

local function updateHat()
if not State.ChinaHat.HatActive.Value or not localCharacter or not localCharacter:FindFirstChild("Head") then
for _, line in ipairs(hatLines) do line.Visible = false end
for _, quad in ipairs(hatCircleQuads) do quad.Visible = false end
return
end
local head = localCharacter.Head
local y = head.Position.Y + State.ChinaHat.HatYOffset.Value
local t = tick()
local hatHeight = 2.15 * State.ChinaHat.HatScale.Value
local hatRadius = 1.95 * State.ChinaHat.HatScale.Value
for i, line in ipairs(hatLines) do
local angle = (i / State.ChinaHat.HatParts.Value) * 2 * math.pi
local x = math.cos(angle) * hatRadius
local z = math.sin(angle) * hatRadius
local basePosition = Vector3.new(head.Position.X, y, head.Position.Z)
local topPosition = Vector3.new(head.Position.X + x, y - hatHeight / 3, head.Position.Z + z)
local direction = (topPosition - basePosition).Unit
local endPoint = topPosition + direction * 0.03
local screenStart, onScreenStart = camera:WorldToViewportPoint(basePosition)
local screenEnd, onScreenEnd = camera:WorldToViewportPoint(endPoint)
if onScreenStart and onScreenEnd and screenStart.Z > 0 and screenEnd.Z > 0 then
line.From = Vector2.new(screenStart.X, screenStart.Y)
line.To = Vector2.new(screenEnd.X, screenEnd.Y)
line.Visible = true
if State.ChinaHat.HatGradient.Value then
local factor = (math.sin(t * State.ChinaHat.HatGradientSpeed.Value + (i / State.ChinaHat.HatParts.Value) * 2 * math.pi) + 1) / 2
line.Color = interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, factor)
else
line.Color = State.ChinaHat.HatColor.Value
end
else
line.Visible = false
end
end
if State.ChinaHat.OutlineCircle.Value and #hatCircleQuads > 0 then
local topCenter = Vector3.new(0, 0, 0)
local visibleEnds = 0
for i, line in ipairs(hatLines) do
if line.Visible then
local angle = (i / State.ChinaHat.HatParts.Value) * 2 * math.pi
local x2 = math.cos(angle) * hatRadius
local z2 = math.sin(angle) * hatRadius
topCenter = topCenter + Vector3.new(head.Position.X + x2, y - hatHeight / 3, head.Position.Z + z2)
visibleEnds = visibleEnds + 1
end
end
topCenter = visibleEnds > 0 and (topCenter / visibleEnds) or Vector3.new(head.Position.X, y - hatHeight / 3, head.Position.Z)
local screenCenter, onScreenCenter = camera:WorldToViewportPoint(topCenter)
if onScreenCenter and screenCenter.Z > 0 then
local circleRadius = 2.0 * State.ChinaHat.HatScale.Value
for i, quad in ipairs(hatCircleQuads) do
local angle1 = ((i - 1) / #hatCircleQuads) * 2 * math.pi
local angle2 = (i / #hatCircleQuads) * 2 * math.pi
local point1 = topCenter + Vector3.new(math.cos(angle1) * circleRadius, 0, math.sin(angle1) * circleRadius)
local point2 = topCenter + Vector3.new(math.cos(angle2) * circleRadius, 0, math.sin(angle2) * circleRadius)
local sp1, os1 = camera:WorldToViewportPoint(point1)
local sp2, os2 = camera:WorldToViewportPoint(point2)
if os1 and os2 and sp1.Z > 0 and sp2.Z > 0 then
quad.PointA = Vector2.new(sp1.X, sp1.Y)
quad.PointB = Vector2.new(sp2.X, sp2.Y)
quad.PointC = Vector2.new(sp2.X, sp2.Y)
quad.PointD = Vector2.new(sp1.X, sp1.Y)
quad.Visible = true
if State.ChinaHat.HatGradient.Value then
local factor = (math.sin(t * State.ChinaHat.HatGradientSpeed.Value + (i / #hatCircleQuads) * 2 * math.pi) + 1) / 2
quad.Color = interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, factor)
else
quad.Color = State.ChinaHat.HatColor.Value
end
else
quad.Visible = false
end
end
else
for _, quad in ipairs(hatCircleQuads) do quad.Visible = false end
end
end
end

local function updateCircle()
if not State.Circle.CircleActive.Value or not localCharacter or not localCharacter:FindFirstChild("HumanoidRootPart") then
for _, quad in ipairs(circleQuads) do quad.Visible = false end
return
end
local rootPart = localCharacter.HumanoidRootPart

-- ── Единственная формула без ветки ShiftLock ─────────────────────────────
-- WorldToViewportPoint сам учитывает позицию/угол камеры.
-- ShiftLock не меняет мировые координаты персонажа — мировая позиция
-- кольца одна и та же в обоих режимах, поэтому проекция всегда верна.
local circleHeight = rootPart.Position.Y + State.Circle.CircleYOffset.Value
-- ─────────────────────────────────────────────────────────────────────────

local t = tick()
local center = Vector3.new(rootPart.Position.X, circleHeight, rootPart.Position.Z)
local screenCenter, onScreenCenter = camera:WorldToViewportPoint(center)
if not (onScreenCenter and screenCenter.Z > 0) then
for _, quad in ipairs(circleQuads) do quad.Visible = false end
return
end
local circleRadius = State.Circle.CircleRadius.Value
local partsCount = #circleQuads
for i, quad in ipairs(circleQuads) do
local angle1 = ((i - 1) / partsCount) * 2 * math.pi
local angle2 = (i / partsCount) * 2 * math.pi
local point1 = center + Vector3.new(math.cos(angle1) * circleRadius, 0, math.sin(angle1) * circleRadius)
local point2 = center + Vector3.new(math.cos(angle2) * circleRadius, 0, math.sin(angle2) * circleRadius)
local sp1, os1 = camera:WorldToViewportPoint(point1)
local sp2, os2 = camera:WorldToViewportPoint(point2)
if os1 and os2 and sp1.Z > 0 and sp2.Z > 0 then
quad.PointA = Vector2.new(sp1.X, sp1.Y)
quad.PointB = Vector2.new(sp2.X, sp2.Y)
quad.PointC = Vector2.new(sp2.X, sp2.Y)
quad.PointD = Vector2.new(sp1.X, sp1.Y)
quad.Visible = true
if State.Circle.CircleGradient.Value then
local factor = (math.sin(t * State.Circle.CircleGradientSpeed.Value + (i / partsCount) * 2 * math.pi) + 1) / 2
quad.Color = interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, factor)
else
quad.Color = State.Circle.CircleColor.Value
end
else
quad.Visible = false
end
end
end

local function updateNimb()
if not State.Nimb.NimbActive.Value or not localCharacter then
for _, quad in ipairs(nimbQuads) do quad.Visible = false end
return
end
local head = localCharacter:FindFirstChild("Head")
if not head then
for _, quad in ipairs(nimbQuads) do quad.Visible = false end
return
end
local nimbHeight = head.Position.Y + State.Nimb.NimbYOffset.Value
local t = tick()
local center = Vector3.new(head.Position.X, nimbHeight, head.Position.Z)
local screenCenter, onScreenCenter = camera:WorldToViewportPoint(center)
if not (onScreenCenter and screenCenter.Z > 0) then
for _, quad in ipairs(nimbQuads) do quad.Visible = false end
return
end
local nimbRadius = State.Nimb.NimbRadius.Value
local partsCount = #nimbQuads
for i, quad in ipairs(nimbQuads) do
local angle1 = ((i - 1) / partsCount) * 2 * math.pi
local angle2 = (i / partsCount) * 2 * math.pi
local point1 = center + Vector3.new(math.cos(angle1) * nimbRadius, 0, math.sin(angle1) * nimbRadius)
local point2 = center + Vector3.new(math.cos(angle2) * nimbRadius, 0, math.sin(angle2) * nimbRadius)
local sp1, os1 = camera:WorldToViewportPoint(point1)
local sp2, os2 = camera:WorldToViewportPoint(point2)
if os1 and os2 and sp1.Z > 0 and sp2.Z > 0 then
quad.PointA = Vector2.new(sp1.X, sp1.Y)
quad.PointB = Vector2.new(sp2.X, sp2.Y)
quad.PointC = Vector2.new(sp2.X, sp2.Y)
quad.PointD = Vector2.new(sp1.X, sp1.Y)
quad.Visible = true
if State.Nimb.NimbGradient.Value then
local factor = (math.sin(t * State.Nimb.NimbGradientSpeed.Value + (i / partsCount) * 2 * math.pi) + 1) / 2
quad.Color = interpolateColor(Core.GradientColors.Color1.Value, Core.GradientColors.Color2.Value, factor)
else
quad.Color = State.Nimb.NimbColor.Value
end
else
quad.Visible = false
end
end
end

local function animateJump()
if not State.Circle.JumpAnimate.Value or #circleQuads == 0 or jumpAnimationActive then return end
jumpAnimationActive = true
local t = 0
local duration = 0.55
local initialRadius = State.Circle.CircleRadius.Value
local maxRadius = initialRadius * 1.6
while t < duration do
local dt = RunService.RenderStepped:Wait()
t = t + dt
State.Circle.CircleRadius.Value = initialRadius + (maxRadius - initialRadius) * math.sin((t / duration) * math.pi)
updateCircle()
end
State.Circle.CircleRadius.Value = initialRadius
jumpAnimationActive = false
end

local function toggleHat(value)
State.ChinaHat.HatActive.Value = value
if value then createHat(); notify("ChinaHat", "Hat Enabled", true)
else destroyParts(hatLines); destroyParts(hatCircleQuads); notify("ChinaHat", "Hat Disabled", true) end
end

local function toggleCircle(value)
State.Circle.CircleActive.Value = value
if value then createCircle(); notify("Circle", "Circle Enabled", true)
else destroyParts(circleQuads); notify("Circle", "Circle Disabled", true) end
end

local function toggleNimb(value)
State.Nimb.NimbActive.Value = value
if value then createNimb(); notify("Nimb", "Nimb Enabled", true)
else destroyParts(nimbQuads); notify("Nimb", "Nimb Disabled", true) end
end

local function onStateChanged(oldState, newState)
if State.Circle.JumpAnimate.Value and newState == Enum.HumanoidStateType.Jumping and not jumpAnimationActive then
animateJump()
end
end

local function connectHumanoid(character)
if humanoidConnection then humanoidConnection:Disconnect() end
localCharacter = character
camera = Workspace.CurrentCamera
local humanoid = character:WaitForChild("Humanoid", 5)
if humanoid then
localHumanoid = humanoid
humanoidConnection = humanoid.StateChanged:Connect(onStateChanged)
end
if State.ChinaHat.HatActive.Value then createHat() end
if State.Circle.CircleActive.Value then createCircle() end
if State.Nimb.NimbActive.Value then createNimb() end
end

local function SynchronizeConfigValues()
if not uiElements then return end
if uiElements.HatScale and uiElements.HatScale.GetValue then
local v = uiElements.HatScale:GetValue()
if v ~= State.ChinaHat.HatScale.Value then State.ChinaHat.HatScale.Value = v; if State.ChinaHat.HatActive.Value then createHat() end end
end
if uiElements.HatParts and uiElements.HatParts.GetValue then
local v = uiElements.HatParts:GetValue()
if v ~= State.ChinaHat.HatParts.Value then State.ChinaHat.HatParts.Value = v; if State.ChinaHat.HatActive.Value then createHat() end end
end
if uiElements.HatGradientSpeed and uiElements.HatGradientSpeed.GetValue then State.ChinaHat.HatGradientSpeed.Value = uiElements.HatGradientSpeed:GetValue() end
if uiElements.HatYOffset and uiElements.HatYOffset.GetValue then State.ChinaHat.HatYOffset.Value = uiElements.HatYOffset:GetValue() end
if uiElements.CircleRadius and uiElements.CircleRadius.GetValue then
local v = uiElements.CircleRadius:GetValue()
if v ~= State.Circle.CircleRadius.Value then State.Circle.CircleRadius.Value = v; if State.Circle.CircleActive.Value then createCircle() end end
end
if uiElements.CircleParts and uiElements.CircleParts.GetValue then
local v = uiElements.CircleParts:GetValue()
if v ~= State.Circle.CircleParts.Value then State.Circle.CircleParts.Value = v; if State.Circle.CircleActive.Value then createCircle() end end
end
if uiElements.CircleGradientSpeed and uiElements.CircleGradientSpeed.GetValue then State.Circle.CircleGradientSpeed.Value = uiElements.CircleGradientSpeed:GetValue() end
if uiElements.CircleYOffset and uiElements.CircleYOffset.GetValue then State.Circle.CircleYOffset.Value = uiElements.CircleYOffset:GetValue() end
if uiElements.NimbRadius and uiElements.NimbRadius.GetValue then
local v = uiElements.NimbRadius:GetValue()
if v ~= State.Nimb.NimbRadius.Value then State.Nimb.NimbRadius.Value = v; if State.Nimb.NimbActive.Value then createNimb() end end
end
if uiElements.NimbParts and uiElements.NimbParts.GetValue then
local v = uiElements.NimbParts:GetValue()
if v ~= State.Nimb.NimbParts.Value then State.Nimb.NimbParts.Value = v; if State.Nimb.NimbActive.Value then createNimb() end end
end
if uiElements.NimbGradientSpeed and uiElements.NimbGradientSpeed.GetValue then State.Nimb.NimbGradientSpeed.Value = uiElements.NimbGradientSpeed:GetValue() end
if uiElements.NimbYOffset and uiElements.NimbYOffset.GetValue then State.Nimb.NimbYOffset.Value = uiElements.NimbYOffset:GetValue() end
end

renderConnection = RunService.RenderStepped:Connect(function()
if localCharacter then
updateHat(); updateCircle(); updateNimb()
else
for _, l in ipairs(hatLines) do l.Visible = false end
for _, q in ipairs(hatCircleQuads) do q.Visible = false end
for _, q in ipairs(circleQuads) do q.Visible = false end
for _, q in ipairs(nimbQuads) do q.Visible = false end
end
end)

-- ── CharacterAdded: task.spawn fallback для первого запуска ──────────────────
LocalPlayer.CharacterAdded:Connect(connectHumanoid)
if localCharacter then
connectHumanoid(localCharacter)
else
task.spawn(function()
connectHumanoid(LocalPlayer.CharacterAdded:Wait())
end)
end
-- ─────────────────────────────────────────────────────────────────────────────

if UI.Tabs and UI.Tabs.Visuals then
local chinaHatSection = UI.Sections.ChinaHat or UI.Tabs.Visuals:Section({ Name = "ChinaHat", Side = "Left" })
UI.Sections.ChinaHat = chinaHatSection
chinaHatSection:Header({ Name = "China Hat" })
chinaHatSection:SubLabel({ Text = "Displays a hat above the player head" })
uiElements.HatEnabled = chinaHatSection:Toggle({ Name = "Enabled", Default = State.ChinaHat.HatActive.Default, Callback = function(v) toggleHat(v) end }, "HatEnabled")
chinaHatSection:Divider()
uiElements.HatScale = chinaHatSection:Slider({ Name = "Scale", Minimum = 0.5, Maximum = 2.0, Default = State.ChinaHat.HatScale.Default, Precision = 2, Callback = function(v) State.ChinaHat.HatScale.Value = v; if State.ChinaHat.HatActive.Value then createHat() end; notify("ChinaHat", "Scale: "..v, false) end }, "HatScale")
uiElements.HatParts = chinaHatSection:Slider({ Name = "Parts", Minimum = 20, Maximum = 150, Default = State.ChinaHat.HatParts.Value, Precision = 0, Callback = function(v) State.ChinaHat.HatParts.Value = v; if State.ChinaHat.HatActive.Value then createHat() end; notify("ChinaHat", "Parts: "..v, false) end }, "HatParts")
chinaHatSection:Divider()
uiElements.HatGradientSpeed = chinaHatSection:Slider({ Name = "Gradient Speed", Minimum = 1, Maximum = 10, Default = State.ChinaHat.HatGradientSpeed.Default, Precision = 1, Callback = function(v) State.ChinaHat.HatGradientSpeed.Value = v; notify("ChinaHat", "Gradient Speed: "..v, false) end }, "HatGradientSpeed")
uiElements.HatGradient = chinaHatSection:Toggle({ Name = "Gradient", Default = State.ChinaHat.HatGradient.Default, Callback = function(v) State.ChinaHat.HatGradient.Value = v; if State.ChinaHat.HatActive.Value then createHat() end; notify("ChinaHat", "Gradient: "..(v and "On" or "Off"), true) end }, "HatGradient")
uiElements.HatColor = chinaHatSection:Colorpicker({ Name = "Color", Default = State.ChinaHat.HatColor.Default, Callback = function(v) State.ChinaHat.HatColor.Value = v; if State.ChinaHat.HatActive.Value and not State.ChinaHat.HatGradient.Value then createHat() end; notify("ChinaHat", "Color updated", false) end }, "HatColor")
chinaHatSection:Divider()
uiElements.HatYOffset = chinaHatSection:Slider({ Name = "Y Offset", Minimum = -5, Maximum = 5, Default = State.ChinaHat.HatYOffset.Default, Precision = 2, Callback = function(v) State.ChinaHat.HatYOffset.Value = v; notify("ChinaHat", "Y Offset: "..v, false) end }, "HatYOffset")
uiElements.OutlineCircle = chinaHatSection:Toggle({ Name = "Outline Circle", Default = State.ChinaHat.OutlineCircle.Default, Callback = function(v) State.ChinaHat.OutlineCircle.Value = v; if State.ChinaHat.HatActive.Value then createHat() end; notify("ChinaHat", "Outline: "..(v and "On" or "Off"), true) end }, "OutlineCircle")

local circleSection = UI.Sections.Circle or UI.Tabs.Visuals:Section({ Name = "Circle", Side = "Left" })
UI.Sections.Circle = circleSection
circleSection:Header({ Name = "Circle" })
circleSection:SubLabel({ Text = "Displays a circle at the player feet" })
uiElements.CircleEnabled = circleSection:Toggle({ Name = "Enabled", Default = State.Circle.CircleActive.Default, Callback = function(v) toggleCircle(v) end }, "CircleEnabled")
circleSection:Divider()
uiElements.CircleRadius = circleSection:Slider({ Name = "Radius", Minimum = 1.0, Maximum = 3.0, Default = State.Circle.CircleRadius.Default, Precision = 1, Callback = function(v) State.Circle.CircleRadius.Value = v; if State.Circle.CircleActive.Value then createCircle() end; notify("Circle", "Radius: "..v, false) end }, "CircleRadius")
uiElements.CircleParts = circleSection:Slider({ Name = "Parts", Minimum = 20, Maximum = 100, Default = State.Circle.CircleParts.Default, Precision = 0, Callback = function(v) State.Circle.CircleParts.Value = v; if State.Circle.CircleActive.Value then createCircle() end; notify("Circle", "Parts: "..v, false) end }, "CircleParts")
circleSection:Divider()
uiElements.CircleGradientSpeed = circleSection:Slider({ Name = "Gradient Speed", Minimum = 1, Maximum = 10, Default = State.Circle.CircleGradientSpeed.Default, Precision = 1, Callback = function(v) State.Circle.CircleGradientSpeed.Value = v; notify("Circle", "Gradient Speed: "..v, false) end }, "CircleGradientSpeed")
uiElements.CircleGradient = circleSection:Toggle({ Name = "Gradient", Default = State.Circle.CircleGradient.Default, Callback = function(v) State.Circle.CircleGradient.Value = v; if State.Circle.CircleActive.Value then createCircle() end; notify("Circle", "Gradient: "..(v and "On" or "Off"), true) end }, "CircleGradient")
uiElements.CircleColor = circleSection:Colorpicker({ Name = "Color", Default = State.Circle.CircleColor.Default, Callback = function(v) State.Circle.CircleColor.Value = v; if State.Circle.CircleActive.Value and not State.Circle.CircleGradient.Value then createCircle() end; notify("Circle", "Color updated", false) end }, "CircleColor")
circleSection:Divider()
uiElements.JumpAnimate = circleSection:Toggle({ Name = "Jump Animate", Default = State.Circle.JumpAnimate.Default, Callback = function(v) State.Circle.JumpAnimate.Value = v; notify("Circle", "Jump Animate: "..(v and "On" or "Off"), true) end }, "JumpAnimate")
uiElements.CircleYOffset = circleSection:Slider({ Name = "Y Offset", Minimum = -5, Maximum = 0, Default = State.Circle.CircleYOffset.Default, Precision = 1, Callback = function(v) State.Circle.CircleYOffset.Value = v; notify("Circle", "Y Offset: "..v, false) end }, "CircleYOffset")

local nimbSection = UI.Sections.Nimb or UI.Tabs.Visuals:Section({ Name = "Nimb", Side = "Right" })
UI.Sections.Nimb = nimbSection
nimbSection:Header({ Name = "Nimb" })
nimbSection:SubLabel({ Text = "Displays a circle above the player head" })
uiElements.NimbEnabled = nimbSection:Toggle({ Name = "Nimb Enabled", Default = State.Nimb.NimbActive.Default, Callback = function(v) toggleNimb(v) end }, "NimbEnabled")
nimbSection:Divider()
uiElements.NimbRadius = nimbSection:Slider({ Name = "Radius", Minimum = 1.0, Maximum = 3.0, Default = State.Nimb.NimbRadius.Default, Precision = 1, Callback = function(v) State.Nimb.NimbRadius.Value = v; if State.Nimb.NimbActive.Value then createNimb() end; notify("Nimb", "Radius: "..v, false) end }, "NimbRadius")
uiElements.NimbParts = nimbSection:Slider({ Name = "Parts", Minimum = 20, Maximum = 100, Default = State.Nimb.NimbParts.Default, Precision = 0, Callback = function(v) State.Nimb.NimbParts.Value = v; if State.Nimb.NimbActive.Value then createNimb() end; notify("Nimb", "Parts: "..v, false) end }, "NimbParts")
nimbSection:Divider()
uiElements.NimbGradientSpeed = nimbSection:Slider({ Name = "Gradient Speed", Minimum = 1, Maximum = 10, Default = State.Nimb.NimbGradientSpeed.Default, Precision = 1, Callback = function(v) State.Nimb.NimbGradientSpeed.Value = v; notify("Nimb", "Gradient Speed: "..v, false) end }, "NimbGradientSpeed")
uiElements.NimbGradient = nimbSection:Toggle({ Name = "Gradient", Default = State.Nimb.NimbGradient.Default, Callback = function(v) State.Nimb.NimbGradient.Value = v; if State.Nimb.NimbActive.Value then createNimb() end; notify("Nimb", "Gradient: "..(v and "On" or "Off"), true) end }, "NimbGradient")
uiElements.NimbColor = nimbSection:Colorpicker({ Name = "Color", Default = State.Nimb.NimbColor.Default, Callback = function(v) State.Nimb.NimbColor.Value = v; if State.Nimb.NimbActive.Value and not State.Nimb.NimbGradient.Value then createNimb() end; notify("Nimb", "Color updated", false) end }, "NimbColor")
nimbSection:Divider()
uiElements.NimbYOffset = nimbSection:Slider({ Name = "Y Offset", Minimum = 0, Maximum = 5, Default = State.Nimb.NimbYOffset.Default, Precision = 1, Callback = function(v) State.Nimb.NimbYOffset.Value = v; notify("Nimb", "Y Offset: "..v, false) end }, "NimbYOffset")
end

local syncTimer = 0
RunService.Heartbeat:Connect(function(dt)
syncTimer = syncTimer + dt
if syncTimer >= 0.5 then syncTimer = 0; SynchronizeConfigValues() end
end)

function ChinaHat:Destroy()
destroyParts(hatLines); destroyParts(hatCircleQuads)
destroyParts(circleQuads); destroyParts(nimbQuads)
if renderConnection then renderConnection:Disconnect() end
if humanoidConnection then humanoidConnection:Disconnect() end
end

return ChinaHat
end

return ChinaHat
