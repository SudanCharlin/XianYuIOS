#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mach-O 轻量解析：提取 load commands / sections / objc 相关字符串
仅依赖标准库，用于 iOS 二进制静态侦察。
"""
import struct, sys, os, json, re

class MachO:
    def __init__(self, path):
        self.path = path
        self.f = open(path, 'rb')
        self.data = None
        self.sections = {}   # (seg, sect) -> (offset, size, addr)
        self.segments = []   # (name, vmaddr, vmsize, fileoff, filesize)
        self.libs = []
        self.archs = []
        self.cputype = 0
        self._parse()

    def _parse(self):
        f = self.f
        magic = f.read(4)
        f.seek(0)
        if magic in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
            hdr = f.read(8)
            n = struct.unpack('>I', hdr[4:8])[0]
            for i in range(n):
                f.seek(8 + i * 20)
                cpu, sub, off, size, align = struct.unpack('>IIIII', f.read(20))
                self.archs.append((cpu, sub, off, size))
            # 只解析 arm64 (cpu=0x0100000C)
            for cpu, sub, off, size in self.archs:
                if cpu == 0x0100000C:
                    self._parse_slice(off)
                    break
        else:
            self._parse_slice(0)

    def _parse_slice(self, base):
        f = self.f
        f.seek(base)
        hdr = f.read(32)
        magic = hdr[:4]
        endian = '<' if magic == b'\xcf\xfa\xed\xfe' else '>'
        self.endian = endian
        self.cputype, self.cpusub, ft, ncmds, szcmds, flags = struct.unpack(endian + 'IIIIII', hdr[4:28])
        self.base = base
        self.is64 = True
        o = base + 32
        for i in range(ncmds):
            f.seek(o)
            raw = f.read(8)
            if len(raw) < 8: break
            cmd, size = struct.unpack(endian + 'II', raw)
            body = f.read(size - 8)
            if cmd == 0x19:  # LC_SEGMENT_64
                segname = body[0:16].rstrip(b'\0').decode('utf-8', 'replace')
                vmaddr, vmsize, fileoff, filesize = struct.unpack(endian + 'QQQQ', body[16:48])
                nsects = struct.unpack(endian + 'I', body[56:60])[0]
                self.segments.append((segname, vmaddr, vmsize, fileoff, filesize))
                so = 64
                for s in range(nsects):
                    sb = body[so:so + 80]
                    so += 80
                    sectname = sb[0:16].rstrip(b'\0').decode('utf-8', 'replace')
                    segn = sb[16:32].rstrip(b'\0').decode('utf-8', 'replace')
                    addr, sz = struct.unpack(endian + 'QQ', sb[32:48])
                    offset = struct.unpack(endian + 'I', sb[48:52])[0]
                    self.sections[(segn, sectname)] = (offset, sz, addr)
            elif cmd == 0xC:  # LC_LOAD_DYLIB
                noff = struct.unpack(endian + 'I', body[0:4])[0]
                nm = body[noff:].split(b'\0')[0].decode('utf-8', 'replace')
                self.libs.append(nm)
            elif cmd in (0xD, 0x18 + 0x7ffffff):  # weak dylib
                try:
                    noff = struct.unpack(endian + 'I', body[0:4])[0]
                    nm = body[noff:].split(b'\0')[0].decode('utf-8', 'replace')
                    self.libs.append(nm)
                except Exception:
                    pass
            o += size

    def section_data(self, seg, sect):
        key = (seg, sect)
        if key not in self.sections:
            return None
        off, sz, addr = self.sections[key]
        if off == 0 or sz == 0:
            return b''
        self.f.seek(off)
        return self.f.read(sz)

    def cstr_list(self, seg, sect):
        d = self.section_data(seg, sect)
        if d is None:
            return []
        return [x.decode('utf-8', 'replace') for x in d.split(b'\0') if x]

if __name__ == '__main__':
    p = sys.argv[1]
    m = MachO(p)
    print('archs:', m.archs)
    print('cputype:', hex(m.cputype))
    print('segments:')
    for s in m.segments:
        print('  ', s[0], 'vm=%x size=%x off=%x fsize=%x' % (s[1], s[2], s[3], s[4]))
    print('objc sections:')
    for k in m.sections:
        if 'objc' in k[0] or k[0].startswith('__DATA'):
            print('  ', k, m.sections[k])
