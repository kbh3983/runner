# RunTogether — Architecture & Data Contract

이 문서는 Flutter 앱 / Cloud Functions / Security Rules 가 공유하는 **데이터 계약**입니다.
필드명을 바꿀 때는 반드시 이 문서와 세 곳을 함께 수정하세요.

## 1. 저장소 역할

| 저장소 | 역할 |
|---|---|
| Local DB (sqflite) | 현재 러닝 & GPS 원본 데이터, 사진 경로, 메모 (러닝 데이터의 **원본**) |
| Realtime Database | 단체 러닝 중 실시간 상태 (최소 데이터) |
| Cloud Firestore | 완료된 러닝 / 사용자 / 통계 / 파티 (영구 저장소) |
| Firebase Auth | 인증 & uid |
| FCM | 푸시 알림 |
| Cloud Functions | 소셜 로그인 커스텀 토큰, 파티 관리(비밀번호 검증), 기록 검증, 통계, 세션 정리 |

```
GPS ─▶ Local DB ─▶ (러닝 진행) ─▶ 러닝 종료 ─▶ Firestore runs/{runId}
              └─(단체 러닝일 때만, 3~5초 주기)─▶ RTDB liveSessions/{partyKey}
```

* FK 없음. 모든 관계는 ID 문자열로만 연결.
* Functions region: `asia-northeast3`.

## 2. ID 규칙

* `uid` : Firebase Auth uid. 커스텀 토큰 사용자 → `kakao:{id}`, `naver:{id}`, `instagram:{id}`.
* `partyId` (사용자에게 보여주고 공유하는 ID) : `{hostUid}#{roomNo}`
  * `roomNo` 는 `users/{hostUid}.partyCounter` 를 트랜잭션으로 +1 한 정수 → 전역 유일.
* `partyKey` (DB 키) : `partyId` 의 `#` 를 `_` 로 치환한 값. (RTDB 키에는 `#` 사용 불가)
  * 예: `abc123#7` → `abc123_7`
* `runId` : 클라이언트가 생성한 UUID v4. Firestore 업로드 시 문서 ID로 그대로 사용 (멱등 업로드).

## 3. Firestore

### `users/{uid}`
```
displayName: string
photoUrl: string|null
provider: 'google'|'apple'|'kakao'|'naver'|'instagram'
fcmTokens: string[]
createdAt: timestamp
partyCounter: number          // Functions 만 수정
stats: {                      // Functions 만 수정 (검증된 거리 기반)
  totalRuns: number, totalDistanceM: number, totalDurationMs: number,
  bestPaceSecPerKm: number|null, lastRunAt: timestamp
}
```
* 클라이언트는 본인 문서의 `displayName, photoUrl, provider, fcmTokens, createdAt` 만 쓸 수 있다.

### `users/{uid}/monthlyStats/{yyyy-MM}` (Functions 만 작성)
```
runs: number, distanceM: number, durationMs: number, days: string[] // 'yyyy-MM-dd'
```

### `runs/{runId}`  (클라이언트 작성, 소유자만)
```
id: string                 // == runId
ownerId: string            // == auth.uid
ownerName: string
mode: 'solo'|'group'
partyKey: string|null
partyId: string|null
goalType: 'none'|'distance'|'time'
goalValue: number|null     // distance → meters, time → seconds
loyalty: bool              // 의리게임
startedAt: number          // epoch ms (내 러닝 시작)
endedAt: number            // epoch ms
raceStartAt: number|null   // 단체 러닝 공통 시작 시각 epoch ms (서버 시간 기준)
durationMs: number         // 일시정지 제외 이동 시간
distanceM: number
avgPaceSecPerKm: number|null
maxSpeedMps: number|null
elevationGainM: number|null
colorIndex: number|null    // 단체 러닝 시 파티원 색 (0..9)
splits: [ { km: number, movingMs: number, raceMs: number|null, paceSec: number } ]
          // km 지점 통과 시점. raceMs = 통과시각 - raceStartAt (단체 러닝 순위 계산용)
timeline: [ { t: number, d: number, r: number|null } ]
          // 30초(이동시간) 간격 샘플. t=이동시간(s), d=누적거리(m), r=race 경과(s)
path: string               // Google encoded polyline (다운샘플, 최대 ~1500 pts)
pathTimes: number[]        // path 각 점의 startedAt 기준 경과 초
pathBreaks: number[]       // 일시정지 후 새 구간이 시작되는 점 인덱스
memos: [ { id: string, text: string, createdAt: number } ]
clientVersion: string
createdAt: serverTimestamp
updatedAt: serverTimestamp
// ↓ Functions 만 작성 (클라이언트 쓰기 금지)
verification: { verified: bool, flags: string[], serverDistanceM: number, checkedAt: timestamp }
```
* 사진은 **서버에 저장하지 않는다** (로컬 전용).
* 클라이언트 업데이트는 `memos`, `updatedAt` 만 허용 (생성 후).

