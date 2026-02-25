import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SessionManager()),
      ],
      child: const ModbusMobileApp(),
    ),
  );
}

// ─── DATA MODELS ────────────────────────────────────────────────────────────

class LogEntry {
  final DateTime timestamp;
  final String message;
  final String tag;
  final String? source;

  LogEntry({required this.timestamp, required this.message, this.tag = "data", this.source});

  String get timeString => 
      "${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}";
}

class WriteEntry {
  String label;
  int address;
  String writeType;
  List<int> values;
  WriteEntry({required this.label, required this.address, required this.writeType, required this.values});
}

class ReadResultRow {
  final String label;
  final int address;
  final int value;
  final bool isBitType;
  ReadResultRow({this.label = "", required this.address, required this.value, this.isBitType = false});
}

class ModbusSession {
  final String id = UniqueKey().toString();
  String label;
  String host;
  int port;
  int defaultUnitId;
  ModbusClientTcp? client;
  bool isConnected = false;
  
  List<LogEntry> logs = [];
  List<WriteEntry> writeEntries = [];
  List<ReadResultRow> lastReadResults = [];

  bool isReadPolling = false;
  double readInterval = 1.0;
  Timer? readTimer;

  bool isWritePolling = false;
  double writeInterval = 1.0;
  Timer? writeTimer;

  bool isMultiWritePolling = false;
  double multiWriteInterval = 1.0;
  Timer? multiWriteTimer;

  ModbusSession({this.label = "New PLC", this.host = "192.168.1.10", this.port = 502, this.defaultUnitId = 1});
}

// ─── STATE MANAGEMENT (THE ENGINE) ──────────────────────────────────────────

class SessionManager extends ChangeNotifier {
  final List<ModbusSession> _sessions = [];
  final List<LogEntry> globalLogs = [];
  
  List<ModbusSession> get sessions => _sessions;

  void addSession(ModbusSession session) {
    _sessions.add(session);
    _globalLog("Session '${session.label}' added.", "info");
    notifyListeners();
  }

  void removeSession(ModbusSession session) {
    disconnect(session);
    _sessions.remove(session);
    _globalLog("Session '${session.label}' removed.", "warn");
    notifyListeners();
  }

  void _sessionLog(ModbusSession session, String message, String tag) {
    final entry = LogEntry(timestamp: DateTime.now(), message: message, tag: tag, source: session.label);
    session.logs.add(entry);
    if (session.logs.length > 500) session.logs.removeAt(0); 
    _globalLog(message, tag, source: session.label);
    notifyListeners();
  }

  void _globalLog(String message, String tag, {String? source}) {
    final entry = LogEntry(timestamp: DateTime.now(), message: message, tag: tag, source: source);
    globalLogs.add(entry);
    if (globalLogs.length > 1000) globalLogs.removeAt(0);
    notifyListeners();
  }

  Future<void> connect(ModbusSession session) async {
    if (session.isConnected) return;
    session.client = ModbusClientTcp(session.host, serverPort: session.port);
    _sessionLog(session, "Connecting to ${session.host}:${session.port}...", "info");
    
    try {
      await session.client!.connect();
      session.isConnected = true;
      _sessionLog(session, "Connected.", "ok");
    } catch (e) {
      session.isConnected = false;
      _sessionLog(session, "Connection failed: $e", "error");
    }
    notifyListeners();
  }

  Future<void> disconnect(ModbusSession session) async {
    _stopReadPolling(session);
    _stopWritePolling(session);
    _stopMultiWritePolling(session);
    
    session.client?.disconnect();
    session.isConnected = false;
    _sessionLog(session, "Disconnected.", "warn");
    notifyListeners();
  }

