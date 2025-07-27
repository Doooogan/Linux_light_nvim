
-- ~/.config/nvim/lua/config/lsp.lua
local lspconfig = require('lspconfig')

lspconfig.pyright.setup {}      -- Python
lspconfig.lua_ls.setup {        -- Lua
  settings = {
    Lua = {
      diagnostics = {
        globals = { 'vim' }
      }
    }
  }
}