### `parties/{partyKey}`  (Functions 만 작성, 멤버만 읽기)
```
id: string                 // partyId  (uid#roomNo)
key: string                // partyKey
hostId: string
hostName: string
roomNo: number
maxMembers: number         // 2..10 (방장 포함)
goalType: 'none'|'distance'|'time'
goalValue: number|null     // meters | seconds
loyalty: bool              // goalType=='distance' 일 때만 true 가능
status: 'waiting'|'running'|'finished'|'success'|'failed'
                           // success/failed 는 의리게임 전용
memberIds: string[]        // 방장 포함
members: { [uid]: { name: string, photoUrl: string|null, colorIndex: number, joinedAt: number } }
bannedIds: string[]        // 강퇴된 사용자 (재참여 불가)
createdAt: timestamp
startAt: number|null       // epoch ms, 카운트다운 종료(=출발) 시각. 서버 now + 7000
loyaltyDeadline: number|null // startAt + 24h
loyaltyProgress: { totalM: number, contributions: { [uid]: number } }  // 검증 거리
finishedAt: timestamp|null
finalLive: { [uid]: <RTDB member 노드 마지막 스냅샷> } | null  // 세션 종료 시 RTDB → Firestore
```

### `parties/{partyKey}/private/secret` (Functions 만 접근)
```
passwordHash: string   // sha256(salt + password)
salt: string
```

### `parties/{partyKey}/results/{runId}` (Functions 가 runs 생성 시 복사, 멤버만 읽기)
`runs/{runId}` 에서 `memos` 를 제외한 모든 필드 + `verification`.

## 4. Realtime Database

```
liveSessions/{partyKey}/
  meta: { hostId, startAt, goalType, goalValue, loyalty, status: 'RUNNING'|'COMPLETED'|'FAILED' }
  allowed/{uid}: true                 // Functions 가 작성 (startParty 시점의 멤버)
  members/{uid}: {                    // 각 클라이언트가 본인 노드만 작성
    userId: string,
    name: string,
    colorIndex: number,
    distance: number,      // km (소수 3자리)  ← 이번 세션 거리
    baseDistance: number,  // km, 의리게임에서 이전 세션까지 내가 기여한 거리 (그 외 0)
    pace: number,          // 평균 페이스 sec/km (정수, 0 = 없음)
    latitude: number,
    longitude: number,
    status: 'READY'|'RUNNING'|'PAUSED'|'FINISHED',
    connected: bool,       // onDisconnect → false
    updatedAt: number      // epoch ms (ServerValue.timestamp)
  }
```
* 순위는 저장하지 않는다. 클라이언트에서 `distance DESC` 정렬.
* 의리게임 팀 합계 = Σ(baseDistance + distance).
* 업데이트 주기: 기본 4초, 이동 없으면 최대 15초마다 heartbeat, 상태 변화 시 즉시.

## 5. Cloud Functions (asia-northeast3)

| 이름 | 종류 | 입력 → 출력 |
|---|---|---|
| `kakaoLogin` | callable (비인증 허용) | `{accessToken}` → `{token}` (custom token, uid `kakao:{id}`) |
| `naverLogin` | callable (비인증 허용) | `{accessToken}` → `{token}` (uid `naver:{id}`) |
| `instagramAuthRedirect` | https (GET) | Instagram OAuth redirect_uri. code 교환 → custom token → `runtogether://auth?token=...` 로 302 |
| `createParty` | callable | `{maxMembers, goalType, goalValue, loyalty, password}` → `{partyId, partyKey}` |
| `joinParty` | callable | `{partyId, password}` → `{partyKey}`; 에러 코드: `not-found`, `permission-denied`(비밀번호/강퇴), `resource-exhausted`(정원), `failed-precondition`(이미 시작 → 메시지 "러닝이 이미 시작되었어요") |
| `leaveParty` | callable | `{partyKey}` (방장은 불가 → deleteParty) |
| `kickMember` | callable | `{partyKey, uid}` (방장만, 대기 상태에서만) |
| `deleteParty` | callable | `{partyKey}` (방장만) → Firestore + RTDB 삭제 |
| `startParty` | callable | `{partyKey}` (방장만, waiting 상태) → status=running, startAt=now+7000, RTDB meta/allowed 생성, 멤버에 FCM |
| `onRunCreated` | firestore onCreate `runs/{runId}` | 검증(verification) → 통계 갱신 → 단체면 results 복사, 의리게임 진행도 갱신/성공 판정, 전원 완료 시 세션 종료 처리 |
| `onLiveMemberWritten` | RTDB onWrite `liveSessions/{key}/members/{uid}` | 일반 파티: 전원 FINISHED 면 finalizeSession |
| `cleanupSessions` | scheduler (15분) | 의리게임 24h 초과 → failed, 일반 파티 running 24h 초과 → finished, RTDB 정리 |

