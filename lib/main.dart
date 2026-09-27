import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';

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
          surface: Color(0xFF1C2027),
        ),
      ),
      home: const WorldManagerDashboard(),
    );
  }
}

class WorldManagerDashboard extends StatefulWidget {
  const WorldManagerDashboard({super.key});

  @override
  State<WorldManagerDashboard> createState() => _WorldManagerDashboardState();
}

class WorldItem {
  final String id;
  final String name;
  final Directory directory;
  WorldItem({required this.id, required this.name, required this.directory});
}

class PackEntry {
  final String uuid;
  List<int> version;
  String name;
  bool updateAvailable;
  List<int>? latestVersion;

  PackEntry({
    required this.uuid,
    required this.version,
    required this.name,
    this.updateAvailable = false,
    this.latestVersion,
  });

  Map<String, dynamic> toJson() => {
        'pack_id': uuid,
        'version': version,
      };
}

class _WorldManagerDashboardState extends State<WorldManagerDashboard>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<WorldItem> _worlds = [];
  WorldItem? _selectedWorld;
  String? _customPath;

  List<PackEntry> _activeBehaviorPacks = [];
  List<PackEntry> _activeResourcePacks = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initStorage();
  }

  Future<void> _initStorage() async {
    if (Platform.isAndroid) {
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        await Permission.manageExternalStorage.request();
      }
    }
    _loadWorlds();
  }

  String _getBaseMojangPath() {
    if (_customPath != null) return _customPath!;
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Android/data/com.mojang.minecraftpe/files/games/com.mojang';
    } else if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      return '$localAppData\\Packages\\Microsoft.MinecraftUWP_8wekyb3d8bbwe\\LocalState\\games\\com.mojang';
    }
    return '';
  }

  void _loadWorlds() {
    final basePath = _getBaseMojangPath();
    if (basePath.isEmpty) return;

    final worldsDir = Directory('$basePath/minecraftWorlds');
    if (!worldsDir.existsSync()) {
      setState(() {
        _worlds = [];
        _activeBehaviorPacks = [];
        _activeResourcePacks = [];
      });
      return;
    }

    final found = <WorldItem>[];
    for (var entity in worldsDir.listSync()) {
      if (entity is Directory) {
        String worldName = entity.path.split(Platform.pathSeparator).last;
        final nameFile = File('${entity.path}/levelname.txt');
        if (nameFile.existsSync()) {
          try {
            worldName = nameFile.readAsStringSync().trim();
          } catch (_) {}
        }
        found.add(WorldItem(
          id: entity.path.split(Platform.pathSeparator).last,
          name: worldName,
          directory: entity,
        ));
      }
    }

    setState(() {
      _worlds = found;
      if (_worlds.isNotEmpty) {
        _selectedWorld = _worlds.first;
        _inspectWorldPacks();
      }
    });
  }

  void _inspectWorldPacks() {
    if (_selectedWorld == null) return;

    _activeBehaviorPacks = _readPacksFromFile(
      '${_selectedWorld!.directory.path}/world_behavior_packs.json',
      'behavior_packs',
    );
    _activeResourcePacks = _readPacksFromFile(
      '${_selectedWorld!.directory.path}/world_resource_packs.json',
      'resource_packs',
    );
    setState(() {});
  }

  List<PackEntry> _readPacksFromFile(String jsonPath, String globalFolder) {
    final file = File(jsonPath);
    if (!file.existsSync()) return [];

    try {
      final content = jsonDecode(file.readAsStringSync()) as List;
      final basePath = _getBaseMojangPath();
      final globalDir = Directory('$basePath/$globalFolder');

      return content.map((entry) {
        final uuid = entry['pack_id'] ?? '';
        final List<int> currentVer = List<int>.from(entry['version'] ?? [1, 0, 0]);
        String packName = uuid;
        bool hasUpdate = false;
        List<int>? newestVer;

        if (globalDir.existsSync()) {
          for (var packDir in globalDir.listSync()) {
            if (packDir is Directory) {
              final manifestFile = File('${packDir.path}/manifest.json');
              if (manifestFile.existsSync()) {
                try {
                  final manifest = jsonDecode(manifestFile.readAsStringSync());
                  final header = manifest['header'];
                  if (header != null && header['uuid'] == uuid) {
                    packName = header['name'] ?? packName;
                    final manifestVer = List<int>.from(header['version'] ?? [1, 0, 0]);
                    if (_isNewer(manifestVer, currentVer)) {
                      hasUpdate = true;
                      newestVer = manifestVer;
                    }
                  }
                } catch (_) {}
              }
            }
          }
        }

        return PackEntry(
          uuid: uuid,
          version: currentVer,
          name: packName,
          updateAvailable: hasUpdate,
          latestVersion: newestVer,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  bool _isNewer(List<int> candidate, List<int> current) {
    for (int i = 0; i < candidate.length && i < current.length; i++) {
      if (candidate[i] > current[i]) return true;
      if (candidate[i] < current[i]) return false;
    }
    return candidate.length > current.length;
  }

  void _savePacksToFile(String jsonPath, List<PackEntry> packs) {
    final file = File(jsonPath);
    final data = packs.map((p) => p.toJson()).toList();
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  }

  void _updatePackVersion(PackEntry pack, bool isBehavior) {
    setState(() {
      pack.version = pack.latestVersion!;
      pack.updateAvailable = false;
    });

    if (_selectedWorld != null) {
      final fileName = isBehavior ? 'world_behavior_packs.json' : 'world_resource_packs.json';
      final list = isBehavior ? _activeBehaviorPacks : _activeResourcePacks;
      _savePacksToFile('${_selectedWorld!.directory.path}/$fileName', list);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Updated ${pack.name} to version ${pack.version.join('.')}!'),
        backgroundColor: const Color(0xFF107C41),
      ),
    );
  }

  void _autoSortDependencies(bool isBehavior) {
    final basePath = _getBaseMojangPath();
    final globalFolder = isBehavior ? 'behavior_packs' : 'resource_packs';
    final globalDir = Directory('$basePath/$globalFolder');
    final currentList = isBehavior ? _activeBehaviorPacks : _activeResourcePacks;

    if (currentList.isEmpty || !globalDir.existsSync()) return;

    final Map<String, List<String>> dependencyGraph = {};

    for (var pack in currentList) {
      dependencyGraph[pack.uuid] = [];
      for (var dir in globalDir.listSync()) {
        if (dir is Directory) {
          final manifestFile = File('${dir.path}/manifest.json');
          if (manifestFile.existsSync()) {
            try {
              final manifest = jsonDecode(manifestFile.readAsStringSync());
              if (manifest['header'] != null && manifest['header']['uuid'] == pack.uuid) {
                if (manifest['dependencies'] != null) {
                  for (var dep in manifest['dependencies']) {
                    if (dep['uuid'] != null) {
                      dependencyGraph[pack.uuid]!.add(dep['uuid']);
                    }
                  }
                }
              }
            } catch (_) {}
          }
        }
      }
    }

    setState(() {
      currentList.sort((a, b) {
        if (dependencyGraph[b.uuid]?.contains(a.uuid) ?? false) {
          return -1;
        }
        if (dependencyGraph[a.uuid]?.contains(b.uuid) ?? false) {
          return 1;
        }
        return 0;
      });
    });

    if (_selectedWorld != null) {
      final fileName = isBehavior ? 'world_behavior_packs.json' : 'world_resource_packs.json';
      _savePacksToFile('${_selectedWorld!.directory.path}/$fileName', currentList);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Auto-sorted ${isBehavior ? 'behavior' : 'resource'} packs by dependency order!'),
        backgroundColor: const Color(0xFF107C41),
      ),
    );
  }

  Future<void> _pickCustomFolder() async {
    String? selected = await FilePicker.platform.getDirectoryPath();
    if (selected != null) {
      setState(() => _customPath = selected);
      _loadWorlds();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF16191F),
        elevation: 0,
        title: const Text('BEDROCKSMITH', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Select custom com.mojang folder',
            onPressed: _pickCustomFolder,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF52B788)),
            onPressed: _loadWorlds,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF107C41),
          tabs: [
            Tab(text: 'Behavior Packs (${_activeBehaviorPacks.length})'),
            Tab(text: 'Resource Packs (${_activeResourcePacks.length})'),
          ],
        ),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF1E232B),
            child: Row(
              children: [
                const Icon(Icons.public, color: Color(0xFF52B788)),
                const SizedBox(width: 12),
                const Text('World:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                Expanded(
                  child: _worlds.isEmpty
                      ? const Text('No worlds detected in com.mojang', style: TextStyle(color: Colors.white54))
                      : DropdownButtonHideUnderline(
                          child: DropdownButton<WorldItem>(
                            value: _selectedWorld,
                            dropdownColor: const Color(0xFF262C36),
                            isExpanded: true,
                            items: _worlds.map((w) {
                              return DropdownMenuItem(
                                value: w,
                                child: Text(w.name, overflow: TextOverflow.ellipsis),
                              );
                            }).toList(),
                            onChanged: (val) {
                              setState(() {
                                _selectedWorld = val;
                                _inspectWorldPacks();
                              });
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFF16191F),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF262C36),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    icon: const Icon(Icons.auto_awesome, size: 16, color: Color(0xFF52B788)),
                    label: const Text('AUTO-SORT ORDER', style: TextStyle(fontSize: 12)),
                    onPressed: () => _autoSortDependencies(_tabController.index == 0),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Hold & drag to manually reorder',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildReorderablePackList(_activeBehaviorPacks, true),
                _buildReorderablePackList(_activeResourcePacks, false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReorderablePackList(List<PackEntry> packs, bool isBehavior) {
    if (packs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.layers_clear, size: 44, color: Colors.white24),
              const SizedBox(height: 10),
              Text(
                'No active ${isBehavior ? 'behavior' : 'resource'} packs applied to this world.',
                style: const TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Select com.mojang folder manually'),
                onPressed: _pickCustomFolder,
              ),
            ],
          ),
        ),
      );
    }

    return ReorderableListView.builder(
      itemCount: packs.length,
      padding: const EdgeInsets.symmetric(vertical: 8),
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex -= 1;
          final item = packs.removeAt(oldIndex);
          packs.insert(newIndex, item);
        });

        if (_selectedWorld != null) {
          final fileName = isBehavior ? 'world_behavior_packs.json' : 'world_resource_packs.json';
          _savePacksToFile('${_selectedWorld!.directory.path}/$fileName', packs);
        }
      },
      itemBuilder: (context, index) {
        final pack = packs[index];
        return Card(
          key: ValueKey(pack.uuid),
          color: const Color(0xFF1E232B),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: const Color(0xFF262C36),
              child: Text('${index + 1}', style: const TextStyle(color: Color(0xFF52B788))),
            ),
            title: Text(pack.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Installed: v${pack.version.join('.')}', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                if (pack.updateAvailable)
                  Text(
                    'Newer version: v${pack.latestVersion?.join('.')}',
                    style: const TextStyle(fontSize: 12, color: Colors.amberAccent, fontWeight: FontWeight.bold),
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (pack.updateAvailable)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF107C41),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    ),
                    icon: const Icon(Icons.upgrade, size: 16),
                    label: const Text('REPLACE', style: TextStyle(fontSize: 11)),
                    onPressed: () => _updatePackVersion(pack, isBehavior),
                  ),
                const SizedBox(width: 8),
                const Icon(Icons.drag_handle, color: Colors.white38),
              ],
            ),
          ),
        );
      },
    );
  }
}