-- https://www.reddit.com/r/neovim/comments/1cxsy0c/comment/l554j3t
local test_folder = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h")

-- Load the tests.
-- We create a coroutine so that we can have it wait on events.
-- Very hacky, but I just wanted something working.
-- Must be initialled called when the server is initialised
cmds = coroutine.create(function ()
  local curr_file = vim.api.nvim_buf_get_name(0):gsub(".nim", ".vim")
  local cmds_file = io.open(curr_file)
  if cmds_file == nil then
    print("Couldn't load", curr_file)
    return
  end
  for line in cmds_file:lines() do
    -- Wait for a certain message to be sent
    print("Running", line)
    if line == ":diagnostics" then
      while coroutine.yield() ~= "diagnostics" do
      end
    else
      -- Just run the command
      vim.cmd(line)
    end
  end
end)

vim.lsp.set_log_level("TRACE")
local config = {
  name = "Nim LSP Test",
  cmd = {test_folder .. "/../" .. "nim_lsp_sdk"}
}

config.on_init = function (client, results)
  print("Attaching", client.id)
  vim.lsp.buf_attach_client(0, client.id)

  -- Now run the tests
  coroutine.resume(cmds)
end
vim.lsp.start_client(config)

function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end


-- Just store the diagnostics, will will print them when asked
diagnostics = {}
vim.lsp.handlers["textDocument/publishDiagnostics"] = function (_, result, ctx, config)
  print(dump(result.diagnostics))
  coroutine.resume(cmds, "diagnostics")
end

vim.lsp.handlers["window/logMessage"] = function (_, result, ctx, config)
  print(result["message"])
end


-- Register commands to make writing tests easier

-- Prints diagnostics on the current line
vim.api.nvim_create_user_command("Diag", function (opts)
  print("getting called\n")
end, { })
