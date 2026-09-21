fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'as-fines'
author 'you'
description 'Fines: police issue them with /fine, players pay them on lsgov.co.uk (as-browser). Exports let other scripts issue fines.'
version '1.0.0'

-- config.lua is SERVER ONLY: it holds the Discord webhook.
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config.lua',
    'server/bridge.lua',
    'server/main.lua',
}

dependencies {
    'oxmysql',
}
