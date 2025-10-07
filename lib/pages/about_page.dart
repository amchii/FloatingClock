import 'package:flutter/material.dart';
import 'dart:typed_data';

import 'package:flutter/services.dart' show Clipboard, ClipboardData, MethodChannel;
import 'package:url_launcher/url_launcher.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final String _appName = '悬浮时间';
  String _version = '';
  final String _repoUrl = 'https://github.com/amchii/FloatingClock';
  bool _loading = false;
  Uint8List? _iconBytes;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadIcon();
  }

  Future<void> _loadIcon() async {
    try {
      final channel = MethodChannel('floating_clock');
      final res = await channel.invokeMethod<dynamic>('getAppIcon');
      if (res != null) {
        if (res is Uint8List) {
          setState(() => _iconBytes = res);
        } else if (res is List) {
          setState(() => _iconBytes = Uint8List.fromList(List<int>.from(res)));
        }
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> _loadVersion() async {
    setState(() => _loading = true);
    try {
      final channel = MethodChannel('floating_clock');
      final v = await channel.invokeMethod<String>('getAppVersion');
      if (v != null && v.isNotEmpty) {
        setState(() => _version = v);
      }
    } catch (_) {
      // ignore errors and leave version empty
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _openRepo() async {
    final uri = Uri.parse(_repoUrl);
    try {
      final can = await canLaunchUrl(uri);
      if (!can) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开链接')));
        return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开链接')));
    }
  }

  void _copyRepo() {
    Clipboard.setData(ClipboardData(text: _repoUrl)).then((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('仓库地址已复制到剪贴板')));
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayedVersion = _version.isNotEmpty ? _version : '未知';

    final avatarLabel = _appName.isNotEmpty ? _appName.substring(0, 1) : '时';

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: Center(
        child: Card(
          elevation: 6,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 应用图标：优先从平台读取已安装应用的 launcher 图标，失败时使用首字母回退
                if (_iconBytes != null)
                  ClipOval(
                    child: Image.memory(
                      _iconBytes!,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                    ),
                  )
                else
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: Theme.of(context).primaryColor,
                    child: Text(avatarLabel,
                        style: const TextStyle(fontSize: 28, color: Colors.white)),
                  ),
                const SizedBox(height: 12),
                Text(_appName,
                    style:
                        const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                if (_loading)
                  const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                if (!_loading)
                  Text('版本 $displayedVersion',
                      style: TextStyle(color: Colors.grey[700])),
                const SizedBox(height: 12),
                const Text('一个显示并同步时间的悬浮窗应用。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54)),
                const SizedBox(height: 18),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  ElevatedButton.icon(
                    onPressed: _openRepo,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('打开仓库'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _copyRepo,
                    icon: const Icon(Icons.copy),
                    label: const Text('复制地址'),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
