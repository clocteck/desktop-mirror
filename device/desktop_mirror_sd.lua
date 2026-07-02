local prev = rawget(_G, "DESKTOP_MIRROR_SD_APP")
if prev and prev.shutdown then
  pcall(function()
    prev.shutdown()
  end)
end

DESKTOP_MIRROR_SD_APP = {}
local APP = DESKTOP_MIRROR_SD_APP

local MAIN_STYLE = 0
if LV_PART_MAIN and LV_STATE_DEFAULT then
  MAIN_STYLE = LV_PART_MAIN | LV_STATE_DEFAULT
end

local SCREEN_W = 320
local SCREEN_H = 240
local CANVAS_FMT_TRUE_COLOR = rawget(_G, "LV_IMG_CF_TRUE_COLOR") or rawget(_G, "CANVAS_FMT_TRUE_COLOR") or 4
local MAGIC_D = 68
local MAGIC_M = 77
local MAGIC_J = 74
local MAGIC_1 = 49

APP.url = "ws://192.168.31.188:8787"
APP.config_path = "/sd/apps/desktop_mirror_sd.json"
APP.module_path = "/sd/modules/jpg.so"
APP.ws_buffer = 32768
APP.serial_debug = true
APP.serial_debug_every = 1
APP.serial_debug_interval_ms = 5000
APP.native_gc_every = 4
APP.native_chunk_rows = 16
APP.native_swap_color_bytes = false
APP.native_chunked = false
APP.native_direct_present = true
APP.native_async = true
APP.last_debug_ms = 0
APP.last_debug_frame_count = 0
APP.last_debug_byte_count = 0
APP.overlay = false
APP.paused = false
APP.shutting_down = false
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
APP.fatal_error = nil
APP.last_native_decode_ms = 0
APP.last_native_decode_us = 0
APP.last_present_ms = 0
APP.last_present_us = 0
APP.ws = nil
APP.jpg = nil
APP.native_jpg = true
APP.native_canvas = false
APP.reconnect_timer = nil
APP.stat_timer = nil
APP.process_timer = nil
APP.pending_frame = nil
APP.render_busy = false
APP.pending_overwrite_count = 0
APP.submitted_frame_count = 0
APP.present_empty_count = 0
APP.ui = {}
APP.stat = {
  fps = 0,
  kbps = 0,
  frames = 0,
  bytes = 0,
  rx_binary = 0,
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

local function now_us()
  if tmr and tmr.now then
    return tmr.now() or 0
  end
  return now_ms() * 1000
end

local function elapsed_us(start_us)
  local n = now_us()
  if n >= start_us then
    return n - start_us
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

local function json_string(raw, key)
  return raw:match('"' .. key .. '"%s*:%s*"([^"]+)"')
end

local function json_bool(raw, key)
  local value = raw:match('"' .. key .. '"%s*:%s*(%a+)')
  if value == "true" then
    return true
  end
  if value == "false" then
    return false
  end
  return nil
end

local function json_number(raw, key)
  return tonumber(raw:match('"' .. key .. '"%s*:%s*(%d+)') or "")
end

local function load_config()
  if not file or not file.getcontents then
    return
  end

  local raw = file.getcontents(APP.config_path)
  if type(raw) ~= "string" then
    return
  end

  local url = json_string(raw, "url")
  if url and url:match("^wss?://") then
    APP.url = url
  end

  local serial_flag = json_bool(raw, "serial_debug")
  if serial_flag ~= nil then
    APP.serial_debug = serial_flag
  end

  local overlay = json_bool(raw, "overlay")
  if overlay ~= nil then
    APP.overlay = overlay
  end

  local every = json_number(raw, "serial_debug_every")
  if every and every >= 1 then
    APP.serial_debug_every = math.floor(every)
  end

  local interval = json_number(raw, "serial_debug_interval_ms")
  if interval and interval >= 100 then
    APP.serial_debug_interval_ms = math.floor(interval)
  end

  local native_gc_every = json_number(raw, "native_gc_every")
  if native_gc_every and native_gc_every >= 1 then
    APP.native_gc_every = math.floor(native_gc_every)
  end

  local native_chunk_rows = json_number(raw, "native_chunk_rows")
  if native_chunk_rows and native_chunk_rows >= 1 then
    APP.native_chunk_rows = math.floor(native_chunk_rows)
  end

  local native_swap_color_bytes = json_bool(raw, "native_swap_color_bytes")
  if native_swap_color_bytes ~= nil then
    APP.native_swap_color_bytes = native_swap_color_bytes
  end

  local native_chunked = json_bool(raw, "native_chunked")
  if native_chunked ~= nil then
    APP.native_chunked = native_chunked
  end

  local native_direct_present = json_bool(raw, "native_direct_present")
  if native_direct_present ~= nil then
    APP.native_direct_present = native_direct_present
  end

  local native_async = json_bool(raw, "native_async")
  if native_async ~= nil then
    APP.native_async = native_async
  end

  local ws_buffer = json_number(raw, "ws_buffer")
  if ws_buffer and ws_buffer >= 8192 then
    APP.ws_buffer = math.floor(ws_buffer)
  end

  local module_path = json_string(raw, "module_path")
  if module_path and module_path:match("%.so$") then
    APP.module_path = module_path
  end

  local native_jpg = json_bool(raw, "native_jpg")
  if native_jpg ~= nil then
    APP.native_jpg = native_jpg
  end
end

local function load_jpg_module()
  if not APP.native_jpg then
    return
  end
  if not require then
    APP.fatal_error = "Native JPEG requires require"
    print("[dmirror] fatal: " .. APP.fatal_error)
    return
  end
  if (not APP.native_direct_present) and (not lv_canvas_create or not lv_canvas_blit_rgb565) then
    APP.fatal_error = "Native JPEG canvas mode requires canvas/blit"
    print("[dmirror] fatal: " .. APP.fatal_error)
    return
  end

  local last_err = ""
  local paths = {
    APP.module_path,
    "/sd/apps/jpg.so",
    "/sd/apps/desktop_mirror/jpg.so",
    "/sd/apps/desktop_mirror/modules/jpg.so",
  }
  for _, path in ipairs(paths) do
    if path and path ~= "" then
      if package and package.loaded then
        package.loaded[path] = nil
      end
      local ok, mod = pcall(require, path)
      if ok and type(mod) == "table" and type(mod.decode) == "function" then
        if type(mod.submit) ~= "function" then
          last_err = "module missing async submit API"
        elseif APP.native_direct_present and type(mod.present_ready) ~= "function" then
          last_err = "module missing async direct present API"
        elseif (not APP.native_direct_present) and type(mod.read_ready) ~= "function" then
          last_err = "module missing async canvas API"
        else
          APP.jpg = mod
          APP.native_canvas = not APP.native_direct_present
          print("[dmirror] native jpg module loaded: " .. path)
          return
        end
      elseif not ok then
        last_err = tostring(mod or "module invalid")
      else
        last_err = "module invalid"
      end
    end
  end

  APP.native_canvas = false
  APP.fatal_error = "Native JPEG module unavailable: " .. last_err
  print("[dmirror] fatal: " .. APP.fatal_error)
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

local function update_overlay_visible()
  set_obj_hidden(APP.ui.panel, not APP.overlay)
  update_status()
end

local function show_error_screen(text)
  local root = lv_scr_act()
  lv_clear()

  local bg = lv_obj_create(root)
  lv_obj_set_pos(bg, 0, 0)
  lv_obj_set_size(bg, SCREEN_W, SCREEN_H)
  lv_obj_set_style_bg_color(bg, 0x220000, MAIN_STYLE)
  lv_obj_set_style_bg_opa(bg, 255, MAIN_STYLE)
  lv_obj_set_style_border_width(bg, 0, MAIN_STYLE)
  lv_obj_set_style_radius(bg, 0, MAIN_STYLE)
  lv_obj_set_style_pad_all(bg, 0, MAIN_STYLE)

  local title = lv_label_create(root)
  lv_obj_set_pos(title, 8, 16)
  lv_obj_set_size(title, SCREEN_W - 16, 24)
  lv_obj_set_style_text_color(title, 0xFF6666, MAIN_STYLE)
  lv_label_set_text(title, "Desktop Mirror Error")

  local msg = lv_label_create(root)
  lv_obj_set_pos(msg, 8, 48)
  lv_obj_set_size(msg, SCREEN_W - 16, 160)
  lv_obj_set_style_text_color(msg, 0xFFFFFF, MAIN_STYLE)
  if lv_label_set_long_mode and LV_LABEL_LONG_WRAP then
    pcall(function()
      lv_label_set_long_mode(msg, LV_LABEL_LONG_WRAP)
    end)
  end
  lv_label_set_text(msg, tostring(text or "unknown error"))
end

local function log_error(text)
  APP.last_error = tostring(text or "")
  if APP.last_error_log_ms == 0 or elapsed_ms(APP.last_error_log_ms) >= 1000 then
    APP.last_error_log_ms = now_ms()
    print("[dmirror] " .. APP.last_error)
  end
end

local function fatal_stop(text)
  APP.fatal_error = tostring(text or "unknown fatal error")
  APP.paused = true
  log_error(APP.fatal_error)
  if APP.jpg and type(APP.jpg.release) == "function" then
    pcall(function()
      APP.jpg.release()
    end)
  end
  if APP.ws then
    pcall(function()
      APP.ws:close()
    end)
    APP.ws = nil
  end
  APP.connected = false
  APP.connecting = false
  show_error_screen(APP.fatal_error)
end

local function log_receive(data, opcode)
  APP.rx_count = APP.rx_count + 1
  local is_binary = websocket and opcode == websocket.BINARY
  if is_binary then
    APP.rx_binary_count = APP.rx_binary_count + 1
  else
    APP.rx_ignored_count = APP.rx_ignored_count + 1
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
    "[dmirror] rx=%d bin=%d ignored=%d opcode=%s len=%d magic=%02X %02X %02X %02X",
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
  if APP.fatal_error then
    show_error_screen(APP.fatal_error)
    return
  end

  local root = lv_scr_act()
  lv_clear()

  local bg = lv_obj_create(root)
  lv_obj_set_pos(bg, 0, 0)
  lv_obj_set_size(bg, SCREEN_W, SCREEN_H)
  style_plain_panel(bg, 0x000000, 255)

  if APP.native_canvas then
    APP.ui.canvas = lv_canvas_create(root, SCREEN_W, SCREEN_H, CANVAS_FMT_TRUE_COLOR)
    lv_obj_set_pos(APP.ui.canvas, 0, 0)
  else
    APP.ui.img = lv_img_create(root)
    lv_obj_set_pos(APP.ui.img, 0, 0)
    if lv_img_set_antialias then
      pcall(function()
        lv_img_set_antialias(APP.ui.img, false)
      end)
    end
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
  local frame_delta = APP.frame_count - (APP.last_debug_frame_count or 0)
  local byte_delta = APP.byte_count - (APP.last_debug_byte_count or 0)
  local debug_fps = debug_dt > 0 and (frame_delta * 1000 / debug_dt) or 0
  local debug_kbps = debug_dt > 0 and (byte_delta * 1000 / debug_dt / 1024) or 0
  APP.last_debug_ms = now_ms()
  APP.last_debug_frame_count = APP.frame_count
  APP.last_debug_byte_count = APP.byte_count

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
    "[dmirror] frame=%d bytes=%d drop=%d order_err=%d pc_cap=%dms pc_resize=%dms pc_jpeg=%dms pc_send=%dms pc_all=%dms dev_parse=%dms lv_set_src=%dms dev_all=%dms fps=%.1f kbps=%.0f mon_cnt=%d mon_fps=%.1f mon_render=%.1f mon_last=%dms/%dpx",
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
    debug_fps,
    debug_kbps,
    mon_cnt,
    mon_wall_fps,
    mon_render_fps,
    mon_last_time,
    mon_last_px
  ))
