# Desktop Mirror Native

Desktop Mirror Native 是面向 Cubic 320x240 屏幕的桌面投屏 app。电脑端使用 Python 截图、缩放并编码为 JPEG，通过 WebSocket 推送；设备端使用 Lua + LVGL 接收画面，并通过动态模块 `jpg.so` 将 JPEG 解码为 RGB565 以降低 Lua 侧压力。

本分支是动态模块版本，适合已经支持运行时加载 C 模块的设备固件。

## 仓库结构

- `desktop_mirror_sd/`：可安装 app 目录。
- `desktop_mirror_sd/app.info`：app 元信息，遵循 holocubic-apps 的 app 格式。
- `desktop_mirror_sd/main.lua`：设备端入口脚本。
- `desktop_mirror_sd/config.json`：设备端连接和 native 模块配置。
- `native_module/`：`jpg.so` 动态模块源码和构建脚本，不是设备 app。
- `computer/`：电脑端推流程序和依赖安装脚本，不是设备 app。

## app.info

```ini
name = Desktop Mirror Native
entry = main.lua
description = Desktop mirror receiver with native JPEG module
kind = app
version = 0.1.0
```

## 部署电脑端

1. 在电脑上安装 Python 3。

2. 在仓库根目录安装推流依赖：

   ```bat
   computer\install_deps.bat
   ```

3. 启动推流服务：

   ```bat
   computer\start_mirror.bat --fps 20 --quality 65
   ```

   启动后会打印可用地址，例如：

   ```text
   ws://192.168.0.80:8787
   ```

4. 可选：查看显示器编号并指定显示器：

   ```bat
   py -3 computer\desktop_mirror_server.py --list-monitors
   computer\start_mirror.bat --monitor 2 --fps 20 --quality 65
   ```

5. 可选：Windows 上安装 dxcam 截图后端：

   ```bat
   py -3 -m pip install -r computer\requirements-dxcam.txt
   computer\start_mirror.bat --capture dxcam --dxcam-live --fps 20 --quality 65
   ```

## 构建动态模块

1. 准备 ESP-IDF 环境，确保当前终端可用 `idf.py`，或设置 `IDF_PATH`。

2. 在仓库根目录构建 `jpg.so`：

   ```bat
   native_module\build_jpg.bat
   ```

3. 构建产物会复制到：

   ```text
   native_module\src\build\jpg.so
   ```

如果脚本提示找不到 ESP-IDF，请先安装 ESP-IDF，或把 `IDF_PATH` 指向本机 ESP-IDF 目录。

## 部署设备端

1. 修改 `desktop_mirror_sd/config.json`，把 `url` 改成电脑端打印的 WebSocket 地址：

   ```json
   {
     "url": "ws://电脑IP:8787",
     "module_path": "/sd/apps/desktop_mirror_sd/modules/jpg.so",
     "native_jpg": true
   }
   ```

2. 将整个 `desktop_mirror_sd/` 目录复制到设备 SD 卡：

   ```text
   /sd/apps/desktop_mirror_sd/
     app.info
     main.lua
     config.json
     modules/
       jpg.so
   ```

3. 将构建产物复制到 app 内的模块目录：

   ```text
   native_module/src/build/jpg.so -> /sd/apps/desktop_mirror_sd/modules/jpg.so
   ```

4. 设备和电脑连接同一个局域网。

5. 在设备启动器中打开 `Desktop Mirror Native`。

Windows 第一次运行电脑端服务时，需要允许防火墙访问 `8787` 端口。

## 常用 native 配置

- `native_jpg`：是否启用 `jpg.so`。
- `module_path`：动态模块路径，默认 `/sd/apps/desktop_mirror_sd/modules/jpg.so`。
- `native_async`：启用异步 native 解码。
- `native_img_userdata`：使用 native 图片 userdata 传给 LVGL。
- `ws_buffer`：WebSocket 接收缓冲区，动态模块版默认 `32768`。

模块加载失败时，Lua 端会记录错误并回退到普通 JPEG 显示流程；如果设备固件不支持运行时加载 C 模块，请使用 `main` 分支的纯 Lua 版本。

## 设备按键

- `LEFT`：显示或隐藏状态浮层。
- `RIGHT`：手动重连。
- `DOWN`：暂停或恢复画面。

## 协议说明

电脑端将桌面画面缩放到 `320x240`，编码成 JPEG，并在二进制帧前加入 `DMJ1` 头部，记录帧号、尺寸、质量和耗时信息。设备端收到 WebSocket 二进制帧后解析头部，再交给 `jpg.so` 解码或回退给 LVGL JPEG 显示。
