set -Eeuo pipefail
umask 077

STAMP="$(date +%Y%m%d-%H%M%S)"
SNAP="$HOME/clawbak-snapshot-$STAMP"

mkdir -p "$SNAP"/{config,systemd,scripts,docs,manifests,patches,inventory}
cd "$SNAP"

git init -q
git branch -M main >/dev/null 2>&1 || true

cat > .gitignore <<'EOF'
.env
.env.*
*.pem
*.key
*.crt
*.p12
*.pfx
*.kdbx
*.sqlite
*.db
*.log
*.tmp
*.swp
*.bak
node_modules/
__pycache__/
.cache/
tmp/
logs/
downloads/
screenshots/
browser-profile/
.config/chromium/
.playwright/
EOF

{
  date -Is || true
  echo "user=$(whoami)"
  echo "host=$(hostname)"
  echo "snapshot_dir=$SNAP"
} > manifests/snapshot-meta.txt

uname -a > manifests/uname.txt 2>/dev/null || true
[ -r /etc/os-release ] && cp /etc/os-release manifests/os-release.txt || true
command -v lsb_release >/dev/null && lsb_release -a > manifests/lsb-release.txt 2>&1 || true
command -v git >/dev/null && git --version > manifests/git-version.txt 2>&1 || true
command -v python3 >/dev/null && python3 --version > manifests/python-version.txt 2>&1 || true
python3 -m pip freeze > manifests/pip-freeze.txt 2>/dev/null || true
command -v node >/dev/null && node --version > manifests/node-version.txt 2>&1 || true
command -v npm >/dev/null && npm --version > manifests/npm-version.txt 2>&1 || true
npm list -g --depth=0 > manifests/npm-global.txt 2>/dev/null || true
dpkg-query -W -f='${binary:Package}\t${Version}\n' > manifests/dpkg-packages.tsv 2>/dev/null || true
systemctl --user list-unit-files > manifests/systemctl-user-list-unit-files.txt 2>&1 || true
systemctl --user list-units --all > manifests/systemctl-user-list-units.txt 2>&1 || true
systemctl list-unit-files > manifests/systemctl-system-list-unit-files.txt 2>/dev/null || true

if command -v openclaw >/dev/null; then
  {
    echo "===== openclaw --version ====="
    openclaw --version || true
    echo
    echo "===== openclaw version ====="
    openclaw version || true
    echo
    echo "===== openclaw doctor ====="
    openclaw doctor || true
  } > manifests/openclaw-info.txt 2>&1
fi

if [ -f "$HOME/.openclaw/.env" ]; then
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$HOME/.openclaw/.env" | sed 's/=.*$/=/' > config/openclaw.env.template || true
fi

python3 - "$HOME" "$SNAP" <<'PY'
import os, sys, json, re, shutil, pathlib

home = pathlib.Path(sys.argv[1]).expanduser()
snap = pathlib.Path(sys.argv[2])

SECRET_KEY_PAT=__REDACTED__
    r'(secret|token|api[_-]?key|password|passwd|bearer|cookie|session|credential|private[_-]?key|client[_-]?secret|refresh[_-]?token|access[_-]?token)',
    re.I,
)
TOKEN_PAT=__REDACTED__
    r'(sk-[A-Za-z0-9]{10,}|sess-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{10,}|glpat-[A-Za-z0-9\-]{10,}|xox[baprs]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z\-_]{20,}|[A-Za-z0-9_\-]{24,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{20,})'
)