  Future<void> executeRead(ModbusSession session, int address, int count, int unitId, String type) async {
    if (!session.isConnected) {
      _sessionLog(session, "Cannot read: Not connected.", "error");
      return;
    }
    try {
      bool isBit = type == "Coils" || type == "Discrete Inputs";
      
      if (isBit && count > 2000) throw Exception("Max 2000 coils per request");
      if (!isBit && count > 125) throw Exception("Max 125 registers per request");

      List<ModbusElement> elements = [];
      if (type == "Holding Registers") {
        for (int i = 0; i < count; i++) {
          elements.add(ModbusUint16Register(name: "R${address + i}", type: ModbusElementType.holdingRegister, address: address + i));
        }
      } else if (type == "Coils") {
        for (int i = 0; i < count; i++) {
          elements.add(ModbusCoil(name: "C${address + i}", address: address + i));
        }
      } else {
        throw Exception("Type not yet mapped in client.");
      }

      var group = ModbusElementsGroup(elements);
      await session.client!.send(group.getReadRequest());
      
      session.lastReadResults.clear();
      for (int i = 0; i < count; i++) {
        var el = group[i];
        int val = el.value is bool ? (el.value == true ? 1 : 0) : (el.value as int? ?? 0);
        session.lastReadResults.add(ReadResultRow(address: address + i, value: val, isBitType: isBit));
      }
      
      _sessionLog(session, "✓ $count value(s) read from addr $address", "ok");
    } catch (e) {
      _sessionLog(session, "Read exception: $e", "error");
    }
    notifyListeners();
  }

  Future<void> executeMultiWrite(ModbusSession session, int unitId) async {
    if (!session.isConnected) return;
    int okCount = 0;
    _sessionLog(session, "MULTI-WRITE: sending ${session.writeEntries.length} entries", "info");

    for (var entry in session.writeEntries) {
      if (!session.isConnected) break;
      try {
        if (entry.writeType == "Holding Register") {
          var reg = ModbusUint16Register(name: entry.label, type: ModbusElementType.holdingRegister, address: entry.address);
          await session.client!.send(reg.getWriteRequest(entry.values[0]));
        } else if (entry.writeType == "Coil") {
          var coil = ModbusCoil(name: entry.label, address: entry.address);
          await session.client!.send(coil.getWriteRequest(entry.values[0] != 0));
        }
        _sessionLog(session, "  ✓ addr=${entry.address} [${entry.label}]: ${entry.values}", "ok");
        okCount++;
      } catch (e) {
        _sessionLog(session, "  ✗ addr=${entry.address} [${entry.label}]: exception: $e", "error");
      }
    }
    _sessionLog(session, "Multi-write complete: $okCount/${session.writeEntries.length} succeeded.", okCount == session.writeEntries.length ? "ok" : "warn");
    notifyListeners();
  }

  void addWriteEntry(ModbusSession session, WriteEntry entry) {
    session.writeEntries.add(entry);
    notifyListeners();
  }

  void removeWriteEntry(ModbusSession session, WriteEntry entry) {
    session.writeEntries.remove(entry);
    notifyListeners();
  }

  void toggleReadPolling(ModbusSession session, int address, int count, int unitId, String type) {
    session.isReadPolling ? _stopReadPolling(session) : _startReadPolling(session, address, count, unitId, type);
  }

  void _startReadPolling(ModbusSession session, int address, int count, int unitId, String type) {
    if (!session.isConnected) return;
    double safeInterval = session.readInterval < 0.1 ? 0.1 : session.readInterval; 
    session.isReadPolling = true;
    _sessionLog(session, "Read polling started (${safeInterval}s).", "info");
    
    session.readTimer = Timer.periodic(Duration(milliseconds: (safeInterval * 1000).toInt()), (timer) async {
      if (!session.isConnected) { _stopReadPolling(session); return; }
      await executeRead(session, address, count, unitId, type);
    });
    notifyListeners();
  }

  void _stopReadPolling(ModbusSession session) {
    session.readTimer?.cancel();
    session.isReadPolling = false;
    notifyListeners();
  }

