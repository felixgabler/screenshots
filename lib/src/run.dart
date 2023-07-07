import 'dart:async';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:path/path.dart' as path;
import 'package:tool_base/tool_base.dart' hide Config;
import 'package:tool_mobile/tool_mobile.dart';

import 'archive.dart';
import 'config.dart';
import 'context_runner.dart';
import 'daemon_client.dart';
import 'fastlane.dart' as fastlane;
import 'globals.dart';
import 'image_processor.dart';
import 'orientation.dart';
import 'resources.dart' as resources;
import 'screens.dart';
import 'utils.dart' as utils;
import 'validate.dart' as validate;

/// Run screenshots
Future<bool> screenshots(
    {String? configPath,
    String? configStr,
    String? mode = 'normal',
    String? flavor = kNoFlavor,
    bool? isBuild,
    bool isVerbose = false}) async {
  final screenshots = Screenshots(
      configPath: configPath, configStr: configStr, mode: mode, flavor: flavor, isBuild: isBuild, verbose: isVerbose);
  // run in context
  if (isVerbose) {
    Logger verboseLogger = VerboseLogger(platform.isWindows ? WindowsStdoutLogger() : StdoutLogger());
    return runInContext<bool>(() async {
      return screenshots.run();
    }, overrides: <Type, Generator>{
      Logger: () => verboseLogger,
    });
  } else {
    return runInContext<bool>(() async {
      return screenshots.run();
    });
  }
}

class Screenshots {
  Screenshots({
    this.configPath,
    this.configStr,
    this.mode = 'normal',
    this.flavor = kNoFlavor,
    this.isBuild,
    this.verbose = false,
  }) {
    config = Config(configPath: configPath, configStr: configStr);
  }

  final String? configPath;
  final String? configStr;
  final String? mode;
  final String? flavor;
  final bool? isBuild; // defaults to null
  final bool verbose;

  RunMode? runMode;
  List<DaemonDevice>? devices;
  List<DaemonEmulator>? emulators;
  late Config config;
  Archive? archive;

  /// Capture screenshots, process, and load into fastlane according to config file.
  ///
  /// For each locale and device or emulator/simulator:
  ///
  /// 1. If not a real device, start the emulator/simulator for current locale.
  /// 2. Run each integration test and capture the screenshots.
  /// 3. Process the screenshots including adding a frame if required.
  /// 4. Move processed screenshots to fastlane destination for upload to stores.
  /// 5. If not a real device, stop emulator/simulator.
  Future<bool> run() async {
    runMode = utils.getRunModeEnum(mode);

    final screens = Screens();
    await screens.init();

    // start flutter daemon
    final status = logger?.startProgress('Starting flutter daemon...', timeout: Duration(milliseconds: 10000));
    await daemonClient.start;
    status?.stop();

    // get all attached devices and running emulators/simulators
    devices = await daemonClient.devices;
    // get all available unstarted android emulators
    // note: unstarted simulators are not properly included in this list
    //       so have to be handled separately
    emulators = await daemonClient.emulators;
    emulators!.sort(utils.emulatorComparison);

    // validate config file
    if (!await validate.isValidConfig(config, screens, devices, emulators)) {
      return false;
    }

    // init
    await fs.directory(path.join(config.stagingDir!, kTestScreenshotsDir)).create(recursive: true);
    if (!platform.isWindows) await resources.unpackScripts(config.stagingDir);
    archive = Archive(config.archiveDir);
    if (runMode == RunMode.archive) {
      printStatus('Archiving screenshots to ${archive!.archiveDirPrefix}...');
    } else {
      await fastlane.clearFastlaneDirs(config, screens, runMode);
    }

    // run integration tests in each real device (or emulator/simulator) for
    // each locale and process screenshots
    await runTestsOnAll(screens);

    // shutdown daemon
    await daemonClient.stop;

    printStatus('\n\nScreen images are available in:');
    if (runMode == RunMode.recording) {
      _printScreenshotDirs(config.recordingDir);
    } else {
      if (runMode == RunMode.archive) {
        printStatus('  ${archive!.archiveDirPrefix}');
      } else {
        _printScreenshotDirs(null);
        final isIosActive = config.isRunTypeActive(DeviceType.ios);
        final isAndroidActive = config.isRunTypeActive(DeviceType.android);
        if (isIosActive && isAndroidActive) {
          printStatus('for upload to both Apple and Google consoles.');
        }
        if (isIosActive && !isAndroidActive) {
          printStatus('for upload to Apple console.');
        }
        if (!isIosActive && isAndroidActive) {
          printStatus('for upload to Google console.');
        }
        printStatus('\nFor uploading and other automation options see:');
        printStatus('  https://pub.dartlang.org/packages/fledge');
      }
    }
    printStatus('\nscreenshots completed successfully.');
    return true;
  }

