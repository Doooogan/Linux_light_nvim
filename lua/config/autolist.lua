
local autolist = require("autolist")
autolist.setup()

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "text", "norg", "telekasten" },
  callback = function()
    local opts = { buffer = true, silent = true }

    vim.keymap.set("i", "<tab>", "<cmd>AutolistTab<cr>", opts)
    vim.keymap.set("i", "<s-tab>", "<cmd>AutolistShiftTab<cr>", opts)
    vim.keymap.set("i", "<CR>", "<CR><cmd>AutolistNewBullet<cr>")
    vim.keymap.set("n", "o", "o<cmd>AutolistNewBullet<cr>", opts)
    vim.keymap.set("n", "O", "O<cmd>AutolistNewBulletBefore<cr>", opts)

    --vim.keymap.set("n", "<leader>d", "0f[di[ix<esc>0", opts)


    vim.keymap.set("n", "<leader>d", "<cmd>AutolistToggleCheckbox<cr><CR>", opts)
    --vim.keymap.set("n", "<C-r>", "<cmd>AutolistRecalculate<cr>", opts)

    vim.keymap.set("n", ">>", ">><cmd>AutolistRecalculate<cr>", opts)
    vim.keymap.set("n", "<<", "<<<cmd>AutolistRecalculate<cr>", opts)
    vim.keymap.set("n", "dd", "dd<cmd>AutolistRecalculate<cr>", opts)
    vim.keymap.set("v", "d", "d<cmd>AutolistRecalculate<cr>", opts)

    -- Optional: cycle list styles
    vim.keymap.set("n", "<leader>cn", require("autolist").cycle_next_dr, { expr = true, buffer = true })
    vim.keymap.set("n", "<leader>cp", require("autolist").cycle_prev_dr, { expr = true, buffer = true })

    vim.keymap.set("n", "<leader>b", function()
      local line = vim.api.nvim_get_current_line()
      local bullet_pattern = "^(%s*)([-*+])%s+"
      local checkbox_pattern = "^(%s*)([-*+])%s+%[.%]%s+"
    
      if line:match(bullet_pattern) and not line:match(checkbox_pattern) then
        local new_line = line:gsub(bullet_pattern, "%1%2 [ ] ")
        vim.api.nvim_set_current_line(new_line)
      end
    end, { desc = "Convert bullet to checkbox" })
  end,
})
