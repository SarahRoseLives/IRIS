#!/bin/bash

# This script builds a Flutter APK and pushes it to a connected Android device via ADB.
#
# Usage:
#   ./build_and_deploy.sh           (Builds and deploys debug APK)
#   ./build_and_deploy.sh --debug   (Builds and deploys debug APK)
#   ./build_and_deploy.sh --release (Builds and deploys release APK)

# --- Configuration ---
FLUTTER_PROJECT_DIR=$(pwd) # Assumes script is run from Flutter project root
BUILD_TYPE="debug"         # Default build type (can be overridden by arguments)
APK_OUTPUT_DIR="build/app/outputs/flutter-apk"

# --- Functions ---

# Function to check if a command exists
command_exists () {
  command -v "$1" >/dev/null 2>&1
}

# Function to display script usage
usage() {
  echo "Usage: $0 [--release | --debug]"
  echo "  --release : Builds a release APK and deploys."
  echo "  --debug   : Builds a debug APK and deploys (default)."
  exit 1
}

# --- Argument parsing ---
for arg in "$@"; do
  case $arg in
    --release)
      BUILD_TYPE="release"
      shift
      ;;
    --debug)
      BUILD_TYPE="debug"
      shift
      ;;
    *)
      usage # Call usage function for invalid arguments
      ;;
  esac
done

# --- Pre-checks: Ensure Flutter and ADB are available ---
echo "--- Checking prerequisites ---"

if ! command_exists flutter; then
  echo "Error: Flutter command not found. Please ensure Flutter SDK is installed and in your PATH."
  exit 1
fi

if ! command_exists adb; then
  echo "Error: ADB command not found. Please ensure Android SDK Platform-Tools are installed and in your PATH."
  echo "You can usually install it via your OS package manager (e.g., 'sudo apt install android-tools-adb') or Android Studio."
  exit 1
fi

# Check for connected devices
DEVICE_COUNT=$(adb devices | grep -w "device" | wc -l)
if [ "$DEVICE_COUNT" -eq 0 ]; then
  echo "Error: No Android devices detected. Please ensure a device is connected, powered on, and ADB debugging is enabled."
  exit 1
elif [ "$DEVICE_COUNT" -gt 1 ]; then
  echo "Warning: Multiple Android devices detected:"
  adb devices
  echo "ADB will attempt to install on one of them. If you want to specify a device, use 'adb -s <serial> install ...'."
  echo "To get a serial, run 'adb devices' and copy the serial from the list."
fi

echo "--- Prerequisites met ---"

# --- Clean and Build the Flutter APK ---
echo "--- Cleaning Flutter project ---"
flutter clean

echo "--- Building Flutter APK ($BUILD_TYPE) ---"
flutter build apk --"$BUILD_TYPE"

BUILD_EXIT_CODE=$?
if [ $BUILD_EXIT_CODE -ne 0 ]; then
  echo "Error: Flutter APK build failed with exit code $BUILD_EXIT_CODE."
  exit $BUILD_EXIT_CODE
fi

# Find the latest built APK file (APK names can vary slightly, so globbing is safer)
# This finds the newest .apk file in the target directory
APK_FILE=$(ls -t "$FLUTTER_PROJECT_DIR/$APK_OUTPUT_DIR"/*.apk | head -n 1)

if [ -z "$APK_FILE" ]; then
  echo "Error: Could not find the built APK file in $FLUTTER_PROJECT_DIR/$APK_OUTPUT_DIR."
  echo "Please check the Flutter build output for errors."
  exit 1
fi

echo "--- Successfully built APK: $APK_FILE ---"

# --- Uninstall existing app (optional but highly recommended to avoid conflicts) ---
# Get package name from AndroidManifest.xml
PACKAGE_NAME=$(grep -oP 'package="\K[^"]+' android/app/src/main/AndroidManifest.xml | head -n 1)

if [ -n "$PACKAGE_NAME" ]; then
  echo "--- Attempting to uninstall existing app ($PACKAGE_NAME) from device (ignoring errors if not found) ---"
  adb uninstall "$PACKAGE_NAME"
else
  echo "Warning: Could not determine package name for uninstall from AndroidManifest.xml. Skipping uninstall step."
fi

# --- Push and Install the APK ---
echo "--- Installing APK on connected device ---"
# -r flag means "replace existing application"
adb install -r "$APK_FILE"

INSTALL_EXIT_CODE=$?
if [ $INSTALL_EXIT_CODE -ne 0 ]; then
  echo "Error: ADB installation failed with exit code $INSTALL_EXIT_CODE."
  exit $INSTALL_EXIT_CODE
else
  echo "--- APK successfully installed! ---"
fi

echo "--- Deployment complete! ---"
