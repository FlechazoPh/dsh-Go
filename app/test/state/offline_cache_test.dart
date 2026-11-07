// iOS remote-only build: on-disk conversation cache (see offline_cache.dart).
//
// Covers the round-trip (sessions + messages), host/workspace isolation,
// corrupt-file handling, TTL expiry, message truncation and pruning. The
// cache never touches the network or the live client; tests use an injected
// temp directory, so no platform channels are involved.
import 'dart:io';

import 'package:dsh_app/state/offline_cache.dart';
import 'package:dsh_app/state/read_list_data.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary row(String id, String title, int updatedMs) => SessionSummary(
  sessionId: id,
  updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedMs),
  running: false,
  blank: false,
  agentAvailable: false,
  projections: SessionProjections(-1, <String, Object?>{'title': title}),
);

CachedSessions projection(List<SessionSummary> sessions) => CachedSessions(
  sessions: sessions,
  bots: const [],
  workspaceVersion: 'v1',
  scoped: false,
  workspaceLabel: 'All',
);

Map<String, Object?> wire(int seq, String type, Map<String, Object?> data) => {
  'seq': seq,
  'time': 1000 + seq,
  'type': type,
  'data': data,
};

List<SessionLogEvent> sampleEvents() => [
  SessionLogEvent.fromJson(wire(1, 'turn/start', {'turn': 1})),
  SessionLogEvent.fromJson(
    wire(2, 'user/message', {
      'id': 'm1',
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'hello'},
      ],
      'source': {'kind': 'user'},
    }),
  ),
  SessionLogEvent.fromJson(
    wire(3, 'assistant/message', {
      'turn': 1,
      'step': 1,
      'message': {
        'id': 'm2',
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'hi there'},
        ],
      },
      'usage': null,
      'interrupted': false,
    }),
  ),
  SessionLogEvent.fromJson(wire(4, 'session/title', {'title': 'Greetings', 'source': {'kind': 'user'}})),
];

