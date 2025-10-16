#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="log_cleaner"

# Функции для красивого вывода
info() { echo "[INFO] $1" >&2; }
error() { echo "[ERROR] $1" >&2; }

# Показать справку
show_help() {
    cat << EOF
Использование: $SCRIPT_NAME [ПУТЬ_К_ЛОГАМ] [ПОРОГ_В_ПРОЦЕНТАХ]

Аргументы:
  ПУТЬ_К_ЛОГАМ        Директория с лог-файлами для мониторинга
  ПОРОГ_В_ПРОЦЕНТАХ   Порог заполнения в % (по умолчанию: 70)

Примеры:
  $SCRIPT_NAME /var/log 80
  $SCRIPT_NAME /app/logs

Описание:
  Скрипт проверяет заполнение ФАЙЛОВОЙ СИСТЕМЫ где находятся логи
  и архивирует старые файлы, если заполнение превышает указанный порог.
EOF
}

#Проверка что порог - число от 1 до 100
validate_threshold() {
    local threshold="$1"
    if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -lt 1 ] || [ "$threshold" -gt 100 ]; then
        error "Порог должен быть числом от 1 до 100"
        return 1
    fi
    return 0
}

# Проверка что директория существует и доступна
validate_directory() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        error "Директория '$dir' не существует"
        return 1
    fi
    if [ ! -r "$dir" ]; then
        error "Нет прав на чтение директории '$dir'"
        return 1
    fi
    return 0
}

# Получение аргументов
if [ "$#" -gt 0 ]; then
    case "$1" in
        -h|--help|help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "$SCRIPT_NAME v$VERSION"
            exit 0
            ;;
        *)
            LOG_DIR="$1"
            ;;
    esac
fi

# Если путь не передан - запрашиваем
if [ -z "${LOG_DIR:-}" ]; then
    read -rp "Введите путь к директории с логами: " LOG_DIR
fi

# Проверяем директорию
if ! validate_directory "$LOG_DIR"; then
    exit 1
fi

# Получение порога
if [ "$#" -ge 2 ]; then
    THRESHOLD="$2"
else
    read -rp "Введите порог заполнения в % (по умолчанию 70): " input_threshold
    THRESHOLD="${input_threshold:-70}"
fi

# Проверяем порог
if ! validate_threshold "$THRESHOLD"; then
    exit 1
fi

# Переходим в директорию и получаем абсолютный путь
if ! cd "$LOG_DIR" 2>/dev/null; then
    error "Не удалось перейти в директорию '$LOG_DIR'"
    exit 1
fi
LOG_DIR_ABS=$(pwd -P)
info "Рабочая директория: $LOG_DIR_ABS"

# Функция получения информации о файловой системе
get_filesystem_info() {
    local dir="$1"
    
    # Размер папки логов в KB
    FOLDER_KB=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
    if [ -z "$FOLDER_KB" ] || [ "$FOLDER_KB" -eq 0 ]; then
        error "Не удалось определить размер папки или папка пуста"
        return 1
    fi
    
    # Информация о файловой системе (используем df для получения % заполнения)
    local fs_info
    if ! fs_info=$(df -k "$dir" 2>/dev/null | tail -1); then
        error "Не удалось получить информацию о файловой системы"
        return 1
    fi
    
    # Парсим данные для macOS
    FS_TOTAL_KB=$(echo "$fs_info" | awk '{print $2}')    # Общий размер
    FS_USED_KB=$(echo "$fs_info" | awk '{print $3}')     # Использовано
    # shellcheck disable=SC2034
    FS_AVAIL_KB=$(echo "$fs_info" | awk '{print $4}')    # 
    
    if [ -z "$FS_TOTAL_KB" ] || [ "$FS_TOTAL_KB" -eq 0 ]; then
        error "Неверные данные файловой системы"
        return 1
    fi
    
    
    PERCENT=$(awk -v used="$FS_USED_KB" -v total="$FS_TOTAL_KB" \
        'BEGIN { if (total>0) printf "%.1f", (used/total)*100; else print "0.0" }')
    
    # Человечкские размеры
    FOLDER_HUMAN=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    FS_TOTAL_HUMAN=$(df -h "$dir" | tail -1 | awk '{print $2}')
    FS_USED_HUMAN=$(df -h "$dir" | tail -1 | awk '{print $3}')
    FS_AVAIL_HUMAN=$(df -h "$dir" | tail -1 | awk '{print $4}')
    
    return 0
}

# Получаем информацию о файловой системе
if ! get_filesystem_info "$LOG_DIR_ABS"; then
    exit 1
fi

# Вывод информации
echo "=== ИНФОРМАЦИЯ О СИСТЕМЕ ==="
echo "Директория логов: $LOG_DIR_ABS"
echo "Размер логов: $FOLDER_KB KB ($FOLDER_HUMAN)"
echo "Файловая система: всего $FS_TOTAL_HUMAN, использовано $FS_USED_HUMAN, доступно $FS_AVAIL_HUMAN"
echo "Заполнение файловой системы: $PERCENT%"
echo "Установленный порог: $THRESHOLD%"

# Проверка превышения порога
EXCEED=$(awk -v p="$PERCENT" -v t="$THRESHOLD" \
    'BEGIN { print (p + 0 > t + 0) ? 1 : 0 }')

if [ "$EXCEED" -eq 0 ]; then
    info "Заполненность $PERCENT% в пределах порога $THRESHOLD% - архивация не требуется."
    exit 0
