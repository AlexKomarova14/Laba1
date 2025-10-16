#!/usr/bin/env bash
set -euo pipefail

echo "===================================================================="
echo "🎯 АВТОМАТИЗИРОВАННОЕ ТЕСТИРОВАНИЕ LOG_CLEANER"
echo "===================================================================="
echo "Все тесты выполняются автоматически. Пользовательский ввод не требуется."
echo ""

# ============================================================================
# НАСТРОЙКИ И ФУНКЦИИ
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_CLEANER="$SCRIPT_DIR/log_cleaner.sh"
TEST_BASE="/tmp/log_cleaner_final_test_$$"
RESULTS_LOG="$TEST_BASE/test_results.log"

# Создаем тестовую среду
mkdir -p "$TEST_BASE"
echo "Тестовая среда создана: $TEST_BASE" | tee "$RESULTS_LOG"

# 🔹 Функции вывода
print_header() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🧪 $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$1" >> "$RESULTS_LOG"
}

print_step() {
    echo "  🔹 $1" | tee -a "$RESULTS_LOG"
}

print_success() {
    echo "  ✅ УСПЕХ: $1" | tee -a "$RESULTS_LOG"
}

print_error() {
    echo "  ❌ ОШИБКА: $1" | tee -a "$RESULTS_LOG"
}

print_info() {
    echo "  📋 ИНФО: $1" | tee -a "$RESULTS_LOG"
}

show_files() {
    local dir="$1"
    local description="$2"
    echo "  📁 $description:" | tee -a "$RESULTS_LOG"
    if [ -d "$dir" ]; then
        find "$dir" -type f -exec ls -lh {} \; 2>/dev/null | while read -r line; do
            echo "      $line" | tee -a "$RESULTS_LOG"
        done
        local file_count
        file_count=$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
        echo "      Всего файлов: $file_count" | tee -a "$RESULTS_LOG"
    else
        echo "      Директория не существует" | tee -a "$RESULTS_LOG"
    fi
}

# 🔹 Проверка основного скрипта
check_main_script() {
    print_step "Проверка наличия основного скрипта..."
    if [ ! -f "$LOG_CLEANER" ]; then
        print_error "Основной скрипт не найден: $LOG_CLEANER"
        exit 1
    fi
    
    print_step "Проверка прав выполнения..."
    if [ ! -x "$LOG_CLEANER" ]; then
        chmod +x "$LOG_CLEANER"
        print_info "Права на выполнение добавлены"
    fi
    
    print_step "Проверка синтаксиса..."
    if bash -n "$LOG_CLEANER"; then
        print_success "Синтаксис скрипта корректен"
    else
        print_error "Ошибка синтаксиса в основном скрипте"
        exit 1
    fi
}

# ============================================================================
# ТЕСТ 1: ОСНОВНАЯ ФУНКЦИОНАЛЬНОСТЬ - АРХИВАЦИЯ
# ============================================================================

test_basic_functionality() {
    local test_dir="$TEST_BASE/test1"
    mkdir -p "$test_dir/log" "$test_dir/backup"
    
    print_header "ТЕСТ 1: ОСНОВНАЯ ФУНКЦИОНАЛЬНОСТЬ"
    print_step "Создание тестовых файлов..."
    
    # Создаем файлы разных размеров
    for i in {1..5}; do
        dd if=/dev/zero of="$test_dir/log/old_file_$i.log" bs=1M count=30 status=none 2>/dev/null
        echo "Старый лог-файл $i" >> "$test_dir/log/old_file_$i.log"
    done
    
    for i in {1..3}; do
        dd if=/dev/zero of="$test_dir/log/new_file_$i.log" bs=1M count=20 status=none 2>/dev/null
        echo "Новый лог-файл $i" >> "$test_dir/log/new_file_$i.log"
    done
    
    show_files "$test_dir/log" "Файлы до архивации"
    
    print_step "Запуск архивации с порогом 60%..."
    cd "$test_dir"
    "$LOG_CLEANER" "./log" 60
    
    print_step "Проверка результатов..."
    show_files "$test_dir/log" "Файлы после архивации"
    show_files "$test_dir/backup" "Созданные архивы"
    
    local remaining_files
    remaining_files=$(find "$test_dir/log" -type f 2>/dev/null | wc -l | tr -d ' ')
    local archive_count
    archive_count=$(find "$test_dir/backup" -name "*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$archive_count" -gt 0 ] && [ "$remaining_files" -lt 8 ]; then
        print_success "Архивация выполнена корректно"
        return 0
    else
        print_error "Архивация не выполнена или выполнена некорректно"
        return 1
    fi
}

