#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ObjC 元数据还原：classlist -> class_ro_t -> method_list
支持 absolute 与 relative method list。
输出 JSON: 类名 -> {superclass, methods:[{sel,types}], ivars}
"""
import struct, sys, json, os

class Bin:
    def __init__(self, path):
        self.f = open(path, 'rb')
        self.buf = self.f.read()
        self.segs = []
        self.sects = {}
        self._parse()

    def _parse(self):
        b = self.buf
        assert b[:4] == b'\xcf\xfa\xed\xfe', 'not arm64 macho'
        e = '<'
        cputype, cpusub, ft, ncmds, szcmds, flags = struct.unpack(e + 'IIIIII', b[4:28])
        o = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack(e + 'II', b[o:o + 8])
            if cmd == 0x19:
                body = b[o + 8:o + size]
                seg = body[0:16].rstrip(b'\0').decode('utf-8', 'replace')
                vm, vs, fo, fs = struct.unpack(e + 'QQQQ', body[16:48])
                ns = struct.unpack(e + 'I', body[56:60])[0]
                self.segs.append((seg, vm, vs, fo, fs))
                so = 64
                for _j in range(ns):
                    sb = body[so:so + 80]; so += 80
                    sn = sb[0:16].rstrip(b'\0').decode('utf-8', 'replace')
                    sg = sb[16:32].rstrip(b'\0').decode('utf-8', 'replace')
                    ad, sz = struct.unpack(e + 'QQ', sb[32:48])
                    off = struct.unpack(e + 'I', sb[48:52])[0]
                    self.sects[(sg, sn)] = (ad, sz, off)
            o += size
        self.segs.sort(key=lambda x: -x[1])

    def off_of(self, vm):
        for seg, vma, vsz, fo, fs in self.segs:
            if vma <= vm < vma + vsz:
                delta = vm - vma
                if delta < fs:
                    return fo + delta
                return None
        return None

    def read(self, vm, n):
        off = self.off_of(vm)
        if off is None or off + n > len(self.buf):
            return None
        return self.buf[off:off + n]

    def cstr(self, vm):
        off = self.off_of(vm)
        if off is None:
            return None
        end = self.buf.find(b'\0', off)
        if end < 0:
            return None
        try:
            return self.buf[off:end].decode('utf-8')
        except Exception:
            return self.buf[off:end].decode('latin-1')


def parse_method_list(bn, addr):
    """返回 [(sel, types)]"""
    hdr = bn.read(addr, 8)
    if not hdr:
        return []
    entsize_flags, count = struct.unpack('<II', hdr)
    if count > 20000 or count == 0:
        return []
    is_rel = bool(entsize_flags & 0x80000000)
    entsize = entsize_flags & 0x0000FFFF
    out = []
    if is_rel:
        if entsize != 12:
            return []
        data = bn.read(addr + 8, count * 12)
        if not data:
            return []
        for i in range(count):
            name_off, types_off = struct.unpack('<ii', data[i * 12:i * 12 + 8])
            sel = bn.cstr(addr + 8 + i * 12 + name_off)
            types = bn.cstr(addr + 8 + i * 12 + 4 + types_off)
            out.append((sel, types))
    else:
        if entsize < 24:
            entsize = 24
        data = bn.read(addr + 8, count * entsize)
        if not data:
            return []
        for i in range(count):
            e = data[i * entsize:i * entsize + 16]
            if len(e) < 16:
                break
            sel_p, types_p = struct.unpack('<QQ', e)
            out.append((bn.cstr(sel_p), bn.cstr(types_p)))
    return out


def parse_classlist(bn):
    sec = bn.sects.get(('__DATA_CONST', '__objc_classlist')) or bn.sects.get(('__DATA', '__objc_classlist'))
    addr, size, _off = sec
    data = bn.read(addr, size)
    n = size // 8
    classes = []
    for i in range(n):
        ptr = struct.unpack('<Q', data[i * 8:i * 8 + 8])[0]
        ptr &= 0x00007FFFFFFFFFFF
        if ptr == 0:
            continue
        info = parse_class(bn, ptr)
        if info:
            classes.append(info)
    return classes


def parse_class(bn, cls_vm):
    d = bn.read(cls_vm, 40)
    if not d:
        return None
    isa, sup, cache, vtable, data_p = struct.unpack('<QQQQQ', d)
    ro_p = data_p & 0x00007FFFFFFFFFF8
    ro = bn.read(ro_p, 72)
    if not ro:
        return None
    flags, istart, isize, reserved = struct.unpack('<IIII', ro[0:16])
    ivar_layout, name_p, methods_p, protos_p, ivars_p, weak_p, props_p = struct.unpack('<QQQQQQQ', ro[16:72])
    name = bn.cstr(name_p)
    methods = parse_method_list(bn, methods_p) if methods_p else []
    ib = bn.read(ivar_list_hdr := ivars_p, 8) if ivars_p else None
    ivars = []
    if ib:
        entsize, cnt = struct.unpack('<II', ib)
        if 0 < cnt < 5000 and 24 <= entsize <= 64:
            raw = bn.read(ivars_p + 8, cnt * entsize)
            for k in range(cnt):
                nm_p = struct.unpack('<Q', raw[k * entsize + 8:k * entsize + 16])[0]
                ivars.append(bn.cstr(nm_p))
    return {'name': name, 'methods': methods, 'ivars': ivars, 'flags': flags}


if __name__ == '__main__':
    path = sys.argv[1]
    out_path = sys.argv[2]
    bn = Bin(path)
    cls = parse_classlist(bn)
    print('parsed classes:', len(cls))
    d = {}
    for c in cls:
        if not c or not c['name']:
            continue
        d[c['name']] = {'m': [s for s, t in c['methods']], 't': {s: t for s, t in c['methods']}, 'iv': c['ivars']}
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False)
    print('written', out_path, os.path.getsize(out_path))
