local playerGUID
local wfTotal = 0
local debugOn = false

-- Jump counter (session)
local jumpCount
local jumpHooked = false


-- Proc accumulator + debounce
local wfCurrentDamage = 0
local wfSeq = 0

-- IDs only used to fetch localized names
local WF_NAME_IDS = {
  8232, 8235, 10486, 16362, 25505,
  25504,
}
local WF_NAMES = {}

local function BuildWindfuryNameSet()
  for _, id in ipairs(WF_NAME_IDS) do
    local name = GetSpellInfo(id)
    if name then WF_NAMES[name] = true end
  end
end

local function fmt(n)
  n = math.floor((n or 0) + 0.5)
  local s = tostring(n)
  local sign, int = s:match("^([%-]?)(%d+)$")
  local out = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (sign or "") .. out
end

local function dprint(...)
  if debugOn then
    print("|cff00ff88WFT debug|r", ...)
  end
end

local function IsWindfurySpell(spellId, spellName)
  if spellName and WF_NAMES[spellName] then return true end
  if spellName and spellName:lower():find("windfury") then return true end
  if spellId == 25504 then return true end
  return false
end

local function PlayToggleSound()
  if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
  elseif PlaySound then
    -- fallback for older APIs
    PlaySound("igMainMenuOptionCheckBoxOn")
  end
end

-- -------------------------
-- UI: main frame
-- -------------------------
local frame = CreateFrame("Frame", "WFT_Frame", UIParent, "BackdropTemplate")
frame:SetSize(220, 70)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
frame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background" })
frame:SetBackdropColor(0, 0, 0, 0.45)
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

-- Classic header banner (hidden in modern theme)
frame.header = frame:CreateTexture(nil, "ARTWORK")
frame.header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
frame.header:SetSize(256, 64)
frame.header:SetPoint("TOP", frame, "TOP", 0, 12)
frame.header:Hide()

-- Close button (classic vibes)
frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
frame.close:SetPoint("TOPRIGHT", -4, -4)
frame.close:SetScript("OnClick", function()
  frame:Hide()
  PlayToggleSound()
end)
frame.close:Hide() -- show in classic theme

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.title:SetText("Windfury Log")

frame.best = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.best:SetText("Best: -")

frame.jumps = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.jumps:SetText("Jumps: 0")


frame.lines = {}
for i = 1, 3 do
  local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetText(i .. ") -")
  frame.lines[i] = fs
end

-- Theme toggle button
frame.themeBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
frame.themeBtn:SetSize(80, 18)
frame.themeBtn:SetText("Classic")

-- -------------------------
-- Totem icons bar (below the window)
-- -------------------------
local TOTEM_SIZE = 40
local TOTEM_GAP  = 4
local TOTEM_YOFF = -6  -- space below the window

local TOTEM_BORDER_COLORS = {
  [1] = {1.00, 0.25, 0.10}, -- Fire
  [2] = {0.55, 0.35, 0.15}, -- Earth
  [3] = {0.10, 0.55, 1.00}, -- Water
  [4] = {0.85, 0.85, 0.90}, -- Air
}

frame.totemBar = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
frame.totemBar:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, TOTEM_YOFF)
frame.totemBar:SetSize((TOTEM_SIZE + TOTEM_GAP) * 4 - TOTEM_GAP, TOTEM_SIZE)

-- optional: keep it "outside" the window, no background
-- frame.totemBar:SetBackdrop(nil)

frame.totemIcons = {}

