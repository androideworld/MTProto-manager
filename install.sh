#!/bin/bash
# 🚀 MTProto Manager — Установщик
set -e

echo "🚀 Установка MTProto Proxy Manager..."

# Скачиваем основной скрипт
curl -fsSL https://github.com/androideworld/MTProto-manager/raw/refs/heads/main/mtproto-manager.sh \
    -o /usr/local/bin/mtproto-manager

# Делаем исполняемым
chmod +x /usr/local/bin/mtproto-manager

# Проверяем
if command -v mtproto-manager &>/dev/null; then
    echo ""
    echo "✅ Установка завершена!"
    echo ""
    echo "📋 Использование:"
    echo "   sudo mtproto-manager          — главное меню"
    echo "   sudo mtproto-manager add ...  — добавить прокси"
    echo "   sudo mtproto-manager web      — веб-панель"
    echo ""
    echo "🌐 Документация: https://github.com/androideworld/MTProto-manager"
else
    echo "❌ Ошибка установки"
    exit 1
fi
