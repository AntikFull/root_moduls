#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Автоматический кроссплатформенный компилятор нативного Zygisk модуля Smart Reward Bypass.
Автор: eCubz (https://t.me/eCubz)
"""

import os
import sys
import subprocess
import shutil
import argparse
import glob

def resolve_executable(value):
    if not value:
        return ""
    if os.path.isfile(value):
        return value
    return shutil.which(value) or value

def find_jdk():
    if os.environ.get("JAVA_HOME") and os.path.isdir(os.environ["JAVA_HOME"]):
        return os.environ["JAVA_HOME"]
    default_jdk = r"C:\Program Files\Java\jdk-25.0.2"
    if os.path.isdir(default_jdk):
        return default_jdk
    java_dirs = sorted(glob.glob(r"C:\Program Files\Java\jdk-*"), reverse=True)
    if java_dirs:
        return java_dirs[0]
    return ""

def find_android_sdk():
    for var in ["ANDROID_SDK_ROOT", "ANDROID_HOME"]:
        if os.environ.get(var) and os.path.isdir(os.environ[var]):
            return os.environ[var]
    default_sdk = os.path.expanduser(r"~\AppData\Local\Android\Sdk")
    if os.path.isdir(default_sdk):
        return default_sdk
    return ""

def find_latest_build_tool(sdk_path, tool_name):
    bt_dir = os.path.join(sdk_path, "build-tools")
    if not os.path.isdir(bt_dir):
        return ""
    versions = sorted(os.listdir(bt_dir), reverse=True)
    for v in versions:
        candidate = os.path.join(bt_dir, v, tool_name)
        if os.path.exists(candidate):
            return candidate
        if os.name == "nt":
            for ext in [".bat", ".cmd", ".exe"]:
                candidate_ext = candidate + ext
                if os.path.exists(candidate_ext):
                    return candidate_ext
    return ""

def find_latest_platform(sdk_path):
    pf_dir = os.path.join(sdk_path, "platforms")
    if not os.path.isdir(pf_dir):
        return ""
    platforms = sorted([p for p in os.listdir(pf_dir) if p.startswith("android-")], reverse=True)
    for p in platforms:
        jar = os.path.join(pf_dir, p, "android.jar")
        if os.path.isfile(jar):
            return jar
    return ""

def find_ndk_bin(sdk_path):
    if os.environ.get("NDK_BIN") and os.path.isdir(os.environ["NDK_BIN"]):
        return os.environ["NDK_BIN"]
    ndk_dir = os.path.join(sdk_path, "ndk")
    if not os.path.isdir(ndk_dir):
        return ""
    ndk_versions = sorted(os.listdir(ndk_dir), reverse=True)
    for nv in ndk_versions:
        prebuilt_dir = os.path.join(ndk_dir, nv, "toolchains", "llvm", "prebuilt")
        if os.path.isdir(prebuilt_dir):
            for host in os.listdir(prebuilt_dir):
                candidate_bin = os.path.join(prebuilt_dir, host, "bin")
                if os.path.isdir(candidate_bin):
                    return candidate_bin
    return ""

def main():
    parser = argparse.ArgumentParser(description="Zygisk Smart Reward Bypass Builder")
    parser.add_argument("--clean", action="store_true", help="Очистить временные файлы сборки")
    parser.add_argument("--abi", choices=["all", "arm64-v8a", "armeabi-v7a", "x86", "x86_64"], default="all", help="Целевой ABI")
    parser.add_argument("--debug", action="store_true", help="Сборка с флагами отладки (-O0 -g)")
    args = parser.parse_args()

    module_dir = os.path.dirname(os.path.abspath(__file__))
    temp_dir = os.environ.get("SMART_REWARD_TEMP", os.path.join(module_dir, ".build", "smart_reward"))
    out_zygisk = os.path.join(module_dir, "zygisk")

    if args.clean:
        print("[*] Очистка временных каталогов сборки...")
        if os.path.isdir(temp_dir):
            shutil.rmtree(temp_dir)
        print("[OK] Очистка завершена.")
        return

    # Авто-поиск путей
    jdk_dir = find_jdk()
    javac_default = os.path.join(jdk_dir, "bin", "javac.exe" if os.name == "nt" else "javac") if jdk_dir else "javac"
    javac = resolve_executable(os.environ.get("JAVAC", javac_default))
    
    sdk_dir = find_android_sdk()
    d8 = resolve_executable(os.environ.get("D8", find_latest_build_tool(sdk_dir, "d8")))
    android_jar = os.environ.get("ANDROID_JAR", find_latest_platform(sdk_dir))
    ndk_bin = find_ndk_bin(sdk_dir)

    # Настройка окружения Java
    if jdk_dir:
        os.environ["JAVA_HOME"] = jdk_dir
        os.environ["PATH"] = os.path.join(jdk_dir, "bin") + os.pathsep + os.environ.get("PATH", "")

    src_java = os.path.join(module_dir, "src", "ecubz", "smartreward", "zygisk", "SmartRewardCore.java")
    header_dex = os.path.join(module_dir, "jni", "smart_reward_dex.h")

    cpp_sources = [
        os.path.join(module_dir, "jni", "main.cpp"),
        os.path.join(module_dir, "jni", "core", "target_filter.cpp"),
        os.path.join(module_dir, "jni", "core", "config.cpp"),
        os.path.join(module_dir, "jni", "core", "inline_hook.cpp"),
        os.path.join(module_dir, "jni", "core", "jni_bridge_hook.cpp"),
        os.path.join(module_dir, "jni", "core", "engine_probe.cpp"),
        os.path.join(module_dir, "jni", "core", "il2cpp_api.cpp"),
        os.path.join(module_dir, "jni", "core", "reward_trace.cpp"),
        os.path.join(module_dir, "jni", "core", "java_loader.cpp"),
        os.path.join(module_dir, "jni", "runtimes", "il2cpp", "il2cpp_catalog.cpp"),
        os.path.join(module_dir, "jni", "runtimes", "il2cpp", "managed_invoker.cpp"),
        os.path.join(module_dir, "jni", "adapters", "applovin_adapter.cpp"),
        os.path.join(module_dir, "jni", "adapters", "max_bridge.cpp"),
        os.path.join(module_dir, "jni", "adapters", "reward_channels.cpp"),
        os.path.join(module_dir, "jni", "adapters", "admob_adapter.cpp"),
        os.path.join(module_dir, "jni", "adapters", "unity_ads_adapter.cpp"),
        os.path.join(module_dir, "jni", "adapters", "ironsource_adapter.cpp"),
        os.path.join(module_dir, "jni", "adapters", "yandex_adapter.cpp"),
        os.path.join(module_dir, "jni", "discovery", "fingerprint.cpp"),
        os.path.join(module_dir, "jni", "discovery", "report_writer.cpp"),
        os.path.join(module_dir, "jni", "discovery", "auto_rule_engine.cpp"),
    ]

    print("=" * 65)
    print(" Сборщик Zygisk Smart Reward & Ad Bypass (Clang + In-Memory DEX)")
    print(" Автор: eCubz (https://t.me/eCubz)")
    print("=" * 65)
    print(f"[*] JDK:         {jdk_dir}")
    print(f"[*] javac:       {javac}")
    print(f"[*] D8:          {d8}")
    print(f"[*] android.jar: {android_jar}")
    print(f"[*] NDK bin:     {ndk_bin}")

    # Проверка наличия всех инструментов
    missing = []
    if not javac or not os.path.exists(javac): missing.append(f"javac: {javac}")
    if not d8 or not os.path.exists(d8): missing.append(f"D8: {d8}")
    if not os.path.exists(android_jar): missing.append(f"android.jar: {android_jar}")
    if not os.path.exists(ndk_bin): missing.append(f"NDK bin: {ndk_bin}")
    if not os.path.exists(src_java): missing.append(f"Java source: {src_java}")
    for src in cpp_sources:
        if not os.path.exists(src): missing.append(f"C++ source: {src}")

    if missing:
        print("\n[ERROR] Не найдены обязательные компоненты сборки:")
        for item in missing:
            print("  - " + item)
        sys.exit(1)

    os.makedirs(out_zygisk, exist_ok=True)
    os.makedirs(temp_dir, exist_ok=True)

    # Синхронизация версии из module.prop в SmartRewardCore.java
    prop_path = os.path.join(module_dir, "module.prop")
    version = "v0.0.0"
    version_code = "0"
    if os.path.isfile(prop_path):
        with open(prop_path, "r", encoding="utf-8") as f:
            for line in f:
                if "=" in line and not line.strip().startswith("#"):
                    k, v = line.split("=", 1)
                    if k.strip() == "version":
                        version = v.strip()
                    elif k.strip() == "versionCode":
                        version_code = v.strip()

    if os.path.isfile(src_java):
        with open(src_java, "r", encoding="utf-8") as f:
            java_code = f.read()
        import re
        java_code = re.sub(
            r'public\s+static\s+final\s+String\s+VERSION\s*=\s*\"[^\"]*\";',
            f'public static final String VERSION = "{version}";',
            java_code
        )
        java_code = re.sub(
            r'public\s+static\s+final\s+int\s+VERSION_CODE\s*=\s*\d+;',
            f'public static final int VERSION_CODE = {version_code};',
            java_code
        )
        with open(src_java, "w", encoding="utf-8", newline="\n") as f:
            f.write(java_code)
        print(f"[*] Синхронизирована версия из module.prop в SmartRewardCore.java: {version} ({version_code})")

    # Автоматическое обновление/генерация update.json
    update_json_path = os.path.join(module_dir, "update.json")
    update_json_content = f"""{{
  "version": "{version}",
  "versionCode": {version_code},
  "zipUrl": "https://raw.githubusercontent.com/AntikFull/root_moduls/main/zygisk_smart_reward_bypass/zygisk_smart_reward_bypass_{version}_{version_code}.zip",
  "changelog": "https://raw.githubusercontent.com/AntikFull/root_moduls/main/zygisk_smart_reward_bypass/CHANGELOG.md"
}}
"""
    with open(update_json_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(update_json_content)
    print(f"[*] Автоматически синхронизирован update.json с версией: {version} ({version_code})")

    # Автоматическое обновление fallback значений в customize.sh
    customize_sh_path = os.path.join(module_dir, "customize.sh")
    if os.path.isfile(customize_sh_path):
        with open(customize_sh_path, "r", encoding="utf-8") as f:
            cust_code = f.read()
        if cust_code.count('echo "unknown"') < 2:
            raise RuntimeError("customize.sh должен читать version/versionCode из module.prop без числовых fallback")
        print("[*] customize.sh использует module.prop как единственный источник версии")

    # 1. Сборка Java -> DEX
    print("\n[1/3] Компиляция SmartRewardCore.java -> classes.dex...")
    classes_dir = os.path.join(temp_dir, "classes")
    if os.path.isdir(classes_dir):
        shutil.rmtree(classes_dir)
    os.makedirs(classes_dir, exist_ok=True)

    javac_cmd = [
        javac,
        "-encoding", "UTF-8",
        "-source", "1.8",
        "-target", "1.8",
        "-cp", android_jar,
        "-d", classes_dir,
        src_java
    ]
    res = subprocess.run(javac_cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[ERROR] Ошибка компиляции Java (javac):\n{res.stderr}")
        sys.exit(1)

    dex_out_dir = os.path.join(temp_dir, "dex")
    if os.path.isdir(dex_out_dir):
        shutil.rmtree(dex_out_dir)
    os.makedirs(dex_out_dir, exist_ok=True)

    class_files = []
    for root, dirs, files in os.walk(classes_dir):
        for f in files:
            if f.endswith(".class"):
                class_files.append(os.path.join(root, f))

    d8_cmd = [d8, "--output", dex_out_dir, "--min-api", "26"] + class_files
    d8_exec = (["cmd", "/c"] + d8_cmd) if os.name == "nt" and d8.lower().endswith((".bat", ".cmd")) else d8_cmd
    res = subprocess.run(d8_exec, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"[ERROR] Ошибка создания DEX (d8):\n{res.stderr}")
        sys.exit(1)

    dex_src = os.path.join(dex_out_dir, "classes.dex")
    dex_dst = os.path.join(out_zygisk, "smart_reward_core.dex")
    shutil.copyfile(dex_src, dex_dst)
    print(f"[OK] smart_reward_core.dex успешно создан ({os.path.getsize(dex_dst)} байт)")

    # 2. Генерация C++ Header с байтами DEX (In-Memory Embedding)
    print("\n[2/3] Генерация smart_reward_dex.h для In-Memory загрузки...")
    with open(dex_src, "rb") as f:
        dex_bytes = f.read()

    hex_array = []
    for i, b in enumerate(dex_bytes):
        if i % 12 == 0:
            hex_array.append("\n    ")
        hex_array.append(f"0x{b:02x}, ")

    header_content = f"""#pragma once
#include <cstdint>
#include <cstddef>

// Автосгенерированный массив байт Java DEX ядра SmartRewardCore
static const uint8_t SMART_REWARD_DEX_BYTES[] = {{{''.join(hex_array)}
}};

static const size_t SMART_REWARD_DEX_SIZE = sizeof(SMART_REWARD_DEX_BYTES);
"""
    with open(header_dex, "w", encoding="utf-8", newline="\n") as f:
        f.write(header_content)
    print(f"[OK] smart_reward_dex.h сгенерирован ({len(dex_bytes)} байт DEX)")

    # 3. Сборка C++ -> .so
    print("\n[3/3] Компиляция нативных библиотек NDK Clang...")
    target_abis = {
        "arm64-v8a": ("aarch64-linux-android26-clang++", "arm64-v8a.so"),
        "armeabi-v7a": ("armv7a-linux-androideabi26-clang++", "armeabi-v7a.so"),
        "x86": ("i686-linux-android26-clang++", "x86.so"),
        "x86_64": ("x86_64-linux-android26-clang++", "x86_64.so"),
    }

    if args.abi != "all":
        target_abis = {args.abi: target_abis[args.abi]}

    opt_flags = ["-O0", "-g", "-fno-omit-frame-pointer"] if args.debug else [
        "-O2",
        "-DNDEBUG",
        # Отладочная информация нужна для разбора tombstone по смещениям.
        # На машинный код она не влияет и полностью удаляется при strip,
        # поэтому размер поставляемой библиотеки не меняется.
        "-g",
        "-fno-omit-frame-pointer",
        "-ffunction-sections",
        "-fdata-sections",
        "-Wl,--gc-sections",
        "-Wl,--exclude-libs,ALL",
        "-Wl,-z,max-page-size=16384"
    ]

    strip_tool = os.path.join(ndk_bin, "llvm-strip.exe" if os.name == "nt" else "llvm-strip")

    for abi, (compiler_base, so_name) in target_abis.items():
        compiler = os.path.join(ndk_bin, compiler_base + (".cmd" if os.name == "nt" else ""))
        if not os.path.exists(compiler):
            compiler = os.path.join(ndk_bin, compiler_base)

        so_dst = os.path.join(out_zygisk, so_name)
        abi_flags = ["-mbranch-protection=standard"] if abi == "arm64-v8a" else []
        cmd = [
            compiler,
            "-shared",
            "-fPIC",
            "-static-libstdc++",
            "-std=c++20",
            "-fstack-protector-strong",
            "-fno-rtti",
            "-fvisibility=hidden",
            "-fvisibility-inlines-hidden",
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
            f"-I{os.path.join(module_dir, 'jni')}",
        ] + abi_flags + opt_flags + cpp_sources + [
            "-o", so_dst,
            "-llog"
        ]

        print(f"[*] Сборка {so_name} ({abi})...")
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"[ERROR] Ошибка сборки {so_name}:\n{res.stderr}")
            sys.exit(1)
        
        # Strip неиспользуемых символов для release сборки
        # Отладочная копия сохраняется ДО удаления таблицы символов.
        # Адреса при strip не меняются, поэтому по смещению из tombstone
        # можно восстановить имя функции и строку исходника.
        symbols_dir = os.path.join(module_dir, ".build", "symbols")
        os.makedirs(symbols_dir, exist_ok=True)
        shutil.copy2(so_dst, os.path.join(symbols_dir, so_name))

        if not args.debug and os.path.exists(strip_tool):
            strip_cmd = [strip_tool, "--strip-unneeded", so_dst]
            subprocess.run(strip_cmd, capture_output=True)
            print(f"[OK] {so_name} успешно собран и stripped ({os.path.getsize(so_dst)} байт)")
        else:
            print(f"[OK] {so_name} успешно собран ({os.path.getsize(so_dst)} байт)")

    print("\n" + "=" * 65)
    print(" [+] ВСЕ АРТЕФАКТЫ УСПЕШНО СОБРАНЫ И ГОТОВЫ К РЕЛИЗУ!")
    print("=" * 65)

if __name__ == "__main__":
    main()
