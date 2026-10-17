#!/usr/bin/env bash
set -e

# 1. Khởi chạy Web Server giữ cổng dưới nền
python3 server.py &

# 2. Tải Stockfish, cấu hình config.yml và chạy BotLi bằng môi trường của uv
uv run python - << 'EOF'
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

# --- BƯỚC 1: TẢI ENGINE STOCKFISH HỢP LỆ TỪ GITHUB API ---
engine_dir = "./engines"
engine_path = os.path.join(engine_dir, "stockfish")
os.makedirs(engine_dir, exist_ok=True)

if not os.path.isfile(engine_path):
    print("[Setup] Đang lấy link tải Stockfish Linux từ GitHub API...")
    cpuinfo = ""
    if os.path.exists("/proc/cpuinfo"):
        with open("/proc/cpuinfo", "r", encoding="utf-8", errors="ignore") as f:
            cpuinfo = f.read()

    preferred = ["ubuntu-x86-64-sse41-popcnt.tar", "ubuntu-x86-64-avx2.tar", "ubuntu-x86-64.tar"]
    if "avx2" in cpuinfo:
        preferred = ["ubuntu-x86-64-avx2.tar", "ubuntu-x86-64-sse41-popcnt.tar", "ubuntu-x86-64.tar"]

    download_url = None
    api_url = "https://api.github.com/repos/official-stockfish/Stockfish/releases/latest"
    req = urllib.request.Request(api_url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            assets = data.get("assets", [])
            for pref in preferred:
                for asset in assets:
                    if pref in asset.get("name", ""):
                        download_url = asset.get("browser_download_url")
                        break
                if download_url:
                    break
    except Exception as e:
        print(f"[Setup] Không truy cập được GitHub API ({e}), dùng link dự phòng...")

    if not download_url:
        download_url = "https://github.com/official-stockfish/Stockfish/releases/download/sf_17.1/stockfish-ubuntu-x86-64-sse41-popcnt.tar"

    print(f"[Setup] Đang tải Stockfish từ: {download_url}")
    tar_path = "stockfish.tar"
    dl_req = urllib.request.Request(download_url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(dl_req, timeout=120) as response, open(tar_path, "wb") as out_file:
        shutil.copyfileobj(response, out_file)

    if not tarfile.is_tarfile(tar_path):
        raise RuntimeError("File tải về không phải là định dạng .tar hợp lệ!")

    print("[Setup] Đang giải nén Stockfish...")
    with tarfile.open(tar_path, "r:*") as tar:
        binary_member = None
        for member in tar.getmembers():
            base = os.path.basename(member.name)
            if member.isfile() and "stockfish" in base and not base.endswith((".txt", ".md", ".1")):
                if binary_member is None or member.size > binary_member.size:
                    binary_member = member
        if not binary_member:
            raise RuntimeError("Không tìm thấy file chạy Stockfish bên trong gói .tar!")
        extracted_f = tar.extractfile(binary_member)
        with open(engine_path, "wb") as out_f:
            shutil.copyfileobj(extracted_f, out_f)

    os.chmod(engine_path, os.stat(engine_path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    os.remove(tar_path)
    print(f"[Setup] Đã cài đặt xong Stockfish tại {engine_path}")

# --- BƯỚC 2: TỰ ĐỘNG CẤU HÌNH CONFIG.YML BẰNG PYYAML ---
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
    elif "engine" in cfg and isinstance(cfg["engine"], dict):
        eng = cfg["engine"]
        if "dir" in eng and "name" in eng:
            eng["dir"] = abs_engine_dir
            eng["name"] = "stockfish"
        elif "path" in eng:
            eng["path"] = abs_engine_path

    with open("config.yml", "w", encoding="utf-8") as f:
        yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
    print("[Setup] Đã cập nhật thành công config.yml!")

# --- BƯỚC 3: KHỞI CHẠY BOTLI TRONG MÔI TRƯỜNG TERMINAL ẢO (PTY) ---
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
    os.execv(sys.executable, [sys.executable, "user_interface.py"])
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
