import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:archive/archive_io.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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
  int? originalPriority;
  bool inMegaPack;
  bool isTrinketBridge;

  AddonEntry({
    required this.id,
    required this.name,
    required this.currentVersion,
    required this.type,
    this.originalPriority,
    this.inMegaPack = true,
    this.isTrinketBridge = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'currentVersion': currentVersion,
        'type': type.name,
        'originalPriority': originalPriority,
        'inMegaPack': inMegaPack,
        'isTrinketBridge': isTrinketBridge,
      };

  factory AddonEntry.fromMap(Map<String, dynamic> map) => AddonEntry(
        id: map['id'] ?? const Uuid().v4(),
        name: map['name'] ?? '',
        currentVersion: map['currentVersion'] ?? 'v1.0.0',
        type: map['type'] == 'behavior' ? PackType.behavior : PackType.resource,
        originalPriority: map['originalPriority'],
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
    final savedData = prefs.getString('saved_addons_v10');
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
    await prefs.setString('saved_addons_v10', encoded);
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
        final file = File(image.path);
        final bytes = await file.readAsBytes();
        final decodedImage = await decodeImageFromList(bytes);
        final double imgWidth = decodedImage.width.toDouble();
        final double imgHeight = decodedImage.height.toDouble();

        final inputImage = InputImage.fromFilePath(image.path);
        final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);

        totalFound += _processSpatialRecognition(recognizedText, targetType, imgWidth, imgHeight);
      }

      await textRecognizer.close();

      if (mounted) {
        final label = targetType == PackType.resource ? 'Resource' : 'Behavior';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cleanly detected $totalFound $label Pack(s) in priority sequence!'),
            backgroundColor: const Color(0xFF107C41),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  int _processSpatialRecognition(RecognizedText recognized, PackType targetType, double imgWidth, double imgHeight) {
    final minX = imgWidth * 0.35;
    final maxX = imgWidth * 0.80;
    final minY = imgHeight * 0.08;
    final maxY = imgHeight * 0.86;

    final blockedTerms = [
      'SETTINGS', 'GENERAL', 'ADVANCED', 'MULTIPLAYER', 'CHEATS', 'RESOURCE PACKS',
      'BEHAVIOUR PACKS', 'BEHAVIOR PACKS', 'ACTIVE', 'MY PACKS', 'AVAILABLE', 'DEACTIVATE',
      'STORAGE', 'EXPERIMENT', 'CHANGES TO THE SAME', 'IF MULTIPLE', 'CREATOR', 'GLOBAL RESOURCES',
      'MINECRAFT', 'FEEDBACK', 'HELP', 'HOW TO PLAY', 'AUDIO', 'VIDEO', 'KEYBOARD', 'CONTROLLER',
      'TOUCH', 'SUBSCRIPTION', 'REALMS', 'EDIT WORLD', 'ACHIEVEMENTS', 'SAME ENTITY'
    ];

    final List<TextLine> validLines = [];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final box = line.boundingBox;
        if (box.left < minX || box.right > maxX || box.top < minY || box.bottom > maxY) {
          continue;
        }

        final upper = line.text.trim().toUpperCase();
        if (upper.length < 2 || RegExp(r'^[^a-zA-Z0-9]+$').hasMatch(upper)) continue;
        if (blockedTerms.any((term) => upper.contains(term))) continue;
        if (line.text.split(' ').length > 8 || line.text.endsWith('.')) continue;

        validLines.add(line);
      }
    }

    validLines.sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));

    final List<AddonEntry> parsedPacks = [];
    AddonEntry? currentPack;

    for (final line in validLines) {
      var raw = line.text.trim();
      final priorityMatch = RegExp(r'^(?:::|#|:|\.)?\s*(\d{1,3})\b').firstMatch(raw);

      if (priorityMatch != null) {
        final pNum = int.tryParse(priorityMatch.group(1)!);
        raw = raw.replaceFirst(priorityMatch.group(0)!, '').trim();
        raw = _cleanRawTitle(raw);

        if (raw.isNotEmpty) {
          final entry = _createEntry(raw, pNum, targetType);
          parsedPacks.add(entry);
          currentPack = entry;
        }
      } else {
        raw = _cleanRawTitle(raw);
        if (raw.isEmpty) continue;
        if (raw.length <= 4 && !raw.contains('Add') && !raw.contains('Pack')) continue;

        if (currentPack != null &&
            !currentPack.name.endsWith(raw) &&
            !currentPack.name.contains(raw)) {
          currentPack.name = '${currentPack.name} $raw'.trim();
        } else {
          final entry = _createEntry(raw, null, targetType);
          parsedPacks.add(entry);
          currentPack = entry;
        }
      }
    }

    int newlyAdded = 0;
    for (final pack in parsedPacks) {
      pack.name = _permanentMojanglesEngine(pack.name);

      final exists = _detectedAddons.any(
        (a) => a.name.toLowerCase() == pack.name.toLowerCase() && a.type == targetType,
      );

      if (!exists && pack.name.length >= 3) {
        _detectedAddons.add(pack);
        newlyAdded++;
      }
    }

    if (newlyAdded > 0) {
      setState(() {
        _detectedAddons.sort((a, b) {
          if (a.originalPriority != null && b.originalPriority != null) {
            return a.originalPriority!.compareTo(b.originalPriority!);
          }
          if (a.originalPriority != null) return -1;
          if (b.originalPriority != null) return 1;
          return 0;
        });
      });
      _persistState();
    }

    return newlyAdded;
  }

  String _cleanRawTitle(String text) {
    return text
        .replaceAll(RegExp(r'^[\]\[:;|\-_/\\•?.]+\s*'), '')
        .replaceAll(RegExp(r'[\]\[]+'), '')
        .trim();
  }

  String _permanentMojanglesEngine(String rawTitle) {
    final words = rawTitle.split(' ');
    final correctedWords = words.map((word) {
      var w = word;
      if (RegExp(r'^Oravestone', caseSensitive: false).hasMatch(w)) {
        w = w.replaceFirst(RegExp(r'^O', caseSensitive: false), 'G');
      }
      if (RegExp(r'^Foison', caseSensitive: false).hasMatch(w)) {
        w = w.replaceFirst(RegExp(r'^F', caseSensitive: false), 'P');
      }
      if (RegExp(r'^Ouide', caseSensitive: false).hasMatch(w)) {
        w = w.replaceFirst(RegExp(r'^Oui', caseSensitive: false), 'Gui');
      }
      if (RegExp(r'^Riotten', caseSensitive: false).hasMatch(w)) {
        w = 'Rotten';
      }
      return w;
    }).toList();

    return correctedWords.join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  AddonEntry _createEntry(String title, int? priority, PackType targetType) {
    final versionMatch = RegExp(r'v?(\d+\.\d+(\.\d+)?)', caseSensitive: false).firstMatch(title);
    final version = versionMatch != null ? versionMatch.group(0)! : 'v1.0.0';

    final lower = title.toLowerCase();
    final isBridge = lower.contains('trinket') ||
        lower.contains('curios') ||
        lower.contains('amulet') ||
        lower.contains('backpack') ||
        lower.contains('neck') ||
        lower.contains('api') ||
        lower.contains('core');

    return AddonEntry(
      id: const Uuid().v4(),
      name: title,
      currentVersion: version,
      type: targetType,
      originalPriority: priority,
      inMegaPack: true,
      isTrinketBridge: isBridge,
    );
  }

  Future<void> _launchGeminiSupport() async {
    final rpPacks = _detectedAddons.where((a) => a.type == PackType.resource).toList();
    final bpPacks = _detectedAddons.where((a) => a.type == PackType.behavior).toList();

    // Create a diagnostic summary of the app's current state
    final buffer = StringBuffer();
    buffer.writeln('=== BedrockSmith Support Report ===');
    buffer.writeln('App Version: v1.0.0');
    buffer.writeln('Bundle UUID: ${_bundleMasterUuid ?? "None"}');
    buffer.writeln('Bundle Revision: $_bundleRevision');
    buffer.writeln('Total Detected Add-ons: ${_detectedAddons.length}');
    buffer.writeln('\n-- Resource Packs (${rpPacks.length}) --');
    for (final p in rpPacks) {
      buffer.writeln('#${p.originalPriority ?? "?"} ${p.name} (${p.currentVersion})');
    }
    buffer.writeln('\n-- Behavior Packs (${bpPacks.length}) --');
    for (final p in bpPacks) {
      buffer.writeln('#${p.originalPriority ?? "?"} ${p.name} (${p.currentVersion})');
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString()));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Diagnostics copied to clipboard! Paste it into Gemini.'),
          backgroundColor: Color(0xFF107C41),
          duration: Duration(seconds: 4),
        ),
      );
    }

    final Uri url = Uri.parse('https://gemini.google.com/');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  void _showEditTitleDialog(AddonEntry addon) {
    final titleController = TextEditingController(text: addon.name);
    final versionController = TextEditingController(text: addon.currentVersion);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E232B),
        title: const Text('Edit Add-on Details', style: TextStyle(color: Color(0xFF52B788))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(labelText: 'Add-on Title', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: versionController,
              decoration: const InputDecoration(labelText: 'Version', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF107C41)),
            child: const Text('Save'),
            onPressed: () {
              setState(() {
                addon.name = titleController.text.trim();
                addon.currentVersion = versionController.text.trim();
              });
              _persistState();
              Navigator.pop(ctx);
            },
          ),
        ],
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
            initialChildSize: 0.85,
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
                            'Mega-Pack Bundler',
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
                      _buildReorderSectionHeader('Behavior Packs', PackType.behavior, () {
                        setState(() {
                          _detectedAddons.sort((a, b) {
                            if (a.isTrinketBridge && !b.isTrinketBridge) return -1;
                            if (!a.isTrinketBridge && b.isTrinketBridge) return 1;
                            return (a.originalPriority ?? 999).compareTo(b.originalPriority ?? 999);
                          });
                        });
                        setModalState(() {});
                        _persistState();
                      }),
                      _buildReorderList(PackType.behavior, setModalState),
                      const SizedBox(height: 16),
                      _buildReorderSectionHeader('Resource Packs', PackType.resource, () {
                        setState(() {
                          _detectedAddons.sort((a, b) {
                            if (a.isTrinketBridge && !b.isTrinketBridge) return -1;
                            if (!a.isTrinketBridge && b.isTrinketBridge) return 1;
                            return (a.originalPriority ?? 999).compareTo(b.originalPriority ?? 999);
                          });
                        });
                        setModalState(() {});
                        _persistState();
                      }),
                      _buildReorderList(PackType.resource, setModalState),
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

  Widget _buildReorderSectionHeader(String title, PackType type, VoidCallback onSort) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF52B788)),
            icon: const Icon(Icons.sort, size: 16),
            label: const Text('Priority Order', style: TextStyle(fontSize: 12)),
            onPressed: onSort,
          ),
        ],
      ),
    );
  }

  Widget _buildReorderList(PackType type, StateSetter setModalState) {
    final list = _detectedAddons.where((a) => a.type == type).toList();
    if (list.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text('No packs scanned in this category.', style: TextStyle(color: Colors.white30, fontSize: 12)),
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

          final others = _detectedAddons.where((a) => a.type != type).toList();
          _detectedAddons = type == PackType.behavior ? [...list, ...others] : [...others, ...list];
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
            border: addon.isTrinketBridge ? Border.all(color: const Color(0xFF52B788).withOpacity(0.4)) : null,
          ),
          child: ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 12,
              backgroundColor: addon.inMegaPack ? const Color(0xFF107C41) : const Color(0xFF262C36),
              child: Text(
                addon.originalPriority != null ? '${addon.originalPriority}' : '${index + 1}',
                style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
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
              'Bundling ${activeRPs.length} Resource Pack(s) and ${activeBPs.length} Behavior Pack(s) into one single-tap `.mcaddon`:',
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
    final currentRev = _bundleRevision;

    final List<Map<String, dynamic>> modules = [];
    if (behaviorPacks.isNotEmpty) {
      modules.add({
        'description': 'ATM Combined Behavior Pack Modules',
        'type': 'data',
        'uuid': const Uuid().v4(),
        'version': [1, currentRev, 0],
      });
    }
    if (resourcePacks.isNotEmpty) {
      modules.add({
        'description': 'ATM Combined Resource Pack Modules',
        'type': 'resources',
        'uuid': const Uuid().v4(),
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
        'bundled_behavior_packs_order': behaviorPacks
            .map((p) => '#${p.originalPriority ?? '?'}: ${p.name}')
            .toList(),
        'bundled_resource_packs_order': resourcePacks
            .map((p) => '#${p.originalPriority ?? '?'}: ${p.name}')
            .toList(),
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
                'Select screenshots of your Minecraft ${isRP ? "Resource Packs" : "Behavior Packs"} tab.',
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
        return Card(
          color: const Color(0xFF1E232B),
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: ListTile(
            onTap: () => _showEditTitleDialog(addon),
            leading: CircleAvatar(
              backgroundColor: addon.inMegaPack ? const Color(0xFF107C41) : const Color(0xFF262C36),
              child: Text(
                addon.originalPriority != null ? '#${addon.originalPriority}' : '${index + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    addon.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (addon.isTrinketBridge)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF107C41).withOpacity(0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('CORE / BRIDGE', style: TextStyle(fontSize: 9, color: Color(0xFF52B788))),
                  ),
              ],
            ),
            subtitle: Text(
              '${addon.type == PackType.resource ? "RP" : "BP"} • ${addon.currentVersion} • Tap to edit',
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
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: Color(0xFF52B788)),
            tooltip: 'Ask Gemini Support',
            onPressed: _launchGeminiSupport,
          ),
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
              ? 'Scanning...'
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