import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/gps_point.dart';
import '../models/run_record.dart';

/// Local Database — 러닝 데이터의 1차 원본 저장소.
///
/// GPS 원본, 진행 중 러닝, 완료 러닝, 사진 경로, 메모를 보관한다.
/// 네트워크와 무관하게 동작해야 하므로 모든 러닝 쓰기는 반드시 여기부터 한다.
class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();

  Database? _db;

  /// 데이터가 바뀌면 증가 → 화면이 다시 읽도록
  final ValueNotifier<int> changes = ValueNotifier(0);

  void _notify() => changes.value++;

  bool _columnsEnsured = false;

  Future<void> _ensureColumns(Database d) async {
    if (_columnsEnsured) return;
    try {
      final info = await d.rawQuery('PRAGMA table_info(runs)');
      final names = info.map((r) => r['name'] as String?).toSet();
      if (!names.contains('region')) {
        await d.execute('ALTER TABLE runs ADD COLUMN region TEXT');
      }
      await d.execute('''
        CREATE TABLE IF NOT EXISTS point_history (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          points INTEGER NOT NULL,
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          description TEXT,
          created_at INTEGER NOT NULL,
          ref_id TEXT
        )
      ''');
      await d.execute('CREATE INDEX IF NOT EXISTS idx_point_history_user ON point_history (user_id, created_at DESC)');
      await d.execute('CREATE INDEX IF NOT EXISTS idx_point_history_ref ON point_history (ref_id)');
      _columnsEnsured = true;
    } catch (e) {
      debugPrint('Error ensuring region column: $e');
    }
  }

  Future<Database> get db async {
    _db ??= await _open();
    await _ensureColumns(_db!);
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return await openDatabase(
      p.join(dir, 'runtogether.db'),
      version: 2,
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode=WAL');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute('ALTER TABLE runs ADD COLUMN region TEXT');
          } catch (_) {}
        }
      },
      onOpen: (db) async {
        try {
          await db.execute('ALTER TABLE runs ADD COLUMN region TEXT');
        } catch (_) {}
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE runs (
            id TEXT PRIMARY KEY,
            owner_id TEXT NOT NULL,
            owner_name TEXT,
            mode TEXT NOT NULL,
            party_key TEXT,
            party_id TEXT,
            goal_type TEXT,
            goal_value REAL,
            loyalty INTEGER DEFAULT 0,
            status TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            race_start_at INTEGER,
            duration_ms INTEGER DEFAULT 0,
            distance_m REAL DEFAULT 0,
            avg_pace REAL,
            max_speed REAL,
            elevation_gain REAL,
            color_index INTEGER,
            splits_json TEXT,
            timeline_json TEXT,
            thumbnail_path TEXT,
            sync_status TEXT DEFAULT 'pending',
            participants_json TEXT,
            remote_path_json TEXT,
            region TEXT,
            updated_at INTEGER
          )
        ''');
        await db.execute('CREATE INDEX idx_runs_owner ON runs(owner_id, started_at DESC)');
        await db.execute('CREATE INDEX idx_runs_party ON runs(party_key)');
        await db.execute('''
          CREATE TABLE gps_points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            ts INTEGER NOT NULL,
            speed REAL,
            altitude REAL,
            accuracy REAL,
            distance REAL NOT NULL,
            pace REAL,
            segment INTEGER NOT NULL,
            elapsed_ms INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_points_run ON gps_points(run_id, seq)');
        await db.execute('''
          CREATE TABLE photos (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            rel_path TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_photos_run ON photos(run_id)');
        await db.execute('''
          CREATE TABLE memos (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_memos_run ON memos(run_id)');
        // 방장이 공유하기 위해 로컬에만 보관하는 파티 비밀번호 (서버엔 해시만 존재)
        await db.execute('''
          CREATE TABLE party_secrets (
            party_key TEXT PRIMARY KEY,
            password TEXT NOT NULL
          )
        ''');
      },
    );
  }

  // ---------------------------------------------------------------- runs

  Future<void> upsertRun(RunRecord run, {bool notify = true}) async {
    run.updatedAt = DateTime.now().millisecondsSinceEpoch;
    final d = await db;
    try {
      await d.insert('runs', run.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      // 컬럼 누락 에러일 경우 즉시 ALTER TABLE 후 재시도
      try {
        await d.execute('ALTER TABLE runs ADD COLUMN region TEXT');
        await d.insert('runs', run.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
      } catch (retryErr) {
        debugPrint('upsertRun fallback failed: $retryErr');
        try {
          final fallbackRow = run.toRow()..remove('region');
          await d.insert('runs', fallbackRow, conflictAlgorithm: ConflictAlgorithm.replace);
        } catch (fatalErr) {
          debugPrint('upsertRun fatal fallback error: $fatalErr');
        }
      }
    }
    if (notify) _notify();
  }

  Future<RunRecord?> getRun(String id) async {
    final d = await db;
    final rows = await d.query('runs', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : RunRecord.fromRow(rows.first);
  }

  Future<bool> runExists(String id) async {
    final d = await db;
    final rows = await d.query('runs', columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isNotEmpty;
  }

  Future<List<RunRecord>> getAllRuns() async {
    final d = await db;
    final rows = await d.query('runs', orderBy: 'started_at DESC');
    return rows.map(RunRecord.fromRow).toList();
  }

  /// 완료된 러닝 (최신순)
  Future<List<RunRecord>> getFinishedRuns(String ownerId) async {
    final d = await db;
    final rows = await d.query(
      'runs',
      where: 'owner_id = ? AND status = ?',
      whereArgs: [ownerId, RunStatus.finished.name],
      orderBy: 'started_at DESC',
    );
    return rows.map(RunRecord.fromRow).toList();
  }

  Future<List<RunRecord>> getFinishedRunsBetween(String ownerId, DateTime from, DateTime to) async {
    final d = await db;
    final rows = await d.query(
      'runs',
      where: 'owner_id = ? AND status = ? AND started_at >= ? AND started_at < ?',
      whereArgs: [ownerId, RunStatus.finished.name, from.millisecondsSinceEpoch, to.millisecondsSinceEpoch],
      orderBy: 'started_at DESC',
    );
    return rows.map(RunRecord.fromRow).toList();
  }

  /// 앱이 비정상 종료되어 남아 있는 진행 중 러닝
  Future<RunRecord?> getUnfinishedRun(String ownerId) async {
    final d = await db;
    final rows = await d.query(
      'runs',
      where: 'owner_id = ? AND status != ?',
      whereArgs: [ownerId, RunStatus.finished.name],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : RunRecord.fromRow(rows.first);
  }

  Future<List<RunRecord>> getRunsForParty(String ownerId, String partyKey) async {
    final d = await db;
    final rows = await d.query(
      'runs',
      where: 'owner_id = ? AND party_key = ?',
      whereArgs: [ownerId, partyKey],
      orderBy: 'started_at ASC',
    );
    return rows.map(RunRecord.fromRow).toList();
  }

  Future<List<RunRecord>> getRunsToSync(String ownerId) async {
    final d = await db;
    final rows = await d.query(
      'runs',
      where: 'owner_id = ? AND status = ? AND sync_status != ?',
      whereArgs: [ownerId, RunStatus.finished.name, SyncStatus.synced.name],
      orderBy: 'started_at ASC',
    );
    return rows.map(RunRecord.fromRow).toList();
  }

  Future<void> setSyncStatus(String runId, SyncStatus status) async {
    final d = await db;
    await d.update('runs', {'sync_status': status.name}, where: 'id = ?', whereArgs: [runId]);
    _notify();
  }

  Future<void> setThumbnail(String runId, String relPath) async {
    final d = await db;
    await d.update('runs', {'thumbnail_path': relPath}, where: 'id = ?', whereArgs: [runId]);
    _notify();
  }

  Future<void> deleteRun(String runId) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete('gps_points', where: 'run_id = ?', whereArgs: [runId]);
      await txn.delete('photos', where: 'run_id = ?', whereArgs: [runId]);
      await txn.delete('memos', where: 'run_id = ?', whereArgs: [runId]);
      await txn.delete('runs', where: 'id = ?', whereArgs: [runId]);
    });
    _notify();
  }

  // ---------------------------------------------------------------- gps

  Future<void> insertPoint(GpsPoint point) async {
    final d = await db;
    await d.insert('gps_points', point.toRow());
  }

  Future<List<GpsPoint>> getPoints(String runId) async {
    final d = await db;
    final rows = await d.query('gps_points', where: 'run_id = ?', whereArgs: [runId], orderBy: 'seq ASC');
    return rows.map(GpsPoint.fromRow).toList();
  }

  // ---------------------------------------------------------------- photos

  Future<void> insertPhoto(RunPhoto photo) async {
    final d = await db;
    await d.insert('photos', photo.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
    _notify();
  }

  Future<void> deletePhoto(String id) async {
    final d = await db;
    await d.delete('photos', where: 'id = ?', whereArgs: [id]);
    _notify();
  }

  Future<List<RunPhoto>> getPhotos(String runId) async {
    final d = await db;
    final rows = await d.query('photos', where: 'run_id = ?', whereArgs: [runId], orderBy: 'created_at ASC');
    return rows.map(RunPhoto.fromRow).toList();
  }

  /// runId → 첫 번째 사진 (달력 섬네일용)
  Future<Map<String, RunPhoto>> getFirstPhotos(List<String> runIds) async {
    if (runIds.isEmpty) return {};
    final d = await db;
    final marks = List.filled(runIds.length, '?').join(',');
    final rows = await d.rawQuery(
      'SELECT * FROM photos WHERE run_id IN ($marks) ORDER BY created_at ASC',
      runIds,
    );
    final map = <String, RunPhoto>{};
    for (final r in rows) {
      final photo = RunPhoto.fromRow(r);
      map.putIfAbsent(photo.runId, () => photo);
    }
    return map;
  }

  // ---------------------------------------------------------------- memos

  Future<void> insertMemo(RunMemo memo) async {
    final d = await db;
    await d.insert('memos', memo.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
    await _markMemoDirty(d, memo.runId);
    _notify();
  }

  Future<void> deleteMemo(RunMemo memo) async {
    final d = await db;
    await d.delete('memos', where: 'id = ?', whereArgs: [memo.id]);
    await _markMemoDirty(d, memo.runId);
    _notify();
  }

  Future<void> replaceMemos(String runId, List<RunMemo> memos) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete('memos', where: 'run_id = ?', whereArgs: [runId]);
      for (final m in memos) {
        await txn.insert('memos', m.toRow());
      }
    });
  }

  Future<void> _markMemoDirty(Database d, String runId) async {
    // 아직 업로드 전이면 pending 유지 (최초 업로드에 메모 포함됨)
    await d.update(
      'runs',
      {'sync_status': SyncStatus.memoPending.name},
      where: 'id = ? AND sync_status = ?',
      whereArgs: [runId, SyncStatus.synced.name],
    );
  }

  Future<List<RunMemo>> getMemos(String runId) async {
    final d = await db;
    final rows = await d.query('memos', where: 'run_id = ?', whereArgs: [runId], orderBy: 'created_at ASC');
    return rows.map(RunMemo.fromRow).toList();
  }

  // ---------------------------------------------------------------- party secrets

  Future<void> savePartySecret(String partyKey, String password) async {
    final d = await db;
    await d.insert('party_secrets', {'party_key': partyKey, 'password': password},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getPartySecret(String partyKey) async {
    final d = await db;
    final rows = await d.query('party_secrets', where: 'party_key = ?', whereArgs: [partyKey], limit: 1);
    return rows.isEmpty ? null : rows.first['password'] as String;
  }

  // ---------------------------------------------------------------- points

  Future<void> insertPointHistory(Map<String, dynamic> row) async {
    final d = await db;
    await d.insert('point_history', row, conflictAlgorithm: ConflictAlgorithm.replace);
    _notify();
  }

  Future<int> getTotalPoints(String userId) async {
    final d = await db;
    final res = await d.rawQuery(
      'SELECT COALESCE(SUM(points), 0) as total FROM point_history WHERE user_id = ?',
      [userId],
    );
    if (res.isEmpty) return 0;
    return (res.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<List<Map<String, dynamic>>> getPointHistory(String userId, {int limit = 100}) async {
    final d = await db;
    return await d.query(
      'point_history',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  Future<bool> hasPointWithRefId(String refId) async {
    final d = await db;
    final rows = await d.query(
      'point_history',
      columns: ['id'],
      where: 'ref_id = ?',
      whereArgs: [refId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> hasPointWithTypeOnDate(String userId, String type, int startMs, int endMs) async {
    final d = await db;
    final rows = await d.query(
      'point_history',
      columns: ['id'],
      where: 'user_id = ? AND type = ? AND created_at >= ? AND created_at <= ?',
      whereArgs: [userId, type, startMs, endMs],
      limit: 1,
    );
    return rows.isNotEmpty;
  }
}
