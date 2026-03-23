-- MultiSpec (WoW 3.3.5)
-- Server -> client via addon msg: MSPEC\tDATA|active|max|id:name:icon:unlocked|...|TALENTS:talentString

local MAX_SPECS = 8
local activeSpec = 1
local specData = {}
local buttons = {}
local initialized = false
local layoutTicker = nil
local currentTalentString = ""

local msSessionEnabled = false
local msLoginPromptShown = false

local switchCooldownMs = 5000
local lastSwitchTime = 0

local isCasting = false
local castEndTime = 0
local castTargetSpec = nil
local castFrame = nil

MultiSpec_Debug = MultiSpec_Debug or false

local function MS_Dbg(...)
    if not MultiSpec_Debug then return end
    local t = {}
    for i=1, select("#", ...) do t[#t+1] = tostring(select(i, ...)) end
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ff99MultiSpec DBG:|r "..table.concat(t, " "))
end

local function RunCmd(cmd)
    local eb = DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox
    if not eb then return end
    eb:SetText("." .. cmd)
    ChatEdit_SendText(eb)
end

local function MS_SendAddon(msg)
    local eb = DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox
    if not eb then return end
    local escaped = msg:gsub("|", "||")
    eb:SetText("||MSPEC||" .. escaped)
    ChatEdit_SendText(eb)
end

local function MS_Delay(sec, fn)
    local f = CreateFrame("Frame")
    local e = 0
    f:SetScript("OnUpdate", function(self, dt)
        e = e + dt
        if e >= sec then
            self:SetScript("OnUpdate", nil)
            self:Hide()
            fn()
        end
    end)
end

local function GetTreeIcon(treeIndex)
    if not treeIndex or treeIndex <= 0 then return nil end
    local _, iconTexture = GetTalentTabInfo(treeIndex)
    return iconTexture
end

local function ForceHideFrame(f)
    if not f or f._ms_forcedHidden then return end
    f._ms_forcedHidden = true
    f:Hide()
    f:SetAlpha(0)
    f:EnableMouse(false)
    if f.HookScript then
        f:HookScript("OnShow", function(self) self:Hide() end)
    end
end
-- Reversible hide (used for TalentFrame tabs that must re-appear later)
local function MS_SetHidden(f, hide)
    if not f then return end

    if not f._ms_hideHooked and f.HookScript then
        f:HookScript("OnShow", function(self)
            if self._ms_hidden then
                -- Keep it "there" (so user can still click back) but make it invisible.
                self:SetAlpha(0)
            else
                self:SetAlpha(1)
            end
        end)
        f._ms_hideHooked = true
    end

    f._ms_hidden = hide and true or false
    if f._ms_hidden then
        f:Show()
        f:SetAlpha(0)
        f:EnableMouse(true)   -- лишаємо клікабельність, щоб можна було повернутись назад
    else
        f:SetAlpha(1)
        f:EnableMouse(true)
        f:Show()
    end
end

-- ============================================================================
-- Cast Bar з правильним звуком
-- ============================================================================
local function CreateCastFrame()
    if castFrame then return castFrame end

    local f = CreateFrame("Frame", "MultiSpecCastFrame", UIParent)
    f:SetSize(195, 20)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
    f:SetFrameStrata("HIGH")
    f:Hide()

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\CastingBar\\UI-CastingBar-Background")

    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetPoint("TOPLEFT", 2, -2)
    bar:SetPoint("BOTTOMRIGHT", -2, 2)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.0, 0.7, 1.0, 1.0)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    f.bar = bar

    local border = f:CreateTexture(nil, "OVERLAY")
    border:SetPoint("TOPLEFT", -23, 25)
    border:SetPoint("BOTTOMRIGHT", 23, -25)
    border:SetTexture("Interface\\CastingBar\\UI-CastingBar-Border")

    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("CENTER", 0, 0)
    f.text = text

    local spark = bar:CreateTexture(nil, "OVERLAY")
    spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    spark:SetBlendMode("ADD")
    spark:SetSize(32, 32)
    f.spark = spark

    castFrame = f
    return f
