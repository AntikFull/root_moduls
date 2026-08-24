#!/usr/bin/env python3
import os
import zipfile

def get_prop_dict(prop_path):
    props = {}
    if os.path.exists(prop_path):
        with open(prop_path, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    k, v = line.split('=', 1)
                    props[k.strip()] = v.strip()
    return props

def pack_module():
    module_dir = os.path.dirname(os.path.abspath(__file__))
    prop_path = os.path.join(module_dir, 'module.prop')
    props = get_prop_dict(prop_path)
    
    mod_id = props.get('id', 'alice-bt-launcher')
    version = props.get('version', 'v1.1.0')
    version_code = props.get('versionCode', '110')
    
    # Целевой каталог для релизов
    output_dir = os.path.abspath(os.path.join(module_dir, '..', 'releases'))
    os.makedirs(output_dir, exist_ok=True)
    
    zip_name = f"{mod_id}_{version}_{version_code}.zip"
    zip_path = os.path.join(output_dir, zip_name)
    
    # Текстовые расширения для принудительной конвертации CRLF -> LF
    text_extensions = ('.sh', '.prop', '.conf', '.rule', '.json', '.md', 'update-binary', 'updater-script')
    
    # Исключаемые файлы и каталоги
    exclude_items = {'pack_module.py', '.git', '.gitignore', 'reports', 'debug.log'}
    
    print(f"Сборка модуля: {mod_id} ({version}_{version_code})")
    print(f"Целевой архив: {zip_path}")
    
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(module_dir):
            # Фильтрация директорий
            dirs[:] = [d for d in dirs if d not in exclude_items]
            
            for file in files:
                if file in exclude_items or file.endswith('.zip') or file.endswith('.tmp') or file == 'debug.log':
                    continue
                
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, module_dir)
                
                # POSIX-нормализация путей
                arcname = rel_path.replace('\\', '/')
                
                # Нормализация LF
                if file.endswith(text_extensions) or file in text_extensions:
                    with open(full_path, 'rb') as f:
                        content = f.read()
                    content = content.replace(b'\r\n', b'\n')
                    zipf.writestr(arcname, content)
                    print(f"  + [LF] {arcname}")
                else:
                    zipf.write(full_path, arcname)
                    print(f"  + {arcname}")
                    
    print(f"\n[OK] Модуль успешно упакован: {zip_path}")
    return zip_path

if __name__ == '__main__':
    pack_module()

