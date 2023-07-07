import 'dart:async';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:meta/meta.dart';
import 'package:screenshots/src/utils.dart';
import 'package:tool_base/tool_base.dart';

final DaemonClient _kDaemonClient = DaemonClient();

/// Currently active implementation of the daemon client.
///
/// Override this in tests with a fake/mocked daemon client.
DaemonClient get daemonClient => context.get<DaemonClient>() ?? _kDaemonClient;

enum EventType { deviceRemoved }

/// Starts and communicates with flutter daemon.
class DaemonClient {
  late Process _process;
  int _messageId = 0;
  bool _connected = false;
  late Completer _waitForConnection;
  late Completer _waitForResponse;
  Completer<List<dynamic>> _waitForEvent = Completer<List<dynamic>>();
  final Map<String, Completer<List<dynamic>>> _waitForEmulators = {};
  StreamSubscription? _stdOutListener;
  StreamSubscription? _stdErrListener;

  /// Start flutter tools daemon.
  Future<void> get start async {
    if (!_connected) {
      _process = await runCommand(['flutter', 'daemon']);
      _listen();
      _waitForConnection = Completer<bool>();
      _connected = await (_waitForConnection.future as FutureOr<bool>);
      await enableDeviceDiscovery();
      // wait for device discovery
      await Future.delayed(Duration(milliseconds: 100));
    }
  }

  @visibleForTesting
  Future enableDeviceDiscovery() async {
    await _sendCommandWaitResponse(<String, dynamic>{'method': 'device.enable'});
  }

  /// List installed emulators (not including iOS simulators).
  Future<List<DaemonEmulator>> get emulators async {
    final emulators = await _sendCommandWaitResponse(<String, dynamic>{'method': 'emulator.getEmulators'}) ?? [];
    final daemonEmulators = <DaemonEmulator>[];
    for (var emulator in emulators) {
      final daemonEmulator = loadDaemonEmulator(emulator);
      printTrace('daemonEmulator=$daemonEmulator');
      daemonEmulators.add(daemonEmulator);
    }
    return daemonEmulators;
  }

  /// Launch an emulator and return device id.
  Future<String> launchEmulator(String emulatorId) async {
    _waitForEmulators[emulatorId] = Completer<List<dynamic>>();
    final command = <String, dynamic>{
      'method': 'emulator.launch',
      'params': <String, dynamic>{
        'emulatorId': emulatorId,
      },
    };
    _sendCommand(command);

    // wait for expected device-added-emulator event
    // Note: future does not complete if emulator already running
    final results = await Future.wait(<Future>[_waitForResponse.future, _waitForEmulators[emulatorId]!.future]);
    // process the response
    _processResponse(results[0], command);
    // process the event
    final eventInfo = results[1];
    if (eventInfo.length != 1 ||
        eventInfo[0]['event'] != 'device.added' ||
        eventInfo[0]['params']['emulator'] != true) {
      throw 'Error: emulator $emulatorId not started: $eventInfo';
    }

    return Future.value(eventInfo[0]['params']['id']);
  }

  /// List running real devices and booted emulators/simulators.
  Future<List<DaemonDevice>> get devices async {
    final devices = await (_sendCommandWaitResponse(
          <String, dynamic>{'method': 'device.getDevices'},
        )) ??
        [];
    return Future.value(devices.map((device) {
      // add model name if real ios device present
      // if (platform.isMacOS &&
      //     device['platform'] == 'ios' &&
      //     device['emulator'] == false) {
      //   final iosDevice = _iosDevices.firstWhere(
      //       (iosDevice) => iosDevice['id'] == device['id'],
      //       orElse: () =>
      //           throw 'Error: could not find model name for real ios device: ${device['name']}');
      //   device['model'] = iosDevice['model'];
      // }
      final daemonDevice = loadDaemonDevice(device);
      printTrace('daemonDevice=$daemonDevice');
      return daemonDevice;
    }).toList());
  }

  /// Wait for an event of type [EventType] and return event info.
  Future<Map> waitForEvent(EventType eventType) async {
    final eventInfo = await _waitForEvent.future;
    switch (eventType) {
      case EventType.deviceRemoved:
        // event info is a device descriptor
        if (eventInfo.length != 1 || eventInfo[0]['event'] != 'device.removed') {
          throw 'Error: expected: $eventType, received: $eventInfo';
        }
        break;
      default:
        throw 'Error: unexpected event: $eventInfo';
    }
    return Future.value(eventInfo[0]['params']);
  }

  int _exitCode = 0;

  /// Stop daemon.
  Future<int> get stop async {
    if (!_connected) throw 'Error: not connected to daemon.';
    await _sendCommandWaitResponse(<String, dynamic>{'method': 'daemon.shutdown'});
    _connected = false;
    _exitCode = await _process.exitCode;
    await _stdOutListener?.cancel();
    await _stdErrListener?.cancel();
    return _exitCode;
  }

