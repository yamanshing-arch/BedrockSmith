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

enum PackType { resource, behavior }

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
  String name;
  String currentVersion;
  PackType type;
  bool inMegaPack;
  bool isTrinketBridge;

  AddonEntry({
    required this.id,
    required this.name,
    required this.currentVersion,
    required this.type,
    this.inMegaPack = true,
    this.isTrinketBridge = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'currentVersion': currentVersion,
        'type': type.name,
        'inMegaPack': inMegaPack,
        'isTrinketBridge': isTrinketBridge,
      };

  factory AddonEntry.fromMap(Map<String, dynamic> map) => AddonEntry(
        id: map['id'] ?? const Uuid().v4(),
        name: map['name'] ?? '',
        currentVersion: map['currentVersion'] ?? 'v1.0.0',
        type: map['type'] == 'behavior' ? PackType.behavior : PackType.resource,
        inMegaPack: map['inMegaPack'] ?? true,
        isTrinketBridge: map['isTrinketBridge'] ?? false,
      );
}

class AddonScannerHome extends StatefulWidget {
  const AddonScannerHome({super.key});

  @override
  State<AddonScannerHome> createState() => _AddonScannerHomeState();
}

class _AddonScannerHomeState extends State<AddonScannerHome> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<AddonEntry> _detectedAddons = [];
  bool _isProcessing = false;
  final ImagePicker _picker = ImagePicker();

  String? _bundleMasterUuid;
  int _bundleRevision = 1;
  String _bundleName = 'ATM_Mega_Pack';

  static const Set<String> _ignoredKeywords = {
    'GENERAL',
    'ADVANCED',
    'MULTIPLAYER',
    'CHEATS',
    'EXPERIMENT',
    'EXPERIMENTS',
    'CEXPERIMENT',
    'RESOURCE PACKS',
    'RIESOURCE PACKS',
    'BEHAVIOUR PACKS',
    'BEHAVIOR PACKS',
    'MY PACKS',
    'ACTIVE',
    'AVAILABLE',
    'DEACTIVATE',
    'SETTINGS',
    'GLOBAL RESOURCES',
    'STORAGE',
    'MINECRAFT',
    'REALMS',
    'EDIT',
    'REMOVE',
    'IEMOVE',
    'SELECT',
    'BACK',
    'PLAY',
    'WORLD',
    'CREATE',
    'CANCEL',
    'DONE',
    'TEXTURES',
    'DEFAULT',
  };

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadState();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedData = prefs.getString('saved_addons_list_v2');
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
    await prefs.setString('saved_addons_list_v2', encoded);
    if (_bundleMasterUuid != null) {
      await prefs.setString('atm_bundle_uuid', _bundleMasterUuid!);
    }
    await prefs.setInt('atm_bundle_revision', _bundleRevision);
    await prefs.setString('atm_bundle_name', _bundleName);
  }

  Future<void> _scanScreenshots(PackType targetType) async {
    final List<XFile> images = await _picker.pickMultiImage();
    if (images.isEmpty) return;

    setState(() => _isProcessing = true);

    try {
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      int totalFound = 0;

      for (final image in images) {
        final inputImage = InputImage.fromFilePath(image.path);
        final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
        totalFound += _parseExtractedText(recognizedText.text, targetType);
      }

      await textRecognizer.close();

      if (mounted) {
        final label = targetType == PackType.resource ? 'Resource Pack' : 'Behavior Pack';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(totalFound > 0
                ? 'Added $totalFound$label(s) to your collection!'
                : 'Scanned images, but no new $label titles were recognized.'),
            backgroundColor: const Color(0xFF107C41),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error analyzing screenshots: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  int _parseExtractedText(String rawText, PackType targetType) {
    final lines = rawText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final List<AddonEntry> newAddons = [];

    for (int i = 0; i < lines.length; i++) {
      var line = lines[i];
      line = line.replaceAll(RegExp(r'^[\]\[|/\\•\-_]+\s*'), '').trim();
      final upper = line.toUpperCase();

      if (line.length < 3 || _ignoredKeywords.contains(upper)) {
        continue;
      }

      bool isBlocked = false;
      for (final kw in _ignoredKeywords) {
        if (upper == kw || upper == '$kw S' || upper.startsWith('$kw ')) {
          if (!upper.contains('DELIGHT') && !upper.contains('WAILA') && !upper.contains('LIGHT')) {
            isBlocked = true;
            break;
          }
        }
      }
      if (isBlocked) continue;

      final versionMatch = RegExp(r'v?(\d+\.\d+(\.\d+)?)', caseSensitive: false).firstMatch(line);
      String foundVersion = versionMatch != null ? versionMatch.group(0)! : 'v1.0.0';

      String addonName = line;
      if (versionMatch != null && line.length <= 8) {
        continue;
      }

      addonName = addonName.replaceAll(RegExp(r'v?\d+\.\d+(\.\d+)?'), '').trim();
      if (addonName.isEmpty || addonName.length < 3) continue;

      // Deduce pack type preference if explicit in name, otherwise respect the tab
      PackType assignedType = targetType;
      if (addonName.toLowerCase().endsWith(' rp') || addonName.toLowerCase().contains('[rf]')) {
        assignedType = PackType.resource;
      } else if (addonName.toLowerCase().endsWith(' bp')) {
        assignedType = PackType.behavior;
      }

      final isBridge = addonName.toLowerCase().contains('trinket') ||
          addonName.toLowerCase().contains('curios') ||
          addonName.toLowerCase().contains('accessory') ||
          addonName.toLowerCase().contains('api') ||
          addonName.toLowerCase().contains('core');

      final alreadyExists = _detectedAddons.any(
            (a) => a.name.toLowerCase() == addonName.toLowerCase() && a.type == assignedType,
          ) ||
          newAddons.any(
            (a) => a.name.toLowerCase() == addonName.toLowerCase() && a.type == assignedType,
          );

      if (!alreadyExists) {
        newAddons.add(AddonEntry(
          id: const Uuid().v4(),
          name: addonName,
          currentVersion: foundVersion,
          type: assignedType,
          inMegaPack: true,
          isTrinketBridge: isBridge,
        ));
      }
    }

    if (newAddons.isNotEmpty) {
      setState(() {
        _detectedAddons.addAll(newAddons);
      });
      _persistState();
    }

    return newAddons.length;
  }

  void _autoSortSectionOrder(PackType type) {
    setState(() {
      final sectionItems = _detectedAddons.where((a) => a.type == type).toList();
      final otherItems = _detectedAddons.where((a) => a.type != type).toList();

      sectionItems.sort((a, b) {
        if (a.isTrinketBridge && !b.isTrinketBridge) return -1;
        if (!a.isTrinketBridge && b.isTrinketBridge) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      _detectedAddons = [...sectionItems, ...otherItems];
    });
    _persistState();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Auto-sorted ${type == PackType.resource ? "Resource" : "Behavior"} Packs!'),
        backgroundColor: const Color(0xFF107C41),
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
          final rpList = _detectedAddons.where((a) => a.type == PackType.resource && a.inMegaPack).toList();
          final bpList = _detectedAddons.where((a) => a.type == PackType.behavior && a.inMegaPack).toList();

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.8,
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
                            'Mega-Pack Bundler (RP + BP)',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${rpList.length} Resource Packs • ${bpList.length} Behavior Packs',
                            style: const TextStyle(color: Color(0xFF52B788), fontSize: 12),
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
                const Divider(height: 1, color: Colors.white24),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    children: [
                      _buildReorderableSectionHeader('Behavior Packs (Scripts & Logic)', PackType.behavior, () {
                        _autoSortSectionOrder(PackType.behavior);
                        setModalState(() {});
                      }),
                      _buildSectionReorderList(PackType.behavior, setModalState),
                      const SizedBox(height: 16),
                      _buildReorderableSectionHeader('Resource Packs (Textures & Models)', PackType.resource, () {
                        _autoSortSectionOrder(PackType.resource);
                        setModalState(() {});
                      }),
                      _buildSectionReorderList(PackType.resource, setModalState),
                    ],
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
                        _bundleMasterUuid != null ? 'EXPORT COMBINED UPDATE' : 'CREATE COMBINED MEGA-PACK',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      onPressed: (rpList.isEmpty && bpList.isEmpty)
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

  Widget _buildReorderableSectionHeader(String title, PackType type, VoidCallback onSort) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF52B788)),
            icon: const Icon(Icons.sort, size: 16),
            label: const Text('Sort', style: TextStyle(fontSize: 12)),
            onPressed: onSort,
          ),
        ],
      ),
    );
  }

  Widget _buildSectionReorderList(PackType type, StateSetter setModalState) {
    final list = _detectedAddons.where((a) => a.type == type).toList();
    if (list.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Text('No packs scanned for this section.', style: TextStyle(color: Colors.white30, fontSize: 12)),
      );
    }

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: list.length,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex -= 1;
          final item = list.removeAt(oldIndex);
          list.insert(newIndex, item);

          // Update main state order
          final otherItems = _detectedAddons.where((a) => a.type != type).toList();
          _detectedAddons = type == PackType.behavior ? [...list, ...otherItems] : [...otherItems, ...list];
        });
        setModalState(() {});
        _persistState();
      },
      itemBuilder: (context, index) {
        final addon = list[index];
        return Container(
          key: ValueKey(addon.id),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF1E232B),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 12,
              backgroundColor: addon.inMegaPack ? const Color(0xFF107C41) : const Color(0xFF262C36),
              child: Text(
                '${index + 1}',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            title: Text(addon.name, style: TextStyle(fontSize: 13, color: addon.inMegaPack ? Colors.white : Colors.white38)),
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
                const Icon(Icons.drag_handle, color: Colors.white38, size: 18),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showExportDialog() {
    final activeRPs = _detectedAddons.where((a) => a.type == PackType.resource && a.inMegaPack).toList();
    final activeBPs = _detectedAddons.where((a) => a.type == PackType.behavior && a.inMegaPack).toList();
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
              'Bundles ${activeRPs.length} Resource Pack(s) and${activeBPs.length} Behavior Pack(s) into one single-tap `.mcaddon`:',
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
              _generateAndExportMegaPack(nameController.text.trim(), activeRPs, activeBPs);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _generateAndExportMegaPack(
    String packName,
    List<AddonEntry> resourcePacks,
    List<AddonEntry> behaviorPacks,
  ) async {
    final masterUuid = _bundleMasterUuid ?? const Uuid().v4();
    final bpModuleUuid = const Uuid().v4();
    final rpModuleUuid = const Uuid().v4();
    final currentRev = _bundleRevision;

    final List<Map<String, dynamic>> modules = [];
    if (behaviorPacks.isNotEmpty) {
      modules.add({
        'description': 'ATM Combined Behavior Pack Modules',
        'type': 'data',
        'uuid': bpModuleUuid,
        'version': [1, currentRev, 0],
      });
    }
    if (resourcePacks.isNotEmpty) {
      modules.add({
        'description': 'ATM Combined Resource Pack Modules',
        'type': 'resources',
        'uuid': rpModuleUuid,
        'version': [1, currentRev, 0],
      });
    }

    final manifestContent = {
      'format_version': 2,
      'header': {
        'name': packName,
        'description': 'ATM Combined Pack ($currentRev) • ${behaviorPacks.length} BP / ${resourcePacks.length} RP',
        'uuid': masterUuid,
        'version': [1, currentRev, 0],
        'min_engine_version': [1, 20, 0],
      },
      'modules': modules,
      'metadata': {
        'authors': ['BedrockSmith User'],
        'bundled_behavior_packs': behaviorPacks.map((p) => p.name).toList(),
        'bundled_resource_packs': resourcePacks.map((p) => p.name).toList(),
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

  Widget _buildListForType(PackType type) {
    final list = _detectedAddons.where((a) => a.type == type).toList();
    if (list.isEmpty) {
      final isRP = type == PackType.resource;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(isRP ? Icons.palette_outlined : Icons.extension_outlined, size: 64, color: Colors.white24),
              const SizedBox(height: 16),
              Text(
                'No ${isRP ? "Resource" : "Behavior"} Packs Scanned',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Take screenshots of your ${isRP ? "Resource Packs" : "Behavior Packs"} tab in Minecraft and tap below to scan.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final addon = list[index];
        return Dismissible(
          key: Key(addon.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20.0),
            color: Colors.redAccent.withOpacity(0.8),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) {
            setState(() => _detectedAddons.removeWhere((a) => a.id == addon.id));
            _persistState();
          },
          child: Card(
            color: const Color(0xFF1E232B),
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: addon.inMegaPack ? const Color(0xFF107C41) : const Color(0xFF262C36),
                child: Icon(
                  addon.type == PackType.resource ? Icons.brush : Icons.smart_toy,
                  color: Colors.white,
                  size: 16,
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
              subtitle: Text(
                '${addon.type == PackType.resource ? "RP" : "BP"} • ${addon.currentVersion}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close, color: Colors.white38, size: 18),
                tooltip: 'Remove',
                onPressed: () {
                  setState(() => _detectedAddons.removeWhere((a) => a.id == addon.id));
                  _persistState();
                },
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final megaPackCount = _detectedAddons.where((a) => a.inMegaPack).length;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF16191F),
        elevation: 0,
        title: const Text('BEDROCKSMITH', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF52B788),
          labelColor: const Color(0xFF52B788),
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(icon: Icon(Icons.palette), text: 'Resource Packs'),
            Tab(icon: Icon(Icons.extension), text: 'Behavior Packs'),
          ],
        ),
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
              icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
              tooltip: 'Clear All',
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
        label: Text(
          _isProcessing
              ? 'Analyzing...'
              : (_tabController.index == 0 ? 'Scan Resource Packs' : 'Scan Behavior Packs'),
        ),
        onPressed: _isProcessing
            ? null
            : () => _scanScreenshots(_tabController.index == 0 ? PackType.resource : PackType.behavior),
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
                  'EXPORT MEGA-PACK ($megaPackCount ACTIVE)',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                onPressed: _showManageMegaPackSheet,
              ),
            )
          : null,
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildListForType(PackType.resource),
          _buildListForType(PackType.behavior),
        ],
      ),
    );
  }
}