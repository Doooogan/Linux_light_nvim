-- ~/.config/nvim/lua/config/lsp.lua

-- disable inline error text
vim.diagnostic.config({
  virtual_text = false,
  signs = false,
  underline = true,
  float = { border = 'none' },
})

-- Python
vim.lsp.config('pyright', {})

-- Lua
vim.lsp.config('lua_ls', {
  cmd = { "/home/doogan/lua-language-server/bin/lua-language-server" },
  settings = {
    Lua = {
      diagnostics = {
        globals = { 'vim' }
      }
    }
  }
})

vim.lsp.enable({ 'pyright', 'lua_ls' })
