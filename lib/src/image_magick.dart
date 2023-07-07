import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:screenshots/src/utils.dart';
import 'package:tool_base/tool_base.dart';

import 'context_runner.dart';

final ImageMagick _kImageMagick = ImageMagick();

/// Currently active implementation of ImageMagick.
///
/// Override this in tests with a fake/mocked daemon client.
ImageMagick get im => context.get<ImageMagick>() ?? _kImageMagick;

class ImageMagick {
  static const _kThreshold = 0.76;
  static const kDiffSuffix = '-diff';

//const kThreshold = 0.5;

  // singleton
  static final ImageMagick _imageMagick = ImageMagick._internal();

  factory ImageMagick() {
    return _imageMagick;
  }

  ImageMagick._internal();

  ///
  /// ImageMagick calls.
  ///

  void resizeWithCanvas({
    required String firstImagePath,
    required String size,
    required String backgroundColor,
    required String? padding,
    required String destinationPath,
  }) {
    _imageMagickCmd(
      'convert',
      [
        '-size',
        size,
        'canvas:$backgroundColor',
        firstImagePath,
        '-geometry',
        '+0${padding ?? '+0'}',
        '-composite',
        destinationPath,
      ],
    );
  }

  void overlay({
    required String firstImagePath,
    required String secondImagePath,
    required String destinationPath,
    String gravity = 'north',
  }) {
    _imageMagickCmd(
      'convert',
      [
        firstImagePath,
        secondImagePath,
        '-gravity',
        gravity,
        '-composite',
        destinationPath,
      ],
    );
  }

  void append({
    required String firstImagePath,
    required String secondImagePath,
    required String destinationPath,
  }) {
    // convert -append screenshot_statusbar.png navbar.png final_screenshot.png
    _imageMagickCmd(
      'convert',
      [
        '-append',
        firstImagePath,
        secondImagePath,
        destinationPath,
      ],
    );
  }

  void frame({
    required String imagePath,
    required String size,
    required String backgroundColor,
    required String resize,
    required String offset,
    required String framePath,
    required String destinationPath,
  }) {
    //  convert -size $size xc:none \
//   \( "$frameFile" -resize $resize \) -gravity center -composite \
//   \( final_screenshot.png -resize $resize \) -gravity center -geometry -4-9 -composite \
//   framed.png
    _imageMagickCmd(
      'convert',
      [
        '-size',
        size,
        backgroundColor,
        '(',
        imagePath,
        '-resize',
        resize,
        ')',
        '-gravity',
        'center',
        '-geometry',
        offset,
        '-composite',
        '(',
        framePath,
        '-resize',
        resize,
        ')',
        '-gravity',
        'center',
        '-composite',
        destinationPath,
      ],
    );
  }

  void mask({
    required String imagePath,
    required String maskPath,
    required String? maskResize,
    required String destinationPath,
  }) {
    //  convert in.png -matte \( mask.png -resize <mask_resize> \) -gravity center -compose DstIn -composite out.png
    _imageMagickCmd(
      'convert',
      [
        imagePath,
        '-matte',
        if (maskResize != null) ...[
          '(',
          maskPath,
          '-resize',
          maskResize,
          ')',
        ] else maskPath,
        '-gravity',
        'center',
        '-compose',
        'DstIn',
        '-composite',
        destinationPath,
      ],
    );
  }

  /// Checks if brightness of sample of image exceeds a threshold.
  /// Section is specified by [cropSizeOffset] which is of the form
  /// cropSizeOffset, eg, '1242x42+0+0'.
  bool isThresholdExceeded(String imagePath, String cropSizeOffset, [double threshold = _kThreshold]) {
    //convert logo.png -crop $crop_size$offset +repage -colorspace gray -format "%[fx:(mean>$threshold)?1:0]" info:
    final result = cmd(_getPlatformCmd('convert', <String>[
      imagePath,
      '-crop',
      cropSizeOffset,
      '+repage',
      '-colorspace',
      'gray',
      '-format',
      '""%[fx:(mean>$threshold)?1:0]""',
      'info:'
    ]))!
        .replaceAll('"', ''); // remove quotes ""0""
    return result != '1';
  }

  bool compare(String comparisonImage, String recordedImage) {
    final diffImage = getDiffImagePath(comparisonImage);

    var returnCode = _imageMagickCmd('compare', <String>['-metric', 'mae', recordedImage, comparisonImage, diffImage]);

    if (returnCode == 0) {
      // delete no-diff diff image created by image magick
      fs.file(diffImage).deleteSync();
    }
    return returnCode == 0;
  }

  /// Append diff suffix [kDiffSuffix] to [imagePath].
  String getDiffImagePath(String imagePath) {
    final diffName =
        p.dirname(imagePath) + '/' + p.basenameWithoutExtension(imagePath) + kDiffSuffix + p.extension(imagePath);
    return diffName;
  }

  void deleteDiffs(String dirPath) {
    fs
        .directory(dirPath)
        .listSync()
        .where((fileSysEntity) => p.basename(fileSysEntity.path).contains(kDiffSuffix))
        .forEach((diffImage) => fs.file(diffImage.path).deleteSync());
  }

  /// Different command for windows (based on recommended installed version!)
  List<String> _getPlatformCmd(String imCmd, List imCmdArgs) {
    // windows uses ImageMagick v7 or later which by default does not
    // have the legacy commands.
    if (platform.isWindows) {
      return [
        ...['magick'],
        ...[imCmd],
        ...imCmdArgs
      ];
    } else {
      return [
        ...[imCmd],
        ...imCmdArgs
      ];
    }
  }

  /// ImageMagick command
  int _imageMagickCmd(String imCmd, List imCmdArgs) {
    return runCmd(_getPlatformCmd(imCmd, imCmdArgs));
  }
}

/// Check Image Magick is installed.
Future<bool> isImageMagicInstalled() async {
  try {
    return await runInContext<bool>(() {
      return runCmd(platform.isWindows ? ['magick', '-version'] : ['convert', '-version']) == 0;
    });
  } catch (e) {
    return false;
  }
}
