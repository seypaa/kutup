#!/usr/bin/env python3
"""Adds attachments to a compiled GoldSrc model (.mdl) without decompiling it.

  python3 mdl_attachment.py model.mdl --list
  python3 mdl_attachment.py model.mdl --add Bone_AK47 0 -30 2 -o model_new.mdl

--add takes: <bone name or index> <x> <y> <z>, the position is in the bone's local space
(the same numbers as "$attachment <index> <bone> <x> <y> <z>" in the QC file).

How it works: the attachment table sits between the bone and the hitbox tables, so it cannot
grow in place. The new table (old entries + the new one) is appended to the end of the file and
the header (numattachments, attachmentindex, file length) points to it. The old table is left
unused. Nothing else in the model moves.
"""
import argparse
import struct
import sys

ATTACH_SIZE = 88   # name[32], type, bone, org[3], vectors[3][3]
BONE_SIZE = 112
HEADER_FIELDS = ['flags', 'numbones', 'boneindex', 'numbonecontrollers', 'bonecontrollerindex',
                 'numhitboxes', 'hitboxindex', 'numseq', 'seqindex', 'numseqgroups', 'seqgroupindex',
                 'numtextures', 'textureindex', 'texturedataindex', 'numskinref', 'numskinfamilies',
                 'skinindex', 'numbodyparts', 'bodypartindex', 'numattachments', 'attachmentindex',
                 'soundtable', 'soundindex', 'soundgroups', 'soundgroupindex', 'numtransitions',
                 'transitionindex']
HEADER_OFFSET = 136


def read_header(d):
    if d[:4] != b'IDST' or struct.unpack('<i', d[4:8])[0] != 10:
        sys.exit('Not a GoldSrc studio model (IDST version 10)')
    values = struct.unpack('<27i', d[HEADER_OFFSET:HEADER_OFFSET + 108])
    return dict(zip(HEADER_FIELDS, values))


def cstr(b):
    return b.split(b'\0')[0].decode('latin-1')


def bones(d, h):
    out = []
    for i in range(h['numbones']):
        o = h['boneindex'] + i * BONE_SIZE
        out.append((cstr(d[o:o + 32]), struct.unpack('<i', d[o + 32:o + 36])[0]))
    return out


def attachments(d, h):
    out = []
    for i in range(h['numattachments']):
        o = h['attachmentindex'] + i * ATTACH_SIZE
        name = cstr(d[o:o + 32])
        typ, bone = struct.unpack('<2i', d[o + 32:o + 40])
        org = struct.unpack('<3f', d[o + 40:o + 52])
        out.append((name, typ, bone, org))
    return out


def list_model(d, h):
    bl = bones(d, h)
    print('Bones (%d):' % len(bl))
    for i, (name, parent) in enumerate(bl):
        print('  %2d  %-20s parent %d' % (i, name, parent))
    print('Attachments (%d):' % h['numattachments'])
    for i, (name, typ, bone, org) in enumerate(attachments(d, h)):
        print('  %d  bone %d (%s)  origin %.2f %.2f %.2f' % (i, bone, bl[bone][0], *org))


def add(d, h, bone, x, y, z):
    bl = bones(d, h)
    names = [b[0] for b in bl]

    if bone.isdigit():
        index = int(bone)
    elif bone in names:
        index = names.index(bone)
    else:
        sys.exit('Unknown bone %r, use --list to see the bones' % bone)

    if not 0 <= index < len(bl):
        sys.exit('Bone index out of range (0-%d)' % (len(bl) - 1))

    old = d[h['attachmentindex']:h['attachmentindex'] + h['numattachments'] * ATTACH_SIZE]

    entry = bytearray(ATTACH_SIZE)
    struct.pack_into('<2i', entry, 32, 0, index)
    struct.pack_into('<3f', entry, 40, x, y, z)
    # vectors[3][3] stay zero, the engine only uses the origin

    out = bytearray(d)
    while len(out) % 4:
        out.append(0)

    new_index = len(out)
    out += old + entry

    struct.pack_into('<i', out, HEADER_OFFSET + HEADER_FIELDS.index('numattachments') * 4, h['numattachments'] + 1)
    struct.pack_into('<i', out, HEADER_OFFSET + HEADER_FIELDS.index('attachmentindex') * 4, new_index)
    struct.pack_into('<i', out, 72, len(out))   # file length

    return bytes(out), h['numattachments']


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('model')
    ap.add_argument('--list', action='store_true', help='print bones and attachments')
    ap.add_argument('--add', nargs=4, metavar=('BONE', 'X', 'Y', 'Z'), help='add an attachment')
    ap.add_argument('-o', '--output', help='output file (default: <model>_attach.mdl)')
    args = ap.parse_args()

    d = open(args.model, 'rb').read()
    h = read_header(d)

    if args.list or not args.add:
        list_model(d, h)
        return

    bone, x, y, z = args.add
    new, number = add(d, h, bone, float(x), float(y), float(z))

    output = args.output or args.model.rsplit('.', 1)[0] + '_attach.mdl'
    open(output, 'wb').write(new)

    print('Added attachment %d to %s' % (number, output))
    list_model(new, read_header(new))


if __name__ == '__main__':
    main()