  void toggleWritePolling(ModbusSession s) => s.isWritePolling ? _stopWritePolling(s) : _startWritePolling(s);
  void _startWritePolling(ModbusSession s) { /* Implementation follows same pattern as Read */ }
  void _stopWritePolling(ModbusSession s) { s.writeTimer?.cancel(); s.isWritePolling = false; notifyListeners(); }

  void toggleMultiWritePolling(ModbusSession s, int unitId) => s.isMultiWritePolling ? _stopMultiWritePolling(s) : _startMultiWritePolling(s, unitId);
  void _startMultiWritePolling(ModbusSession s, int unitId) {
    if (!s.isConnected || s.writeEntries.isEmpty) return;
    double safeInterval = s.multiWriteInterval < 0.1 ? 0.1 : s.multiWriteInterval;
    s.isMultiWritePolling = true;
    _sessionLog(s, "Write All polling started (${safeInterval}s).", "info");
    
    s.multiWriteTimer = Timer.periodic(Duration(milliseconds: (safeInterval * 1000).toInt()), (t) async {
      if (!s.isConnected) { _stopMultiWritePolling(s); return; }
      await executeMultiWrite(s, unitId);
    });
    notifyListeners();
  }
  void _stopMultiWritePolling(ModbusSession s) { s.multiWriteTimer?.cancel(); s.isMultiWritePolling = false; notifyListeners(); }
}

// ─── UI COMPONENTS ──────────────────────────────────────────────────────────

class ModbusMobileApp extends StatelessWidget {
  const ModbusMobileApp({super.key}); 
  
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Modbus Matrix Client',
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF00FF41),
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Color(0xFF00FF41),
          elevation: 0,
          shape: Border(bottom: BorderSide(color: Color(0xFF008F11), width: 1)),
        ),
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: 'monospace',
          bodyColor: const Color(0xFF00FF41),
          displayColor: const Color(0xFF00FF41),
        ),
        cardTheme: const CardThemeData(
          color: Colors.black,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Color(0xFF008F11), width: 1),
            borderRadius: BorderRadius.zero,
          ),
          margin: EdgeInsets.all(4),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          labelStyle: TextStyle(color: Color(0xFF008F11)),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF008F11)),
            borderRadius: BorderRadius.zero,
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF00FF41), width: 2),
            borderRadius: BorderRadius.zero,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF003B00),
            foregroundColor: const Color(0xFF00FF41),
            shape: const RoundedRectangleBorder(
              side: BorderSide(color: Color(0xFF00FF41)),
              borderRadius: BorderRadius.zero,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF00FF41),
          ),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key}); 

  Future<void> _showAddConnectionDialog(BuildContext context, SessionManager manager) async {
    final TextEditingController labelController = TextEditingController(text: "New_Node");
    final TextEditingController hostController = TextEditingController();
    final TextEditingController portController = TextEditingController(text: "502");

    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.black,
          shape: const RoundedRectangleBorder(
            side: BorderSide(color: Color(0xFF00FF41), width: 2),
            borderRadius: BorderRadius.zero,
          ),
          title: const Text('INITIALIZE CONNECTION', style: TextStyle(color: Color(0xFF00FF41), fontFamily: 'monospace')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: labelController, decoration: const InputDecoration(labelText: 'Label'), style: const TextStyle(color: Color(0xFF00FF41))),
                const SizedBox(height: 8),
                TextField(controller: hostController, decoration: const InputDecoration(labelText: 'Host / IP'), style: const TextStyle(color: Color(0xFF00FF41))),
                const SizedBox(height: 8),
                TextField(
                  controller: portController, 
                  decoration: const InputDecoration(labelText: 'Port'), 
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Color(0xFF00FF41)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ABORT', style: TextStyle(color: Color(0xFF008F11))),
            ),
            ElevatedButton(
              onPressed: () {
                final String label = labelController.text.trim();
                final String host = hostController.text.trim();
                final int port = int.tryParse(portController.text.trim()) ?? 502;
                
                if (host.isNotEmpty) {
                  manager.addSession(ModbusSession(
                    label: label.isEmpty ? "New_Node" : label, 
                    host: host, 
                    port: port
                  ));
                  Navigator.pop(context);
                }
              },
              child: const Text('EXECUTE'),
            ),
          ],
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<SessionManager>();
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('MODBUS_ICS_LINK', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_box_outlined), 
            onPressed: () => _showAddConnectionDialog(context, manager)
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: ListView.builder(
              itemCount: manager.sessions.length,
              itemBuilder: (context, index) {
                final session = manager.sessions[index];
                return Card(
                  child: ListTile(
                    leading: Text(
                      session.isConnected ? "[ON]" : "[OFF]", 
                      style: TextStyle(
                        color: session.isConnected ? const Color(0xFF00FF41) : const Color(0xFF008F11),
                        fontWeight: FontWeight.bold
                      )
                    ),
                    title: Text(session.label, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text("${session.host}:${session.port}"),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => session.isConnected ? manager.disconnect(session) : manager.connect(session),
                          child: Text(
                            session.isConnected ? "DISCONNECT" : "CONNECT", 
                            style: TextStyle(color: session.isConnected ? Colors.redAccent : const Color(0xFF00FF41))
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.terminal, color: Color(0xFF00FF41)),
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SessionOpsScreen(session: session))),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Expanded(
            flex: 1,
            child: LogViewerWidget(title: "GLOBAL_STREAM", logs: manager.globalLogs, isGlobal: true),
          )
        ],
      ),
    );
  }
}

