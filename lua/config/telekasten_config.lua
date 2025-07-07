
local M = {}

M.setup = function()
	print("Telekasten config loaded")
	local home = vim.fn.expand('~/zettelkasten')

	local telekasten = require("telekasten")

	telekasten.setup({
		home = home,
		take_over_my_home = true,
		auto_set_filetype = true,

		dailes = home .. '/' .. 'daily',
		weeklies = home .. '/' .. 'weekly',
		templates = home .. '/' .. 'templates',

		extension = '.md',

		new_note_filename = 'title-uuid',
		uuid_type = '%Y%m%d%H%M',
		uuid_sep = '-',

		follow_create_nonexisting = true,
		dalies_create_nonexisting = true,
		weeklies_create_nonexisting = true,

		journal_auto_open = false,

		template_new_note = home .. '/' .. 'templates/new_note.md',
		template_new_daily = home .. '/' .. 'templates/daily.md',
		template_new_weekly = home .. '/' .. 'templates/weekly.md',

		image_link_style = 'markdown',
		sort = 'filename',
		close_after_yanking = false,
		insert_after_inserting = true,

		tag_notation = ':tag:',

		command_palette_theme = 'ivy',
		show_tags_theme = 'ivy',
		subdirs_in_links = true,

		template_handling = 'smart',
		new_note_location = 'smart',
		rename_update_links = true,
		media_previewer = 'telescope-media-files',
		follow_url_fallback = nil,
	})

	local keymap = vim.keymap.set
	local opts = { silent = true }
	-- ============================================================================================
	-- Keybindings
	-- Telekasten Mappings
	keymap("n", "<leader>zf", ":Telekasten find_notes<CR>", opts)
	keymap("n", "<leader>zn", ":Telekasten new_note<CR>", opts)
	keymap("n", "<leader>zi", ":Telekasten insert_link<CR>", opts)
	keymap("n", "<leader>zd", ":Telekasten find_daily_notes<CR>", opts)
	keymap("n", "<leader>zw", ":Telekasten find_weekly_notes<CR>", opts)
	keymap("n", "<leader>zg", ":Telekasten search_notes<CR>", opts)
	keymap("n", "<leader>zt", ":Telekasten show_tags<CR>", opts)
	keymap("n", "<leader>z", ":Telekasten panel<CR>", opts)

	keymap("n", "<CR>", ":Telekasten follow_link<CR>", opts)

	keymap("n", "<leader>ztodo", function()
		vim.cmd("edit ~/zettelkasten/TODO-202505252336.md")
	end, { desc = "Open specific file" })

	keymap("n", "<leader>zh", function()
		vim.cmd("edit ~/zettelkasten/Homepage-202507061939.md")
	end, { desc = "Open specific file" })

	keymap("n", "<leader>td", function()
		local file = vim.fn.expand("%:p")
		vim.cmd("bdelete")
		vim.fn.delete(file)
	end, { desc = "Delete current Telekasten note" })

	keymap("n", "<leader>zpw", function()
		local template_path = vim.fn.expand("~/zettelkasten/Weekly Value Template-202505251830.md")
		local lines = vim.fn.readfile(template_path)
		vim.api.nvim_put(lines, "l", true, true)
	end, { desc = "Paste Weekly Value Template" })

	-- Go to next wikilink
	keymap("n", "<Tab>", function()
		if not vim.fn.search("\\[\\[.*\\]\\]", "W") then
			vim.notify("No next link", vim.log.levels.INFO, { title = "WikiJump" })
		end
	end, { silent = true, noremap = true })

	-- Go to previous wikilink
	keymap("n", "<S-Tab>", function()
		if not vim.fn.search("\\[\\[.*\\]\\]", "bW") then
			vim.notify("No previous link", vim.log.levels.INFO, { title = "WikiJump" })
		end
	end, { silent = true, noremap = true })

	-- Link following with enter, allowing to jump back with BS
	keymap("n", "<CR>", function()
		local row, col = unpack(vim.api.nvim_win_get_cursor(0))
		local line = vim.api.nvim_get_current_line()

		for start_idx, match in line:gmatch("()(%[%[.-%]%])") do
			local end_idx = start_idx + #match - 1
			if col >= start_idx - 1 and col <= end_idx then
				vim.cmd("normal! m'")
				telekasten.follow_link()
				return
			end
		end
	end, { noremap = true, silent = true })

	-- Going back with backspace
	keymap("n", "<BS>", "<C-o>", { noremap = true, silent = true })

	-- 
	--
	

	vim.keymap.set("n", "<leader>zr", function()
	  local notes = vim.fn.globpath(vim.fn.expand("~/zettelkasten"), "*.md", false, true)
	  local filtered = {}

	  for _, note in ipairs(notes) do
	    if not note:find("/daily/") and not note:find("/weekly/") then
	      table.insert(filtered, note)
	    end
	  end

	  if #filtered == 0 then
	    vim.notify("No non-daily/weekly notes found", vim.log.levels.WARN)
	    return
	  end
	  math.randomseed(os.time())
	  local random_index = math.random(#filtered)
	  vim.cmd("edit " .. filtered[random_index])
	end, { desc = "Open random Zettelkasten note (excluding dailies/weeklies)" })



	vim.keymap.set("n", "<leader>zd", function()
	  local file = vim.fn.expand("%:p")

	  -- Confirm it's a markdown file in your zettelkasten
	  if not file:match(vim.fn.expand("~/zettelkasten/") .. ".*%.md$") then
	    vim.notify("Not a Telekasten note", vim.log.levels.WARN)
	    return
	  end

	  local confirm = vim.fn.confirm("Delete this note?\n" .. file, "&Yes\n&No", 2)
	  if confirm ~= 1 then
	    return
	  end

	  -- Close the buffer and delete the file
	  vim.cmd("bdelete")
	  vim.fn.delete(file)
	  vim.notify("Note deleted", vim.log.levels.INFO)
	end, { desc = "Delete current Telekasten note" })




end

return M
