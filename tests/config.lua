-- https://www.reddit.com/r/neovim/comments/1cxsy0c/comment/l554j3t
local test_folder = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h")

-- Load the tests.
-- We create a coroutine so that we can have it wait on events.
-- Very hacky, but I just wanted something working.
-- Must be initialled called when the server is initialised
cmds = coroutine.create(function ()
  local curr_file = vim.api.nvim_buf_get_name(0):gsub("%.nim", ".vim")
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

-- Returns true if the cursor is in a range
function in_range(range)
  local r, c = unpack(vim.api.nvim_win_get_cursor(0))
  r = r - 1
  local start_col = range["start"]["character"]
  local end_col = range["end"]["character"]
  local start_line  = range["start"]["line"]
  local end_line = range["end"]["line"]
  print("(    ", start_line, ":", start_col, ", ", end_line, ":", end_col , "   )")
  return (r == start_line and c >= start_col) or -- Start line
         (r == end_line and c < end_col) or -- Finish line
         (r > start_line and r < end_line) -- In-between
end

-- Just store the diagnostics, will will print them when asked
diagnostics = {}
vim.lsp.handlers["textDocument/publishDiagnostics"] = function (_, result, ctx, config)
  diagnostics = result.diagnostics
  coroutine.resume(cmds, "diagnostics")
end

vim.lsp.handlers["window/logMessage"] = function (_, result, ctx, config)
  print(result["message"])
end


-- Register commands to make writing tests easier

-- Prints diagnostics on the current line
vim.api.nvim_create_user_command("Diag", function (opts)
  for _, diag in ipairs(diagnostics) do
    if in_range(diag["range"]) then
      print(diag["message"])
    end
  end
end, { })