`finalizeSession(partyKey, status)` : RTDB members 스냅샷 → `parties/{key}.finalLive`, party.status 갱신, `liveSessions/{key}` 삭제, 멤버에 FCM.

### 서버 검증 (`onRunCreated`)
* `path` 디코드 → haversine 합 = `serverDistanceM` (pathBreaks 구간 사이 거리는 제외).
* flags: `distance_mismatch` (serverDistance < distanceM*0.85), `too_fast` (avgPace < 150s/km),
  `speed_spike` (연속 점 사이 > 12 m/s 가 전체 구간 5% 이상), `bad_time` (endedAt > now+5min 또는 durationMs > endedAt-startedAt+60s).
* `effectiveDistance = verified ? distanceM : min(distanceM, serverDistanceM)` → 통계/의리게임에 사용.

### FCM data payload
`{ type: 'party_started'|'party_joined'|'party_kicked'|'party_deleted'|'loyalty_success'|'loyalty_failed'|'party_finished', partyKey }`

## 6. Local DB (sqflite) — 앱 내부 전용

* `runs` : 위 runs 필드 + `status(active|paused|finished)`, `sync_status(pending|synced)`, `thumbnail_path`, `participants_json`, `remote_path_json`
* `gps_points` : `run_id, seq, lat, lng, ts, speed, altitude, accuracy, distance, pace, segment, elapsed_ms`
* `photos` : `id, run_id, rel_path, created_at`  (앱 Documents 기준 **상대 경로** 저장)
* `memos` : `id, run_id, text, created_at`

## Backend notes

Decisions made while implementing `functions/` and the rules (gaps in the contract above):

* **Join brute-force counter**: `parties/{partyKey}/private/attempts` = `{ counts: { [uid]: number }, updatedAt }`. 10 wrong passwords → `resource-exhausted` "시도 횟수를 초과했어요". Already-member check runs before the status check, so `joinParty` is idempotent for members (returns `{partyKey}`).
* **Max 5 active hosted parties** (`waiting|running`) per host → `createParty` fails with `failed-precondition`.
* `leaveParty` / `kickMember` / `deleteParty` / `startParty` return `{ ok: true }` / `{ startAt }`. `leaveParty`: host → `failed-precondition`; only while `waiting`. Kicked uid is added to `bannedIds`.
* **finalizeSession only acts on `status == 'running'`** (idempotent). `finalLive` is the raw RTDB `members` map (or `null`).
* **Loyalty**: when the live RTDB total Σ(baseDistance+distance) reaches the goal, the function sets `liveSessions/{key}/meta/status = 'COMPLETED'` (UI hint only). The party becomes `success` only when verified run uploads bring `loyaltyProgress.totalM ≥ goalValue × 0.97`. Contributions only count while the party is `running`. At `loyaltyDeadline`, cleanup marks `failed` (or `success` if totalM already reached the threshold).
* **Normal party end**: `finished` when every `allowed` uid has RTDB status `FINISHED`, or every `memberIds` uid has a `results` doc, or 24 h after `startAt` (cleanup). Waiting parties older than 7 days are deleted.
* **Stats**: `monthlyStats/{yyyy-MM}` and `days` use the run's `startedAt` in Asia/Seoul. `bestPaceSecPerKm` is an integer (rounded), only from verified runs ≥ 1 km; initialised to `null`. `lastRunAt` = run `endedAt` as Timestamp. Verification + stats + results copy + loyalty progress are written in one transaction guarded by "verification not yet present" (no double counting on retries).
* **Results doc** (`parties/{key}/results/{runId}`) is written for any group run whose owner is in `memberIds`, regardless of party status.
* **RTDB rules**: member node only requires `userId` (== `$uid`) in the merged node; every child is validated individually, unknown children rejected. Partial `update()` and `onDisconnect().update({connected:false})` work on an existing node.
* **Firestore rules**: `get` of a non-existent `runs/{runId}` is allowed for signed-in users (idempotent upload check).
* **Extra indexes**: `parties (hostId ASC, status ASC)` for the active-party limit, `parties (status ASC, createdAt ASC)` for cleanup.
* **RTDB trigger region**: `onLiveMemberWritten` is deployed in the RTDB instance's location (param `RTDB_REGION`, default `us-central1`), since RTDB triggers must be co-located with the database. All other functions are in `asia-northeast3`.
* Callable error messages are Korean and user-presentable (`HttpsError.message`).
