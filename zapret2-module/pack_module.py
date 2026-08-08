import os
import zipfile

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_ZIP = os.path.abspath(os.path.join(SOURCE_DIR, "..", "..", "..", "module", "zapret2-v2.0.1-eCubz.zip"))

# Список исключений для упаковки
EXCLUDE_ITEMS = {
    ".git", ".github", ".gitignore", ".gitattributes", "pack_module.py", "install.zip", "install.zip.bak", "zygisk"
}

def fix_line_endings_and_pack():
    print(f"Packing module from {SOURCE_DIR} to {OUTPUT_ZIP}")
    os.makedirs(os.path.dirname(OUTPUT_ZIP), exist_ok=True)
    if os.path.exists(OUTPUT_ZIP):
        os.remove(OUTPUT_ZIP)

    with zipfile.ZipFile(OUTPUT_ZIP, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(SOURCE_DIR):
            # Фильтрация директорий
            dirs[:] = [d for d in dirs if d not in EXCLUDE_ITEMS]
            for file in files:
                if file in EXCLUDE_ITEMS or file.lower().endswith('.zip'):
                    continue
                file_path = os.path.join(root, file)
                rel_path = os.path.relpath(file_path, SOURCE_DIR).replace('\\', '/')

                # Преобразование окончаний строк LF для текстовых файлов
                if file.endswith(('.sh', '.prop', '.rule', '.conf', '.list', '.json', '.html', '.css', '.js')):
                    with open(file_path, 'rb') as f:
                        content = f.read()
                    content = content.replace(b'\r\n', b'\n')
                    zipf.writestr(rel_path, content)
                else:
                    zipf.write(file_path, rel_path)

    print(f"Successfully created zip: {OUTPUT_ZIP}")

if __name__ == "__main__":
    fix_line_endings_and_pack()
