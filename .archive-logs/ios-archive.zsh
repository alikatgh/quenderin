#!/bin/zsh
set -euo pipefail
export QUENDERIN_RUNTIME=prism
unset QUENDERIN_LLAMA_DIR
cd /Users/s_avelova/Documents/projects/quenderin-wt-store-36/apple/QuenderinApp
mkdir -p "$HOME/Library/Developer/Xcode/Archives/2026-11-13"
mkdir -p "$HOME/Library/Developer/Xcode/DerivedData"
echo "START $(date) $(df -h /System/Volumes/Data | awk 'NR==2{print $4}')"
xcodebuild \
  -project Quenderin.xcodeproj \
  -scheme Quenderin \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$HOME/Library/Developer/Xcode/Archives/2026-11-13/Quenderin-iOS-36.xcarchive" \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Quenderin-ios-36" \
  -allowProvisioningUpdates \
  COMPILER_INDEX_STORE_ENABLE=NO \
  ENABLE_PREVIEWS=NO \
  CURRENT_PROJECT_VERSION=36 \
  MARKETING_VERSION=0.6.2 \
  INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=9M2B2P4KSA \
  archive
echo "EXIT $?"
