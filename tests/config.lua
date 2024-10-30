-- https://www.reddit.com/r/neovim/comments/1cxsy0c/comment/l554j3t
local test_folder = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h")

-- Start the server
vim.lsp.start({
  name = "Nim LSP Test",
  cmd = {test_folder .. "/../" .. "nim_lsp_sdk"}
})

-- Just store the diagnostics, will will print them when asked
diagnostics = {}
vim.lsp.handlers["textDocument/publishDiagnostics"] = function (_, result, ctx, config)
  print(result.diagnostics)
end


-- Give server time to start-up, then load the tests
vim.defer_fn(function ()
  local curr_file = vim.api.nvim_buf_get_name(0)
  vim.cmd("source " .. curr_file:gsub(".nim", ".vim"))
end, 400)

-- Register commands to make writing tests easier

-- Prints diagnostics on the current line
vim.api.nvim_create_user_command("Diag", function (opts)
  print("getting called")
end, { })