void main() {
  late Directory dir;
  late OfflineCache cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('offline_cache_test');
    cache = OfflineCache(rootOverride: () async => dir);
    await cache.warmUp();
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> theFile(String prefix) async {
    final files = await Directory('${dir.path}/offline-cache')
        .list()
        .where((e) => e is File && e.path.split('/').last.startsWith(prefix))
        .cast<File>()
        .toList();
    expect(files, hasLength(1));
    return files.single;
  }

  group('session lists', () {
    test('round-trip keeps id, title and updated time', () async {
      final data = projection([row('s1', 'First', 1000), row('s2', 'Second', 2000)]);
      await cache.saveSessions(hostKey: 'ssh:akimoto', workspace: 'all', data: data);
      final loaded = cache.loadSessionsSync(hostKey: 'ssh:akimoto', workspace: 'all');
      expect(loaded, isNotNull);
      expect(loaded!.sessions.map((s) => s.sessionId), ['s1', 's2']);
      expect(loaded.sessions.map((s) => s.title), ['First', 'Second']);
      expect(loaded.sessions.map((s) => s.updatedAt.millisecondsSinceEpoch), [1000, 2000]);
      expect(loaded.workspaceVersion, 'v1');
      expect(loaded.workspaceLabel, 'All');
      // Restored rows are display-only.
      expect(loaded.sessions.every((s) => !s.running && !s.blank && !s.agentAvailable), isTrue);
    });

    test('a host never reads another host or workspace file', () async {
      await cache.saveSessions(
        hostKey: 'ssh:akimoto',
        workspace: 'all',
        data: projection([row('s1', 'First', 1000)]),
      );
      expect(cache.loadSessionsSync(hostKey: 'ssh:other', workspace: 'all'), isNull);
      expect(cache.loadSessionsSync(hostKey: 'ssh:akimoto', workspace: 'workspace:w1'), isNull);
    });

    test('a corrupt file is dropped and reads as null', () async {
      await cache.saveSessions(
        hostKey: 'ssh:akimoto',
        workspace: 'all',
        data: projection([row('s1', 'First', 1000)]),
      );
      final file = await theFile('sessions-');
      await file.writeAsString('this is not json', flush: true);
      expect(cache.loadSessionsSync(hostKey: 'ssh:akimoto', workspace: 'all'), isNull);
      expect(await file.exists(), isFalse);
    });

    test('an expired file is dropped and reads as null', () async {
      final t0 = DateTime(2026, 11, 7, 12);
      final old = OfflineCache(rootOverride: () async => dir, now: () => t0);
      await old.warmUp();
      await old.saveSessions(
        hostKey: 'ssh:akimoto',
        workspace: 'all',
        data: projection([row('s1', 'First', 1000)]),
      );
      final late = OfflineCache(rootOverride: () async => dir, now: () => t0.add(const Duration(hours: 25)));
      await late.warmUp();
      expect(late.loadSessionsSync(hostKey: 'ssh:akimoto', workspace: 'all'), isNull);
    });

    test('fromJson skips bad rows and returns null for garbage', () {
      expect(CachedSessions.fromJson('nope'), isNull);
      expect(CachedSessions.fromJson({'sessions': 'nope'}), isNotNull);
      final parsed = CachedSessions.fromJson({
        'sessions': [
          {'id': 's1', 'title': 'First', 'updated': 1000},
          {'id': '', 'title': 'Bad', 'updated': 1000},
          {'title': 'No id', 'updated': 1000},
          {'id': 's2', 'title': 'Second', 'updated': 2000},
        ],
        'bots': [],
        'scoped': false,
      });
      expect(parsed!.sessions.map((s) => s.sessionId), ['s1', 's2']);
    });

    test('clearHost removes only that host', () async {
      await cache.saveSessions(
        hostKey: 'ssh:akimoto',
        workspace: 'all',
        data: projection([row('s1', 'First', 1000)]),
      );
      await cache.saveSessions(
        hostKey: 'ssh:other',
        workspace: 'all',
        data: projection([row('s9', 'Ninth', 9000)]),
      );
      await cache.clearHost('ssh:akimoto');
      expect(cache.loadSessionsSync(hostKey: 'ssh:akimoto', workspace: 'all'), isNull);
      expect(cache.loadSessionsSync(hostKey: 'ssh:other', workspace: 'all'), isNotNull);
    });
  });

  group('conversation transcripts', () {
    test('round-trip restores the transcript items', () async {
      final events = sampleEvents();
      await cache.saveMessages(
        hostKey: 'ssh:akimoto',
        sessionId: 's1',
        events: events,
        cursor: 4,
        hasMore: false,
      );
      final loaded = cache.loadMessagesSync(hostKey: 'ssh:akimoto', sessionId: 's1');
      expect(loaded, isNotNull);
      expect(loaded!.events.map((e) => e.seq), [1, 2, 3, 4]);
      expect(loaded.cursor, 4);
      expect(loaded.hasMore, isFalse);

      final transcript = ChatTranscript();
      transcript.apply(
        SessionSnapshotEvent(
          sessionId: 's1',
          header: SessionHeader.fromJson(const {}),
          cursor: loaded.cursor,
          events: loaded.events,
          hasMore: loaded.hasMore,
          projections: SessionProjections.empty,
          assistantRevision: null,
          isResync: true,
        ),
      );
      transcript.hasMoreHistory = loaded.hasMore;
      final texts = transcript.items.map((i) {
        return switch (i) {
          UserChatItem(:final text) => text,
          AssistantChatItem(:final text) => text,
          _ => '',
        };
      }).toList();
      expect(texts, containsAll(['hello', 'hi there']));
      expect(transcript.title, 'Greetings');
    });

    test('a host never reads another host or session file', () async {
      await cache.saveMessages(
        hostKey: 'ssh:akimoto',
        sessionId: 's1',
        events: sampleEvents(),
        cursor: 4,
        hasMore: false,
      );
      expect(cache.loadMessagesSync(hostKey: 'ssh:other', sessionId: 's1'), isNull);
      expect(cache.loadMessagesSync(hostKey: 'ssh:akimoto', sessionId: 's2'), isNull);
    });

    test('only the most recent 200 events are kept', () async {
      final many = [
        for (var i = 0; i < 250; i++) SessionLogEvent.fromJson(wire(i, 'turn/start', {'turn': i})),
      ];
      await cache.saveMessages(
        hostKey: 'ssh:akimoto',
        sessionId: 's1',
        events: many,
        cursor: 249,
        hasMore: true,
      );
      final loaded = cache.loadMessagesSync(hostKey: 'ssh:akimoto', sessionId: 's1');
      expect(loaded!.events, hasLength(200));
      expect(loaded.events.first.seq, 50);
      expect(loaded.events.last.seq, 249);
    });

    test('a single oversized event is not saved', () async {
      final huge = 'x' * (600 * 1024);
      final events = [
        SessionLogEvent.fromJson(wire(1, 'user/message', {
          'id': 'm1',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': huge},
          ],
          'source': {'kind': 'user'},
        })),
      ];
      await cache.saveMessages(
        hostKey: 'ssh:akimoto',
        sessionId: 's1',
        events: events,
        cursor: 1,
        hasMore: false,
      );
      expect(cache.loadMessagesSync(hostKey: 'ssh:akimoto', sessionId: 's1'), isNull);
    });

    test('message files are pruned to the newest 20 sessions', () async {
      for (var i = 0; i < 21; i++) {
        await cache.saveMessages(
          hostKey: 'ssh:akimoto',
          sessionId: 's$i',
          events: sampleEvents(),
          cursor: 4,
          hasMore: false,
        );
      }
      final files = await Directory('${dir.path}/offline-cache')
          .list()
          .where((e) => e is File && e.path.split('/').last.startsWith('messages-'))
          .toList();
      expect(files, hasLength(20));
      expect(cache.loadMessagesSync(hostKey: 'ssh:akimoto', sessionId: 's0'), isNull);
      expect(cache.loadMessagesSync(hostKey: 'ssh:akimoto', sessionId: 's20'), isNotNull);
    });
  });
}
