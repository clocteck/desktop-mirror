local prev = rawget(_G, "PURE_LUA_DESKTOP_MIRROR_APP")
if prev and prev.shutdown then
  pcall(function()
    prev.shutdown()
  end)
end

PURE_LUA_DESKTOP_MIRROR_APP = {}
local APP = PURE_LUA_DESKTOP_MIRROR_APP

local MAIN_STYLE = 0
if LV_PART_MAIN and LV_STATE_DEFAULT then
  MAIN_STYLE = LV_PART_MAIN | LV_STATE_DEFAULT
end

local SCREEN_W = 320
local SCREEN_H = 240
local MAGIC_D = 68
local MAGIC_M = 77
local MAGIC_J = 74
local MAGIC_1 = 49

APP.url = "ws://192.168.31.188:8787"
APP.config_path = "/sd/apps/pure_lua_desktop_mirror.json"
APP.ws_buffer = 8192
APP.serial_debug = true
APP.serial_debug_every = 1
APP.serial_debug_interval_ms = 5000
APP.last_debug_ms = 0
APP.overlay = false
APP.paused = false
APP.connected = false
APP.connecting = false
APP.frame_count = 0
APP.byte_count = 0
APP.rx_count = 0
APP.rx_binary_count = 0
APP.rx_ignored_count = 0
APP.last_frame_id = 0
APP.has_frame_id = false
APP.drop_count = 0
APP.out_of_order_count = 0
APP.last_rx_ms = 0
APP.last_error = ""
APP.last_error_log_ms = 0
APP.ws = nil
APP.reconnect_timer = nil
APP.stat_timer = nil
APP.ui = {}
APP.stat = {
  fps = 0,
  kbps = 0,
  frames = 0,
  bytes = 0,
  last_ms = 0,
}

local function now_ms()
  if millis then
    return millis() or 0
  end
  return 0
end

local function elapsed_ms(start_ms)
  local n = now_ms()
  if n >= start_ms then
    return n - start_ms
  end
  return 0
end

local function u16le(s, i)
  local b1, b2 = string.byte(s, i, i + 1)
  if not b2 then
    return 0
  end
  return b1 + b2 * 256
end

local function u32le(s, i)
  local b1, b2, b3, b4 = string.byte(s, i, i + 3)
  if not b4 then
    return 0
  end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function load_config()
  if not file or not file.getcontents then
    return
  end

  local raw = file.getcontents(APP.config_path)
  if type(raw) ~= "string" then
    return
  end

  local url = raw:match('"url"%s*:%s*"([^"]+)"')
  if url and url:match("^wss?://") then
    APP.url = url
  end

  local serial_flag = raw:match('"serial_debug"%s*:%s*(%a+)')
  if serial_flag == "false" then
    APP.serial_debug = false
  elseif serial_flag == "true" then
    APP.serial_debug = true
  end

  local overlay_flag = raw:match('"overlay"%s*:%s*(%a+)')
  if overlay_flag == "false" then
    APP.overlay = false
  elseif overlay_flag == "true" then
    APP.overlay = true
  end

  local every = tonumber(raw:match('"serial_debug_every"%s*:%s*(%d+)') or "")
  if every and every >= 1 then
    APP.serial_debug_every = math.floor(every)
  end

  local interval = tonumber(raw:match('"serial_debug_interval_ms"%s*:%s*(%d+)') or "")
  if interval and interval >= 100 then
    APP.serial_debug_interval_ms = math.floor(interval)
  end

  local ws_buffer = tonumber(raw:match('"ws_buffer"%s*:%s*(%d+)') or "")
  if ws_buffer and ws_buffer >= 8192 then
    APP.ws_buffer = math.floor(ws_buffer)
  end
end

local function set_status(text)
  if APP.ui.status then
    lv_label_set_text(APP.ui.status, text or "")
  end
end

local function update_status()
  if APP.paused then
    set_status("PAUSED")
  elseif APP.connected then
    set_status("CONNECTED")
  elseif APP.connecting then
    set_status("CONNECTING")
  else
    set_status("OFFLINE")
  end
end

local function set_obj_hidden(id, hidden)
  if not id or not lv_obj_add_flag or not lv_obj_clear_flag or not LV_OBJ_FLAG_HIDDEN then
    return
  end

  if hidden then
    lv_obj_add_flag(id, LV_OBJ_FLAG_HIDDEN)
  else
    lv_obj_clear_flag(id, LV_OBJ_FLAG_HIDDEN)
  end
end

local function update_overlay_visible()
  set_obj_hidden(APP.ui.panel, not APP.overlay)
  update_status()