def redact(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if SECRET_KEY_PAT.search(str(k)):
                out[k] = "__REDACTED__"
            else:
                out[k] = redact(v)
        return out
    if isinstance(obj, list):
        return [redact(x) for x in obj]
    if isinstance(obj, str):
        if TOKEN_PAT.search(obj):
            return "__REDACTED__"
        return obj
    return obj

def redact_text(s: str) -> str:
    lines = []
    for line in s.splitlines():
        if re.match(r'^\s*[A-Za-z_][A-Za-z0-9_]*\s*=', line):
            key = line.split("=", 1)[0].strip()
            if SECRET_KEY_PAT.search(key):
                lines.append(f"{key}=__REDACTED__")
                continue
        line = TOKEN_PAT.sub("__REDACTED__", line)
        lines.append(line)
    return "\n".join(lines) + ("\n" if s.endswith("\n") else "")

pairs = [
    (home/".openclaw"/"openclaw.json", snap/"config"/"openclaw.json.redacted"),
    (home/".openclaw"/"openclaw.yaml", snap/"config"/"openclaw.yaml.redacted"),
    (home/".openclaw"/"config.json", snap/"config"/"config.json.redacted"),
    (home/".config"/"openclaw"/"openclaw.json", snap/"config"/"openclaw.config.json.redacted"),
]

for src, dst in pairs:
    if src.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            if src.suffix.lower() == ".json":
                data = json.loads(src.read_text())
                dst.write_text(json.dumps(redact(data), indent=2, sort_keys=True) + "\n")
            else:
                dst.write_text(redact_text(src.read_text()))
        except Exception:
            dst.write_text(redact_text(src.read_text()))

user_systemd = home/".config"/"systemd"/"user"
if user_systemd.exists():
    for p in user_systemd.iterdir():
        if p.is_file() and re.search(r'(openclaw|clawbak|clawbot)', p.name, re.I):
            shutil.copy2(p, snap/"systemd"/p.name)

sysd = pathlib.Path("/etc/systemd/system")
if sysd.exists():
    for p in sysd.iterdir():
        if p.is_file() and re.search(r'(openclaw|clawbak|clawbot)', p.name, re.I):
            try:
                shutil.copy2(p, snap/"systemd"/p.name)
            except Exception:
                pass

EXCLUDE_DIR_NAMES = {
    ".git", "node_modules", "__pycache__", ".venv", "venv",
    "tmp", "logs", "downloads", "screenshots"
}
EXCLUDE_PATH_PREFIXES = [
    home/".cache",
    home/".npm",
    home/".cargo",
    home/".rustup",
    home/".mozilla",
    home/".config"/"chromium",
]

candidate_paths = []

for root, dirs, files in os.walk(home):
    root_path = pathlib.Path(root)

    skip_root = False
    for p in EXCLUDE_PATH_PREFIXES:
        try:
            root_path.relative_to(p)
            skip_root = True
            break
        except Exception:
            pass
    if skip_root:
        dirs[:] = []
        continue

    dirs[:] = [
        d for d in dirs
        if d not in EXCLUDE_DIR_NAMES
        and not d.startswith(".git")
        and "clawbak-snapshot-" not in d
    ]

    for f in files:
        full = root_path / f
        try:
            rel = full.relative_to(home)
            srel = str(rel)
            if (
                re.search(r'(openclaw|clawbak|clawbot)', srel, re.I)
                or srel.startswith(".openclaw/")
                or srel.startswith(".config/systemd/user/")
            ):
                st = full.stat()
                candidate_paths.append((srel, st.st_size))
        except Exception:
            pass

with (snap/"inventory"/"candidate-files.tsv").open("w") as out:
    for path, size in sorted(candidate_paths):
        out.write(f"{size}\t{path}\n")

SCRIPT_EXTS = {
    ".sh", ".py", ".js", ".ts", ".mjs", ".cjs",
    ".service", ".timer", ".conf", ".md", ".txt",
    ".yaml", ".yml", ".json"
}

for path, size in candidate_paths:
    src = home / path
    if size > 512_000:
        continue
    if ".env" in src.name.lower():
        continue
    if re.search(r'(token|secret|cookie|session|credential|key)', path, re.I):
        continue

    if src.suffix.lower() in SCRIPT_EXTS or re.search(r'(openclaw|clawbak|clawbot)', path, re.I):
        dst = snap/"scripts"/"home"/path
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            text = src.read_text()
            dst.write_text(redact_text(text))
        except Exception:
            pass
PY

cat > docs/RESTORE_NOTES.md <<'EOF'
# Restore notes

Fill this in before pushing:

- VM name:
- Zone/region:
- OS image:
- How OpenClaw was installed:
- Where config lives:
- Which services are enabled:
- Which accounts/integrations exist (do not include secrets):
- Manual steps required after restore:
- Ports used / SSH tunnel commands:
EOF

{
  echo "Potential secret-like strings in snapshot content:"
  grep -RInE --exclude='secret-scan.txt' '(sk-[A-Za-z0-9]|ghp_[A-Za-z0-9]|glpat-|xox[baprs]-|AIza[0-9A-Za-z\-_]{20,}|BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|Authorization: Bearer|api[_-]?key|client[_-]?secret|refresh[_-]?token|access[_-]?token)' . || true
} > inventory/secret-scan.txt

git add .gitignore docs manifests config systemd scripts inventory
git status --short > inventory/git-status-before-commit.txt
git commit -m "Snapshot OpenClaw state (sanitized)" >/dev/null 2>&1 || true

ln -sfn "$SNAP" "$HOME/clawbak-snapshot-latest"

echo
echo "DONE"
echo "Snapshot dir: $SNAP"
echo "Convenience symlink: $HOME/clawbak-snapshot-latest"
echo
echo "Review these next:"
echo "  sed -n '1,160p' \"$HOME/clawbak-snapshot-latest/inventory/secret-scan.txt\""
echo "  sed -n '1,200p' \"$HOME/clawbak-snapshot-latest/inventory/candidate-files.tsv\""
echo "  find \"$HOME/clawbak-snapshot-latest\" -maxdepth 3 -type f | sort"
