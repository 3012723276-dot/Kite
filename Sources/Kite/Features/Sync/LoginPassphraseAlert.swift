import SwiftUI

enum LoginPassphraseMode {
    /// A new passphrase for the folder; replaces any earlier one.
    case create
    /// The folder's existing passphrase, entered once per device.
    case unlock
}

private struct LoginPassphraseAlert: ViewModifier {
    @Binding var mode: LoginPassphraseMode?
    let onSubmit: (LoginPassphraseMode, String, String) -> Void
    @State private var passphrase = ""
    @State private var confirmation = ""

    func body(content: Content) -> some View {
        content.alert(
            mode == .create ? "设置同步密码" : "输入同步密码",
            isPresented: Binding(get: { mode != nil }, set: { if !$0 { mode = nil } }),
            presenting: mode
        ) { mode in
            SecureField("同步密码", text: $passphrase)
            if mode == .create { SecureField("再次输入", text: $confirmation) }
            Button("取消", role: .cancel) { clear() }
            Button(mode == .create ? "保存" : "解锁") {
                let entered = (passphrase, confirmation)
                clear()
                onSubmit(mode, entered.0, entered.1)
            }
        } message: { mode in
            switch mode {
            case .create: Text("登录信息会用此密码加密。其他设备需输入同一密码才能登录。")
            case .unlock: Text("输入在其他设备上设置的同步密码。")
            }
        }
    }

    private func clear() {
        passphrase = ""
        confirmation = ""
    }
}

extension View {
    func loginPassphraseAlert(
        mode: Binding<LoginPassphraseMode?>, onSubmit: @escaping (LoginPassphraseMode, String, String) -> Void
    ) -> some View {
        modifier(LoginPassphraseAlert(mode: mode, onSubmit: onSubmit))
    }
}
