local home = vim.fn.expand('~/zettelkasten')

require('telekasten').setup({
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

	template_new_note = home ..'/' .. 'templates/new_note.md',
	template_new_daily = home ..'/' .. 'templates/daily.md',
	template_new_weekly = home ..'/' .. 'templates/weekly.md',

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
