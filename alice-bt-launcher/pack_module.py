#!/usr/bin/env python3
import os
import zipfile

def pack_module():
    module_dir = os.path.dirname(os.path.abspath(__file__))
    output_dir = os.path.abspath(os.path.join(module_dir, '..', 'module'))
    os.makedirs(output_dir, exist_ok=True)
    
    zip_path = os.path.join(output_dir, 'alice-bt-launcher-v1.0.0.zip')
    
    # Расширения файлов для нормализации LF
    text_extensions = ('.sh', '.prop', '.conf', '.rule', '.json', '.md')
    
    # Перечень исключаемых файлов
    exclude_files = {'pack_module.py', '.git', '.gitignore'}
    
    print(f"Сборка модуля из: {module_dir}")
    print(f"Целевой архив: {zip_path}")
    
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(module_dir):
            for file in files:
                if file in exclude_files or file.endswith('.zip'):
                    continue
                
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, module_dir)
                
                # Позикс-нормализация путей в архиве (ОБЯЗАТЕЛЬНОЕ ПРАВИЛО ПРОЕКТА)
                arcname = rel_path.replace('\\', '/')
                
                # Нормализация окончаний строк LF для текстовых файлов
                if file.endswith(text_extensions):
                    with open(full_path, 'rb') as f:
                        content = f.read()
                    # Замена CRLF на LF
                    content = content.replace(b'\r\n', b'\n')
                    zipf.writestr(arcname, content)
                    print(f"  + Добавлен (LF normalized): {arcname}")
                else:
                    zipf.write(full_path, arcname)
                    print(f"  + Добавлен: {arcname}")
                    
    print(f"\n[OK] Модуль успешно собран и упакован в: {zip_path}")
    return zip_path

if __name__ == '__main__':
    pack_module()
