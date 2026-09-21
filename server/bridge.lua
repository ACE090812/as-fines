-- Framework bridge: who the player is, their character, job, bank and phone. Works with qbx_core,
-- qb-core and es_extended.
Bridge = {}

local function detectFramework()
    if Config.framework ~= 'auto' then return Config.framework end
    if GetResourceState('qbx_core') == 'started' then return 'qbx' end
    if GetResourceState('qb-core') == 'started' then return 'qb' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return 'standalone'
end

Bridge.framework = detectFramework()
local framework = Bridge.framework

local QBCore, qbxExport, ESX

local function ensureCore()
    if framework == 'qb' and not QBCore then
        QBCore = exports['qb-core']:GetCoreObject()
    elseif framework == 'qbx' and not qbxExport then
        qbxExport = exports.qbx_core
    elseif framework == 'esx' and not ESX then
        ESX = exports['es_extended']:getSharedObject()
    end
end

local function getPlayer(source)
    ensureCore()
    if framework == 'qb' and QBCore then return QBCore.Functions.GetPlayer(source) end
    if framework == 'qbx' and qbxExport then return qbxExport:GetPlayer(source) end
    return nil
end

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

--- The character's stable id (citizenid, or the ESX identifier).
function Bridge.getIdentifier(source)
    ensureCore()
    if framework == 'qb' or framework == 'qbx' then
        local p = getPlayer(source)
        return p and p.PlayerData.citizenid or nil
    elseif framework == 'esx' and ESX then
        local x = ESX.GetPlayerFromId(source)
        return x and x.identifier or nil
    end
    return source and ('standalone:' .. tostring(source)) or nil
end

--- The server id of an online character, or nil.
function Bridge.findSource(identifier)
    ensureCore()
    if type(identifier) ~= 'string' then return nil end
    if framework == 'qb' and QBCore then
        local p = QBCore.Functions.GetPlayerByCitizenId(identifier)
        return p and p.PlayerData.source or nil
    elseif framework == 'qbx' and qbxExport then
        local p = qbxExport:GetPlayerByCitizenId(identifier)
        return p and p.PlayerData.source or nil
    elseif framework == 'esx' and ESX then
        local x = ESX.GetPlayerFromIdentifier(identifier)
        return x and x.source or nil
    end
    local id = identifier:match('^standalone:(%d+)$')
    return id and tonumber(id) or nil
end

local function sexLetter(v)
    if v == nil then return 'X' end
    local s = tostring(v):lower()
    if s == '0' or s == 'm' or s == 'male' then return 'M' end
    if s == '1' or s == 'f' or s == 'female' then return 'F' end
    return 'X'
end

--- { first, last, dob, sex ('M'/'F'/'X'), nationality } exactly as the character was created.
function Bridge.getCharInfo(source)
    ensureCore()
    if framework == 'qb' or framework == 'qbx' then
        local p = getPlayer(source)
        local ci = p and p.PlayerData.charinfo
        if ci then
            return {
                first = trim(ci.firstname), last = trim(ci.lastname),
                dob = trim(ci.birthdate), sex = sexLetter(ci.gender),
                nationality = trim(ci.nationality), birthplace = trim(ci.birthplace or ci.placeofbirth),
            }
        end
    elseif framework == 'esx' and ESX then
        local x = ESX.GetPlayerFromId(source)
        if x then
            local function get(k) local ok, v = pcall(function() return x.get(k) end); return ok and v or nil end
            return {
                first = trim(get('firstName')), last = trim(get('lastName')),
                dob = trim(get('dateofbirth')), sex = sexLetter(get('sex')), nationality = '',
            }
        end
    end
    local name = GetPlayerName(source) or 'Citizen'
    return { first = name, last = '', dob = '', sex = 'X', nationality = '' }
end

function Bridge.getCharacterName(source)
    local ci = Bridge.getCharInfo(source)
    local name = trim(('%s %s'):format(ci.first or '', ci.last or ''))
    return name ~= '' and name or (GetPlayerName(source) or 'Citizen')
end

