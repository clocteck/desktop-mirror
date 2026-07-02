# 桌面投屏

本工程按两端拆分：

- `device/`：设备端 Lua 应用，复制到 SD 卡 `/sd/apps/`。
- `computer/`：电脑端 Python 推流程序，负责截图、压缩和 WebSocket 发送。
- `device/src/`：可选 JPEG 原生解码动态模块源码，构建产物为 `jpg.so`。

## 部署

1. 电脑安装依赖：

   ```bat
   cd C:\Users\wzh\Documents\PlatformIO\Projects\桌面投屏\computer
   install_deps.bat
   ```

2. 启动电脑端：

   ```bat
   start_mirror.bat
   ```

   程序启动后会打印可用地址，例如 `ws://192.168.x.x:8787`。

3. 修改 `device/desktop_mirror_sd.json`：

   ```json
   {
     "url": "ws://电脑IP:8787"
   }
   ```

4. 把这两个文件复制到设备 SD 卡：

   - `device/desktop_mirror_sd.lua` -> `/sd/apps/desktop_mirror_sd.lua`
   - `device/desktop_mirror_sd.json` -> `/sd/apps/desktop_mirror_sd.json`

5. 设备和电脑连同一个局域网，打开设备上的 `desktop_mirror_sd.lua` 应用。Windows 第一次运行时需要允许防火墙访问 `8787` 端口。

## 可选原生 JPEG 解码模块

这个模块只做 `JPEG -> RGB565` 解码，不直接操作屏幕；Lua 仍用 LVGL canvas 推屏。

构建：

```bat
cd C:\Users\wzh\Documents\PlatformIO\Projects\桌面投屏\device
build_jpg.bat
```

需要先在当前终端加载 ESP-IDF 环境，让 `idf.py` 和 `IDF_PATH` 可用。构建成功后复制：

```text
device/src/build/jpg.so -> /sd/modules/jpg.so
```

`desktop_mirror_sd.json` 默认已启用：

```json
{
  "module_path": "/sd/modules/jpg.so",
  "native_jpg": true
}
```

模块加载成功后，设备端流程变为：WebSocket 收 JPEG -> `jpg.so` 解码 RGB565 -> `lv_canvas_blit_rgb565()` 写入 LVGL canvas。模块不存在或加载失败时，会自动回退到原来的 `lv_img_set_src(jpeg)`。

## 常用参数

查看显示器编号：

```bat
py -3 computer\desktop_mirror_server.py --list-monitors
```

指定显示器、降低码率：

```bat
computer\start_mirror.bat --monitor 2 --fps 20 --quality 65
```

Windows 上想尝试更快截图：

```bat
py -3 -m pip install dxcam opencv-python numpy mss
computer\start_mirror.bat --capture dxcam
```

设备按键：

- `LEFT`：显示/隐藏状态浮层。
- `RIGHT`：手动重连。
- `DOWN`：暂停/恢复画面。

## 实现过程

电脑端参考原项目协议：截图后缩放到 `320x240`，编码成 JPEG，用 `DMJ1` 二进制头记录帧号、尺寸、质量和耗时，再通过 WebSocket 二进制帧发送。

设备端 Lua 启动后读取 `/sd/apps/desktop_mirror_sd.json`，主动连接电脑端 WebSocket，收到二进制帧后校验 `DMJ1` 头，把 JPEG 数据交给 `lv_img_set_src()` 显示，并带有自动重连、丢帧统计和串口性能日志。

## 帧率优化想法

当前版本瓶颈通常在设备端 JPEG 解码和 LVGL 刷新。短期优先调 `--quality 60~75`、`--fps 15~24`、`--capture dxcam`，并通过串口日志看 `lv_set_src` 和 `mon_fps`。

当前 `jpg.so` 已经绕过 LVGL 自带 JPEG 解码，但仍然由 Lua/LVGL canvas 推屏。下一步如果要更高帧率，可以把 WebSocket 收包和 JPEG 解码放到核心 0 的模块任务里，只把最新 RGB565 帧交给核心 1/LVGL 提交。LVGL 本身不线程安全，所以不能在两个核心同时操作 LVGL 对象。

最高帧率方案是全屏投屏时绕过 LVGL，解码后直接用 `esp_lcd_panel_draw_bitmap` 或屏幕驱动 DMA 推 RGB565。这样会牺牲 LVGL 叠层便利性，但可以减少 `lv_img_set_src()`、图片解码器和对象刷新开销。

`.so` 动态模块要看当前 Lua 固件是否支持运行时加载 C 模块；ESP32 上更稳的做法通常是把 native mirror 作为 ESP-IDF/Arduino 组件编进固件，再给 Lua 暴露 `present_jpeg()` 或 `present_rgb565()` API。
