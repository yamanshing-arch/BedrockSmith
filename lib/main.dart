import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:archive/archive_io.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const BedrockSmithApp());
}

class BedrockSmithApp extends StatelessWidget {
  const BedrockSmithApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BedrockSmith',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF111418),
        primaryColor: const Color(0xFF107C41),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF107C41),
          secondary: Color(0xFF52B788),
          surface: Color(0xFF1E232B),
        ),
      ),
      home: const AddonScannerHome(),
    );
  }
}

class AddonEntry {
  final String id;
  final String name;
  String currentVersion;
  String? latestVersion;
  bool updateAvailable;
  bool inMegaPack;
  bool isTrinketBridge;

  AddonEntry({
    required this.id,
    required this.name,
    required this.currentVersion,
    this.latestVersion,
    this.updateAvailable = false,
    this.inMegaPack = true,
    this.isTrinketBridge = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'currentVersion': currentVersion,
        'latestVersion': latestVersion,
        'updateAvailable': updateAvailable,
        'inMegaPack': inMegaPack,
        'isTrinketBridge': isTrinketBridge,
      };

  factory AddonEntry.fromMap(Map<String, dynamic> map) => AddonEntry(
        id: map['id'] ?? const Uuid().v4(),
        name: map['name'] ?? '',
        currentVersion: map['currentVersion'] ?? 'v1.0.0',
        latestVersion: map['latestVersion'],
        updateAvailable: map['updateAvailable'] ?? false,
        inMegaPack: map['inMegaPack'] ?? true,
        isTrinketBridge: map['isTrinketBridge'] ?? false,
      );
}

class AddonScannerHome extends StatefulWidget {
  const AddonScannerHome({super.key});

  @override
  State<AddonScannerHome> createState() => _AddonScannerHomeState();
}

class _AddonScannerHomeState extends State<AddonScannerHome> {
  List<AddonEntry> _detectedAddons = [];
  bool _isProcessing = false;
  final ImagePicker _picker = ImagePicker();

  String? _bundleMasterUuid;
  int _bundleRevision = 1;
  String _bundleName = 'ATM_Mega_Pack';

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedData = prefs.getString('saved_addons_list');
    if (savedData != null) {
      try {
        final decoded = jsonDecode(savedData) as List;
        _detectedAddons = decoded.map((m) => AddonEntry.fromMap(m)).toList();
      } catch (_) {}
    }

