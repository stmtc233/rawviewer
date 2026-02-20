import 'package:flutter/material.dart';

class ViewerSettings {
  final bool useEmbeddedPreview;
  final bool halfSize;
  final int maxCacheSize; // in MB

  const ViewerSettings({
    this.useEmbeddedPreview = false,
    this.halfSize = true,
    this.maxCacheSize = 512,
  });

  ViewerSettings copyWith({
    bool? useEmbeddedPreview,
    bool? halfSize,
    int? maxCacheSize,
  }) {
    return ViewerSettings(
      useEmbeddedPreview: useEmbeddedPreview ?? this.useEmbeddedPreview,
      halfSize: halfSize ?? this.halfSize,
      maxCacheSize: maxCacheSize ?? this.maxCacheSize,
    );
  }
}

class SettingsPage extends StatefulWidget {
  final ViewerSettings settings;
  final void Function(ViewerSettings?) onClose;

  const SettingsPage(
      {super.key, required this.settings, required this.onClose});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ViewerSettings _currentSettings;

  @override
  void initState() {
    super.initState();
    _currentSettings = widget.settings;
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              widget.onClose(_currentSettings);
            },
          ),
        ),
        body: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                'Preview Mode',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            ExcludeSemantics(
              child: RadioListTile<bool>(
                title: const Text('Embedded JPEG'),
                subtitle: const Text('Fast preview, lower quality'),
                value: true,
                groupValue: _currentSettings.useEmbeddedPreview,
                onChanged: (value) {
                  setState(() {
                    _currentSettings =
                        _currentSettings.copyWith(useEmbeddedPreview: value);
                  });
                },
              ),
            ),
            ExcludeSemantics(
              child: RadioListTile<bool>(
                title: const Text('Load RAW Image'),
                subtitle: const Text('High quality, slower'),
                value: false,
                groupValue: _currentSettings.useEmbeddedPreview,
                onChanged: (value) {
                  setState(() {
                    _currentSettings =
                        _currentSettings.copyWith(useEmbeddedPreview: value);
                  });
                },
              ),
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                'RAW Processing',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            ExcludeSemantics(
              child: SwitchListTile(
                title: const Text('Half Size Decoding'),
                subtitle: const Text(
                    'Faster decoding, 50% resolution. Disable for full resolution.'),
                value: _currentSettings.halfSize,
                onChanged: (value) {
                  setState(() {
                    _currentSettings =
                        _currentSettings.copyWith(halfSize: value);
                  });
                },
              ),
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                'Cache',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              title: const Text('Max Cache Size'),
              subtitle: Text('${_currentSettings.maxCacheSize} MB'),
            ),
            ExcludeSemantics(
              child: Slider(
                value: _currentSettings.maxCacheSize.toDouble(),
                min: 64,
                max: 4096,
                divisions: (4096 - 64) ~/ 64,
                label: '${_currentSettings.maxCacheSize} MB',
                onChanged: (value) {
                  setState(() {
                    _currentSettings =
                        _currentSettings.copyWith(maxCacheSize: value.toInt());
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
