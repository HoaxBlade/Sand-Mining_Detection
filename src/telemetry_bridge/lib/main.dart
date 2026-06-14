import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';


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
  bool _isDJIConnected = false;
  final String _serverUrl = 'https://sandmining.nielitbhubaneswar.in/api/edge/sync';

  // Cloud AI & Model Selection variables
  bool _isAiDetectionEnabled = false;
  List<String> _availableModels = ['yolov8n.pt'];
  String _selectedModel = 'yolov8n.pt';
  bool _isLoadingModels = false;
  List<Map<String, dynamic>> _detections = [];
  int _frameWidth = 1280;
  int _frameHeight = 720;

  // Map and Geofencing state variables
  final List<LatLng> _drawnPoints = [];
  bool _isDrawingMode = false;
  List<List<LatLng>> _customGeofencePolygons = [];
  List<List<LatLng>> _riverBufferPolygons = [];
  bool _isInsideIllegalZone = false;
  bool _isSatelliteMode = true;
  bool _autoFollowDrone = true;
  int _currentTab = 0;
  final MapController _mapController = MapController();

  // Violation/Incident points for map display
  final List<ViolationPoint> _violationPoints = [];
  Timer? _incidentsFetchTimer;

  // Extract base URL dynamically from _serverUrl
  String get _baseUrl {
    try {
      final uri = Uri.parse(_serverUrl);
      return '${uri.scheme}://${uri.host}${uri.hasPort ? ":${uri.port}" : ""}';
    } catch (_) {
      return 'https://sandmining.nielitbhubaneswar.in';
    }
  }

  // Telemetry variables (boot state: waiting/unacquired)
  double _lat = 0.0;
  double _lon = 0.0;
  double _altitude = -1.0;
  double _speed = -1.0;
  int _battery = -1;

  // RTMP Streaming variables
  bool _isRtmpStreaming = false;
  bool _isCameraFullscreen = false;
  String _rtmpStatus = 'IDLE';
  final TextEditingController _rtmpController = TextEditingController();

  // Tap-to-focus state
  Offset? _focusDot;
  double _focusDotOpacity = 0.0;
  Timer? _focusDotTimer;

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
    // Fetch cloud models and config on boot
    _fetchCloudModelsAndConfig();
    // Fetch mapping/geofence geometries
    _fetchRiverBufferZone();
    _fetchCustomGeofences();
    _fetchIncidents();
    _startIncidentsFetchLoop();
  }

  Future<void> _fetchCloudModelsAndConfig() async {
    if (_isLoadingModels) return;
    setState(() {
      _isLoadingModels = true;
    });
    _addLog('[Cloud AI] Fetching available models & flight configuration...');

    try {
      // 1. Fetch available models
      final modelsResponse = await http.get(Uri.parse('$_baseUrl/api/model/list')).timeout(const Duration(seconds: 4));
      
      List<String> fetchedModels = ['yolov8n.pt'];
      if (modelsResponse.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(modelsResponse.body);
        if (data.containsKey('models')) {
          final List<dynamic> modelList = data['models'];
          fetchedModels = modelList.map((m) => m['filename'] as String).toList();
        }
      } else {
        _addLog('[Cloud AI WARNING] Failed to list models: Code ${modelsResponse.statusCode}');
      }

      // 2. Fetch current flight config
      final configResponse = await http.get(Uri.parse('$_baseUrl/api/flight/config')).timeout(const Duration(seconds: 4));
      
      bool remoteDetectionEnabled = _isAiDetectionEnabled;
      String remoteActiveModel = _selectedModel;
      
      if (configResponse.statusCode == 200) {
        final Map<String, dynamic> config = jsonDecode(configResponse.body);
        remoteDetectionEnabled = config['detection_enabled'] ?? false;
        remoteActiveModel = config['active_model'] ?? 'yolov8n.pt';
        _addLog('[Cloud AI] Sync complete. Active Model: $remoteActiveModel | Detection: $remoteDetectionEnabled');
      } else {
        _addLog('[Cloud AI WARNING] Failed to get config: Code ${configResponse.statusCode}');
      }

      setState(() {
        _availableModels = fetchedModels;
        _isAiDetectionEnabled = remoteDetectionEnabled;
        if (_availableModels.contains(remoteActiveModel)) {
          _selectedModel = remoteActiveModel;
        } else if (_availableModels.isNotEmpty) {
          _selectedModel = _availableModels.first;
        }
      });
    } catch (e) {
      _addLog('[Cloud AI ERROR] Sync failed: Connection timed out');
    } finally {
      setState(() {
        _isLoadingModels = false;
      });
    }
  }

  Future<void> _updateCloudFlightConfig({bool? detectionEnabled, String? activeModel}) async {
    final targetDetection = detectionEnabled ?? _isAiDetectionEnabled;
    final targetModel = activeModel ?? _selectedModel;

    _addLog('[Cloud AI] Updating config: detection=$targetDetection, model=$targetModel...');

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/flight/config'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'detection_enabled': targetDetection,
          'active_model': targetModel,
        }),
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        setState(() {
          _isAiDetectionEnabled = targetDetection;
          _selectedModel = targetModel;
          if (!targetDetection) {
            _detections.clear();
          }
        });
        _addLog('[Cloud AI] Config successfully updated and synced.');
      } else {
        _addLog('[Cloud AI ERROR] Update failed: Code ${response.statusCode}');
      }
    } catch (e) {
      _addLog('[Cloud AI ERROR] Update failed: Connection timed out');
    }
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
          _addLog('[SDK] Flight SDK registration status: SUCCESS');
        } else {
          _addLog('[SDK ERROR] Flight SDK registration status: FAILED (${data['error']})');
        }
        break;
      case 'onDJIConnectionUpdate':
        final bool connected = call.arguments as bool;
        setState(() {
          _isDJIConnected = connected;
          if (!connected) {
            _lat = 0.0;
            _lon = 0.0;
            _altitude = -1.0;
            _speed = -1.0;
            _battery = -1;
          }
        });
        _addLog('[AIRCRAFT] Drone connection state updated: ${connected ? "CONNECTED" : "DISCONNECTED"}');
        break;
      case 'onTelemetryUpdate':
        final Map data = call.arguments as Map;
        setState(() {
          _lat = data['lat'] as double;
          _lon = data['lon'] as double;
          _altitude = data['altitude'] as double;
          // Native speed is in m/s, convert to km/h for pilot HUD display
          _speed = (data['speed'] as double) * 3.6;
          
          _checkGeofenceViolation();
          if (_autoFollowDrone && _lat != 0.0 && _lon != 0.0) {
            try {
              _mapController.move(LatLng(_lat, _lon), _mapController.camera.zoom);
            } catch (_) {}
          }
        });
        break;
      case 'onBatteryUpdate':
        final int batPercent = call.arguments as int;
        setState(() {
          _battery = batPercent;
        });
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
    _focusDotTimer?.cancel();
    _incidentsFetchTimer?.cancel();
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
      if (_isBroadcasting) {
        _sendTelemetryToServer();
      }
    });
  }

  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    bool inside = false;
    final double x = point.longitude;
    final double y = point.latitude;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      final double xi = polygon[i].longitude;
      final double yi = polygon[i].latitude;
      final double xj = polygon[j].longitude;
      final double yj = polygon[j].latitude;
      
      final bool intersect = ((yi > y) != (yj > y)) &&
          (x < (xj - xi) * (y - yi) / (yj - yi) + xi);
      if (intersect) inside = !inside;
      j = i;
    }
    return inside;
  }

  void _checkGeofenceViolation() {
    if (_lat == 0.0 && _lon == 0.0) {
      if (_isInsideIllegalZone) {
        setState(() {
          _isInsideIllegalZone = false;
        });
      }
      return;
    }
    
    final currentPoint = LatLng(_lat, _lon);
    
    // Check legal river buffer zones
    for (final poly in _riverBufferPolygons) {
      if (_isPointInPolygon(currentPoint, poly)) {
        if (!_isInsideIllegalZone) {
          setState(() {
            _isInsideIllegalZone = true;
          });
        }
        return;
      }
    }
    
    // Check custom geofences
    for (final poly in _customGeofencePolygons) {
      if (_isPointInPolygon(currentPoint, poly)) {
        if (!_isInsideIllegalZone) {
          setState(() {
            _isInsideIllegalZone = true;
          });
        }
        return;
      }
    }
    
    if (_isInsideIllegalZone) {
      setState(() {
        _isInsideIllegalZone = false;
      });
    }
  }

  List<List<LatLng>> _parseGeoJsonPolygons(Map<String, dynamic> geojson) {
    List<List<LatLng>> polygons = [];
    final features = geojson['features'];
    if (features is List) {
      for (final feature in features) {
        final geometry = feature['geometry'];
        if (geometry is Map) {
          final type = geometry['type'];
          final coordinates = geometry['coordinates'];
          if (type == 'Polygon' && coordinates is List) {
            for (final ring in coordinates) {
              if (ring is List) {
                List<LatLng> points = [];
                for (final coord in ring) {
                  if (coord is List && coord.length >= 2) {
                    final lon = (coord[0] as num).toDouble();
                    final lat = (coord[1] as num).toDouble();
                    points.add(LatLng(lat, lon));
                  }
                }
                if (points.isNotEmpty) {
                  polygons.add(points);
                }
              }
            }
          } else if (type == 'MultiPolygon' && coordinates is List) {
            for (final polygon in coordinates) {
              if (polygon is List) {
                for (final ring in polygon) {
                  if (ring is List) {
                    List<LatLng> points = [];
                    for (final coord in ring) {
                      if (coord is List && coord.length >= 2) {
                        final lon = (coord[0] as num).toDouble();
                        final lat = (coord[1] as num).toDouble();
                        points.add(LatLng(lat, lon));
                      }
                    }
                    if (points.isNotEmpty) {
                      polygons.add(points);
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    return polygons;
  }

  Future<void> _fetchRiverBufferZone() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/data/legal_zones/river_buffer_1km.geojson'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final polys = _parseGeoJsonPolygons(data);
        setState(() {
          _riverBufferPolygons = polys;
        });
        _addLog('[MAP] River buffer zone loaded: ${polys.length} polygons.');
      } else {
        _addLog('[MAP WARNING] River buffer not found on server (using centerline only).');
      }
    } catch (e) {
      _addLog('[MAP ERROR] Connection error fetching river buffer: $e');
    }
  }

  Future<void> _fetchCustomGeofences() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/api/zone/geofence'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final polys = _parseGeoJsonPolygons(data);
        setState(() {
          _customGeofencePolygons = polys;
        });
        _addLog('[MAP] Custom geofences loaded: ${polys.length} polygons.');
        _checkGeofenceViolation();
      } else {
        _addLog('[MAP ERROR] Failed to fetch custom geofences: Status ${response.statusCode}');
      }
    } catch (e) {
      _addLog('[MAP ERROR] Connection error fetching custom geofences: $e');
    }
  }

  void _startIncidentsFetchLoop() {
    _incidentsFetchTimer?.cancel();
    _incidentsFetchTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _fetchIncidents();
    });
  }

  Future<void> _fetchIncidents() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/api/incidents')).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        final List<ViolationPoint> fetchedPoints = [];
        for (var item in data) {
          final lat = (item['centroid_latitude'] as num?)?.toDouble();
          final lon = (item['centroid_longitude'] as num?)?.toDouble();
          if (lat != null && lon != null && lat != 0.0 && lon != 0.0) {
            fetchedPoints.add(ViolationPoint(
              id: item['id']?.toString() ?? '',
              coordinate: LatLng(lat, lon),
              timestamp: item['timestamp']?.toString() ?? '',
              source: 'server',
              severity: item['severity']?.toString() ?? 'MEDIUM',
              illegalZone: item['illegal_zone'] as bool? ?? false,
            ));
          }
        }
        setState(() {
          _violationPoints.removeWhere((p) => p.source == 'server');
          _violationPoints.addAll(fetchedPoints);
        });
      }
    } catch (e) {
      _addLog('[MAP ERROR] Connection error fetching incidents: $e');
    }
  }

  void _showViolationDetails(ViolationPoint vp) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext context) {
        final isViolation = vp.illegalZone;
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Incident #${vp.id}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF38BDF8),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: vp.severity == 'EXTREME' || vp.severity == 'SEVERE' || vp.severity == 'CRITICAL'
                          ? const Color(0xFFEF4444).withValues(alpha: 0.2)
                          : const Color(0xFFF59E0B).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: vp.severity == 'EXTREME' || vp.severity == 'SEVERE' || vp.severity == 'CRITICAL'
                            ? const Color(0xFFEF4444)
                            : const Color(0xFFF59E0B),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      vp.severity,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: vp.severity == 'EXTREME' || vp.severity == 'SEVERE' || vp.severity == 'CRITICAL'
                            ? const Color(0xFFEF4444)
                            : const Color(0xFFF59E0B),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Coordinates: ${vp.coordinate.latitude.toStringAsFixed(6)}, ${vp.coordinate.longitude.toStringAsFixed(6)}',
                style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 6),
              Text(
                'Time: ${vp.timestamp}',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Text('Status: ', style: TextStyle(fontSize: 13, color: Colors.grey)),
                  Text(
                    isViolation ? 'Geofence Violation' : 'Safe/OK',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isViolation ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(context);
                    final url = 'https://www.google.com/maps/dir/?api=1&destination=${vp.coordinate.latitude},${vp.coordinate.longitude}';
                    try {
                      if (await canLaunchUrl(Uri.parse(url))) {
                        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                      } else {
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          const SnackBar(content: Text('Could not open map navigation.')),
                        );
                      }
                    } catch (e) {
                      _addLog('[NAV ERROR] Failed to launch navigation: $e');
                    }
                  },
                  icon: const Icon(Icons.directions, color: Colors.white),
                  label: const Text('Get Directions', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _saveCustomGeofence() async {
    if (_drawnPoints.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please draw a polygon with at least 3 points!'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }

    // Build the geojson structure
    List<List<double>> coordinates = [];
    for (final pt in _drawnPoints) {
      coordinates.add([pt.longitude, pt.latitude]);
    }
    // Close polygon
    coordinates.add([_drawnPoints.first.longitude, _drawnPoints.first.latitude]);

    final geojson = {
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature",
          "properties": {},
          "geometry": {
            "type": "Polygon",
            "coordinates": [coordinates]
          }
        }
      ]
    };

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/zone/geofence'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({"geojson": geojson}),
      );

      if (response.statusCode == 200) {
        _addLog('[MAP] Custom geofences synced to server.');
        setState(() {
          _isDrawingMode = false;
          _drawnPoints.clear();
        });
        await _fetchCustomGeofences();
      } else {
        _addLog('[MAP ERROR] Failed to save geofence: Status ${response.statusCode}');
      }
    } catch (e) {
      _addLog('[MAP ERROR] Connection error saving geofence: $e');
    }
  }

  Future<void> _deleteCustomGeofence() async {
    final emptyGeojson = {
      "type": "FeatureCollection",
      "features": []
    };

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/zone/geofence'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({"geojson": emptyGeojson}),
      );

      if (response.statusCode == 200) {
        _addLog('[MAP] Custom geofences cleared on server.');
        setState(() {
          _drawnPoints.clear();
          _customGeofencePolygons.clear();
        });
        _checkGeofenceViolation();
      } else {
        _addLog('[MAP ERROR] Failed to clear geofence: Status ${response.statusCode}');
      }
    } catch (e) {
      _addLog('[MAP ERROR] Connection error clearing geofence: $e');
    }
  }

  Future<void> _sendTelemetryToServer() async {
    // Always broadcast whatever data we have — do NOT block on GPS or battery.
    // The dashboard will show 0,0 coordinates while GPS is acquiring, and 0%
    // battery while the DJI battery key hasn't fired yet. Once real values
    // arrive the next tick will send them automatically.
    final bool gpsAcquiring = _lat == 0.0 && _lon == 0.0;
    final bool batteryUnknown = _battery == -1;

    if (gpsAcquiring) {
      _addLog('Sync: GPS acquiring — broadcasting placeholder coordinates...');
    }
    if (batteryUnknown) {
      _addLog('Sync: Battery data pending — broadcasting 0%...');
    }

    final payload = {
      'lat': _lat,
      'lon': _lon,
      'altitude': _altitude < 0 ? 0.0 : _altitude,
      'speed': _speed < 0 ? 0.0 : _speed / 3.6, // Server expects m/s, HUD converts back to km/h
      'battery': batteryUnknown ? 0 : _battery,
    };

    try {
      final response = await http.post(
        Uri.parse(_serverUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        final locStr = gpsAcquiring ? 'GPS acquiring...' : '${_lat.toStringAsFixed(5)}, ${_lon.toStringAsFixed(5)}';
        final batStr = batteryUnknown ? 'Bat: pending' : 'Bat: $_battery%';
        _addLog('Synced: $locStr | $batStr (Success)');

        if (_isAiDetectionEnabled) {
          try {
            final Map<String, dynamic> data = jsonDecode(response.body);
            if (data.containsKey('detections')) {
              setState(() {
                _detections = List<Map<String, dynamic>>.from(data['detections']);
                _frameWidth = data['frame_width'] ?? 1280;
                _frameHeight = data['frame_height'] ?? 720;

                // Add new local violation point if we are inside illegal zone and have active detections
                if (_isInsideIllegalZone && _detections.isNotEmpty && _lat != 0.0 && _lon != 0.0) {
                  final newPt = LatLng(_lat, _lon);
                  bool isTooClose = false;
                  for (final vp in _violationPoints) {
                    final dist = const Distance().distance(vp.coordinate, newPt);
                    if (dist < 15.0) {
                      isTooClose = true;
                      break;
                    }
                  }
                  if (!isTooClose) {
                    _violationPoints.add(ViolationPoint(
                      id: 'L-${DateTime.now().millisecondsSinceEpoch}',
                      coordinate: newPt,
                      timestamp: DateTime.now().toLocal().toString().split('.').first,
                      source: 'local',
                      severity: 'CRITICAL',
                      illegalZone: true,
                    ));
                  }
                }
              });
            }
          } catch (_) {
            // Ignore format exceptions
          }
        } else {
          setState(() {
            _detections.clear();
          });
        }
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
    return const Color(0xFFF59E0B); // Amber Orange: Waiting for Physical Drone Accessory
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor();

    return Scaffold(
      appBar: _isCameraFullscreen ? null : AppBar(
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
                    color: statusColor.withValues(alpha: 0.5),
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
                if (!_isDJIConnected) {
                  _lat = 0.0;
                  _lon = 0.0;
                  _battery = -1;
                  _altitude = -1.0;
                  _speed = -1.0;
                }
                _addLog('HUD reset to unacquired state (waiting for drone connection).');
              });
            },
          ),
        ],
      ),
      body: _isCameraFullscreen
          ? _buildRawFeedMonitor()
          : IndexedStack(
              index: _currentTab,
              children: [
                SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    children: [
                      if (_isInsideIllegalZone)
                        Container(
                          margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFEF4444), width: 2),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 24),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'GEOFENCE VIOLATION WARNING',
                                      style: TextStyle(
                                        color: Color(0xFFEF4444),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                        letterSpacing: 1.1,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      'AIRCRAFT IS INSIDE AN ENFORCED RESTRICTED ZONE',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
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
                    title: const Text('Cloud Telemetry Sync', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                    subtitle: const Text('Broadcast live coordinates and battery to the dashboard', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    value: _isBroadcasting,
                    onChanged: (val) {
                      setState(() {
                        _isBroadcasting = val;
                        if (!val) {
                          _detections.clear();
                        }
                      });
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
                        SwitchListTile(
                          title: const Text(
                            'Cloud AI Detection',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          subtitle: const Text(
                            'Enable server-side YOLO surveillance on the live video feed',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                          value: _isAiDetectionEnabled,
                          onChanged: (val) {
                            _updateCloudFlightConfig(detectionEnabled: val);
                          },
                          activeThumbColor: const Color(0xFFA855F7), // Purple/indigo for AI
                          contentPadding: EdgeInsets.zero,
                        ),
                        if (_isAiDetectionEnabled) ...[
                          const Divider(color: Color(0xFF334155), height: 16),
                          Row(
                            children: [
                              const Icon(Icons.psychology, color: Color(0xFFA855F7), size: 18),
                              const SizedBox(width: 8),
                              const Text(
                                'Active YOLO Model:',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Container(
                                  height: 38,
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0F172A),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: const Color(0xFF334155)),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: _availableModels.contains(_selectedModel)
                                          ? _selectedModel
                                          : (_availableModels.isNotEmpty ? _availableModels.first : 'yolov8n.pt'),
                                      dropdownColor: const Color(0xFF0F172A),
                                      style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
                                      icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                                      isExpanded: true,
                                      onChanged: (String? newVal) {
                                        if (newVal != null) {
                                          _updateCloudFlightConfig(activeModel: newVal);
                                        }
                                      },
                                      items: _availableModels.map<DropdownMenuItem<String>>((String value) {
                                        return DropdownMenuItem<String>(
                                          value: value,
                                          child: Text(value),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _isLoadingModels
                                  ? const SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: Padding(
                                        padding: EdgeInsets.all(6.0),
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFA855F7)),
                                      ),
                                    )
                                  : IconButton(
                                      icon: const Icon(Icons.sync_sharp, color: Color(0xFFA855F7), size: 20),
                                      onPressed: _fetchCloudModelsAndConfig,
                                      tooltip: 'Sync Models & Config',
                                    ),
                            ],
                          ),
                        ],
                      ],
                    ),
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
                                    ? const Color(0xFF10B981).withValues(alpha: 0.15) 
                                    : Colors.grey.withValues(alpha: 0.15),
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
                          'Configure target RTMP publishing URL to stream the aircraft camera feed live.',
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
                  _battery == -1 ? 'WAITING FOR AIRCRAFT...' : '$_battery%',
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
            height: 240,
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
                                color: const Color(0xFF38BDF8).withValues(alpha: 0.8),
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
      _buildMapView(),
      ],
    ),
      bottomNavigationBar: _isCameraFullscreen
          ? null
          : BottomNavigationBar(
              currentIndex: _currentTab,
              onTap: (index) {
                setState(() {
                  _currentTab = index;
                });
              },
              backgroundColor: const Color(0xFF0F172A),
              selectedItemColor: const Color(0xFF38BDF8),
              unselectedItemColor: Colors.grey,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.dashboard_customize_outlined),
                  activeIcon: Icon(Icons.dashboard_customize),
                  label: 'HUD Dashboard',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.map_outlined),
                  activeIcon: Icon(Icons.map),
                  label: 'Geofence Map',
                ),
              ],
            ),
    );
  }

  Widget _buildMapView() {
    // Determine target center for the map
    LatLng initialCenter = LatLng(26.12555, 91.81244);
    if (_lat != 0.0 && _lon != 0.0) {
      initialCenter = LatLng(_lat, _lon);
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: initialCenter,
            initialZoom: 13.0,
            onTap: (tapPosition, point) {
              if (_isDrawingMode) {
                setState(() {
                  _drawnPoints.add(point);
                });
              }
            },
          ),
          children: [
            // Tile Layer (Satellite vs Dark Mode)
            TileLayer(
              urlTemplate: _isSatelliteMode
                  ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                  : 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{y}/{x}.png',
              subdomains: const ['a', 'b', 'c', 'd'],
              userAgentPackageName: 'sq.rogue.telemetry_bridge',
            ),
            
            // Polygons for River Buffer
            PolygonLayer(
              polygons: _riverBufferPolygons.map((polyPoints) {
                return Polygon(
                  points: polyPoints,
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  borderColor: const Color(0xFFF59E0B),
                  borderStrokeWidth: 2,
                );
              }).toList(),
            ),

            // Polygons for Custom Geofences
            PolygonLayer(
              polygons: _customGeofencePolygons.map((polyPoints) {
                return Polygon(
                  points: polyPoints,
                  color: const Color(0xFFEF4444).withValues(alpha: 0.2),
                  borderColor: const Color(0xFFEF4444),
                  borderStrokeWidth: 2,
                );
              }).toList(),
            ),

            // Polyline layer for active drawing
            if (_isDrawingMode && _drawnPoints.isNotEmpty) ...[
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _drawnPoints,
                    color: const Color(0xFFA855F7),
                    strokeWidth: 3,
                  ),
                  // Connect last point back to first point if >= 3 points
                  if (_drawnPoints.length >= 3)
                    Polyline(
                      points: [_drawnPoints.last, _drawnPoints.first],
                      color: const Color(0xFFA855F7).withValues(alpha: 0.5),
                      strokeWidth: 2,
                    ),
                ],
              ),
            ],

            // Drone position and active drawing vertex markers
            MarkerLayer(
              markers: [
                // Render drone marker if coordinates are active
                if (_lat != 0.0 && _lon != 0.0)
                  Marker(
                    point: LatLng(_lat, _lon),
                    width: 40,
                    height: 40,
                    child: Transform.rotate(
                      angle: 0.0,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: (_isInsideIllegalZone ? const Color(0xFFEF4444) : const Color(0xFF10B981)).withValues(alpha: 0.2),
                            ),
                          ),
                          Icon(
                            Icons.navigation,
                            color: _isInsideIllegalZone ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                            size: 24,
                          ),

                        ],
                      ),
                    ),
                  ),

                // Render drawing vertex markers
                if (_isDrawingMode)
                  ..._drawnPoints.map((LatLng pt) {
                    final idx = _drawnPoints.indexOf(pt);
                    return Marker(
                      point: pt,
                      width: 16,
                      height: 16,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFA855F7),
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: Center(
                          child: Text(
                            '${idx + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),

                // Render violation point markers
                ..._violationPoints.map((ViolationPoint vp) {
                  return Marker(
                    point: vp.coordinate,
                    width: 30,
                    height: 30,
                    child: GestureDetector(
                      onTap: () => _showViolationDetails(vp),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                              border: Border.all(color: Colors.white, width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFEF4444).withValues(alpha: 0.5),
                                  blurRadius: 6,
                                  spreadRadius: 2,
                                )
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.warning,
                            color: Colors.white,
                            size: 10,
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ],
        ),

        // TOP HUD Status Overlay
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isInsideIllegalZone ? const Color(0xFFEF4444) : const Color(0xFF334155),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 10,
                  spreadRadius: 2,
                )
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isInsideIllegalZone ? 'GEOFENCE VIOLATION' : 'GEOFENCE SAFE',
                        style: TextStyle(
                          color: _isInsideIllegalZone ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                          letterSpacing: 1.1,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        (_lat == 0.0 && _lon == 0.0)
                            ? 'GPS: Unacquired'
                            : 'GPS: ${_lat.toStringAsFixed(5)}, ${_lon.toStringAsFixed(5)}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _isInsideIllegalZone
                        ? const Color(0xFFEF4444).withValues(alpha: 0.2)
                        : const Color(0xFF10B981).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _isInsideIllegalZone ? 'VIOLATION' : 'OK',
                    style: TextStyle(
                      color: _isInsideIllegalZone ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // BOTTOM LEFT: Geofence Drawing / Editing Panel
        Positioned(
          bottom: 16,
          left: 16,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF334155), width: 1),
            ),
            child: Row(
              children: [
                if (!_isDrawingMode) ...[
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFA855F7), // Purple/indigo for edit
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    icon: const Icon(Icons.edit_location_alt, size: 14),
                    label: const Text('Draw Fence', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    onPressed: () {
                      setState(() {
                        _isDrawingMode = true;
                        _drawnPoints.clear();
                      });
                      _addLog('[MAP] Geofence drawing mode enabled. Tap map to add points.');
                    },
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEF4444), // Red for clear
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    icon: const Icon(Icons.delete_forever, size: 14),
                    label: const Text('Clear Server', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: const Color(0xFF1E293B),
                          title: const Text('Clear Custom Geofence?', style: TextStyle(color: Colors.white)),
                          content: const Text(
                            'Are you sure you want to delete all custom geofences from the server?',
                            style: TextStyle(color: Colors.grey),
                          ),
                          actions: [
                            TextButton(
                              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                              onPressed: () => Navigator.of(ctx).pop(),
                            ),
                            TextButton(
                              child: const Text('Delete', style: TextStyle(color: Color(0xFFEF4444))),
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                _deleteCustomGeofence();
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ] else ...[
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981), // Green for save
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    icon: const Icon(Icons.check, size: 14),
                    label: const Text('Save', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    onPressed: _saveCustomGeofence,
                  ),
                  const SizedBox(width: 8),
                  if (_drawnPoints.isNotEmpty) ...[
                    IconButton(
                      icon: const Icon(Icons.undo, color: Colors.amber, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        setState(() {
                          _drawnPoints.removeLast();
                        });
                      },
                      tooltip: 'Undo last point',
                    ),
                    const SizedBox(width: 8),
                  ],
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF64748B), // Slate for cancel
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    icon: const Icon(Icons.close, size: 14),
                    label: const Text('Cancel', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    onPressed: () {
                      setState(() {
                        _isDrawingMode = false;
                        _drawnPoints.clear();
                      });
                      _addLog('[MAP] Geofence drawing cancelled.');
                    },
                  ),
                ],
              ],
            ),
          ),
        ),

        // BOTTOM RIGHT: Map Control Buttons
        Positioned(
          bottom: 16,
          right: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Auto Follow Toggle
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                child: FloatingActionButton.small(
                  heroTag: 'btn_follow',
                  backgroundColor: _autoFollowDrone ? const Color(0xFF38BDF8) : const Color(0xFF0F172A),
                  foregroundColor: _autoFollowDrone ? Colors.white : const Color(0xFF38BDF8),
                  onPressed: () {
                    setState(() {
                      _autoFollowDrone = !_autoFollowDrone;
                    });
                    _addLog('[MAP] Drone auto-follow ${_autoFollowDrone ? "ENABLED" : "DISABLED"}.');
                  },
                  tooltip: 'Toggle Drone Auto-Follow',
                  child: Icon(_autoFollowDrone ? Icons.gps_fixed : Icons.gps_not_fixed),
                ),
              ),
              
              // Recenter on Drone Button
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                child: FloatingActionButton.small(
                  heroTag: 'btn_recenter',
                  backgroundColor: const Color(0xFF0F172A),
                  foregroundColor: const Color(0xFF38BDF8),
                  onPressed: () {
                    if (_lat != 0.0 && _lon != 0.0) {
                      _mapController.move(LatLng(_lat, _lon), _mapController.camera.zoom);
                      _addLog('[MAP] Map camera recentered on drone.');
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Cannot recenter: No active drone GPS coordinates!'),
                          backgroundColor: Color(0xFFEF4444),
                        ),
                      );
                    }
                  },
                  tooltip: 'Recenter on Drone',
                  child: const Icon(Icons.my_location),
                ),
              ),
              
              // Toggle Satellite Mode
              FloatingActionButton.small(
                heroTag: 'btn_style',
                backgroundColor: const Color(0xFF0F172A),
                foregroundColor: const Color(0xFF38BDF8),
                onPressed: () {
                  setState(() {
                    _isSatelliteMode = !_isSatelliteMode;
                  });
                  _addLog('[MAP] Layer style toggled to ${_isSatelliteMode ? "SATELLITE" : "STREETS (DARK)"}.');
                },
                tooltip: 'Toggle Map Style',
                child: Icon(_isSatelliteMode ? Icons.layers : Icons.satellite_alt),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHUDCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
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
                  color: color.withValues(alpha: 0.3),
                  blurRadius: 4,
                )
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _onCameraTap(TapDownDetails details, BoxConstraints constraints) {
    if (!_isDJIConnected) return;
    final double normalizedX = (details.localPosition.dx / constraints.maxWidth).clamp(0.1, 0.9);
    final double normalizedY = (details.localPosition.dy / constraints.maxHeight).clamp(0.1, 0.9);

    setState(() {
      _focusDot = details.localPosition;
      _focusDotOpacity = 1.0;
    });

    // Tell the native layer to focus at this normalized position
    _platform.invokeMethod('tapFocus', {'x': normalizedX, 'y': normalizedY}).then((_) {
      _addLog('[CAMERA] Focus locked at (${normalizedX.toStringAsFixed(2)}, ${normalizedY.toStringAsFixed(2)})');
    }).catchError((e) {
      _addLog('[CAMERA ERROR] Focus request failed: $e');
    });

    // Auto-fade the focus ring after 2 seconds
    _focusDotTimer?.cancel();
    _focusDotTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusDotOpacity = 0.0);
    });
  }

  void _toggleRtmpStreaming() {
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
            content: Text('Please configure a valid stream URL in the RTMP panel first!'),
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
  }

  void _simulateTakeoff() {
    if (!_isDJIConnected) {
      _addLog('[AIRCRAFT ERROR] Takeoff rejected: drone disconnected.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Takeoff rejected: Connect drone!'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }
    
    _addLog('[PILOT] Initiating Auto-Takeoff sequence...');
    double targetAlt = 12.0;
    double current = 0.0;
    Timer.periodic(const Duration(milliseconds: 150), (timer) {
      current += 1.2;
      if (current >= targetAlt) {
        current = targetAlt;
        timer.cancel();
        _addLog('[PILOT] Aircraft hovered safely at ${targetAlt.toStringAsFixed(1)}m.');
      }
      setState(() {
        _altitude = current;
        _speed = timer.isActive ? 4.5 : 0.0;
      });
    });
  }

  void _simulateRTH() {
    if (!_isDJIConnected) {
      _addLog('[AIRCRAFT ERROR] Return-to-Home rejected: drone disconnected.');
      return;
    }
    
    _addLog('[PILOT] Return-to-Home (RTH) sequence triggered.');
    _addLog('[PILOT] Returning back to home point (26.12555, 91.81244)...');
    
    double currentAlt = _altitude > 0 ? _altitude : 12.0;
    Timer.periodic(const Duration(milliseconds: 200), (timer) {
      currentAlt -= 1.5;
      if (currentAlt <= 0.0) {
        currentAlt = 0.0;
        timer.cancel();
        _addLog('[PILOT] RTH complete. Aircraft landed safely and disarmed.');
        setState(() {
          _lat = 26.12555;
          _lon = 91.81244;
          _speed = 0.0;
          _altitude = 0.0;
        });
      } else {
        setState(() {
          _altitude = currentAlt;
          _speed = 10.0;
        });
      }
    });
  }

  Widget _buildRawFeedMonitor() {
    final double currentLat = _lat;
    final double currentAlt = _altitude;
    final double currentSpeed = _speed;
    final int currentBat = _battery;

    final double horizonOffset = _isRtmpStreaming ? 5.0 * math.sin(DateTime.now().millisecond / 100.0) : 0.0;
    final double rollAngle = _isRtmpStreaming ? 0.03 * math.cos(DateTime.now().millisecond / 200.0) : 0.0;

    final bool isStreamActive = _isRtmpStreaming;

    return Container(
      margin: _isCameraFullscreen ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      height: _isCameraFullscreen ? double.infinity : 200,
      width: _isCameraFullscreen ? double.infinity : null,
      decoration: BoxDecoration(
        color: const Color(0xFF030712),
        borderRadius: _isCameraFullscreen ? BorderRadius.zero : BorderRadius.circular(12),
        border: _isCameraFullscreen
            ? null
            : Border.all(
                color: _isRtmpStreaming ? const Color(0xFF10B981) : const Color(0xFF334155),
                width: 1.5,
              ),
        boxShadow: (!_isCameraFullscreen && _isRtmpStreaming) ? [
          BoxShadow(
            color: const Color(0xFF10B981).withValues(alpha: 0.15),
            blurRadius: 10,
            spreadRadius: 2,
          )
        ] : [],
      ),
      child: ClipRRect(
        borderRadius: _isCameraFullscreen ? BorderRadius.zero : BorderRadius.circular(10),
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _onCameraTap(details, constraints),
            child: Stack(
              children: [
                // Dark Background Layer
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.1,
                    child: Container(
                      color: const Color(0xFF0F172A),
                    ),
                  ),
                ),
                
                // Native Camera View
                if (_isDJIConnected)
                  Positioned.fill(
                    child: defaultTargetPlatform == TargetPlatform.iOS
                        ? const UiKitView(
                            viewType: 'sq.rogue.telemetry_bridge/dji_camera_view',
                            creationParams: <String, dynamic>{},
                            creationParamsCodec: StandardMessageCodec(),
                          )
                        : const AndroidView(
                            viewType: 'sq.rogue.telemetry_bridge/dji_camera_view',
                            creationParams: <String, dynamic>{},
                            creationParamsCodec: StandardMessageCodec(),
                          ),
                  ),
                
                // horizon Custom Grid HUD
                CustomPaint(
                  size: Size.infinite,
                  painter: _HUDGridPainter(
                    horizonOffset: horizonOffset, 
                    rollAngle: rollAngle, 
                    isActive: isStreamActive,
                  ),
                ),

                // Real-time AI bounding box overlay
                if (_isDJIConnected && _isAiDetectionEnabled && _detections.isNotEmpty)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _BoundingBoxPainter(
                          detections: _detections,
                          frameWidth: _frameWidth,
                          frameHeight: _frameHeight,
                          isViolation: _isInsideIllegalZone,
                        ),

                      ),
                    ),
                  ),

                // CRT / Scanline effect
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: List.generate(45, (index) => 
                            index % 2 == 0 ? Colors.transparent : Colors.black.withValues(alpha: 0.12)
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Standby state overlay (if not connected)
                if (!_isDJIConnected)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.videocam_off, 
                          color: Colors.amber.withValues(alpha: 0.6), 
                          size: 32,
                          shadows: [
                            Shadow(color: Colors.amber.withValues(alpha: 0.3), blurRadius: 8)
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'RAW VIDEO FEED STANDBY',
                          style: TextStyle(
                            color: Colors.amber.withValues(alpha: 0.8),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'CONNECT AIRCRAFT TO DEPLOY COCKPIT HUD',
                          style: TextStyle(
                            color: Colors.grey.withValues(alpha: 0.8),
                            fontSize: 8,
                            fontFamily: 'monospace',
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),

                // ── DJI FLY-STYLE PREMIUM HUD OVERLAYS ──
                if (_isDJIConnected) ...[
                  // 1. Sleek Top Status Bar
                  Positioned(
                    top: 6,
                    left: 8,
                    right: 8,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Left: Flight Mode Pill
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 5,
                                height: 5,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF10B981),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                'N MODE',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Center: Flight Status Warning Pill
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: (_lat == 0.0) 
                                ? const Color(0xFFFBBF24).withValues(alpha: 0.85)
                                : Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            !_isDJIConnected
                                ? 'AIRCRAFT DISCONNECTED'
                                : (_lat == 0.0
                                    ? 'ACQUIRING GPS LOCK...'
                                    : 'READY TO FLY (GPS)'),
                            style: TextStyle(
                              color: (_lat == 0.0) ? const Color(0xFF1C1917) : const Color(0xFF10B981),
                              fontSize: 8.5,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),

                        // Right: Satellites, Signal & Battery Indicators
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.satellite_alt, color: Colors.white.withValues(alpha: 0.9), size: 11),
                            const SizedBox(width: 2),
                            Text(
                              (_lat == 0.0) ? '0' : '18',
                              style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.wifi, color: Colors.white.withValues(alpha: 0.9), size: 11),
                            const SizedBox(width: 8),
                            Icon(
                              currentBat <= 20 && currentBat != -1 ? Icons.battery_alert : Icons.battery_std, 
                              color: currentBat <= 20 && currentBat != -1 ? const Color(0xFFEF4444) : const Color(0xFF10B981), 
                              size: 12
                            ),
                            const SizedBox(width: 1),
                            Text(
                              '${currentBat == -1 ? 100 : currentBat}%',
                              style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 2. Left Column Action Buttons: Takeoff & Return to Home (RTH)
                  Positioned(
                    left: 8,
                    top: 45,
                    bottom: 30,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Auto Takeoff/Hover
                        GestureDetector(
                          onTap: _simulateTakeoff,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1),
                            ),
                            child: const Center(
                              child: Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 15),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Return to Home
                        GestureDetector(
                          onTap: _simulateRTH,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1),
                            ),
                            child: const Center(
                              child: Icon(Icons.keyboard_return_rounded, color: Colors.amber, size: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 3. Right Side DJI-Style Shutter/Record Button (Toggles RTMP stream!) and Fullscreen Toggle
                  Positioned(
                    right: 12,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: _toggleRtmpStreaming,
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              padding: const EdgeInsets.all(3.0),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 250),
                                decoration: BoxDecoration(
                                  color: _isRtmpStreaming ? const Color(0xFFEF4444) : Colors.white,
                                  shape: _isRtmpStreaming ? BoxShape.rectangle : BoxShape.circle,
                                  borderRadius: _isRtmpStreaming ? BorderRadius.circular(4) : null,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          // Fullscreen Toggle Button
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _isCameraFullscreen = !_isCameraFullscreen;
                                if (_isCameraFullscreen) {
                                  SystemChrome.setPreferredOrientations([
                                    DeviceOrientation.landscapeLeft,
                                  ]);
                                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
                                } else {
                                  SystemChrome.setPreferredOrientations([
                                    DeviceOrientation.portraitUp,
                                  ]);
                                  SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
                                }
                              });
                            },
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Icon(
                                  _isCameraFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                                  color: Colors.white,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 4. Bottom-Left & Bottom-Right Cockpit Telemetry Overlays
                  Positioned(
                    bottom: 6,
                    left: 8,
                    right: 8,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // Flight Distance & Height Group
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'D  ${(currentLat == 0.0) ? "0.0" : "12.4"} M',
                                style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.w900, fontFamily: 'monospace'),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'H  ${currentAlt == -1.0 ? "0.0" : currentAlt.toStringAsFixed(1)} M',
                                style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.w900, fontFamily: 'monospace'),
                              ),
                            ],
                          ),
                        ),

                        // Flight Speed Indicators (Horizontal Speed & Vertical Speed in m/s)
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'HS  ${currentSpeed == -1.0 ? "0.0" : (currentSpeed / 3.6).toStringAsFixed(1)} M/S',
                                style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.w900, fontFamily: 'monospace'),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'VS  ${currentSpeed > 0 ? "1.2" : "0.0"} M/S',
                                style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.w900, fontFamily: 'monospace'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // ── GPS No-Signal Banner (top-right corner, only when physical drone connected but no coordinates) ──
                if (_isDJIConnected && _lat == 0.0)
                  Positioned(
                    top: 36,
                    right: 8,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 500),
                      opacity: 1.0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFBBF24).withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFFBBF24).withValues(alpha: 0.4),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.satellite_alt, size: 10, color: Color(0xFF1C1917)),
                            SizedBox(width: 4),
                            Text(
                              'NO GPS SIGNAL',
                              style: TextStyle(
                                color: Color(0xFF1C1917),
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // ── Tap-to-Focus animated ring ──
                if (_focusDot != null)
                  Positioned(
                    left: _focusDot!.dx - 28,
                    top: _focusDot!.dy - 28,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 400),
                      opacity: _focusDotOpacity,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0xFFFBBF24),
                            width: 2.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFFBBF24).withValues(alpha: 0.3),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned(top: 0, left: 0, child: Container(width: 8, height: 2, color: const Color(0xFFFBBF24))),
                            Positioned(top: 0, left: 0, child: Container(width: 2, height: 8, color: const Color(0xFFFBBF24))),
                            Positioned(top: 0, right: 0, child: Container(width: 8, height: 2, color: const Color(0xFFFBBF24))),
                            Positioned(top: 0, right: 0, child: Container(width: 2, height: 8, color: const Color(0xFFFBBF24))),
                            Positioned(bottom: 0, left: 0, child: Container(width: 8, height: 2, color: const Color(0xFFFBBF24))),
                            Positioned(bottom: 0, left: 0, child: Container(width: 2, height: 8, color: const Color(0xFFFBBF24))),
                            Positioned(bottom: 0, right: 0, child: Container(width: 8, height: 2, color: const Color(0xFFFBBF24))),
                            Positioned(bottom: 0, right: 0, child: Container(width: 2, height: 8, color: const Color(0xFFFBBF24))),
                            Container(width: 4, height: 4, decoration: const BoxDecoration(color: Color(0xFFFBBF24), shape: BoxShape.circle)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],      // end Stack children
            ),        // Stack
          ),          // GestureDetector
        ),            // LayoutBuilder builder
      ),              // ClipRRect
    );
  }
} // end of _DashboardPageState


