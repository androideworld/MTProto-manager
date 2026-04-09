#!/bin/bash
# 🚀 MTProto Manager — Установщик + Авто-запуск
set -e

echo "🚀 Установка MTProto Proxy Manager..."

# Скачиваем основной скрипт
curl -fsSL https://raw.githubusercontent.com/androideworld/MTProto-manager/main/mtproto-manager.sh \
    -o /usr/local/bin/mtproto-manager

# Делаем исполняемым
chmod +x /usr/local/bin/mtproto-manager

# Проверяем установку
if command -v mtproto-manager &>/dev/null; then
    echo ""
    echo "✅ Установка завершена!"
    echo ""
    echo "📋 Использование в будущем:"
    echo "   sudo mtproto-manager          — главное меню"
    echo "   sudo mtproto-manager add ...  — добавить прокси"
    echo "   sudo mtproto-manager web      — веб-панель"
    echo ""
    echo "🌐 Документация: https://github.com/androideworld/MTProto-manager"
    echo ""
    
    # 🔥 АВТО-ЗАПУСК (только если скрипт запущен от root)
    if [ "$EUID" -eq 0 ]; then
        echo "🚀 Запуск меню управления..."
        echo "Нажмите Ctrl+C, если хотите выйти"
        sleep 2
        mtproto-manager  # ← Запускаем без sudo, т.к. уже root
    else
        echo "💡 Для запуска введите: sudo mtproto-manager"
    fi
else
    echo "❌ Ошибка установки"
    exit 1
fi