  void _printScreenshotDirs(String? dirPrefix) {
    final prefix = dirPrefix == null ? '' : '$dirPrefix/';
    if (config.isRunTypeActive(DeviceType.ios)) {
      printStatus('  ${prefix}ios/fastlane/screenshots');
    }
    if (config.isRunTypeActive(DeviceType.android)) {
      printStatus('  ${prefix}android/fastlane/metadata/android');
    }
  }

  /// Run the screenshot integration tests on current device, emulator or simulator.
  ///
  /// Each test is expected to generate a sequential number of screenshots.
  /// (to match order of appearance in Apple and Google stores)
  ///
  /// Assumes the integration tests capture the screen shots into a known directory using
  /// provided [capture_screen.screenshot()].
  Future runTestsOnAll(Screens screens) async {
    final recordingDir = config.recordingDir;
    switch (runMode) {
      case RunMode.recording:
        recordingDir == null ? throw 'Error: \'recording\' dir is not specified in your screenshots.yaml' : null;
        break;
      case RunMode.comparison:
        runMode == RunMode.comparison && (!(await utils.isRecorded(recordingDir)))
            ? throw 'Error: a recording must be run before a comparison'
            : null;
        break;
      case RunMode.archive:
        config.archiveDir == null ? throw 'Error: \'archive\' dir is not specified in your screenshots.yaml' : null;
        break;
      case RunMode.normal:
      default:
        break;
    }

    for (final configDeviceName in config.deviceNames) {
      // look for matching device first.
      // Note: flutter daemon handles devices and running emulators/simulators as devices.
      await runAllTestsOnDevice(configDeviceName, screens);
    }
  }

  Future<void> runAllTestsOnDevice(String configDeviceName, Screens screens) async {
    final device = findRunningDevice(devices!, emulators, configDeviceName);

    String? deviceId;
    DaemonEmulator? emulator;
    Map? simulator;
    if (device != null) {
      deviceId = device.id;
    } else {
      // if no matching device, look for matching android emulator
      // and start it
      emulator = utils.findEmulator(emulators!, configDeviceName);
      if (emulator != null) {
        printStatus('Starting $configDeviceName...');
        deviceId = await startEmulator(daemonClient, emulator.id, config.stagingDir);
      } else {
        // if no matching android emulator, look for matching ios simulator
        // and start it
        simulator = utils.getHighestIosSimulator(utils.getIosSimulators(), configDeviceName);
        deviceId = simulator!['udid'];
        printStatus('Starting $configDeviceName...');
        await startSimulator(daemonClient, deviceId);
      }
    }

    // a device is now found
    // (and running if not ios simulator pending locale change)
    if (deviceId == null) {
      throw 'Error: device \'$configDeviceName\' not found';
    }

    // todo: make a backup of GlobalPreferences.plist if changing iOS locale
    // set locale and run tests
    final deviceType = getDeviceType(config, configDeviceName);
    if (device != null && !device.emulator!) {
      // device is real
      await runProcessTests(
        configDeviceName,
        null,
        deviceType,
        deviceId,
        screens,
      );
    } else {
      // device is emulated

      // Change orientation if required
      final configDevice = config.getDevice(configDeviceName);
      if (configDevice.orientations != null) {
        for (final orientation in configDevice.orientations!) {
          final currentDevice = utils.getDeviceFromId(await daemonClient.devices, deviceId);
          if (currentDevice == null) {
            throw 'Error: device \'$configDeviceName\' not found in flutter daemon.';
          }
          switch (deviceType) {
            case DeviceType.android:
              if (currentDevice.emulator!) {
                changeDeviceOrientation(deviceType, orientation, deviceId: deviceId);
              } else {
                printStatus('Warning: cannot change orientation of a real android device.');
              }
              break;
            case DeviceType.ios:
              if (currentDevice.emulator!) {
                changeDeviceOrientation(deviceType, orientation, scriptDir: '${config.stagingDir}/resources/script');
              } else {
                printStatus('Warning: cannot change orientation of a real iOS device.');
              }
              break;
          }

          // store env for later use by tests
          // ignore: invalid_use_of_visible_for_testing_member
          await config.storeEnv(screens, configDeviceName, deviceType, orientation);

          // run tests and process images
          await runProcessTests(
            configDeviceName,
            orientation,
            deviceType,
            deviceId,
            screens,
          );
        }
      } else {
        await runProcessTests(
          configDeviceName,
          null,
          deviceType,
          deviceId,
          screens,
        );
      }

      // if an emulator was started, revert locale if necessary and shut it down
      if (emulator != null) {
        await shutdownAndroidEmulator(daemonClient, deviceId);
      }
      // if a simulator was started, revert locale if necessary and shut it down
      if (simulator != null) {
        await shutdownSimulator(deviceId);
      }
    }
  }