class SessionOpsScreen extends StatelessWidget {
  final ModbusSession session;
  const SessionOpsScreen({super.key, required this.session}); 

  Future<void> _showWriteEntryDialog(BuildContext context, SessionManager manager, {WriteEntry? existingEntry}) async {
    final TextEditingController labelController = TextEditingController(text: existingEntry?.label ?? "Var_X");
    final TextEditingController addressController = TextEditingController(text: existingEntry?.address.toString() ?? "0");
    final TextEditingController valueController = TextEditingController(text: existingEntry?.values.join(',') ?? "0");
    String selectedType = existingEntry?.writeType ?? "Holding Register";

    return showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: Colors.black,
              shape: const RoundedRectangleBorder(
                side: BorderSide(color: Color(0xFF00FF41), width: 2),
                borderRadius: BorderRadius.zero,
              ),
              title: Text(existingEntry == null ? 'ADD WRITE ENTRY' : 'EDIT WRITE ENTRY', style: const TextStyle(color: Color(0xFF00FF41), fontFamily: 'monospace')),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: labelController, decoration: const InputDecoration(labelText: 'Label'), style: const TextStyle(color: Color(0xFF00FF41))),
                    const SizedBox(height: 8),
                    TextField(controller: addressController, decoration: const InputDecoration(labelText: 'Address'), keyboardType: TextInputType.number, style: const TextStyle(color: Color(0xFF00FF41))),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      dropdownColor: Colors.black,
                      value: selectedType,
                      style: const TextStyle(color: Color(0xFF00FF41), fontFamily: 'monospace'),
                      decoration: const InputDecoration(labelText: 'Type'),
                      items: ["Holding Register", "Coil"].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                      onChanged: (val) {
                        if (val != null) setState(() => selectedType = val);
                      },
                    ),
                    const SizedBox(height: 8),
                    TextField(controller: valueController, decoration: const InputDecoration(labelText: 'Value(s) (comma separated)'), style: const TextStyle(color: Color(0xFF00FF41))),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('ABORT', style: TextStyle(color: Color(0xFF008F11))),
                ),
                ElevatedButton(
                  onPressed: () {
                    int address = int.tryParse(addressController.text) ?? 0;
                    List<int> values = valueController.text.split(',').map((e) => int.tryParse(e.trim()) ?? 0).toList();
                    if (values.isEmpty) values = [0];

                    if (existingEntry != null) {
                      manager.removeWriteEntry(session, existingEntry);
                    }
                    manager.addWriteEntry(session, WriteEntry(
                      label: labelController.text,
                      address: address,
                      writeType: selectedType,
                      values: values,
                    ));
                    Navigator.pop(context);
                  },
                  child: const Text('SAVE'),
                ),
              ],
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    // Add the watcher here so the persistent Log updates when state changes
    final manager = context.watch<SessionManager>();

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text("> ${session.label}"),
          bottom: const TabBar(
            indicatorColor: Color(0xFF00FF41),
            labelColor: Color(0xFF00FF41),
            unselectedLabelColor: Color(0xFF008F11),
            tabs: [Tab(text: "READ"), Tab(text: "WRITE"), Tab(text: "POLL")],
          ),
        ),
        body: Column(
          children: [
            // The active tab takes up the remaining upper space
            Expanded(
              child: TabBarView(
                children: [
                  _buildReadTab(context, manager),
                  _buildWriteTab(context, manager),
                  _buildPollTab(context, manager),
                ],
              ),
            ),
            // The Session Log is permanently pinned to the bottom
            SizedBox(
              height: 150, 
              child: LogViewerWidget(title: "SESSION_LOG", logs: session.logs)
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReadTab(BuildContext context, SessionManager manager) {
    int tempAddr = 0; int tempCount = 10;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(child: TextField(decoration: const InputDecoration(labelText: "Address"), keyboardType: TextInputType.number, onChanged: (v) => tempAddr = int.tryParse(v) ?? 0)),
              const SizedBox(width: 8),
              Expanded(child: TextField(decoration: const InputDecoration(labelText: "Count"), keyboardType: TextInputType.number, onChanged: (v) => tempCount = int.tryParse(v) ?? 1)),
              IconButton(icon: const Icon(Icons.download, color: Color(0xFF00FF41)), onPressed: () => manager.executeRead(session, tempAddr, tempCount, session.defaultUnitId, "Holding Registers")),
            ],
          ),
        ),
        Expanded(child: ReadResultsTable(results: session.lastReadResults)),
      ],
    );
  }

  Widget _buildWriteTab(BuildContext context, SessionManager manager) {
    return SingleChildScrollView(
      child: Column(
        children: [
          ListTile(
            title: const Text("MULTI-ADDRESS WRITE"),
            trailing: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF500000), foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)),
              onPressed: () => manager.executeMultiWrite(session, session.defaultUnitId), 
              child: const Text("EXECUTE_ALL")
            ),
          ),
          ...session.writeEntries.map((e) => ListTile(
            title: Text("${e.writeType} @ ${e.address}"),
            subtitle: Text("Values: ${e.values.join(', ')}"),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit, color: Color(0xFF00FF41)), 
                  onPressed: () => _showWriteEntryDialog(context, manager, existingEntry: e)
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.redAccent), 
                  onPressed: () => manager.removeWriteEntry(session, e)
                ),
              ],
            ),
          )),
          TextButton(
            onPressed: () => _showWriteEntryDialog(context, manager), 
            child: const Text("+ ADD WRITE ENTRY")
          ),
          const Divider(color: Color(0xFF008F11)),
          const FormatConverterWidget(),
        ],
      ),
    );
  }

  Widget _buildPollTab(BuildContext context, SessionManager manager) {
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Card(
          child: ListTile(
            title: const Text("AUTO_READ_LOOP"),
            subtitle: Text("Interval: ${session.readInterval}s"),
            trailing: ElevatedButton(
              style: session.isReadPolling ? ElevatedButton.styleFrom(backgroundColor: const Color(0xFF500000), foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)) : null,
              onPressed: () => manager.toggleReadPolling(session, 0, 10, session.defaultUnitId, "Holding Registers"),
              child: Text(session.isReadPolling ? "HALT" : "INITIATE"),
            ),
          ),
        ),
        Card(
          child: ListTile(
            title: const Text("AUTO_WRITE_LOOP"),
            subtitle: Text("Interval: ${session.multiWriteInterval}s"),
            trailing: ElevatedButton(
              style: session.isMultiWritePolling ? ElevatedButton.styleFrom(backgroundColor: const Color(0xFF500000), foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)) : null,
              onPressed: () => manager.toggleMultiWritePolling(session, session.defaultUnitId),
              child: Text(session.isMultiWritePolling ? "HALT" : "INITIATE"),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── UTILITY WIDGETS ────────────────────────────────────────────────────────

class ReadResultsTable extends StatelessWidget {
  final List<ReadResultRow> results;
  const ReadResultsTable({super.key, required this.results}); 
  
  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) return const Center(child: Text("NO_DATA_FOUND", style: TextStyle(color: Color(0xFF008F11))));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowColor: WidgetStateProperty.all(const Color(0xFF002200)),
        columns: const [DataColumn(label: Text('ADDR')), DataColumn(label: Text('DEC')), DataColumn(label: Text('HEX')), DataColumn(label: Text('BIN'))],
        rows: results.map((r) => DataRow(cells: [
          DataCell(Text(r.address.toString())),
          DataCell(Text(r.value.toString())),
          DataCell(Text("0x${r.value.toRadixString(16).padLeft(4, '0')}")),
          DataCell(Text(r.value.toRadixString(2).padLeft(16, '0'))),
        ])).toList(),
      ),
    );
  }
}

