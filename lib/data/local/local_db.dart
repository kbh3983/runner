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

  Future<Database> get db async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'runtogether.db'),
      version: 1,
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode=WAL');
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
    await d.insert('runs', run.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
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
}
