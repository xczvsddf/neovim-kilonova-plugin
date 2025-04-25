local curl = require('plenary.curl')
local M = {}

-- Configuration
M.config = {
  session_id = nil,
  problem_id = nil,
  base_url = "https://kilonova.ro/api",
  poll_interval = 2,
  window = {
    width = 0.8,
    height = 0.6,
  }
}

-- State
local submission_data = nil
local results_window = nil
local poll_timer = nil

local function get_plugin_dir()
  local plugin_path = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(plugin_path, ":h")
end

local function url_encode(str)
  if str then
    str = string.gsub(str, "\n", "\r\n")
    str = string.gsub(str, "([^%w _%%%-%.~])", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
    str = string.gsub(str, " ", "+")
  end
  return str
end

local function read_creds()
  local creds_path = get_plugin_dir() .. "/creds.txt"
  local file = io.open(creds_path, "r")
  if not file then
    vim.notify("creds.txt not found in plugin directory: " .. creds_path)
    return nil
  end
  local username = file:read("*l")
  local password = file:read("*l")
  file:close()
  if not username or not password then
    vim.notify("creds.txt is malformed - first line should be username, second line password")
    return nil
  end
  return { username = username, password = password }
end

local function login(callback)
  local creds = read_creds()
  if not creds then return end

  local username_encoded = url_encode(creds.username)
  local password_encoded = url_encode(creds.password)
  local url = string.format("%s/auth/login?username=%s&password=%s", 
    M.config.base_url, username_encoded, password_encoded)

  curl.post(url, {
    callback = function(response)
      if response.status ~= 200 then
        vim.schedule(function()
          vim.notify("Login failed: " .. (response.body or "no response"))
        end)
        return
      end
      
      local ok, data = pcall(vim.json.decode, response.body)
      if not ok then
        vim.schedule(function()
          vim.notify("Failed to parse login response: " .. data)
        end)
        return
      end
      
      M.config.session_id = data.data
      vim.schedule(callback)
    end
  })
end

local function create_results_window()
  if results_window and vim.api.nvim_win_is_valid(results_window) then
    vim.api.nvim_win_close(results_window, true)
  end

  local width = math.floor(vim.o.columns * M.config.window.width)
  local height = math.floor(vim.o.lines * M.config.window.height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  results_window = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded'
  })
  -- Make buffer non-editable
  vim.api.nvim_buf_set_option(buf, 'readonly', true)
  return buf
end

local function render_results(data)
  local buf = create_results_window()
  local lines = {}
  -- Header
  table.insert(lines, string.format("Submission #%d - %s", data.id, data.status))
  table.insert(lines, string.format("Score: %d/%d", data.score, data.problem.score_scale))
  table.insert(lines, "")
  
  -- Tests
  for _, test in ipairs(data.subtests) do
    local icon = test.percentage == 100 and "✅" or "❌"
    local line = string.format("%s Test %d: %s (%.3fs, %dKB)",
      icon, test.visible_id, test.verdict, test.time, test.memory)
    table.insert(lines, line)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  
  -- Set highlights
  vim.api.nvim_buf_add_highlight(buf, -1, "DiffAdd", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, -1, "DiffDelete", 1, 0, -1)
end

local handle_poll_response

local function poll_submission(submission_id)
  local url = string.format("%s/submissions/getByID?id=%d", M.config.base_url, submission_id)
  curl.get(url, {
    headers = {
      Authorization = M.config.session_id,
    },
    callback = handle_poll_response
  })
end

handle_poll_response = function (response)
  if response.status ~= 200 then
    vim.schedule(function()
      vim.notify("Failed to get submission status: " .. (response.body or "no response"))
    end)
    return
  end
  
  local ok, data = pcall(vim.json.decode, response.body)
  if not ok then
    vim.schedule(function()
      vim.notify("Failed to parse response: " .. data)
    end)
    return
  end
  if data.data.status ~= "finished" then
    poll_timer = vim.defer_fn(function()
      poll_submission(data.data.id)
    end, M.config.poll_interval * 1000)
  else
    vim.schedule(function()
      render_results(data.data)
    end)
    poll_timer = nil
  end
end

function M.submit_code(problem_id_arg)
  if poll_timer then
    vim.fn.timer_stop(poll_timer)
    poll_timer = nil
  end

  local problem_id = tonumber(problem_id_arg)
  if not problem_id then
    vim.notify("Problem ID must be a number")
    return
  end
  M.config.problem_id = problem_id

  local function do_submit()
    local code = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    local boundary = "----WebKitFormBoundary" .. os.time()
    local body = ""
    
    body = body .. "--" .. boundary .. "\r\n"
    body = body .. 'Content-Disposition: form-data; name="problem_id"\r\n\r\n'
    body = body .. M.config.problem_id .. "\r\n"
    
    body = body .. "--" .. boundary .. "\r\n"
    body = body .. 'Content-Disposition: form-data; name="language"\r\n\r\n'
    body = body .. "cpp17\r\n"
    
    body = body .. "--" .. boundary .. "\r\n"
    body = body .. 'Content-Disposition: form-data; name="code"; filename="code"\r\n'
    body = body .. "Content-Type: text/plain;charset=utf-8\r\n\r\n"
    body = body .. code .. "\r\n"
    body = body .. "--" .. boundary .. "--\r\n"

    curl.post(M.config.base_url .. "/submissions/submit", {
      body = body,
      headers = {
        Authorization = M.config.session_id,
        ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
        ["Content-Length"] = tostring(#body)
      },
      callback = function(response)
        if response.status ~= 200 then
          vim.schedule(function()
            vim.notify("Submission failed: " .. (response.body or "no response"))
          end)
          return
        end
        
        local ok, data = pcall(vim.json.decode, response.body)
        if not ok then
          vim.schedule(function()
            vim.notify("Failed to parse submission response: " .. data)
          end)
          return
        end
        
        vim.schedule(function()
          vim.notify("Submission started! ID: " .. data.data)
        end)
        poll_submission(data.data)
      end
    })
  end

  if M.config.session_id then
    do_submit()
  else
    login(function()
      do_submit()
    end)
  end
end

-- Setup commands
vim.api.nvim_create_user_command("KnsSubmit", function(opts)
  M.submit_code(opts.args)
end, {
  nargs = 1,
  desc = "Submit current buffer to Kilonova problem",
})

return M
