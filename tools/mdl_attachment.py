#!/usr/bin/env python3
"""Adds attachments to a compiled GoldSrc model (.mdl) without decompiling it.

  python3 mdl_attachment.py model.mdl --list
  python3 mdl_attachment.py model.mdl --add Bone_AK47 0 -30 2 -o model_new.mdl
  python3 mdl_attachment.py model.mdl --screen-top-center -o model_new.mdl

--add takes: <bone name or index> <x> <y> <z>, the position is in the bone's local space
(the same numbers as "$attachment <index> <bone> <x> <y> <z>" in the QC file).

--screen-top-center places the attachment where a viewmodel shows it at the top and exactly in the
middle of the screen: the point is in front of the eye (x = --depth), centered (y = 0) and up
(z = depth * --top 0.70, a 90 degree field of view has its top edge at about 0.75). The bone is
chosen automatically: the one whose attached point moves the least in the idle / shoot
animations (a bone attachment always follows the animation, so draw and reload still move it).

How it works: the attachment table sits between the bone and the hitbox tables, so it cannot
grow in place. The new table (old entries + the new one) is appended to the end of the file and
the header (numattachments, attachmentindex, file length) points to it. The old table is left
unused. Nothing else in the model moves.
"""
import argparse
import math
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


def angle_matrix(a):
    sr, cr = math.sin(a[0]), math.cos(a[0])
    sp, cp = math.sin(a[1]), math.cos(a[1])
    sy, cy = math.sin(a[2]), math.cos(a[2])
    return [[cp * cy, sr * sp * cy - cr * sy, cr * sp * cy + sr * sy],
            [cp * sy, sr * sp * sy + cr * cy, cr * sp * sy - sr * cy],
            [-sp, sr * cp, cr * cp]]


def read_anim_value(d, base, offset, frame):
    p = base + offset
    k = frame
    while d[p + 1] <= k:
        k -= d[p + 1]
        p += (d[p] + 1) * 2
    valid = d[p]
    index = k + 1 if valid > k else valid
    return struct.unpack('<h', d[p + index * 2:p + index * 2 + 2])[0]


def sequences(d, h):
    out = []
    for i in range(h['numseq']):
        o = h['seqindex'] + i * 176
        name = cstr(d[o:o + 32])
        frames = struct.unpack('<i', d[o + 56:o + 60])[0]
        animindex = struct.unpack('<i', d[o + 124:o + 128])[0]
        group = struct.unpack('<i', d[o + 156:o + 160])[0]
        out.append((name, frames, animindex, group))
    return out


def pose(d, h, seq, frame):
    """World transform (rotation, translation) of every bone for a sequence frame."""
    _, _, animindex, group = seq
    if group != 0:
        sys.exit('Animations in external sequence groups are not supported')

    mats = []
    for b in range(h['numbones']):
        o = h['boneindex'] + b * BONE_SIZE
        parent = struct.unpack('<i', d[o + 32:o + 36])[0]
        default = struct.unpack('<6f', d[o + 64:o + 88])
        scale = struct.unpack('<6f', d[o + 88:o + 112])
        base = animindex + b * 12
        offsets = struct.unpack('<6H', d[base:base + 12])

        v = list(default)
        for j in range(6):
            if offsets[j]:
                v[j] = default[j] + read_anim_value(d, base, offsets[j], frame) * scale[j]

        rot, pos = angle_matrix(v[3:6]), v[0:3]

        if parent >= 0:
            prot, ppos = mats[parent]
            rot = [[sum(prot[r][k] * rot[k][c] for k in range(3)) for c in range(3)] for r in range(3)]
            pos = [sum(prot[r][k] * pos[k] for k in range(3)) + ppos[r] for r in range(3)]

        mats.append((rot, pos))
    return mats


def to_world(mat, p):
    rot, pos = mat
    return [sum(rot[r][k] * p[k] for k in range(3)) + pos[r] for r in range(3)]


def to_local(mat, p):
    rot, pos = mat
    q = [p[i] - pos[i] for i in range(3)]
    return [sum(rot[r][c] * q[r] for r in range(3)) for c in range(3)]


def screen_top_center(d, h, depth, top):
    """Finds the bone and local position that keep a point at the top center of the view."""
    seqs = sequences(d, h)
    target = [depth, 0.0, depth * top]

    rest = pose(d, h, seqs[0], 0)
    wanted = [i for i, s in enumerate(seqs) if s[0].lower().startswith(('idle', 'shoot', 'fire', 'attack'))] or [0]
    poses = [pose(d, h, seqs[i], f) for i in wanted for f in range(seqs[i][1])]

    best = None
    for b in range(h['numbones']):
        local = to_local(rest[b], target)
        devs = [math.dist(to_world(p[b], local), target) for p in poses]
        rms = math.sqrt(sum(x * x for x in devs) / len(devs))

        if best is None or rms < best[0]:
            best = (rms, max(devs), b, local)

    return best, target


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
    ap.add_argument('--screen-top-center', action='store_true', help='attach to the top center of the screen')
    ap.add_argument('--depth', type=float, default=30.0, help='distance in front of the eye (default 30)')
    ap.add_argument('--top', type=float, default=0.70, help='height as a fraction of the depth (default 0.70)')
    ap.add_argument('-o', '--output', help='output file (default: <model>_attach.mdl)')
    args = ap.parse_args()

    d = open(args.model, 'rb').read()
    h = read_header(d)

    if args.screen_top_center:
        (rms, worst, bone_index, local), target = screen_top_center(d, h, args.depth, args.top)
        bone = str(bone_index)
        x, y, z = local
        print('Target in view space: %.1f %.1f %.1f' % tuple(target))
        print('Bone %d (%s), local %.3f %.3f %.3f, movement in idle/shoot: rms %.2f, worst %.2f' % (
            bone_index, bones(d, h)[bone_index][0], x, y, z, rms, worst))
    elif args.list or not args.add:
        list_model(d, h)
        return
    else:
        bone, x, y, z = args.add

    new, number = add(d, h, bone, float(x), float(y), float(z))

    output = args.output or args.model.rsplit('.', 1)[0] + '_attach.mdl'
    open(output, 'wb').write(new)

    print('Added attachment %d to %s' % (number, output))
    list_model(new, read_header(new))


if __name__ == '__main__':
    main()
