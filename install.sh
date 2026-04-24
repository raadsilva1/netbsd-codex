#!/bin/sh
set -eu

CODEX_REPO="https://github.com/openai/codex.git"

# Pinned for systems with rustc 1.90.0.
# Newer Codex tags may require newer Rust.
CODEX_REF="${CODEX_REF:-rust-v0.87.0}"

SRC_DIR="$HOME/src/codex"
CODEX_RS_DIR="$SRC_DIR/codex-rs"
INSTALL_DIR="/usr/local/bin"
INSTALL_BIN="$INSTALL_DIR/codex"

say() {
  printf '\n==> %s\n' "$1"
}

warn() {
  printf '\nWARNING: %s\n' "$1" >&2
}

die() {
  printf '\nERROR: %s\n' "$1" >&2
  exit 1
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    sh -c "$1"
  elif command -v doas >/dev/null 2>&1; then
    doas sh -c "$1"
  elif command -v sudo >/dev/null 2>&1; then
    sudo sh -c "$1"
  else
    su root -c "$1"
  fi
}

say "Checking system"

OS_NAME="$(uname -s)"
if [ "$OS_NAME" != "NetBSD" ]; then
  warn "This script is intended for NetBSD. Detected: $OS_NAME"
fi

say "Uninstalling npm version of Codex, if present"

if command -v npm >/dev/null 2>&1; then
  if npm list -g --depth=0 2>/dev/null | grep '@openai/codex' >/dev/null 2>&1; then
    if npm uninstall -g @openai/codex; then
      say "Removed npm Codex package"
    else
      warn "npm uninstall failed as current user; trying with root privileges"
      run_as_root "npm uninstall -g @openai/codex"
    fi
  else
    say "No global npm @openai/codex package found"
  fi
else
  say "npm not found; skipping npm uninstall"
fi

hash -r 2>/dev/null || true

say "Installing NetBSD build dependencies"

if command -v pkgin >/dev/null 2>&1; then
  run_as_root "pkgin -y update"
  run_as_root "pkgin -y install git rust pkgconf openssl"
else
  die "pkgin was not found. Install pkgin/pkgsrc first, then rerun this script."
fi

say "Checking required commands"

command -v git >/dev/null 2>&1 || die "git not found"
command -v rustc >/dev/null 2>&1 || die "rustc not found"
command -v cargo >/dev/null 2>&1 || die "cargo not found"

printf 'rustc: '
rustc --version
printf 'cargo: '
cargo --version

say "Cloning or updating Codex source"

mkdir -p "$HOME/src"

if [ -d "$SRC_DIR/.git" ]; then
  say "Existing git repository found at $SRC_DIR"
  cd "$SRC_DIR"
  git fetch --tags --prune --force origin
elif [ -d "$SRC_DIR" ]; then
  die "$SRC_DIR exists but is not a git repository. Remove it or rename it, then rerun the script."
else
  say "Cloning Codex source into $SRC_DIR"
  git clone "$CODEX_REPO" "$SRC_DIR"
  cd "$SRC_DIR"
  git fetch --tags --prune --force origin
fi

say "Checking out Codex ref: $CODEX_REF"

git checkout -f "$CODEX_REF"
git reset --hard "$CODEX_REF"

[ -d "$CODEX_RS_DIR" ] || die "Could not find codex-rs directory"

cd "$CODEX_RS_DIR"

say "Preparing NetBSD build environment"

export PKG_CONFIG_PATH="/usr/pkg/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export OPENSSL_DIR="/usr/pkg"
export RUSTFLAGS="-C link-arg=-Wl,-R/usr/pkg/lib ${RUSTFLAGS:-}"

say "Repairing Codex release Cargo.lock workspace version mismatch"

cargo update --workspace

say "Building Codex Rust CLI with locked dependencies"

cargo build --release --locked --bin codex

[ -x "target/release/codex" ] || die "Build finished, but target/release/codex was not found"

say "Installing Codex to $INSTALL_BIN"

run_as_root "mkdir -p '$INSTALL_DIR'"
run_as_root "cp '$CODEX_RS_DIR/target/release/codex' '$INSTALL_BIN'"
run_as_root "chmod 755 '$INSTALL_BIN'"

say "Checking whether /usr/local/bin is in PATH"

case ":$PATH:" in
  *":/usr/local/bin:"*)
    say "/usr/local/bin is already in PATH"
    ;;
  *)
    warn "/usr/local/bin is not currently in PATH"
    warn "Add this to ~/.profile if needed:"
    printf '\n  export PATH="/usr/local/bin:$PATH"\n'
    ;;
esac

hash -r 2>/dev/null || true

say "Verifying Codex install"

if command -v codex >/dev/null 2>&1; then
  command -v codex
else
  warn "codex is installed at $INSTALL_BIN, but it is not currently on PATH"
fi

if "$INSTALL_BIN" --version >/dev/null 2>&1; then
  "$INSTALL_BIN" --version
elif "$INSTALL_BIN" -V >/dev/null 2>&1; then
  "$INSTALL_BIN" -V
else
  warn "Codex was installed, but version command did not return cleanly"
fi

say "Creating conservative Codex config"

mkdir -p "$HOME/.codex"

if [ -f "$HOME/.codex/config.toml" ]; then
  say "$HOME/.codex/config.toml already exists; leaving it unchanged"
else
  cat > "$HOME/.codex/config.toml" <<'EOF'
sandbox_mode = "read-only"
EOF
  say "Created $HOME/.codex/config.toml"
fi

say "Done"

cat <<EOF

Codex Rust CLI is installed at:

  $INSTALL_BIN

Built from Codex ref:

  $CODEX_REF

To use it:

  codex

If your shell cannot find it, run:

  export PATH="/usr/local/bin:\$PATH"

For workspace editing mode:

  codex --sandbox workspace-write

To update later while staying compatible with rustc 1.90.0:

  cd "$SRC_DIR"
  git fetch --tags --prune --force origin
  git checkout -f "$CODEX_REF"
  git reset --hard "$CODEX_REF"
  cd codex-rs
  export PKG_CONFIG_PATH="/usr/pkg/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"
  export OPENSSL_DIR="/usr/pkg"
  export RUSTFLAGS="-C link-arg=-Wl,-R/usr/pkg/lib \${RUSTFLAGS:-}"
  cargo update --workspace
  cargo build --release --locked --bin codex
  su root -c 'cp target/release/codex $INSTALL_BIN && chmod 755 $INSTALL_BIN'

To try a newer Codex tag later, run this script like:

  CODEX_REF=rust-v0.88.0 sh install-codex-netbsd.sh

But newer tags may require newer rustc.

EOF
