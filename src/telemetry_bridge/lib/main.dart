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
  const TelemetryBridgeApp({super.key});

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
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

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
  final String _serverUrl = 'https://sandmining.nielitbhubaneswar.in/api/edge/sync';

  // Telemetry variables (boot state: waiting/unacquired)
  double _lat = 0.0;
  double _lon = 0.0;
  double _altitude = -1.0;
  double _speed = -1.0;
  int _battery = -1;

  // RTMP Streaming variables
  bool _isRtmpStreaming = false;
  String _rtmpStatus = 'IDLE';
  final TextEditingController _rtmpController = TextEditingController();

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
      case 'onRTMPStatusUpdate':
        final Map data = call.arguments as Map;
        setState(() {
          _rtmpStatus = data['status'] as String;
          if (_rtmpStatus == 'STREAMING') {
            _isRtmpStreaming = true;
          } else if (_rtmpStatus == 'IDLE') {
            _isRtmpStreaming = false;
          } else if (_rtmpStatus == 'FAILED') {
            _isRtmpStreaming = false;
            _addLog('[RTMP ERROR] Broadcast failed: ${data['error']}');
          }
        });
        break;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    _rtmpController.dispose();
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
                    // ignore: deprecated_member_use
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
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
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
                    activeThumbColor: const Color(0xFF38BDF8),
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
                    activeThumbColor: const Color(0xFF10B981),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  color: const Color(0xFF1E293B),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Expanded(
                              child: Row(
                                children: [
                                  Icon(Icons.live_tv, color: Color(0xFF38BDF8), size: 18),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'RTMP Live Stream Broadcaster',
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: _isRtmpStreaming 
                                    ? const Color(0xFF10B981).withOpacity(0.15) 
                                    : Colors.grey.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _isRtmpStreaming ? 'LIVE' : 'STANDBY',
                                style: TextStyle(
                                  color: _isRtmpStreaming ? const Color(0xFF10B981) : Colors.grey,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Configure target RTMP publishing URL to stream the Mini 4 Pro camera feed live.',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 42,
                                child: TextField(
                                  controller: _rtmpController,
                                  enabled: !_isRtmpStreaming,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white,
                                    fontFamily: 'monospace',
                                  ),
                                  decoration: InputDecoration(
                                    hintText: 'rtmp://server/live/stream',
                                    hintStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    filled: true,
                                    fillColor: const Color(0xFF0F172A),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: Color(0xFF334155)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              height: 42,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _isRtmpStreaming 
                                      ? const Color(0xFFEF4444) 
                                      : const Color(0xFF10B981),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                ),
                                icon: Icon(
                                  _isRtmpStreaming ? Icons.portable_wifi_off : Icons.wifi_tethering,
                                  color: Colors.white,
                                  size: 16,
                                ),
                                label: Text(
                                  _isRtmpStreaming ? 'STOP' : 'START',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                onPressed: () {
                                  if (_isRtmpStreaming) {
                                    _platform.invokeMethod('stopRTMPStream').then((val) {
                                      _addLog('[RTMP] Requested stop stream.');
                                    }).catchError((e) {
                                      _addLog('[RTMP ERROR] Stop stream failed: $e');
                                    });
                                  } else {
                                    var url = _rtmpController.text.trim();
                                    if (url.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Please enter a valid stream URL!'),
                                          backgroundColor: Color(0xFFEF4444),
                                        ),
                                      );
                                      return;
                                    }
                                    if (!url.startsWith('rtmp://') && !url.startsWith('rtmps://')) {
                                      url = 'rtmp://$url';
                                    }
                                    _platform.invokeMethod('startRTMPStream', {'url': url}).then((val) {
                                      _addLog('[RTMP] Requested start stream to: $url');
                                    }).catchError((e) {
                                      _addLog('[RTMP ERROR] Start stream failed: $e');
                                    });
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
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

          _buildRawFeedMonitor(),

          const SizedBox(height: 8),

          // Interactive terminal console
          Container(
            height: 140,
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
                                // ignore: deprecated_member_use
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
          ],
        ),
      ),
    );
  }

  Widget _buildHUDCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
        // ignore: deprecated_member_use
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
                  // ignore: deprecated_member_use
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

  Widget _buildRawFeedMonitor() {
    final double currentLat = _lat;
    final double currentLon = _lon;
    final double currentAlt = _altitude;
    final double currentSpeed = _speed;
    final int currentBat = _battery;

    final double horizonOffset = _isSimulating 
        ? 15.0 * math.sin(_simAngle * 2.0) 
        : (_isRtmpStreaming ? 5.0 * math.sin(DateTime.now().millisecond / 100.0) : 0.0);
    final double rollAngle = _isSimulating 
        ? 0.1 * math.cos(_simAngle) 
        : (_isRtmpStreaming ? 0.03 * math.cos(DateTime.now().millisecond / 200.0) : 0.0);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      height: 180,
      decoration: BoxDecoration(
        color: const Color(0xFF030712),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isRtmpStreaming ? const Color(0xFF10B981) : const Color(0xFF334155),
          width: 1.5,
        ),
        boxShadow: _isRtmpStreaming ? [
          BoxShadow(
            color: const Color(0xFF10B981).withOpacity(0.15),
            blurRadius: 10,
            spreadRadius: 2,
          )
        ] : [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: 0.1,
                child: Container(
                  color: const Color(0xFF0F172A),
                ),
              ),
            ),
            
            if (_isDJIConnected)
              const Positioned.fill(
                child: AndroidView(
                  viewType: 'sq.rogue.telemetry_bridge/dji_camera_view',
                  creationParams: <String, dynamic>{},
                  creationParamsCodec: StandardMessageCodec(),
                ),
              ),
            
            CustomPaint(
              size: Size.infinite,
              painter: _HUDGridPainter(
                horizonOffset: horizonOffset, 
                rollAngle: rollAngle, 
                isActive: _isRtmpStreaming || _isSimulating
              ),
            ),

            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: List.generate(45, (index) => 
                        index % 2 == 0 ? Colors.transparent : Colors.black.withOpacity(0.15)
                      ),
                    ),
                  ),
                ),
              ),
            ),

            if (!_isRtmpStreaming && !_isSimulating)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.videocam_off, 
                      color: Colors.amber.withOpacity(0.6), 
                      size: 32,
                      shadows: [
                        Shadow(color: Colors.amber.withOpacity(0.3), blurRadius: 8)
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'RAW VIDEO FEED STANDBY',
                      style: TextStyle(
                        color: Colors.amber.withOpacity(0.8),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'CONNECT DRONE & START RTMP TO BROADCAST',
                      style: TextStyle(
                        color: Colors.grey.withOpacity(0.8),
                        fontSize: 9,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),

            if (_isRtmpStreaming || _isSimulating) ...[
              Positioned(
                top: 8,
                left: 12,
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFEF4444),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isRtmpStreaming ? 'LIVE // BROADCASTING' : 'SIMULATOR // ACTIVE',
                      style: const TextStyle(
                        color: Color(0xFFEF4444),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 8,
                right: 12,
                child: Text(
                  '1080P HD @ 60FPS\nBITRATE: ${(4.5 + 0.3 * math.sin(DateTime.now().second.toDouble())).toStringAsFixed(1)} MBPS',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Color(0xFF38BDF8),
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ),

              Center(
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF38BDF8).withOpacity(0.3),
                      width: 1,
                    ),
                  ),
                ),
              ),

              Positioned(
                bottom: 8,
                left: 12,
                right: 12,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'GPS: ${currentLat == 0.0 ? "ACQUIRING..." : "${currentLat.toStringAsFixed(5)}, ${currentLon.toStringAsFixed(5)}"}\nALT: ${currentAlt == -1.0 ? "0.0" : currentAlt.toStringAsFixed(1)} M',
                      style: TextStyle(
                        color: const Color(0xFF10B981).withOpacity(0.8),
                        fontSize: 9,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'BAT: ${currentBat == -1 ? "100" : currentBat}%\nSPD: ${currentSpeed == -1.0 ? "0.0" : currentSpeed.toStringAsFixed(1)} KM/H',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: const Color(0xFF10B981).withOpacity(0.8),
                        fontSize: 9,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              )
            ],
          ],
        ),
      ),
    );
  }
}

