#!/usr/bin/env bash
set -e

# 1. Khởi chạy Web Server giữ cổng dưới nền
python3 -u server.py &

# 2. Tải Stockfish, tối ưu RAM cho Render Free (512MB) và chạy BotLi
uv run python -u - << 'EOF'
import os
import sys
import pty
import json
import stat
import yaml
import fcntl
import shutil
import struct
import termios
import tarfile
import urllib.request

# --- BƯỚC 1: TẢI ENGINE STOCKFISH HỢP LỆ ---
engine_dir = "./engines"
engine_path = os.path.join(engine_dir, "stockfish")
os.makedirs(engine_dir, exist_ok=True)

if not os.path.isfile(engine_path):
    print("[Setup] Đang tải Stockfish Linux...")
    download_url = "https://github.com/official-stockfish/Stockfish/releases/download/sf_17.1/stockfish-ubuntu-x86-64-sse41-popcnt.tar"
    tar_path = "stockfish.tar"
    dl_req = urllib.request.Request(download_url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(dl_req, timeout=120) as response, open(tar_path, "wb") as out_file:
        shutil.copyfileobj(response, out_file)

    print("[Setup] Đang giải nén Stockfish...")
    with tarfile.open(tar_path, "r:*") as tar:
        binary_member = max(
            (m for m in tar.getmembers() if m.isfile() and "stockfish" in os.path.basename(m.name) and not m.name.endswith((".txt", ".md", ".1"))),
            key=lambda m: m.size
        )
        with open(engine_path, "wb") as out_f:
            shutil.copyfileobj(tar.extractfile(binary_member), out_f)

    os.chmod(engine_path, os.stat(engine_path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    os.remove(tar_path)
    print(f"[Setup] Đã cài đặt xong Stockfish tại {engine_path}")

# --- BƯỚC 2: CẤU HÌNH CONFIG.YML TỐI ƯU CHO RENDER FREE (512MB RAM) ---
if os.path.exists("config.yml.default"):
    shutil.copyfile("config.yml.default", "config.yml")

if os.path.exists("config.yml"):
    with open("config.yml", "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    token = os.environ.get("LICHESS_TOKEN", "").strip()
    if token:
        cfg["token"] = token
    else:
        print("[Cảnh báo] Bạn chưa thêm biến môi trường LICHESS_TOKEN trên Render!")

    abs_engine_path = os.path.abspath(engine_path)
    abs_engine_dir = os.path.abspath(engine_dir)

    if "engines" in cfg and isinstance(cfg["engines"], dict):
        for key, eng in cfg["engines"].items():
            if isinstance(eng, dict):
                if "dir" in eng and "name" in eng:
                    eng["dir"] = abs_engine_dir
                    eng["name"] = "stockfish"
                elif "path" in eng:
                    eng["path"] = abs_engine_path
                elif "executable" in eng:
                    eng["executable"] = abs_engine_path
                
                # Tắt ponder và giảm Hash xuống 32MB để tránh tràn 512MB RAM trên Render Free
                eng["ponder"] = False
                if "uci_options" not in eng or not isinstance(eng["uci_options"], dict):
                    eng["uci_options"] = {}
                eng["uci_options"]["Threads"] = 1
                eng["uci_options"]["Hash"] = 32

    with open("config.yml", "w", encoding="utf-8") as f:
        yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
    print("[Setup] Đã cập nhật config.yml (Threads=1, Hash=32MB, Ponder=False)!")

# --- BƯỚC 3: KHỞI CHẠY BOTLI TRONG TERMINAL ẢO (PTY) ---
print("[BotLi] Đang khởi động user_interface.py...")
master_fd, slave_fd = pty.openpty()
winsize = struct.pack("HHHH", 40, 120, 0, 0)
fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsize)

pid = os.fork()
if pid == 0:
    os.close(master_fd)
    os.setsid()
    fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
    os.dup2(slave_fd, 0)
    os.dup2(slave_fd, 1)
    os.dup2(slave_fd, 2)
    if slave_fd > 2:
        os.close(slave_fd)
    os.environ["TERM"] = "xterm-256color"
    os.execv(sys.executable, [sys.executable, "-u", "user_interface.py"])
else:
    os.close(slave_fd)
    try:
        while True:
            data = os.read(master_fd, 1024)
            if not data:
                break
            sys.stdout.write(data.decode("utf-8", errors="replace"))
            sys.stdout.flush()
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)
    sys.exit(os.WEXITSTATUS(status))
EOF
