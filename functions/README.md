# RunTogether — Cloud Functions

TypeScript · Node 22 · `firebase-functions` v7 (v2 API) · `firebase-admin` v14.
Region: `asia-northeast3` (set once in [`src/config.ts`](src/config.ts)).
Data contract: [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

| File | Contents |
|---|---|
| `src/index.ts` | exports every function |
| `src/config.ts` | `initializeApp()` + `setGlobalOptions({ region: 'asia-northeast3' })` |
| `src/auth.ts` | `kakaoLogin`, `naverLogin`, `instagramAuthRedirect` |
| `src/party.ts` | `createParty`, `joinParty`, `leaveParty`, `kickMember`, `deleteParty`, `startParty` |
| `src/runs.ts` | `onRunCreated` (verification, stats, party results, loyalty) |
| `src/sessions.ts` | `finalizeSession`, `onLiveMemberWritten`, `cleanupSessions` |
| `src/util/*` | polyline decoder, haversine / KST dates, FCM helper |

## 1. Prerequisites

1. **Blaze plan** — Cloud Functions (2nd gen), Secret Manager, Cloud Scheduler and
   outbound HTTP calls (Kakao/Naver/Instagram) require the pay-as-you-go plan:
   Firebase console → ⚙ → *Usage and billing* → *Modify plan* → Blaze.
2. Firebase CLI: `npm i -g firebase-tools` then `firebase login`.
3. Put your project id in `../.firebaserc` (`default`), or `firebase use --add`.
4. Enable in the console: Authentication, Firestore (location **asia-northeast3**),
   Realtime Database (note its location), Cloud Messaging.
5. Custom tokens: the runtime service account
   (`<project-number>-compute@developer.gserviceaccount.com`) needs the
   **Service Account Token Creator** role (`iam.serviceAccountTokenCreator`) and the
   *IAM Service Account Credentials API* enabled, otherwise `createCustomToken` fails.

## 2. Parameters & secrets

String params (`defineString`) are read from `functions/.env` (or `.env.<projectId>`)
at deploy time. Copy the template and fill it in:

```bash
cp functions/.env.example functions/.env
```

| Name | Kind | Value |
|---|---|---|
| `KAKAO_APP_ID` | string | Kakao Developers → 앱 ID (numeric). Tokens from other apps are rejected. |
| `INSTAGRAM_APP_ID` | string | Meta app → Instagram → App ID |
| `INSTAGRAM_REDIRECT_URI` | string | Exactly the redirect URI registered in Meta, i.e. the URL of `instagramAuthRedirect` (`https://asia-northeast3-<projectId>.cloudfunctions.net/instagramAuthRedirect`) |
| `RTDB_REGION` | string | Location of the default RTDB instance (`us-central1`, `asia-southeast1`, `europe-west1`). RTDB triggers must be deployed in the database's location. Default `us-central1`. |
| `INSTAGRAM_APP_SECRET` | **secret** | `firebase functions:secrets:set INSTAGRAM_APP_SECRET` (stored in Secret Manager) |

If a string param is missing, `firebase deploy` prompts for it.

### Instagram flow
The app opens
`https://www.instagram.com/oauth/authorize?client_id=<INSTAGRAM_APP_ID>&redirect_uri=<INSTAGRAM_REDIRECT_URI>&response_type=code&scope=instagram_business_basic&state=<random>`.
`instagramAuthRedirect` exchanges the code and redirects (302) to
`runtogether://auth?token=<customToken>&state=<state>` or
`runtogether://auth?error=<reason>&state=<state>`. `state` is mandatory; the app must
compare it to the value it generated.

## 3. Build

```bash
cd functions
npm install
npm run build        # tsc → lib/
```

Local emulators: `npm run serve` (Auth, Firestore, RTDB, Functions).

## 4. Deploy

```bash
# rules + indexes
firebase deploy --only firestore:rules,firestore:indexes,database

# functions (predeploy runs `npm --prefix functions run build`)
firebase deploy --only functions

# or a single function
firebase deploy --only functions:joinParty
```

Notes
* `onRunCreated` is a Firestore trigger; Firestore must be in `asia-northeast3`
  (if your database is elsewhere, change `REGION` in `src/config.ts`).
* `cleanupSessions` creates a Cloud Scheduler job (every 15 min, Asia/Seoul).
* Composite indexes in `../firestore.indexes.json` must finish building before the
  `hostId+status` (createParty limit) and `status+createdAt` (cleanup) queries work.