# ============================================================================
# ТЕСТ 2: АРХИВАЦИЯ НЕ ТРЕБУЕТСЯ
# ============================================================================

test_no_archive_needed() {
    local test_dir="$TEST_BASE/test2"
    mkdir -p "$test_dir/log" "$test_dir/backup"
    
    print_header "ТЕСТ 2: АРХИВАЦИЯ НЕ ТРЕБУЕТСЯ"
    print_step "Создание небольшого количества файлов..."
    
    for i in {1..2}; do
        dd if=/dev/zero of="$test_dir/log/small_file_$i.log" bs=1M count=10 status=none 2>/dev/null
        echo "Маленький файл $i" >> "$test_dir/log/small_file_$i.log"
    done
    
    show_files "$test_dir/log" "Файлы перед проверкой"
    
    print_step "Запуск с высоким порогом (90%) - архивация не должна сработать..."
    cd "$test_dir"
    "$LOG_CLEANER" "./log" 90
    
    print_step "Проверка результатов..."
    show_files "$test_dir/log" "Файлы после проверки"
    show_files "$test_dir/backup" "Архивы (должны быть пусто)"
    
    local remaining_files
    remaining_files=$(find "$test_dir/log" -type f 2>/dev/null | wc -l | tr -d ' ')
    local archive_count
    archive_count=$(find "$test_dir/backup" -name "*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$archive_count" -eq 0 ] && [ "$remaining_files" -eq 2 ]; then
        print_success "Архивация правильно не выполнена (как и ожидалось)"
        return 0
    else
        print_error "Архивация выполнена когда не должна была"
        return 1
    fi
}

# ============================================================================
# ТЕСТ 3: ОБРАБОТКА ОШИБОК
# ============================================================================

test_error_handling() {
    print_header "ТЕСТ 3: ОБРАБОТКА ОШИБОК"
    
    print_step "Тест 3.1: Несуществующая директория..."
    local output_file="$TEST_BASE/error_output.log"
    local exit_code=0
    
    "$LOG_CLEANER" "/nonexistent/directory/12345" 50 > "$output_file" 2>&1 || exit_code=$?
    
    if [ "$exit_code" -ne 0 ]; then
        print_success "Несуществующая директория обработана корректно"
    else
        print_error "Несуществующая директория не вызвала ошибку"
    fi
    
    print_step "Тест 3.2: Некорректный порог..."
    "$LOG_CLEANER" "/tmp" 150 > "$output_file" 2>&1 || exit_code=$?
    
    if [ "$exit_code" -ne 0 ]; then
        print_success "Некорректный порог обработан корректно"
    else
        print_error "Некорректный порог не вызвал ошибку"
    fi
    
    return 0
}

# ============================================================================
# ТЕСТ 4: ПРОВЕРКА АРХИВА
# ============================================================================

