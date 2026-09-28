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
import 'package:http/http.dart' as http;

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
  String? latestVersion;
  String? curseForgeUrl;
  bool updateAvailable;
  PackType type;
  int? originalPriority;
  bool inMegaPack;
  bool isTrinketBridge;

  AddonEntry({
    required this.id,
    required this.name,
    required this.currentVersion,
    this.latestVersion,
    this.curseForgeUrl,
    this.updateAvailable = false,
    required this.type,
    this.originalPriority,
    this.inMegaPack = true,
    this.isTrinketBridge = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'currentVersion': currentVersion,
        'latestVersion': latestVersion,
        'curseForgeUrl': curseForgeUrl,
        'updateAvailable': updateAvailable,
        'type': type.name,
        'originalPriority': originalPriority,
        'inMegaPack': inMegaPack,
        'isTrinketBridge': isTrinketBridge,
      };

  factory AddonEntry.fromMap(Map<String, dynamic> map) => AddonEntry(
        id: map['id'] ?? const Uuid().v4(),
        name: map['name'] ?? '',
        currentVersion: map['currentVersion'] ?? 'v1.0.0',
        latestVersion: map['latestVersion'],
        curseForgeUrl: map['curseForgeUrl'],
        updateAvailable: map['updateAvailable'] ?? false,
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
  String _statusMessage = '';
  final ImagePicker _picker = ImagePicker();

  String? _bundleMasterUuid;
  int _bundleRevision = 1;
  String _bundleName = 'ATM_Mega_Pack';

  static const String _curseForgeApiKey = r'$2a$10$3FNHa/4qb22oL7Fkd6rSvOOuznn.HKesoJyJk0ZYoLH8w8hVEYcX.';

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
    final savedData = prefs.getString('saved_addons_v14');
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
    await prefs.setString('saved_addons_v14', encoded);
    if (_bundleMasterUuid != null) {
      await prefs.setString('atm_bundle_uuid', _bundleMasterUuid!);
    }
    await prefs.setInt('atm_bundle_revision', _bundleRevision);
    await prefs.setString('atm_bundle_name', _bundleName);
  }

  Future<void> _scanScreenshots(PackType targetType) async {
    final List<XFile> images = await _picker.pickMultiImage();
    if (images.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Reading image coordinates...';
    });

    try {
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final List<AddonEntry> newAddons = [];

      for (int i = 0; i < images.length; i++) {
        setState(() => _statusMessage = 'Parsing screenshot ${i + 1} of ${images.length}...');
        final file = File(images[i].path);
        final bytes = await file.readAsBytes();
        final decodedImage = await decodeImageFromList(bytes);
        final double imgWidth = decodedImage.width.toDouble();
        final double imgHeight = decodedImage.height.toDouble();

        final inputImage = InputImage.fromFilePath(images[i].path);
        final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);

        final found = _extractPacksSpatially(recognizedText, targetType, imgWidth, imgHeight);
        newAddons.addAll(found);
      }

      await textRecognizer.close();

      for (int i = 0; i < newAddons.length; i++) {
        setState(() => _statusMessage = 'Checking CurseForge: ${i + 1}/${newAddons.length}...');
        await _fetchCurseForgeMetadata(newAddons[i]);
      }

      int addedCount = 0;
      for (final addon in newAddons) {
        final exists = _detectedAddons.any(
          (a) => a.name.toLowerCase() == addon.name.toLowerCase() && a.type == targetType,
        );
        if (!exists) {
          _detectedAddons.add(addon);
          addedCount++;
        }
      }

      _sortAddons();
      await _persistState();

      if (mounted) {
        final label = targetType == PackType.resource ? 'Resource' : 'Behavior';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Matched $addedCount $label Pack(s) with Registry!'),
            backgroundColor: const Color(0xFF107C41),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Scan error: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '';
        });
      }
    }
  }

  List<AddonEntry> _extractPacksSpatially(RecognizedText recognized, PackType targetType, double imgWidth, double imgHeight) {
    final minX = imgWidth * 0.33;
    final maxX = imgWidth * 0.82;
    final minY = imgHeight * 0.08;
    final maxY = imgHeight * 0.88;

    final blockedTerms = [
      'SETTINGS', 'GENERAL', 'ADVANCED', 'MULTIPLAYER', 'CHEATS', 'RESOURCE PACKS',
      'BEHAVIOUR PACKS', 'BEHAVIOR PACKS', 'ACTIVE', 'MY PACKS', 'AVAILABLE', 'DEACTIVATE',
      'STORAGE', 'EXPERIMENT', 'CHANGES TO THE SAME', 'IF MULTIPLE', 'CREATOR', 'GLOBAL RESOURCES',
      'MINECRAFT', 'FEEDBACK', 'HELP', 'HOW TO PLAY', 'AUDIO', 'VIDEO', 'KEYBOARD', 'CONTROLLER',
      'TOUCH', 'SUBSCRIPTION', 'REALMS', 'EDIT WORLD', 'ACHIEVEMENTS', 'SAME ENTITY'
    ];

    final List<TextLine> contentLines = [];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final box = line.boundingBox;
        if (box.left < minX || box.right > maxX || box.top < minY || box.bottom > maxY) continue;

        final upper = line.text.trim().toUpperCase();
        if (upper.length < 2 || RegExp(r'^[^a-zA-Z0-9]+$').hasMatch(upper)) continue;
        if (blockedTerms.any((term) => upper.contains(term))) continue;
        if (line.text.split(' ').length > 8 || line.text.endsWith('.')) continue;

        contentLines.add(line);
      }
    }

    if (contentLines.isEmpty) return [];

    final double rowHeightTolerance = imgHeight * 0.075;
    contentLines.sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));

    final List<List<TextLine>> rows = [];
    for (final line in contentLines) {
      bool matched = false;
      for (final row in rows) {
        final double avgY = row.map((l) => l.boundingBox.top).reduce((a, b) => a + b) / row.length;
        if ((line.boundingBox.top - avgY).abs() < rowHeightTolerance) {
          row.add(line);
          matched = true;
          break;
        }
      }
      if (!matched) rows.add([line]);
    }

    final List<AddonEntry> extracted = [];
    for (final row in rows) {
      row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
      String rowText = row.map((l) => l.text.trim()).join(' ');

      int? priorityNumber;
      final priorityMatch = RegExp(r'(?:^|[^\d])#?\s*(\d{1,3})\b').firstMatch(rowText);
      if (priorityMatch != null) {
        priorityNumber = int.tryParse(priorityMatch.group(1)!);
        rowText = rowText.replaceFirst(priorityMatch.group(0)!, ' ').trim();
      }

      final versionMatch = RegExp(r'v?(\d+\.\d+(\.\d+)?)', caseSensitive: false).firstMatch(rowText);
      String version = versionMatch != null ? versionMatch.group(0)! : 'v1.0.0';

      var cleanTitle = rowText
          .replaceAll(RegExp(r'\[v?\d+\.\d+(\.\d+)?\]', caseSensitive: false), '')
          .replaceAll(RegExp(r'v?\d+\.\d+(\.\d+)?', caseSensitive: false), '')
          .replaceAll(RegExp(r'^[\]\[:;|\-_/\\•?.]+\s*'), '')
          .replaceAll(RegExp(r'[\]\[]+'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      cleanTitle = _cleanPixelArtifacts(cleanTitle);
      if (cleanTitle.length < 3) continue;

      final lower = cleanTitle.toLowerCase();
      final isBridge = lower.contains('trinket') ||
          lower.contains('curios') ||
          lower.contains('amulet') ||
          lower.contains('backpack') ||
          lower.contains('neck') ||
          lower.contains('api') ||
          lower.contains('core');

      extracted.add(AddonEntry(
        id: const Uuid().v4(),
        name: cleanTitle,
        currentVersion: version,
        type: targetType,
        originalPriority: priorityNumber,
        inMegaPack: true,
        isTrinketBridge: isBridge,
      ));
    }

    return extracted;
  }

  Future<void> _fetchCurseForgeMetadata(AddonEntry addon) async {
    try {
      final sanitized = addon.name
          .replaceAll('RP', '')
          .replaceAll('BP', '')
          .replaceAll(RegExp(r'v?\d+\.\d+.*'), '')
          .replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), '')
          .trim();

      final query = Uri.encodeComponent(sanitized);
      final url = Uri.parse('https://api.curseforge.com/v1/mods/search?gameId=432&searchFilter=$query&pageSize=1');

      final response = await http.get(
        url,
        headers: {
          'Accept': 'application/json',
          'x-api-key': _curseForgeApiKey,
        },
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['data'] != null && (data['data'] as List).isNotEmpty) {
          final mod = data['data'][0];
          final String officialName = mod['name'] ?? addon.name;
          final String pageUrl = mod['links']?['websiteUrl'] ?? '';

          String? remoteVer;
          if (mod['latestFilesIndexes'] != null && (mod['latestFilesIndexes'] as List).isNotEmpty) {
            remoteVer = mod['latestFilesIndexes'][0]['displayName'];
          }

          addon.name = officialName;
          addon.curseForgeUrl = pageUrl;
          if (remoteVer != null) {
            addon.latestVersion = remoteVer;
            addon.updateAvailable = (remoteVer != addon.currentVersion);
          }
        }
      }
    } catch (_) {}
  }

  void _sortAddons() {
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
  }

  String _cleanPixelArtifacts(String text) {
    return text
        .replaceAll('Oravestone', 'Gravestone')
        .replaceAll('Foisonous', 'Poisonous')
        .replaceAll('Ouide Books', 'Guide Books')
        .replaceAll('Riotten Flesh', 'Rotten Flesh')
        .replaceAll('DURAALITY', 'Durability')
        .replaceAll('CRIEND', "Friend")
        .replaceAll('RODON', "Add-On")
        .replaceAll('REFURGED', "Reforged")
        .replaceAll('CRPJ', "RP")
        .replaceAll('CRF', "RP")
        .replaceAll('HETWTF', "")
        .replaceAll('DRE ERLPS', "")
        .replaceAll('TRS A', "A")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void _openUrl(String? urlString) async {
    if (urlString == null || urlString.isEmpty) return;
    final Uri url = Uri.parse(urlString);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
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
          isUpdate ? 'Export Mega-Pack Update: v$_bundleRevision' : 'Create Mega-Pack',
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
              decoration: const InputDecoration(labelText: 'Mega-Pack Title', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(child: const Text('Cancel'), onPressed: () => Navigator.pop(ctx)),
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
        'bundled_behavior_packs_order': behaviorPacks.map((p) => '#${p.originalPriority ?? '?'}: ${p.name}').toList(),
        'bundled_resource_packs_order': resourcePacks.map((p) => '#${p.originalPriority ?? '?'}: ${p.name}').toList(),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export error: $e')));
      }
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
            TextField(controller: titleController, decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: versionController, decoration: const InputDecoration(labelText: 'Version', border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(child: const Text('Cancel'), onPressed: () => Navigator.pop(ctx)),
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
              Text('No ${isRP ? "Resource" : "Behavior"} Packs Scanned', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 80),
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
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: addon.inMegaPack ? Colors.white : Colors.white38,
                    ),
                  ),
                ),
                if (addon.updateAvailable)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.amber.shade900, borderRadius: BorderRadius.circular(4)),
                    child: const Text('UPDATE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
              ],
            ),
            subtitle: Text(
              '${addon.type == PackType.resource ? "RP" : "BP"} • ${addon.currentVersion}${addon.updateAvailable ? " -> ${addon.latestVersion}" : ""}',
              style: TextStyle(fontSize: 12, color: addon.updateAvailable ? Colors.amberAccent : Colors.white70),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (addon.curseForgeUrl != null)
                  IconButton(
                    icon: const Icon(Icons.open_in_browser, color: Color(0xFF52B788), size: 20),
                    tooltip: 'View on CurseForge',
                    onPressed: () => _openUrl(addon.curseForgeUrl),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white38, size: 18),
                  tooltip: 'Remove',
                  onPressed: () {
                    setState(() => _detectedAddons.removeWhere((a) => a.id == addon.id));
                    _persistState();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final megaPackCount = _detectedAddons.where((a) => a.inMegaPack).length;
    final updatesCount = _detectedAddons.where((a) => a.updateAvailable).length;

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
      drawer: Drawer(
        backgroundColor: const Color(0xFF16191F),
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: const BoxDecoration(color: Color(0xFF107C41)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const Text('BedrockSmith', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('Managing $_bundleName (Rev$_bundleRevision)', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.view_list, color: Color(0xFF52B788)),
              title: const Text('Scanned Load Order'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: Badge(
                isLabelVisible: updatesCount > 0,
                label: Text('$updatesCount'),
                backgroundColor: Colors.amber.shade900,
                child: const Icon(Icons.system_update_alt, color: Colors.amber),
              ),
              title: const Text('CurseForge Updates Hub'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => UpdatesHubScreen(addons: _detectedAddons)),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.layers, color: Colors.white70),
              title: const Text('Manage Mega-Pack Load Order'),
              onTap: () {
                Navigator.pop(context);
                _showManageMegaPackSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.archive, color: Colors.white70),
              title: const Text('Export Mega-Pack'),
              onTap: () {
                Navigator.pop(context);
                _showExportDialog();
              },
            ),
            const Divider(color: Colors.white24),
            ListTile(
              leading: const Icon(Icons.auto_awesome, color: Color(0xFF52B788)),
              title: const Text('Gemini Assistant Diagnostics'),
              onTap: () async {
                Navigator.pop(context);
                final buffer = StringBuffer();
                buffer.writeln('=== BedrockSmith Support Report ===');
                buffer.writeln('App Version: v1.0.0');
                buffer.writeln('Bundle UUID: ${_bundleMasterUuid ?? "None"}');
                buffer.writeln('Bundle Revision: $_bundleRevision');
                buffer.writeln('Total Detected Add-ons: ${_detectedAddons.length}');
                for (final p in _detectedAddons) {
                  buffer.writeln('#${p.originalPriority ?? "?"} ${p.name} (${p.currentVersion}) [${p.type.name.toUpperCase()}]');
                }
                await Clipboard.setData(ClipboardData(text: buffer.toString()));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Diagnostics copied! Opening Gemini...'), backgroundColor: Color(0xFF107C41)),
                  );
                }
                final Uri url = Uri.parse('https://gemini.google.com/');
                if (await canLaunchUrl(url)) launchUrl(url, mode: LaunchMode.externalApplication);
              },
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF107C41),
        icon: _isProcessing
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Icon(Icons.add_photo_alternate),
        label: Text(
          _isProcessing
              ? (_statusMessage.isNotEmpty ? _statusMessage : 'Analyzing...')
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
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: updatesCount > 0 ? Colors.amber.shade900 : const Color(0xFF107C41),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: Icon(updatesCount > 0 ? Icons.system_update_alt : Icons.tune),
                  label: Text(
                    updatesCount > 0
                        ? 'VIEW $updatesCount UPDATE(S) ON CURSEFORGE'
                        : 'MANAGE LOAD ORDER ($megaPackCount ACTIVE)',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  onPressed: updatesCount > 0
                      ? () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => UpdatesHubScreen(addons: _detectedAddons)),
                          )
                      : _showManageMegaPackSheet,
                ),
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

class UpdatesHubScreen extends StatelessWidget {
  final List<AddonEntry> addons;
  const UpdatesHubScreen({super.key, required this.addons});

  @override
  Widget build(BuildContext context) {
    final updateList = addons.where((a) => a.updateAvailable).toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF16191F),
        title: const Text('Add-on Updates Hub', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: updateList.isEmpty
          ? const Center(
              child: Text('All scanned add-ons are up to date!', style: TextStyle(color: Colors.white54)),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: updateList.length,
              itemBuilder: (context, index) {
                final item = updateList[index];
                return Card(
                  color: const Color(0xFF1E232B),
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: ListTile(
                    title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      'Current: ${item.currentVersion}  ->  Latest:${item.latestVersion ?? "Unknown"}',
                      style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
                    ),
                    trailing: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF107C41)),
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Update'),
                      onPressed: () async {
                        if (item.curseForgeUrl != null) {
                          final uri = Uri.parse(item.curseForgeUrl!);
                          if (await canLaunchUrl(uri)) launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }
}