  /// Runs tests and processes images.
  Future runProcessTests(
    configDeviceName,
    Orientation? orientation,
    DeviceType deviceType,
    String deviceId,
    Screens screens,
  ) async {
    for (final testPath in config.tests) {
      final command = <String?>['flutter', '-d', deviceId, 'drive'];
      bool? _isBuild() => isBuild ?? config.getDevice(configDeviceName).isBuild;
      if (!_isBuild()!) {
        command.add('--no-build');
      }
      bool isFlavor() => flavor != null && flavor != kNoFlavor;
      if (isFlavor()) {
        command.addAll(['--flavor', flavor]);
      }
      command.addAll(testPath.split(' ')); // add test path or custom command
      printStatus(
          'Running $testPath on \'$configDeviceName\'${isFlavor() ? ' with flavor $flavor' : ''}${!_isBuild()! ? ' with no build' : ''}...');
      if (!_isBuild()! && isFlavor()) {
        printStatus('Warning: flavor parameter \'$flavor\' is ignored because no build is set for this device');
      }
      await utils.streamCmd(command, environment: {kEnvConfigPath: configPath ?? ''});
      // process screenshots
      final imageProcessor = ImageProcessor(screens, config);
      await imageProcessor.process(deviceType, configDeviceName, orientation, runMode, archive);
    }
  }
}

Future<void> shutdownSimulator(String deviceId) async {
  utils.cmd(['xcrun', 'simctl', 'shutdown', deviceId]);
  // shutdown apparently needs time when restarting
  // see https://github.com/flutter/flutter/issues/10228 for race condition on simulator
  await Future.delayed(Duration(milliseconds: 2000));
}

Future<void> startSimulator(DaemonClient daemonClient, String? deviceId) async {
  try {
    utils.cmd(['xcrun', 'simctl', 'boot', deviceId]);
  } catch (e) {
    // Ignore
  }
  await Future.delayed(Duration(milliseconds: 2000));
  await waitForEmulatorToStart(daemonClient, deviceId);
}

/// Start android emulator and return device id.
Future<String> startEmulator(DaemonClient daemonClient, String? emulatorId, stagingDir) async {
//  if (utils.isCI()) {
//    // testing on CI/CD requires starting emulator in a specific way
//    await _startAndroidEmulatorOnCI(emulatorId, stagingDir);
//    return utils.findAndroidDeviceId(emulatorId);
//  } else {
  // testing locally, so start emulator in normal way
  return await daemonClient.launchEmulator(emulatorId!);
//  }
}

/// Find a real device or running emulator/simulator for [deviceName].
/// Note: flutter daemon handles devices and running emulators/simulators as devices.
DaemonDevice? findRunningDevice(List<DaemonDevice> devices, List<DaemonEmulator>? emulators, String deviceName) {
  return devices.firstWhereOrNull((device) {
//    // hack for CI testing. Platform is reporting as 'android-arm' instead of 'android-x86'
//    if (device.platform == 'android-arm') {
//      /// Find the device name of a running emulator.
//      String findDeviceNameOfRunningEmulator(
//          List<DaemonEmulator> emulators, String deviceId) {
//        final emulatorId = utils.getAndroidEmulatorId(deviceId);
//        final emulator = emulators.firstWhere(
//            (emulator) => emulator.id == emulatorId,
//            orElse: () => null);
//        return emulator == null ? null : emulator.name;
//      }
//
//      final emulatorName =
//          findDeviceNameOfRunningEmulator(emulators, device.id);
//      return emulatorName.contains(deviceName);
//    }

    if (device.emulator!) {
      if (device.platformType == 'android') {
        // running emulator
        return device.emulatorId!.replaceAll('_', ' ').toUpperCase().contains(deviceName.toUpperCase());
      } else {
        // running simulator
        return device.name!.contains(deviceName);
      }
    } else {
      if (device.platformType == 'ios') {
        // real ios device
        return device.iosModel!.contains(deviceName);
      } else {
        // real android device
        return device.name!.contains(deviceName);
      }
    }
  });
}

/// Shutdown an android emulator.
Future<String?> shutdownAndroidEmulator(DaemonClient daemonClient, String deviceId) async {
  utils.cmd([getAdbPath(androidSdk), '-s', deviceId, 'emu', 'kill']);
//  await waitAndroidEmulatorShutdown(deviceId);
  final device = await daemonClient.waitForEvent(EventType.deviceRemoved);
  if (device['id'] != deviceId) {
    throw 'Error: device id \'$deviceId\' not shutdown';
  }
  return device['id'];
}

///// Start android emulator in a CI environment.
//Future _startAndroidEmulatorOnCI(String emulatorId, String stagingDir) async {
//  // testing on CI/CD requires starting emulator in a specific way
//  final androidHome = platform.environment['ANDROID_HOME'];
//  await utils.streamCmd([
//    '$androidHome/emulator/emulator',
//    '-avd',
//    emulatorId,
//    '-no-audio',
//    '-no-window',
//    '-no-snapshot',
//    '-gpu',
//    'swiftshader',
//  ], mode: ProcessStartMode.detached);
//  // wait for emulator to start
//  await utils
//      .streamCmd(['$stagingDir/resources/script/android-wait-for-emulator']);
//}

/// Get device type from config info
DeviceType getDeviceType(Config config, String deviceName) {
  return config.getDevice(deviceName).deviceType;
}
