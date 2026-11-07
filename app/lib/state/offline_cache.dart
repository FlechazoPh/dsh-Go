// iOS remote-only build: on-disk cache so the app can show the last known
// conversations after iOS suspends or kills it in the background.
//
// The in-memory ReadListCache is explicitly process-local ("No persistence"),
// and ChatTranscript only lives while its ChatController is kept alive (60s).
// After a background kill both are gone, so a foreground return shows a blank
// "connecting" screen until the SSH link reconnects and the server answers.
// This cache mirrors the already-projected display data to JSON files under
// the app support directory and reads it back synchronously on the offline
// path, so the drawer and the chat page can show stale-but-labelled content
// while the reconnect runs in the background.
//
// What is stored (display fields only, never credentials):
// - one file per (host, workspace) with the drawer's CachedSessions projection
//   (session id, title, updated time);
// - one file per (host, session) with the durable transcript events of that
//   conversation (seq/time/type/data), capped to the most recent events.
// Host keys isolate the data: a file is only read back for the host (and
// workspace) it was written for. Corrupt, oversized or expired files are
// dropped, never thrown to the UI.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:path_provider/path_provider.dart';

import 'read_list_data.dart';

/// Durable transcript events restored from disk for one session.
class CachedMessages {
  const CachedMessages({
    required this.events,
    required this.cursor,
    required this.hasMore,
    required this.savedAt,
  });

  /// Durable events in seq order (streaming drafts and pending prompts are
  /// never stored; they are transient and replayed by the server).
  final List<SessionLogEvent> events;

  /// Seq of the last durable event at the cut (-1 for an empty log).
  final int cursor;

  /// Older history exists before [events].first; page with history() online.
  final bool hasMore;

  final DateTime savedAt;
}

