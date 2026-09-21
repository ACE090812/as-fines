# as-fines

Fines for the server. Police issue them with `/fine`, other scripts can issue them with an export, and players see and pay them on **lsgov.co.uk** (`as-browser`, "Pay a fine"). Fines are paid from the bank. Nothing happens to a player who does not pay: they get a phone notification and email when fined, and can see what they owe on the site.

## Commands

- `/fine [player id] [amount] [reason]`: for the jobs in `Config.jobs` (police), on duty, within `Config.maxDistance` of the person. Amount limits are `Config.minAmount` and `Config.maxAmount`.
- `/cancelfine [fine number]`: for job grade `Config.cancelGrade` and above.

## Requirements

`oxmysql`, `ox_lib` (only for on-screen notifications), `sd-phone` (statement line, notification, email), `as-browser` (the payment page). Framework: qbx_core, qb-core or es_extended.

## Install

1. Put `as-fines` in your resources (for example `[phone]`).
2. `ensure as-fines` after `ensure as-browser`, then `refresh`, restart `as-browser` and start `as-fines`. The `as_fines` table is created automatically.
3. Set `Config.jobs` (and the grades) to match your police job. Optional: a Discord webhook in `Config.webhook`.

## Exports for other scripts

```lua
-- speed cameras, MDT, etc. who = server id or citizen id. Returns the fine number, or nil + reason
exports['as-fines']:issueFine(source_or_citizenid, { amount = 100, reason = 'Speeding 62 in a 40', issuer = 'Speed camera' })
exports['as-fines']:getUnpaid(source_or_citizenid)   -- { { id, amount, reason, issuedBy, issuedAt }, ... }
exports['as-fines']:getOwed(source_or_citizenid)     -- total unpaid
exports['as-fines']:cancelFine(fineNumber)           -- true / false
```

Server events: `as-fines:issued (citizenid, fineId, amount, reason)` and `as-fines:paid (citizenid, fineId, amount)`, if you want to pay a police society account when fines are paid.

`getState(source)` and `pay(source, { id = 12 } or { all = true })` are used by the government site.