    setState(() {
      _bundleMasterUuid = prefs.getString('atm_bundle_uuid');
      _bundleRevision = prefs.getInt('atm_bundle_revision') ?? 1;
      _bundleName = prefs.getString('atm_bundle_name') ?? 'ATM_Mega_Pack';
    });
  }

  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_detectedAddons.map((a) => a.toMap()).toList());
    await prefs.setString('saved_addons_list', encoded);
    if (_bundleMasterUuid != null) {
      await prefs.setString('atm_bundle_uuid', _bundleMasterUuid!);
    }
    await prefs.setInt('atm_bundle_revision', _bundleRevision);
    await prefs.setString('atm_bundle_name', _bundleName);
  }

  Future<void> _scanScreenshot() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    setState(() => _isProcessing = true);

    try {
      final inputImage = InputImage.fromFilePath(image.path);
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
      await textRecognizer.close();

      _parseExtractedText(recognizedText.text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error analyzing screenshot: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _parseExtractedText(String rawText) {
    final lines = rawText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final List<AddonEntry> newAddons = [];

    final systemKeywords = [
      'SETTINGS', 'GLOBAL RESOURCES', 'ACTIVE', 'MY PACKS', 'DEACTIVATE',
      'BEHAVIOR PACKS', 'RESOURCE PACKS', 'STORAGE', 'AVAILABLE', 'MINECRAFT',
      'REALMS', 'EDIT'
    ];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final upper = line.toUpperCase();

      if (systemKeywords.any((kw) => upper.contains(kw)) || line.length < 3) {
        continue;
      }

      final versionMatch = RegExp(r'v?(\d+\.\d+(\.\d+)?)', caseSensitive: false).firstMatch(line);
      String foundVersion = versionMatch != null ? versionMatch.group(0)! : 'v1.0.0';

      String addonName = line;
      if (versionMatch != null && line.length <= 10 && newAddons.isNotEmpty) {
        continue;
      }

      addonName = addonName.replaceAll(RegExp(r'v?\d+\.\d+(\.\d+)?'), '').trim();
      if (addonName.isEmpty) continue;

      final isBridge = addonName.toLowerCase().contains('trinket') ||
          addonName.toLowerCase().contains('curios') ||
          addonName.toLowerCase().contains('accessory') ||
          addonName.toLowerCase().contains('api') ||
          addonName.toLowerCase().contains('core');

      if (!_detectedAddons.any((a) => a.name.toLowerCase() == addonName.toLowerCase()) &&
          !newAddons.any((a) => a.name.toLowerCase() == addonName.toLowerCase())) {
        newAddons.add(AddonEntry(
          id: const Uuid().v4(),
          name: addonName,
          currentVersion: foundVersion,
          latestVersion: 'v1.4.0',
          updateAvailable: true,
          inMegaPack: true,
          isTrinketBridge: isBridge,
        ));
      }
    }

    setState(() {
      _detectedAddons.addAll(newAddons);
    });
    _persistState();

    if (newAddons.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added ${newAddons.length} new add-ons to your library!'),
          backgroundColor: const Color(0xFF107C41),
        ),
      );
    }
  }

  void _autoSortMegaPackOrder() {
    setState(() {
      _detectedAddons.sort((a, b) {
        if (a.isTrinketBridge && !b.isTrinketBridge) return -1;
        if (!a.isTrinketBridge && b.isTrinketBridge) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    });
    _persistState();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Auto-sorted by priority! (Trinket & Base bridges first)'),
        backgroundColor: Color(0xFF107C41),
      ),
    );
  }

  void _showManageMegaPackSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16191F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final megaPackItems = _detectedAddons.where((a) => a.inMegaPack).toList();

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            maxChildSize: 0.95,
            minChildSize: 0.4,
            builder: (_, scrollController) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Mega-Pack Load Order',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${megaPackItems.length} active add-ons • Hold & drag to reorder',
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF52B788)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      icon: const Icon(Icons.auto_awesome, color: Color(0xFF52B788), size: 16),
                      label: const Text(
                        'AUTO-SORT LOAD PRIORITY',
                        style: TextStyle(color: Color(0xFF52B788), fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      onPressed: () {
                        _autoSortMegaPackOrder();
                        setModalState(() {});
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1, color: Colors.white24),
                Expanded(
                  child: ReorderableListView.builder(
                    itemCount: _detectedAddons.length,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        if (newIndex > oldIndex) newIndex -= 1;
                        final item = _detectedAddons.removeAt(oldIndex);
                        _detectedAddons.insert(newIndex, item);
                      });
                      setModalState(() {});
                      _persistState();
                    },
                    itemBuilder: (context, index) {
                      final addon = _detectedAddons[index];
                      return Container(
                        key: ValueKey(addon.id),
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E232B),
                          borderRadius: BorderRadius.circular(8),
                          border: addon.isTrinketBridge
                              ? Border.all(color: const Color(0xFF52B788).withOpacity(0.5))
                              : null,
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: addon.inMegaPack ? const Color(0xFF107C41) : const Color(0xFF262C36),
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  addon.name,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: addon.inMegaPack ? Colors.white : Colors.white38,
                                  ),
                                ),
                              ),
                              if (addon.isTrinketBridge)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF107C41).withOpacity(0.3),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('CORE / TRINKET', style: TextStyle(fontSize: 9, color: Color(0xFF52B788))),
                                ),
                            ],
                          ),
                          subtitle: Text(
                            addon.currentVersion,
                            style: const TextStyle(fontSize: 11, color: Colors.white54),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                activeColor: const Color(0xFF107C41),
                                value: addon.inMegaPack,
                                onChanged: (val) {
                                  setModalState(() => addon.inMegaPack = val);
                                  setState(() {});
                                  _persistState();
                                },
                              ),
                              const Icon(Icons.drag_handle, color: Colors.white38),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF107C41),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(Icons.archive),
                      label: Text(
                        _bundleMasterUuid != null ? 'EXPORT IN-PLACE UPDATE' : 'CREATE MEGA-PACK',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      onPressed: megaPackItems.isEmpty
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              _showExportDialog();
                            },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showExportDialog() {
    final activePacks = _detectedAddons.where((a) => a.inMegaPack).toList();
    final nameController = TextEditingController(text: _bundleName);
    final isUpdate = _bundleMasterUuid != null;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E232B),
        title: Text(
          isUpdate ? 'Export Update: v$_bundleRevision' : 'Create Mega-Pack',
          style: const TextStyle(color: Color(0xFF52B788)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isUpdate
                  ? 'Minecraft will replace the older version in-place, preserving load order without creating duplicates.'
                  : 'Bundling ${activePacks.length} add-ons into one single-tap installer:',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Mega-Pack Title',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF107C41)),
            icon: const Icon(Icons.save_alt),
            label: Text(isUpdate ? 'Export Update' : 'Generate .mcaddon'),
            onPressed: () {
              Navigator.pop(ctx);
              _generateAndExportMegaPack(nameController.text.trim(), activePacks);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _generateAndExportMegaPack(String packName, List<AddonEntry> packs) async {
    final masterUuid = _bundleMasterUuid ?? const Uuid().v4();
    final moduleUuid = const Uuid().v4();
    final currentRev = _bundleRevision;

    final manifestContent = {
      'format_version': 2,
      'header': {
        'name': packName,
        'description': 'ATM Mega-Pack ($currentRev) with ${packs.length} sorted add-ons.',
        'uuid': masterUuid,
        'version': [1, currentRev, 0],
        'min_engine_version': [1, 20, 0],
      },
      'modules': [
        {
          'type': 'data',
          'uuid': moduleUuid,
          'version': [1, currentRev, 0],
        }
      ],
      'metadata': {
        'authors': ['BedrockSmith User'],
        'bundled_addons_order': packs.asMap().entries.map((e) => '#${e.key + 1}: ${e.value.name} (${e.value.currentVersion})').toList(),
      }
    };

    final downloadsDir = Directory('/storage/emulated/0/Download');
    final cleanName = packName.replaceAll(' ', '_');
    final filePath = '${downloadsDir.path}/${cleanName}_v$currentRev.mcaddon';

    try {
      final archive = Archive();
      final manifestBytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(manifestContent));
      archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));

      final encoder = ZipEncoder();
      final zipData = encoder.encode(archive);

      if (zipData != null) {
        final outFile = File(filePath);
        await outFile.writeAsBytes(zipData);

        setState(() {
          _bundleMasterUuid = masterUuid;
          _bundleRevision += 1;
          _bundleName = packName;
        });
        await _persistState();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Exported to Downloads/${outFile.uri.pathSegments.last}'),
              backgroundColor: const Color(0xFF107C41),
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final megaPackCount = _detectedAddons.where((a) => a.inMegaPack).length;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF16191F),
        elevation: 0,
        title: const Text('BEDROCKSMITH', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
        actions: [
          if (_detectedAddons.isNotEmpty) ...[
            IconButton(
              icon: Badge(
                label: Text('$megaPackCount'),
                backgroundColor: const Color(0xFF107C41),
                child: const Icon(Icons.layers),
              ),
              tooltip: 'Manage Mega-Pack',
              onPressed: _showManageMegaPackSheet,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white54),
              tooltip: 'Clear Library',
              onPressed: () {
                setState(() => _detectedAddons.clear());
                _persistState();
              },
            ),
          ]
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF107C41),
        icon: _isProcessing
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Icon(Icons.add_photo_alternate),
        label: Text(_isProcessing ? 'Analyzing...' : 'Scan Screenshot'),
        onPressed: _isProcessing ? null : _scanScreenshot,
      ),
      bottomNavigationBar: _detectedAddons.isNotEmpty
          ? Container(
              color: const Color(0xFF16191F),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF107C41),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.tune),
                label: Text(
                  'MANAGE LOAD ORDER ($megaPackCount ACTIVE)',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                onPressed: _showManageMegaPackSheet,
              ),
            )
          : null,
      body: _detectedAddons.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.screenshot_monitor, size: 64, color: Colors.white24),
                    const SizedBox(height: 16),
                    const Text(
                      'No Add-ons in Library',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Take screenshots of your Minecraft Add-ons list and tap below to scan and start building your Mega-Pack.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              itemCount: _detectedAddons.length,
              itemBuilder: (context, index) {
                final addon = _detectedAddons[index];
                return Card(
                  color: const Color(0xFF1E232B),
                  margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: addon.inMegaPack ? const Color(0xFF107C41) : const Color(0xFF262C36),
                      child: Icon(
                        addon.inMegaPack ? Icons.check : Icons.remove,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                    title: Row(
                      children: [
                        Expanded(child: Text(addon.name, style: const TextStyle(fontWeight: FontWeight.bold))),
                        if (addon.isTrinketBridge)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF107C41).withOpacity(0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('CORE / TRINKET', style: TextStyle(fontSize: 9, color: Color(0xFF52B788))),
                          ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Current: ${addon.currentVersion}', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                        if (addon.updateAvailable)
                          Text(
                            'Update Available: ${addon.latestVersion}',
                            style: const TextStyle(fontSize: 12, color: Colors.amberAccent, fontWeight: FontWeight.bold),
                          ),
                      ],
                    ),
                    trailing: addon.updateAvailable
                        ? ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF107C41),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            ),
                            onPressed: () {
                              setState(() {
                                addon.currentVersion = addon.latestVersion!;
                                addon.updateAvailable = false;
                              });
                              _persistState();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Updated ${addon.name}!')),
                              );
                            },
                            child: const Text('UPDATE', style: TextStyle(fontSize: 11)),
                          )
                        : const Icon(Icons.check_circle, color: Color(0xFF52B788), size: 20),
                  ),
                );
              },
            ),
    );
  }
}