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
    if (session.logs.length > 500) session.logs.removeAt(0); // Max 500 limit
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

  // Core Read function using the ModbusElementsGroup API
  Future<void> executeRead(ModbusSession session, int address, int count, int unitId, String type) async {
    if (!session.isConnected) {
      _sessionLog(session, "Cannot read: Not connected.", "error");
      return;
    }
    try {
      bool isBit = type == "Coils" || type == "Discrete Inputs";
      
      // Request limit checks
      if (isBit && count > 2000) throw Exception("Max 2000 coils per request");
      if (!isBit && count > 125) throw Exception("Max 125 registers per request");

      List<ModbusElement> elements = [];
      if (type == "Holding Registers") {
        for (int i = 0; i < count; i++) {
          // REQUIRES 'type' parameter
          elements.add(ModbusUint16Register(name: "R${address + i}", type: ModbusElementType.holdingRegister, address: address + i));
        }
      } else if (type == "Coils") {
        for (int i = 0; i < count; i++) {
          // DOES NOT require 'type' parameter
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

  // Multi-Address Write Loop using the ModbusElement API
  Future<void> executeMultiWrite(ModbusSession session, int unitId) async {
    if (!session.isConnected) return;
    int okCount = 0;
    _sessionLog(session, "MULTI-WRITE: sending ${session.writeEntries.length} entries", "info");

    for (var entry in session.writeEntries) {
      if (!session.isConnected) break;
      try {
        if (entry.writeType == "Holding Register") {
          // REQUIRES 'type' parameter
          var reg = ModbusUint16Register(name: entry.label, type: ModbusElementType.holdingRegister, address: entry.address);
          await session.client!.send(reg.getWriteRequest(entry.values[0]));
        } else if (entry.writeType == "Coil") {
          // DOES NOT require 'type' parameter
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

  // Helper methods to securely update the UI from the outside
  void addWriteEntry(ModbusSession session, WriteEntry entry) {
    session.writeEntries.add(entry);
    notifyListeners();
  }

  void removeWriteEntry(ModbusSession session, WriteEntry entry) {
    session.writeEntries.remove(entry);
    notifyListeners();
  }

  // Polling logic 
  void toggleReadPolling(ModbusSession session, int address, int count, int unitId, String type) {
    session.isReadPolling ? _stopReadPolling(session) : _startReadPolling(session, address, count, unitId, type);
  }

  void _startReadPolling(ModbusSession session, int address, int count, int unitId, String type) {
    if (!session.isConnected) return;
    double safeInterval = session.readInterval < 0.1 ? 0.1 : session.readInterval; // 0.1s minimum
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
      title: 'Modbus Multi-Session',
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFFE8A020),
        scaffoldBackgroundColor: const Color(0xFF0B0E0D), // Matches BG_DEEP
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF131816)),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key}); 

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<SessionManager>();
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Modbus ICS Client', style: TextStyle(color: Color(0xFFE8A020))),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: () => manager.addSession(ModbusSession())),
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
                  color: const Color(0xFF191E1C),
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: ListTile(
                    leading: Icon(Icons.circle, color: session.isConnected ? const Color(0xFF3DDC84) : Colors.grey, size: 14),
                    title: Text(session.label, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text("${session.host}:${session.port}"),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => session.isConnected ? manager.disconnect(session) : manager.connect(session),
                          child: Text(session.isConnected ? "DISCONNECT" : "CONNECT", style: TextStyle(color: session.isConnected ? Colors.red : const Color(0xFFE8A020))),
                        ),
                        IconButton(
                          icon: const Icon(Icons.settings),
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SessionOpsScreen(session: session))),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1, color: Color(0xFF1E2824)),
          Expanded(
            flex: 1,
            child: LogViewerWidget(title: "GLOBAL LOG", logs: manager.globalLogs, isGlobal: true),
          )
        ],
      ),
    );
  }
}

