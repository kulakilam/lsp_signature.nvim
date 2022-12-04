-- nvim对外暴露了api，给插件、rpc、lua、vimL使用
-- 查看:h API
local api = vim.api
local fn = vim.fn
-- 声明一个对象
local M = {}
-- 加载隔壁的helper模块
-- aa.bb这种格式是nvim自己定义的，会去找lua/aa/bb.lua或者lua/aa/bb/init.lua
-- 详见:h lua-require
local helper = require("lsp_signature.helper")
-- 用于找到活跃的signature
local match_parameter = helper.match_parameter
-- local check_closer_char = helper.check_closer_char

-- 好像只是一个中间过程的变量，没有被直接用到
local status_line = { hint = "", label = "" }
-- 看起来是一些flag的管理器
local manager = {
  -- neovim支持的所有事件可以看:h events，或者看neovim源码的src/nvim/auevents.lua，目前有123个
  -- 跟InsertCharPre事件相关的flag，具体看:h
  -- InsertCharPre，开启后会在每键入一个字符时都会触发这个事件，可能会影响性能
  insertChar = false, -- flag for InsertCharPre event, turn off imediately when performing completion
  -- InsertLeave事件，从insert模式离开的时候会触发
  insertLeave = true, -- flag for InsertLeave, prevent every completion if true
  -- 改动次数的计数器，具体可以看:h changetick
  changedTick = 0, -- handle changeTick
  -- 手动进行补全的comfirm操作
  confirmedCompletion = false, -- flag for manual confirmation of completion
  -- 定时器
  timer = nil,
}
-- 路径分割符，如果是windows系统用'\\'，其他用'/'
-- vim.loop.os_uname()可以查看:h uv.os_uname()
-- loop是指libuv的时间循环机制，libuv是neovim引入的，老vim不支持
-- 从帮助文档中可以看到，除了提供时间循环相关的功能，uv还提供其他的能力，
-- 比如获取系统名称、路径相关、进程相关、内存、cpu等等
local path_sep = vim.loop.os_uname().sysname == "Windows" and "\\" or "/"

-- 传参个数不限制，功能是把传入的参数通过路径分隔符拼接起来
local function path_join(...)
  return table.concat(vim.tbl_flatten({ ... }), path_sep)
end
-- 跟LSP signature相关的配置
-- 下划线开头的变量根据http://lua-users.org/wiki/LuaStyleGuide这里的说明，似乎
-- 是个不重要的变量，但是这个变量实际上被频繁用到
-- 这里是个全局变量，在调用helper.log时，在里面可以直接用，而不需要传参
-- 可以在init.vim中对这里面的key进行配置
_LSP_SIG_CFG = {
  bind = true, -- This is mandatory, otherwise border config won't get registered.
  -- 显示文档的行数，如果设置成0，则不显示，只显示signature
  -- 这里的文档不是指cmp的预览doc，也不是按下K的doc，而是本插件提供一个signature_help上
  -- 的doc，如果没有doc则只显示函数名、参数、当前第几个参数等信息，如果有doc会显示在下面
  doc_lines = 10, -- how many lines to show in doc, set to 0 if you only want the signature
  -- signature_help的floating window最大的高度
  max_height = 12, -- max height of signature floating_window
  -- signature_help的floating window最大的高度
  max_width = 80, -- max_width of signature floating_window
  -- floating window中的signature_help或者doc是否换行
  wrap = true, -- allow doc/signature wrap inside floating_window, useful if your lsp doc/sig is too long

  -- 是指是否显示signature_help，如果false则整个完全没了
  floating_window = true, -- show hint in a floating window
  -- 把window放到当前行上方
  floating_window_above_cur_line = true, -- try to place the floating above the current line

  -- 调整window的x坐标，横向上
  -- 但是这个不是直接用，会加上一个值
  floating_window_off_x = 1, -- adjust float windows x position.
  -- 调整window的y坐标，纵向上
  floating_window_off_y = 0, -- adjust float windows y position. e.g. set to -2 can make floating window move up 2 lines
  -- 当参数都输入完之后，多久会自动关闭window
  -- 这里如果要复现的话，注意输入完之后，光标不要放在最后一个参数上，可以移动到括号之后
  -- 但是没有找到这个变量被用到的地方
  close_timeout = 4000, -- close floating window after ms when laster parameter is entered
  -- 不知道这是干嘛的
  fix_pos = function(signatures, client) -- first arg: second argument is the client
    _, _ = signatures, client
    return true -- can be expression like : return signatures[1].activeParameter >= 0 and signatures[1].parameters > 1
  end,
  -- also can be bool value fix floating_window position

  -- 开启hint
  hint_enable = true, -- virtual hint
  -- hint前缀
  hint_prefix = "🐼 ",
  -- 不知道有没有别的scheme类型
  hint_scheme = "String",
  -- LSP里定义的高亮
  -- 其他类型可以查看:h lsp-highlight
  hi_parameter = "LspSignatureActiveParameter",
  -- lsp的handlers目前有两种，一种是hover（按K的文档），一种是signature_help
  -- 传递的参数是配置border
  handler_opts = { border = "rounded" },
  cursorhold_update = true, -- if cursorhold slows down the completion, set to false to disable it
  -- signature左右两侧的间隙填充字符，但是我加了这个配置后会报错
  padding = "", -- character to pad on left and right of signature
  always_trigger = false, -- sometime show signature on new line can be confusing, set it to false for #58
  -- set this to true if you the triggered_chars failed to work
  -- this will allow lsp server decide show signature or not
  auto_close_after = nil, -- autoclose signature after x sec, disabled if nil.
  check_completion_visible = true, -- adjust position of signature window relative to completion popup
  -- debug开关，跟日志打印有关
  debug = false,
  log_path = path_join(vim.fn.stdpath("cache"), "lsp_signature.log"), -- log dir when debug is no
  verbose = false, -- debug show code line number
  extra_trigger_chars = {}, -- Array of extra characters that will trigger signature completion, e.g., {"(", ","}
  -- 具体可以看:h nvim_open_win()，跟css中一样，越大就显示在前面
  -- 另外nvim有几个自己hard-coded的zindex，分别是100、200、250，具体可以看帮助文档
  zindex = 200,
  transparency = nil, -- disabled by default
  shadow_blend = 36, -- if you using shadow as border use this set the opacity
  shadow_guibg = "Black", -- if you using shadow as border use this set the color e.g. 'Green' or '#121315'
  timer_interval = 200, -- default timer check interval
  toggle_key = nil, -- toggle signature on and off in insert mode,  e.g. '<M-x>'
  -- set this key also helps if you want see signature in newline
  select_signature_key = nil, -- cycle to next signature, e.g. '<M-n>' function overloading
  -- internal vars, init here to suppress linter warings
  move_cursor_key = nil, -- use nvim_set_current_win

  --- private vars
  -- 这种私有变量放在cfg变量中，不合适吧
  -- 在代码中还会看到其他变量也塞进_LSP_SIG_CFG
  winnr = nil,
  bufnr = 0,
  mainwin = 0,
}

