#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
inject_dylib.py —— 把 dylib 注入 iOS App 主二进制。

做两件事：
  1. 复制 dylib 到 <App>.app/Frameworks/
  2. 在主二进制的 Mach-O load commands 空隙里追加一条 LC_LOAD_DYLIB

不修改任何代码段，文件总长度不变（只用 header 与 __text 之间的 padding），
因此不会破坏原有段偏移；签名由后续签名工具（Sideloadly / zsign / ldid）重做。

用法:
    python3 inject_dylib.py <Payload/Runner.app 或 .ipa> [dylib路径]
"""

import struct
import sys
import os
import shutil
import zipfile
import tempfile

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC

CPU_ARM64 = 0x0100000C


def align(v, a=8):
    return (v + a - 1) // a * a


def find_macho(path):
    """返回 (fileobj, list_of_(offset, size, cputype))"""
    f = open(path, 'r+b')
    head = f.read(8)
    if len(head) < 8:
        raise SystemExit('文件太小')
    magic = struct.unpack('>I', head[:4])[0]
    slices = []
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack('>I', head[4:8])[0]
        f.seek(0)
        f.read(8)
        for i in range(n):
            if magic == FAT_MAGIC:
                raw = f.read(20)
                cpu, sub, off, size, al = struct.unpack('>IIIII', raw)
            else:
                raw = f.read(32)
                cpu, sub, off, size, al, _r = struct.unpack('>IIQQII', raw)
            slices.append((off, size, cpu))
    else:
        f.seek(0)
        m = struct.unpack('<I', f.read(4))[0]
        if m != MH_MAGIC_64:
            raise SystemExit('不是 64 位 Mach-O')
        size = os.path.getsize(path)
        slices.append((0, size, CPU_ARM64))
    return f, slices


def inject_slice(f, base, dylib_path):
    f.seek(base)
    hdr = f.read(32)
    magic = struct.unpack('<I', hdr[0:4])[0]
    if magic != MH_MAGIC_64:
        return False, '跳过：非 arm64 MH_MAGIC_64 切片'
    cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack('<IIIIII', hdr[4:28])

    cmds_start = base + 32
    cmds_end = cmds_start + sizeofcmds

    # 扫描 load commands，找一个最小的节区文件偏移作为可写上限
    o = cmds_start
    limit = None
    has_dylib = False
    for _ in range(ncmds):
        f.seek(o)
        cmd, size = struct.unpack('<II', f.read(8))
        if cmd == LC_SEGMENT_64:
            f.seek(o + 8)
            body = f.read(size - 8)
            segname = body[0:16].rstrip(b'\0').decode('utf-8', 'replace')
            nsects = struct.unpack('<I', body[56:60])[0]
            so = 64
            for _j in range(nsects):
                sb = body[so:so + 80]
                so += 80
                sect_off = struct.unpack('<I', sb[48:52])[0]
                sect_size = struct.unpack('<Q', sb[40:48])[0]
                if sect_off > 0 and sect_size > 0:
                    if limit is None or sect_off < limit:
                        limit = sect_off
        elif cmd == LC_LOAD_DYLIB:
            f.seek(o + 8)
            noff = struct.unpack('<I', f.read(4))[0]
            f.seek(o + noff)
            name = b''
            while True:
                c = f.read(1)
                if not c or c == b'\0':
                    break
                name += c
            if name.decode('utf-8', 'replace').endswith(os.path.basename(dylib_path)):
                has_dylib = True
        o += size

    if has_dylib:
        return True, '已存在同名 LC_LOAD_DYLIB，跳过'
    if limit is None:
        return False, '未找到节区偏移上限'

    install_name = '@executable_path/Frameworks/' + os.path.basename(dylib_path)
    name_bytes = install_name.encode('utf-8') + b'\0'
    needed = 8 + 24 + len(name_bytes)
    needed = align(needed, 8)

    free = limit - cmds_end
    if free < needed:
        return False, 'header 空隙不足：需要 %d，可用 %d' % (needed, free)

    # 写入 dylib_command
    cmd = struct.pack('<II', LC_LOAD_DYLIB, needed)
    cmd += struct.pack('<IIII', 24, 2, 0x10000, 0x10000)   # offset, timestamp, current, compat
    cmd += name_bytes
    cmd += b'\0' * (needed - len(cmd))

    f.seek(cmds_end)
    f.write(cmd)

    # 更新 header 计数
    f.seek(base + 16)
    f.write(struct.pack('<II', ncmds + 1, sizeofcmds + needed))

    return True, '注入成功：%s（占用 %d 字节，空隙余 %d）' % (install_name, needed, free - needed)


def process(app_dir, dylib_path):
    info_plist = os.path.join(app_dir, 'Info.plist')
    exe = None
    try:
        import plistlib
        with open(info_plist, 'rb') as fh:
            pl = plistlib.load(fh)
        exe = pl.get('CFBundleExecutable')
    except Exception:
        pass
    if not exe:
        raise SystemExit('无法读取 CFBundleExecutable')
    bin_path = os.path.join(app_dir, exe)
    if not os.path.exists(bin_path):
        raise SystemExit('主二进制不存在: ' + bin_path)

    # 1) 复制 dylib
    fw_dir = os.path.join(app_dir, 'Frameworks')
    os.makedirs(fw_dir, exist_ok=True)
    dst = os.path.join(fw_dir, os.path.basename(dylib_path))
    shutil.copy2(dylib_path, dst)
    os.chmod(dst, 0o755)
    print('[+] dylib 已放入: %s (%.1f KB)' % (dst, os.path.getsize(dst) / 1024))

    # 2) 注入 load command
    f, slices = find_macho(bin_path)
    try:
        for (off, size, cpu) in slices:
            if cpu not in (CPU_ARM64,):
                print('[-] 跳过切片 cpu=0x%x' % cpu)
                continue
            ok, msg = inject_slice(f, off, dylib_path)
            print(('[+] ' if ok else '[!] ') + msg)
    finally:
        f.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    target = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    dylib = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, 'XianYuPiggyHand.dylib')
    if not os.path.exists(dylib):
        raise SystemExit('dylib 不存在: ' + dylib)

    if target.lower().endswith('.ipa'):
        tmp = tempfile.mkdtemp(prefix='phinject_')
        print('[*] 解包 IPA -> %s' % tmp)
        with zipfile.ZipFile(target) as z:
            z.extractall(tmp)
        payload = os.path.join(tmp, 'Payload')
        app = None
        for d in os.listdir(payload):
            if d.endswith('.app'):
                app = os.path.join(payload, d)
                break
        if not app:
            raise SystemExit('IPA 内未找到 .app')
        process(app, dylib)

        out = os.path.splitext(target)[0] + '_injected.ipa'
        print('[*] 重新打包 -> %s' % out)
        if os.path.exists(out):
            os.remove(out)
        with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
            for root, _dirs, files in os.walk(tmp):
                for fn in files:
                    fp = os.path.join(root, fn)
                    arc = os.path.relpath(fp, tmp)
                    z.write(fp, arc)
        print('[✓] 完成（未签名）。请用 Sideloadly / ESign / zsign 重新签名后安装。')
        print('    产物: %s' % out)
    else:
        process(target, dylib)
        print('[✓] 完成（未签名）。请重新签名主二进制与 dylib 后再安装。')


if __name__ == '__main__':
    main()