end

local function display_frame(data)
  if APP.shutting_down or APP.paused or APP.fatal_error then
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

  local use_async_native = APP.native_async and APP.jpg and type(APP.jpg.submit) == "function" and
    ((APP.native_direct_present and type(APP.jpg.present_ready) == "function") or
      (APP.native_canvas and type(APP.jpg.read_ready) == "function"))

  if APP.has_frame_id and not use_async_native then
    if info.frame_id <= APP.last_frame_id then
      APP.out_of_order_count = APP.out_of_order_count + 1
      print(string.format(
        "[dmirror] frame order error: current=%d last=%d count=%d",
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
        "[dmirror] frame drop: last=%d current=%d lost=%d total=%d",
        APP.last_frame_id,
        info.frame_id,
        lost,
        APP.drop_count
      ))
    end
  end

  local jpeg = jpeg_or_err
  local set_src_start = now_ms()
  local set_src_start_us = now_us()
  local color_byte_order = APP.native_swap_color_bytes and "be" or "le"
  if APP.native_jpg and not APP.jpg then
    fatal_stop("Native JPEG is enabled but module is not ready")
    return
  end

  if use_async_native then
    local submit_ok, submitted_or_err, submit_stats = pcall(function()
      return APP.jpg.submit(jpeg, {
        swap_color_bytes = APP.native_swap_color_bytes,
        frame_id = info.frame_id or 0,
      })
    end)
    if not submit_ok or submitted_or_err ~= true then
      fatal_stop("native submit failed: " .. tostring(submit_stats or submitted_or_err or "submit"))
      return
    end
    APP.submitted_frame_count = APP.submitted_frame_count + 1
    APP.last_rx_ms = now_ms()
    APP.last_error = ""
    APP.last_error_log_ms = 0
    if submit_stats and APP.serial_debug then
      APP.last_native_decode_us = tonumber(submit_stats.decode_us) or APP.last_native_decode_us
      APP.last_native_decode_ms = math.floor((APP.last_native_decode_us or 0) / 1000)
    end
    return
  end

  if APP.native_direct_present and APP.jpg then
    local ok, decoded, out_w, out_h, native_stats = pcall(function()
      return APP.jpg.decode(jpeg, {
        swap_color_bytes = APP.native_swap_color_bytes,
        chunked = true,
      })
    end)
    if not ok then
      fatal_stop("native decode failed: " .. tostring(decoded or "decode"))
      return
    end
    if decoded ~= true then
      fatal_stop("native direct decode failed: " .. tostring(decoded or "decode"))
      return
    end
    if out_w ~= SCREEN_W or out_h ~= SCREEN_H then
      fatal_stop("native decode size mismatch: " .. tostring(out_w) .. "x" .. tostring(out_h))
      return
    end

    local present_ok, present_or_err, present_stats = pcall(function()
      return APP.jpg.present()
    end)
    if not present_ok or present_or_err ~= true then
      fatal_stop("native present failed: " .. tostring(present_or_err or "present"))
      return
    end
    native_stats = present_stats or native_stats
    if native_stats and APP.serial_debug then
      info.native_decode_ms = tonumber(native_stats.decode_ms) or 0
      info.native_push_ms = tonumber(native_stats.push_ms) or 0
      info.native_decode_us = tonumber(native_stats.decode_us) or (info.native_decode_ms * 1000)
      info.native_push_us = tonumber(native_stats.push_us) or (info.native_push_ms * 1000)
      APP.last_native_decode_ms = info.native_decode_ms
      APP.last_native_decode_us = info.native_decode_us
    end
  elseif APP.native_canvas and APP.jpg and APP.ui.canvas then
    local use_chunked = APP.native_chunked and type(APP.jpg.chunk) == "function"
    local ok, rgb565_or_true, out_w, out_h, native_stats = pcall(function()
      return APP.jpg.decode(jpeg, {
        swap_color_bytes = APP.native_swap_color_bytes,
        chunked = use_chunked,
      })
    end)
    if not ok then
      fatal_stop("native decode failed: " .. tostring(rgb565_or_true or "decode"))
      return
    end
    if use_chunked then
      if rgb565_or_true ~= true then
        fatal_stop("native chunked decode failed")
        return
      end
      if out_w ~= SCREEN_W or out_h ~= SCREEN_H then
        fatal_stop("native decode size mismatch: " .. tostring(out_w) .. "x" .. tostring(out_h))
        return
      end
      local y = 0
      local chunk_rows = APP.native_chunk_rows
      while y < SCREEN_H do
        local rows = chunk_rows
        if y + rows > SCREEN_H then
          rows = SCREEN_H - y
        end
        local chunk_ok, chunk_or_err = pcall(function()
          return APP.jpg.chunk(y, rows)
        end)
        if not chunk_ok or type(chunk_or_err) ~= "string" then
          fatal_stop("native chunk failed: " .. tostring(chunk_or_err or "chunk"))
          return
        end
        lv_canvas_blit_rgb565(APP.ui.canvas, 0, y, SCREEN_W, rows, chunk_or_err, {
          byte_order = color_byte_order,
          full_rewrite = y == 0,
        })
        chunk_or_err = nil
        y = y + rows
      end
    else
      if type(rgb565_or_true) ~= "string" then
        fatal_stop("native decode failed: " .. tostring(rgb565_or_true or "decode"))
        return
      end
      if out_w ~= SCREEN_W or out_h ~= SCREEN_H then
        fatal_stop("native decode size mismatch: " .. tostring(out_w) .. "x" .. tostring(out_h))
        return
      end
      lv_canvas_blit_rgb565(APP.ui.canvas, 0, 0, SCREEN_W, SCREEN_H, rgb565_or_true, {
        byte_order = color_byte_order,
        full_rewrite = true,
      })
      rgb565_or_true = nil
    end
    if native_stats and APP.serial_debug then
      info.native_decode_ms = tonumber(native_stats.decode_ms) or 0
      info.native_push_ms = tonumber(native_stats.push_ms) or 0
      info.native_decode_us = tonumber(native_stats.decode_us) or (info.native_decode_ms * 1000)
      info.native_push_us = tonumber(native_stats.push_us) or (info.native_push_ms * 1000)
      APP.last_native_decode_ms = info.native_decode_ms
      APP.last_native_decode_us = info.native_decode_us
    end
    if collectgarbage and APP.native_gc_every > 0 and (APP.frame_count % APP.native_gc_every) == 0 then
      collectgarbage("step", 256)
    end
  else
    if APP.native_jpg then
      fatal_stop("Native JPEG canvas mode is not ready")
      return
    end
    lv_img_set_src(APP.ui.img, jpeg)
    APP.last_native_decode_ms = 0
    APP.last_native_decode_us = 0
  end
  local set_src_ms = elapsed_ms(set_src_start)
  local set_src_us = elapsed_us(set_src_start_us)
  if APP.native_direct_present and info.native_push_us then
    set_src_ms = math.floor(info.native_push_us / 1000)
    set_src_us = info.native_push_us
  end
  APP.last_present_ms = set_src_ms
  APP.last_present_us = set_src_us

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

