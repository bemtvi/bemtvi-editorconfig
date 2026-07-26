# Notes

Prose, not code. The FileType handler in `init.lua` sets
`vim.b[buf].editorconfig = false` for markdown, so the project's
`indent_size = 4` does NOT apply to this buffer.

- Type `i<Tab>x<Esc>` here and you get whatever your own defaults say,
  not the four spaces `app.py` gets.