  void _listen() {
    _stdOutListener = _process.stdout
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter())
        .listen((String line) async {
      printTrace('<== $line');
      // todo: decode json
      if (line.contains('daemon.connected')) {
        _waitForConnection.complete(true);
      } else {
        // get response
        if (line.contains('"result":') || line.contains('"error":') || line == '[{"id":${_messageId - 1}}]') {
          _waitForResponse.complete(line);
        } else {
          // get event
          if (line.contains('[{"event":')) {
            if (line.contains('"event":"daemon.logMessage"')) {
              printTrace('Warning: ignoring log message: $line');
            } else {
              final event = jsonDecode(line);
              _waitForEvent.complete(event);
              _waitForEvent = Completer<List<dynamic>>(); // enable wait for next event
              if (line.contains('"event":"device')) {
                for (final emulatorId in _waitForEmulators.keys) {
                  if (line.contains('"emulatorId":"$emulatorId"')) {
                    _waitForEmulators[emulatorId]!.complete(event);
                  }
                }
              }
            }
          } else if (line != 'Starting device daemon...') {
            throw 'Error: unexpected response from daemon: $line';
          }
        }
      }
    });
    _stdErrListener = _process.stderr.listen((dynamic data) => stderr.add(data));
  }

  void _sendCommand(Map<String, dynamic> command) {
    if (_connected) {
      _waitForResponse = Completer<String>();
      command['id'] = _messageId++;
      final str = '[${json.encode(command)}]';
      _process.stdin.writeln(str);
      printTrace('==> $str');
    } else {
      throw 'Error: not connected to daemon.';
    }
  }

  Future<List?> _sendCommandWaitResponse(Map<String, dynamic> command) async {
    _sendCommand(command);
//    printTrace('waiting for response: $command');
    final response = await (_waitForResponse.future as FutureOr<String>);
//    printTrace('response: $response');
    return _processResponse(response, command);
  }

  List? _processResponse(String response, Map<String, dynamic> command) {
    if (response.contains('result')) {
      final respExp = RegExp(r'result":(.*)}\]');
      return jsonDecode(respExp.firstMatch(response)!.group(1)!);
    } else if (response.contains('error')) {
      // todo: handle errors separately
      throw 'Error: command $command failed:\n ${jsonDecode(response)[0]['error']}';
    } else {
      return jsonDecode(response);
    }
  }
}

/// Get attached ios devices with id and model.
List getIosDevices() {
  final regExp = RegExp(r'Found (\w+) \(\w+, (.*), \w+, \w+\)');
  final noAttachedDevices = 'no attached devices';
  final iosDeployDevices =
      cmd(['sh', '-c', 'ios-deploy -c || echo "$noAttachedDevices"'])!.trim().split('\n').sublist(1);
  if (iosDeployDevices.isEmpty || iosDeployDevices[0] == noAttachedDevices) {
    return [];
  }
  return iosDeployDevices.map((line) {
    final matches = regExp.firstMatch(line)!;
    final device = {};
    device['id'] = matches.group(1);
    device['model'] = matches.group(2);
    return device;
  }).toList();
}

/// Wait for emulator or simulator to start
Future waitForEmulatorToStart(DaemonClient daemonClient, String? deviceId) async {
  var started = false;
  while (!started) {
    printTrace('waiting for emulator/simulator with device id \'$deviceId\' to start...');
    final devices = await daemonClient.devices;
    final device = devices.firstWhereOrNull((device) => device.id == deviceId && device.emulator!);
    started = device != null;
    await Future.delayed(Duration(milliseconds: 1000));
  }
}

abstract class BaseDevice {
  final String? id;
  final String? name;
  final String? category;
  final String? platformType;

  BaseDevice(this.id, this.name, this.category, this.platformType);

  @override
  bool operator ==(other) {
    return other is BaseDevice &&
        other.name == name &&
        other.id == id &&
        other.category == category &&
        other.platformType == platformType;
  }

  @override
  String toString() {
    return 'id: $id, name: $name, category: $category, platformType: $platformType';
  }
}

/// Describe an emulator.
class DaemonEmulator extends BaseDevice {
  DaemonEmulator(
    String? id,
    String? name,
    String? category,
    String? platformType,
  ) : super(id, name, category, platformType);
}

/// Describe a device.
class DaemonDevice extends BaseDevice {
  final String? platform;
  final bool? emulator;
  final bool? ephemeral;
  final String? emulatorId;
  final String? iosModel; //  iOS model
  DaemonDevice(
    String? id,
    String? name,
    String? category,
    String? platformType,
    this.platform,
    this.emulator,
    this.ephemeral,
    this.emulatorId, {
    this.iosModel,
  }) : super(id, name, category, platformType) {
    // debug check in CI
    if (emulator! && emulatorId == null) throw 'Emulator id is null';
  }

  @override
  bool operator ==(other) {
    return super == other &&
        other is DaemonDevice &&
        other.platform == platform &&
        other.emulator == emulator &&
        other.ephemeral == ephemeral &&
        other.emulatorId == emulatorId &&
        other.iosModel == iosModel;
  }

  @override
  String toString() {
    return super.toString() +
        ' platform: $platform, emulator: $emulator, ephemeral: $ephemeral, emulatorId: $emulatorId, iosModel: $iosModel';
  }
}

DaemonEmulator loadDaemonEmulator(Map<String, dynamic> emulator) {
  return DaemonEmulator(
    emulator['id'],
    emulator['name'],
    emulator['category'],
    emulator['platformType'],
  );
}

DaemonDevice loadDaemonDevice(Map<String, dynamic> device) {
  // hack for CI testing.
  // flutter daemon is reporting x64 emulator as real device while
  // flutter doctor is reporting correctly.
  // Platform is reporting as 'android-arm' instead of 'android-x64', etc...
  if (platform.environment['CI']?.toLowerCase() == 'true' && device['emulator'] == false) {
    return DaemonDevice(
      device['id'],
      device['name'],
      device['category'],
      device['platformType'],
      device['platform'],
      true,
      device['ephemeral'],
      'NEXUS_6P_API_28',
      iosModel: device['model'],
    );
  }
  return DaemonDevice(
    device['id'],
    device['name'],
    device['category'],
    device['platformType'],
    device['platform'],
    device['emulator'],
    device['ephemeral'],
    device['emulatorId'],
    iosModel: device['model'],
  );
}