end

local function log_error(text)
  APP.last_error = tostring(text or "")
  if not APP.serial_debug then
    return
  end
  if APP.last_error_log_ms == 0 or elapsed_ms(APP.last_error_log_ms) >= 1000 then
    APP.last_error_log_ms = now_ms()
    print("[pure-lua-mirror] " .. APP.last_error)
  end
end

local function log_receive(data, opcode)
  APP.rx_count = APP.rx_count + 1
  local is_binary = websocket and opcode == websocket.BINARY
  if is_binary then
    APP.rx_binary_count = APP.rx_binary_count + 1
  else
    APP.rx_ignored_count = APP.rx_ignored_count + 1
  end

  if not APP.serial_debug then
    return
  end
  if APP.rx_count ~= 1 and (APP.rx_count % 120) ~= 0 and is_binary then
    return
  end
  if APP.rx_ignored_count > 8 and not is_binary then
    return
  end

  local len = type(data) == "string" and #data or 0
  local b1, b2, b3, b4 = 0, 0, 0, 0
  if len >= 4 then
    b1, b2, b3, b4 = string.byte(data, 1, 4)
  end
  print(string.format(
    "[pure-lua-mirror] rx=%d bin=%d ignored=%d opcode=%s len=%d magic=%02X %02X %02X %02X",
    APP.rx_count,
    APP.rx_binary_count,
    APP.rx_ignored_count,
    tostring(opcode),
    len,
    b1 or 0,
    b2 or 0,
    b3 or 0,
    b4 or 0
  ))
end

local function style_plain_panel(id, color, opa)
  lv_obj_set_style_bg_color(id, color, MAIN_STYLE)
  lv_obj_set_style_bg_opa(id, opa, MAIN_STYLE)
  lv_obj_set_style_border_width(id, 0, MAIN_STYLE)
  lv_obj_set_style_radius(id, 0, MAIN_STYLE)
  lv_obj_set_style_pad_all(id, 0, MAIN_STYLE)
end

local function build_ui()
  local root = lv_scr_act()
  lv_clear()

  local bg = lv_obj_create(root)
  lv_obj_set_pos(bg, 0, 0)
  lv_obj_set_size(bg, SCREEN_W, SCREEN_H)
  style_plain_panel(bg, 0x000000, 255)

  APP.ui.img = lv_img_create(root)
  lv_obj_set_pos(APP.ui.img, 0, 0)
  if lv_img_set_antialias then
    pcall(function()
      lv_img_set_antialias(APP.ui.img, false)
    end)
  end

  APP.ui.panel = lv_obj_create(root)
  lv_obj_set_pos(APP.ui.panel, 4, SCREEN_H - 22)
  lv_obj_set_size(APP.ui.panel, 84, 18)
  style_plain_panel(APP.ui.panel, 0x000000, 180)
  lv_obj_set_style_radius(APP.ui.panel, 4, MAIN_STYLE)

  APP.ui.status = lv_label_create(APP.ui.panel)
  lv_obj_set_pos(APP.ui.status, 4, 2)
  lv_obj_set_size(APP.ui.status, 76, 14)
  lv_obj_set_style_text_color(APP.ui.status, 0xFFFFFF, MAIN_STYLE)
  lv_obj_set_style_text_opa(APP.ui.status, 255, MAIN_STYLE)
  if lv_obj_set_style_text_font then
    pcall(function()
      lv_obj_set_style_text_font(APP.ui.status, LV_FONT_MONTSERRAT_10 or 10, MAIN_STYLE)
    end)
  end
  if lv_label_set_long_mode and LV_LABEL_LONG_CLIP then
    pcall(function()
      lv_label_set_long_mode(APP.ui.status, LV_LABEL_LONG_CLIP)
    end)
  end

  update_overlay_visible()
end

local function parse_frame(data)
  if type(data) ~= "string" or #data < 36 then
    return nil, "short"
  end

  local b1, b2, b3, b4 = string.byte(data, 1, 4)
  if b1 ~= MAGIC_D or b2 ~= MAGIC_M or b3 ~= MAGIC_J or b4 ~= MAGIC_1 then
    return nil, "magic"
  end

  local version = string.byte(data, 5) or 0
  if version ~= 1 then
    return nil, "version"
  end

  local header_len = u16le(data, 7)
  local jpeg_len = u32le(data, 13)
  if header_len < 36 or jpeg_len <= 0 or #data < header_len + jpeg_len then
    return nil, "length"
  end

  local info = {
    frame_id = u32le(data, 9),
    jpeg_len = jpeg_len,
    width = u16le(data, 17),
    height = u16le(data, 19),
    quality = u16le(data, 21),
    fps100 = u16le(data, 23),
    pc_capture_ms = u16le(data, 25),
    pc_resize_ms = u16le(data, 27),
    pc_encode_ms = u16le(data, 29),
    pc_frame_ms = u16le(data, 31),
    pc_send_ms = u16le(data, 33),
    pc_clients = u16le(data, 35),
  }

  if info.width ~= SCREEN_W or info.height ~= SCREEN_H then
    return nil, "size"
  end

  return info, data:sub(header_len + 1, header_len + jpeg_len)
