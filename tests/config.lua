-- Start the server
vim.lsp.start({
  name = "Nim LSP Test",
  cmd = {"../nim_lsp_sdk"}
})


-- Give server time to start-up, then load the tests
vim.defer_fn(function ()
  local curr_file = vim.api.nvim_buf_get_name(0)
  vim.cmd("source " .. curr_file:gsub(".nim", ".vim"))
end, 400)

