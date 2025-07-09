
local M = {}

function M.create_note_from_visual()
  vim.cmd('normal! "zy') -- Yank visual selection
  local selection = vim.fn.getreg('z')

  local original_input = vim.ui.input
  vim.ui.input = function(opts, on_confirm)
    vim.ui.input = original_input
    on_confirm(selection)
  end

  vim.cmd('Telekasten new_note')

  vim.defer_fn(function()
    -- Step 1: Yank note link with <C-y>
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes('<C-y>', true, false, true),
      't', false
    )

    -- Step 2: Press <Esc> twice
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes('<Esc>', true, false, true),
      't', false
    )
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes('<Esc>', true, false, true),
      't', false
    )
    -- Reselect and paste over original selection
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("`[v`]p", true, false, true),
      'n', false
    )
  end, 100)
end

return M
