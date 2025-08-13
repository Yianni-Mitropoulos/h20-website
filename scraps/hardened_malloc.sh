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

# Add default allocator to global preload
echo "/usr/lib/libhardened_malloc_default.so" | sudo tee -a /etc/ld.so.preload
echo "[INFO] libhardened_malloc_default is now active for all dynamically linked binaries"

# Add toggle function to user's .bashrc
until echo '
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
' | sudo tee -a /etc/bash.bashrc > /dev/null; do sleep 1; done

# Make the new function available immediately
until source /etc/bash.bashrc; do sleep 1; done
echo "[INFO] fh20-toggle-alloc function added to /home/user/.bashrc"