class _HUDGridPainter extends CustomPainter {
  final double horizonOffset;
  final double rollAngle;
  final bool isActive;

  _HUDGridPainter({required this.horizonOffset, required this.rollAngle, required this.isActive});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isActive ? const Color(0xFF38BDF8).withOpacity(0.15) : const Color(0xFF334155).withOpacity(0.1)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final center = Offset(size.width / 2, size.height / 2);

    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (int i = 1; i < 5; i++) {
      final x = size.width * i / 5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    if (isActive) {
      final hudPaint = Paint()
        ..color = const Color(0xFF10B981).withOpacity(0.4)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(rollAngle);
      canvas.translate(0, horizonOffset);

      canvas.drawLine(const Offset(-40, 0), const Offset(-10, 0), hudPaint);
      canvas.drawLine(const Offset(10, 0), const Offset(40, 0), hudPaint);
      canvas.drawCircle(Offset.zero, 3, hudPaint..style = PaintingStyle.fill);

      canvas.drawLine(const Offset(-20, -20), const Offset(-10, -20), hudPaint..style = PaintingStyle.stroke);
      canvas.drawLine(const Offset(-20, -20), const Offset(-20, -15), hudPaint);
      canvas.drawLine(const Offset(20, -20), const Offset(10, -20), hudPaint);
      canvas.drawLine(const Offset(20, -20), const Offset(20, -15), hudPaint);

      canvas.drawLine(const Offset(-20, 20), const Offset(-10, 20), hudPaint);
      canvas.drawLine(const Offset(-20, 20), const Offset(-20, 15), hudPaint);
      canvas.drawLine(const Offset(20, 20), const Offset(10, 20), hudPaint);
      canvas.drawLine(const Offset(20, 20), const Offset(20, 15), hudPaint);

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _HUDGridPainter oldDelegate) {
    return oldDelegate.horizonOffset != horizonOffset || 
           oldDelegate.rollAngle != rollAngle || 
           oldDelegate.isActive != isActive;
  }
}
