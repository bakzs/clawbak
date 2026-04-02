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
import json, pathlib, re, sys

home = pathlib.Path(sys.argv[1]).expanduser()
snap = pathlib.Path(sys.argv[2])

secret_key_pat=__REDACTED__
    r'(secret|token|api[_-]?key|password|passwd|bearer|cookie|session|credential|private[_-]?key|client[_-]?secret|refresh[_-]?token|access[_-]?token)',
    re.I,
)
token_pat=__REDACTED__
    r'(sk-ant-[A-Za-z0-9_\-]+|sk-[A-Za-z0-9_\-]{20,}|ghp_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9\-]{20,}|xox[baprs]-[A-Za-z0-9\-]{10,}|ntn_[A-Za-z0-9]+|AIza[0-9A-Za-z\-_]{20,})'
)
bearer_pat=__REDACTED__

def redact_text(s: str) -> str:
    out = []
    for line in s.splitlines():
        m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$', line)
        if m and secret_key_pat.search(m.group(1)):
            out.append(f"{m.group(1)}=__REDACTED__")
            continue
        line = bearer_pat.sub(r'\1__REDACTED__', line)
        line = token_pat.sub("__REDACTED__", line)
        out.append(line)
    return "\n".join(out) + ("\n" if s.endswith("\n") else "")

def redact_obj(x):
    if isinstance(x, dict):
        y = {}
        for k, v in x.items():
            if secret_key_pat.search(str(k)):
                y[k] = "__REDACTED__"
            else:
                y[k] = redact_obj(v)
        return y
    if isinstance(x, list):
        return [redact_obj(v) for v in x]
    if isinstance(x, str):
        x = bearer_pat.sub(r'\1__REDACTED__', x)
        x = token_pat.sub("__REDACTED__", x)
        return x
    return x

def copy_text(src: pathlib.Path, dst: pathlib.Path):
    if not src.exists() or not src.is_file():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(redact_text(src.read_text(errors="ignore")))

def copy_json(src: pathlib.Path, dst: pathlib.Path):
    if not src.exists() or not src.is_file():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        data = json.loads(src.read_text(errors="ignore"))
        dst.write_text(json.dumps(redact_obj(data), indent=2, sort_keys=True) + "\n")
    except Exception:
        dst.write_text(redact_text(src.read_text(errors="ignore")))

# Whitelist only
copy_json(home / ".openclaw" / "openclaw.json", snap / "config" / "openclaw.json.redacted")
copy_json(home / ".openclaw" / "agents" / "main" / "agent" / "models.json", snap / "config" / "models.json.redacted")
copy_json(home / ".openclaw" / "agents" / "main" / "agent" / "auth-profiles.json", snap / "config" / "auth-profiles.json.redacted")

copy_text(home / ".config" / "systemd" / "user" / "openclaw-gateway.service", snap / "systemd" / "openclaw-gateway.service.redacted")
copy_text(home / ".config" / "systemd" / "user" / "openclaw-gateway.service.bak", snap / "systemd" / "openclaw-gateway.service.bak.redacted")

# .env template: keys only
envp = home / ".openclaw" / ".env"
if envp.exists():
    keys = []
    for line in envp.read_text(errors="ignore").splitlines():
        m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=', line)
        if m:
            keys.append(f"{m.group(1)}=")
    (snap / "config" / "openclaw.env.template").write_text("\n".join(keys) + ("\n" if keys else ""))

# Optional known local scripts, only from home root
for name in [
    "snapshot_openclaw.sh",
    "snapshot_openclaw_safe.sh",
    "snapshot_openclaw_safe_v2.sh",
]:
    src = home / name
    if src.exists():
        copy_text(src, snap / "scripts" / name)

# Candidate inventory only; do not auto-copy
exclude_prefixes = [
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

with (snap / "inventory" / "candidate-custom-files.tsv").open("w") as out:
    for p in sorted(home.rglob("*")):
        if not p.is_file():
            continue
        try:
            rel = str(p.relative_to(home))
        except Exception:
            continue
        if rel.startswith("clawbak-snapshot-") or rel.startswith("clawbak-snapshot-safe-"):
            continue
        if any(rel == x or rel.startswith(x + "/") for x in exclude_prefixes):
            continue
        if re.search(r'(openclaw|clawbak|clawbot)', rel, re.I):
            try:
                out.write(f"{p.stat().st_size}\t{rel}\n")
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
  grep -RInE \
    --exclude='secret-scan.txt' \
    --exclude='snapshot_openclaw.sh' \
    --exclude='snapshot_openclaw_safe.sh' \
    --exclude='snapshot_openclaw_safe_v2.sh' \
    '(sk-ant-[A-Za-z0-9_\-]+|sk-[A-Za-z0-9_\-]{20,}|ghp_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9\-]{20,}|xox[baprs]-[A-Za-z0-9\-]{10,}|ntn_[A-Za-z0-9]+|AIza[0-9A-Za-z\-_]{20,}|Authorization: Bearer __REDACTED__ \
    . || true
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