end

local function StartCastBar(specId, durationSec)
    local f = CreateCastFrame()

    local specName = "Spec " .. specId
    if specData[specId] and specData[specId].name then
        specName = specData[specId].name
    end

    f.text:SetText("Activating: " .. specName)
    f.bar:SetValue(0)
    f.spark:SetPoint("CENTER", f.bar, "LEFT", 0, 0)

    isCasting = true
    castTargetSpec = specId
    castEndTime = GetTime() + durationSec

    f:Show()
    
    -- Звук початку касту (як при нативному dual spec)
    PlaySoundFile("Sound\\Spells\\Teleport.wav")

    f:SetScript("OnUpdate", function(self, elapsed)
        if not isCasting then
            self:Hide()
            self:SetScript("OnUpdate", nil)
            return
        end

        local now = GetTime()
        local remaining = castEndTime - now
        local progress = 1 - (remaining / durationSec)

        if progress >= 1 then
            progress = 1
            isCasting = false
            -- Звук завершення
            PlaySoundFile("Sound\\Spells\\ShaysBell.wav")
            MS_Delay(0.3, function()
                self:Hide()
                self:SetScript("OnUpdate", nil)
            end)
        end

        f.bar:SetValue(progress)
        local barWidth = f.bar:GetWidth()
        f.spark:SetPoint("CENTER", f.bar, "LEFT", barWidth * progress, 0)
    end)
end

local function CancelCastBar()
    if not isCasting then return end
    isCasting = false
    castTargetSpec = nil
    if castFrame then
        castFrame:Hide()
        castFrame:SetScript("OnUpdate", nil)
    end
    -- Звук скасування
    PlaySoundFile("Sound\\Spells\\Fizzle.wav")
end

-- ============================================================================
-- Layout
-- ============================================================================
local function ApplyTalentFrameLayout()
    MS_Dbg("petMode:", tostring(PlayerSpecTab3 and PlayerSpecTab3.GetChecked and PlayerSpecTab3:GetChecked()))
    MS_Dbg("PlayerSpecTab3 shown:", tostring(PlayerSpecTab3 and PlayerSpecTab3:IsShown()))

    if not msSessionEnabled then return end
    if not PlayerTalentFrame then return end

    ForceHideFrame(PlayerSpecTab1)
    ForceHideFrame(PlayerSpecTab2)

    if PlayerSpecTab3 then
        PlayerSpecTab3:ClearAllPoints()
        PlayerSpecTab3:SetPoint("RIGHT", PlayerTalentFrame, "RIGHT", -2, -135)
        
        if not PlayerSpecTab3._msHooked then
            PlayerSpecTab3:HookScript("OnShow", function(self)
                self:ClearAllPoints()
                self:SetPoint("RIGHT", PlayerTalentFrame, "RIGHT", -2, -135)
            end)
            PlayerSpecTab3._msHooked = true
        end
    end
    -- Pet-talents mode is controlled by PlayerSpecTab3 (hunter pet button), NOT by PanelTemplates tabs.
    local petMode = false
    if PlayerSpecTab3 and PlayerSpecTab3.GetChecked then
        petMode = (PlayerSpecTab3:GetChecked() == 1)
    end

    if petMode then
        MS_SetHidden(PlayerTalentFrameTab1, true) -- Talents (player)
        MS_SetHidden(PlayerTalentFrameTab2, true) -- Glyphs (player)
    else
        MS_SetHidden(PlayerTalentFrameTab1, false)
        MS_SetHidden(PlayerTalentFrameTab2, false)
    end


    if MultiSpecContainer then
        MultiSpecContainer:ClearAllPoints()
        MultiSpecContainer:SetPoint("TOPLEFT", PlayerTalentFrame, "TOPRIGHT", -32, -40)
    end
