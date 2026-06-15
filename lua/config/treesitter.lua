
-- ~/.config/nvim/lua/config/treesitter.lua

--require('nvim-treesitter.configs').setup {
--  ensure_installed = { "lua", "bash", "python", "json" }, -- add what you use
--  highlight = {
--    enable = true,
--  },
--  indent = {
--    enable = true,
--  },
--}


require('nvim-treesitter').install({
  'lua', 'bash', 'python', 'json', 'markdown', 'vim', 'vimdoc', 'c', 'query',
  -- + whatever else you actually use
})

vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'lua','bash','python','json','markdown', 'vim', 'vimdoc', 'c', 'query',},
  callback = function()
    vim.treesitter.start()
    -- optional folds:
    -- vim.wo[0][0].foldexpr = 'v:lua.vim.treesitter.foldexpr()'
    -- vim.wo[0][0].foldmethod = 'expr'
  end,
})