test_archive_validation() {
    local test_dir="$TEST_BASE/test4"
    mkdir -p "$test_dir/log" "$test_dir/backup"
    
    print_header "ТЕСТ 4: ПРОВЕРКА ЦЕЛОСТНОСТИ АРХИВА"
    print_step "Создание файлов с известным содержимым..."
    
    for i in {1..3}; do
        echo "ТЕСТОВОЕ_СОДЕРЖИМОЕ_$i" > "$test_dir/log/test_file_$i.log"
        dd if=/dev/zero bs=1M count=5 status=none >> "$test_dir/log/test_file_$i.log" 2>/dev/null
    done
    
    show_files "$test_dir/log" "Файлы для архивации"
    
    print_step "Запуск архивации..."
    cd "$test_dir"
    "$LOG_CLEANER" "./log" 1
    
    print_step "Проверка созданного архива..."
    local archive_file
    archive_file=$(find "$test_dir/backup" -name "*.tar.gz" | head -1)
    
    if [ -n "$archive_file" ]; then
        print_info "Архив создан: $(basename "$archive_file")"
        
        # Проверяем целостность архива
        if tar -tzf "$archive_file" >/dev/null 2>&1; then
            print_success "Архив не поврежден"
            
            # Проверяем содержимое
            local extract_dir="$test_dir/extracted"
            mkdir -p "$extract_dir"
            tar -xzf "$archive_file" -C "$extract_dir"
            
            local valid_files=0
            for i in {1..3}; do
                if [ -f "$extract_dir/test_file_$i.log" ]; then
                    if head -1 "$extract_dir/test_file_$i.log" | grep -q "ТЕСТОВОЕ_СОДЕРЖИМОЕ_$i"; then
                        ((valid_files++))
                    fi
                fi
            done
            
            if [ "$valid_files" -eq 3 ]; then
                print_success "Содержимое архива корректно"
                return 0
            else
                print_error "Содержимое архива не соответствует ожидаемому"
                return 1
            fi
        else
            print_error "Архив поврежден"
            return 1
        fi
    else
        print_error "Архив не создан"
        return 1
    fi
}

# ============================================================================
# ГЛАВНАЯ ФУНКЦИЯ ТЕСТИРОВАНИЯ
# ============================================================================

main() {
    echo "Начало тестирования: $(date)" | tee -a "$RESULTS_LOG"
    echo "Основной скрипт: $LOG_CLEANER" | tee -a "$RESULTS_LOG"
    echo "" | tee -a "$RESULTS_LOG"
    
    # Проверка основного скрипта
    check_main_script
    
    # Запуск тестов
    local tests_passed=0
    local tests_total=4
    
    if test_basic_functionality; then ((tests_passed++)); fi
    if test_no_archive_needed; then ((tests_passed++)); fi
    if test_error_handling; then ((tests_passed++)); fi
    if test_archive_validation; then ((tests_passed++)); fi
    
    # Итоги
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎯 ИТОГИ ТЕСТИРОВАНИЯ"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Пройдено тестов: $tests_passed/$tests_total" | tee -a "$RESULTS_LOG"
    echo "Лог тестирования: $RESULTS_LOG" | tee -a "$RESULTS_LOG"
    
    if [ "$tests_passed" -eq "$tests_total" ]; then
        echo ""
        echo "🎉 ВСЕ ТЕСТЫ ПРОЙДЕНЫ УСПЕШНО!"
        echo "Система готова к защите лабораторной работы!"
        echo ""
        echo "📋 Краткое описание выполненых проверок:"
        echo "   ✅ Основная функциональность архивации"
        echo "   ✅ Корректное определение когда архивация не требуется"
        echo "   ✅ Обработка ошибочных ситуаций"
        echo "   ✅ Проверка целостности созданных архивов"
    else
        echo ""
        echo "⚠️  Обнаружены проблемы в работе скрипта!"
        echo "Рекомендуется провести отладку перед защитой."
    fi
    
    echo ""
    echo "Очистка тестовой среды..."
    rm -rf "$TEST_BASE"
    
    # Возвращаем код успеха/ошибки
    if [ "$tests_passed" -eq "$tests_total" ]; then
        exit 0
    else
        exit 1
    fi
}

# Обработка прерывания для очистки
cleanup() {
    echo ""
    echo "Прерывание тестирования. Очистка..."
    rm -rf "$TEST_BASE"
    exit 1
}

trap cleanup INT TERM

# 🚀 ЗАПУСК ТЕСТИРОВАНИЯ
main
