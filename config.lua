-- as-fines settings. SERVER ONLY (never sent to players).
Config = {}

Config.framework = 'auto'      -- 'auto', 'qbx', 'qb' or 'esx'

Config.account  = 'bank'       -- the account fines are paid from
Config.currency = '£'

-- Who can issue fines with /fine, and cancel them with /cancelfine.
Config.jobs          = { 'police' }   -- job names allowed to fine
Config.requireOnDuty = true
Config.minGrade      = 0              -- lowest job grade that can issue fines
Config.cancelGrade   = 3              -- lowest job grade that can cancel a fine (/cancelfine)

Config.command       = 'fine'         -- /fine [player id] [amount] [reason]
Config.cancelCommand = 'cancelfine'   -- /cancelfine [fine number]
Config.minAmount     = 1
Config.maxAmount     = 5000
Config.maxDistance   = 20.0           -- the person must be this close to the officer (0 = any distance)
Config.maxReasonLength = 120

Config.authority = 'Los Santos Police Department'    -- shown on the bank statement and emails
Config.mailFrom  = { name = 'Los Santos Police Department', email = 'noreply@lsgov.co.uk' }

-- How many paid fines the website lists.
Config.historyLimit = 10

-- Discord log of every fine, payment and cancellation. Empty = off.
Config.webhook = ''
