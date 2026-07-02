@echo off
setlocal
py -3 "%~dp0desktop_mirror_server.py" --host 0.0.0.0 --port 8787 --fps 24 --quality 75 --width 320 --height 240 --fit stretch %*
