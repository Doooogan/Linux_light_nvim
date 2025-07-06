
-- ~/.config/nvim/lua/config/treesitter.lua

require('nvim-treesitter.configs').setup {
  ensure_installed = { "lua", "bash", "python", "json" }, -- add what you use
  highlight = {
    enable = true,
  },
  indent = {
    enable = true,
  },
}