-- 加载log方法
local log = helper.log
-- 初始化manager，每次进入insert模式前会调用
function manager.init()
  manager.insertLeave = false
  manager.insertChar = false
  manager.confirmedCompletion = false
end

-- 显示hint的逻辑
-- 触发时机：应该在lsp那边有signature_help的时候才触发
-- 参数：hint，一个字符串，要显示的hint内容
-- 参数：off_y，列坐标的偏移位置
local function virtual_hint(hint, off_y)
  -- hint为空或者不存在，则直接返回
  if hint == nil or hint == "" then
    return
  end
  local dwidth = fn.strdisplaywidth
  -- 获取当前光标的位置，行坐标是从1开始，列坐标是从0开始
  local r = vim.api.nvim_win_get_cursor(0)
  -- 获取当前光标所在行的buffer内容
  local line = api.nvim_get_current_line()
  -- 获取当前光标所在行光标之前的内容，光标后面的会被截掉
  local line_to_cursor = line:sub(1, r[2])
  -- 获取行号，从0开始
  local cur_line = r[1] - 1 -- line number of current line, 0 based
  -- hint显示行位置，在当前行上方
  local show_at = cur_line - 1 -- show at above line
  -- 当前window，光标之上有多少行
  local lines_above = vim.fn.winline() - 1
  -- 当前window，光标之下有多少行，包含光标所在行
  local lines_below = vim.fn.winheight(0) - lines_above
  -- 当上面的行数超过一半时，显示在光标下一行
  if lines_above > lines_below then
    show_at = cur_line + 1 -- same line
  end
  -- 应该不是previous line的缩写，因为pl表示的是hint要显示的行的buffer内容
  local pl
  -- 看当前是否有补全的menu显示，包括cmp的和内置ctrl-p的补全
  local completion_visible = helper.completion_visible()
  -- 当off_y小于0时，如果补全menu可见，则hint显示在当前行，否则显示在下一行
  -- 但目前off_y传参是hardcode为0，所以不会进入这个逻辑内
  if off_y ~= nil and off_y < 0 then -- floating win above first
    if completion_visible then
      show_at = cur_line -- pum, show at current line
    else
      show_at = cur_line - 1 -- show at below line
    end
  end

  if off_y ~= nil and off_y > 0 then
    if completion_visible then
      show_at = cur_line -- pum, show at current line
    else
      show_at = cur_line + 1 -- show at below line
    end
  end

  -- 当signature_help整个不显示，显示hint的逻辑
  -- 优先级：上一行 > 下一行 > 当前行
  if _LSP_SIG_CFG.floating_window == false then
    -- 光标的上一行和下一行内容
    local prev_line, next_line
    -- 当cur_line=0时，也就是第一行，没有上一行
    if cur_line > 0 then
      prev_line = vim.api.nvim_buf_get_lines(0, cur_line - 1, cur_line, false)[1]
    end
    next_line = vim.api.nvim_buf_get_lines(0, cur_line + 1, cur_line + 2, false)[1]
    -- 上一行宽度如果比当前光标的列坐标还要小，则显示在上一行
    -- 也就是说，hint如果要显示在上一行，不能挡住上一行的内容，应显示在后面空白处
    -- @todo：这里有个bug，当光标离离窗口右边的border很近时，hint会显示不全
    if prev_line and vim.fn.strdisplaywidth(prev_line) < r[2] then
      show_at = cur_line - 1
      pl = prev_line
    elseif next_line and dwidth(next_line) < r[2] + 2 and not completion_visible then
    -- 同理，如果下一行的宽度只比当前光标的列坐标大2个宽度，则显示在下一行
    -- 注意：这里跟上一行的区别是2个宽度（不知道为啥），且没有补全的menu
    -- @todo：这里有个bug，当按下ctrl-p显示popupmenu补全时，hint会被遮挡
    --        不过这个问题可能不好修复，因为这个插件是先感知menu是否存在，再决定hint显示的行为
    --        但是如果hint显示之后，menu的变化是感知不到的
    elseif next_line and vim.fn.strdisplaywidth(next_line) < r[2] + 2 and not completion_visible then
      show_at = cur_line + 1
      pl = next_line
    -- 其他情况就显示在当前行
    else
      show_at = cur_line
    end

    log("virtual text only :", prev_line, next_line, r, show_at, pl)
  end

  -- 如果是在第一行，则显示在当前行
  if cur_line == 0 then
    show_at = 0
  end
  -- get show at line
  -- 如果pl是空的，则获取hint要显示的行的buffer内容
  if not pl then
    pl = vim.api.nvim_buf_get_lines(0, show_at, show_at + 1, false)[1]
  end
  -- 如果show_at是在最后一行+1，这时候buffer内容会返回nil，已经没有下一行了
  -- 所以show_at只能又切换回当前行
  if pl == nil then
    show_at = cur_line -- no lines below
  end
  pl = pl or ""
  local pad = ""
  local line_to_cursor_width = dwidth(line_to_cursor)
  local pl_width = dwidth(pl)
  -- 如果hint不在当前行，且光标超过了显示行的宽度，则通过pad来让hint跟光标对齐
  if show_at ~= cur_line and line_to_cursor_width > pl_width + 1 then
    pad = string.rep(" ", line_to_cursor_width - pl_width)
    local width = vim.api.nvim_win_get_width(0)
    local hint_width = dwidth(_LSP_SIG_CFG.hint_prefix .. hint)
    -- todo: 6 is width of sign+linenumber column
    if #pad + pl_width + hint_width + 6 > width then
      pad = string.rep(" ", math.max(1, line_to_cursor_width - pl_width - hint_width - 6))
    end
  end
  -- NS表示namespace，在neovim中namespace用于高亮和virtual text，后者就是这里的hint
  _LSP_SIG_VT_NS = _LSP_SIG_VT_NS or vim.api.nvim_create_namespace("lsp_signature_vt")

  -- 显示前先刷掉之前的virtual text
  helper.cleanup(false) -- cleanup extmark

  -- virt_text，详见:h nvim_buf_set_extmark下面的opts参数中的virt_text
  -- 是一个[text, highlight]二元组，所以这里的hint_scheme似乎是一个高亮的组
  -- 因为hint_scheme默认是String，所以高亮颜色跟代码中的字符串一样
  local vt = { pad .. _LSP_SIG_CFG.hint_prefix .. hint, _LSP_SIG_CFG.hint_scheme }

  log("virtual text: ", cur_line, show_at, vt)
  if r ~= nil then
    -- 开启显示
    vim.api.nvim_buf_set_extmark(0, _LSP_SIG_VT_NS, show_at, 0, {
      virt_text = { vt },
      -- 显示在eol字符之后
      virt_text_pos = "eol",
      hl_mode = "combine",
      -- hl_group = _LSP_SIG_CFG.hint_scheme
    })
  end
