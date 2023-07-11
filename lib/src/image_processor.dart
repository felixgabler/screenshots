import 'dart:async';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:screenshots/src/config.dart';
import 'package:screenshots/src/image_magick.dart';
import 'package:screenshots/src/orientation.dart';
import 'package:tool_base/tool_base.dart' hide Config;

import 'archive.dart';
import 'fastlane.dart' as fastlane;
import 'globals.dart';
import 'resources.dart' as resources;
import 'screens.dart';
import 'utils.dart' as utils;

class ImageProcessor {
  static const _kCrop = '1000x40+0+0'; // default sample size and location to test for brightness

  final Screens _screens;
  final Config _config;

  ImageProcessor(Screens screens, Config config)
      : _screens = screens,
        _config = config;

  /// Process screenshots.
  ///
  /// If android, screenshot is overlaid with a status bar and appended with
  /// a navbar.
  ///
  /// If ios, screenshot is overlaid with a status bar.
  ///
  /// If 'frame' in config file is true, screenshots are placed within image of device.
  ///
  /// After processing, screenshots are handed off for upload via fastlane.
  Future<bool> process(
    DeviceType deviceType,
    String deviceName,
    Orientation? orientation,
    RunMode? runMode,
    Archive? archive,
  ) async {
    final screenProps = _screens.getScreen(deviceName);
    for (final lang in _config.locales) {
      final originalScreenshotsDir = '${_config.stagingDir}/$kTestScreenshotsDir/$lang';
      final unframedScreenshotsDir = '${_config.stagingDir}/unframed/$lang';
      final framedScreenshotsDir = '${_config.stagingDir}/framed/$lang';

      // copy original screenshots before converting them
      utils.copyFiles(originalScreenshotsDir, unframedScreenshotsDir);

      final unframedScreenshotPaths = fs.directory(unframedScreenshotsDir).listSync();
      if (screenProps == null) {
        printStatus('Warning: \'$deviceName\' images will not be processed');
      } else {
        final Map screenResources = screenProps['resources'];
        final status = logger?.startProgress(
          'Processing screenshots from test...',
          timeout: Duration(minutes: 4),
        );

        // unpack images for screen from package to local tmpDir area
        await resources.unpackImages(screenResources, _config.stagingDir);

        // add status and nav bar for each screenshot
        if (unframedScreenshotPaths.isEmpty) {
          printStatus('Warning: no screenshots found in $unframedScreenshotsDir');
        }

        for (final screenshotPath in unframedScreenshotPaths) {
          // enforce correct size and add background if necessary
          addBackgroundIfRequired(
            screenProps,
            screenshotPath.path,
          );

          // add status bar for each screenshot
          await overlayStatusbar(
            _config.stagingDir!,
            screenResources,
            screenProps,
            screenshotPath.path,
          );

          if (_config.isNavbarRequired(deviceName, orientation)) {
            // add nav bar for each screenshot
            await overlayNavbar(
              _config.stagingDir!,
              screenResources,
              screenshotPath.path,
              deviceType,
            );
          }
        }

        // add frame if required
        if (_config.isFrameRequired(deviceName, orientation)) {
          // copy unframed screenshots before framing them
          utils.copyFiles(unframedScreenshotsDir, framedScreenshotsDir);

          // frame screenshots
          final framedScreenshotPaths = fs.directory(framedScreenshotsDir).listSync();
          for (final screenshotPath in framedScreenshotPaths) {
            await frame(
              _config.stagingDir!,
              screenProps,
              screenshotPath.path,
              deviceType,
              runMode,
            );
          }

          status?.stop();
        } else {
          printStatus('Warning: framing is not enabled');
        }
      }

      // move screenshots to final destination for upload to stores via fastlane
      if (unframedScreenshotPaths.isNotEmpty) {
        final androidModelType = fastlane.getAndroidModelType(screenProps, deviceName);
        var dstDir = fastlane.getDirPath(deviceType, lang, androidModelType, framed: true);
        runMode == RunMode.recording ? dstDir = '${_config.recordingDir}/$dstDir' : null;
        runMode == RunMode.archive ? dstDir = archive!.dstDir(deviceType, lang) : null;
        // prefix screenshots with name of device before moving
        // (useful for uploading to apple via fastlane)
        await utils.prefixFilesInDir(framedScreenshotsDir,
            '$deviceName-${orientation == null ? kDefaultOrientation : utils.getStringFromEnum(orientation)}-');

        printStatus('Moving framed screenshots to $dstDir');
        utils.moveFiles(framedScreenshotsDir, dstDir);

        if (runMode == RunMode.comparison) {
          final recordingDir = '${_config.recordingDir}/$dstDir';
          printStatus('Running comparison with recorded screenshots in $recordingDir ...');
          final failedCompare = await compareImages(deviceName, recordingDir, dstDir);
          if (failedCompare.isNotEmpty) {
            showFailedCompare(failedCompare);
            throw 'Error: comparison failed.';
          }
        }

        // move unframed screenshots to final destination
        dstDir = fastlane.getDirPath(deviceType, lang, androidModelType, framed: false);
        // prefix screenshots with name of device before moving
        await utils.prefixFilesInDir(unframedScreenshotsDir,
            '$deviceName-${orientation == null ? kDefaultOrientation : utils.getStringFromEnum(orientation)}-');
        printStatus('Moving unframed screenshots to $dstDir');
        utils.moveFiles(unframedScreenshotsDir, dstDir);
      }
    }
    return true; // for testing
  }

