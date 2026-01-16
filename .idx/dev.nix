{ pkgs, ... }: {
  channel = "stable-24.11";

  packages = [
    pkgs.qemu
    pkgs.htop
    pkgs.cloudflared
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.wget
    pkgs.git
    pkgs.python3
    pkgs.dmg2img
    pkgs.p7zip
    pkgs.cdrkit
    pkgs.libguestfs
  ];

  idx.workspace.onStart = {
    macos = ''
      set -e

      # =========================
      # One-time cleanup
      # =========================
      if [ ! -f /home/user/.cleanup_done ]; then
        rm -rf /home/user/.gradle/* /home/user/.emu/* || true
        find /home/user -mindepth 1 -maxdepth 1 \
          ! -name 'OSX-KVM' \
          ! -name 'idx-macos' \
          ! -name 'idx-windows-gui' \
          ! -name '.cleanup_done' \
          ! -name '.*' \
          -exec rm -rf {} + || true
        touch /home/user/.cleanup_done
      fi

      # =========================
      # Setup KVM modules
      # =========================
      echo "Setting up KVM modules..."
      echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null || true

      # =========================
      # Paths
      # =========================
      PROJECT_DIR="$HOME/idx-macos"
      VM_DIR="$PROJECT_DIR/qemu-macos"
      MACOS_REPO="$PROJECT_DIR/OSX-KVM"
      MACOS_DOWNLOADS="$PROJECT_DIR/macos-downloads"
      BASE_SYSTEM="$VM_DIR/BaseSystem.img"
      BASE_SYSTEM_DMG="$MACOS_DOWNLOADS/BaseSystem.dmg"
      MAC_HDD="$VM_DIR/mac_hdd_ng.img"
      NOVNC_DIR="$PROJECT_DIR/noVNC"
      TEMP_DIR="$PROJECT_DIR/.tmp"
      OVMF_DIR="$MACOS_REPO"

      mkdir -p "$PROJECT_DIR"
      mkdir -p "$VM_DIR"
      mkdir -p "$MACOS_DOWNLOADS"
      mkdir -p "$TEMP_DIR"

      # =========================
      # Copy OSX-KVM repo if needed
      # =========================
      if [ ! -d "$MACOS_REPO" ]; then
        echo "Cloning OSX-KVM repository to $MACOS_REPO..."
        cd "$PROJECT_DIR"
        if ! git clone --depth 1 --recursive https://github.com/kholia/OSX-KVM.git; then
          echo "❌ Failed to clone OSX-KVM repository"
          exit 1
        fi
        if [ ! -d "$MACOS_REPO" ]; then
          echo "❌ OSX-KVM directory not found after clone"
          exit 1
        fi
      else
        echo "OSX-KVM repository already exists at $MACOS_REPO"
      fi

      cd "$MACOS_REPO" || { echo "❌ Failed to enter $MACOS_REPO"; exit 1; }

      # =========================
      # Download macOS Tahoe installer
      # =========================
      if [ ! -f "$BASE_SYSTEM" ]; then
        # Check if DMG already exists, if so, just convert it
        if [ ! -f "$BASE_SYSTEM_DMG" ]; then
          echo "Downloading macOS Tahoe installer to $MACOS_DOWNLOADS..."
          cd "$MACOS_DOWNLOADS" || { echo "❌ Failed to enter $MACOS_DOWNLOADS"; exit 1; }
          
          # Try downloading with the specified method
          if python3 "$MACOS_REPO/fetch-macOS-v2.py" --board-id Mac-27AD2F918AE68F61 --os-type default 2>&1 <<< "9"; then
            echo "✓ Downloaded successfully"
          else
            echo "⚠ First download attempt failed, trying alternative method..."
            if python3 "$MACOS_REPO/fetch-macOS-v2.py" 2>&1 <<< "9"; then
              echo "✓ Alternative download succeeded"
            else
              echo "❌ Failed to download macOS Tahoe installer"
              echo "Checking what files are in $MACOS_DOWNLOADS:"
              ls -lh "$MACOS_DOWNLOADS"
              exit 1
            fi
          fi
          
          # Check for the downloaded file and rename if needed
          echo "Checking for downloaded files in $MACOS_DOWNLOADS..."
          if [ -f "$MACOS_DOWNLOADS/BaseSystem.dmg" ]; then
            echo "✓ BaseSystem.dmg found at $MACOS_DOWNLOADS/BaseSystem.dmg"
          elif [ -f "BaseSystem.dmg" ]; then
            echo "✓ BaseSystem.dmg found in current directory, no move needed"
          else
            echo "❌ BaseSystem.dmg not found after download"
            echo "Files in $MACOS_DOWNLOADS:"
            ls -lh "$MACOS_DOWNLOADS" || true
            echo "Files in current directory:"
            ls -lh . || true
            exit 1
          fi
        else
          echo "BaseSystem.dmg already exists in $MACOS_DOWNLOADS, skipping download."
        fi

        # Convert BaseSystem.dmg to BaseSystem.img if needed
        if [ -f "$BASE_SYSTEM_DMG" ]; then
          echo "Converting $BASE_SYSTEM_DMG to $BASE_SYSTEM..."
          if ! dmg2img "$BASE_SYSTEM_DMG" "$BASE_SYSTEM"; then
            echo "❌ Failed to convert BaseSystem.dmg"
            exit 1
          fi
          echo "✓ Conversion complete"
          echo "✓ BaseSystem.img saved to: $BASE_SYSTEM"
        else
          echo "❌ BaseSystem.dmg not found at $BASE_SYSTEM_DMG"
          echo "Cannot proceed with conversion"
          exit 1
        fi
      else
        echo "macOS BaseSystem already exists, skipping download."
      fi

      # =========================
      # Create virtual HDD if missing
      # =========================
      if [ ! -f "$MAC_HDD" ]; then
        echo "Creating virtual HDD for macOS (24GB)..."
        if ! qemu-img create -f qcow2 "$MAC_HDD" 24G; then
          echo "❌ Failed to create virtual HDD"
          exit 1
        fi
        echo "✓ Virtual HDD created"
      else
        echo "Virtual HDD already exists, skipping creation."
      fi

      # =========================
      # Copy OVMF firmware to VM directory
      # =========================
      if [ ! -f "$VM_DIR/OVMF_CODE.fd" ]; then
        echo "Copying OVMF firmware..."
        if [ -f "$OVMF_DIR/OVMF_CODE.fd" ]; then
          cp "$OVMF_DIR/OVMF_CODE.fd" "$VM_DIR/" || { echo "❌ Failed to copy OVMF_CODE.fd"; exit 1; }
        elif [ -f "$OVMF_DIR/OVMF_CODE.fd.fallback" ]; then
          cp "$OVMF_DIR/OVMF_CODE.fd.fallback" "$VM_DIR/OVMF_CODE.fd" || { echo "❌ Failed to copy OVMF_CODE.fd.fallback"; exit 1; }
        else
          echo "❌ OVMF_CODE.fd not found in $OVMF_DIR"
          ls -la "$OVMF_DIR" | grep -i ovmf || echo "No OVMF files found"
          exit 1
        fi
      else
        echo "OVMF_CODE.fd already exists."
      fi

      if [ ! -f "$VM_DIR/OVMF_VARS-1920x1080.fd" ]; then
        echo "Copying OVMF_VARS..."
        if [ -f "$OVMF_DIR/OVMF_VARS-1920x1080.fd" ]; then
          cp "$OVMF_DIR/OVMF_VARS-1920x1080.fd" "$VM_DIR/" || { echo "❌ Failed to copy OVMF_VARS-1920x1080.fd"; exit 1; }
        elif [ -f "$OVMF_DIR/OVMF_VARS.fd" ]; then
          cp "$OVMF_DIR/OVMF_VARS.fd" "$VM_DIR/OVMF_VARS-1920x1080.fd" || { echo "❌ Failed to copy OVMF_VARS.fd"; exit 1; }
        else
          echo "❌ OVMF_VARS not found in $OVMF_DIR"
          exit 1
        fi
      else
        echo "OVMF_VARS-1920x1080.fd already exists."
      fi
      
      # Verify files exist before proceeding
      if [ ! -f "$VM_DIR/OVMF_CODE.fd" ] || [ ! -f "$VM_DIR/OVMF_VARS-1920x1080.fd" ]; then
        echo "❌ OVMF files verification failed"
        exit 1
      fi
      echo "✓ OVMF firmware ready"

      # =========================
      # Copy OpenCore.qcow2 if available
      # =========================
      if [ ! -f "$VM_DIR/OpenCore.qcow2" ]; then
        if [ -f "$OVMF_DIR/OpenCore/OpenCore.qcow2" ]; then
          echo "Copying OpenCore.qcow2..."
          if ! cp "$OVMF_DIR/OpenCore/OpenCore.qcow2" "$VM_DIR/"; then
            echo "❌ Failed to copy OpenCore.qcow2"
            exit 1
          fi
          
          # Verify the file was copied and check its size
          if [ ! -f "$VM_DIR/OpenCore.qcow2" ]; then
            echo "❌ OpenCore.qcow2 copy verification failed"
            exit 1
          fi
          
          FILE_SIZE=$(du -h "$VM_DIR/OpenCore.qcow2" | cut -f1)
          echo "✓ OpenCore.qcow2 ready (size: $FILE_SIZE)"
        else
          echo "⚠ OpenCore.qcow2 not found at $OVMF_DIR/OpenCore/OpenCore.qcow2"
          echo "Checking available files in $OVMF_DIR/OpenCore/:"
          ls -lh "$OVMF_DIR/OpenCore/" 2>/dev/null || echo "Directory not found"
          echo "⚠ Continuing without OpenCore.qcow2 - QEMU may fail to boot"
        fi
      else
        FILE_SIZE=$(du -h "$VM_DIR/OpenCore.qcow2" | cut -f1)
        echo "OpenCore.qcow2 already exists (size: $FILE_SIZE)."
      fi

      # =========================
      # Clone noVNC if missing
      # =========================
      if [ ! -d "$NOVNC_DIR/.git" ]; then
        echo "Cloning noVNC..."
        mkdir -p "$NOVNC_DIR"
        git clone https://github.com/novnc/noVNC.git "$NOVNC_DIR"
      else
        echo "noVNC already exists, skipping clone."
      fi

      # =========================
      # Start QEMU for macOS
      # =========================
      # Verify all required files exist and are readable
      echo "Verifying QEMU files..."
      [ -f "$VM_DIR/OVMF_CODE.fd" ] || { echo "❌ Missing: $VM_DIR/OVMF_CODE.fd"; exit 1; }
      [ -f "$VM_DIR/OVMF_VARS-1920x1080.fd" ] || { echo "❌ Missing: $VM_DIR/OVMF_VARS-1920x1080.fd"; exit 1; }
      [ -f "$VM_DIR/OpenCore.qcow2" ] || { echo "❌ Missing: $VM_DIR/OpenCore.qcow2"; exit 1; }
      [ -f "$BASE_SYSTEM" ] || { echo "❌ Missing: $BASE_SYSTEM"; exit 1; }
      
      # Verify files are readable
      [ -r "$VM_DIR/OVMF_CODE.fd" ] || { echo "❌ Not readable: $VM_DIR/OVMF_CODE.fd"; exit 1; }
      [ -r "$VM_DIR/OVMF_VARS-1920x1080.fd" ] || { echo "❌ Not readable: $VM_DIR/OVMF_VARS-1920x1080.fd"; exit 1; }
      [ -r "$VM_DIR/OpenCore.qcow2" ] || { echo "❌ Not readable: $VM_DIR/OpenCore.qcow2"; exit 1; }
      [ -r "$BASE_SYSTEM" ] || { echo "❌ Not readable: $BASE_SYSTEM"; exit 1; }
      
      echo "✓ All QEMU files verified and readable"
      
      # Set up local temp directory for QEMU
      echo "Setting up local temporary directory at $TEMP_DIR..."
      export TMPDIR="$TEMP_DIR"
      
      echo "Starting QEMU for macOS Tahoe..."
      nohup env TMPDIR="$TEMP_DIR" qemu-system-x86_64 \
        -enable-kvm \
        -m 4096 \
        -cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check \
        -machine q35 \
        -smp 4,cores=4,sockets=1 \
        -device qemu-xhci,id=xhci \
        -device usb-kbd,bus=xhci.0 \
        -device usb-tablet,bus=xhci.0 \
        -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" \
        -drive if=pflash,format=raw,readonly=on,file="$VM_DIR/OVMF_CODE.fd" \
        -drive if=pflash,format=raw,file="$VM_DIR/OVMF_VARS-1920x1080.fd" \
        -smbios type=2 \
        -device ich9-intel-hda \
        -device hda-duplex \
        -device ich9-ahci,id=sata \
        -drive id=OpenCoreBoot,if=none,format=qcow2,file="$VM_DIR/OpenCore.qcow2" \
        -device ide-hd,bus=sata.2,drive=OpenCoreBoot \
        -drive id=InstallMedia,if=none,file="$BASE_SYSTEM",format=raw \
        -device ide-hd,bus=sata.3,drive=InstallMedia \
        -drive id=MacHDD,if=none,file="$MAC_HDD",format=qcow2 \
        -device ide-hd,bus=sata.4,drive=MacHDD \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27 \
        -device vmware-svga \
        -vnc :0 \
        -display none \
        > /tmp/qemu.log 2>&1 &

      QEMU_PID=$!
      echo "QEMU PID: $QEMU_PID"
      
      # Give QEMU time to start and check for immediate errors
      sleep 2
      if ! kill -0 $QEMU_PID 2>/dev/null; then
        echo "❌ QEMU failed to start. Check /tmp/qemu.log:"
        cat /tmp/qemu.log
        exit 1
      fi
      echo "✓ QEMU started successfully"

      # =========================
      # Start noVNC on port 8888
      # =========================
      echo "Starting noVNC..."
      nohup "$NOVNC_DIR/utils/novnc_proxy" \
        --vnc 127.0.0.1:5900 \
        --listen 8888 \
        > /tmp/novnc.log 2>&1 &

      # =========================
      # Start Cloudflared tunnel
      # =========================
      echo "Starting Cloudflared tunnel..."
      nohup cloudflared tunnel \
        --no-autoupdate \
        --url http://localhost:8888 \
        > /tmp/cloudflared.log 2>&1 &

      sleep 10

      if grep -q "trycloudflare.com" /tmp/cloudflared.log; then
        URL=$(grep -o "https://[a-z0-9.-]*trycloudflare.com" /tmp/cloudflared.log | head -n1)
        echo "========================================="
        echo " 🌍 macOS Tahoe QEMU + noVNC ready:"
        echo "     $URL/vnc.html"
        echo "     $URL/vnc.html" > /home/user/macOS-noVNC-URL.txt
        echo "========================================="
        echo ""
        echo "Installation Notes:"
        echo "  1. Wait for macOS installer to fully load"
        echo "  2. Use Disk Utility to partition and format the disk as APFS"
        echo "  3. Install macOS Tahoe"
        echo "  4. After installation, the VM will restart into macOS"
        echo ""
      else
        echo "❌ Cloudflared tunnel failed"
        echo "Checking noVNC directly on port 8888..."
      fi

      # =========================
      # Keep workspace alive
      # =========================
      elapsed=0
      while true; do
        echo "Time elapsed: $elapsed min"
        ((elapsed++))
        sleep 60
      done
    '';
  };

  idx.previews = {
    enable = true;
    previews = {
      macos = {
        manager = "web";
        command = [
          "bash" "-lc"
          "echo 'macOS Tahoe noVNC running on port 8888'"
        ];
      };
      terminal = {
        manager = "web";
        command = [ "bash" ];
      };
    };
  };
}
