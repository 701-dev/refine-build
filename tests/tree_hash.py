#  The tree hash of hash/tree/tree.ldn, made a second time from what that
#  file's opening comment says and nothing else, so that tests/run.sh can
#  hold the tool to the form it documents.
#
#  Usage: python3 tree_hash.py DIRECTORY [NAME-TO-LEAVE-OUT...]
import hashlib
import os
import stat
import sys


def records(directory, relative, leave):
    for name in os.listdir(directory):
        if not relative and name in leave:
            continue
        path = os.path.join(directory, name)
        below = relative + b"/" + name if relative else name
        status = os.lstat(path)
        if stat.S_ISLNK(status.st_mode):
            target = os.readlink(path)
            yield below, b"l", len(target).to_bytes(8, "big") + target
        elif stat.S_ISDIR(status.st_mode):
            yield below, b"d", b""
            yield from records(path, below, leave)
        elif stat.S_ISREG(status.st_mode):
            with open(path, "rb") as file:
                content = file.read()
            kind = b"x" if status.st_mode & 0o100 else b"f"
            yield (below, kind, len(content).to_bytes(8, "big")
                   + hashlib.sha256(content).digest())
        else:
            sys.exit(f"{path!r} has no record")


root = os.fsencode(sys.argv[1])
leave = {os.fsencode(name) for name in sys.argv[2:]}
whole = hashlib.sha256(b"landin-tree-1\n")
for below, kind, rest in sorted(records(root, b"", leave)):
    whole.update(kind + len(below).to_bytes(8, "big") + below + rest)
print(whole.hexdigest())
