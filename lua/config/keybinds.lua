local keymap = vim.keymap.set
local telekasten = require("telekasten")

local opts = {silent = true}

vim.opt.wrap = true
vim.opt.linebreak = true


vim.o.mouse = ""
keymap("","<Space>", "<Nop>", opts)
vim.g.mapleader = " "

keymap("n", "<S-l>", ":bnext<CR>", opts)
keymap("n", "<S-h>", ":bprevious<CR>", opts)
keymap("n", "<backspace>", ":bprevious<CR>", opts)


keymap("n", "<S-q>", "<cmd>Bdelete<CR>", opts)

keymap("n", ";", ":", { noremap = true })



vim.keymap.set("n", "<leader>cfg", function()
  vim.cmd("cd ~/.config/nvim")
  print("PWD set to ~/.config/nvim")

end, { desc = "Set PWD to Neovim config folder" })




keymap('n', 'gd', vim.lsp.buf.definition, opts)

keymap('n', '<C-s>', '<C-w>v', { desc = 'Open vertical split' })
-- Telescope Mapping
keymap("n", "<leader>ff",":Telescope find_files<CR>", opts)
keymap("n", "<leader>fg",":Telescope live_grep<CR>", opts)
keymap("n", "<leader>fp",":Telescope projects<CR>", opts)
keymap("n", "<leader>fb",":Telescope buffers<CR>", opts)


-- Markdown Preview Mapping
keymap("n", "<leader>mp", "<cmd>MarkdownPreview<CR>", { desc = "Markdown Preview" })
keymap("n", "<leader>ms", "<cmd>MarkdownPreviewStop<CR>", { desc = "Stop Preview" })


-- Save and Quit
keymap("n", "<leader>w",":w<CR>", opts)
keymap("n", "<leader>q",":q<CR>", opts)

-- Exit Insert mode
keymap("i", "jj","<ESC>", opts)



-- Yanking filepath to register
vim.keymap.set("n", "<leader>yp", function()
  local path = vim.fn.expand("%:p")
  vim.fn.setreg('"', path)  -- sets the unnamed register (default yank target)
  vim.notify("Yanked path: " .. path)
end, { desc = "Yank full file path to unnamed register" })


vim.keymap.set("n", "<C-h>", "<C-w>h", { noremap = true, silent = true })
vim.keymap.set("n", "<C-l>", "<C-w>l", { noremap = true, silent = true })



vim.keymap.set("n", "<leader>bda", function()
  local current = vim.api.nvim_get_current_buf()

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and buf ~= current then
      local modified = vim.api.nvim_buf_get_option(buf, "modified")
      local readonly = vim.api.nvim_buf_get_option(buf, "readonly")

      -- Skip unsaved or readonly buffers
      if not modified and not readonly then
        vim.api.nvim_buf_delete(buf, { force = false })
      end
    end
  end

  vim.notify("Closed all **unmodified** buffers except current", vim.log.levels.INFO)
end, { noremap = true, silent = true, desc = "Delete all unmodified buffers but current" })




vim.keymap.set("n", "<leader>zo", function()
  require("config.zk_utils").insert_orphan_links_by_tag()
end, { desc = "List true orphan notes for a :tag:" })
