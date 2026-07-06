# Desktop Mirror

Desktop Mirror 是一个面向 Cubic 320x240 屏幕的桌面投屏 app。电脑端使用 Python 截图、缩放并编码为 JPEG，通过 WebSocket 推送；设备端使用 Lua + LVGL 接收并显示。

本分支是纯 Lua 版本，不需要动态模块，部署最简单。

## 仓库结构

- `desktop_mirror/`：可安装 app 目录。
- `desktop_mirror/app.info`：app 元信息，遵循 holocubic-apps 的 app 格式。
- `desktop_mirror/main.lua`：设备端入口脚本。
- `desktop_mirror/config.json`：设备端连接配置。
- `computer/`：电脑端推流程序和依赖安装脚本，不是设备 app。

## app.info

```ini
name = Desktop Mirror
entry = main.lua
description = Pure Lua desktop mirror receiver
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

## 部署设备端

1. 修改 `desktop_mirror/config.json`，把 `url` 改成电脑端打印的 WebSocket 地址：

   ```json
   {
     "url": "ws://电脑IP:8787"
   }
   ```

2. 将整个 `desktop_mirror/` 目录复制到设备 SD 卡：

   ```text
   /sd/apps/desktop_mirror/
     app.info
     main.lua
     config.json
   ```

3. 设备和电脑连接同一个局域网。

4. 在设备启动器中打开 `Desktop Mirror`。

Windows 第一次运行电脑端服务时，需要允许防火墙访问 `8787` 端口。

## 运行参数

- `--fps 20`：目标帧率，设备端压力大时可降到 `15`。
- `--quality 65`：JPEG 质量，常用范围 `60` 到 `75`。
- `--width 320 --height 240`：输出尺寸，默认匹配 Cubic 屏幕。
- `--fit stretch`：默认拉伸填满屏幕。

## 设备按键

- `LEFT`：显示或隐藏状态浮层。
- `RIGHT`：手动重连。
- `DOWN`：暂停或恢复画面。

## 协议说明

电脑端将桌面画面缩放到 `320x240`，编码成 JPEG，并在二进制帧前加入 `DMJ1` 头部，记录帧号、尺寸、质量和耗时信息。设备端收到 WebSocket 二进制帧后解析头部，将 JPEG 数据交给 LVGL 显示。

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE).
