# Target path for the new desktop entry
DESKTOP_FILE="/usr/share/applications/debian-xterm-root.desktop"

# Create the .desktop file with full metadata
sudo tee "$DESKTOP_FILE" > /dev/null <<'EOF'
# This file was generated to provide a root xterm entry in Qubes
[Desktop Entry]
Name=XTerm (Root)
Comment=Run xterm as root using qvm-run
Exec=qvm-run -u root d12 xterm
Terminal=false
Type=Application
Icon=mini.xterm
Categories=System;TerminalEmulator;
Keywords=shell;prompt;command;commandline;cmd;
StartupWMClass=XTerm
X-Desktop-File-Install-Version=0.26
EOF

echo "✅ Created $DESKTOP_FILE"
echo "➡️  Now shut down the template VM and run:"
echo "   qvm-appmenus --update d12"