class SessionOpsScreen extends StatelessWidget {
  final ModbusSession session;
  const SessionOpsScreen({super.key, required this.session}); 

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(session.label),
          bottom: const TabBar(
            indicatorColor: Color(0xFFE8A020),
            labelColor: Color(0xFFE8A020),
            tabs: [Tab(text: "READ"), Tab(text: "WRITE"), Tab(text: "POLL")],
          ),
        ),
        body: TabBarView(
          children: [
            _buildReadTab(context),
            _buildWriteTab(context),
            _buildPollTab(context),
          ],
        ),
      ),
    );
  }

  Widget _buildReadTab(BuildContext context) {
    final manager = context.watch<SessionManager>();
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
              IconButton(icon: const Icon(Icons.download), onPressed: () => manager.executeRead(session, tempAddr, tempCount, session.defaultUnitId, "Holding Registers")),
            ],
          ),
        ),
        Expanded(child: ReadResultsTable(results: session.lastReadResults)),
        SizedBox(height: 150, child: LogViewerWidget(title: "SESSION LOG", logs: session.logs)),
      ],
    );
  }

  Widget _buildWriteTab(BuildContext context) {
    final manager = context.watch<SessionManager>();
    return SingleChildScrollView(
      child: Column(
        children: [
          ListTile(
            title: const Text("Multi-Address Write"),
            trailing: ElevatedButton(
              onPressed: () => manager.executeMultiWrite(session, session.defaultUnitId), 
              child: const Text("WRITE ALL")
            ),
          ),
          ...session.writeEntries.map((e) => ListTile(
            title: Text("${e.writeType} @ ${e.address}"),
            subtitle: Text("Values: ${e.values}"),
            trailing: IconButton(
              icon: const Icon(Icons.delete, color: Colors.red), 
              onPressed: () => manager.removeWriteEntry(session, e)
            ),
          )),
          TextButton(
            onPressed: () => manager.addWriteEntry(session, WriteEntry(label: "Test", address: 0, writeType: "Holding Register", values: [99])), 
            child: const Text("+ ADD DUMMY ENTRY")
          ),
          const Divider(),
          const FormatConverterWidget(),
        ],
      ),
    );
  }

  Widget _buildPollTab(BuildContext context) {
    final manager = context.watch<SessionManager>();
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        ListTile(
          title: const Text("Continuous Read"),
          subtitle: Text("Every ${session.readInterval}s"),
          trailing: ElevatedButton(
            onPressed: () => manager.toggleReadPolling(session, 0, 10, session.defaultUnitId, "Holding Registers"),
            child: Text(session.isReadPolling ? "STOP" : "START"),
          ),
        ),
        ListTile(
          title: const Text("Continuous Write All"),
          subtitle: Text("Every ${session.multiWriteInterval}s"),
          trailing: ElevatedButton(
            onPressed: () => manager.toggleMultiWritePolling(session, session.defaultUnitId),
            child: Text(session.isMultiWritePolling ? "STOP" : "START"),
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
    if (results.isEmpty) return const Center(child: Text("No data"));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [DataColumn(label: Text('Address')), DataColumn(label: Text('Dec')), DataColumn(label: Text('Hex')), DataColumn(label: Text('Bin'))],
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
    if (val == null) { setState(() { _result = "Invalid input"; }); return; }
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
          children: [
            TextField(controller: _inputController, decoration: const InputDecoration(labelText: "Format Converter Value")),
            Text(_result, style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(onPressed: () => _doFmt("hex"), child: const Text("Hex")),
                ElevatedButton(onPressed: () => _doFmt("dec"), child: const Text("Dec")),
                ElevatedButton(onPressed: () => _doFmt("bin"), child: const Text("Bin")),
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
    if (tag == 'ok') return const Color(0xFF3DDC84);
    if (tag == 'error') return const Color(0xFFFF5555);
    if (tag == 'warn') return const Color(0xFFF0C040);
    return const Color(0xFFCDD5D0);
  }

  @override Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF191E1C),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.all(8), child: Text(title, style: const TextStyle(color: Color(0xFFE8A020)))),
          Expanded(
            child: ListView.builder(
              reverse: true, // Auto-scroll to bottom behavior
              itemCount: logs.length,
              itemBuilder: (context, i) {
                final log = logs[logs.length - 1 - i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                  child: Text("[${log.timeString}] ${isGlobal && log.source != null ? '[${log.source}] ' : ''}${log.message}", 
                    style: TextStyle(color: _getColor(log.tag), fontSize: 11, fontFamily: 'monospace')),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
