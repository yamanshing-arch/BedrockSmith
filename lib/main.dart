import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
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
      title: 'BedrockSmith: Addon Manager',
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
  String _geminiApiKey = '';

  static const String _permanentKeyStorage = 'bedrocksmith_gemini_api_key';
  static const String _curseForgeApiKey = r'$2a$10$3FNHa/4qb22oL7Fkd6rSvOOuznn.HKesoJyJk0ZYoLH8w8hVEYcX.';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {});
      }
    });
    _loadState();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedKey = prefs.getString(_permanentKeyStorage) ?? '';
    final savedData = prefs.getString('saved_addons_store_v1');
    if (savedData != null) {
      try {
        final decoded = jsonDecode(savedData) as List;
        _detectedAddons = decoded.map((m) => AddonEntry.fromMap(m)).toList();
      } catch (_) {}
    }
    setState(() {
      _geminiApiKey = savedKey;
      _bundleMasterUuid = prefs.getString('atm_bundle_uuid');
      _bundleRevision = prefs.getInt('atm_bundle_revision') ?? 1;
      _bundleName = prefs.getString('atm_bundle_name') ?? 'ATM_Mega_Pack';
    });
  }

  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_detectedAddons.map((a) => a.toMap()).toList());
    await prefs.setString('saved_addons_store_v1', encoded);
    if (_bundleMasterUuid != null) {
      await prefs.setString('atm_bundle_uuid', _bundleMasterUuid!);
    }
    await prefs.setInt('atm_bundle_revision', _bundleRevision);
    await prefs.setString('atm_bundle_name', _bundleName);
    await prefs.setString(_permanentKeyStorage, _geminiApiKey);
  }

  void _showApiKeyDialog() {
    final keyController = TextEditingController(text: _geminiApiKey);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E232B),
        title: Row(
          children: const [
            Icon(Icons.auto_awesome, color: Color(0xFF52B788)),
            SizedBox(width: 8),
            Text(
              'Gemini AI Key Settings',
              style: TextStyle(fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _geminiApiKey.isEmpty
                  ? 'Enter your free Gemini API key from Google AI Studio. It will be remembered permanently on your device.'
                  : 'Your API key is active and saved. You can edit, replace, or remove it at any time.',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyController,
              decoration: InputDecoration(
                labelText: 'Google AI Studio Key',
                hintText: 'Paste key here...',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: keyController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => keyController.clear(),
                      )
                    : null,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF107C41),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            icon: const Icon(Icons.check, size: 18, color: Colors.white),
            label: const Text(
              'Apply & Remember Key',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            onPressed: () async {
              final newKey = keyController.text.trim();
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_permanentKeyStorage, newKey);
              setState(() {
                _geminiApiKey = newKey;
              });
              if (mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      newKey.isEmpty
                          ? 'API key removed.'
                          : 'Gemini API key saved permanently! Ready to scan.',
                    ),
                    backgroundColor: const Color(0xFF107C41),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _scanScreenshotsWithAI(PackType targetType) async {
    if (_geminiApiKey.isEmpty) {
      _showApiKeyDialog();
      return;
    }
    final List<XFile> images = await _picker.pickMultiImage();
    if (images.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Initializing gemini-3.8-flash model...';
    });

    try {
      const activeModelName = 'gemini-3.8-flash';
      final model = GenerativeModel(
        model: activeModelName,
        apiKey: _geminiApiKey,
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          temperature: 0.1,
        ),
      );

      final List<AddonEntry> newAddons = [];

      for (int i = 0; i < images.length; i++) {
        final file = File(images[i].path);
        final bytes = await file.readAsBytes();

        final prompt = TextPart('''
You are reading a Minecraft Bedrock world add-on list screenshot.
Examine each horizontal card row carefully.
Extract each active pack on screen in strict order from top to bottom.
Ignore sidebar menu items (General, Advanced, Cheats, Resource packs, Behaviour packs, Experiments).
Ignore buttons (Settings, Remove, Deactivate) and footer instructions.
For each pack card:
- "priority": the integer index shown on the card (e.g. 1, 5, 51, 82, 91). If missing or obscured, use null.
- "name": the complete clean add-on title. Merge wrapped lines of title together. Fix pixel-font OCR glitches (e.g. "Oravestone" -> "Gravestone", "Foisonous" -> "Poisonous", "Ouide" -> "Guide").
- "version": the version string if visible (e.g. "v1.4.1", "1.2.8", "3.3"), otherwise "v1.0.0".
Return ONLY a JSON array with this structure:
[
  {"priority": 51, "name": "Compostables+", "version": "v1.0.0"}
]
''');

        final imagePart = DataPart('image/jpeg', bytes);

        GenerateContentResponse? response;
        int attempts = 0;
        while (attempts < 3) {
          try {
            setState(() => _statusMessage = 'Reading image ${i + 1}/${images.length} ($activeModelName)...');
            response = await model.generateContent([
              Content.multi([prompt, imagePart])
            ]);
            if (response.text != null && response.text!.isNotEmpty) break;
          } catch (err) {
            attempts++;
            if (attempts >= 3) rethrow;
            setState(() => _statusMessage = 'Server busy (attempt $attempts). Waiting ${attempts * 3}s...');
            await Future.delayed(Duration(seconds: attempts * 3));
          }
        }

        if (response == null || response.text == null || response.text!.isEmpty) {
          throw Exception('Failed to receive response from Gemini API.');
        }

        try {
          final List parsed = jsonDecode(response.text!);
          for (final item in parsed) {
            final rawName = (item['name'] ?? '').toString().trim();
            if (rawName.isEmpty) continue;
            final int? priority = item['priority'] is int ? item['priority'] : int.tryParse('${item['priority']}');
            final String version = (item['version'] ?? 'v1.0.0').toString().trim();
            final lower = rawName.toLowerCase();
            final isBridge = lower.contains('trinket') ||
                lower.contains('curios') ||
                lower.contains('amulet') ||
                lower.contains('backpack') ||
                lower.contains('neck') ||
                lower.contains('api') ||
                lower.contains('core');

            newAddons.add(AddonEntry(
              id: const Uuid().v4(),
              name: rawName,
              currentVersion: version,
              type: targetType,
              originalPriority: priority,
              inMegaPack: true,
              isTrinketBridge: isBridge,
            ));
          }
        } catch (_) {}
      }

      for (int i = 0; i < newAddons.length; i++) {
        setState(() => _statusMessage = 'CurseForge registry check: ${i + 1}/${newAddons.length}...');
        await _fetchCurseForgeMetadataStrict(newAddons[i]);
      }

      int addedCount = 0;
      for (final addon in newAddons) {
        final existingIdx = _detectedAddons.indexWhere(
          (a) =>
              (a.originalPriority != null && a.originalPriority == addon.originalPriority && a.type == targetType) ||
              (a.name.toLowerCase() == addon.name.toLowerCase() && a.type == targetType),
        );
        if (existingIdx >= 0) {
          if (addon.originalPriority != null && _detectedAddons[existingIdx].originalPriority == null) {
            _detectedAddons[existingIdx].originalPriority = addon.originalPriority;
          }
        } else {
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
            content: Text('AI parsed $addedCount $label Pack(s) in sequence!'),
            backgroundColor: const Color(0xFF107C41),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('AI Scan error: $e')));
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

  Future<void> _fetchCurseForgeMetadataStrict(AddonEntry addon) async {
    try {
      final sanitized = addon.name
          .replaceAll('RP', '')
          .replaceAll('BP', '')
          .replaceAll(RegExp(r'v?\d+\.\d+.*'), '')
          .replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), '')
          .trim();
      if (sanitized.length < 3) return;

      final query = Uri.encodeComponent(sanitized);
      final url = Uri.parse('https://api.curseforge.com/v1/mods/search?gameId=432&searchFilter=$query&pageSize=3');
      final response = await http.get(
        url,
        headers: {
          'Accept': 'application/json',
          'x-api-key': _curseForgeApiKey,
        },
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['data'] != null && (data['data'] as List).isNotEmpty) {
          final results = data['data'] as List;
          for (final mod in results) {
            final String remoteName = (mod['name'] ?? '').toString();
            if (remoteName.toLowerCase().contains('fabric') || remoteName.toLowerCase().contains('forge')) {
              continue;
            }
            final lowerRemote = remoteName.toLowerCase();
            final lowerLocal = sanitized.toLowerCase();
            if (lowerRemote.contains(lowerLocal) ||
                lowerLocal.contains(remoteName) ||
                _calculateSimilarity(lowerRemote, lowerLocal) > 0.65) {
              addon.name = remoteName;
              addon.curseForgeUrl = mod['links']?['websiteUrl'] ?? '';
              if (mod['latestFilesIndexes'] != null && (mod['latestFilesIndexes'] as List).isNotEmpty) {
                final remoteVer = mod['latestFilesIndexes'][0]['displayName'];
                if (remoteVer != null) {
                  addon.latestVersion = remoteVer;
                  addon.updateAvailable = (remoteVer != addon.currentVersion);
                }
              }
              break;
            }
          }
        }
      }
    } catch (_) {}
  }

  double _calculateSimilarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    final pairs1 = _getWordPairs(s1);
    final pairs2 = _getWordPairs(s2);
    int intersection = 0;
    for (final p in pairs1) {
      if (pairs2.contains(p)) intersection++;
    }
    return (2.0 * intersection) / (pairs1.length + pairs2.length);
  }

  Set<String> _getWordPairs(String str) {
    final set = <String>{};
    for (int i = 0; i < str.length - 1; i++) {
      set.add(str.substring(i, i + 2));
    }
    return set;
  }

  void _sortAddons() {
    setState(() {
      _detectedAddons.sort((a, b) {
        if (a.originalPriority != null && b.originalPriority != null) {
          return a.originalPriority!.compareTo(b.originalPriority!);
        }
        if (a.originalPriority != null) return -1;
        if (b.originalPriority != null) return 1;
        return a.name.compareTo(b.name);
      });
    });
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
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          'Bundle: $_bundleName (Rev $_bundleRevision)',
                          style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white70),
                        ),
                      ),
                      ..._detectedAddons.map((addon) => CheckboxListTile(
                            value: addon.inMegaPack,
                            activeColor: const Color(0xFF107C41),
                            title: Text(addon.name, style: const TextStyle(fontSize: 14)),
                            subtitle: Text('${addon.type.name.toUpperCase()} • ${addon.currentVersion}',
                                style: const TextStyle(fontSize: 11, color: Colors.white54)),
                            onChanged: (val) {
                              setModalState(() {
                                addon.inMegaPack = val ?? true;
                              });
                              setState(() {});
                              _persistState();
                            },
                          )),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentType = _tabController.index == 0 ? PackType.resource : PackType.behavior;
    final currentList = _detectedAddons.where((a) => a.type == currentType).toList();

    return Scaffold(
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
                children: const [
                  Text(
                    'BedrockSmith',
                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text('Add-on Organizer & Bundler', style: TextStyle(color: Colors.white70, fontSize: 13)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2, color: Color(0xFF52B788)),
              title: const Text('Mega-Pack Settings'),
              onTap: () {
                Navigator.pop(context);
                _showManageMegaPackSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.vpn_key, color: Colors.white70),
              title: const Text('Gemini API Key'),
              onTap: () {
                Navigator.pop(context);
                _showApiKeyDialog();
              },
            ),
          ],
        ),
      ),
      appBar: AppBar(
        title: const Text('BEDROCKSMITH'),
        backgroundColor: const Color(0xFF16191F),
        actions: [
          IconButton(
            icon: Icon(
              Icons.vpn_key,
              color: _geminiApiKey.isEmpty ? Colors.white54 : const Color(0xFF52B788),
            ),
            tooltip: 'Gemini API Key',
            onPressed: _showApiKeyDialog,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'Clear Current Tab',
            onPressed: () {
              setState(() {
                _detectedAddons.removeWhere((a) => a.type == currentType);
              });
              _persistState();
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF52B788),
          tabs: const [
            Tab(icon: Icon(Icons.palette), text: 'Resource Packs'),
            Tab(icon: Icon(Icons.extension), text: 'Behavior Packs'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF107C41),
        foregroundColor: Colors.white,
        onPressed: _isProcessing ? null : () => _scanScreenshotsWithAI(currentType),
        icon: const Icon(Icons.auto_awesome),
        label: Text('AI Scan ${currentType == PackType.resource ? 'Resource' : 'Behavior'} Packs'),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: const Color(0xFF16191F),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E232B),
                foregroundColor: Colors.white,
              ),
              onPressed: _showManageMegaPackSheet,
              icon: const Icon(Icons.inventory_2, size: 16),
              label: const Text('Mega-Pack Settings'),
            ),
            Text(
              '${currentList.length} Loaded',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
      body: _isProcessing
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(color: Color(0xFF52B788)),
                  const SizedBox(height: 16),
                  Text(_statusMessage, style: const TextStyle(color: Colors.white70)),
                ],
              ),
            )
          : currentList.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        currentType == PackType.resource ? Icons.palette_outlined : Icons.extension_outlined,
                        size: 64,
                        color: Colors.white24,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No ${currentType == PackType.resource ? 'Resource' : 'Behavior'} Packs scanned yet.',
                        style: const TextStyle(color: Colors.white54),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Take screenshots of your active pack list in Minecraft,\nthen tap "AI Scan" below.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white30, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80, top: 8),
                  itemCount: currentList.length,
                  itemBuilder: (ctx, idx) {
                    final item = currentList[idx];
                    return Card(
                      color: const Color(0xFF1E232B),
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF111418),
                          child: Text(
                            item.originalPriority != null ? '#${item.originalPriority}' : '-',
                            style: const TextStyle(color: Color(0xFF52B788), fontSize: 12),
                          ),
                        ),
                        title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Installed: ${item.currentVersion}', style: const TextStyle(fontSize: 12)),
                            if (item.latestVersion != null)
                              Text(
                                'CurseForge: ${item.latestVersion}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: item.updateAvailable ? Colors.amber : const Color(0xFF52B788),
                                ),
                              ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (item.curseForgeUrl != null && item.curseForgeUrl!.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.open_in_new, size: 20, color: Color(0xFF52B788)),
                                onPressed: () => _openUrl(item.curseForgeUrl),
                              ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18, color: Colors.white30),
                              onPressed: () {
                                setState(() {
                                  _detectedAddons.remove(item);
                                });
                                _persistState();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}