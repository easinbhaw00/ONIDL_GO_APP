ONIDL Go — Consolidated Android Project Source
===============================================

Project identity
- App: ONIDL Go
- Android applicationId: com.onidl.go
- Flutter/Dart UI + native Kotlin libtorrent4j engine
- UI language: English
- Default theme: Dark; Light theme can be selected and is saved locally
- No ads, paid APIs, paid SDKs or API keys are used

Implemented source features
---------------------------
1. App UI
- Home, Search, Downloads, My Files and Settings
- Dark/Light theme preference persists after app restart
- My Files lists only files inside ONIDL Go's private app download folder, including nested folders
- File name, size, extension and honest security label ("Not scanned")
- Open and delete downloaded files

2. Direct HTTP/HTTPS downloads
- background_downloader integration
- Progress, network speed, pause, resume, cancel, retry
- Background scheduling hints and download notifications
- Transfer database auto-clean disabled to preserve task history

3. Free search providers
- Internet Archive Advanced Search + item metadata lookup
- Wikimedia Commons media search
- Source/license page link shown for results
- User must confirm each item's license and reuse conditions before downloading or sharing

4. Torrent engine
- libtorrent4j 2.1.0-39 native Android libraries for ARM, ARM64, x86 and x86_64
- Magnet URI and .torrent file import
- Torrent engine moved to process-wide TorrentEngine and initialized by TorrentForegroundService
- Foreground notification while the torrent service is active
- Progress, download/upload rate, peer/seed counts, downloaded/total size and state sent to Flutter
- Per-torrent and global pause/resume controls
- Magnet/.torrent queue and original save path persisted in app-private storage
- Service uses START_STICKY for best-effort Android process recreation
- Re-added queue is expected to recheck existing pieces; full libtorrent fast-resume data is NOT implemented

5. Reboot recovery
- Boot receiver checks for a saved torrent queue
- It posts a notification asking the user to open ONIDL Go to restore downloads
- It deliberately does NOT start a dataSync foreground service directly from BOOT_COMPLETED because Android 15+ restricts that start
- MainActivity starts the torrent service when opened if a saved queue exists

6. Feedback
- Name + Description form
- Feedback entries can be saved and viewed locally on the same device
- This is NOT a public/shared feedback wall. A public list needs a hosted backend/database and project credentials; none are bundled or fabricated

Important limitations — read before building
--------------------------------------------
- No antivirus or malware scanning is implemented. "Not scanned" is shown honestly; the app does not claim files are safe.
- Full libtorrent fast-resume data serialization/restoration is not implemented. Queue restoration re-adds the original magnet/.torrent and may recheck the downloaded pieces.
- Reboot restoration is user-initiated via notification tap; Android 15+ blocks BOOT_COMPLETED receivers from starting dataSync foreground services directly.
- Android may stop or restrict background work due to Force Stop, battery saver, OEM battery management, network loss, foreground-service policy/time limits, or user restrictions. No app can guarantee uninterrupted transfers in all conditions.
- Android 15+ applies a six-hour-per-24-hour limit to dataSync foreground services for apps targeting API 35+. The service handles the timeout by stopping cleanly; the saved queue can be restored when the user opens the app again.
- Public/shared feedback requires a hosted backend. It is not available in this offline build.
- Search results have varying licenses/rights. The source page must be checked by the user.
- The Gradle wrapper properties are included, but the Gradle wrapper executable/JAR is not included in this source package.
- Flutter, Dart and Android SDK were not installed in the authoring environment. No `flutter pub get`, `flutter analyze`, Gradle compile, APK build, emulator test or physical-device test has been run.

Build requirements and steps
----------------------------
Requirements:
- Flutter SDK compatible with Dart 3.5+ (Flutter 3.24 or newer recommended)
- Android Studio / Android SDK
- Java 17
- Internet access for dependency resolution and Gradle distribution

Steps in a Flutter development environment:
1. Open the ONIDL_Go_Project folder.
2. Run `flutter pub get`.
3. Let Flutter/Android Studio generate or configure the missing Gradle wrapper executable files if needed.
4. Run `flutter build apk --release`.
5. Install the APK on an Android 9+ device (minSdk 28) and test direct downloads, torrent lifecycle, notifications and reboot behavior.

This ZIP is a consolidated source handoff, not a tested APK. Any compile errors discovered by the first real Flutter/Gradle build must be fixed before release.

Cloud build handoff
-------------------
This project now includes:
- codemagic.yaml: Codemagic workflow to resolve packages, analyze, run tests and build a debug APK.
- .github/workflows/android.yml: GitHub Actions workflow for the same validation/build.
- scripts/prepare_android_wrapper.sh: creates the Gradle wrapper on CI because wrapper binaries are not included in this source ZIP.

Important:
- Codemagic's documented app onboarding connects a Git repository; it does not use a ZIP upload as the normal app-import method. Upload/extract this ZIP into a GitHub repository first, then connect that repository to Codemagic.
- A successful CI run is the first real compile/test result. The source has not been compiled in this authoring environment.
- This workflow creates a DEBUG APK for installation/testing. A release APK signed for distribution requires a private Android keystore; do not share that keystore or passwords in chat or commit them to Git.
