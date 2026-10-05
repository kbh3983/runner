import Flutter
import NidThirdPartyLogin
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // UIScene 기반 앱에서는 외부 URL 이 SceneDelegate 로 들어온다.
  // 네이버 앱 로그인 결과를 먼저 처리하고, 나머지(카카오/딥링크 등)는 Flutter 플러그인에 넘긴다.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    var rest = Set<UIOpenURLContext>()
    for context in URLContexts {
      if NidOAuth.shared.handleURL(context.url) != true {
        rest.insert(context)
      }
    }
    if !rest.isEmpty {
      super.scene(scene, openURLContexts: rest)
    }
  }
}