for slot = 1, 4 do
  local b = CreateFrame("Frame", nil, frame.totemBar, "BackdropTemplate")
  b:SetSize(TOTEM_SIZE, TOTEM_SIZE)
  b:SetPoint("LEFT", (slot - 1) * (TOTEM_SIZE + TOTEM_GAP), 0)

  -- a thin border so icons look “button-ish”
  b:SetBackdrop({
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  local c = TOTEM_BORDER_COLORS[slot]
  b:SetBackdropBorderColor(c[1], c[2], c[3], 1)

  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("TOPLEFT", 2, -2)
  b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
  b.cd:SetAllPoints(b.icon)
  if b.cd.SetReverse then b.cd:SetReverse(true) end

  b:Hide()
  frame.totemIcons[slot] = b
end

local function UpdateTotemIcons()
  -- If you're not a shaman, hide the whole bar
  local _, class = UnitClass("player")
  if class ~= "SHAMAN" then
    frame.totemBar:Hide()
    return
  end
  frame.totemBar:Show()

  for slot = 1, 4 do
    local haveTotem, name, startTime, duration, icon = GetTotemInfo(slot)
    local b = frame.totemIcons[slot]

    if haveTotem and icon then
      b.icon:SetTexture(icon)

      if startTime and duration and duration > 0 then
        b.cd:SetCooldown(startTime, duration)
      else
        b.cd:Clear()
      end

      b:Show()
    else
      b:Hide()
    end
  end
end


-- -------------------------
-- Theme
-- -------------------------
local function ApplyTheme(theme)
  theme = theme or "modern"
  WindfuryTotalDB.theme = theme

  -- Clear layout anchors
  frame:ClearAllPoints()
  frame.title:ClearAllPoints()
  frame.best:ClearAllPoints()
  frame.themeBtn:ClearAllPoints()
  frame.jumps:ClearAllPoints()
  for i = 1, 3 do
    frame.lines[i]:ClearAllPoints()
  end

  if theme == "classic" then
    -- 2005 vibes: parchment + dialog border + header + close button
    frame:SetSize(200, 115)
    frame:SetPoint("CENTER", UIParent, "CENTER", -350, 350)

    frame:SetBackdrop({
      bgFile   = "Interface\\FrameGeneral\\UI-Background-Marble",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 64, edgeSize = 32,
      insets = { left = 10, right = 10, top = 10, bottom = 10 },
    })
    frame:SetBackdropColor(1, 1, 1, 0.95)

    frame.header:Show()
    frame.close:Show()

    frame.title:SetPoint("TOP", frame, "TOP", 0, -0)
    frame.title:SetFontObject("GameFontNormalLarge")
    frame.title:SetTextColor(0.95, 0.82, 0.55) -- warm gold

    frame.best:SetPoint("CENTER", frame, "CENTER", -0, 20)
    frame.best:SetFontObject("GameFontHighlightLarge")
    frame.best:SetTextColor(1, 1, 0)

	frame.jumps:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 16)
    frame.jumps:SetFontObject("GameFontHighlightSmall")
    frame.jumps:SetTextColor(1, 1, 1)

    for i = 1, 3 do
      frame.lines[i]:SetPoint("CENTER", frame, "CENTER", 0, 19 - (i * 20))
      frame.lines[i]:SetFontObject("GameFontHighlight")
      frame.lines[i]:SetTextColor(1, 1, 1) -- dark on parchment
    end

    --frame.themeBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 16)
    --frame.themeBtn:SetWidth(90)

  else
    -- Modern: tooltip panel
    frame:SetSize(220, 80)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 220)

    frame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background" })
    frame:SetBackdropColor(0, 0, 0, 0.45)

    frame.header:Hide()
    frame.close:Hide()

    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -8)
    frame.title:SetFontObject("GameFontNormal")
    frame.title:SetTextColor(1, 1, 1)

    frame.best:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -8)
    frame.best:SetFontObject("GameFontNormalSmall")
    frame.best:SetTextColor(1, 1, 1)
	
	frame.jumps:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
    frame.jumps:SetFontObject("GameFontNormalSmall")
    frame.jumps:SetTextColor(1, 1, 1)


    for i = 1, 3 do
      frame.lines[i]:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -8 - (i * 16))
      frame.lines[i]:SetFontObject("GameFontHighlight")
      frame.lines[i]:SetTextColor(1, 1, 1)
    end

    frame.themeBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)
    frame.themeBtn:SetWidth(80)
  end

  frame.themeBtn:SetText(theme == "classic" and "Modern" or "Classic")
end

frame.themeBtn:SetScript("OnClick", function()
  WindfuryTotalDB.theme = WindfuryTotalDB.theme or "modern"
  local nextTheme = (WindfuryTotalDB.theme == "modern") and "classic" or "modern"
  ApplyTheme(nextTheme)
  PlayToggleSound()
end)

-- -------------------------
-- Text update
-- -------------------------
local function UpdateHistoryText()
  local hist = (WindfuryTotalDB and WindfuryTotalDB.history) or {}
  for line = 1, 3 do
    -- top shows oldest, bottom shows newest
    local idx = 4 - line
    local v = hist[idx]
    if v then
      frame.lines[line]:SetText(fmt(v))
    else
      frame.lines[line]:SetText("-")
    end
  end

  local best = (WindfuryTotalDB and WindfuryTotalDB.best) or 0
  frame.best:SetText("Top: " .. (best > 0 and fmt(best) or "-"))
end

local function PushHistory(total)
  if not total or total <= 0 then return end
  if not WindfuryTotalDB or not WindfuryTotalDB.history then return end

  table.insert(WindfuryTotalDB.history, 1, total)
  if #WindfuryTotalDB.history > 3 then
    table.remove(WindfuryTotalDB.history, 4)
  end
  UpdateHistoryText()
end

local function UpdateJumpText()
  if frame.jumps then
    frame.jumps:SetText("Jumps: " .. tostring(jumpCount))
  end
end


