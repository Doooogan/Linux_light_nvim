
-- ~/.config/nvim/lua/config/lsp.lua
local lspconfig = require('lspconfig')
--
-- disable inline error text
vim.diagnostic.config({
  virtual_text = false,
  signs = false,
  underline = true,
  float = { border = 'none'},
})

lspconfig.pyright.setup {}      -- Python
lspconfig.lua_ls.setup {        -- Lua
  cmd = {"/home/doogan/lua-language-server/bin/lua-language-server"},
  settings = {
    Lua = {
      diagnostics = {
        globals = { 'vim' }
      }
    }
  }
}