--- { name, grade, onduty } for a character's job, or nil.
function Bridge.getJob(source)
    ensureCore()
    if framework == 'qb' or framework == 'qbx' then
        local p = getPlayer(source)
        local j = p and p.PlayerData.job
        if not j then return nil end
        local grade = type(j.grade) == 'table' and (j.grade.level or 0) or tonumber(j.grade) or 0
        return { name = j.name, grade = grade, onduty = j.onduty ~= false }
    elseif framework == 'esx' and ESX then
        local x = ESX.GetPlayerFromId(source)
        local j = x and x.getJob and x.getJob()
        if not j then return nil end
        return { name = j.name, grade = tonumber(j.grade) or 0, onduty = true }
    end
    return nil
end

--- The server id of the online character with this first and last name (case-insensitive), or nil.
--- A number (or numeric text) is taken as a server id. Returns nil, 'many' when a name matches twice.
function Bridge.findByName(text)
    text = trim(text)
    if text == '' then return nil end
    if text:match('^%d+$') then
        local id = tonumber(text)
        return Bridge.getIdentifier(id) and id or nil
    end
    local want = text:lower():gsub('%s+', ' ')
    local found
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src and Bridge.getIdentifier(src) then
            if Bridge.getCharacterName(src):lower():gsub('%s+', ' ') == want then
                if found then return nil, 'many' end
                found = src
            end
        end
    end
    return found
end

-- ---------------------------------------------------------------------------------------------
-- Money
-- ---------------------------------------------------------------------------------------------

function Bridge.removeMoney(source, account, amount, reason)
    ensureCore()
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end
    if framework == 'qb' or framework == 'qbx' then
        local p = getPlayer(source)
        if not p or (p.PlayerData.money[account] or 0) < amount then return false end
        return p.Functions.RemoveMoney(account, amount, reason or 'as-fines') == true
    elseif framework == 'esx' and ESX then
        local x = ESX.GetPlayerFromId(source)
        if not x then return false end
        local acc = x.getAccount(account)
        if not acc or acc.money < amount then return false end
        x.removeAccountMoney(account, amount)
        return true
    end
    return true
end

function Bridge.addMoney(source, account, amount, reason)
    ensureCore()
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end
    if framework == 'qb' or framework == 'qbx' then
        local p = getPlayer(source)
        if not p then return false end
        p.Functions.AddMoney(account, amount, reason or 'as-fines-refund')
        return true
    elseif framework == 'esx' and ESX then
        local x = ESX.GetPlayerFromId(source)
        if not x then return false end
        x.addAccountMoney(account, amount)
        return true
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Phone
-- ---------------------------------------------------------------------------------------------

function Bridge.phoneNotify(source, title, body)
    if not source then return end
    pcall(function()
        exports['sd-phone']:notify(source, { app = 'as-browser', appId = 'as-browser', title = title, body = body, time = 'now' })
    end)
end

--- Sends a system email to the character's Mail app. Prints the reason when it can't.
function Bridge.sendPhoneMail(source, identifier, from, subject, body)
    local ok, err = pcall(function()
        local email
        if source then
            local live = exports['sd-phone']:getMailAccounts(source)
            if type(live) == 'table' and live[1] then email = live[1].email end
        end
        if not email and identifier then
            local saved = exports['sd-phone']:getMailAddresses(identifier)
            if type(saved) == 'table' and saved[1] then email = saved[1].email end
        end
        if not email then
            print(('^5[as-fines]^0 mail not sent: %s has no email account in the Mail app'):format(tostring(identifier)))
            return
        end
        local attempts = { from, from and { name = from.name } or nil, false }
        for i = 1, 3 do
            local sender = attempts[i]
            if sender ~= nil then
                local mail = { to = email, subject = subject, body = body }
                if sender then mail.from = sender end
                local res = exports['sd-phone']:sendMail(mail)
                if type(res) == 'table' and res.delivered and res.delivered > 0 then return end
            end
        end
        print(('^5[as-fines]^0 mail to %s was not delivered by sd-phone'):format(email))
    end)
    if not ok then print(('^5[as-fines]^0 mail failed: %s'):format(tostring(err))) end
end

return Bridge