-- -------------------------
-- Popup above target
-- -------------------------
local function ShowWindfuryAboveTarget(total)
  if not total or total <= 0 then return end

  local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit("target")
  if not plate then
    UIErrorsFrame:AddMessage("WF " .. total, 1, 1, 0, 1)
    return
  end

  local f = CreateFrame("Frame", nil, plate)
  f:SetFrameStrata("HIGH")
  f:SetFrameLevel(1000)

  local fs = f:CreateFontString(nil, "OVERLAY")
  fs:SetFont("Fonts\\FRIZQT__.TTF", 80, "THICKOUTLINE")
  fs:SetText(tostring(total))
  fs:SetTextColor(1, 1, 0)
  fs:SetShadowOffset(2, -2)
  fs:SetShadowColor(0, 0, 0, 1)
  fs:SetPoint("CENTER", f, "CENTER")

  f:SetSize(fs:GetStringWidth() + 20, fs:GetStringHeight() + 10)
  f:SetPoint("TOP", plate, "TOP", 0, 28)
  f:SetAlpha(1)

  local ag = f:CreateAnimationGroup()

  local move = ag:CreateAnimation("Translation")
  move:SetOffset(0, 120)
  move:SetDuration(1.8)
  move:SetSmoothing("OUT")

  local fade = ag:CreateAnimation("Alpha")
  fade:SetFromAlpha(1)
  fade:SetToAlpha(1)
  fade:SetDuration(1.8)
  fade:SetSmoothing("OUT")

  ag:SetScript("OnFinished", function()
    f:Hide()
    f:SetParent(nil)
  end)

  ag:Play()
end

-- Commit the current WF proc after it "settles"
local function DebouncedCommit()
  wfSeq = wfSeq + 1
  local mySeq = wfSeq

  C_Timer.After(0.35, function()
    if mySeq ~= wfSeq then return end

    local total = math.floor(wfCurrentDamage + 0.5)
    if total > 0 then
      ShowWindfuryAboveTarget(total)

      -- Best only updates if higher
      WindfuryTotalDB.best = WindfuryTotalDB.best or 0
      if total > WindfuryTotalDB.best then
        WindfuryTotalDB.best = total
      end

      PushHistory(total)
    end

    wfCurrentDamage = 0
  end)
end

-- -------------------------
-- Slash commands
-- -------------------------
SLASH_WFTOTAL1 = "/wftotal"
SlashCmdList.WFTOTAL = function()
  print("|cff00ff88WindfuryTotal|r session total:", wfTotal)
end

SLASH_WFRESET1 = "/wfreset"
SlashCmdList.WFRESET = function()
  wfTotal = 0
  wfCurrentDamage = 0

  WindfuryTotalDB = WindfuryTotalDB or {}
  WindfuryTotalDB.history = WindfuryTotalDB.history or {}

  for i = #WindfuryTotalDB.history, 1, -1 do
    WindfuryTotalDB.history[i] = nil
  end

  -- NOTE: Best is NOT reset here (keeps your record).
  UpdateHistoryText()
  UIErrorsFrame:AddMessage("WF history reset.", 0.2, 1, 0.2, 1)
end

SLASH_WFTOGGLE1 = "/wftoggle"
SlashCmdList.WFTOGGLE = function()
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

SLASH_WFDEBUG1 = "/wfdebug"
SlashCmdList.WFDEBUG = function()
  debugOn = not debugOn
  print("|cff00ff88WindfuryTotal|r debug:", debugOn and "ON" or "OFF")
end

-- -------------------------
-- Events
-- -------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:RegisterEvent("PLAYER_TOTEM_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    playerGUID = UnitGUID("player")

    WindfuryTotalDB = WindfuryTotalDB or {}
    WindfuryTotalDB.history = WindfuryTotalDB.history or {}
    WindfuryTotalDB.best = WindfuryTotalDB.best or 0
    WindfuryTotalDB.theme = WindfuryTotalDB.theme or "modern"
	WindfuryTotalDB.jumps = WindfuryTotalDB.jumps or 0
    jumpCount = WindfuryTotalDB.jumps


    BuildWindfuryNameSet()
    ApplyTheme(WindfuryTotalDB.theme)
    UpdateHistoryText()
	
	    UpdateJumpText()

    if not jumpHooked and type(JumpOrAscendStart) == "function" then
      jumpHooked = true
      hooksecurefunc("JumpOrAscendStart", function()
        WindfuryTotalDB.jumps = (WindfuryTotalDB.jumps or 0) + 1
        jumpCount = WindfuryTotalDB.jumps
        UpdateJumpText()

      end)
    else
      dprint("Jump hook not available:", tostring(JumpOrAscendStart))
    end

	
	UpdateTotemIcons()

    return
  end
  
  if event == "PLAYER_TOTEM_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
  UpdateTotemIcons()
  return
end


  local info = { CombatLogGetCurrentEventInfo() }
  local subevent = info[2]
  local sourceGUID = info[4]

  if not playerGUID then playerGUID = UnitGUID("player") end
  if not next(WF_NAMES) then BuildWindfuryNameSet() end
  if sourceGUID ~= playerGUID then return end

  -- Your client: WF comes through as SPELL_DAMAGE with name "Windfury Weapon"
  if subevent == "SPELL_DAMAGE" then
    local spellId   = info[12]
    local spellName = info[13]
    local amount    = info[15] or 0

    if IsWindfurySpell(spellId, spellName) and amount > 0 then
      wfCurrentDamage = wfCurrentDamage + amount
      wfTotal = wfTotal + amount
      DebouncedCommit()
      dprint("WF SPELL_DAMAGE:", "id=", tostring(spellId), "name=", tostring(spellName), "amount=", amount)
    end
    return
  end
end)
