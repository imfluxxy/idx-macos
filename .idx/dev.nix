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
      VM_DIR="$HOME/qemu-macos"
      MACOS_REPO="$HOME/OSX-KVM"
      BASE_SYSTEM="$VM_DIR/BaseSystem.img"
      MAC_HDD="$VM_DIR/mac_hdd_ng.img"
      NOVNC_DIR="$HOME/noVNC"
      OVMF_DIR="$MACOS_REPO"

      mkdir -p "$VM_DIR"

      # =========================
      # Copy OSX-KVM repo if needed
      # =========================
      if [ ! -d "$MACOS_REPO" ]; then
        echo "Cloning OSX-KVM repository..."
        cd "$HOME"
        if ! git clone --depth 1 --recursive https://github.com/kholia/OSX-KVM.git; then
          echo "❌ Failed to clone OSX-KVM repository"
          exit 1
        fi
        if [ ! -d "$MACOS_REPO" ]; then
          echo "❌ OSX-KVM directory not found after clone"
          exit 1
        fi
      else
        echo "OSX-KVM repository already exists."
      fi

      cd "$MACOS_REPO" || { echo "❌ Failed to enter $MACOS_REPO"; exit 1; }

      # =========================
      # Download macOS Tahoe installer
      # =========================
      if [ ! -f "$BASE_SYSTEM" ]; then
        echo "Downloading macOS Tahoe installer..."
        # Create a temporary script to fetch macOS Tahoe (option 9)
        if python3 ./fetch-macOS-v2.py --board-id Mac-27AD2F918AE68F61 --os-type default -o "$VM_DIR" 2>&1 <<< "9"; then
          echo "✓ Downloaded successfully"
        else
          echo "⚠ First download attempt failed, trying alternative method..."
          if python3 ./fetch-macOS-v2.py 2>&1 <<< "9"; then
            echo "✓ Alternative download succeeded"
          else
            echo "❌ Failed to download macOS Tahoe installer"
            exit 1
          fi
        fi

        # Convert BaseSystem.dmg to BaseSystem.img if needed
        if [ -f "$VM_DIR/BaseSystem.dmg" ]; then
          echo "Converting BaseSystem.dmg to BaseSystem.img..."
          if ! dmg2img "$VM_DIR/BaseSystem.dmg" "$BASE_SYSTEM"; then
            echo "❌ Failed to convert BaseSystem.dmg"
            exit 1
          fi
          echo "✓ Conversion complete"
        elif [ ! -f "$BASE_SYSTEM" ]; then
          echo "❌ BaseSystem image not found after download"
          exit 1
        fi
      else
        echo "macOS BaseSystem already exists, skipping download."
      fi

      # =========================
      # Create virtual HDD if missing
      # =========================
      if [ ! -f "$MAC_HDD" ]; then
        echo "Creating virtual HDD for macOS (128GB)..."
        if ! qemu-img create -f qcow2 "$MAC_HDD" 128G; then
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
          cp "$OVMF_DIR/OpenCore/OpenCore.qcow2" "$VM_DIR/" || { echo "❌ Failed to copy OpenCore.qcow2"; exit 1; }
          echo "✓ OpenCore.qcow2 ready"
        else
          echo "⚠ OpenCore.qcow2 not found, QEMU may fail to boot"
        fi
      else
        echo "OpenCore.qcow2 already exists."
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
      # Verify all required files exist
      echo "Verifying QEMU files..."
      [ -f "$VM_DIR/OVMF_CODE.fd" ] || { echo "❌ Missing: $VM_DIR/OVMF_CODE.fd"; exit 1; }
      [ -f "$VM_DIR/OVMF_VARS-1920x1080.fd" ] || { echo "❌ Missing: $VM_DIR/OVMF_VARS-1920x1080.fd"; exit 1; }
      [ -f "$VM_DIR/OpenCore.qcow2" ] || { echo "❌ Missing: $VM_DIR/OpenCore.qcow2"; exit 1; }
      [ -f "$BASE_SYSTEM" ] || { echo "❌ Missing: $BASE_SYSTEM"; exit 1; }
      echo "✓ All QEMU files verified"
      
      echo "Starting QEMU for macOS Tahoe..."
      nohup qemu-system-x86_64 \
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
        -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file="$VM_DIR/OpenCore.qcow2" \
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