end

local UpdateButtons

local function ScheduleLayoutEnforce()
    if not msSessionEnabled then return end
    if layoutTicker then return end

    local t = CreateFrame("Frame")
    local elapsed = 0
    t:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        ApplyTalentFrameLayout()
        if type(UpdateButtons) == "function" then
            UpdateButtons()
        end
        if elapsed >= 1.0 then
            self:SetScript("OnUpdate", nil)
            self:Hide()
            layoutTicker = nil
        end
    end)
    layoutTicker = t
end

-- ============================================================================
-- Export/Import талантів
-- Формат: tab:index:rank,tab:index:rank,...
-- ============================================================================
local pendingImport = nil  -- таблиця талантів для імпорту
local importFrame = nil    -- фрейм для повторного застосування

local function ShowExportPopup()
    if currentTalentString == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000MultiSpec:|r Немає даних талантів. Спочатку використайте /ms.")
        return
    end
    
    StaticPopupDialogs["MULTISPEC_EXPORT"] = {
        text = "Експорт талантів (Ctrl+C):",
        button1 = "Закрити",
        hasEditBox = true,
        editBoxWidth = 350,
        OnShow = function(self)
            self.editBox:SetText(currentTalentString)
            self.editBox:HighlightText()
            self.editBox:SetFocus()
        end,
        OnAccept = function() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("MULTISPEC_EXPORT")
end

local function StopImport()
    pendingImport = nil
    if importFrame then
        importFrame:SetScript("OnUpdate", nil)
        importFrame:Hide()
    end
end

local function StartImport(talentString)
    -- Перевіряємо чи увімкнений предпросмотр талантів
    local previewEnabled = GetCVarBool("previewTalents")
    if not previewEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000MultiSpec:|r Спочатку увімкніть предпросмотр талантів!")
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8800MultiSpec:|r Інтерфейс → Відображення → Предпросмотр талантів")
        return
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00MultiSpec:|r Імпорт талантів...")
    
    -- Парсимо формат tab:index:rank,tab:index:rank,...
    local talents = {}
    for entry in talentString:gmatch("([^,]+)") do
        local tab, index, rank = entry:match("(%d+):(%d+):(%d+)")
        if tab and index and rank then
            -- Отримуємо tier (рядок) для сортування
            local name, _, tier = GetTalentInfo(tonumber(tab), tonumber(index))
            table.insert(talents, {
                tab = tonumber(tab),
                index = tonumber(index),
                rank = tonumber(rank),
                tier = tier or 99
            })
        end
    end
    
    if #talents == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000MultiSpec:|r Невірний формат рядка талантів.")
        return
    end
    
    local freePoints = GetUnspentTalentPoints() or 0
    if freePoints == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000MultiSpec:|r Немає вільних очок талантів! Спочатку скиньте таланти.")
        return
    end
    
    -- Сортуємо по tab, потім по tier (рядку) - спочатку верхні ряди
    table.sort(talents, function(a, b)
        if a.tab ~= b.tab then
            return a.tab < b.tab
        end
        return a.tier < b.tier
    end)
    
    -- Скидаємо preview
    if ResetGroupPreviewTalentPoints then
        pcall(function() ResetGroupPreviewTalentPoints(false) end)
    end
    
    -- Додаємо preview points для кожного таланту
    -- Повторюємо кілька разів бо пререквізити можуть блокувати
    local totalAdded = 0
    local maxPasses = 10  -- максимум 10 проходів
    
    for pass = 1, maxPasses do
        local addedThisPass = 0
        
        for _, t in ipairs(talents) do
            local name, _, _, _, currentRank, maxRank, _, meetsPrereq = GetTalentInfo(t.tab, t.index)
            if name then
                -- Перевіряємо preview rank
                local _, _, _, _, _, _, _, _, previewRank = GetTalentInfo(t.tab, t.index)
                local currentPreview = previewRank or currentRank
                local pointsToAdd = t.rank - currentPreview
                
                if pointsToAdd > 0 then
                    for i = 1, pointsToAdd do
                        local ok = pcall(function()
                            AddPreviewTalentPoints(t.tab, t.index, 1, false)
                        end)
                        if ok then
                            -- Перевіряємо чи реально додалось
                            local _, _, _, _, _, _, _, _, newPreviewRank = GetTalentInfo(t.tab, t.index)
                            if (newPreviewRank or currentRank) > currentPreview then
                                addedThisPass = addedThisPass + 1
                                totalAdded = totalAdded + 1
                                currentPreview = newPreviewRank or currentRank
                            else
                                break  -- не додалось, пререквізит не виконаний
                            end
                        end
                    end
                end
            end
        end
        
        if addedThisPass == 0 then
            break  -- нічого не додалось, виходимо
        end
    end
    
    if totalAdded > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00MultiSpec:|r Готово! Додано " .. totalAdded .. " очок.")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00MultiSpec:|r Відкрийте таланти (N) і натисніть 'Вивчити'.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000MultiSpec:|r Не вдалося додати таланти.")
    end
