# behavior_tracker

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Running on an Android emulator (Pixel 7)

If you want to run the app on a Pixel 7 emulator, follow these steps:

1. Start an Android emulator

- Using Android Studio: Tools → AVD Manager → launch the Pixel 7 AVD.
- From the command line (if Android SDK tools are installed):

```bash
# list available AVDs
emulator -list-avds
# launch an AVD (replace <AVD_NAME> with the name shown above)
emulator -avd <AVD_NAME>
```

- Or create & launch with Flutter (may require downloading system images):

```bash
flutter emulators --create --name pixel_7_avd
flutter emulators --launch pixel_7_avd
```

2. Verify the emulator is recognized by Flutter:

```bash
flutter devices
```

3. Run the app on the emulator:

```bash
# If only one device is connected
flutter run

# If multiple devices are connected, specify device id from `flutter devices`
flutter run -d <deviceId>
```

4. Run tests (optional):

```bash
flutter test
```

Notes:
- If `emulator` is not found, install Android SDK command-line tools and ensure the tools are on your PATH.
- If your Pixel 7 AVD is missing, create it in AVD Manager or with `flutter emulators --create`.
- For release builds use `flutter run --release`.
