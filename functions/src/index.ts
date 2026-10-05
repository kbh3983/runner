/**
 * RunTogether Cloud Functions entry point.
 * Data contract: ../docs/ARCHITECTURE.md (section 5).
 */
import "./config"; // initializeApp + setGlobalOptions({ region: 'asia-northeast3' })

export { kakaoLogin, naverLogin } from "./auth";
export { createParty, joinParty, leaveParty, kickMember, deleteParty, startParty } from "./party";
export { onRunCreated } from "./runs";
export { onLiveMemberWritten, cleanupSessions } from "./sessions";
