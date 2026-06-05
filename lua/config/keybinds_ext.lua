-- This multiplies the current line by 1% to get the next workout parameter
vim.keymap.set('n', '<leader>hs', function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()

  -- Parse the current row's cells: split on | and trim
  local cells = {}
  for cell in line:gmatch('|([^|]*)') do
    table.insert(cells, cell:match('^%s*(.-)%s*$'))
  end

  if #cells < 2 then
    vim.notify('Not on a table row', vim.log.levels.WARN)
    return
  end

  local time = tonumber(cells[1])
  if not time then
    vim.notify('Time cell is not numeric: ' .. tostring(cells[1]), vim.log.levels.WARN)
    return
  end
  local new_time = string.format('%.1f', time * 1.01)

  local date = os.date('%-m/%-d/%y')

  local new_cells = { new_time, date }
  for i = 3, #cells do
    new_cells[i] = ''
  end

  local new_line = '| ' .. table.concat(new_cells, ' | ')

  vim.api.nvim_buf_set_lines(0, row, row, false, { new_line })
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })

  vim.cmd('TableModeRealign')
end, { desc = 'New table row: today + 1% time' })
