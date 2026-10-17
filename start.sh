#!/usr/bin/env bash
set -e

# 1. Khởi chạy Web Server giữ cổng (không cần cài thêm Flask)
python3 server.py &

# 2. Tự động tải Engine Stockfish cho Linux nếu chưa có
mkdir -p engines
if [ ! -f "engines/stockfish" ]; then
    echo "[Setup] Đang tải Stockfish cho Linux x86_64..."
    curl -L -s https://github.com/official-stockfish/Stockfish/releases/latest/download/stockfish-ubuntu-x86-64-avx2.tar -o stockfish.tar
    tar -xf stockfish.tar
    mv stockfish/stockfish-ubuntu-x86-64-avx2 engines/stockfish
    chmod +x engines/stockfish
    rm -rf stockfish stockfish.tar
    echo "[Setup] Đã cài đặt xong Stockfish tại ./engines/stockfish"
fi

# 3. Tự động tạo config.yml từ config.yml.default và biến môi trường LICHESS_TOKEN
if [ ! -f "config.yml" ]; then
    echo "[Setup] Đang tạo config.yml từ config.yml.default..."
    cp config.yml.default config.yml
fi

if [ -n "$LICHESS_TOKEN" ]; then
    echo "[Setup] Đang cập nhật LICHESS_TOKEN và đường dẫn Engine vào config.yml..."
    python3 - << 'EOF'
import os, re

with open("config.yml", "r", encoding="utf-8") as f:
    content = f.read()

token = os.environ.get("LICHESS_TOKEN", "")
# Thay thế token dòng đầu tiên
content = re.sub(r'^token:\s*".*?"', f'token: "{token}"', content, count=1, flags=re.MULTILINE)
# Cập nhật thư mục và tên file engine
content = re.sub(r'^(\s*dir:\s*)".*?"', r'"./engines"', content, count=1, flags=re.MULTILINE)
content = re.sub(r'^(\s*name:\s*)".*?"', r'"stockfish"', content, count=1, flags=re.MULTILINE)

with open("config.yml", "w", encoding="utf-8") as f:
    f.write(content)
EOF
fi

# 4. Chạy BotLi (Torom/BotLi sử dụng uv và user_interface.py)
echo "[BotLi] Đang khởi động BotLi..."
pip install -q uv
uv run user_interface.py