end

local function print_frame_debug(info, times)
  if not APP.serial_debug then
    return
  end

  local every = APP.serial_debug_every or 1
  if every > 1 and (APP.frame_count % every) ~= 0 then
    return
  end

  local interval = APP.serial_debug_interval_ms or 5000
  local debug_dt = interval
  if APP.last_debug_ms > 0 then
    debug_dt = elapsed_ms(APP.last_debug_ms)
  end
  if APP.last_debug_ms > 0 and debug_dt < interval then
    return
  end
  APP.last_debug_ms = now_ms()

  local mon_cnt, mon_time, mon_px, mon_last_time, mon_last_px = 0, 0, 0, 0, 0
  if lv_lvgl_monitor_get then
    local ok, a, b, c, d, e = pcall(lv_lvgl_monitor_get)
    if ok then
      mon_cnt = tonumber(a) or 0
      mon_time = tonumber(b) or 0
      mon_px = tonumber(c) or 0
      mon_last_time = tonumber(d) or 0
      mon_last_px = tonumber(e) or 0
    end
  end
  local mon_wall_fps = debug_dt > 0 and (mon_cnt * 1000 / debug_dt) or 0
  local mon_render_fps = mon_time > 0 and (mon_cnt * 1000 / mon_time) or 0
  if lv_lvgl_monitor_reset then
    pcall(lv_lvgl_monitor_reset)
  end

  print(string.format(
    "[pure-lua-mirror] frame=%d bytes=%d drop=%d order_err=%d pc_cap=%dms pc_resize=%dms pc_jpeg=%dms pc_send=%dms pc_all=%dms dev_parse=%dms lv_set_src=%dms dev_all=%dms fps=%.1f kbps=%.0f mon_cnt=%d mon_fps=%.1f mon_render=%.1f mon_last=%dms/%dpx",
    info.frame_id or 0,
    info.jpeg_len or 0,
    APP.drop_count or 0,
    APP.out_of_order_count or 0,
    info.pc_capture_ms or 0,
    info.pc_resize_ms or 0,
    info.pc_encode_ms or 0,
    info.pc_send_ms or 0,
    info.pc_frame_ms or 0,
    times.parse_ms or 0,
    times.set_src_ms or 0,
    times.total_ms or 0,
    APP.stat.fps or 0,
    APP.stat.kbps or 0,
    mon_cnt,
    mon_wall_fps,
    mon_render_fps,
    mon_last_time,
    mon_last_px
  ))
end

local function display_frame(data)
  if APP.paused then
    return
  end

  local total_start = now_ms()
  local parse_start = now_ms()
  local info, jpeg_or_err = parse_frame(data)
  local parse_ms = elapsed_ms(parse_start)
  if not info then
    log_error("parse failed: " .. tostring(jpeg_or_err or "parse"))
    return
  end

  if APP.has_frame_id then
    if info.frame_id <= APP.last_frame_id then
      APP.out_of_order_count = APP.out_of_order_count + 1
      print(string.format(
        "[pure-lua-mirror] frame order error: current=%d last=%d count=%d",
        info.frame_id,
        APP.last_frame_id,
        APP.out_of_order_count
      ))
      return
    end

    if info.frame_id > APP.last_frame_id + 1 then
      local lost = info.frame_id - APP.last_frame_id - 1
      APP.drop_count = APP.drop_count + lost
      print(string.format(
        "[pure-lua-mirror] frame drop: last=%d current=%d lost=%d total=%d",
        APP.last_frame_id,
        info.frame_id,
        lost,
        APP.drop_count
      ))
    end
  end

  local jpeg = jpeg_or_err
  local set_src_start = now_ms()
  lv_img_set_src(APP.ui.img, jpeg)
  local set_src_ms = elapsed_ms(set_src_start)

  APP.frame_count = APP.frame_count + 1
  APP.byte_count = APP.byte_count + #jpeg
  APP.last_frame_id = info.frame_id
  APP.has_frame_id = true
  APP.last_rx_ms = now_ms()
  APP.last_error = ""
  APP.last_error_log_ms = 0

  if APP.ui.panel and APP.overlay and lv_obj_move_foreground then
    pcall(function()
      lv_obj_move_foreground(APP.ui.panel)
    end)
  end

  print_frame_debug(info, {
    parse_ms = parse_ms,
    set_src_ms = set_src_ms,
    total_ms = elapsed_ms(total_start),
  })
