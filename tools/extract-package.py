"""Extract an npm tarball into an ordinary, relocatable vendor directory."""
import io
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
with tarfile.open(fileobj=io.BytesIO(sys.stdin.buffer.read()), mode="r:gz") as archive:
    for member in archive:
        parts = pathlib.PurePosixPath(member.name).parts[1:]
        if not member.isfile() or not parts or ".." in parts:
            continue
        if any(p in (".git", ".github", "node_modules", "test", "tests", "docs") or p.startswith(".env") for p in parts):
            continue
        if parts[-1].endswith((".map", ".ts", ".tsbuildinfo")) or parts[-1] == "soljson.js":
            continue
        target = root.joinpath(*parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(archive.extractfile(member).read())
        if member.mode & 0o111:
            target.chmod(0o755)
