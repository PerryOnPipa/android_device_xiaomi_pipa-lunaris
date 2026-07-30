#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok()  { echo -e "${GREEN}✔ $1${NC}"; }
err() { echo -e "${RED}✖ $1${NC}" >&2; }

ROOT_DIR=$(pwd)
DEVICE_PATH="${ROOT_DIR}/device/xiaomi/pipa"
PATCH_DIR="${DEVICE_PATH}/source-patches"

PATCH_SETTINGS_FILE="${PATCH_DIR}/packages_apps_Settings.patch"
PATCH_FWB_FILE="${PATCH_DIR}/frameworks_base.patch"
PATCH_AV_FILE="${PATCH_DIR}/frameworks_av.patch"

clone_if_missing() {
    local url=$1 branch=$2 dir=$3
    if [ ! -d "$dir" ]; then
        echo "→ Cloning $dir..."
        git clone --depth=10 "$url" -b "$branch" "$dir" -q \
            && ok "Cloned $dir." || { err "Failed to clone: $url"; return 1; }
    else
        echo "→ $dir exists, skipping."
    fi
}

clean_clone() {
    local url=$1 branch=$2 dir=$3
    echo "→ Fresh cloning $dir..."
    [ -d "$dir" ] && rm -rf "$dir" && ok "Removed $dir."
    git clone --depth=10 "$url" -b "$branch" "$dir" -q \
        && ok "Cloned $dir." || { err "Clone failed: $url"; return 1; }
}

clone_if_missing "https://github.com/SD870/kernel_xiaomi_sm8250"                     "16"      "kernel/xiaomi/sm8250"
clone_if_missing "https://github.com/nullpointer1101/android_device_xiaomi_sm8250-common"  "16"      "device/xiaomi/sm8250-common"
clone_if_missing "https://github.com/SD870/vendor_xiaomi_sm8250-common"              "16"      "vendor/xiaomi/sm8250-common"
clone_if_missing "https://github.com/SD870/vendor_xiaomi_pipa"                       "16"      "vendor/xiaomi/pipa"
clean_clone      "https://github.com/SD870/hardware_xiaomi.git"                         "16"      "hardware/xiaomi"
clean_clone      "https://github.com/PocoF3Releases/packages_resources_devicesettings.git" "aosp-16" "packages/resources/devicesettings"
clone_if_missing "https://github.com/kuroringo90/priv_axion.git"                           "main"    "vendor/lineage-priv"
echo "──────────────────────────────────────────────"

apply_patch() {
    local patch_file=$1 target_dir=$2
    local tmp_patch="/tmp/$(basename "$patch_file")"

    if [ ! -f "$patch_file" ]; then
        echo "File not found: $(basename "$patch_file")"; return
    fi
    if ! cd "$ROOT_DIR/$target_dir" 2>/dev/null; then
        echo "Could not enter: $target_dir"; cd "$ROOT_DIR"; return
    fi

    tr -d '\r' < "$patch_file" > "$tmp_patch"

    if git apply --check --ignore-whitespace "$tmp_patch" >/dev/null 2>&1; then
        if git apply --ignore-whitespace "$tmp_patch" >/dev/null 2>&1; then
            git add . && git commit -m "patch: $(sha1sum "$tmp_patch" | awk '{print $1}')" -q || true
            echo "Applied successfully"
        else
            git reset --hard HEAD >/dev/null 2>&1 || true
            git clean -fd >/dev/null 2>&1 || true
            echo "Failed to apply"
        fi
    else
        echo "Already applied"
    fi

    rm -f "$tmp_patch"
    cd "$ROOT_DIR"
}

# ── Firmware Setup ──────────────────────────────────────────────
setup_firmware() {
    local target_dir="${ROOT_DIR}/vendor/xiaomi/pipa"
    local fw_url="https://github.com/SD870/vendor_xiaomi_pipa/releases/download/pipa-2.0.20.0-CN/pipa-2.0.20.0-CN.zip"
    local tmp_zip="/tmp/pipa-2.0.20.0-CN.zip"
    local tmp_extract="/tmp/firmware_extract"

    # Skip entirely if radio folder already exists
    if [ -d "$target_dir/radio" ]; then
        echo "already_present"; return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -L --fail --progress-bar -o "$tmp_zip" "$fw_url" \
            || { err "Download failed."; rm -f "$tmp_zip"; echo "failed"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget --show-progress --quiet -O "$tmp_zip" "$fw_url" \
            || { err "Download failed."; rm -f "$tmp_zip"; echo "failed"; return 1; }
    else
        err "No downloader (curl/wget) available."
        echo "failed"; return 1
    fi

    rm -rf "$tmp_extract" && mkdir -p "$tmp_extract"

    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$tmp_zip" -d "$tmp_extract" \
            || { err "Extraction failed."; rm -f "$tmp_zip"; rm -rf "$tmp_extract"; echo "failed"; return 1; }
    elif command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$tmp_zip" -C "$tmp_extract" \
            || { err "Extraction failed."; rm -f "$tmp_zip"; rm -rf "$tmp_extract"; echo "failed"; return 1; }
    else
        err "No extractor (unzip/bsdtar) available."
        rm -f "$tmp_zip"; rm -rf "$tmp_extract"; echo "failed"; return 1
    fi

    local radio_dir
    radio_dir=$(find "$tmp_extract" -type d -name radio -print -quit)

    [ -z "$radio_dir" ] && {
        err "No 'radio' folder found in firmware."
        rm -f "$tmp_zip"; rm -rf "$tmp_extract"; echo "failed"; return 1
    }

    mv "$radio_dir" "$target_dir/" || {
        err "Failed to move radio dir."
        rm -f "$tmp_zip"; rm -rf "$tmp_extract"; echo "failed"; return 1
    }

    rm -f "$tmp_zip"; rm -rf "$tmp_extract"
    echo "downloaded"
}

echo "→ Applying patches..."
STATUS_SETTINGS=$(apply_patch "$PATCH_SETTINGS_FILE" "packages/apps/Settings")
STATUS_FWB=$(apply_patch      "$PATCH_FWB_FILE"      "frameworks/base")
STATUS_AV=$(apply_patch       "$PATCH_AV_FILE"       "frameworks/av")

echo "→ Setting up firmware..."
FW_STATUS=$(setup_firmware)

# ── Deferred Status Output ──────────────────────────────────────
print_status() {
    [ "$2" = "Applied successfully" ] \
        && ok  "[$1]: $2" \
        || echo "→ [$1]: $2"
}

echo "──────────────────────────────────────────────"
print_status "Settings patch"        "$STATUS_SETTINGS"
sleep 3
print_status "Frameworks Base patch" "$STATUS_FWB"
sleep 3
print_status "Frameworks AV patch"   "$STATUS_AV"
sleep 3

case "$FW_STATUS" in
    already_present) ok  "Firmware already there, skipping setup." ;;
    downloaded)      ok  "Firmware downloaded and set up."         ;;
    *)               err "Firmware setup issue: $FW_STATUS"        ;;
esac
sleep 5

echo "──────────────────────────────────────────────"
echo "           Setup complete!           "
echo "──────────────────────────────────────────────"