class _HUDGridPainter extends CustomPainter {
  final double horizonOffset;
  final double rollAngle;
  final bool isActive;

  _HUDGridPainter({required this.horizonOffset, required this.rollAngle, required this.isActive});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isActive ? const Color(0xFF38BDF8).withValues(alpha: 0.15) : const Color(0xFF334155).withValues(alpha: 0.1)
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
        ..color = const Color(0xFF10B981).withValues(alpha: 0.4)
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

class _BoundingBoxPainter extends CustomPainter {
  final List<Map<String, dynamic>> detections;
  final int frameWidth;
  final int frameHeight;
  final bool isViolation;

  _BoundingBoxPainter({
    required this.detections,
    required this.frameWidth,
    required this.frameHeight,
    required this.isViolation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width == 0 || size.height == 0 || frameWidth == 0 || frameHeight == 0) return;

    final double scaleX = size.width / frameWidth;
    final double scaleY = size.height / frameHeight;

    final paintBox = Paint()
      ..color = isViolation ? const Color(0xFFEF4444) : const Color(0xFF10B981) // Red if violation, Green if safe/OK
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    for (final det in detections) {
      final double xMin = (det['bbox_x_min'] as num).toDouble() * scaleX;
      final double yMin = (det['bbox_y_min'] as num).toDouble() * scaleY;
      final double xMax = (det['bbox_x_max'] as num).toDouble() * scaleX;
      final double yMax = (det['bbox_y_max'] as num).toDouble() * scaleY;

      final rect = Rect.fromLTRB(xMin, yMin, xMax, yMax);
      canvas.drawRect(rect, paintBox);

      final String label = '${det['class_name']} ${((det['confidence'] as num) * 100).toStringAsFixed(0)}%';

      textPainter.text = TextSpan(
        text: ' $label ',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          backgroundColor: isViolation ? const Color(0xFFEF4444) : const Color(0xFF10B981),
        ),
      );
      textPainter.layout();
      
      // Paint text slightly above the box, or inside at the top if at the edge of the screen
      final double textY = yMin - 12 > 0 ? yMin - 12 : yMin;
      textPainter.paint(canvas, Offset(xMin, textY));
    }
  }

  @override
  bool shouldRepaint(covariant _BoundingBoxPainter oldDelegate) {
    return oldDelegate.detections != detections ||
           oldDelegate.frameWidth != frameWidth ||
           oldDelegate.frameHeight != frameHeight ||
           oldDelegate.isViolation != isViolation;
  }
}

class ViolationPoint {
  final String id;
  final LatLng coordinate;
  final String timestamp;
  final String source; // 'local' or 'server'
  final String severity;
  final bool illegalZone;

  ViolationPoint({
    required this.id,
    required this.coordinate,
    required this.timestamp,
    required this.source,
    required this.severity,
    required this.illegalZone,
  });
}