/// On-disk mirror of the display caches. All methods are safe to call from
/// the UI path: reads are synchronous and return null on any failure, writes
/// are fire-and-forget and swallow their errors.
class OfflineCache {
  OfflineCache({this._rootOverride, DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// Production instance; the app warms it up in main() before runApp.
  static final OfflineCache instance = OfflineCache();

  /// Host key for the disk cache: 'kind:id', the same format as
  /// CurrentSessionController._hostKey (keep in sync).
  static String hostKey(String kindName, String id) => '$kindName:$id';

  static const _dirName = 'offline-cache';

  /// Session lists stay useful for a day; a stale list is still labelled
  /// offline and is replaced as soon as the server answers.
  static const sessionsTtl = Duration(hours: 24);

  /// Message history is inherently historical; a week-old transcript is
  /// still worth showing with the cache label.
  static const messagesTtl = Duration(days: 7);

  /// Same ceiling as the in-memory ReadListCache entry budget.
  static const maxSessionBytes = 256 * 1024;

  /// One conversation snapshot at most; the tail window is truncated to fit.
  static const maxMessageBytes = 512 * 1024;

  /// Most recent durable events kept per conversation.
  static const maxMessageEvents = 200;

  /// Oldest message files are pruned past this many conversations.
  static const maxChatFiles = 20;

  /// Oldest session-list files are pruned past this many (host, workspace)
  /// projections.
  static const maxSessionFiles = 32;

  final Future<Directory> Function()? _rootOverride;
  final DateTime Function() _now;
  Directory? _root;

  /// Last successfully written content per file, so repeated identical
  /// projections (every drawer rebuild) do not rewrite the file.
  final _lastWritten = <String, String>{};

  /// Resolves the cache directory. Safe to call repeatedly; a failure leaves
  /// the cache disabled (all reads return null, all writes are skipped).
  Future<void> warmUp() async {
    if (_root != null) return;
    try {
      _root = await (_rootOverride?.call() ?? getApplicationSupportDirectory());
    } catch (_) {
      _root = null;
    }
  }

  Directory? get _dir {
    final root = _root;
    return root == null ? null : Directory('${root.path}/$_dirName');
  }

  String _fileName(String prefix, String key) =>
      '$prefix-${sha256.convert(utf8.encode(key)).toString().substring(0, 32)}.json';

  Future<void> _writeAtomic(File target, String content) async {
    final name = target.path.split('/').last;
    if (_lastWritten[name] == content) return;
    try {
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.tmp-${_now().microsecondsSinceEpoch}');
      try {
        await tmp.writeAsString(content, flush: true);
        await tmp.rename(target.path);
        _lastWritten[name] = content;
      } catch (_) {
        try {
          await tmp.delete();
        } catch (_) {}
        rethrow;
      }
    } catch (_) {
      // Disk full, no permission, or the app was killed mid-write: the
      // cache is best-effort and must never surface an error.
    }
  }

  String? _readSync(File file) {
    try {
      return file.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  void _drop(File file) {
    try {
      file.deleteSync();
    } catch (_) {}
  }

  Future<void> _prune(String prefix, int maxFiles) async {
    final dir = _dir;
    if (dir == null) return;
    try {
      if (!await dir.exists()) return;
      final files = <File>[];
      await for (final entry in dir.list()) {
        final name = entry.path.split('/').last;
        if (entry is File && name.startsWith(prefix) && name.endsWith('.json')) files.add(entry);
      }
      if (files.length <= maxFiles) return;
      files.sort((a, b) {
        DateTime at(File f) {
          try {
            return f.statSync().modified;
          } catch (_) {
            return DateTime.fromMillisecondsSinceEpoch(0);
          }
        }

        return at(a).compareTo(at(b));
      });
      for (final extra in files.take(files.length - maxFiles)) {
        _drop(extra);
      }
    } catch (_) {}
  }

  // ── Session lists ──────────────────────────────────────────────────────

  Future<void> saveSessions({required String hostKey, required String workspace, required CachedSessions data}) async {
    final envelope = <String, Object?>{
      'v': 1,
      'host': hostKey,
      'workspace': workspace,
      'savedAt': _now().millisecondsSinceEpoch,
      'data': data.toJson(),
    };
    String content;
    try {
      content = jsonEncode(envelope);
    } catch (_) {
      return;
    }
    if (utf8.encode(content).length > maxSessionBytes) return;
    await warmUp();
    final dir = _dir;
    if (dir == null) return;
    await _writeAtomic(
      File('${dir.path}/${_fileName('sessions', '$hostKey\n$workspace')}'),
      content,
    );
    await _prune('sessions-', maxSessionFiles);
  }

  /// Synchronous read for the offline drawer path. Returns null when there
  /// is no file, it belongs to another host/workspace, it expired, or it
  /// does not parse.
  CachedSessions? loadSessionsSync({required String hostKey, required String workspace}) {
    final dir = _dir;
    if (dir == null) return null;
    final file = File('${dir.path}/${_fileName('sessions', '$hostKey\n$workspace')}');
    final raw = _readSync(file);
    if (raw == null) return null;
    try {
      final envelope = jsonDecode(raw);
      if (envelope is! Map) return null;
      if (envelope['v'] != 1 || envelope['host'] != hostKey || envelope['workspace'] != workspace) {
        _drop(file);
        return null;
      }
      final savedAt = envelope['savedAt'];
      if (savedAt is! int ||
          _now().difference(DateTime.fromMillisecondsSinceEpoch(savedAt)) > sessionsTtl) {
        _drop(file);
        return null;
      }
      final data = CachedSessions.fromJson(envelope['data']);
      if (data == null) _drop(file);
      return data;
    } catch (_) {
      _drop(file);
      return null;
    }
  }

  // ── Conversation transcripts ───────────────────────────────────────────

  Future<void> saveMessages({
    required String hostKey,
    required String sessionId,
    required List<SessionLogEvent> events,
    required int cursor,
    required bool hasMore,
  }) async {
    var tail = events.length > maxMessageEvents ? events.sublist(events.length - maxMessageEvents) : events;
    String encode(List<SessionLogEvent> kept) => jsonEncode(<String, Object?>{
      'v': 1,
      'host': hostKey,
      'sessionId': sessionId,
      'savedAt': _now().millisecondsSinceEpoch,
      'cursor': cursor,
      'hasMore': hasMore,
      'events': [
        for (final e in kept)
          {'seq': e.seq, 'time': e.time.millisecondsSinceEpoch, 'type': e.type, 'data': e.data},
      ],
    });
    String content;
    try {
      content = encode(tail);
      // Drop the oldest events until the snapshot fits; the window stays a
      // tail, so hasMore keeps describing what is missing before it.
      while (utf8.encode(content).length > maxMessageBytes && tail.length > 1) {
        tail = tail.sublist(tail.length ~/ 2);
        content = encode(tail);
      }
      if (utf8.encode(content).length > maxMessageBytes) return;
    } catch (_) {
      return;
    }
    await warmUp();
    final dir = _dir;
    if (dir == null) return;
    await _writeAtomic(
      File('${dir.path}/${_fileName('messages', '$hostKey\n$sessionId')}'),
      content,
    );
    await _prune('messages-', maxChatFiles);
  }

  /// Synchronous read for the offline chat path. Returns null when there is
  /// no file, it belongs to another host/session, it expired, or it does not
  /// parse. Events with no usable seq are dropped.
  CachedMessages? loadMessagesSync({required String hostKey, required String sessionId}) {
    final dir = _dir;
    if (dir == null) return null;
    final file = File('${dir.path}/${_fileName('messages', '$hostKey\n$sessionId')}');
    final raw = _readSync(file);
    if (raw == null) return null;
    try {
      final envelope = jsonDecode(raw);
      if (envelope is! Map) return null;
      if (envelope['v'] != 1 || envelope['host'] != hostKey || envelope['sessionId'] != sessionId) {
        _drop(file);
        return null;
      }
      final savedAt = envelope['savedAt'];
      if (savedAt is! int ||
          _now().difference(DateTime.fromMillisecondsSinceEpoch(savedAt)) > messagesTtl) {
        _drop(file);
        return null;
      }
      final rawEvents = envelope['events'];
      if (rawEvents is! List) return null;
      final events = <SessionLogEvent>[];
      for (final rawEvent in rawEvents) {
        final event = SessionLogEvent.fromJson(rawEvent);
        if (event.seq >= 0) events.add(event);
      }
      final cursor = envelope['cursor'];
      return CachedMessages(
        events: events,
        cursor: cursor is int ? cursor : (events.isEmpty ? -1 : events.last.seq),
        hasMore: envelope['hasMore'] == true,
        savedAt: DateTime.fromMillisecondsSinceEpoch(savedAt),
      );
    } catch (_) {
      _drop(file);
      return null;
    }
  }

  /// Removes every cached file for one host (host deleted or signed out).
  Future<void> clearHost(String hostKey) async {
    await warmUp();
    final dir = _dir;
    if (dir == null) return;
    try {
      if (!await dir.exists()) return;
      await for (final entry in dir.list()) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final raw = _readSync(entry);
        if (raw == null) continue;
        try {
          final envelope = jsonDecode(raw);
          if (envelope is Map && envelope['host'] == hostKey) _drop(entry);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Removes one conversation's cached transcript (session deleted).
  Future<void> deleteMessages({required String hostKey, required String sessionId}) async {
    await warmUp();
    final dir = _dir;
    if (dir == null) return;
    _drop(File('${dir.path}/${_fileName('messages', '$hostKey\n$sessionId')}'));
  }
}
