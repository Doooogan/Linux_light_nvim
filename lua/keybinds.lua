local keymap = vim.keymap.set

local opts = {silent = true}

keymap("","<Space>", "<Nop>", opts)
vim.g.mapleader = " "

keymap("n", "<S-l>", ":bnext<CR>", opts)
keymap("n", "<S-R>", ":bprevious<CR>", opts)


keymap("n", "<S-q>", "<cmd>Bdelete<CR>", opts)

keymap("n", "<leader>ff",":Telescope find_files<CR>", opts)
keymap("n", "<leader>ft",":Telescope live_grep<CR>", opts)
keymap("n", "<leader>fp",":Telescope projects<CR>", opts)
keymap("n", "<leader>fb",":Telescope buffers<CR>", opts)



keymap("i", "jj","<ESC>", opts)



keymap("n", "<leader>zf",":Telekasten find_notes<CR>", opts)
keymap("n", "<leader>zn",":Telekasten new_note<CR>", opts)
keymap("n", "<leader>zi",":Telekasten insert_link<CR>", opts)
keymap("n", "<leader>zd",":Telekasten find_daily_notes<CR>", opts)
keymap("n", "<leader>zg",":Telekasten search_notes<CR>", opts)
keymap("n", "<leader>z",":Telekasten panel<CR>", opts)
keymap("n", "<cr>",":Telekasten follow_link<CR>", opts)

