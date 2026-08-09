import os
import sys
import hashlib
import zipfile

def update_sha256sums(bin_dir):
    sums_file = os.path.join(bin_dir, "SHA256SUMS")
    bins = ["aiunblock-router", "curl"]
    lines = []
    for b in bins:
        b_path = os.path.join(bin_dir, b)
        if os.path.exists(b_path):
            with open(b_path, "rb") as f:
                h = hashlib.sha256(f.read()).hexdigest()
            lines.append(f"{h}  {b}\n")
            print(f"Calculated SHA256 for {b}: {h}")
    with open(sums_file, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(lines)
    print(f"Updated {sums_file}")

def pack_zip(project_dir, output_zip, file_list):
    print(f"Packing ZIP: {output_zip}")
    with zipfile.ZipFile(output_zip, 'w', zipfile.ZIP_DEFLATED) as zf:
        for item in file_list:
            full_path = os.path.join(project_dir, item)
            if not os.path.exists(full_path):
                print(f"Warning: {full_path} not found, skipping...")
                continue
            if os.path.isfile(full_path):
                arcname = item.replace('\\', '/')
                zf.write(full_path, arcname)
                print(f"  + {arcname}")
            elif os.path.isdir(full_path):
                for root, dirs, files in os.walk(full_path):
                    for f in files:
                        file_full = os.path.join(root, f)
                        rel_path = os.path.relpath(file_full, project_dir)
                        arcname = rel_path.replace('\\', '/')
                        zf.write(file_full, arcname)
                        print(f"  + {arcname}")

if __name__ == '__main__':
    proj = r"f:\Antigravity\MagiskModuls\module\AIUnblock"
    out = r"f:\Antigravity\MagiskModuls\module\AIUnblock_v2.2.7_229.zip"
    
    bin_path = os.path.join(proj, "bin")
    if os.path.exists(bin_path):
        update_sha256sums(bin_path)

    files = [
        "module.prop",
        "service.sh",
        "customize.sh",
        "action.sh",
        "post-fs-data.sh",
        "uninstall.sh",
        "skip_mount",
        "sni_routes.conf",
        "proxies.conf",
        "proxies.override.example",
        "smartdns.conf",
        "smartdns.user.conf.example",
        "bin",
        "system",
        "META-INF",
        "CHANGELOG.md"
    ]
    pack_zip(proj, out, files)
