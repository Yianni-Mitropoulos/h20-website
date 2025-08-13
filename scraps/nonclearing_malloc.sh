#!/bin/bash

# ========================
#  Install prerequisites
# ========================
until sudo apt update; do sleep 1; done
until sudo apt install -y git build-essential cmake pkg-config; do sleep 1; done

# ========================
#  Clone repository
# ========================
rm -rf hardened_malloc
until git clone https://github.com/GrapheneOS/hardened_malloc.git; do sleep 1; done
cd hardened_malloc

# ========================
#  Build default version
# ========================
until make clean; do sleep 1; done
until make RELEASE=1; do sleep 1; done
cp out/libhardened_malloc.so ../libhardened_malloc_default.so

# ========================
#  Build non-clearing version
# ========================
# Override configuration via environment variables
export CONFIG_ZERO_ON_FREE=0
export CONFIG_WRITE_AFTER_FREE_CHECK=0
until make clean; do sleep 1; done
until make RELEASE=1; do sleep 1; done
cp out/libhardened_malloc.so ../libhardened_malloc_nonclearing.so

# ========================
#  Package both versions
# ========================
cd ..
tar -czf libhardened_malloc_variants.tar.gz libhardened_malloc_default.so libhardened_malloc_nonclearing.so

# ========================
#  Qubes copy to VM
# ========================
until sync; do sleep 1; done
until qvm-copy-to-vm d12 libhardened_malloc_variants.tar.gz; do sleep 1; done

################################################

#!/bin/bash

# Define source directory (adjust dispYYYY as needed if not automatic)
SRC_DIR="/home/user/QubesIncoming/dispYYYY"

# Verify the source directory exists
if [ ! -d "$SRC_DIR" ]; then
  echo "[ERROR] Source directory not found: $SRC_DIR"
  exit 1
fi

cd "$SRC_DIR" || exit 1

# Extract the tarball and remove it
tar -xzf libhardened_malloc_variants.tar.gz && rm libhardened_malloc_variants.tar.gz

# Move both libraries into place
mv libhardened_malloc_default.so /usr/lib/
mv libhardened_malloc_nonclearing.so /usr/lib/
chmod 755 /usr/lib/libhardened_malloc_*.so

# Add default allocator to global preload if not already present
grep -qxF "/usr/lib/libhardened_malloc_default.so" /etc/ld.so.preload || echo "/usr/lib/libhardened_malloc_default.so" >> /etc/ld.so.preload
echo "[INFO] libhardened_malloc_default is now active for all dynamically linked binaries"

# Add toggle function to user's .bashrc
BASHRC="/home/user/.bashrc"
cat <<'EOF' >> "$BASHRC"

# Toggle allocator for a given binary: default <-> nonclearing
fh20-toggle-alloc() {
  local target="$1"
  local launcher="${target}.fh20"

  if [[ -z "$target" || ! -x "$target" ]]; then
    echo "Usage: fh20-toggle-alloc /full/path/to/executable"
    return 1
  fi

  if [[ -f "$launcher" ]]; then
    rm "$launcher"
    echo "[fh20-toggle-alloc] Restored default allocator for: $target"
  else
    echo -e "#!/bin/bash\nLD_PRELOAD=/usr/lib/libhardened_malloc_nonclearing.so exec \"$target\" \"\$@\"" > "$launcher"
    chmod +x "$launcher"
    echo "[fh20-toggle-alloc] Enabled nonclearing allocator for: $target (use $launcher)"
  fi
}
EOF

chown user:user "$BASHRC"
echo "[INFO] fh20-toggle-alloc function added to /home/user/.bashrc"