end

-- 四种事件会触发signature_help和hint关闭
-- 分别是：光标在normal和insert模式下的移动、buffer隐藏、输入字符
-- 输入字符触发关闭，然后如果有新的会重新显示
local close_events = { "CursorMoved", "CursorMovedI", "BufHidden", "InsertCharPre" }

-- ----------------------
-- --  signature help  --
-- ----------------------
-- Note: nvim 0.5.1/0.6.x   - signature_help(err, {result}, {ctx}, {config})

-- handler相关文档可以查看:h lsp-handler，介绍了怎么用，这四个参数的意思
local signature_handler = function(err, result, ctx, config)
  log("signature handler")
  -- 这个err是lsp server传过来的，如果不为nil表示lsp遇到了问题
  if err ~= nil then
    print(err)
    return
  end

  -- log("sig result", ctx, result, config)
  -- if config.check_client_handlers then
  --   -- this feature will be removed
  --   if helper.client_handler(err, result, ctx, config) then
  --     return
  --   end
  -- end

  -- lsp client的id
  local client_id = ctx.client_id
  -- buffer的number，跟:ls 的数字是相同的，0表示当前buffer
  local bufnr = ctx.bufnr
  -- 这个result是lsp server传过来的
  -- 如果lsp server返回的result中没有signature，需要关闭floating window(即signature_help)
  -- 和virtual text(即hint)
  if result == nil or result.signatures == nil or result.signatures[1] == nil then
    -- only close if this client opened the signature
    log("no valid signatures", result)

    status_line = { hint = "", label = "" }
    if _LSP_SIG_CFG.client_id == client_id then
      helper.cleanup_async(true, 0.2, true)
      -- need to close floating window and virtual text (if they are active)
    end

    return
  end
  -- 如果当前所在的buffer跟lsp返回的buffer不是同一个，则忽略
  if api.nvim_get_current_buf() ~= bufnr then
    log("ignore outdated signature result")
    return
  end

  if config.trigger_from_next_sig then
    log("trigger from next sig", config.activeSignature)
  end

  if config.trigger_from_next_sig then
    -- 如果返回的signature个数超过1个，函数重载的情况
    if #result.signatures > 1 then
      -- 不知道这一步什么意思
      -- 实现的逻辑是把result.signatures前面cnt个元素放到末尾去
      local cnt = math.abs(config.activeSignature - result.activeSignature)
      for _ = 1, cnt do
        local m = result.signatures[1]
        table.insert(result.signatures, #result.signatures + 1, m)
        table.remove(result.signatures, 1)
      end
      result.cfgActiveSignature = config.activeSignature
    end
  else
    result.cfgActiveSignature = 0 -- reset
  end
  log("sig result", ctx, result, config)
  _LSP_SIG_CFG.signature_result = result

  -- 到目前位置result.activeSignature是没有被修改过的(也不应该被修改，好的代码习惯)，
  -- 都是从lsp server过来的
  local activeSignature = result.activeSignature or 0
  -- 这里加1的原因是lsp server返回的0-based的索引，而在lua里index是从1开始的
  activeSignature = activeSignature + 1
  -- 避免越界
  if activeSignature > #result.signatures then
    -- this is a upstream bug of metals
    activeSignature = #result.signatures
  end

  -- result的结构如下
  -- {
  --   activeParameter = 1,
  --   activeSignature = 0,
  --   cfgActiveSignature = 0, -- 这个是上面的代码加入的，不是lsp返回的
  --   signatures =
  --   {
  --     {
  --       documentation = "Returns void",
  --       label = "addNumber(int a, int b) -> void",
  --       parameters =
  --       {
  --         { label = { 10, 15 } }, -- 数字表示函数中参数的字符位置范围
  --         { label = { 17, 22 } },
  --       }
  --     }
  --   }
  -- }

  local actSig = result.signatures[activeSignature]

  if actSig == nil then
    log("no valid signature, or invalid response", result)
    print("no valid signature or incorrect lsp reponse ", vim.inspect(result))
    return
  end

  -- label format and trim
  -- 把字符串中的\n\r\t替换成空格
  -- 这里的label应该就是指floating window里展示的内容，不包括doc
  -- floating window会展示两部分内容，label和doc
  actSig.label = string.gsub(actSig.label, "[\n\r\t]", " ")
  -- 遍历parameters里的label，如果是字符串，也替换\n\r\t
  -- 不过从上面那个例子来看，label也可能是一个数字的数组
  if actSig.parameters then
    for i = 1, #actSig.parameters do
      if type(actSig.parameters[i].label) == "string" then
        actSig.parameters[i].label = string.gsub(actSig.parameters[i].label, "[\n\r\t]", " ")
      end
    end
  end

  -- if multiple signatures existed, find the best match and correct parameter
  -- 当函数中存在多个参数时，找到当前匹配的那个
  -- 这里的hint是指参数的字符串，比如'int num'
  -- s表示参数的起始位置，l表示结束位置
  local _, hint, s, l = match_parameter(result, config)
  local force_redraw = false
  if #result.signatures > 1 then
    -- 跟signature的个数有啥关系？
    force_redraw = true
    for i = #result.signatures, 1, -1 do
      local sig = result.signatures[i]
      -- hack for lua
      -- 从上面的例子看，似乎signature下面并没有activeParameter这个key，而result有
      local actPar = sig.activeParameter or result.activeParameter or 0
      -- 当activeparameter存在时，防止越界
      if actPar > 0 and actPar + 1 > #(sig.parameters or {}) then
        log("invalid lsp response, active parameter out of boundary")
        -- reset active parameter to last parameter
        sig.activeParameter = #(sig.parameters or {})
      end
    end
  end

  -- status_line.signature = actSig
  status_line.hint = hint or ""
  status_line.label = actSig.label or ""
  status_line.range = { start = s or 0, ["end"] = l or 0 }
  status_line.doc = helper.get_doc(result)

  local mode = vim.api.nvim_get_mode().mode
  local insert_mode = (mode == "niI" or mode == "i")
  local floating_window_on = (
    _LSP_SIG_CFG.winnr ~= nil
    and _LSP_SIG_CFG.winnr ~= 0
    and api.nvim_win_is_valid(_LSP_SIG_CFG.winnr)
  )
  if config.trigger_from_cursor_hold and not floating_window_on and not insert_mode then
    log("trigger from cursor hold, no need to update floating window")
    return
  end

  -- trim the doc
  if _LSP_SIG_CFG.doc_lines == 0 and config.trigger_from_lsp_sig then -- doc disabled
    helper.remove_doc(result)
  end

  if _LSP_SIG_CFG.hint_enable == true then
    if _LSP_SIG_CFG.floating_window == false then
      virtual_hint(hint, 0)
    end
  else
    _LSP_SIG_VT_NS = _LSP_SIG_VT_NS or vim.api.nvim_create_namespace("lsp_signature_vt")

    helper.cleanup(false) -- cleanup extmark
  end
  -- I do not need a floating win
  if _LSP_SIG_CFG.floating_window == false and config.toggle ~= true and config.trigger_from_lsp_sig then
    return {}, s, l
  end

  if _LSP_SIG_CFG.floating_window == false and config.trigger_from_cursor_hold then
    return {}, s, l
  end
  local off_y
  local ft = vim.api.nvim_buf_get_option(bufnr, "ft")

  ft = helper.ft2md(ft)
  -- handles multiple file type, we should just take the first filetype
  -- find the first file type and substring until the .
  local dot_index = string.find(ft, "%.")
  if dot_index ~= nil then
    ft = string.sub(ft, 0, dot_index - 1)
  end

  local lines = vim.lsp.util.convert_signature_help_to_markdown_lines(result, ft)

  if lines == nil or type(lines) ~= "table" then
    log("incorrect result", result)
    return
  end

  lines = vim.lsp.util.trim_empty_lines(lines)
  -- offset used for multiple signatures
  -- makrdown format
  log("md lines trim", lines)
  local offset = 2
  local num_sigs = #result.signatures
  if #result.signatures > 1 then
    if string.find(lines[1], [[```]]) then -- markdown format start with ```, insert pos need after that
      log("line1 is markdown reset offset to 3")
      offset = 3
    end
    log("before insert", lines)
    for index, sig in ipairs(result.signatures) do
      if index ~= activeSignature then
        table.insert(lines, offset, sig.label)
        offset = offset + 1
      end
    end
  end

  -- log("md lines", lines)
  local label = result.signatures[1].label
  if #result.signatures > 1 then
    label = result.signatures[activeSignature].label
  end

  log(
    "label:",
    label,
    result.activeSignature,
    activeSignature,
    result.activeParameter,
    result.signatures[activeSignature]
  )

  -- truncate empty document it
  if
    result.signatures[activeSignature].documentation
    and result.signatures[activeSignature].documentation.kind == "markdown"
    and result.signatures[activeSignature].documentation.value == "```text\n\n```"
  then
    result.signatures[activeSignature].documentation = nil
    lines = vim.lsp.util.convert_signature_help_to_markdown_lines(result, ft)

    log("md lines remove empty", lines)
  end

  local pos = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, pos[2])

  local woff = 1
  if config.triggered_chars and vim.tbl_contains(config.triggered_chars, "(") then
    woff = helper.cal_woff(line_to_cursor, label)
  end

  if _LSP_SIG_CFG.floating_window_off_x ~= nil then
    woff = woff + _LSP_SIG_CFG.floating_window_off_x
  end

  if _LSP_SIG_CFG.floating_window_off_y ~= nil then
    config.offset_y = _LSP_SIG_CFG.floating_window_off_y
  end

  -- total lines allowed
  if config.trigger_from_lsp_sig then
    lines = helper.truncate_doc(lines, num_sigs)
  end

  -- log(lines)
  if vim.tbl_isempty(lines) then
    log("WARN: signature is empty")
    return
  end
  local syntax = vim.lsp.util.try_trim_markdown_code_blocks(lines)

  if config.trigger_from_lsp_sig == true and _LSP_SIG_CFG.preview == "guihua" then
    -- This is a TODO
    error("guihua text view not supported yet")
  end
  helper.update_config(config)
  config.offset_x = woff

  if type(_LSP_SIG_CFG.fix_pos) == "function" then
    local client = vim.lsp.get_client_by_id(client_id)
    _LSP_SIG_CFG._fix_pos = _LSP_SIG_CFG.fix_pos(result, client)
  else
    _LSP_SIG_CFG._fix_pos = _LSP_SIG_CFG.fix_pos or true
  end

  -- when should the floating close
  config.close_events = { "BufHidden" } -- , 'InsertLeavePre'}
  if not _LSP_SIG_CFG._fix_pos then
    config.close_events = close_events
  end
  if not config.trigger_from_lsp_sig then
    config.close_events = close_events
  end
  if force_redraw and _LSP_SIG_CFG._fix_pos == false then
    config.close_events = close_events
  end
  if result.signatures[activeSignature].parameters == nil or #result.signatures[activeSignature].parameters == 0 then
    -- auto close when fix_pos is false
    if _LSP_SIG_CFG._fix_pos == false then
      config.close_events = close_events
    end
  end
  config.zindex = _LSP_SIG_CFG.zindex

  -- fix pos
  log("win config", config)
  local new_line = helper.is_new_line()

  if _LSP_SIG_CFG.padding ~= "" then
    for lineIndex = 1, #lines do
      lines[lineIndex] = _LSP_SIG_CFG.padding .. lines[lineIndex] .. _LSP_SIG_CFG.padding
    end
    config.offset_x = config.offset_x - #_LSP_SIG_CFG.padding
  end

  local display_opts
  local cnts

  display_opts, off_y, cnts = helper.cal_pos(lines, config)
  if cnts then
    lines = cnts
  end

  if _LSP_SIG_CFG.hint_enable == true then
    local v_offy = off_y
    if v_offy < 0 then
      v_offy = 1 -- put virtual text below current line
    end
    virtual_hint(hint, v_offy)
  end
  config.offset_y = off_y + config.offset_y
  config.focusable = true -- allow focus
  config.max_height = display_opts.max_height
  config.noautocmd = true

  -- try not to overlap with pum autocomplete menu
  if
    config.check_completion_visible
    and helper.completion_visible()
    and ((display_opts.anchor == "NW" or display_opts.anchor == "NE") and off_y == 0)
    and _LSP_SIG_CFG.zindex < 50
  then
    log("completion is visible, no need to show off_y", off_y)
    return
  end

  log("floating opt", config, display_opts, off_y, cnts)
  if _LSP_SIG_CFG._fix_pos and _LSP_SIG_CFG.bufnr and _LSP_SIG_CFG.winnr then
    if api.nvim_win_is_valid(_LSP_SIG_CFG.winnr) and _LSP_SIG_CFG.label == label and not new_line then
      status_line = { hint = "", label = "", range = nil }
    else
      -- vim.api.nvim_win_close(_LSP_SIG_CFG.winnr, true)
      _LSP_SIG_CFG.bufnr, _LSP_SIG_CFG.winnr = vim.lsp.util.open_floating_preview(lines, syntax, config)

      -- vim.api.nvim_buf_set_option(_LSP_SIG_CFG.bufnr, "filetype", "")
      log("sig_cfg bufnr, winnr not valid recreate", _LSP_SIG_CFG.bufnr, _LSP_SIG_CFG.winnr)
      _LSP_SIG_CFG.label = label
      _LSP_SIG_CFG.client_id = client_id
    end
  else
    _LSP_SIG_CFG.bufnr, _LSP_SIG_CFG.winnr = vim.lsp.util.open_floating_preview(lines, syntax, config)
    _LSP_SIG_CFG.label = label
    _LSP_SIG_CFG.client_id = client_id

    log("sig_cfg new bufnr, winnr ", _LSP_SIG_CFG.bufnr, _LSP_SIG_CFG.winnr)

    -- vim.api.nvim_buf_set_option(_LSP_SIG_CFG.bufnr, "filetype", "lsp_signature")
  end

  if _LSP_SIG_CFG.transparency and _LSP_SIG_CFG.transparency > 1 and _LSP_SIG_CFG.transparency < 100 then
    if type(_LSP_SIG_CFG.winnr) == "number" and vim.api.nvim_win_is_valid(_LSP_SIG_CFG.winnr) then
      vim.api.nvim_win_set_option(_LSP_SIG_CFG.winnr, "winblend", _LSP_SIG_CFG.transparency)
    end
  end
  local sig = result.signatures
  -- if it is last parameter, close windows after cursor moved

  local actPar = sig.activeParameter or result.activeParameter or 0
  if
    sig and sig[activeSignature].parameters == nil
    or actPar == nil
    or actPar + 1 == #sig[activeSignature].parameters
  then
    log("last para", close_events)
    if _LSP_SIG_CFG._fix_pos == false then
      vim.lsp.util.close_preview_autocmd(close_events, _LSP_SIG_CFG.winnr)
      -- elseif _LSP_SIG_CFG._fix_pos then
      --   vim.lsp.util.close_preview_autocmd(close_events_au, _LSP_SIG_CFG.winnr)
    end
    if _LSP_SIG_CFG.auto_close_after then
      helper.cleanup_async(true, _LSP_SIG_CFG.auto_close_after)
      status_line = { hint = "", label = "", range = nil }
    end
  end
  helper.highlight_parameter(s, l)

  return lines, s, l
end

local line_to_cursor_old
local signature = function(opts)
  opts = opts or {}
  local pos = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, pos[2])
  local clients = vim.lsp.buf_get_clients(0)
  if clients == nil or next(clients) == nil then
    return
  end
  local delta = line_to_cursor
  if line_to_cursor_old == nil then
    delta = line_to_cursor
  elseif #line_to_cursor_old > #line_to_cursor then
    delta = line_to_cursor_old:sub(#line_to_cursor)
  elseif #line_to_cursor_old < #line_to_cursor then
    delta = line_to_cursor:sub(#line_to_cursor_old)
  elseif not opts.trigger then
    line_to_cursor_old = line_to_cursor
    return
  end
  log("delta", delta, line_to_cursor, line_to_cursor_old, opts)
  line_to_cursor_old = line_to_cursor

  local signature_cap, triggered, trigger_position, trigger_chars = helper.check_lsp_cap(clients, line_to_cursor)
  local should_trigger = false
  for _, c in ipairs(trigger_chars) do
    c = helper.replace_special(c)
    if delta:find(c) then
      should_trigger = true
    end
  end

  -- no signature is shown
  if not _LSP_SIG_CFG.winnr or not vim.api.nvim_win_is_valid(_LSP_SIG_CFG.winnr) then
    should_trigger = true
  end
  if not should_trigger then
    local mode = vim.api.nvim_get_mode().mode
    log("mode:   ", mode)
    if mode == "niI" or mode == "i" then
      -- line_to_cursor_old = ""
      log("should not trigger")
      return
    end
  end
  if signature_cap == false then
    log("signature capabilities not enabled")
    return
  end

  if opts.trigger == "CursorHold" then
    local params = vim.lsp.util.make_position_params()
    params.position.character = trigger_position

    return vim.lsp.buf_request(
      0,
      "textDocument/signatureHelp",
      params,
      vim.lsp.with(signature_handler, {
        trigger_from_cursor_hold = true,
        border = _LSP_SIG_CFG.handler_opts.border,
        line_to_cursor = line_to_cursor:sub(1, trigger_position),
        triggered_chars = trigger_chars,
      })
    )
  end

  if opts.trigger == "NextSignature" then
    if _LSP_SIG_CFG.signature_result == nil or #_LSP_SIG_CFG.signature_result.signatures < 2 then
      return
    end
    log(_LSP_SIG_CFG.signature_result.activeSignature, _LSP_SIG_CFG.signature_result.cfgActiveSignature)
    local sig = _LSP_SIG_CFG.signature_result.signatures
    local actSig = (_LSP_SIG_CFG.signature_result.cfgActiveSignature or 0) + 1
    if actSig > #sig then
      actSig = 1
    end

    local params = vim.lsp.util.make_position_params()
    params.position.character = trigger_position

    return vim.lsp.buf_request(
      0,
      "textDocument/signatureHelp",
      params,
      vim.lsp.with(signature_handler, {
        check_completion_visible = true,
        trigger_from_next_sig = true,
        activeSignature = actSig,
        line_to_cursor = line_to_cursor:sub(1, trigger_position),
        border = _LSP_SIG_CFG.handler_opts.border,
        triggered_chars = trigger_chars,
      })
    )
  end
  if triggered then
    -- overwrite signature help here to disable "no signature help" message
    local params = vim.lsp.util.make_position_params()
    params.position.character = trigger_position
    -- Try using the already binded one, otherwise use it without custom config.
    -- LuaFormatter off
    vim.lsp.buf_request(
      0,
      "textDocument/signatureHelp",
      params,
      vim.lsp.with(signature_handler, {
        check_completion_visible = true,
        trigger_from_lsp_sig = true,
        line_to_cursor = line_to_cursor:sub(1, trigger_position),
        border = _LSP_SIG_CFG.handler_opts.border,
        triggered_chars = trigger_chars,
      })
    )
    -- LuaFormatter on
  else
    -- check if we should close the signature
    if _LSP_SIG_CFG.winnr and _LSP_SIG_CFG.winnr > 0 then
      -- if check_closer_char(line_to_cursor, triggered_chars) then
      if vim.api.nvim_win_is_valid(_LSP_SIG_CFG.winnr) then
        vim.api.nvim_win_close(_LSP_SIG_CFG.winnr, true)
      end
      _LSP_SIG_CFG.winnr = nil
      _LSP_SIG_CFG.bufnr = nil
      _LSP_SIG_CFG.startx = nil
      -- end
    end

    -- check should we close virtual hint
    if _LSP_SIG_CFG.signature_result and _LSP_SIG_CFG.signature_result.signatures ~= nil then
      local sig = _LSP_SIG_CFG.signature_result.signatures
      local actSig = _LSP_SIG_CFG.signature_result.activeSignature or 0
      local actPar = _LSP_SIG_CFG.signature_result.activeParameter or 0
      actSig, actPar = actSig + 1, actPar + 1
      if sig[actSig] ~= nil and sig[actSig].parameters ~= nil and #sig[actSig].parameters == actPar then
        M.on_CompleteDone()
      end
      _LSP_SIG_CFG.signature_result = nil
      _LSP_SIG_CFG.activeSignature = nil
      _LSP_SIG_CFG.activeParameter = nil
    end
  end
end

M.signature = signature

-- 在autocmd中调用，订阅的是InsertCharPre事件
function M.on_InsertCharPre()
  manager.insertChar = true
end

-- 在autocmd中调用，订阅的是InsertLeave 事件
function M.on_InsertLeave()
  line_to_cursor_old = ""
  -- 当前的mode，具体有哪些mode，可以看下:h mode()
  local mode = vim.api.nvim_get_mode().mode

  log("mode:   ", mode)
  if mode == "niI" or mode == "i" or mode == "s" then
    -- @todo：这条log有问题，1、niI？2、可以直接用上面的mode变量，不要重复获取
    log("mode:  niI ", vim.api.nvim_get_mode().mode)
    return
  end

  local delay = 0.2 -- 200ms
  -- vim.defer_fn()用于延迟执行函数
  vim.defer_fn(function()
    mode = vim.api.nvim_get_mode().mode
    log("mode:   ", mode)
    if mode == "i" or mode == "s" then
      signature()
      -- still in insert mode debounce
      return
    end
    log("close timer")
    manager.insertLeave = true
    if manager.timer then
      manager.timer:stop()
      manager.timer:close()
      manager.timer = nil
    end
  end, delay * 1000)

  log("Insert leave cleanup")
  helper.cleanup_async(true, delay, true) -- defer close after 0.3s
  status_line = { hint = "", label = "" }
end

local start_watch_changes_timer = function()
  if manager.timer then
    return
  end
  manager.changedTick = 0
  local interval = _LSP_SIG_CFG.timer_interval or 200
  if manager.timer then
    manager.timer:stop()
    manager.timer:close()
    manager.timer = nil
  end
  manager.timer = vim.loop.new_timer()
  manager.timer:start(
    100,
    interval,
    vim.schedule_wrap(function()
      local l_changedTick = api.nvim_buf_get_changedtick(0)
      local m = vim.api.nvim_get_mode().mode
      -- log(m)
      if m == "n" or m == "v" then
        M.on_InsertLeave()
        return
      end
      if l_changedTick ~= manager.changedTick then
        manager.changedTick = l_changedTick
        log("changed")
        signature()
      end
    end)
  )
end

function M.on_InsertEnter()
  log("insert enter")
  line_to_cursor_old = ""

  -- show signature immediately upon entering insert mode
  if manager.insertLeave == true then
    start_watch_changes_timer()
  end
  manager.init()
end

-- handle completion confirmation and dismiss hover popup
-- Note: this function may not work, depends on if complete plugin add parents or not
function M.on_CompleteDone()
  -- need auto brackets to make things work
  -- signature()
  -- cleanup virtual hint
  local m = vim.api.nvim_get_mode().mode
  vim.api.nvim_buf_clear_namespace(0, _LSP_SIG_VT_NS, 0, -1)
  if m == "i" or m == "s" or m == "v" then
    log("completedone ", m, "enable signature ?")
  end

  log("Insert leave cleanup", m)
end

function M.on_UpdateSignature()
  -- need auto brackets to make things work
  signature({ trigger = "CursorHold" })
  -- cleanup virtual hint
  local m = vim.api.nvim_get_mode().mode

  log("Insert leave cleanup", m)
end

-- 如果你的配置中有一些已经被废弃的参数，会提示出来
M.deprecated = function(cfg)
  if cfg.trigger_on_new_line ~= nil or cfg.trigger_on_nomatch ~= nil then
    print("trigger_on_new_line and trigger_on_nomatch deprecated, using always_trigger instead")
  end

  if cfg.use_lspsaga or cfg.check_3rd_handler ~= nil then
    print("lspsaga signature and 3rd handler deprecated")
  end
  if cfg.floating_window_above_first ~= nil then
    print("use floating_window_above_cur_line instead")
  end
  if cfg.decorator then
    print("decorator deprecated, use hi_parameter instead")
  end
end

-- 当日志文件大小超限时，删除日志文件
-- 在加载这个插件的时候执行
local function cleanup_logs(cfg)
  local log_path = cfg.log_path or _LSP_SIG_CFG.log_path or nil
  local fp = io.open(log_path, "r")
  if fp then
    local size = fp:seek("end")
    fp:close()
    if size > 1234567 then
      os.remove(log_path)
    end
  end
end

-- 加载插件的入口代码
M.on_attach = function(cfg, bufnr)
  bufnr = bufnr or 0

  -- 开启定义一个autocmd组
  api.nvim_command("augroup Signature")
  api.nvim_command("autocmd! * <buffer>")
  api.nvim_command("autocmd InsertEnter <buffer> lua require'lsp_signature'.on_InsertEnter()")
  api.nvim_command("autocmd InsertLeave <buffer> lua require'lsp_signature'.on_InsertLeave()")
  api.nvim_command("autocmd InsertCharPre <buffer> lua require'lsp_signature'.on_InsertCharPre()")
  api.nvim_command("autocmd CompleteDone <buffer> lua require'lsp_signature'.on_CompleteDone()")

  if _LSP_SIG_CFG.cursorhold_update then
    api.nvim_command("autocmd CursorHoldI,CursorHold <buffer> lua require'lsp_signature'.on_UpdateSignature()")
    api.nvim_command(
      "autocmd CursorHold,CursorHoldI <buffer> lua require'lsp_signature'.check_signature_should_close()"
    )
  end

  api.nvim_command("augroup end")
  -- autogroup结束

  if type(cfg) == "table" then
    _LSP_SIG_CFG = vim.tbl_extend("keep", cfg, _LSP_SIG_CFG)
    cleanup_logs(cfg)
    log(_LSP_SIG_CFG)
  end

  if _LSP_SIG_CFG.bind then
    vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(signature_handler, _LSP_SIG_CFG.handler_opts)
  end

  local shadow_cmd =
    string.format("hi default FloatShadow blend=%i guibg=%s", _LSP_SIG_CFG.shadow_blend, _LSP_SIG_CFG.shadow_guibg)
  vim.cmd(shadow_cmd)

  shadow_cmd = string.format(
    "hi default FloatShadowThrough blend=%i guibg=%s",
    _LSP_SIG_CFG.shadow_blend + 20,
    _LSP_SIG_CFG.shadow_guibg
  )
  vim.cmd(shadow_cmd)

  if _LSP_SIG_CFG.toggle_key then
    vim.keymap.set({ "i", "v", "s" }, _LSP_SIG_CFG.toggle_key, function()
      require("lsp_signature").toggle_float_win()
    end, { silent = true, noremap = true, buffer = bufnr, desc = "toggle signature" })
  end
  if _LSP_SIG_CFG.select_signature_key then
    vim.keymap.set("i", _LSP_SIG_CFG.select_signature_key, function()
      require("lsp_signature").signature({ trigger = "NextSignature" })
    end, { silent = true, noremap = true, buffer = bufnr, desc = "select signature" })
  end
  if _LSP_SIG_CFG.move_cursor_key then
    vim.keymap.set("i", _LSP_SIG_CFG.move_cursor_key, function()
      require("lsp_signature.helper").change_focus()
    end, { silent = true, noremap = true, desc = "change cursor focus" })
  end
  _LSP_SIG_VT_NS = api.nvim_create_namespace("lsp_signature_vt")
end

local signature_should_close_handler = helper.mk_handler(function(err, result, ctx, _)
  if err ~= nil then
    print(err)
    helper.cleanup_async(true, 0.01, true)
    status_line = { hint = "", label = "" }
    return
  end

  log("sig cleanup", result, ctx)
  local client_id = ctx.client_id
  local valid_result = result and result.signatures and result.signatures[1]
  local rlabel = nil
  if not valid_result then
    -- only close if this client opened the signature
    if _LSP_SIG_CFG.client_id == client_id then
      helper.cleanup_async(true, 0.01, true)
      status_line = { hint = "", label = "" }
      return
    end
  end

  -- corner case, result is not same
  if valid_result then
    rlabel = result.signatures[1].label
  end
  result = _LSP_SIG_CFG.signature_result
  local last_valid_result = result and result.signatures and result.signatures[1]
  local llabel = nil
  if last_valid_result then
    llabel = result.signatures[1].label
  end

  log(rlabel, llabel)

  if rlabel and rlabel ~= llabel then
    helper.cleanup(true)
    status_line = { hint = "", label = "" }
    signature()
  end
end)

-- 检查sig是否能关闭
M.check_signature_should_close = function()
  if _LSP_SIG_CFG.winnr and _LSP_SIG_CFG.winnr > 0 and vim.api.nvim_win_is_valid(_LSP_SIG_CFG.winnr) then
    local params = vim.lsp.util.make_position_params()
    local pos = api.nvim_win_get_cursor(0)
    local line = api.nvim_get_current_line()
    local line_to_cursor = line:sub(1, pos[2])
    -- Try using the already binded one, otherwise use it without custom config.
    -- LuaFormatter off
    vim.lsp.buf_request(
      0,
      "textDocument/signatureHelp",
      params,
      vim.lsp.with(signature_should_close_handler, {
        check_completion_visible = true,
        trigger_from_lsp_sig = true,
        line_to_cursor = line_to_cursor,
        border = _LSP_SIG_CFG.handler_opts.border,
      })
    )
  end

  -- LuaFormatter on
end

M.status_line = function(size)
  size = size or 300
  if #status_line.label + #status_line.hint > size then
    local labelsize = size - #status_line.hint
    -- local hintsize = #status_line.hint
    if labelsize < 10 then
      labelsize = 10
    end
    return {
      hint = status_line.hint,
      label = status_line.label:sub(1, labelsize) .. [[]],
      range = status_line.range,
    }
  end
  return { hint = status_line.hint, label = status_line.label, range = status_line.range, doc = status_line.doc }
end

M.toggle_float_win = function()
  _LSP_SIG_CFG.floating_window = not _LSP_SIG_CFG.floating_window

  if _LSP_SIG_CFG.winnr and _LSP_SIG_CFG.winnr > 0 and vim.api.nvim_win_is_valid(_LSP_SIG_CFG.winnr) then
    vim.api.nvim_win_close(_LSP_SIG_CFG.winnr, true)
    _LSP_SIG_CFG.winnr = nil
    _LSP_SIG_CFG.bufnr = nil
    if _LSP_SIG_VT_NS then
      vim.api.nvim_buf_clear_namespace(0, _LSP_SIG_VT_NS, 0, -1)
    end
    return
  end

  local params = vim.lsp.util.make_position_params()
  local pos = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, pos[2])
  -- Try using the already binded one, otherwise use it without custom config.
  -- LuaFormatter off
  vim.lsp.buf_request(
    0,
    "textDocument/signatureHelp",
    params,
    vim.lsp.with(signature_handler, {
      check_completion_visible = true,
      trigger_from_lsp_sig = true,
      toggle = true,
      line_to_cursor = line_to_cursor,
      border = _LSP_SIG_CFG.handler_opts.border,
    })
  )
  -- LuaFormatter on
end

M.signature_handler = signature_handler
-- setup function enable the signature and attach it to client
-- call it before startup lsp client

-- 加载插件的入口代码
M.setup = function(cfg)
  cfg = cfg or {}
  M.deprecated(cfg)
  -- 这里打印日志其实不会生效，因为log函数依赖_LSP_SIG_CFG里面的配置，
  -- 而用户配置的cfg是在M.on_attach()里面才合并到_LSP_SIG_CFG
  log("user cfg:", cfg)
  local _start_client = vim.lsp.start_client
  _LSP_SIG_VT_NS = api.nvim_create_namespace("lsp_signature_vt")
  -- 这段代码让我很困惑
  -- 1. lsp_config从哪来的
  -- 2. 这个函数中执行了_start_client()，也就是执行了vim.lsp_start_client()，会不会对LSP产生什么影响？
  vim.lsp.start_client = function(lsp_config)
    if lsp_config.on_attach == nil then
      -- lsp_config.on_attach = function(client, bufnr)
      lsp_config.on_attach = function(_, bufnr)
        M.on_attach(cfg, bufnr)
      end
    else
      local _on_attach = lsp_config.on_attach
      lsp_config.on_attach = function(client, bufnr)
        M.on_attach(cfg, bufnr)
        _on_attach(client, bufnr)
      end
    end
    return _start_client(lsp_config)
  end

  -- default if not defined
  vim.cmd([[hi default link LspSignatureActiveParameter Search]])
end

return M
