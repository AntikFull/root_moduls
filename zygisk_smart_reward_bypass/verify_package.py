#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Углубленный предрелизный аудит модуля Zygisk Smart Reward Bypass.
Автор: eCubz (https://t.me/eCubz)
"""

import os
import sys
import struct
import hashlib
import json
import re

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception: # глушение-обосновано: реконфигурация stdout опциональна в устаревших окружениях
        pass # глушение-обосновано: реконфигурация stdout опциональна в устаревших окружениях

def check_file(path, desc):
    if not os.path.isfile(path):
        print(f"[FAIL] Отсутствует обязательный файл: {desc} ({path})")
        return False
    if os.path.getsize(path) == 0:
        print(f"[FAIL] Файл пуст (0 байт): {desc} ({path})")
        return False
    print(f"[OK] {desc}: {os.path.basename(path)} ({os.path.getsize(path)} байт)")
    return True

def check_line_endings_and_encoding(path):
    with open(path, "rb") as f:
        data = f.read()
    
    if data.startswith(b"\xef\xbb\xbf"):
        print(f"[FAIL] Обнаружен UTF-8 BOM в файле: {path}")
        return False
    
    if b"\r\n" in data or b"\r" in data:
        print(f"[FAIL] Обнаружены CRLF или CR переносы строк в файле: {path}")
        return False
        
    return True

def verify_elf_binary(path, expected_machine, expected_bits, name):
    if not os.path.isfile(path):
        return False
    with open(path, "rb") as f:
        header = f.read(52)
    
    if len(header) < 52 or header[:4] != b"\x7fELF":
        print(f"[FAIL] {name}: некорректный ELF magic header")
        return False
    
    ei_class = header[4] # 1 = 32-bit, 2 = 64-bit
    ei_data = header[5]  # 1 = little-endian
    
    if (expected_bits == 32 and ei_class != 1) or (expected_bits == 64 and ei_class != 2):
        print(f"[FAIL] {name}: неверная битность (класс={ei_class}, ожидалось {expected_bits}-bit)")
        return False
    
    e_machine = struct.unpack("<H" if ei_data == 1 else ">H", header[18:20])[0]
    if e_machine != expected_machine:
        print(f"[FAIL] {name}: неверный e_machine (получено {e_machine}, ожидалось {expected_machine})")
        return False

    with open(path, "rb") as f:
        content = f.read()
        is_stripped = (b".debug_info" not in content)
    
    status_str = "stripped" if is_stripped else "not stripped"
    print(f"[OK] ELF {name}: {expected_bits}-bit, e_machine=0x{e_machine:x}, статус={status_str}")
    return True

def verify_dex_embedding(dex_file, header_file):
    if not os.path.isfile(dex_file) or not os.path.isfile(header_file):
        return False
    
    with open(dex_file, "rb") as f:
        dex_bytes = f.read()
    
    dex_sha256 = hashlib.sha256(dex_bytes).hexdigest()
    
    with open(header_file, "r", encoding="utf-8", errors="replace") as f:
        h_text = f.read()
    
    hex_values = re.findall(r"0x([0-9a-fA-F]{2})", h_text)
    embedded_bytes = bytes([int(h, 16) for h in hex_values])
    embedded_sha256 = hashlib.sha256(embedded_bytes).hexdigest()
    
    if dex_sha256 != embedded_sha256:
        print(f"[FAIL] Несоответствие SHA-256 встроенного DEX и smart_reward_core.dex:\n  DEX:    {dex_sha256}\n  HEADER: {embedded_sha256}")
        return False
    
    print(f"[OK] SHA-256 встроенного DEX и файла полностью совпадают ({dex_sha256[:16]}...)")
    return True

def verify_version_consistency(base_dir):
    errors = 0
    prop_path = os.path.join(base_dir, "module.prop")
    update_path = os.path.join(base_dir, "update.json")
    java_path = os.path.join(base_dir, "src", "ecubz", "smartreward", "zygisk", "SmartRewardCore.java")
    dex_path = os.path.join(base_dir, "zygisk", "smart_reward_core.dex")
    customize_path = os.path.join(base_dir, "customize.sh")

    props = {}
    if os.path.isfile(prop_path):
        with open(prop_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    props[k.strip()] = v.strip()

    prop_ver = props.get("version", "")
    prop_vcode = int(props.get("versionCode", 0)) if props.get("versionCode", "").isdigit() else 0

    print(f"[INFO] module.prop version={prop_ver}, versionCode={prop_vcode}")

    # 1. Проверка update.json
    if not os.path.isfile(update_path):
        print(f"[FAIL] update.json отсутствует!")
        errors += 1
    else:
        try:
            with open(update_path, "r", encoding="utf-8") as f:
                up_data = json.load(f)
            
            up_ver = up_data.get("version", "")
            up_vcode = up_data.get("versionCode", 0)
            zip_url = up_data.get("zipUrl", "")

            if up_ver != prop_ver:
                print(f"[FAIL] Несоответствие version: module.prop ({prop_ver}) != update.json ({up_ver})")
                errors += 1
            else:
                print(f"[OK] update.json version совпадает ({up_ver})")

            if up_vcode != prop_vcode:
                print(f"[FAIL] Несоответствие versionCode: module.prop ({prop_vcode}) != update.json ({up_vcode})")
                errors += 1
            else:
                print(f"[OK] update.json versionCode совпадает ({up_vcode})")

            expected_zip_name = f"{props.get('id')}_{prop_ver}_{prop_vcode}.zip"
            if expected_zip_name not in zip_url:
                print(f"[FAIL] update.json zipUrl ({zip_url}) не содержит ожидаемое имя архива ({expected_zip_name})")
                errors += 1
            else:
                print(f"[OK] update.json zipUrl корректно ссылается на {expected_zip_name}")

        except Exception as e:
            print(f"[FAIL] Ошибка парсинга update.json: {e}")
            errors += 1

    # 2. Проверка Java исходника
    if os.path.isfile(java_path):
        with open(java_path, "r", encoding="utf-8") as f:
            j_text = f.read()
        if prop_ver not in j_text:
            print(f"[FAIL] SmartRewardCore.java не содержит текущую версию ({prop_ver})")
            errors += 1
        else:
            print(f"[OK] SmartRewardCore.java содержит актуальную версию ({prop_ver})")

        found_versions = set(re.findall(r'v[23]\.\d+\.\d+', j_text))
        for old_ver in found_versions:
            if old_ver != prop_ver:
                print(f"[FAIL] SmartRewardCore.java содержит устаревший маркер версии: {old_ver} (ожидается только {prop_ver})")
                errors += 1

    # 3. Проверка скомпилированного DEX
    if os.path.isfile(dex_path):
        with open(dex_path, "rb") as f:
            d_bytes = f.read()
        if prop_ver.encode("utf-8") not in d_bytes:
            print(f"[FAIL] smart_reward_core.dex не содержит актуальный байтовый маркер версии ({prop_ver})")
            errors += 1
        else:
            print(f"[OK] smart_reward_core.dex подтвержден маркером версии ({prop_ver})")

        found_dex_vers = set(re.findall(rb'v[23]\.\d+\.\d+', d_bytes))
        for old_b in found_dex_vers:
            old_str = old_b.decode('utf-8', errors='ignore')
            if old_str != prop_ver:
                print(f"[FAIL] smart_reward_core.dex содержит устаревший байтовый маркер: {old_str} (ожидается только {prop_ver})")
                errors += 1

    # 4. Проверка customize.sh
    if os.path.isfile(customize_path):
        with open(customize_path, "r", encoding="utf-8") as f:
            c_text = f.read()
        if "grep -Fxq" not in c_text:
            print(f"[FAIL] customize.sh должен использовать 'grep -Fxq' для точного полнострочного поиска")
            errors += 1
        else:
            print(f"[OK] customize.sh использует строгое сопоставление 'grep -Fxq'")
        
        if c_text.count('echo "unknown"') < 2:
            print("[FAIL] customize.sh должен читать version/versionCode только из module.prop")
            errors += 1
        else:
            print("[OK] customize.sh использует module.prop как единственный источник версии")

    return errors == 0

def verify_configs(base_dir):
    errors = 0
    list_path = os.path.join(base_dir, "smart_reward.list")
    if os.path.isfile(list_path):
        with open(list_path, "r", encoding="utf-8") as f:
            valid_pkgs = 0
            for line_no, line in enumerate(f, 1):
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                if s.startswith("!"):
                    s = s[1:].strip()
                if s == "*" or s == "all":
                    valid_pkgs += 1
                    continue
                if "." not in s or len(s) < 3:
                    print(f"[FAIL] smart_reward.list строка {line_no}: некорректный формат пакета '{line.strip()}'")
                    errors += 1
                else:
                    valid_pkgs += 1
            print(f"[OK] smart_reward.list: {valid_pkgs} валидных правил пакетов")
    
    conf_path = os.path.join(base_dir, "il2cpp_hooks.conf")
    if os.path.isfile(conf_path):
        valid_actions = {
            "observe", "resolve", "bypass", "show", "ready",
            "callback", "always_true", "fast_pass", "show_and_reward",
            "reachability", "forward_interceptor", "intercept_events",
            "max_forward", "forward_event"
        }
        with open(conf_path, "r", encoding="utf-8") as f:
            valid_rules = 0
            for line_no, line in enumerate(f, 1):
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                if "::" not in s or "|" not in s:
                    print(f"[FAIL] il2cpp_hooks.conf строка {line_no}: отсутствует '::' или '|': '{s}'")
                    errors += 1
                    continue
                parts = s.split("|")
                if len(parts) < 3:
                    print(f"[FAIL] il2cpp_hooks.conf строка {line_no}: ожидалось минимум 3 сегмента: '{s}'")
                    errors += 1
                    continue
                action = parts[-2].strip().lower()
                if action not in valid_actions:
                    print(f"[WARN] il2cpp_hooks.conf строка {line_no}: неизвестное действие '{action}'")
                try:
                    argc = int(parts[-1].strip())
                    if argc < -1 or argc > 32:
                        print(f"[FAIL] il2cpp_hooks.conf строка {line_no}: недопустимый argc {argc}")
                        errors += 1
                except ValueError:
                    print(f"[FAIL] il2cpp_hooks.conf строка {line_no}: нечисловой argc '{parts[-1]}'")
                    errors += 1
                valid_rules += 1
            print(f"[OK] il2cpp_hooks.conf: {valid_rules} валидных правил резолва")
    
    return errors == 0

def verify_static_source_safety(base_dir):
    print("\n--- [2/2] Static Source Security Checks ---")
    errors = 0

    safe_mem_path = os.path.join(base_dir, "jni", "core", "safe_memory.hpp")
    if os.path.isfile(safe_mem_path):
        with open(safe_mem_path, "r", encoding="utf-8") as f:
            content = f.read()
        if "if (fd < 0) return true;" in content:
            print("[FAIL] safe_memory.hpp: обнаружен опасный fail-open паттерн 'if (fd < 0) return true;'")
            errors += 1
        elif "if (fd < 0) return false;" in content:
            print("[OK] safe_memory.hpp: подтверждена безопасная fail-closed логика 'if (fd < 0) return false;'")
        else:
            print("[WARN] safe_memory.hpp: проверка дескриптора fd не найдена")

    catalog_path = os.path.join(base_dir, "jni", "runtimes", "il2cpp", "il2cpp_catalog.cpp")
    if os.path.isfile(catalog_path):
        with open(catalog_path, "r", encoding="utf-8") as f:
            content = f.read()
        if "free(raw);" in content:
            print("[FAIL] il2cpp_catalog.cpp: обнаружен опасный системный free(raw) fallback")
            errors += 1
        else:
            print("[OK] il2cpp_catalog.cpp: память освобождается строго через экспортированный il2cpp_free")

    api_path = os.path.join(base_dir, "jni", "core", "il2cpp_api.cpp")
    if os.path.isfile(api_path):
        with open(api_path, "r", encoding="utf-8") as f:
            content = f.read()
        if ("cpp_args > 5" in content or "cpp_args > 3" in content or "cpp_args > 2" in content or "cpp_args > 4" in content or "pcount > 4" in content) and "method_get_return_type_" in content:
            print("[OK] il2cpp_api.cpp: подтвержден строгий отказ от неподдерживаемых ABI (argc > 5 и fail-closed return type)")
        else:
            print("[FAIL] il2cpp_api.cpp: отсутствует строгая валидация argc > 5 или return_type")
            errors += 1

        if "ScopedJniString" in content:
            print("[OK] il2cpp_api.cpp: подтверждено безопасное управление памятью JNI UTF через ScopedJniString")
        else:
            print("[FAIL] il2cpp_api.cpp: отсутствует RAII-управление памятью JNI UTF строк")
            errors += 1

        if "dispatch_hook_index" in content and "ShowTrampoline" in content and "OverrideApplied" in content:
            print("[OK] il2cpp_api.cpp: подтверждены индексированные трамплины (ShowTrampoline), точный SDK dispatch (dispatch_hook_index) и OverrideApplied")
        else:
            print("[FAIL] il2cpp_api.cpp: отсутствует вызов dispatch_hook_index, ShowTrampoline или OverrideApplied")
            errors += 1

    loader_path = os.path.join(base_dir, "jni", "core", "java_loader.cpp")
    if os.path.isfile(loader_path):
        with open(loader_path, "r", encoding="utf-8") as f:
            content = f.read()
        required_jni = ["nativeNotifyUnityReward", "nativeStartRewardTrace", "nativeRecordRewardStage", "nativeRecordReadyCheck"]
        missing_jni = [m for m in required_jni if m not in content]
        if not missing_jni:
            print("[OK] java_loader.cpp: подтверждена регистрация всех 4 JNI методов через RegisterNatives")
        else:
            print(f"[FAIL] java_loader.cpp: пропущены методы в RegisterNatives: {missing_jni}")
            errors += 1

    trace_path = os.path.join(base_dir, "jni", "core", "reward_trace.cpp")
    if os.path.isfile(trace_path):
        with open(trace_path, "r", encoding="utf-8") as f:
            content = f.read()
        if "update_telemetry" in content and "apply_event" in content and "to_json_summary_locked" in content:
            print("[OK] reward_trace.cpp: подтверждены Lifecycle Reducer (apply_event), Smart LRU, to_json_summary_locked и update_telemetry")
        else:
            print("[FAIL] reward_trace.cpp: отсутствуют вызовы update_telemetry, apply_event или to_json_summary_locked")
            errors += 1

    return errors == 0

def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    prop_ver = "unknown"
    prop_path = os.path.join(base_dir, "module.prop")
    if os.path.isfile(prop_path):
        with open(prop_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("version="):
                    prop_ver = line.split("=", 1)[1].strip()
                    break

    print("=" * 65)
    print(f" Углубленный аудит модуля {prop_ver}")
    print(" Автор: eCubz (https://t.me/eCubz)")
    print("=" * 65)

    errors = 0

    print("\n--- [1/2] Package Integrity & Binary Consistency Checks ---")
    required_files = [
        ("module.prop", "Метаданные модуля"),
        ("update.json", "Конфигурация авто-обновлений"),
        ("customize.sh", "Установочный скрипт"),
        ("service.sh", "Сервисный скрипт"),
        ("reporting.conf", "Конфигурация сбора отчетов и GC"),
        ("smart_reward.list", "Список целевых пакетов"),
        ("il2cpp_hooks.conf", "Конфигурация IL2CPP инспектора"),
        ("zygisk/smart_reward_core.dex", "Java DEX ядро"),
        ("zygisk/arm64-v8a.so", "Нативная библиотека arm64-v8a"),
        ("zygisk/armeabi-v7a.so", "Нативная библиотека armeabi-v7a"),
        ("zygisk/x86.so", "Нативная библиотека x86"),
        ("zygisk/x86_64.so", "Нативная библиотека x86_64"),
    ]

    for rel_path, desc in required_files:
        full_path = os.path.join(base_dir, rel_path)
        if not check_file(full_path, desc):
            errors += 1

    elf_specs = [
        ("zygisk/arm64-v8a.so", 0xb7, 64, "ARM64-v8a"),
        ("zygisk/armeabi-v7a.so", 0x28, 32, "ARMv7-A"),
        ("zygisk/x86.so", 0x03, 32, "x86"),
        ("zygisk/x86_64.so", 0x3e, 64, "x86_64"),
    ]
    for rel_path, exp_mach, exp_bits, name in elf_specs:
        if not verify_elf_binary(os.path.join(base_dir, rel_path), exp_mach, exp_bits, name):
            errors += 1

    dex_path = os.path.join(base_dir, "zygisk", "smart_reward_core.dex")
    if os.path.isfile(dex_path):
        with open(dex_path, "rb") as f:
            magic = f.read(4)
        if magic != b"dex\n":
            print(f"[FAIL] Некорректный DEX заголовок в {dex_path}: {magic}")
            errors += 1
        else:
            print(f"[OK] DEX magic header корректен: {magic}")

    header_path = os.path.join(base_dir, "jni", "smart_reward_dex.h")
    if not verify_dex_embedding(dex_path, header_path):
        errors += 1

    text_files = [
        "module.prop",
        "update.json",
        "customize.sh",
        "service.sh",
        "reporting.conf",
        "smart_reward.list",
        "il2cpp_hooks.conf",
        "README.md",
        "CHANGELOG.md"
    ]
    for tf in text_files:
        p = os.path.join(base_dir, tf)
        if os.path.isfile(p):
            if not check_line_endings_and_encoding(p):
                errors += 1
            else:
                print(f"[OK] Кодировка UTF-8 без BOM и LF окончания: {tf}")

    if not verify_configs(base_dir):
        errors += 1

    if not verify_version_consistency(base_dir):
        errors += 1

    if not verify_static_source_safety(base_dir):
        errors += 1

    print("-" * 65)
    if errors == 0:
        print("[SUCCESS] Package integrity and static source security checks passed!")
        return 0
    else:
        print(f"[FAILED] Обнаружено ошибок: {errors}. Исправьте их перед упаковкой.")
        return 1

if __name__ == "__main__":
    sys.exit(main())