end

local function ShowImportPopup()
    local freePoints = GetUnspentTalentPoints() or 0
    
    if freePoints == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000MultiSpec:|r Немає вільних очок талантів!")
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8800MultiSpec:|r Скиньте таланти або перемкніться на порожній спек.")
        return
    end
    
    StaticPopupDialogs["MULTISPEC_IMPORT"] = {
        text = "Вставте рядок талантів (Ctrl+V):\nВільних очок: " .. freePoints,
        button1 = "Імпорт",
        button2 = "Скасувати",
        hasEditBox = true,
        editBoxWidth = 350,
        OnShow = function(self)
            local editBox = _G[self:GetName().."EditBox"]
            if editBox then
                editBox:SetText("")
                editBox:SetFocus()
            end
        end,
        OnAccept = function(self)
            local editBox = _G[self:GetName().."EditBox"]
            local importStr = editBox and editBox:GetText() or ""
            if importStr ~= "" then
                StartImport(importStr)
            end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            local importStr = self:GetText() or ""
            if importStr ~= "" then
                StartImport(importStr)
            end
            parent:Hide()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("MULTISPEC_IMPORT")
end

-- ============================================================================
-- Context Menu
-- ============================================================================
local function ShowContextMenu(specId)
    local data = specData[specId]
    local isUnlocked = data and data.unlocked

    local menu = {
        { text = "MultiSpec", isTitle = true, notCheckable = true },
    }

    if isUnlocked then
        table.insert(menu, { 
            text = "Застосувати", 
            notCheckable = true, 
            func = function()
                if specId ~= activeSpec then
                    RunCmd("spec switch " .. specId)
                end
            end 
        })
        table.insert(menu, { 
            text = "Зберегти", 
            notCheckable = true, 
            func = function()
                RunCmd("spec save")
            end 
        })
        
        table.insert(menu, { 
            text = "Переймен.", 
            notCheckable = true, 
            func = function()
                StaticPopupDialogs["MULTISPEC_RENAME"] = {
                    text = "Введіть назву спеку:",
                    button1 = "OK",
                    button2 = "Відміна",
                    hasEditBox = true,
                    editBoxWidth = 220,
                    OnShow = function(self)
                        local cur = (specData[specId] and specData[specId].name) or ("Спек " .. specId)
                        self.editBox:SetText(cur)
                        self.editBox:HighlightText()
                        self.editBox:SetFocus()
                    end,
                    OnAccept = function(self)
                        local newName = self.editBox:GetText()
                        if newName and newName ~= "" then
                            RunCmd("spec rename " .. specId .. " " .. newName)
                        end
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                }
                StaticPopup_Show("MULTISPEC_RENAME")
            end 
        })
        
        -- Export/Import тільки для активного спека
        if specId == activeSpec then
            table.insert(menu, { 
                text = "Експорт талантів", 
                notCheckable = true, 
                func = ShowExportPopup
            })
            table.insert(menu, { 
                text = "Імпорт талантів", 
                notCheckable = true, 
                func = ShowImportPopup
            })
        end
    else
        table.insert(menu, { 
            text = "Розблокувати спек", 
            notCheckable = true, 
            func = function()
                RunCmd("spec unlock " .. specId)
            end 
        })
    end

    table.insert(menu, { text = "Close", notCheckable = true, func = function() CloseDropDownMenus() end })

    EasyMenu(menu, CreateFrame("Frame", "MultiSpecDropdown", UIParent, "UIDropDownMenuTemplate"), "cursor", 0, 0, "MENU")
end

-- ============================================================================
-- Unlock confirmation popup
-- ============================================================================
local function ShowUnlockPopup(specId, costGold)
    StaticPopupDialogs["MULTISPEC_UNLOCK"] = {
        text = string.format("Unlock Spec %d for %d gold?", specId, costGold),
        button1 = "Yes",
        button2 = "No",
        OnAccept = function()
            RunCmd("spec unlock " .. specId .. " confirm")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("MULTISPEC_UNLOCK")
end

-- ============================================================================
-- UI Buttons
-- ============================================================================
UpdateButtons = function()
    for i = 1, MAX_SPECS do
        local btn = buttons[i]
        if btn then
            local data = specData[i]
            local isUnlocked = data and data.unlocked
            local treeIcon = data and GetTreeIcon(data.icon) or nil

            if isUnlocked then
                if treeIcon then
                    btn.icon:SetTexture(treeIcon)
                    btn.icon:SetDesaturated(false)
                else
                    btn.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                    btn.icon:SetDesaturated(false)
                end
                btn:SetAlpha(1.0)
            else
                btn.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                btn.icon:SetDesaturated(true)
                btn:SetAlpha(0.5)
            end
            btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local name = (data and data.name and data.name ~= "") and data.name or ("Spec " .. i)
            if not isUnlocked then
                name = "|cff888888[Locked]|r"
            end
            btn.label:SetText(name)

            if i == activeSpec and isUnlocked then
                btn.activeBorder:Show()
            else
                btn.activeBorder:Hide()
            end
        end
    end
end

local function CreateUI()
    if not msSessionEnabled then return end
    if initialized then return end
    initialized = true
    if not PlayerTalentFrame then return end

    local container = CreateFrame("Frame", "MultiSpecContainer", PlayerTalentFrame)
    container:SetSize(220, 380)
    container:ClearAllPoints()
    container:SetPoint("TOPLEFT", PlayerTalentFrame, "TOPRIGHT", -32, -40)

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 36, -2)
    title:SetText("MultiSpec")

    local btnSize = 32
    local spacing = 6
    local yStart = -22

    for i = 1, MAX_SPECS do
        local btn = CreateFrame("Button", "MultiSpecButton"..i, container)
        btn:SetSize(btnSize, btnSize)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", 0, yStart - (i - 1) * (btnSize + spacing))
        btn.specId = i

        btn:SetNormalTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
        btn:SetPushedTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        btn:GetHighlightTexture():SetBlendMode("ADD")

        btn.icon = btn:CreateTexture(nil, "OVERLAY")
        btn.icon:SetSize(btnSize - 10, btnSize - 10)
        btn.icon:SetPoint("CENTER", 0, 0)
        btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        btn.activeBorder = btn:CreateTexture(nil, "OVERLAY")
        btn.activeBorder:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        btn.activeBorder:SetBlendMode("ADD")
        btn.activeBorder:SetSize(btnSize + 18, btnSize + 18)
        btn.activeBorder:SetPoint("CENTER", 0, 0)
        btn.activeBorder:Hide()

        btn.label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.label:SetPoint("LEFT", btn, "RIGHT", 8, 0)
        btn.label:SetWidth(160)
        btn.label:SetJustifyH("LEFT")

        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnClick", function(self, mouseButton)
            local data = specData[self.specId]
            local isUnlocked = data and data.unlocked

            if mouseButton == "LeftButton" then
                if not isUnlocked then
                    RunCmd("spec unlock " .. self.specId)
                elseif self.specId ~= activeSpec then
                    RunCmd("spec switch " .. self.specId)
                end
            else
                ShowContextMenu(self.specId)
            end
        end)

        buttons[i] = btn
    end

    ApplyTalentFrameLayout()
    ScheduleLayoutEnforce()
    RunCmd("spec sync")

    MS_Delay(0.45, function()
        RunCmd("spec bars")
    end)

    UpdateButtons()