end

local function close_ws()
  if APP.ws then
    pcall(function()
      APP.ws:close()
    end)
    APP.ws = nil
  end
  APP.connected = false
  APP.connecting = false
  update_status()
end

local function connect_ws()
  if APP.connecting then
    return
  end

  close_ws()
  if not websocket or not websocket.createClient then
    print("[pure-lua-mirror] websocket module missing")
    return
  end

  APP.connecting = true
  update_status()

  local ws = websocket.createClient()
  APP.ws = ws
  ws:config({
    buffer_size = APP.ws_buffer,
    task_stack = 12288,
    network_timeout_ms = 5000,
    auto_reconnect = false,
  })

  ws:on("connection", function(client)
    APP.connected = true
    APP.connecting = false
    APP.has_frame_id = false
    APP.last_frame_id = 0
    APP.drop_count = 0
    APP.out_of_order_count = 0
    APP.last_rx_ms = now_ms()
    if lv_lvgl_monitor_reset then
      pcall(lv_lvgl_monitor_reset)
    end
    update_overlay_visible()
    print("[pure-lua-mirror] connected " .. APP.url)
    pcall(function()
      client:send("ready", websocket.TEXT)
    end)
  end)

  ws:on("receive", function(_, data, opcode)
    log_receive(data, opcode)
    if websocket and opcode == websocket.BINARY then
      display_frame(data)
    end
  end)

  ws:on("close", function(_, status)
    APP.connected = false
    APP.connecting = false
    APP.ws = nil
    update_overlay_visible()
    print("[pure-lua-mirror] disconnected " .. tostring(status or 0))
  end)

  local ok, err = pcall(function()
    ws:connect(APP.url)
  end)
  if not ok then
    APP.connecting = false
    APP.last_error = tostring(err)
    update_status()
    print("[pure-lua-mirror] connect failed: " .. APP.last_error)
  end
end

local function start_timers()
  if tmr and tmr.create then
    APP.stat_timer = tmr.create()
    APP.stat_timer:alarm(1000, tmr.ALARM_AUTO, function()
      local ts = now_ms()
      local dt = APP.stat.last_ms > 0 and (ts - APP.stat.last_ms) or 1000
      if dt <= 0 then
        dt = 1000
      end
      APP.stat.fps = (APP.frame_count - APP.stat.frames) * 1000 / dt
      APP.stat.kbps = (APP.byte_count - APP.stat.bytes) * 1000 / dt / 1024
      APP.stat.frames = APP.frame_count
      APP.stat.bytes = APP.byte_count
      APP.stat.last_ms = ts
    end)

    APP.reconnect_timer = tmr.create()
    APP.reconnect_timer:alarm(2500, tmr.ALARM_AUTO, function()
      if (not APP.connected) and (not APP.connecting) and (not APP.paused) then
        connect_ws()
      end
    end)
  end
end

local function bind_keys()
  if not key or not key.on then
    return
  end

  key.on(key.LEFT, function(evt)
    if evt == key.SHORT then
      APP.overlay = not APP.overlay
      update_overlay_visible()
    end
  end)

  key.on(key.RIGHT, function(evt)
    if evt == key.SHORT then
      connect_ws()
    end
  end)

  key.on(key.DOWN, function(evt)
    if evt == key.SHORT then
      APP.paused = not APP.paused
      update_status()
      print("[pure-lua-mirror] paused=" .. tostring(APP.paused))
    end
  end)
end

function APP.shutdown()
  close_ws()

  if APP.reconnect_timer then
    pcall(function()
      APP.reconnect_timer:unregister()
    end)
    APP.reconnect_timer = nil
  end
  if APP.stat_timer then
    pcall(function()
      APP.stat_timer:unregister()
    end)
    APP.stat_timer = nil
  end

  if key and key.off then
    pcall(function()
      key.off(key.LEFT)
      key.off(key.RIGHT)
      key.off(key.DOWN)
    end)
  end

  pcall(function()
    lv_clear()
  end)
end

load_config()
build_ui()
bind_keys()
start_timers()
connect_ws()
