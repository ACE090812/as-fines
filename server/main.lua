-- as-fines server: issuing, paying and cancelling fines, and the exports other scripts use.
--
-- A fine is 'unpaid' until it is paid ('paid') or cancelled ('cancelled'). Nothing happens to a
-- player who does not pay: they see it on lsgov.co.uk and get a phone notification.

local function now() return os.time() end
local function log(fmt, ...) print(('^5[as-fines]^0 ' .. fmt):format(...)) end
local function money(n) return Config.currency .. tostring(n) end

MySQL.ready(function()
    MySQL.query([[CREATE TABLE IF NOT EXISTS as_fines (
        id INT AUTO_INCREMENT PRIMARY KEY,
        citizenid VARCHAR(64) NOT NULL,
        amount INT NOT NULL,
        reason VARCHAR(200) NOT NULL,
        issued_by VARCHAR(100) NOT NULL,
        issued_by_cid VARCHAR(64) NULL,
        issued_at INT NOT NULL,
        status VARCHAR(12) NOT NULL DEFAULT 'unpaid',
        paid_at INT NULL,
        KEY idx_owner (citizenid, status)
    )]])
end)

-- ---------------------------------------------------------------------------------------------
-- Discord log
-- ---------------------------------------------------------------------------------------------

local function discordLog(title, color, fields)
    if type(Config.webhook) ~= 'string' or not Config.webhook:find('^https://') then return end
    local out = {}
    for _, f in ipairs(fields) do
        out[#out + 1] = { name = f[1], value = tostring(f[2]):gsub('@', '@\226\128\139'):sub(1, 200), inline = true }
    end
    PerformHttpRequest(Config.webhook, function() end, 'POST', json.encode({
        embeds = { { title = title, color = color, fields = out, timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'), footer = { text = 'as-fines' } } },
        allowed_mentions = { parse = {} },
    }), { ['Content-Type'] = 'application/json' })
end

-- ---------------------------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------------------------

local function cleanReason(text)
    text = tostring(text or ''):gsub('[%c]', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    return text:sub(1, Config.maxReasonLength or 120)
end

local function toFine(row)
    return { id = row.id, amount = row.amount, reason = row.reason, issuedBy = row.issued_by,
             issuedAt = row.issued_at, status = row.status, paidAt = row.paid_at }
end

local function unpaidRows(cid)
    return MySQL.query.await("SELECT * FROM as_fines WHERE citizenid = ? AND status = 'unpaid' ORDER BY id", { cid }) or {}
end

--- Turns a server id or a citizen id into a citizen id.
local function toCid(who)
    if type(who) == 'number' then return Bridge.getIdentifier(who) end
    if type(who) == 'string' and who ~= '' then return who end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- Issuing
-- ---------------------------------------------------------------------------------------------

--- Adds a fine. `who` is a server id or a citizen id. data = { amount, reason, issuer, issuerCid }.
--- Returns the fine number, or nil and a reason.
local function issueFine(who, data)
    if type(data) ~= 'table' then return nil, 'Bad request.' end
    local cid = toCid(who)
    if not cid then return nil, 'That person could not be found.' end
    local amount = math.floor(tonumber(data.amount) or 0)
    if amount < (Config.minAmount or 1) or amount > (Config.maxAmount or 5000) then
        return nil, ('The amount must be between %s and %s.'):format(money(Config.minAmount or 1), money(Config.maxAmount or 5000))
    end
    local reason = cleanReason(data.reason)
    if reason == '' then return nil, 'Give a reason for the fine.' end
    local issuer = cleanReason(data.issuer or Config.authority):sub(1, 100)
    if issuer == '' then issuer = Config.authority end

    local id = MySQL.insert.await(
        'INSERT INTO as_fines (citizenid, amount, reason, issued_by, issued_by_cid, issued_at) VALUES (?, ?, ?, ?, ?, ?)',
        { cid, amount, reason, issuer, data.issuerCid or '', now() })
    if not id then return nil, 'The fine could not be saved.' end

    local src = Bridge.findSource(cid)
    if src then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'Fine issued', type = 'error', duration = 8000,
            description = ('%s fine: %s. Pay it on lsgov.co.uk.'):format(money(amount), reason),
        })
        Bridge.phoneNotify(src, 'You have been fined', ('%s: %s. Pay it on lsgov.co.uk.'):format(money(amount), reason))
    end
    Bridge.sendPhoneMail(src, cid, Config.mailFrom, ('Fine notice: %s'):format(money(amount)),
        ('You have been fined %s.\n\nReason: %s\nIssued by: %s\nFine number: %d\n\nYou can pay it on lsgov.co.uk (Pay a fine).'):format(amount, reason, issuer, id))
    discordLog('Fine issued', 0xf59e0b, { { 'Fine', '#' .. id }, { 'Citizen ID', cid }, { 'Amount', money(amount) }, { 'Reason', reason }, { 'Issued by', issuer } })
    TriggerEvent('as-fines:issued', cid, id, amount, reason)
    return id
end

-- ---------------------------------------------------------------------------------------------
-- What the website shows and does
-- ---------------------------------------------------------------------------------------------

local function getState(src)
    local cid = Bridge.getIdentifier(src)
    if not cid then return nil, 'You are not signed in.' end
    local fines, owed = {}, 0
    for _, row in ipairs(unpaidRows(cid)) do
        fines[#fines + 1] = toFine(row)
        owed = owed + row.amount
    end
    local paid = {}
    local rows = MySQL.query.await(
        "SELECT * FROM as_fines WHERE citizenid = ? AND status = 'paid' ORDER BY paid_at DESC, id DESC LIMIT ?",
        { cid, math.floor(Config.historyLimit or 10) }) or {}
    for _, row in ipairs(rows) do paid[#paid + 1] = toFine(row) end
    return { currency = Config.currency, fines = fines, owed = owed, paid = paid, now = now() }
end

local busy = {}

--- Pays one fine, or all unpaid fines. data = { id = 12 } or { all = true }.
local function pay(src, data)
    local cid = Bridge.getIdentifier(src)
    if not cid then return nil, 'You are not signed in.' end

    local rows
    if data.all == true then
        rows = unpaidRows(cid)
    else
        local id = math.floor(tonumber(data.id) or 0)
        if id <= 0 then return nil, 'Choose a fine to pay.' end
        local row = MySQL.single.await("SELECT * FROM as_fines WHERE id = ? AND citizenid = ? AND status = 'unpaid'", { id, cid })
        rows = row and { row } or {}
    end
    if #rows == 0 then return nil, 'There is nothing to pay.' end

    local total = 0
    for _, r in ipairs(rows) do total = total + r.amount end
    if not Bridge.removeMoney(src, Config.account, total, 'fine') then
        return nil, 'You do not have enough money in your bank account.'
    end

    -- Mark each one paid. Anything that changed in the meantime (cancelled, paid twice) is refunded.
    local paidTotal, paidCount, ts = 0, 0, now()
    for _, r in ipairs(rows) do
        local changed = MySQL.update.await("UPDATE as_fines SET status = 'paid', paid_at = ? WHERE id = ? AND status = 'unpaid'", { ts, r.id })
        if changed and changed > 0 then
            paidTotal, paidCount = paidTotal + r.amount, paidCount + 1
            TriggerEvent('as-fines:paid', cid, r.id, r.amount)
        end
    end
    if paidTotal < total then Bridge.addMoney(src, Config.account, total - paidTotal, 'fine-refund') end
    if paidCount == 0 then return nil, 'That fine has already been dealt with.' end

    pcall(function()
        exports['sd-phone']:addBankTransaction(cid, {
            label = paidCount == 1 and ('Fine #' .. rows[1].id) or ('Fines (' .. paidCount .. ')'),
            amount = -paidTotal, category = 'government', counterparty = Config.authority,
        })
    end)
    local name = Bridge.getCharacterName(src)
    Bridge.sendPhoneMail(src, cid, Config.mailFrom, 'Fine payment received',
        ('Hello %s,\n\nThank you. We have received your payment of %s for %d fine(s).'):format(name, money(paidTotal), paidCount))
    discordLog('Fine paid', 0x16a34a, { { 'Citizen ID', cid }, { 'Character', name }, { 'Paid', money(paidTotal) }, { 'Fines', paidCount } })
    return { paid = paidTotal, count = paidCount, now = ts }
end

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------

local function say(src, text, kind)
    if src == 0 then log('%s', text); return end
    TriggerClientEvent('ox_lib:notify', src, { title = 'Fines', description = text, type = kind or 'error' })
end

local function jobAllowed(src, minGrade)
    local j = Bridge.getJob(src)
    if not j then return false end
    local ok = false
    for _, name in ipairs(Config.jobs) do if name == j.name then ok = true end end
    if not ok then return false end
    if Config.requireOnDuty and j.onduty == false then return false, 'You need to be on duty.' end
    return (j.grade or 0) >= (minGrade or 0), 'Your rank cannot do this.'
end

local function near(a, b)
    local d = tonumber(Config.maxDistance) or 0
    if d <= 0 then return true end
    local pa, pb = GetPlayerPed(a), GetPlayerPed(b)
    if not pa or pa == 0 or not pb or pb == 0 then return false end
    return #(GetEntityCoords(pa) - GetEntityCoords(pb)) <= d
end

RegisterCommand(Config.command, function(src, args)
    if src == 0 then return say(src, 'Use this in game.') end
    local allowed, why = jobAllowed(src, Config.minGrade)
    if not allowed then return say(src, why or 'You cannot issue fines.') end

    local target = tonumber(args[1])
    local amount = tonumber(args[2])
    local reason = table.concat(args, ' ', 3)
    if not target or not amount or reason == '' then
        return say(src, ('Use /%s [player id] [amount] [reason]'):format(Config.command))
    end
    if target == src then return say(src, 'You cannot fine yourself.') end
    if not Bridge.getIdentifier(target) then return say(src, 'There is nobody with that id.') end
    if not near(src, target) then return say(src, 'They are too far away.') end

    local id, err = issueFine(target, {
        amount = amount, reason = reason, issuer = Bridge.getCharacterName(src), issuerCid = Bridge.getIdentifier(src),
    })
    if not id then return say(src, err) end
    say(src, ('Fined %s %s (fine #%d).'):format(Bridge.getCharacterName(target), money(math.floor(amount)), id), 'success')
end, false)

RegisterCommand(Config.cancelCommand, function(src, args)
    if src == 0 then return say(src, 'Use this in game.') end
    local allowed, why = jobAllowed(src, Config.cancelGrade)
    if not allowed then return say(src, why or 'You cannot cancel fines.') end
    local id = math.floor(tonumber(args[1]) or 0)
    if id <= 0 then return say(src, ('Use /%s [fine number]'):format(Config.cancelCommand)) end
    local changed = MySQL.update.await("UPDATE as_fines SET status = 'cancelled' WHERE id = ? AND status = 'unpaid'", { id })
    if not changed or changed == 0 then return say(src, 'There is no unpaid fine with that number.') end
    discordLog('Fine cancelled', 0xdc2626, { { 'Fine', '#' .. id }, { 'By', Bridge.getCharacterName(src) } })
    say(src, ('Fine #%d cancelled.'):format(id), 'success')
end, false)

AddEventHandler('playerDropped', function() busy[source] = nil end)

-- ---------------------------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------------------------

--- Issue a fine from another script (speed cameras, MDT). who = server id or citizen id.
--- data = { amount = 100, reason = 'Speeding', issuer = 'Speed camera' }. Returns the fine number, or nil, reason.
exports('issueFine', function(who, data)
    local ok, id, err = pcall(issueFine, who, data)
    if not ok then log('issueFine failed: %s', tostring(id)); return nil, 'Something went wrong.' end
    return id, err
end)

--- Unpaid fines for a character (server id or citizen id): { { id, amount, reason, issuedBy, issuedAt }, ... }
exports('getUnpaid', function(who)
    local cid = toCid(who)
    if not cid then return {} end
    local out = {}
    for _, row in ipairs(unpaidRows(cid)) do out[#out + 1] = toFine(row) end
    return out
end)

--- Total owed in unpaid fines.
exports('getOwed', function(who)
    local cid = toCid(who)
    if not cid then return 0 end
    return tonumber(MySQL.scalar.await("SELECT CAST(COALESCE(SUM(amount), 0) AS SIGNED) FROM as_fines WHERE citizenid = ? AND status = 'unpaid'", { cid })) or 0
end)

--- Cancel a fine by number. Returns true when an unpaid fine was cancelled.
exports('cancelFine', function(id)
    id = math.floor(tonumber(id) or 0)
    local changed = MySQL.update.await("UPDATE as_fines SET status = 'cancelled' WHERE id = ? AND status = 'unpaid'", { id })
    return changed ~= nil and changed > 0
end)

-- For the government site.
exports('getState', getState)
exports('pay', function(src, data)
    if type(src) ~= 'number' or type(data) ~= 'table' then return nil, 'Bad request.' end
    if busy[src] then return nil, 'Please wait, your last request is still being processed.' end
    busy[src] = true
    local ok, res, err = pcall(pay, src, data)
    busy[src] = nil
    if not ok then log('pay failed: %s', tostring(res)); return nil, 'Something went wrong. Please try again.' end
    return res, err
end)

CreateThread(function()
    Wait(2000)
    log('framework: %s | fining jobs: %s', Bridge.framework, table.concat(Config.jobs, ', '))
end)