fi

info "Заполнение $PERCENT% превышает порог $THRESHOLD% - требуется архивация."

# Процесс архивации
BACKUP_DIR="$(dirname "$LOG_DIR_ABS")/backup"
mkdir -p "$BACKUP_DIR"

if [ ! -w "$BACKUP_DIR" ]; then
    error "Нет прав на запись в директорию бэкапа: $BACKUP_DIR"
    exit 1
fi

# Вычисление необходимого места для освобождения
# "Нужно освободить столько, чтобы заполнение стало ниже порога"
NEED_FREE_KB=$(awk -v used="$FS_USED_KB" -v total="$FS_TOTAL_KB" -v threshold="$THRESHOLD" \
    'BEGIN { 
        target_used_kb = (threshold / 100) * total * 0.95  # 95% от порога для надежности
        need_free = used - target_used_kb
        print (need_free > 0) ? need_free : 0 
    }')

if [ "$(echo "$NEED_FREE_KB" | awk '{print int($1)}')" -le 0 ]; then
    info "Не требуется освобождать место."
    exit 0
fi

info "Требуется освободить: $NEED_FREE_KB KB"

# Поиск и сортировка файлов для архивации (ДЛЯ MACOS)
find_oldest_files() {
    local target_size="$1"
    local current_size=0
    local files=()
    
    info "Поиск старых файлов для освобождения $target_size KB..."
    
    # Находим файлы, сортируем по времени модификации (старые первыми)
    while IFS= read -r file; do
        if [ -z "$file" ] || [ ! -f "$file" ]; then
            continue
        fi
        
        # Получаем размер файла в KB (для macOS)
        local size_kb
        size_kb=$(( $(stat -f%z "$file" 2>/dev/null) / 1024 ))
        
        if [ "$size_kb" -eq 0 ]; then
            continue
        fi
        
        files+=("$file")
        current_size=$((current_size + size_kb))
        
        # Проверяем, достигли ли целевого размера
        if [ "$(echo "$current_size" | awk '{print int($1)}')" -ge "$(echo "$target_size" | awk '{print int($1)}')" ]; then
            info "Достигнут целевой размер: $current_size KB >= $target_size KB"
            break
        fi
        
    done < <(find "$LOG_DIR_ABS" -type f -not -name ".*" -exec stat -f "%m %N" {} \; 2>/dev/null | \
             sort -n | \
             cut -d' ' -f2-)
    
    printf '%s\n' "${files[@]}"
}

# Ищем файлы для архивации
info "Поиск файлов для архивации..."
ARCHIVE_FILES=()
while IFS= read -r file; do
    [ -n "$file" ] && ARCHIVE_FILES+=("$file")
done < <(find_oldest_files "$NEED_FREE_KB")

if [ "${#ARCHIVE_FILES[@]}" -eq 0 ]; then
    info "Нет файлов для архивации."
    exit 0
fi

#Подсчет общего размера
TOTAL_ARCHIVE_KB=0
for file in "${ARCHIVE_FILES[@]}"; do
    size_kb=$(( $(stat -f%z "$file" 2>/dev/null) / 1024 ))
    TOTAL_ARCHIVE_KB=$((TOTAL_ARCHIVE_KB + size_kb))
done

info "Найдено файлов для архивации: ${#ARCHIVE_FILES[@]}"
info "Общий размер для архивации: $TOTAL_ARCHIVE_KB KB"

# Создание архива
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ARCHIVE_NAME="log_backup_${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"

info "Создание архива: $ARCHIVE_PATH"

# Создаем временный файл со списком файлов
TMP_LIST=$(mktemp "/tmp/log_archive_list.XXXXXX")
trap 'rm -f "$TMP_LIST"' EXIT

for file in "${ARCHIVE_FILES[@]}"; do
    echo "$file" >> "$TMP_LIST"
done

# Создаем архив (gzip сжатие)
info "Архивируем файлы..."
if ! tar -czf "$ARCHIVE_PATH" -C "$LOG_DIR_ABS" -T "$TMP_LIST" 2>/dev/null; then
    error "Ошибка создания архива"
    exit 1
fi

# Проверяем что архив создан
if [ ! -f "$ARCHIVE_PATH" ]; then
    error "Архив не был создан"
    exit 1
fi

ARCHIVE_SIZE=$(stat -f%z "$ARCHIVE_PATH" 2>/dev/null | awk '{print int($1/1024)}')
info "Архив создан: $ARCHIVE_PATH ($ARCHIVE_SIZE KB)"

# Удаление заархивированных файлов
info "Удаление оригинальных файлов..."
for file in "${ARCHIVE_FILES[@]}"; do
    if [ -f "$file" ]; then
        rm -f "$file"
    fi
done

# Удаление пустых директорий
#find "$LOG_DIR_ABS" -type d -empty -delete 2>/dev/null || true

info "Архивация завершена успешно!"
info "Освобождено примерно: $TOTAL_ARCHIVE_KB KB"

# Финальная проверка
if get_filesystem_info "$LOG_DIR_ABS"; then
    echo "=== РЕЗУЛЬТАТ ==="
    echo "Новое заполнение файловой системы: $PERCENT%"
    echo "Архив сохранен: $ARCHIVE_PATH"
    echo "Освобождено места: $TOTAL_ARCHIVE_KB KB"
fi

# Очистка временных файлов
rm -f "$TMP_LIST"
trap - EXIT

info "Скрипт завершил работу успешно!"
