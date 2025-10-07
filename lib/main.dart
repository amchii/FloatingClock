import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pages/about_page.dart';

// Preset/source identifiers and defaults
const String _presetNtpAliyun = 'ntp.aliyun.com';
const String _presetNtpTencent = 'ntp.tencent.com';
const String _presetHttpMeituan =
    'https://cube.meituan.com/ipromotion/cube/toc/component/base/getServerCurrentTime';

const Map<String, String> _presetAliases = {
  _presetNtpAliyun: '阿里云',
  _presetNtpTencent: '腾讯',
  _presetHttpMeituan: '美团',
};

const Map<String, String> _meituanDefaultHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36'
};
const String _timeSourcesKey = 'time_sources_json';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '悬浮时间',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _channel = MethodChannel('floating_clock');

  Timer? _uiTimer;
  Timer? _syncTimer;

  final List<TimeSource> _sources = [];
  int _selectedIndex = 0;
  // Tracks preset hosts that the user chose to hide/delete. Preset restore
  // will clear entries from this set.
  Set<String> _hiddenPresets = <String>{};
  bool _overlayRunning = false;

  @override
  void initState() {
    super.initState();
    _sources.add(TimeSource.system());

    // Load persisted NTP servers and hidden preset list; then ensure presets
    // are present unless the user explicitly hid them.
    _loadSavedServers().then((_) {
      final presets = <TimeSource>[
        TimeSource.ntp(_presetNtpAliyun, alias: _presetAliases[_presetNtpAliyun] ?? ''),
        TimeSource.ntp(_presetNtpTencent, alias: _presetAliases[_presetNtpTencent] ?? ''),
        TimeSource.http(_presetHttpMeituan,
            alias: _presetAliases[_presetHttpMeituan] ?? '', headers: _meituanDefaultHeaders),
      ];

      for (final preset in presets) {
        if (_hiddenPresets.contains(preset.host)) continue;
        final exists = _sources.any((s) => s.host == preset.host && s.type == preset.type);
        if (!exists) {
          setState(() => _sources.add(preset));

          // Try an immediate initial sync for the restored preset.
          if (preset.type == TimeSourceType.ntp) {
            _queryNtpOffset(preset.host).then((off) {
              if (off != null) {
                if (!mounted) return;
                setState(() {
                  final s = _sources.firstWhere((x) => x.host == preset.host,
                      orElse: () => _sources.last);
                  s.offsetMillis = off;
                  s.lastSync = DateTime.now();
                });
              }
            });
          } else if (preset.type == TimeSourceType.http) {
            _queryHttpOffset(preset).then((off) {
              if (off != null) {
                if (!mounted) return;
                setState(() {
                  final s = _sources.firstWhere((x) => x.host == preset.host,
                      orElse: () => _sources.last);
                  s.offsetMillis = off;
                  s.lastSync = DateTime.now();
                });
              }
            });
          }
        }
      }

      _uiTimer = Timer.periodic(
          const Duration(milliseconds: 10), (_) => setState(() {}));
      _syncAllServers();
      _syncTimer =
          Timer.periodic(const Duration(seconds: 60), (_) => _syncAllServers());
    });
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _syncTimer?.cancel();
    super.dispose();
  }

  Future<void> _syncAllServers() async {
    for (var i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      if (s.isSystem) continue;

      int? off;
      if (s.type == TimeSourceType.ntp) {
        off = await _queryNtpOffset(s.host);
      } else if (s.type == TimeSourceType.http) {
        off = await _queryHttpOffset(s);
      }

      if (off != null) {
        setState(() {
          s.offsetMillis = off!;
          s.lastSync = DateTime.now();
        });
      } else {
        debugPrint(
            '${s.type == TimeSourceType.ntp ? 'NTP' : 'HTTP'}: sync failed for ${s.host}');
      }
    }
  }

  Future<int?> _queryNtpOffset(String host,
      {int port = 123,
      Duration timeout = const Duration(seconds: 2),
      int attempts = 5}) async {
    List<_NtpSample> samples = [];
    for (var i = 0; i < attempts; i++) {
      debugPrint(
          'NTP: $host - attempt ${i + 1}/$attempts (timeout=${timeout.inMilliseconds}ms)');
      final s = await _queryNtpOnce(host, port: port, timeout: timeout);
      if (s != null) {
        samples.add(s);
        // if we got a low-delay sample, prefer it and stop early
        if (s.delay >= 0 && s.delay < 100) {
          debugPrint(
              'NTP: $host - early stop on low-delay sample (${s.delay} ms)');
          break;
        }
      }
      await Future.delayed(const Duration(milliseconds: 80));
    }
    if (samples.isEmpty) {
      debugPrint('NTP: $host - no successful samples after $attempts attempts');
      return null;
    }
    samples.sort((a, b) => a.delay.compareTo(b.delay));
    // Use a small set of the lowest-delay samples and return their median
    // offset to reduce sensitivity to a single lucky/erroneous sample.
    final takeN = samples.length >= 3 ? 3 : samples.length;
    final bestOffsets = samples.take(takeN).map((s) => s.offset).toList()
      ..sort();
    final median = bestOffsets[bestOffsets.length ~/ 2];
    debugPrint(
        'NTP: $host - median offset=$median (used $takeN of ${samples.length} samples, best delay=${samples.first.delay} ms)');
    return median;
  }

  Future<_NtpSample?> _queryNtpOnce(String host,
      {int port = 123, Duration timeout = const Duration(seconds: 2)}) async {
    try {
      // Try IPv4 first, then IPv6, then any. This can help on devices where
      // one address family is preferred or where the lookup behaves differently.
      List<InternetAddress> addrs = [];
      try {
        addrs =
            await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
        if (addrs.isEmpty) {
          addrs = await InternetAddress.lookup(host,
              type: InternetAddressType.IPv6);
        }
        if (addrs.isEmpty) addrs = await InternetAddress.lookup(host);
      } catch (e) {
        debugPrint('NTP: DNS lookup failed for $host: $e');
        return null;
      }
      if (addrs.isEmpty) return null;
      final addr = addrs.firstWhere((a) => a.type == InternetAddressType.IPv4,
          orElse: () => addrs.first);

      // Log the address we're about to query and the local transmit timestamp.
      // `t1ms` is captured immediately before building/sending the packet.

      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final data = Uint8List(48);
      data[0] = 0x1B;

      // Use microsecond precision when creating the transmit timestamp to
      // reduce quantization error on the fractional part.
      final t1us = DateTime.now().microsecondsSinceEpoch;
      final t1Sec = (t1us ~/ 1000000) + 2208988800;
      final t1Frac = ((t1us % 1000000) * 0x100000000) ~/ 1000000;

      final bd =
          ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
      bd.setUint32(40, (t1Sec & 0xffffffff), Endian.big);
      bd.setUint32(44, (t1Frac & 0xffffffff), Endian.big);

      final completer = Completer<_NtpSample?>();

      debugPrint(
          'NTP: sending request to $host -> ${addr.address}:$port t1us=$t1us');
      socket.send(data, addr, port);

      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket.receive();
          if (dg == null) return;
          final r = dg.data;
          if (r.length < 48) return;
          final t4ms = DateTime.now().millisecondsSinceEpoch;
          // `dg.data` (a `Uint8List`) may be a view into a larger buffer,
          // so create a ByteData that starts at the datagram's offset.
          final rb = ByteData.view(r.buffer, r.offsetInBytes, r.lengthInBytes);

          final secT1 = rb.getUint32(24, Endian.big);
          final fracT1 = rb.getUint32(28, Endian.big);
          final secT2 = rb.getUint32(32, Endian.big);
          final fracT2 = rb.getUint32(36, Endian.big);
          final secT3 = rb.getUint32(40, Endian.big);
          final fracT3 = rb.getUint32(44, Endian.big);

          // Basic response validation: mode should be server (4), and stratum
          // should not be 0 (KOD / Kiss-o'-Death). Also ensure the originate
          // timestamp matches what we sent to avoid accepting replayed/other
          // responses from middleboxes.
          final mode = r[0] & 0x7;
          final stratum = rb.getUint8(1);
          if (mode != 4) {
            debugPrint('NTP: $host - unexpected mode=$mode, ignoring response');
            return;
          }
          if (stratum == 0) {
            debugPrint('NTP: $host - stratum=0 (KOD?), ignoring response');
            return;
          }

          if (secT1 != (t1Sec & 0xffffffff) ||
              fracT1 != (t1Frac & 0xffffffff)) {
            debugPrint(
                'NTP: $host - originate timestamp mismatch, ignoring response (got sec=$secT1 frac=$fracT1, expected sec=${t1Sec & 0xffffffff} frac=${t1Frac & 0xffffffff})');
            return;
          }

          int msFromNtp(int sec, int frac) {
            final unixSec = sec - 2208988800;
            final ms = unixSec * 1000 + ((frac * 1000) ~/ 0x100000000);
            return ms;
          }

          final t1 = msFromNtp(secT1, fracT1);
          final t2 = msFromNtp(secT2, fracT2);
          final t3 = msFromNtp(secT3, fracT3);
          final t4 = t4ms;

          final offset = ((t2 - t1) + (t3 - t4)) ~/ 2;
          final delay = ((t4 - t1) - (t3 - t2));
          debugPrint(
              'NTP: $host recv: t1=$t1 t2=$t2 t3=$t3 t4=$t4 offset=$offset delay=$delay');
          if (!completer.isCompleted) {
            completer.complete(_NtpSample(offset: offset, delay: delay));
          }
          socket.close();
        }
      });

      Future.delayed(timeout, () {
        if (!completer.isCompleted) {
          completer.complete(null);
          socket.close();
        }
      });

      return await completer.future;
    } catch (e) {
      debugPrint('NTP: $host error: $e');
      return null;
    }
  }

  // Query an HTTP/JSON endpoint that returns a server timestamp (ms since epoch)
  // in a `data` field. Returns the offset (server_ms - local_ms) or null.
  Future<int?> _queryHttpOffset(TimeSource s,
      {Duration timeout = const Duration(seconds: 2)}) async {
    try {
      final uri = Uri.parse(s.host);
      final client = HttpClient();

      final req = await client.getUrl(uri).timeout(timeout);
      // Apply optional headers (e.g. custom User-Agent for some endpoints)
      if (s.headers != null) {
        s.headers!.forEach((k, v) {
          try {
            req.headers.set(k, v);
          } catch (_) {}
        });
      }

      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) {
        debugPrint('HTTP: ${s.host} status=${resp.statusCode}');
        client.close(force: true);
        return null;
      }
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      client.close();

      final m = jsonDecode(body);
      if (m == null || m is! Map || !m.containsKey('data')) {
        debugPrint('HTTP: ${s.host} unexpected JSON (no data field)');
        return null;
      }
      final dyn = m['data'];
      int serverMs;
      if (dyn is int) {
        serverMs = dyn;
      } else if (dyn is num) {
        serverMs = dyn.toInt();
      } else {
        serverMs = int.tryParse(dyn.toString()) ?? 0;
      }
      if (serverMs == 0) return null;
      final now = DateTime.now().millisecondsSinceEpoch;
      final offset = serverMs - now;
      debugPrint('HTTP: ${s.host} serverMs=$serverMs offset=$offset');
      return offset;
    } catch (e) {
      debugPrint('HTTP: ${s.host} error: $e');
      return null;
    }
  }

  Future<void> _startOverlayForSelected() async {
    try {
      final bool has = await _channel.invokeMethod('hasPermission');
      if (!has) {
        await _channel.invokeMethod('requestPermission');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请在系统设置允许“悬浮窗/在其他应用上层显示”权限后再次点击开始'),
        ));
        return;
      }
      final s = _sources[_selectedIndex];
      final offset = s.isSystem ? 0 : s.offsetMillis;
      final label = s.isSystem ? '' : (s.alias.isNotEmpty ? s.alias : s.host);
      await _channel
          .invokeMethod('startOverlay', {'offset': offset, 'label': label});
      _overlayRunning = true;
    } on PlatformException catch (e) {
      debugPrint('PlatformException: $e');
    }
  }

  Future<void> _stopOverlay() async {
    try {
      await _channel.invokeMethod('stopOverlay');
      _overlayRunning = false;
    } on PlatformException catch (e) {
      debugPrint('PlatformException: $e');
    }
  }

  // Update running overlay to reflect the currently selected source.
  Future<void> _updateOverlayForSelected() async {
    if (!_overlayRunning) return;
    try {
      final s = _sources[_selectedIndex];
      final offset = s.isSystem ? 0 : s.offsetMillis;
      final label = s.isSystem ? '' : (s.alias.isNotEmpty ? s.alias : s.host);
      await _channel
          .invokeMethod('startOverlay', {'offset': offset, 'label': label});
    } on PlatformException catch (e) {
      debugPrint('PlatformException: $e');
    }
  }

  void _addServerDialog() {
    final controllerHost = TextEditingController(text: 'ntp.aliyun.com');
    final controllerAlias = TextEditingController(text: '');
    showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('添加 NTP 服务器'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: controllerHost,
                  decoration: const InputDecoration(
                      hintText: 'ntp.example.com', labelText: '主机')),
              TextField(
                  controller: controllerAlias,
                  decoration:
                      const InputDecoration(hintText: '可选别名', labelText: '别名')),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () async {
                    final host = controllerHost.text.trim();
                    final alias = controllerAlias.text.trim();
                    if (host.isNotEmpty) {
                      // Show a small progress indicator while testing the server.
                      showDialog<void>(
                          context: ctx,
                          barrierDismissible: false,
                          builder: (_) {
                            return AlertDialog(
                                content: Row(children: const [
                              CircularProgressIndicator(),
                              SizedBox(width: 12),
                              Text('正在测试 NTP 服务器...')
                            ]));
                          });

                      // For quick UI tests use a short timeout and few attempts
                      final off = await _queryNtpOffset(host,
                          attempts: 2,
                          timeout: const Duration(milliseconds: 800));

                      // If the state was disposed while awaiting, bail out.
                      if (!mounted) return;

                      // close progress dialog
                      Navigator.of(context, rootNavigator: true).pop();

                      if (off == null) {
                        // Don't add silently if the server failed — inform the user and keep the dialog open.
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('无法从 $host 获取 NTP 时间，请检查主机或网络')));
                        return;
                      }

                      setState(() {
                        _sources.add(TimeSource.ntp(host, alias: alias));
                        _sources.last.offsetMillis = off;
                        _sources.last.lastSync = DateTime.now();
                      });
                      _saveServers();

                      // close the add dialog now that we've confirmed the server works
                      if (!mounted) return;
                      Navigator.of(context).pop();
                    }
                  },
                  child: const Text('添加')),
            ],
          );
        });
  }

  void _editServerDialog(int index) {
    final s = _sources[index];
    final controllerHost = TextEditingController(text: s.host);
    final controllerAlias = TextEditingController(text: s.alias);
    showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('编辑 NTP 服务器'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: controllerHost,
                  decoration: const InputDecoration(
                      hintText: 'ntp.example.com', labelText: '主机')),
              TextField(
                  controller: controllerAlias,
                  decoration:
                      const InputDecoration(hintText: '可选别名', labelText: '别名')),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () async {
                    final host = controllerHost.text.trim();
                    final alias = controllerAlias.text.trim();
                    if (host.isNotEmpty) {
                      // Show progress while testing the edited server
                      showDialog<void>(
                          context: ctx,
                          barrierDismissible: false,
                          builder: (_) {
                            return AlertDialog(
                                content: Row(children: const [
                              CircularProgressIndicator(),
                              SizedBox(width: 12),
                              Text('正在测试 NTP 服务器...')
                            ]));
                          });

                      // For quick UI tests use a short timeout and few attempts
                      final off = await _queryNtpOffset(host,
                          attempts: 2,
                          timeout: const Duration(milliseconds: 800));

                      // If the state was disposed while awaiting, bail out.
                      if (!mounted) return;

                      // close progress dialog
                      Navigator.of(context, rootNavigator: true).pop();

                      if (off == null) {
                        // Keep the edit dialog open and report the failure
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('无法从 $host 获取 NTP 时间，请检查主机或网络')));
                        return;
                      }

                      setState(() {
                        _sources[index] = TimeSource.ntp(host, alias: alias);
                        _sources[index].offsetMillis = off;
                        _sources[index].lastSync = DateTime.now();
                        if (_selectedIndex == index) {
                          _selectedIndex = index; // keep selection
                        }
                      });
                      _saveServers();
                      if (!mounted) return;
                      Navigator.of(context).pop();
                    }
                  },
                  child: const Text('保存')),
            ],
          );
        });
  }

  String _formatTimeForSource(TimeSource s) {
    final now = DateTime.now().add(Duration(milliseconds: s.offsetMillis));
    final centis = (now.millisecond ~/ 10).toString().padLeft(2, '0');
    return '${_twoDigits(now.hour)}:${_twoDigits(now.minute)}:${_twoDigits(now.second)}.$centis';
  }

  String _twoDigits(int n) => n.toString().padLeft(2, '0');

  String _formatOffset(int ms) {
    if (ms.abs() < 1000) return '${ms >= 0 ? '+' : '-'}${ms.abs()} ms';
    final s = ms / 1000.0;
    return '${ms >= 0 ? '+' : '-'}${s.toStringAsFixed(2)} s';
  }

  // Persistence helpers
  Future<void> _loadSavedServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // First try unified format (all sources)
      final rawAll = prefs.getString(_timeSourcesKey);
      if (rawAll != null && rawAll.isNotEmpty) {
        try {
          final list = jsonDecode(rawAll) as List<dynamic>;
          setState(() {
            for (final it in list) {
              final m = it as Map<String, dynamic>;
              final t = (m['type'] ?? 'ntp').toString();
              if (t == 'http' || t == 'TimeSourceType.http') {
                final rawHeaders = m['headers'] ?? {};
                final headers = <String, String>{};
                if (rawHeaders is Map) {
                  rawHeaders.forEach((k, v) {
                    headers[k.toString()] = v.toString();
                  });
                }
                _sources.add(TimeSource.http(m['host'] ?? '',
                    alias: m['alias'] ?? '', headers: headers));
              } else {
                _sources.add(TimeSource.ntp(m['host'] ?? '', alias: m['alias'] ?? ''));
              }
            }
          });
        } catch (_) {
          // fall back to legacy handling below
        }
      } else {
        // legacy format: NTP-only
        final raw = prefs.getString('ntp_servers_json');
        if (raw != null && raw.isNotEmpty) {
          try {
            final list = jsonDecode(raw) as List<dynamic>;
            setState(() {
              for (final it in list) {
                final m = it as Map<String, dynamic>;
                _sources.add(TimeSource.ntp(m['host'] ?? '', alias: m['alias'] ?? ''));
              }
            });
          } catch (_) {}
        }
      }

      // Load hidden preset list (hosts the user explicitly removed).
      final rawHidden = prefs.getString('hidden_presets_json');
      if (rawHidden != null && rawHidden.isNotEmpty) {
        try {
          final arr = jsonDecode(rawHidden) as List<dynamic>;
          _hiddenPresets = arr.map((e) => e.toString()).toSet();
        } catch (_) {
          _hiddenPresets = <String>{};
        }
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> _saveServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Persist all non-system sources (NTP + HTTP) under a unified key.
      final listAll = _sources
          .where((s) => !s.isSystem)
          .map((s) => {
                'host': s.host,
                'alias': s.alias,
                'type': s.type == TimeSourceType.http ? 'http' : 'ntp',
                if (s.headers != null) 'headers': s.headers,
              })
          .toList();
      prefs.setString(_timeSourcesKey, jsonEncode(listAll));

      // Also update legacy NTP-only key for backward compatibility.
      final listNtp = listAll
          .where((m) => (m['type'] ?? 'ntp') == 'ntp')
          .map((m) => {'host': m['host'], 'alias': m['alias']})
          .toList();
      prefs.setString('ntp_servers_json', jsonEncode(listNtp));
    } catch (e) {
      // ignore
    }
  }

  Future<void> _saveHiddenPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      prefs.setString('hidden_presets_json', jsonEncode(_hiddenPresets.toList()));
    } catch (e) {
      // ignore
    }
  }

  bool _isPresetHost(String host) {
    return host == _presetNtpAliyun ||
        host == _presetNtpTencent ||
        host == _presetHttpMeituan;
  }

  void _restorePresetsDialog() {
    final missing = <String>[];
    if (!_sources.any((s) => s.host == _presetNtpAliyun)) missing.add(_presetNtpAliyun);
    if (!_sources.any((s) => s.host == _presetNtpTencent)) missing.add(_presetNtpTencent);
    if (!_sources.any((s) => s.host == _presetHttpMeituan)) missing.add(_presetHttpMeituan);

    if (missing.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有缺失的预设需要恢复')));
      return;
    }

    showDialog<void>(context: context, builder: (ctx) {
      return AlertDialog(
        title: const Text('恢复预设源'),
        content: Text('将恢复以下预设: ${missing.map((h) => _presetAliases[h] ?? h).join(', ')}'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(onPressed: () {
            Navigator.of(ctx).pop();
            _restorePresets();
          }, child: const Text('恢复')),
        ],
      );
    });
  }

  Future<void> _restorePresets() async {
    final toAdd = <TimeSource>[];
    if (!_sources.any((s) => s.host == _presetNtpAliyun)) {
      toAdd.add(TimeSource.ntp(_presetNtpAliyun, alias: _presetAliases[_presetNtpAliyun] ?? ''));
    }
    if (!_sources.any((s) => s.host == _presetNtpTencent)) {
      toAdd.add(TimeSource.ntp(_presetNtpTencent, alias: _presetAliases[_presetNtpTencent] ?? ''));
    }
    if (!_sources.any((s) => s.host == _presetHttpMeituan)) {
      toAdd.add(TimeSource.http(_presetHttpMeituan,
          alias: _presetAliases[_presetHttpMeituan] ?? '', headers: _meituanDefaultHeaders));
    }

    if (toAdd.isEmpty) return;

    setState(() {
      _sources.addAll(toAdd);
    });

    // Clear these hosts from hidden presets (if user previously hid them)
    for (final s in toAdd) {
      _hiddenPresets.remove(s.host);
    }
    await _saveHiddenPresets();

    // Persist NTP additions and run an immediate sync for added presets.
    await _saveServers();
    for (final s in toAdd) {
      if (s.type == TimeSourceType.ntp) {
        final off = await _queryNtpOffset(s.host);
        if (off != null) {
          setState(() {
            final ts = _sources.firstWhere((x) => x.host == s.host);
            ts.offsetMillis = off;
            ts.lastSync = DateTime.now();
          });
        }
      } else if (s.type == TimeSourceType.http) {
        final off = await _queryHttpOffset(s);
        if (off != null) {
          setState(() {
            final ts = _sources.firstWhere((x) => x.host == s.host);
            ts.offsetMillis = off;
            ts.lastSync = DateTime.now();
          });
        }
      }
    }
  }

  // Simple container for a single NTP measurement sample
  // (declared at top-level below)

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('悬浮时间'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'about') {
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const AboutPage()));
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'about', child: Text('关于')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            children: [
              Expanded(
                child: Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('时间源'),
                        trailing:
                            Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: _addServerDialog),
                          IconButton(
                              icon: const Icon(Icons.restore),
                              tooltip: '恢复预设源',
                              onPressed: _restorePresetsDialog),
                        ]),
                      ),
                      Expanded(
                        child: ListView.separated(
                          itemCount: _sources.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final s = _sources[index];
                            return ListTile(
                              leading: Radio<int>(
                                  value: index,
                                  groupValue: _selectedIndex,
                                  onChanged: (v) {
                                    if (v != null) {
                                      setState(() => _selectedIndex = v);
                                      if (_overlayRunning) _updateOverlayForSelected();
                                    }
                                  }),
                              title: Row(children: [
                                Expanded(
                                    child: Text(
                                        s.isSystem
                                            ? 'System'
                                            : (s.alias.isNotEmpty ? s.alias : s.host),
                                        style: const TextStyle(
                                            fontFeatures: [
                                              FontFeature.tabularFigures()
                                            ]))),
                                const SizedBox(width: 8),
                                // Small type badge to distinguish NTP vs HTTP
                                Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                        color: s.type == TimeSourceType.ntp
                                            ? Colors.blue.shade50
                                            : (s.type == TimeSourceType.http
                                                ? Colors.green.shade50
                                                : Colors.grey.shade200),
                                        borderRadius: BorderRadius.circular(6)),
                                    child: Text(
                                        s.type == TimeSourceType.ntp
                                            ? 'NTP'
                                            : (s.type == TimeSourceType.http
                                                ? 'HTTP'
                                                : 'SYS'),
                                        style: const TextStyle(fontSize: 12))),
                              ]),
                              subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_formatTimeForSource(s)),
                                    if (!s.isSystem && s.lastSync != null)
                                      Text('最近同步: ${s.lastSync}',
                                          style: const TextStyle(fontSize: 12)),
                                  ]),
                              trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!s.isSystem)
                                      Padding(
                                          padding:
                                              const EdgeInsets.only(right: 8.0),
                                          child: Text(
                                              _formatOffset(s.offsetMillis),
                                              style: const TextStyle(
                                                  fontSize: 12))),
                                    if (s.type == TimeSourceType.ntp)
                                      IconButton(
                                          icon: const Icon(Icons.edit),
                                          onPressed: () =>
                                              _editServerDialog(index)),
                                    if (!s.isSystem)
                                      IconButton(
                                          icon: const Icon(Icons.delete),
                                          onPressed: () async {
                                            final removed = _sources[index];
                                            final removedHost = removed.host;
                                            setState(() {
                                              if (_selectedIndex == index) {
                                                _selectedIndex = 0;
                                              } else if (_selectedIndex > index) {
                                                _selectedIndex -= 1;
                                              }
                                              _sources.removeAt(index);
                                            });

                                            // Persist the updated server list (now includes HTTP/NTP).
                                            await _saveServers();

                                            // If the removed host is a preset, mark it hidden
                                            // so it won't be re-added on next startup.
                                            if (_isPresetHost(removedHost)) {
                                              _hiddenPresets.add(removedHost);
                                              await _saveHiddenPresets();
                                            }
                                          }),
                                  ]),
                              onTap: () {
                                setState(() => _selectedIndex = index);
                                if (_overlayRunning) _updateOverlayForSelected();
                              },
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ElevatedButton(
                                onPressed: _startOverlayForSelected,
                                child: const Text('开始悬浮')),
                            const SizedBox(width: 12),
                            ElevatedButton(
                                onPressed: _stopOverlay,
                                child: const Text('停止悬浮')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum TimeSourceType { system, ntp, http }

class TimeSource {
  final String host;
  String alias;
  int offsetMillis;
  DateTime? lastSync;
  final TimeSourceType type;
  final bool isSystem;
  final Map<String, String>? headers;

  TimeSource._(this.host,
      {this.alias = '',
      this.offsetMillis = 0,
      this.lastSync,
      this.type = TimeSourceType.ntp,
      this.isSystem = false,
      this.headers});

  factory TimeSource.system() => TimeSource._('',
      alias: 'System',
      offsetMillis: 0,
      isSystem: true,
      type: TimeSourceType.system);
  factory TimeSource.ntp(String host, {String alias = ''}) => TimeSource._(host,
      alias: alias,
      offsetMillis: 0,
      lastSync: null,
      isSystem: false,
      type: TimeSourceType.ntp);
  factory TimeSource.http(String url,
          {String alias = '', Map<String, String>? headers}) =>
      TimeSource._(url,
          alias: alias,
          offsetMillis: 0,
          lastSync: null,
          isSystem: false,
          type: TimeSourceType.http,
          headers: headers);

  Map<String, dynamic> toJson() => {
        'host': host,
        'alias': alias,
        'type': type.toString(),
        'headers': headers
      };

  static TimeSource fromJson(Map<String, dynamic> m) {
    final t = m['type'] ?? 'ntp';
    if (t == 'TimeSourceType.http' || t == 'http') {
      final rawHeaders = m['headers'] ?? {};
      final headers = <String, String>{};
      if (rawHeaders is Map) {
        rawHeaders.forEach((k, v) {
          headers[k.toString()] = v.toString();
        });
      }
      return TimeSource.http(m['host'] ?? '',
          alias: m['alias'] ?? '', headers: headers);
    }
    return TimeSource.ntp(m['host'] ?? '', alias: m['alias'] ?? '');
  }
}

class _NtpSample {
  final int offset;
  final int delay;
  _NtpSample({required this.offset, required this.delay});
}
