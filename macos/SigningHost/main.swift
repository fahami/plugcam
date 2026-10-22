// Never shipped. This target only makes Xcode register the app ID with the System Extension
// capability and create its provisioning profile, and sign the camera extension embedded in it.
// scripts/macos-build.sh moves both into the real app, which Tauri builds.
print("Build Plugcam with scripts/macos-build.sh")
