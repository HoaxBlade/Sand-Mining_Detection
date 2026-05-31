import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';

void main() {
  runApp(const TelemetryBridgeApp());
}

class TelemetryBridgeApp extends StatelessWidget {
  const TelemetryBridgeApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drone Telemetry Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8), // Neon blue
          secondary: Color(0xFF10B981), // Glowing green
          surface: Color(0xFF1E293B),
          background: Color(0xFF0B0F19),
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({Key? key}) : super(key: key);

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // Native Platform Channel Bridge
  static const _platform = MethodChannel('sq.rogue.telemetry_bridge/dji');

  // Connection states
  bool _isBroadcasting = false;
  bool _isSimulating = false; // Default simulator to OFF on boot
  bool _isDJIConnected = false;
  String _serverUrl = 'https://sandmining.nielitbhubaneswar.in/api/edge/sync';

  // Telemetry variables (boot state: waiting/unacquired)
  double _lat = 0.0;
  double _lon = 0.0;
  double _altitude = -1.0;
  double _speed = -1.0;
  int _battery = -1;

  // Simulator helper variables
  double _simAngle = 0.0;
  Timer? _timer;

  // Log terminal variables
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _addLog('System Initialized. Ready for flight connection.');
    _addLog('Target Server: $_serverUrl');
    _startTelemetryLoop();
    _setupPlatformChannel();
  }

  void _setupPlatformChannel() {
    _platform.setMethodCallHandler(_handleNativeMethodCall);
    // Trigger DJI SDK registration check inside native Kotlin
    _platform.invokeMethod('startDJISDK').then((value) {
      _addLog('[SDK] Platform channel initialized: $value');
    }).catchError((e) {
      _addLog('[SDK ERROR] Platform channel failed: $e');
    });
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onConsoleLog':
        _addLog(call.arguments as String);
        break;
      case 'onSDKStatusUpdate':
        final Map data = call.arguments as Map;
        if (data['status'] == 'REGISTERED') {
          _addLog('[SDK] DJI Registration status: SUCCESS');
        } else {
          _addLog('[SDK ERROR] DJI Registration status: FAILED (${data['error']})');
        }
        break;
      case 'onDJIConnectionUpdate':
        final bool connected = call.arguments as bool;
        setState(() {
          _isDJIConnected = connected;
          if (connected) {
            // Auto disable simulator upon actual physical controller plug-in!
            _isSimulating = false;
          } else {
            // Clear state back to waiting if not in simulation mode
            if (!_isSimulating) {
              _lat = 0.0;
              _lon = 0.0;
              _altitude = -1.0;
              _speed = -1.0;
              _battery = -1;
            }
          }
        });
        _addLog('[DJI] Aircraft Connection state updated: ${connected ? "CONNECTED" : "DISCONNECTED"}');
        break;
      case 'onTelemetryUpdate':
        final Map data = call.arguments as Map;
        if (!_isSimulating) {
          setState(() {
            _lat = data['lat'] as double;
            _lon = data['lon'] as double;
            _altitude = data['altitude'] as double;
            // Native speed is in m/s, convert to km/h for pilot HUD display
            _speed = (data['speed'] as double) * 3.6;
          });
        }
        break;
      case 'onBatteryUpdate':
        final int batPercent = call.arguments as int;
        if (!_isSimulating) {
          setState(() {
            _battery = batPercent;
          });
        }
        break;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _addLog(String message) {
    final timestamp = DateTime.now().toLocal().toString().split(' ')[1].substring(0, 8);
    setState(() {
      _logs.add('[$timestamp] $message');
      if (_logs.length > 100) {
        _logs.removeAt(0);
      }
    });
    // Auto scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _startTelemetryLoop() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_isSimulating) {
        _runSimulationStep();
      }

      if (_isBroadcasting) {
        _sendTelemetryToServer();
      }
    });
  }

  void _runSimulationStep() {
    setState(() {
      // Simulate slow battery drain
      if (math.Random().nextDouble() < 0.05) {
        _battery = math.max(15, _battery - 1);
      }

      // Simulate movement along a wave path (Brahmaputra River path)
      _simAngle += 0.03;
      _lat = 26.12555 + 0.015 * math.sin(_simAngle);
      _lon = 91.81244 + 0.025 * _simAngle; // Slowly drifts Eastward

      // altitude hover
      _altitude = 65.0 + 5.0 * math.sin(_simAngle * 2.5);

      // speed hover
      _speed = 18.5 + 4.0 * math.cos(_simAngle * 1.5);
    });
  }

  Future<void> _sendTelemetryToServer() async {
    if (_lat == 0.0 && _lon == 0.0) {
      _addLog('Sync Skipped: Waiting for valid GPS coordinates...');
      return;
    }
    if (_battery == -1) {
      _addLog('Sync Skipped: Waiting for battery telemetry...');
      return;
    }

    final payload = {
      'lat': _lat,
      'lon': _lon,
      'altitude': _altitude < 0 ? 0.0 : _altitude,
      'speed': _speed < 0 ? 0.0 : _speed / 3.6, // Server expects m/s, HUD converts back to km/h
      'battery': _battery < 0 ? 0 : _battery,
    };

    try {
      final response = await http.post(
        Uri.parse(_serverUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        _addLog('Synced: ${_lat.toStringAsFixed(5)}, ${_lon.toStringAsFixed(5)} | Bat: $_battery% (Success)');
      } else {
        _addLog('Server Error: Code ${response.statusCode}');
      }
    } catch (e) {
      _addLog('Connection Error: Failed to reach cloud API');
    }
  }

  Color _getStatusColor() {
    if (!_isBroadcasting) {
      return const Color(0xFFEF4444); // Red: Broadcasting Off
    }
    if (_isDJIConnected) {
      return const Color(0xFF10B981); // Emerald Green: Active Drone Telemetry Sync
    }
    if (_isSimulating) {
      return const Color(0xFF38BDF8); // Neon Blue: Route Simulator Active
    }
    return const Color(0xFFF59E0B); // Amber Orange: Waiting for Physical Drone Accessory
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: statusColor.withOpacity(0.5),
                    blurRadius: 8,
                    spreadRadius: 2,
                  )
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              'TACTICAL HUD BRIDGE',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                fontSize: 16,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                if (_isSimulating) {
                  _lat = 26.12555;
                  _lon = 91.81244;
                  _simAngle = 0.0;
                  _battery = 100;
                  _altitude = 65.0;
                  _speed = 18.5;
                  _addLog('Telemetry simulator reset to home coordinates.');
                } else {
                  if (!_isDJIConnected) {
                    _lat = 0.0;
                    _lon = 0.0;
                    _battery = -1;
                    _altitude = -1.0;
                    _speed = -1.0;
                  }
                  _addLog('HUD reset to unacquired state (waiting for DJI connection).');
                }
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Control switches panel
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF0F172A),
            child: Column(
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  color: const Color(0xFF1E293B),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: SwitchListTile(
                    title: const Text('Route Simulation Mode', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                    subtitle: const Text('Generates mock flight telemetry for virtual mapping tests', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    value: _isSimulating,
                    onChanged: (val) {
                      setState(() {
                        _isSimulating = val;
                        if (val) {
                          // Warm up simulator variables instantly
                          _lat = 26.12555;
                          _lon = 91.81244;
                          _battery = 100;
                          _altitude = 65.0;
                          _speed = 18.5;
                          _simAngle = 0.0;
                        } else {
                          // Clear back to unacquired state if no real DJI product connected
                          if (!_isDJIConnected) {
                            _lat = 0.0;
                            _lon = 0.0;
                            _battery = -1;
                            _altitude = -1.0;
                            _speed = -1.0;
                          }
                        }
                      });
                      _addLog('Telemetry simulator ${val ? "ENABLED" : "DISABLED"}');
                    },
                    activeColor: const Color(0xFF38BDF8),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  color: const Color(0xFF1E293B),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: SwitchListTile(
                    title: const Text('Cloud Telemetry Sync', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                    subtitle: const Text('Broadcast live coordinates and battery to the dashboard', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    value: _isBroadcasting,
                    onChanged: (val) {
                      setState(() => _isBroadcasting = val);
                      _addLog('Cloud telemetry broadcast ${val ? "ACTIVATED" : "DEACTIVATED"}');
                    },
                    activeColor: const Color(0xFF10B981),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Primary Grid Telemetry displays
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.6,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildHUDCard(
                  'GPS COORDINATES',
                  (_lat == 0.0 && _lon == 0.0) 
                      ? 'ACQUIRING GPS...' 
                      : '${_lat.toStringAsFixed(5)}, ${_lon.toStringAsFixed(5)}',
                  Icons.gps_fixed,
                  const Color(0xFF38BDF8),
                ),
                _buildHUDCard(
                  'BATTERY LEVEL',
                  _battery == -1 ? 'WAITING FOR DJI...' : '$_battery%',
                  Icons.battery_charging_full,
                  _battery == -1 
                      ? Colors.grey 
                      : (_battery > 20 ? const Color(0xFF10B981) : const Color(0xFFEF4444)),
                ),
                _buildHUDCard(
                  'SPEED (RAW)',
                  _speed == -1.0 ? '--' : '${_speed.toStringAsFixed(1)} km/h',
                  Icons.speed,
                  const Color(0xFFF59E0B),
                ),
                _buildHUDCard(
                  'ALTITUDE',
                  _altitude == -1.0 ? '--' : '${_altitude.toStringAsFixed(1)} m',
                  Icons.landscape,
                  const Color(0xFFA855F7),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Interactive terminal console
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF070A13),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF334155), width: 1.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.terminal, color: Color(0xFF38BDF8), size: 14),
                            const SizedBox(width: 6),
                            Text(
                              'PILOT CONSOLE',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: const Color(0xFF38BDF8).withOpacity(0.8),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.content_copy, color: Color(0xFF38BDF8), size: 14),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            tooltip: 'Copy Console Logs',
                            onPressed: () {
                              if (_logs.isNotEmpty) {
                                final allLogs = _logs.join('\n');
                                Clipboard.setData(ClipboardData(text: allLogs));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Console logs successfully copied to clipboard!'),
                                    duration: Duration(seconds: 2),
                                    backgroundColor: Color(0xFF10B981), // Neon Green Success
                                  ),
                                );
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Console log is currently empty.'),
                                    duration: Duration(seconds: 2),
                                    backgroundColor: Color(0xFFEF4444), // Red Warning
                                  ),
                                );
                              }
                            },
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'WS/SYNC ACTIVE',
                            style: TextStyle(
                              color: _isBroadcasting ? const Color(0xFF10B981) : Colors.grey,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const Divider(color: Color(0xFF334155), height: 16),
                  Expanded(
                    child: ListView.builder(
                      controller: _scrollController,
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                          child: Text(
                            _logs[index],
                            style: const TextStyle(
                              color: Color(0xFFE2E8F0),
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHUDCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.2), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Icon(icon, color: color, size: 16),
            ],
          ),
          Text(
            value,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              shadows: [
                Shadow(
                  color: color.withOpacity(0.3),
                  blurRadius: 4,
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}