  @visibleForTesting
  static void showFailedCompare(Map failedCompare) {
    printError('Comparison failed:');

    failedCompare.forEach((screenshotName, result) {
      printError('${result['comparison']} is not equal to ${result['recording']}');
      printError('       Differences can be found in ${result['diff']}');
    });
  }

  @visibleForTesting
  static Future<Map> compareImages(String deviceName, String recordingDir, String? comparisonDir) async {
    var failedCompare = <String, Map<String, String>>{};
    final recordedImages = fs.directory(recordingDir).listSync();
    fs
        .directory(comparisonDir)
        .listSync()
        .where((screenshot) =>
            p.basename(screenshot.path).contains(deviceName) &&
            !p.basename(screenshot.path).contains(ImageMagick.kDiffSuffix))
        .forEach((screenshot) {
      final screenshotName = p.basename(screenshot.path);
      final recordedImageEntity = recordedImages.firstWhere((image) => p.basename(image.path) == screenshotName,
          orElse: (() => throw 'Error: screenshot $screenshotName not found in $recordingDir'));

      if (!im.compare(screenshot.path, recordedImageEntity.path)) {
        failedCompare[screenshotName] = {
          'recording': recordedImageEntity.path,
          'comparison': screenshot.path,
          'diff': im.getDiffImagePath(screenshot.path)
        };
      }
    });
    return failedCompare;
  }

  static void addBackgroundIfRequired(
    Map screen,
    String screenshotPath,
  ) {
    final background =
        im.isThresholdExceeded(screenshotPath, _kCrop) ? screen['background dark'] : screen['background light'];
    if (background != null) {
      im.resizeWithCanvas(
        firstImagePath: screenshotPath,
        size: screen['size'],
        backgroundColor: background,
        padding: screen['statusbar offset'],
        destinationPath: screenshotPath,
      );
    }
  }

  /// Overlay status bar over screenshot.
  static Future<void> overlayStatusbar(
    String tmpDir,
    Map screenResources,
    Map screen,
    String screenshotPath,
  ) async {
    // if no status bar skip
    // todo: get missing status bars
    if (screenResources['statusbar'] == null) {
      printStatus('error: image ${p.basename(screenshotPath)} is missing status bar.');
      return Future.value(null);
    }

    var statusbarPath = '$tmpDir/${screenResources['statusbar']}';
    // select black or white status bar based on brightness of area to be overlaid
    // todo: add black and white status bars
    if (im.isThresholdExceeded(screenshotPath, _kCrop) && screenResources.containsKey('statusbar black')) {
      // use black status bar
      statusbarPath = '$tmpDir/${screenResources['statusbar black']}';
    } else if (!im.isThresholdExceeded(screenshotPath, _kCrop) && screenResources.containsKey('statusbar white')) {
      // use white status bar
      statusbarPath = '$tmpDir/${screenResources['statusbar white']}';
    }

    im.overlay(
      firstImagePath: screenshotPath,
      secondImagePath: statusbarPath,
      destinationPath: screenshotPath,
    );
  }

  /// Append android navigation bar to screenshot.
  static Future<void> overlayNavbar(
      String tmpDir, Map screenResources, String screenshotPath, DeviceType deviceType) async {
    // if no nav bar skip
    if (screenResources['navbar'] == null) {
      printStatus('error: image ${p.basename(screenshotPath)} is missing nav bar.');
      return Future.value(null);
    }

    var navbarPath = '$tmpDir/${screenResources['navbar']}';
    // select black or white nav bar based on brightness of area to be overlaid
    if (im.isThresholdExceeded(screenshotPath, _kCrop) && screenResources.containsKey('navbar black')) {
      // use black nav bar
      navbarPath = '$tmpDir/${screenResources['navbar black']}';
    } else if (!im.isThresholdExceeded(screenshotPath, _kCrop) && screenResources.containsKey('navbar white')) {
      // use white nav bar
      navbarPath = '$tmpDir/${screenResources['navbar white']}';
    }

    im.overlay(
      firstImagePath: screenshotPath,
      secondImagePath: navbarPath,
      destinationPath: screenshotPath,
      gravity: 'south',
    );
  }

  /// Frame a copy of the screenshot with image of device.
  ///
  /// Resulting image is scaled to fit dimensions required by stores.
  static Future<void> frame(
    String tmpDir,
    Map screen,
    String screenshotPath,
    DeviceType deviceType,
    RunMode? runMode,
  ) async {
    final Map resources = screen['resources'];

    final framePath = tmpDir + '/' + resources['frame'];
    final size = screen['size'];
    final resize = screen['resize'];
    final offset = screen['offset'];

    im.frame(
      imagePath: screenshotPath,
      size: size,
      // transparent
      backgroundColor: 'xc:none',
      resize: resize,
      offset: offset,
      framePath: framePath,
      destinationPath: screenshotPath,
    );

    if (resources.containsKey('mask')) {
      final maskPath = tmpDir + '/' + resources['mask'];

      im.mask(
        imagePath: screenshotPath,
        maskPath: maskPath,
        maskResize: resize,
        destinationPath: screenshotPath,
      );
    }
  }
}
