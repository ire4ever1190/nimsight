-- https://www.reddit.com/r/neovim/comments/1cxsy0c/comment/l554j3t
local test_folder = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h")
local custom_cmds = {}

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


function println(...)
  -- newlines get removed for some reason
  -- So use the unit separator
  print(select(1, ...))
  print("<====>")
end

-- Load the tests.
-- We create a coroutine so that we can have it wait on events.
-- Must be initially called when the server is initialised
cmds = coroutine.create(function ()
  local curr_file = vim.api.nvim_buf_get_name(0):gsub("%.nim", ".vim")
  local cmds_file = io.open(curr_file)
  if cmds_file == nil then
    println("Couldn't load", curr_file)
    return
  end
  for line in cmds_file:lines() do
    -- Check if we are waiting on an LSP message
    match = string.match(line, ":wait%s+(.+)")
    if match ~= nil then
      while coroutine.yield() ~= match do
      end
    else
      -- Just run the command
      local status, err = pcall(function () vim.cmd(line) end)
      if err then
        println(status, err)
      end
    end
  end
end)


function register_cmd(name, func, extra)
  local cmd_name = ":" .. name
  custom_cmds[cmd_name] = true
  local function wrapped(opts)
    func(opts)
    coroutine.resume(cmds, cmd_name)
  end
  vim.api.nvim_create_user_command(name, wrapped, extra)
end

vim.lsp.set_log_level("TRACE")
local config = {
  name = "Nim LSP Test",
  cmd = {test_folder .. "/../" .. "nim_lsp_sdk"}
}

config.on_init = function (client, results)
  println("Attaching", client.id)
  vim.lsp.buf_attach_client(0, client.id)

  -- Now run the tests
  coroutine.resume(cmds)
end
vim.lsp.start_client(config)

-- Returns true if the cursor is in a range
function in_range(range)
  local r, c = unpack(vim.api.nvim_win_get_cursor(0))
  r = r - 1
  local start_col = range["start"]["character"]
  local end_col = range["end"]["character"]
  local start_line  = range["start"]["line"]
  local end_line = range["end"]["line"]
  return (r == start_line and c >= start_col) or -- Start line
         (r == end_line and c < end_col) or -- Finish line
         (r > start_line and r < end_line) -- In-between
end


-- Function to add a listener for a method.
-- Calls the handler, then polls the
function listen_for(meth, handler)
  vim.lsp.handlers[meth] = function (idk, result, ctx, config)
    handler(idk, result, ctx, config)
    coroutine.resume(cmds, meth)
  end
end

-- Just store the diagnostics, will will print them when asked
diagnostics = {}
listen_for("textDocument/publishDiagnostics", function (idk, result, ctx, config)
  diagnostics = result.diagnostics
  vim.lsp.diagnostic.on_publish_diagnostics(idk, result, ctx, config)
end)

listen_for("textDocument/documentSymbol", function (_, result, _, config)
  for _, symbol in ipairs(result) do
    println(symbol["name"])
  end
end)


vim.lsp.handlers["window/logMessage"] = function (_, result, ctx, config)
  println(result["message"])
end


function get_diagnostics()
  local result = {}
  for _, diag in ipairs(diagnostics) do
    if in_range(diag["range"]) then
      result[#result + 1] = diag
    end
  end
  println(dump(result))
  return result
end

-- Register commands to make writing tests easier

-- Prints diagnostics on the current line
register_cmd("Diag", function (opts)
  for _, diag in ipairs(get_diagnostics()) do
    println(diag["message"])
  end
end, { })

-- Applies a code action
register_cmd("CodeAction", function (opts)
  local pos = vim.api.nvim_win_get_cursor(0)
  vim.lsp.buf.code_action({
    context = {
      diagnostics = get_diagnostics()
    },
    apply = true,
    range = {start = pos, ["end"] = pos}
  })
  coroutine.resume(cmds, "textDocument/codeAction")
end, {})

-- Saves the file in a knowable place
register_cmd("SaveTemp", function (opts)
  local curr_file = vim.api.nvim_buf_get_name(0):gsub("%.nim", ".out")
  vim.cmd(":w! " .. curr_file)
end, {})

register_cmd('Symbols', function (opts, continue)
  local args = { textDocument = vim.lsp.util.make_text_document_params() }
  vim.lsp.buf_request_all(0, "textDocument/documentSymbol", args, function (result)
    for _, symbol in ipairs(result[1]["result"]) do
      println(symbol["name"])
      if symbol["children"] ~= nil then
        for _, child in ipairs(symbol["children"]) do
          println(" - " .. child["name"])
        end
      end
    end
    coroutine.resume(cmds, "textDocument/documentSymbol")
  end)
end, {})

-- Poll when the buffer is modified
vim.api.nvim_create_autocmd('TextChanged', {
  callback = function(args)
    coroutine.resume(cmds, "TextChanged")
  end,
})

register_cmd("Shutdown", function (opts)
  vim.lsp.stop_client(vim.lsp.get_clients())
end, {})