class FormatConverterWidget extends StatefulWidget {
  const FormatConverterWidget({super.key}); 
  
  @override 
  State<FormatConverterWidget> createState() => _FormatConverterWidgetState(); 
}

class _FormatConverterWidgetState extends State<FormatConverterWidget> {
  final TextEditingController _inputController = TextEditingController(text: "0");
  String _result = "";
  
  void _doFmt(String fmt) {
    int? val = int.tryParse(_inputController.text);
    if (val == null) { setState(() { _result = "ERR: INVALID_INPUT"; }); return; }
    setState(() {
      if (fmt == "hex") _result = "0x${val.toRadixString(16).padLeft(4, '0')}";
      if (fmt == "dec") _result = "$val";
      if (fmt == "bin") _result = val.toRadixString(2).padLeft(16, '0');
    });
  }
  
  @override 
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("DATA_FORMAT_UTILITY", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(controller: _inputController, decoration: const InputDecoration(labelText: "INPUT_VALUE")),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: const Color(0xFF002200),
              child: Text("> $_result", style: const TextStyle(fontSize: 16)),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(onPressed: () => _doFmt("hex"), child: const Text("TO_HEX")),
                ElevatedButton(onPressed: () => _doFmt("dec"), child: const Text("TO_DEC")),
                ElevatedButton(onPressed: () => _doFmt("bin"), child: const Text("TO_BIN")),
              ],
            )
          ],
        ),
      ),
    );
  }
}

class LogViewerWidget extends StatelessWidget {
  final String title;
  final List<LogEntry> logs;
  final bool isGlobal;
  const LogViewerWidget({super.key, required this.title, required this.logs, this.isGlobal = false}); 

  Color _getColor(String tag) {
    if (tag == 'ok') return const Color(0xFF00FF41);
    if (tag == 'error') return Colors.redAccent;
    if (tag == 'warn') return Colors.yellowAccent;
    return const Color(0xFF008F11); // Info/Data
  }

  @override Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: const Color(0xFF002200),
            padding: const EdgeInsets.all(8), 
            child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))
          ),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: logs.length,
              itemBuilder: (context, i) {
                final log = logs[logs.length - 1 - i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                  child: Text("[${log.timeString}] ${isGlobal && log.source != null ? '[${log.source}] ' : ''}${log.message}", 
                    style: TextStyle(color: _getColor(log.tag), fontSize: 11)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
