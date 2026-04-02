set -Eeuo pipefail
umask 077

STAMP="$(date +%Y%m%d-%H%M%S)"
SNAP="$HOME/clawbak-snapshot-safe-$STAMP"

mkdir -p "$SNAP"/{config,systemd,scripts,docs,manifests,inventory}
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

python3 - "$HOME" "$SNAP" <<'PY'
import json
import os
import pathlib
import re
import sys

home = pathlib.Path(sys.argv[1]).expanduser()
snap = pathlib.Path(sys.argv[2])

SECRET_KEY_PAT=__REDACTED__
    r'(secret|token|api[_-]?key|password|passwd|bearer|cookie|session|credential|private[_-]?key|client[_-]?secret|refresh[_-]?token|access[_-]?token)',
    re.I,
)

TOKEN_PAT=__REDACTED__
    r'(sk-ant-[A-Za-z0-9_\-]+|sk-[A-Za-z0-9_\-]{20,}|ghp_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9\-]{20,}|xox[baprs]-[A-Za-z0-9\-]{10,}|ntn_[A-Za-z0-9]+|AIza[0-9A-Za-z\-_]{20,})'
)

AUTH_BEARER_PAT=__REDACTED__

SAFE_SUFFIXES = {
    ".sh", ".py", ".js", ".ts", ".mjs", ".cjs",
    ".service", ".timer", ".conf", ".md", ".txt",
    ".yaml", ".yml", ".json"
}

EXCLUDE_PREFIXES = [
    ".openclaw/browser",
    ".openclaw/workspace",
    ".openclaw/cron",
    ".openclaw/backups",
    ".openclaw/completions",
    ".openclaw/agents/main/sessions",
    ".config/systemd/user/default.target.wants",
    ".npm-global",
    ".Trash",
]

def redact_obj(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if SECRET_KEY_PAT.search(str(k)):
                out[k] = "__REDACTED__"
            else:
                out[k] = redact_obj(v)
        return out
    if isinstance(obj, list):
        return [redact_obj(x) for x in obj]
    if isinstance(obj, str):
        obj = AUTH_BEARER_PAT.sub(r'\1__REDACTED__', obj)
        obj = TOKEN_PAT.sub("__REDACTED__", obj)
        return obj
    return obj

def redact_text(s: str) -> str:
    lines = []
    for line in s.splitlines():
        m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$', line)
        if m and SECRET_KEY_PAT.search(m.group(1)):
            lines.append(f"{m.group(1)}=__REDACTED__")
            continue
        line = AUTH_BEARER_PAT.sub(r'\1__REDACTED__', line)
        line = TOKEN_PAT.sub("__REDACTED__", line)
        lines.append(line)
    return "\n".join(lines) + ("\n" if s.endswith("\n") else "")

def write_text_redacted(src: pathlib.Path, dst: pathlib.Path):
    if not src.exists() or not src.is_file():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(redact_text(src.read_text(errors="ignore")))

def write_json_redacted(src: pathlib.Path, dst: pathlib.Path):
    if not src.exists() or not src.is_file():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        data = json.loads(src.read_text(errors="ignore"))
        dst.write_text(json.dumps(redact_obj(data), indent=2, sort_keys=True) + "\n")
    except Exception:
        dst.write_text(redact_text(src.read_text(errors="ignore")))

# Redacted systemd units
for rel in [
    ".config/systemd/user/openclaw-gateway.service",
    ".config/systemd/user/openclaw-gateway.service.bak",
]:
    src = home / rel
    if src.exists():
        write_text_redacted(src, snap / "systemd" / src.name)

# Redacted config and selected agent metadata
write_json_redacted(home / ".openclaw" / "openclaw.json", snap / "config" / "openclaw.json.redacted")
write_json_redacted(home / ".openclaw" / "agents" / "main" / "agent" / "models.json", snap / "config" / "models.json")
write_json_redacted(home / ".openclaw" / "agents" / "main" / "agent" / "auth-profiles.json", snap / "config" / "auth-profiles.json")

# .env template with only variable names
env_path = home / ".openclaw" / ".env"
if env_path.exists():
    lines = []
    for line in env_path.read_text(errors="ignore").splitlines():
        m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=', line)
        if m:
            lines.append(f"{m.group(1)}=")
    (snap / "config" / "openclaw.env.template").write_text("\n".join(lines) + ("\n" if lines else ""))

# Inventory of intentionally excluded paths
with (snap / "inventory" / "excluded-paths.txt").open("w") as out:
    for p in EXCLUDE_PREFIXES:
        out.write(p + "\n")

# Search for likely custom user-authored files and copy only small text files
with (snap / "inventory" / "candidate-custom-files.tsv").open("w") as out:
    for root, dirs, files in os.walk(home):
        root_path = pathlib.Path(root)
        rel_root = "." if root_path == home else str(root_path.relative_to(home))

        # prune obvious noise
        dirs[:] = [d for d in dirs if d not in {".git", "node_modules", "__pycache__", ".venv", "venv", ".cache"}]

        if rel_root != ".":
            if any(rel_root == p or rel_root.startswith(p + "/") for p in EXCLUDE_PREFIXES):
                dirs[:] = []
                continue

        for name in files:
            src = root_path / name
            try:
                rel = str(src.relative_to(home))
                size = src.stat().st_size
            except Exception:
                continue

            if not re.search(r'(openclaw|clawbak|clawbot)', rel, re.I):
                continue

            out.write(f"{size}\t{rel}\n")

            if src.suffix.lower() not in SAFE_SUFFIXES:
                continue
            if size > 256_000:
                continue
            if any(rel == p or rel.startswith(p + "/") for p in EXCLUDE_PREFIXES):
                continue

            dst = snap / "scripts" / "home" / rel
            write_text_redacted(src, dst)
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
  grep -RInE --exclude='secret-scan.txt' '(sk-ant-[A-Za-z0-9_\-]+|sk-[A-Za-z0-9_\-]{20,}|ghp_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9\-]{20,}|xox[baprs]-[A-Za-z0-9\-]{10,}|ntn_[A-Za-z0-9]+|AIza[0-9A-Za-z\-_]{20,}|BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|Authorization: Bearer __REDACTED__ . || true
} > inventory/secret-scan.txt

ln -sfn "$SNAP" "$HOME/clawbak-snapshot-safe-latest"

echo
echo "DONE"
echo "Snapshot dir: $SNAP"
echo "Convenience symlink: $HOME/clawbak-snapshot-safe-latest"
echo
echo "Review these next:"
echo "  sed -n '1,160p' \"$HOME/clawbak-snapshot-safe-latest/inventory/secret-scan.txt\""
echo "  sed -n '1,200p' \"$HOME/clawbak-snapshot-safe-latest/inventory/candidate-custom-files.tsv\""
echo "  find \"$HOME/clawbak-snapshot-safe-latest\" -maxdepth 3 -type f | sort"