end

-- ============================================================================
-- Parse Server Messages
-- ============================================================================
local function ParseSystemMsg(rawMsg)
    if not msSessionEnabled then return end
    if not rawMsg or rawMsg == "" then return end

    local msg = rawMsg
    if msg:sub(1, 7) == "|MSPEC|" then
        msg = msg:sub(8)
    else
        return
    end

    MS_Dbg("Recv:", msg)

    -- COOLDOWN|remainingMs
    if msg:sub(1, 9) == "COOLDOWN|" then
        local remainingMs = tonumber(msg:sub(10))
        if remainingMs then
            local remaining = math.ceil(remainingMs / 1000)
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000MultiSpec:|r Please wait " .. remaining .. " seconds.")
        end
        return
    end

    -- CAST_START|specId|durationMs
    if msg:sub(1, 11) == "CAST_START|" then
        local rest = msg:sub(12)
        local specId, durationMs = rest:match("^(%d+)|(%d+)$")
        if specId and durationMs then
            StartCastBar(tonumber(specId), tonumber(durationMs) / 1000)
        end
        return
    end

    -- CAST_CANCEL
    if msg == "CAST_CANCEL" then
        CancelCastBar()
        return
    end

    -- CAST_COMPLETE|specId
    if msg:sub(1, 14) == "CAST_COMPLETE|" then
        if isCasting then
            isCasting = false
            castTargetSpec = nil
        end
        return
    end

    -- UNLOCK_PROMPT|specId|costGold
    if msg:sub(1, 14) == "UNLOCK_PROMPT|" then
        local rest = msg:sub(15)
        local specId, cost = rest:match("^(%d+)|(%d+)$")
        if specId and cost then
            ShowUnlockPopup(tonumber(specId), tonumber(cost))
        end
        return
    end

    -- UNLOCKED|specId
    if msg:sub(1, 9) == "UNLOCKED|" then
        local specId = tonumber(msg:sub(10))
        if specId and specData[specId] then
            specData[specId].unlocked = true
            UpdateButtons()
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00MultiSpec:|r Spec " .. specId .. " unlocked!")
        end
        return
    end

    -- CONFIG|cooldownMs
    if msg:sub(1, 7) == "CONFIG|" then
        local cdMs = tonumber(msg:sub(8))
        if cdMs then
            switchCooldownMs = cdMs
            MS_Dbg("Cooldown set to", cdMs, "ms")
        end
        return
    end

    -- DATA|active|max|id:name:icon:unlocked|...|TALENTS:talentString
    if msg:sub(1, 5) ~= "DATA|" then return end

    local parts = {}
    for tok in msg:gmatch("([^|]+)") do parts[#parts+1] = tok end

    local prevActive = activeSpec

    activeSpec = tonumber(parts[2]) or activeSpec
    MAX_SPECS = tonumber(parts[3]) or MAX_SPECS

    wipe(specData)
    for i = 4, #parts do
        if parts[i]:sub(1, 8) == "TALENTS:" then
            currentTalentString = parts[i]:sub(9)
            MS_Dbg("Got talent string:", currentTalentString)
        else
            local sid, name, iconStr, unlockedStr = parts[i]:match("^(%d+):(.*):(%-?%d+):(%d)$")
            if sid then
                local id = tonumber(sid)
                specData[id] = { 
                    name = name or ("Spec "..id), 
                    icon = tonumber(iconStr) or 0,
                    unlocked = (unlockedStr == "1")
                }
            end
        end
    end

    UpdateButtons()

    if prevActive ~= activeSpec then
        if isCasting then
            isCasting = false
            castTargetSpec = nil
        end
        MS_Delay(0.45, function()
            RunCmd("spec bars")
        end)
    end
end

-- ============================================================================
-- Slash Commands
-- ============================================================================
SLASH_MS1 = "/ms"
SlashCmdList["MS"] = function(msg)
    msg = (msg or ""):lower()
    if msg == "debug" then
        MultiSpec_Debug = not MultiSpec_Debug
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00MultiSpec|r debug = " .. tostring(MultiSpec_Debug))
        return
    end
    
    if msg == "export" then
        ShowExportPopup()
        return
    end
    
    if msg == "import" then
        ShowImportPopup()
        return
    end

    if not msSessionEnabled then
        if type(GetActiveTalentGroup) == "function" and (GetActiveTalentGroup() or 1) == 1 then
            msSessionEnabled = true
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000MultiSpec:|r Disabled. Switch to primary spec first.")
            return
        end
    end

    RunCmd("spec sync")
end

-- ============================================================================
-- Native dual-spec login gate
-- ============================================================================
local function MS_IsOnPrimaryTalentGroup()
    if type(GetActiveTalentGroup) ~= "function" then return true end
    return (GetActiveTalentGroup() or 1) == 1
end

local function MS_EnableNow()
    msSessionEnabled = true

    if PlayerTalentFrame and PlayerTalentFrame:IsShown() then
        CreateUI()
        ApplyTalentFrameLayout()
        ScheduleLayoutEnforce()
    end

    RunCmd("spec sync")
    MS_Delay(0.45, function()
        RunCmd("spec bars")
    end)
end

local function MS_ShowNeedPrimarySpecPopup()
    if msLoginPromptShown then return end
    msLoginPromptShown = true

    StaticPopupDialogs["MULTISPEC_NEED_PRIMARY_SPEC"] = {
        text = "MultiSpec requires primary talent spec. Switch now?",
        button1 = "Yes",
        button2 = "No",
        OnAccept = function()
            MS_SendAddon("NATIVE|0")

            local function poll(try)
                if MS_IsOnPrimaryTalentGroup() then
                    MS_EnableNow()
                    return
                end

                if try >= 20 then
                    msSessionEnabled = false
                    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000MultiSpec:|r Failed to switch. Try /ms manually.")
                    return
                end

                MS_Delay(0.5, function() poll(try + 1) end)
            end

            poll(0)
        end,

        OnCancel = function()
            msSessionEnabled = false
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    StaticPopup_Show("MULTISPEC_NEED_PRIMARY_SPEC")
end

local function MS_LoginGateCheck(try)
    try = try or 0
    if try > 10 then
        msSessionEnabled = true
        return
    end

    if type(GetNumTalentGroups) ~= "function" or type(GetActiveTalentGroup) ~= "function" then
        msSessionEnabled = true
        return
    end

    local n = GetNumTalentGroups()
    local g = GetActiveTalentGroup()

    if not n or not g then
        MS_Delay(0.5, function() MS_LoginGateCheck(try + 1) end)
        return
    end

    if n > 1 and g ~= 1 then
        msSessionEnabled = false
        MS_ShowNeedPrimarySpecPopup()
    else
        msSessionEnabled = true
    end
end

-- ============================================================================
-- Events
-- ============================================================================
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("UNIT_SPELLCAST_START")
f:RegisterEvent("PET_BAR_UPDATE")
f:RegisterEvent("UNIT_PET")

f:SetScript("OnEvent", function(self, ev, a1, a2, a3, a4, a5, a6, a7, a8, a9)

    if ev == "ADDON_LOADED" and a1 == "Blizzard_TalentUI" then
        if PlayerTalentFrame then
            PlayerTalentFrame:HookScript("OnShow", function()
                if not msSessionEnabled then return end
                CreateUI()
                ApplyTalentFrameLayout()
                ScheduleLayoutEnforce()
            end)
                        -- Re-apply layout when switching between Talents/Glyphs/Pet tabs.
            -- Blizzard frequently re-anchors the hunter pet button on tab switches.
            local function HookTab(tab)
                if not tab or tab._msTabHooked or not tab.HookScript then return end
                tab:HookScript("OnClick", function()
                    if not msSessionEnabled then return end
                    ApplyTalentFrameLayout()
                    ScheduleLayoutEnforce()
                end)
                tab._msTabHooked = true
            end

            HookTab(PlayerTalentFrameTab1)
            HookTab(PlayerTalentFrameTab2)
            HookTab(PlayerTalentFrameTab3)
                        -- Pet button (hunter) toggles pet talents; Blizzard re-anchors it + re-shows tabs on every update.
            if PlayerSpecTab3 and not PlayerSpecTab3._msPetHooked then
                PlayerSpecTab3:HookScript("OnClick", function()
                    if not msSessionEnabled then return end
                    -- run after Blizzard handlers
                    MS_Delay(0.01, function()
                        ApplyTalentFrameLayout()
                        ScheduleLayoutEnforce()
                    end)
                end)
                PlayerSpecTab3._msPetHooked = true
            end

            -- Re-apply after Blizzard refreshes the talent frame (this is what resets your anchor and tabs).
            if type(hooksecurefunc) == "function" then
                if type(PlayerTalentFrame_Update) == "function" and not _G.__MSPEC_HOOK_PTFU then
                    hooksecurefunc("PlayerTalentFrame_Update", function()
                        if not msSessionEnabled then return end
                        ApplyTalentFrameLayout()
                    end)
                    _G.__MSPEC_HOOK_PTFU = true
                end
                if type(PlayerTalentFrame_UpdateTabs) == "function" and not _G.__MSPEC_HOOK_PTFT then
                    hooksecurefunc("PlayerTalentFrame_UpdateTabs", function()
                        if not msSessionEnabled then return end
                        ApplyTalentFrameLayout()
                    end)
                    _G.__MSPEC_HOOK_PTFT = true
                end
            end

        end
    elseif ev == "PLAYER_LOGIN" then
        MS_LoginGateCheck()
    elseif ev == "CHAT_MSG_ADDON" then
        local prefix = a1
        local msg = a2

        if prefix == "MSPEC" and msg and msg ~= "" then
            ParseSystemMsg("|MSPEC|" .. msg)
        end
    elseif ev == "PLAYER_REGEN_DISABLED" then
        if isCasting then
            CancelCastBar()
        end
    elseif ev == "UNIT_SPELLCAST_START" and a1 == "player" then
        if isCasting then
            CancelCastBar()
        end
    elseif ev == "PET_BAR_UPDATE" or (ev == "UNIT_PET" and a1 == "player") then
        if msSessionEnabled and PlayerTalentFrame and PlayerTalentFrame:IsShown() then
            ApplyTalentFrameLayout()
        end
    end
end)

-- ============================================================================
-- Movement cancel
-- ============================================================================
local msMovePoll = CreateFrame("Frame")
msMovePoll.acc = 0

msMovePoll:SetScript("OnUpdate", function(self, dt)
    if not isCasting then return end

    self.acc = self.acc + dt
    if self.acc < 0.05 then return end
    self.acc = 0

    local speed = (type(GetUnitSpeed) == "function") and (GetUnitSpeed("player") or 0) or 0
    if speed > 0 then
        CancelCastBar()
    end
end)

print("|cff00ff00MultiSpec|r loaded. /ms debug | /ms export | /ms import")