local function queue_frame(data)
  if APP.pending_frame ~= nil then
    APP.pending_overwrite_count = APP.pending_overwrite_count + 1
  end
  APP.pending_frame = data
end

local function process_pending_frame()
  if APP.render_busy or APP.shutting_down or APP.paused or APP.fatal_error then
    return
  end
  local data = APP.pending_frame
  if data == nil then
    return
  end
  APP.pending_frame = nil
  APP.render_busy = true
  local ok, err = pcall(function()
    display_frame(data)
  end)
  APP.render_busy = false
  data = nil
  if not ok then
    fatal_stop("display failed: " .. tostring(err))
  end
end

local function present_ready_frame()
  if APP.shutting_down or APP.paused or APP.fatal_error then
    return
  end
  if not (APP.native_async and APP.jpg) then
    return
  end

  if APP.native_direct_present and type(APP.jpg.present_ready) == "function" then
    local present_ok, presented_or_err, stats = pcall(function()
      return APP.jpg.present_ready()
    end)
    if not present_ok then
      fatal_stop("native present_ready failed: " .. tostring(presented_or_err or "present_ready"))
      return
    end
    if presented_or_err ~= true then
      return
    end

    stats = stats or {}
    local frame_id = tonumber(stats.frame_id) or 0
    local input_bytes = tonumber(stats.input_bytes) or 0
    if frame_id > 0 then
      if APP.has_frame_id then
        if frame_id <= APP.last_frame_id then
          APP.out_of_order_count = APP.out_of_order_count + 1
        elseif frame_id > APP.last_frame_id + 1 then
          APP.drop_count = APP.drop_count + (frame_id - APP.last_frame_id - 1)
        end
      end
      APP.last_frame_id = frame_id
      APP.has_frame_id = true
    end

    APP.frame_count = APP.frame_count + 1
    APP.byte_count = APP.byte_count + input_bytes
    APP.last_rx_ms = now_ms()
    APP.last_error = ""
    APP.last_error_log_ms = 0
    APP.last_native_decode_us = tonumber(stats.decode_us) or APP.last_native_decode_us
    APP.last_native_decode_ms = math.floor((APP.last_native_decode_us or 0) / 1000)
    APP.last_present_us = tonumber(stats.push_us) or APP.last_present_us
    APP.last_present_ms = math.floor((APP.last_present_us or 0) / 1000)
    return
  end

  if not (APP.native_canvas and type(APP.jpg.read_ready) == "function" and APP.ui.canvas) then
    return
  end

  local read_ok, rgb_or_err, out_w, out_h, stats = pcall(function()
    return APP.jpg.read_ready()
  end)
  if not read_ok then
    fatal_stop("native read_ready failed: " .. tostring(rgb_or_err or "read_ready"))
    return
  end
  if type(rgb_or_err) ~= "string" then
    return
  end
  if out_w ~= SCREEN_W or out_h ~= SCREEN_H then
    fatal_stop("native read_ready size mismatch: " .. tostring(out_w) .. "x" .. tostring(out_h))
    return
  end

  local blit_start_us = now_us()
  local blit_ok, blit_err = pcall(function()
    lv_canvas_blit_rgb565(APP.ui.canvas, 0, 0, SCREEN_W, SCREEN_H, rgb_or_err, {
      byte_order = APP.native_swap_color_bytes and "be" or "le",
      full_rewrite = true,
    })
  end)
  if not blit_ok then
    fatal_stop("lvgl canvas blit failed: " .. tostring(blit_err or "blit"))
    return
  end

  stats = stats or {}
  local frame_id = tonumber(stats.frame_id) or 0
  local input_bytes = tonumber(stats.input_bytes) or 0
  if frame_id > 0 then
    if APP.has_frame_id then
      if frame_id <= APP.last_frame_id then
        APP.out_of_order_count = APP.out_of_order_count + 1
      elseif frame_id > APP.last_frame_id + 1 then
        APP.drop_count = APP.drop_count + (frame_id - APP.last_frame_id - 1)
      end
    end
    APP.last_frame_id = frame_id
    APP.has_frame_id = true
  end

  APP.frame_count = APP.frame_count + 1
  APP.byte_count = APP.byte_count + input_bytes
  APP.last_rx_ms = now_ms()
  APP.last_error = ""
  APP.last_error_log_ms = 0
  APP.last_native_decode_us = tonumber(stats.decode_us) or APP.last_native_decode_us
  APP.last_native_decode_ms = math.floor((APP.last_native_decode_us or 0) / 1000)
  APP.last_present_us = elapsed_us(blit_start_us)
  APP.last_present_ms = math.floor((APP.last_present_us or 0) / 1000)
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
    print("[dmirror] websocket module missing")
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
    APP.pending_frame = nil
    APP.pending_overwrite_count = 0
    APP.submitted_frame_count = 0
    APP.present_empty_count = 0
    APP.last_rx_ms = now_ms()
    if lv_lvgl_monitor_reset then
      pcall(lv_lvgl_monitor_reset)
    end
    update_overlay_visible()
    print("[dmirror] connected " .. APP.url)
  end)

  ws:on("receive", function(client, data, opcode)
    if APP.shutting_down then
      return
    end
    log_receive(data, opcode)
    if opcode == websocket.BINARY then
      queue_frame(data)
      if not APP.process_timer then
        process_pending_frame()
      end
    end
  end)

  ws:on("close", function(_, status)
    APP.connected = false
    APP.connecting = false
    APP.ws = nil
    update_overlay_visible()
    print("[dmirror] disconnected " .. tostring(status or 0))
  end)

  local ok, err = pcall(function()
    ws:connect(APP.url)
  end)
  if not ok then
    APP.connecting = false
    APP.last_error = tostring(err)
    update_status()
    print("[dmirror] connect failed: " .. APP.last_error)
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
      APP.stat.rx_fps = (APP.rx_binary_count - (APP.stat.rx_binary or 0)) * 1000 / dt
      APP.stat.kbps = (APP.byte_count - APP.stat.bytes) * 1000 / dt / 1024
      APP.stat.frames = APP.frame_count
      APP.stat.bytes = APP.byte_count
      APP.stat.rx_binary = APP.rx_binary_count
      APP.stat.last_ms = ts
      if APP.serial_debug then
        print(string.format(
          "[dmirror][fps] display=%.1f rx=%.1f kbps=%.0f frames=%d submitted=%d drop=%d overwrite=%d empty=%d order_err=%d native_decode=%dus present=%dus",
          APP.stat.fps or 0,
          APP.stat.rx_fps or 0,
          APP.stat.kbps or 0,
          APP.frame_count or 0,
          APP.submitted_frame_count or 0,
          APP.drop_count or 0,
          APP.pending_overwrite_count or 0,
          APP.present_empty_count or 0,
          APP.out_of_order_count or 0,
          APP.last_native_decode_us or ((APP.last_native_decode_ms or 0) * 1000),
          APP.last_present_us or ((APP.last_present_ms or 0) * 1000)
        ))
      end
    end)

    APP.process_timer = tmr.create()
    APP.process_timer:alarm(1, tmr.ALARM_AUTO, function()
      process_pending_frame()
      present_ready_frame()
    end)

    APP.reconnect_timer = tmr.create()
    APP.reconnect_timer:alarm(2500, tmr.ALARM_AUTO, function()
      if (not APP.fatal_error) and (not APP.connected) and (not APP.connecting) and (not APP.paused) then
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
      if not APP.fatal_error then
        connect_ws()
      end
    end
  end)

  key.on(key.DOWN, function(evt)
    if evt == key.SHORT then
      if APP.fatal_error then
        return
      end
      APP.paused = not APP.paused
      update_status()
      print("[dmirror] paused=" .. tostring(APP.paused))
    end
  end)
end

function APP.shutdown()
  APP.shutting_down = true
  APP.paused = true
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
  if APP.process_timer then
    pcall(function()
      APP.process_timer:unregister()
    end)
    APP.process_timer = nil
  end
  APP.pending_frame = nil

  if key and key.off then
    pcall(function()
      key.off(key.LEFT)
      key.off(key.RIGHT)
      key.off(key.DOWN)
    end)
  end

  if APP.jpg and type(APP.jpg.release) == "function" then
    pcall(function()
      APP.jpg.release()
    end)
    APP.jpg = nil
  end

  pcall(function()
    lv_clear()
  end)
end

load_config()
load_jpg_module()
build_ui()
if not APP.fatal_error then
  bind_keys()
  start_timers()
  connect_ws()
end
