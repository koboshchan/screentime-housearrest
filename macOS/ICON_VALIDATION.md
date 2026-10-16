The editable app icon is macOS/AppIcon.icon. It is an Apple Icon Composer document containing three independent SVG vector layers, a clock dial, hands, and a mint selected-session arc. Both apps compile this shared document using macOS/scripts/compile-icon.sh and Apple's actool. The compiled Assets.car retains all three native icon groups and the IconImageStack, not just a flattened image. macOS additionally receives AppIcon.icns, and iOS receives backward-compatible iPhone/iPad PNG assets.

Icon Composer 27.1 successfully exported Default, Dark, TintedLight, TintedDark, ClearLight and ClearDark previews. The actual renders were visually inspected. Default and Dark retain the mint accent. Tinted and clear appearances use Apple's system treatments, including monochromatic accents. Previews live in macOS/build/icon-previews/. The six-appearance contact sheet is ScreenTimeEditor-icon-appearances.png in that directory.

Validation commands completed successfully on October 16, 2026.

```sh
bash macOS/build.sh
bash iOS/build.sh
python3 iOS/package.py
python3 macOS/scripts/verify_icon.py
codesign --verify --deep --strict macOS/build/ScreenTimeEditor.app
cd macOS
swift test
python3 -m unittest discover -s BackendTests
```

The macOS app, iOS compile-validation bundle, and extracted RootHide package each passed icon-layer, asset-stack, fallback-asset and Info.plist checks. macOS code signing and iOS package signature, deployment, entitlement and helper caller-pin checks passed. Swift reported 16 tests passed; Python reported 104 tests passed. iOS compiler-validation storage/model/IPC checks also passed. Build minimums remain macOS 26 and iOS 18.

The pre-icon macOS app, iOS package and affected build/source files were preserved in the owner-only sibling directory screentime-housearrest-icon-backup-20261016-100237. Earlier full-project private backups remain untouched. No app was installed or launched, no usage data was modified, and nothing was pushed. RootHide runtime remains untested on an actual device.
